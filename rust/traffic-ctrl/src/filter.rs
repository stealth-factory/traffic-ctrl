use std::collections::HashSet;
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use traffic_ctrl_core::ProcessId;
#[cfg(target_os = "macos")]
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum FilterState {
    Ready,
    Disabled,
    Unavailable,
    Error,
}

#[derive(Clone, Debug)]
pub struct FilterSnapshot {
    pub state: FilterState,
    pub blocked_pids: HashSet<u32>,
    pub message: Option<String>,
    pub busy: bool,
}

impl FilterSnapshot {
    pub fn is_blocked(&self, id: &ProcessId) -> bool {
        self.blocked_pids.contains(&id.pid)
    }
}

enum FilterCommand {
    Status,
    SetBlocked(bool, ProcessId),
}

pub struct FilterController {
    commands: SyncSender<FilterCommand>,
    results: Receiver<FilterSnapshot>,
    snapshot: FilterSnapshot,
    last_refresh: Instant,
}

impl FilterController {
    pub fn start() -> Result<Self, String> {
        let (command_tx, command_rx) = mpsc::sync_channel(1);
        let (result_tx, result_rx) = mpsc::channel();
        thread::Builder::new()
            .name("traffic-ctrl-filter".into())
            .spawn(move || {
                while let Ok(command) = command_rx.recv() {
                    let result = match command {
                        FilterCommand::Status => perform(FilterAction::Status, None),
                        FilterCommand::SetBlocked(blocked, id) => {
                            let action = if blocked {
                                FilterAction::Block
                            } else {
                                FilterAction::Unblock
                            };
                            perform(action, Some(id))
                        }
                    };
                    if result_tx.send(result).is_err() {
                        break;
                    }
                }
            })
            .map_err(|error| format!("could not start filter client: {error}"))?;
        Ok(Self {
            commands: command_tx,
            results: result_rx,
            snapshot: FilterSnapshot {
                state: FilterState::Unavailable,
                blocked_pids: HashSet::new(),
                message: Some("Network filter service is not installed".into()),
                busy: false,
            },
            last_refresh: Instant::now() - Duration::from_secs(10),
        })
    }

    pub fn refresh(&mut self, force: bool) {
        if self.snapshot.busy || (!force && self.last_refresh.elapsed() < Duration::from_secs(2)) {
            return;
        }
        if self.commands.try_send(FilterCommand::Status).is_ok() {
            self.snapshot.busy = true;
            self.last_refresh = Instant::now();
        }
    }

    pub fn set_blocked(&mut self, blocked: bool, id: ProcessId) -> Result<(), String> {
        if self.snapshot.state != FilterState::Ready {
            return Err(self
                .snapshot
                .message
                .clone()
                .unwrap_or_else(|| "Network filter is unavailable".into()));
        }
        if self.snapshot.busy {
            return Err("Network filter is busy; try again".into());
        }
        self.commands
            .try_send(FilterCommand::SetBlocked(blocked, id))
            .map_err(|_| "Network filter is busy; try again".to_owned())?;
        self.snapshot.busy = true;
        Ok(())
    }

    pub fn drain(&mut self) -> bool {
        let mut changed = false;
        while let Ok(snapshot) = self.results.try_recv() {
            self.snapshot = snapshot;
            changed = true;
        }
        changed
    }

