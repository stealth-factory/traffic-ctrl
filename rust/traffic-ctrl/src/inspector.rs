use std::collections::HashMap;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::thread;

use traffic_ctrl_core::ProcessId;

#[cfg(target_os = "macos")]
use std::collections::HashSet;
#[cfg(target_os = "linux")]
use std::{fs, path::PathBuf};

#[derive(Clone, Debug)]
pub struct OpenFile {
    pub path: String,
    pub display_path: String,
    pub size: u64,
}

#[derive(Clone, Debug, Default)]
pub struct ProcessDetails {
    pub connections: Vec<String>,
    pub files: Vec<OpenFile>,
    pub note: Option<String>,
}

pub struct InspectionResult {
    pub id: ProcessId,
    pub details: ProcessDetails,
}

pub struct BackgroundInspector {
    requests: SyncSender<ProcessId>,
    results: Receiver<InspectionResult>,
}

impl BackgroundInspector {
    pub fn start() -> Result<Self, String> {
        let (request_tx, request_rx) = mpsc::sync_channel::<ProcessId>(1);
        let (result_tx, result_rx) = mpsc::channel();
        thread::Builder::new()
            .name("traffic-ctrl-inspector".into())
            .spawn(move || {
                while let Ok(id) = request_rx.recv() {
                    let details = inspect(id.pid);
                    if result_tx.send(InspectionResult { id, details }).is_err() {
                        break;
                    }
                }
            })
            .map_err(|error| format!("could not start process inspector: {error}"))?;
        Ok(Self {
            requests: request_tx,
            results: result_rx,
        })
    }

    pub fn request(&self, id: ProcessId) {
        let _ = self.requests.try_send(id);
    }

    pub fn drain(&self) -> Vec<InspectionResult> {
        let mut values = Vec::new();
        while let Ok(result) = self.results.try_recv() {
            values.push(result);
        }
        values
    }
}

#[cfg(target_os = "macos")]
fn inspect(pid: u32) -> ProcessDetails {
    let output = match Command::new("/usr/sbin/lsof")
        .args(["-nP", "-p", &pid.to_string()])
        .output()
    {
        Ok(output) if output.status.success() => output,
        Ok(_) => {
            return ProcessDetails {
                note: Some("Open-file details are unavailable for this process.".into()),
                ..ProcessDetails::default()
            };
        }
        Err(error) => {
            return ProcessDetails {
                note: Some(error.to_string()),
                ..ProcessDetails::default()
            };
        }
    };
    parse_lsof(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(target_os = "macos")]
fn parse_lsof(output: &str) -> ProcessDetails {
    let mut connections = HashSet::new();
    let mut files = HashMap::new();
    for line in output.lines().skip(1) {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() < 9 {
            continue;
        }
        let kind = fields[4];
        let name = fields[8..].join(" ");
        if kind == "IPv4" || kind == "IPv6" {
            let connection = format!("{} {name}", fields[7]);
            if connection.starts_with("TCP ") || connection.starts_with("UDP ") {
                connections.insert(connection);
            }
        } else if kind == "REG"
            && (name.starts_with("/Users/") || name.starts_with("/private/var/"))
        {
            let size = fields[6].parse().unwrap_or(0);
            files.insert(
                name.clone(),
                OpenFile {
                    display_path: compact_path(&name),
                    path: name,
                    size,
                },
            );
        }
    }
    let mut connections: Vec<_> = connections.into_iter().collect();
    connections.sort();
    let mut files: Vec<_> = files.into_values().collect();
    files.sort_by(|left, right| {
        right
            .size
            .cmp(&left.size)
            .then_with(|| left.path.cmp(&right.path))
    });
    ProcessDetails {
        connections,
        files,
        note: None,
    }
}

#[cfg(target_os = "linux")]
fn inspect(pid: u32) -> ProcessDetails {
    let mut connections = Vec::new();
    if let Ok(output) = Command::new("ss").args(["-tupnH"]).output() {
        let marker = format!("pid={pid},");
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            if line.contains(&marker) {
                connections.push(line.trim().to_owned());
            }
        }
    }
    connections.sort();
    connections.dedup();

    let mut files_by_path = HashMap::new();
    let directory = PathBuf::from(format!("/proc/{pid}/fd"));
    let note = match fs::read_dir(directory) {
        Ok(entries) => {
            for entry in entries.flatten() {
                let Ok(path) = fs::read_link(entry.path()) else {
                    continue;
                };
                let value = path.to_string_lossy().into_owned();
                if !value.starts_with('/')
                    || value.starts_with("/proc/")
                    || value.starts_with("/sys/")
                {
                    continue;
                }
                let size = fs::metadata(&path).map_or(0, |metadata| metadata.len());
                files_by_path.entry(value.clone()).or_insert(OpenFile {
                    display_path: compact_path(&value),
                    path: value,
                    size,
                });
            }
            None
        }
        Err(_) => Some("Open-file details are unavailable for this process.".into()),
    };
    let mut files: Vec<_> = files_by_path.into_values().collect();
    files.sort_by(|left, right| {
        right
            .size
            .cmp(&left.size)
            .then_with(|| left.path.cmp(&right.path))
    });
    ProcessDetails {
        connections,
        files,
        note,
    }
}

fn compact_path(path: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let abbreviated =
        if !home.is_empty() && (path == home || path.starts_with(&(home.clone() + "/"))) {
            format!("~{}", &path[home.len()..])
        } else {
            path.to_owned()
        };
    if let (Some(cloudkit), Some(mmcs)) = (
        abbreviated.find("/CloudKit/com.apple.bird/"),
        abbreviated.find("/MMCS/"),
    ) {
        if mmcs > cloudkit {
            return format!(
                "~/Library/Caches/CloudKit/…/MMCS/{}",
                &abbreviated[mmcs + 6..]
            );
        }
    }
    abbreviated
}

pub fn copy_to_clipboard(value: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let candidates: &[(&str, &[&str])] = &[("/usr/bin/pbcopy", &[])];
    #[cfg(target_os = "linux")]
    let candidates: &[(&str, &[&str])] = &[
        ("wl-copy", &[]),
        ("xclip", &["-selection", "clipboard"]),
        ("xsel", &["--clipboard", "--input"]),
    ];

    for (command, arguments) in candidates {
        let Ok(mut child) = Command::new(command)
            .args(*arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        else {
            continue;
        };
        if let Some(stdin) = &mut child.stdin {
            let _ = stdin.write_all(value.as_bytes());
        }
        if child.wait().is_ok_and(|status| status.success()) {
            return Ok(());
        }
    }
    Err("No supported clipboard command is available".into())
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::parse_lsof;

    #[test]
    fn parses_connections_and_relevant_files() {
        let fixture = "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n\
            curl 42 me 3u IPv4 0x0 0t0 TCP 10.0.0.1:5000->1.1.1.1:443\n\
            curl 42 me 4r REG 1,1 120 1 /Users/me/file.txt\n";
        let details = parse_lsof(fixture);
        assert_eq!(details.connections.len(), 1);
        assert_eq!(details.files.len(), 1);
        assert_eq!(details.files[0].size, 120);
    }
}