    pub fn snapshot(&self) -> &FilterSnapshot {
        &self.snapshot
    }
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
enum FilterAction {
    Status,
    Block,
    Unblock,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
#[cfg(target_os = "macos")]
struct FilterRequest {
    protocol_version: u32,
    request_id: Uuid,
    action: FilterAction,
    process: Option<FilterProcessIdentity>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[cfg(target_os = "macos")]
struct FilterProcessIdentity {
    pid: u32,
    name: String,
    executable_path: String,
    start_time_microseconds: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
#[cfg(target_os = "macos")]
struct FilterResponse {
    protocol_version: u32,
    request_id: Uuid,
    state: FilterState,
    blocked_processes: Vec<FilterProcessIdentity>,
    message: Option<String>,
}

#[cfg(target_os = "macos")]
fn perform(action: FilterAction, process: Option<ProcessId>) -> FilterSnapshot {
    match send_request(action, process) {
        Ok(response) => FilterSnapshot {
            state: response.state,
            blocked_pids: response
                .blocked_processes
                .into_iter()
                .map(|process| process.pid)
                .collect(),
            message: response.message,
            busy: false,
        },
        Err(message) => FilterSnapshot {
            state: FilterState::Unavailable,
            blocked_pids: HashSet::new(),
            message: Some(format!("Network block unavailable: {message}")),
            busy: false,
        },
    }
}

#[cfg(target_os = "linux")]
fn perform(_action: FilterAction, _process: Option<ProcessId>) -> FilterSnapshot {
    FilterSnapshot {
        state: FilterState::Unavailable,
        blocked_pids: HashSet::new(),
        message: Some("Linux network blocking requires the planned eBPF service".into()),
        busy: false,
    }
}

#[cfg(target_os = "macos")]
fn send_request(
    action: FilterAction,
    process: Option<ProcessId>,
) -> Result<FilterResponse, String> {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;

    let identity = process.map(process_identity).transpose()?;
    let request_id = Uuid::new_v4();
    let request = FilterRequest {
        protocol_version: 1,
        request_id,
        action,
        process: identity,
    };
    let home = std::env::var("HOME").map_err(|_| "HOME is unavailable")?;
    let path = format!("{home}/Library/Application Support/Traffic Ctrl/filter.sock");
    let mut stream = UnixStream::connect(path).map_err(|error| match error.kind() {
        std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused => {
            "filter service is not installed or running".to_owned()
        }
        _ => error.to_string(),
    })?;
    let timeout = Some(Duration::from_millis(300));
    stream
        .set_read_timeout(timeout)
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(timeout)
        .map_err(|error| error.to_string())?;
    serde_json::to_writer(&mut stream, &request).map_err(|error| error.to_string())?;
    stream.write_all(b"\n").map_err(|error| error.to_string())?;
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .map_err(|error| error.to_string())?;
    if line.len() > 1_048_576 || line.is_empty() {
        return Err("filter service returned an invalid response".into());
    }
    let response: FilterResponse =
        serde_json::from_str(&line).map_err(|error| error.to_string())?;
    if response.protocol_version != 1 || response.request_id != request_id {
        return Err("filter service returned an invalid response".into());
    }
    Ok(response)
}

#[cfg(target_os = "macos")]
fn process_identity(id: ProcessId) -> Result<FilterProcessIdentity, String> {
    const PROC_PIDTBSDINFO: i32 = 3;
    const MAX_PATH: usize = 4096;
    let mut info = ProcBsdInfo::default();
    let expected = std::mem::size_of::<ProcBsdInfo>() as i32;
    let read = unsafe {
        proc_pidinfo(
            id.pid as i32,
            PROC_PIDTBSDINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            expected,
        )
    };
    if read != expected {
        return Err(format!("Could not verify {} (PID {})", id.name, id.pid));
    }
    let mut path = [0u8; MAX_PATH];
    let length = unsafe {
        proc_pidpath(
            id.pid as i32,
            path.as_mut_ptr() as *mut libc::c_void,
            path.len() as u32,
        )
    };
    if length <= 0 {
        return Err(format!("Could not verify {} (PID {})", id.name, id.pid));
    }
    let end = path
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(length as usize);
    Ok(FilterProcessIdentity {
        pid: id.pid,
        name: id.name,
        executable_path: String::from_utf8_lossy(&path[..end]).into_owned(),
        start_time_microseconds: info
            .start_tvsec
            .saturating_mul(1_000_000)
            .saturating_add(info.start_tvusec),
    })
}

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Default)]
struct ProcBsdInfo {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu_1: u32,
    comm: [u8; 16],
    name: [u8; 32],
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    nice: i32,
    start_tvsec: u64,
    start_tvusec: u64,
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn proc_pidinfo(
        pid: i32,
        flavor: i32,
        arg: u64,
        buffer: *mut libc::c_void,
        buffer_size: i32,
    ) -> i32;
    fn proc_pidpath(pid: i32, buffer: *mut libc::c_void, buffer_size: u32) -> i32;
}
