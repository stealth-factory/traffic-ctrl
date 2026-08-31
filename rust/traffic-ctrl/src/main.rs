mod collector;
mod filter;
mod inspector;
mod process_control;
mod resolver;

use std::collections::HashMap;
use std::env;
use std::io::{self, IsTerminal, Read, Write};
use std::os::fd::AsRawFd;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::TryRecvError;
use std::thread;
use std::time::{Duration, Instant};

use collector::RunningCollector;
use filter::{FilterController, FilterState};
use inspector::{BackgroundInspector, ProcessDetails, copy_to_clipboard};
use process_control::PauseManager;
use resolver::HostnameResolver;
use traffic_ctrl_core::{EndpointTraffic, ProcessId, ProcessTraffic, RateSample, TrafficMonitor};

const VERSION: &str = env!("CARGO_PKG_VERSION");
static TERMINATE_REQUESTED: AtomicBool = AtomicBool::new(false);

extern "C" fn request_termination(_signal: libc::c_int) {
    TERMINATE_REQUESTED.store(true, Ordering::Relaxed);
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum SortMode {
    Total,
    Live,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum DetailFocus {
    Endpoints,
    Connections,
    Files,
}

impl DetailFocus {
    fn next(self) -> Self {
        match self {
            Self::Endpoints => Self::Connections,
            Self::Connections => Self::Files,
            Self::Files => Self::Endpoints,
        }
    }
}

struct DetailView<'a> {
    process: &'a ProcessTraffic,
    history: &'a [RateSample],
    endpoints: &'a [EndpointTraffic],
    endpoint_history: &'a [RateSample],
    hostnames: &'a HashMap<String, String>,
    details: &'a ProcessDetails,
    focus: DetailFocus,
    selected_endpoint: usize,
    selected_connection: usize,
    selected_file: usize,
}

#[derive(Clone, Copy)]
struct ControlState {
    paused: bool,
    pause_seconds_remaining: Option<u64>,
    blocked: bool,
    filter_state: FilterState,
}

struct Options {
    interval: f64,
    limit: Option<usize>,
    public_only: bool,
    plain: bool,
    once: bool,
    sort: SortMode,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            interval: 1.0,
            limit: None,
            public_only: true,
            plain: false,
            once: false,
            sort: SortMode::Total,
        }
    }
}

impl Options {
    fn parse() -> Result<Self, String> {
        let mut options = Self::default();
        let mut arguments = env::args().skip(1);
        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "-i" | "--interval" => {
                    options.interval = arguments
                        .next()
                        .ok_or("--interval requires seconds")?
                        .parse()
                        .map_err(|_| "--interval requires a number")?;
                    if options.interval < 0.2 {
                        return Err("--interval must be at least 0.2 seconds".into());
                    }
                }
                "-n" | "--limit" => {
                    options.limit = Some(
                        arguments
                            .next()
                            .ok_or("--limit requires a row count")?
                            .parse()
                            .map_err(|_| "--limit requires a positive integer")?,
                    );
                }
                "--external" => options.public_only = true,
                "--all-external" => options.public_only = false,
                "--plain" => options.plain = true,
                "--once" => {
                    options.once = true;
                    options.plain = true;
                }
                "--sort" => {
                    options.sort = match arguments.next().as_deref() {
                        Some("total") => SortMode::Total,
                        Some("live") => SortMode::Live,
                        _ => return Err("--sort requires either 'total' or 'live'".into()),
                    };
                }
                "-h" | "--help" => {
                    print_help();
                    std::process::exit(0);
                }
                "-V" | "--version" => {
                    println!("traffic-ctrl {VERSION}");
                    std::process::exit(0);
                }
                _ => return Err(format!("unknown option: {argument}")),
            }
        }
        Ok(options)
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("traffic-ctrl: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    install_signal_handlers();
    let options = Options::parse()?;
    let collector = RunningCollector::start(options.interval, options.public_only)?;
    let inspector = BackgroundInspector::start()?;
    let mut resolver = HostnameResolver::start()?;
    let mut filter = FilterController::start()?;
    filter.refresh(true);
    let mut monitor = TrafficMonitor::default();
    let mut sort = options.sort;
    let mut selected = 0usize;
    let mut detail_id: Option<ProcessId> = None;
    let mut selected_endpoint = 0usize;
    let mut selected_connection = 0usize;
    let mut selected_file = 0usize;
    let mut detail_focus = DetailFocus::Endpoints;
    let mut details = ProcessDetails::default();
    let mut last_inspection = Instant::now() - Duration::from_secs(10);
    let mut pause_manager = PauseManager::new();
    let mut pending_pause: Option<(ProcessId, Instant)> = None;
    let mut pending_block: Option<(ProcessId, Instant)> = None;
    let mut started = Instant::now();
    let mut notice = Some(collector.limitations.to_owned());
    let interactive = io::stdin().is_terminal() && !options.plain;
    let _terminal = interactive.then(TerminalGuard::activate).transpose()?;
    let mut input = Vec::new();
    let mut escape_pending_since: Option<Instant> = None;
    let mut needs_render = true;
    let mut received_samples = 0usize;

    loop {
        if TERMINATE_REQUESTED.load(Ordering::Relaxed) {
            return Ok(());
        }
        let mut got_sample = false;
        loop {
            match collector.receiver.try_recv() {
                Ok(Ok(delta)) => {
                    monitor.ingest(delta, Duration::from_secs_f64(collector.sample_interval));
                    received_samples += 1;
                    got_sample = true;
                    needs_render = true;
                }
                Ok(Err(error)) => return Err(error),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    return Err("collector stopped unexpectedly".into());
                }
            }
        }

        filter.refresh(false);
        if filter.drain() {
            needs_render = true;
        }
        if resolver.drain() {
            needs_render = true;
        }
        for result in inspector.drain() {
            if detail_id.as_ref() == Some(&result.id) {
                details = result.details;
                needs_render = true;
            }
        }
        if let Some(id) = detail_id.as_ref() {
            if last_inspection.elapsed() >= Duration::from_secs(2) {
                inspector.request(id.clone());
                last_inspection = Instant::now();
            }
        }
        for (id, result) in pause_manager.resume_expired() {
            notice = Some(match result {
                Ok(()) => format!(
                    "Automatically unpaused {} (PID {}) after 30 seconds",
                    id.name, id.pid
                ),
                Err(message) => message,
            });
            needs_render = true;
        }
        if pending_pause
            .as_ref()
            .is_some_and(|(_, deadline)| Instant::now() >= *deadline)
        {
            pending_pause = None;
            notice = Some("Pause confirmation expired".into());
            needs_render = true;
        }
        if pending_block
            .as_ref()
            .is_some_and(|(_, deadline)| Instant::now() >= *deadline)
        {
            pending_block = None;
            notice = Some("Network-block confirmation expired".into());
            needs_render = true;
        }

        let mut ranked: Vec<_> = monitor.processes().cloned().collect();
        sort_processes(&mut ranked, sort);
        selected = selected.min(ranked.len().saturating_sub(1));

        let mut endpoints: Vec<_> = detail_id
            .as_ref()
            .map(|id| monitor.endpoints(id).cloned().collect())
            .unwrap_or_default();
        endpoints.sort_by(|left: &EndpointTraffic, right: &EndpointTraffic| {
            right
                .total()
                .cmp(&left.total())
                .then_with(|| right.total_rate().total_cmp(&left.total_rate()))
                .then_with(|| left.address.cmp(&right.address))
        });
        resolver.request(endpoints.iter().map(|endpoint| endpoint.address.as_str()));
        selected_endpoint = selected_endpoint.min(endpoints.len().saturating_sub(1));
        selected_connection = selected_connection.min(details.connections.len().saturating_sub(1));
        selected_file = selected_file.min(details.files.len().saturating_sub(1));

        let mut selected_after_sort = None;
        if interactive {
            read_available_input(&mut input)?;
            if input == [0x1b] {
                escape_pending_since.get_or_insert_with(Instant::now);
            } else {
                escape_pending_since = None;
            }
            let flush_escape = escape_pending_since
                .is_some_and(|started| started.elapsed() >= Duration::from_millis(25));
            for action in parse_input(&mut input, flush_escape) {
                needs_render = true;
                match action {
                    Action::Up if detail_id.is_some() => match detail_focus {
                        DetailFocus::Endpoints => {
                            selected_endpoint = selected_endpoint.saturating_sub(1)
                        }
                        DetailFocus::Connections => {
                            selected_connection = selected_connection.saturating_sub(1)
                        }
                        DetailFocus::Files => selected_file = selected_file.saturating_sub(1),
                    },
                    Action::Down if detail_id.is_some() => match detail_focus {
                        DetailFocus::Endpoints => {
                            selected_endpoint =
                                (selected_endpoint + 1).min(endpoints.len().saturating_sub(1))
                        }
                        DetailFocus::Connections => {
                            selected_connection = (selected_connection + 1)
                                .min(details.connections.len().saturating_sub(1))
                        }
                        DetailFocus::Files => {
                            selected_file =
                                (selected_file + 1).min(details.files.len().saturating_sub(1))
                        }
                    },
                    Action::Up => selected = selected.saturating_sub(1),
                    Action::Down => selected = (selected + 1).min(ranked.len().saturating_sub(1)),
                    Action::Details if detail_id.is_none() => {
                        detail_id = ranked.get(selected).map(|item| item.id.clone());
                        selected_endpoint = 0;
                        selected_connection = 0;
                        selected_file = 0;
                        detail_focus = DetailFocus::Endpoints;
                        details = ProcessDetails::default();
                        last_inspection = Instant::now() - Duration::from_secs(10);
                        notice = None;
                    }
                    Action::Back if detail_id.is_some() => {
                        detail_id = None;
                        selected_endpoint = 0;
                        selected_connection = 0;
                        selected_file = 0;
                        notice = None;
                    }
                    Action::Details | Action::Back => {}
                    Action::CycleFocus if detail_id.is_some() => {
                        detail_focus = detail_focus.next();
                        notice = None;
                    }
                    Action::FocusEndpoints if detail_id.is_some() => {
                        detail_focus = DetailFocus::Endpoints;
                        notice = None;
                    }
                    Action::FocusFiles if detail_id.is_some() => {
                        detail_focus = DetailFocus::Files;
                        notice = None;
                    }
                    Action::CycleFocus | Action::FocusEndpoints | Action::FocusFiles => {}
                    Action::Copy if detail_id.is_some() => {
                        let value = match detail_focus {
                            DetailFocus::Endpoints => {
                                endpoints.get(selected_endpoint).map(|item| {
                                    resolver
                                        .get(&item.address)
                                        .unwrap_or(&item.address)
                                        .to_owned()
                                })
                            }
                            DetailFocus::Connections => {
                                details.connections.get(selected_connection).cloned()
                            }
                            DetailFocus::Files => details
                                .files
                                .get(selected_file)
                                .map(|file| file.path.clone()),
                        };
                        notice = Some(match value {
                            Some(value) => match copy_to_clipboard(&value) {
                                Ok(()) => format!("Copied: {value}"),
                                Err(message) => message,
                            },
                            None => "Nothing selected to copy".into(),
                        });
                    }
                    Action::Copy => {}
                    Action::Pause => {
                        if let Some(target) = detail_id
                            .clone()
                            .or_else(|| ranked.get(selected).map(|item| item.id.clone()))
                        {
                            if pause_manager.is_paused(&target) {
                                notice = Some(format!(
                                    "{} (PID {}) is paused; press [u] to unpause",
                                    target.name, target.pid
                                ));
                            } else if pending_pause.as_ref().is_some_and(|(id, deadline)| {
                                id == &target && Instant::now() < *deadline
                            }) {
                                pending_pause = None;
                                notice = Some(match pause_manager.pause(target.clone()) {
                                    Ok(()) => format!(
                                        "Paused only {} (PID {}) for up to 30 seconds",
                                        target.name, target.pid
                                    ),
                                    Err(message) => message,
                                });
                            } else {
                                pending_pause =
                                    Some((target.clone(), Instant::now() + Duration::from_secs(4)));
                                notice = Some(format!(
                                    "Press [p] again within 4s to pause only {} (PID {}) for up to 30s",
                                    target.name, target.pid
                                ));
                            }
                        }
                    }
                    Action::Unpause => {
                        if let Some(target) = detail_id
                            .clone()
                            .or_else(|| ranked.get(selected).map(|item| item.id.clone()))
                        {
                            notice = Some(if pause_manager.is_paused(&target) {
                                match pause_manager.resume(&target) {
                                    Ok(()) => {
                                        format!("Unpaused {} (PID {})", target.name, target.pid)
                                    }
                                    Err(message) => message,
                                }
                            } else {
                                format!("{} (PID {}) is not paused", target.name, target.pid)
                            });
                        }
                    }
                    Action::ToggleBlock => {
                        if let Some(target) = detail_id
                            .clone()
                            .or_else(|| ranked.get(selected).map(|item| item.id.clone()))
                        {
                            if filter.snapshot().is_blocked(&target) {
                                notice =
                                    filter.set_blocked(false, target.clone()).err().or_else(|| {
                                        Some(format!(
                                            "Unblocking public-Internet traffic for {} (PID {})…",
                                            target.name, target.pid
                                        ))
                                    });
                            } else if pending_block.as_ref().is_some_and(|(id, deadline)| {
                                id == &target && Instant::now() < *deadline
                            }) {
                                pending_block = None;
                                notice =
                                    filter.set_blocked(true, target.clone()).err().or_else(|| {
                                        Some(format!(
                                            "Blocking public-Internet traffic for {} (PID {})…",
                                            target.name, target.pid
                                        ))
                                    });
                            } else if filter.snapshot().state == FilterState::Ready {
                                pending_block =
                                    Some((target.clone(), Instant::now() + Duration::from_secs(4)));
                                notice = Some(format!(
                                    "Press [b] again within 4s to block public-Internet traffic only for {} (PID {}); the process keeps running",
                                    target.name, target.pid
                                ));
                            } else {
                                notice = Some(
                                    filter
                                        .snapshot()
                                        .message
                                        .clone()
                                        .unwrap_or_else(|| "Network block unavailable".into()),
                                );
                            }
                        }
                    }
                    Action::Sort => {
                        selected_after_sort = ranked.get(selected).map(|item| item.id.clone());
                        sort = if sort == SortMode::Total {
                            SortMode::Live
                        } else {
                            SortMode::Total
                        };
                        notice = None;
                    }
                    Action::Reset => {
                        monitor.reset();
                        started = Instant::now();
                        selected = 0;
                        detail_id = None;
                        selected_endpoint = 0;
                        selected_connection = 0;
                        selected_file = 0;
                        pause_manager.resume_all();
                        pending_pause = None;
                        pending_block = None;
                        notice = Some("Statistics reset".into());
                    }
                    Action::Quit => {
                        if interactive {
                            print!("\x1b[2J\x1b[H");
                            let _ = io::stdout().flush();
                        }
                        return Ok(());
                    }
                }
            }
        }

        // Rebuild view models after input so sort, reset and detail entry are
        // reflected on the same 20 ms input tick instead of the next sample.
        if needs_render {
            ranked = monitor.processes().cloned().collect();
            sort_processes(&mut ranked, sort);
            if let Some(id) = selected_after_sort {
                selected = ranked
                    .iter()
                    .position(|item| item.id == id)
                    .unwrap_or(selected);
            }
            selected = selected.min(ranked.len().saturating_sub(1));

            endpoints = detail_id
                .as_ref()
                .map(|id| monitor.endpoints(id).cloned().collect())
                .unwrap_or_default();
            endpoints.sort_by(|left: &EndpointTraffic, right: &EndpointTraffic| {
                right
                    .total()
                    .cmp(&left.total())
                    .then_with(|| right.total_rate().total_cmp(&left.total_rate()))
                    .then_with(|| left.address.cmp(&right.address))
            });
            resolver.request(endpoints.iter().map(|endpoint| endpoint.address.as_str()));
            selected_endpoint = selected_endpoint.min(endpoints.len().saturating_sub(1));
        }

        if needs_render && (!options.once || received_samples >= 1) {
            let detail_process = detail_id
                .as_ref()
                .and_then(|id| monitor.process(id))
                .cloned();
            let detail_history = detail_id
                .as_ref()
                .map(|id| monitor.process_history(id).to_vec())
                .unwrap_or_default();
            let endpoint_history = detail_id
                .as_ref()
                .zip(endpoints.get(selected_endpoint))
                .map(|(id, endpoint)| monitor.endpoint_history(id, &endpoint.address).to_vec())
                .unwrap_or_default();
            let hostnames: HashMap<_, _> = endpoints
                .iter()
                .filter_map(|endpoint| {
                    resolver
                        .get(&endpoint.address)
                        .map(|hostname| (endpoint.address.clone(), hostname.to_owned()))
                })
                .collect();
            let detail_view = detail_process.as_ref().map(|process| DetailView {
                process,
                history: &detail_history,
                endpoints: &endpoints,
                endpoint_history: &endpoint_history,
                hostnames: &hostnames,
                details: &details,
                focus: detail_focus,
                selected_endpoint,
                selected_connection,
                selected_file,
            });
            let control_target = detail_id
                .as_ref()
                .or_else(|| ranked.get(selected).map(|item| &item.id));
            let controls = ControlState {
                paused: control_target.is_some_and(|id| pause_manager.is_paused(id)),
                pause_seconds_remaining: control_target
                    .and_then(|id| pause_manager.seconds_remaining(id)),
                blocked: control_target.is_some_and(|id| filter.snapshot().is_blocked(id)),
                filter_state: filter.snapshot().state,
            };
            render(
                &ranked,
                monitor.aggregate_history(),
                detail_view,
                selected,
                sort,
                started.elapsed(),
                collector.name,
                collector.sample_interval,
                notice.as_deref(),
                options.limit,
                options.public_only,
                interactive,
                controls,
            )?;
            needs_render = false;
        }

        if options.once && got_sample && received_samples >= 1 {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(20));
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Action {
    Up,
    Down,
    Details,
    Back,
    CycleFocus,
    FocusEndpoints,
    FocusFiles,
    Copy,
    ToggleBlock,
    Pause,
    Unpause,
    Sort,
    Reset,
    Quit,
}

fn parse_input(bytes: &mut Vec<u8>, flush_escape: bool) -> Vec<Action> {
    let mut actions = Vec::new();
    while !bytes.is_empty() {
        if bytes[0] == 0x1b {
            if bytes.len() < 3 {
                if flush_escape {
                    actions.push(Action::Back);
                    bytes.remove(0);
                    continue;
                }
                break;
            }
            if bytes[1] == b'[' || bytes[1] == b'O' {
                match bytes[2] {
                    b'A' => actions.push(Action::Up),
                    b'B' => actions.push(Action::Down),
                    b'C' => actions.push(Action::Details),
                    b'D' => actions.push(Action::Back),
                    _ => {}
                }
                bytes.drain(..3);
            } else {
                bytes.remove(0);
            }
            continue;
        }
        match bytes.remove(0).to_ascii_lowercase() {
            b'k' => actions.push(Action::Up),
            b'j' => actions.push(Action::Down),
            b'\r' | b'\n' => actions.push(Action::Details),
            b'\t' => actions.push(Action::CycleFocus),
            0x7f => actions.push(Action::Back),
            b'e' => actions.push(Action::FocusEndpoints),
            b'f' => actions.push(Action::FocusFiles),
            b'c' => actions.push(Action::Copy),
            b'b' => actions.push(Action::ToggleBlock),
            b'p' => actions.push(Action::Pause),
            b'u' => actions.push(Action::Unpause),
            b's' | b't' => actions.push(Action::Sort),
            b'r' => actions.push(Action::Reset),
            b'q' => actions.push(Action::Quit),
            _ => {}
        }
    }
    actions
}

fn read_available_input(bytes: &mut Vec<u8>) -> Result<(), String> {
    let fd = io::stdin().as_raw_fd();
    let mut poll_fd = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    let ready = unsafe { libc::poll(&mut poll_fd, 1, 0) };
    if ready < 0 {
        return Err(format!(
            "terminal input failed: {}",
            io::Error::last_os_error()
        ));
    }
    if ready > 0 && poll_fd.revents & libc::POLLIN != 0 {
        let mut buffer = [0u8; 64];
        let count = io::stdin()
            .read(&mut buffer)
            .map_err(|error| error.to_string())?;
        bytes.extend_from_slice(&buffer[..count]);
    }
    Ok(())
}

fn sort_processes(values: &mut Vec<ProcessTraffic>, sort: SortMode) {
    values.retain(|item| item.total() > 0 || item.total_rate() > 0.0);
    values.sort_by(|left, right| {
        let ordering = match sort {
            SortMode::Total => right.total().cmp(&left.total()),
            SortMode::Live => right.total_rate().total_cmp(&left.total_rate()),
        };
        ordering
            .then_with(|| right.total().cmp(&left.total()))
            .then_with(|| left.id.cmp(&right.id))
    });
}

#[allow(clippy::too_many_arguments)]
fn render(
    ranked: &[ProcessTraffic],
    history: &[RateSample],
    detail: Option<DetailView<'_>>,
    selected: usize,
    sort: SortMode,
    elapsed: Duration,
    collector: &str,
    sample_interval: f64,
    notice: Option<&str>,
    configured_limit: Option<usize>,
    public_only: bool,
    interactive: bool,
    controls: ControlState,
) -> Result<(), String> {
    let (width, height) = terminal_size();
    // Keep the last terminal column unused to avoid right-margin auto-wrap.
    let width = width.saturating_sub(1).max(40);
    let active_history = detail.as_ref().map_or(history, |detail| detail.history);
    let chart = chart_lines(active_history, width, chart_height(height), interactive);
    let notice_rows = usize::from(notice.is_some()) * 2;
    let reserved_rows = chart.len() + notice_rows + 7;
    let available_rows = height.saturating_sub(reserved_rows).max(1);
    let row_limit = configured_limit.map_or(available_rows, |limit| limit.min(available_rows));
    let latest = active_history.last().copied().unwrap_or_default();
    let mut output = String::new();
    if interactive {
        output.push_str("\x1b[?25l\x1b[H\x1b[2J");
    }
    let scope = if !public_only && cfg!(target_os = "linux") {
        "all remote endpoints · TCP preview"
    } else if !public_only {
        "all external endpoints"
    } else if cfg!(target_os = "linux") {
        "public internet · TCP preview"
    } else {
        "public internet"
    };
    output.push_str(&truncate(
        &format!(
            "Traffic Ctrl v{VERSION}  {scope}  {}  sort: {}",
            duration(elapsed),
            if sort == SortMode::Total {
                "total data"
            } else {
                "live bandwidth"
            }
        ),
        width,
    ));
    output.push('\n');
    output.push_str(&truncate(&format!("Collector: {collector}"), width));
    output.push('\n');
    let window =
        Duration::from_secs_f64(active_history.len().saturating_sub(1) as f64 * sample_interval);
    let chart_title = detail
        .as_ref()
        .map_or("All processes", |detail| detail.process.id.name.as_str());
    output.push('\n');
    output.push_str(&truncate(
        &format!(
            "Traffic — {chart_title}   RX ↑ {}   TX ↓ {}   last {}",
            rate(latest.received),
            rate(latest.sent),
            short_duration(window),
        ),
        width,
    ));
    output.push('\n');
    for line in chart {
        output.push_str(&line);
        output.push('\n');
    }
    if let Some(detail) = &detail {
        let process = detail.process;
        output.push_str(&truncate(
            &format!(
                "Process: {}  PID {}  total {}  rate {}",
                process.id.name,
                process.id.pid,
                bytes(process.total()),
                rate(process.total_rate())
            ),
            width,
        ));
        output.push('\n');
        if let Some(seconds) = controls.pause_seconds_remaining {
            output.push_str(&truncate(
                &format!("STATUS: PAUSED — all activity stopped (auto-unpause in {seconds}s)"),
                width,
            ));
            output.push('\n');
        } else if controls.blocked {
            output.push_str(&truncate(
                "STATUS: PUBLIC-INTERNET TRAFFIC BLOCKED — process is still running",
                width,
            ));
            output.push('\n');
        }
        output.push_str(&section_heading(
            detail.focus == DetailFocus::Endpoints,
            "Remote endpoints",
            width,
        ));
        output.push('\n');
        output.push_str(&endpoint_header(width));
        output.push('\n');
        output.push_str(&"─".repeat(width));
        output.push('\n');
        let adaptive_endpoint_limit = match height {
            0..=30 => 2,
            31..=42 => 3,
            _ => 5,
        };
        let endpoint_limit = configured_limit.map_or(adaptive_endpoint_limit, |limit| {
            limit.min(adaptive_endpoint_limit)
        });
        let start = if detail.selected_endpoint < endpoint_limit {
            0
        } else {
            detail.selected_endpoint + 1 - endpoint_limit
        };
        for (offset, endpoint) in detail
            .endpoints
            .iter()
            .skip(start)
            .take(endpoint_limit)
            .enumerate()
        {
            let index = start + offset;
            output.push_str(&endpoint_row(
                endpoint,
                index,
                detail.hostnames.get(&endpoint.address).map(String::as_str),
                detail.focus == DetailFocus::Endpoints && index == detail.selected_endpoint,
                width,
            ));
            output.push('\n');
            if detail.focus == DetailFocus::Endpoints && index == detail.selected_endpoint {
                for line in compact_endpoint_chart(detail.endpoint_history, width, interactive) {
                    output.push_str(&line);
                    output.push('\n');
                }
            }
        }
        if detail.endpoints.is_empty() {
            output.push_str("No public-Internet endpoints recorded for this process.\n");
        }
        let inspection_limit = if height < 36 { 2 } else { 4 };
        render_inspection_sections(&mut output, detail, width, inspection_limit);
    } else {
        output.push_str(&table_header(width));
        output.push('\n');
        output.push_str(&"─".repeat(width));
        output.push('\n');
        let start = if selected < row_limit {
            0
        } else {
            selected + 1 - row_limit
        };
        for (offset, item) in ranked.iter().skip(start).take(row_limit).enumerate() {
            let index = start + offset;
            output.push_str(&table_row(item, index, index == selected, width));
            output.push('\n');
        }
        if ranked.is_empty() {
            output.push_str("Waiting for attributed public-Internet traffic…\n");
        }
    }
    if let Some(notice) = notice {
        output.push('\n');
        output.push_str(&truncate(notice, width));
        output.push('\n');
    }
    if interactive {
        let body_rows = height.saturating_sub(1);
        let lines: Vec<_> = output.lines().take(body_rows).map(str::to_owned).collect();
        output = lines.join("\n");
        output.push('\n');
        for _ in lines.len()..body_rows {
            output.push('\n');
        }
    }
    if detail.is_some() {
        output.push_str(&detail_footer(controls, width));
    } else {
        output.push_str(&list_footer(controls, width));
    }
    output.push_str("\x1b[K");
    print!("{output}");
    io::stdout().flush().map_err(|error| error.to_string())
}

fn table_header(width: usize) -> String {
    if width < 58 {
        let name_width = width.saturating_sub(31).max(8);
        return format!(
            "#   {:name_width$}  {:>7}  {:>7}  {:>7}",
            "PROCESS", "PID", "DOWN", "UP"
        );
    }
    let name_width = width.saturating_sub(51).max(12);
    format!(
        "#   {:name_width$}  {:>7}  {:>10}  {:>10}  {:>10}",
        "PROCESS", "PID", "TOTAL", "DOWN", "UP"
    )
}

fn table_row(item: &ProcessTraffic, index: usize, selected: bool, width: usize) -> String {
    if width < 58 {
        let name_width = width.saturating_sub(31).max(8);
        let marker = if selected { '›' } else { ' ' };
        return format!(
            "{marker}{:<2} {:name_width$}  {:>7}  {:>7}  {:>7}",
            index + 1,
            truncate(&item.id.name, name_width),
            item.id.pid,
            short_rate(item.receive_rate),
            short_rate(item.send_rate),
        );
    }
    let name_width = width.saturating_sub(51).max(12);
    let marker = if selected { '›' } else { ' ' };
    format!(
        "{marker}{:<2} {:name_width$}  {:>7}  {:>10}  {:>10}  {:>10}",
        index + 1,
        truncate(&item.id.name, name_width),
        item.id.pid,
        bytes(item.total()),
        rate(item.receive_rate),
        rate(item.send_rate),
    )
}

fn endpoint_header(width: usize) -> String {
    if width < 58 {
        let address_width = width.saturating_sub(31).max(8);
        return format!(
            "#   {:address_width$}  {:>7}  {:>7}  {:>7}",
            "REMOTE", "TOTAL", "DOWN", "UP"
        );
    }
    let address_width = width.saturating_sub(40).max(18);
    format!(
        "#   {:address_width$}  {:>10}  {:>10}  {:>10}",
        "REMOTE ENDPOINT", "TOTAL", "DOWN", "UP"
    )
}

fn endpoint_row(
    endpoint: &EndpointTraffic,
    index: usize,
    hostname: Option<&str>,
    selected: bool,
    width: usize,
) -> String {
    if width < 58 {
        let address_width = width.saturating_sub(31).max(8);
        let marker = if selected { '›' } else { ' ' };
        let label = hostname.unwrap_or(&endpoint.address);
        return format!(
            "{marker}{:<2} {:address_width$}  {:>7}  {:>7}  {:>7}",
            index + 1,
            truncate(label, address_width),
            short_quantity(endpoint.total() as f64),
            short_rate(endpoint.receive_rate),
            short_rate(endpoint.send_rate),
        );
    }
    let address_width = width.saturating_sub(40).max(18);
    let marker = if selected { '›' } else { ' ' };
    let label = hostname.map_or_else(
        || endpoint.address.clone(),
        |hostname| {
            if hostname == endpoint.address {
                hostname.to_owned()
            } else {
                format!("{hostname} ({})", endpoint.address)
            }
        },
    );
    format!(
        "{marker}{:<2} {:address_width$}  {:>10}  {:>10}  {:>10}",
        index + 1,
        truncate(&label, address_width),
        bytes(endpoint.total()),
        rate(endpoint.receive_rate),
        rate(endpoint.send_rate),
    )
}

fn compact_endpoint_chart(
    history: &[RateSample],
    width: usize,
    colour_enabled: bool,
) -> Vec<String> {
    chart_lines(history, width, 4, colour_enabled)
}

fn render_inspection_sections(
    output: &mut String,
    detail: &DetailView<'_>,
    width: usize,
    limit: usize,
) {
    output.push('\n');
    output.push_str(&section_heading(
        detail.focus == DetailFocus::Connections,
        "Network connections (current snapshot)",
        width,
    ));
    output.push('\n');
    if detail.details.connections.is_empty() {
        output.push_str("  No active sockets visible.\n");
    } else {
        let start = detail
            .selected_connection
            .saturating_sub(limit.saturating_sub(1));
        for (offset, connection) in detail
            .details
            .connections
            .iter()
            .skip(start)
            .take(limit)
            .enumerate()
        {
            let index = start + offset;
            let marker = if detail.focus == DetailFocus::Connections
                && index == detail.selected_connection
            {
                '›'
            } else {
                ' '
            };
            output.push_str(&format!(
                "{marker}{:<2} {}\n",
                index + 1,
                truncate(connection, width.saturating_sub(4))
            ));
        }
    }

    output.push('\n');
    output.push_str(&section_heading(
        detail.focus == DetailFocus::Files,
        "Relevant open files (correlation only; not proof of transfer)",
        width,
    ));
    output.push('\n');
    if detail.details.files.is_empty() {
        output.push_str("  No relevant regular files visible.\n");
    } else {
        let start = detail.selected_file.saturating_sub(limit.saturating_sub(1));
        for (offset, file) in detail
            .details
            .files
            .iter()
            .skip(start)
            .take(limit)
            .enumerate()
        {
            let index = start + offset;
            let marker = if detail.focus == DetailFocus::Files && index == detail.selected_file {
                '›'
            } else {
                ' '
            };
            let size = bytes(file.size);
            let available = width.saturating_sub(16);
            output.push_str(&format!(
                "{marker}{:<2} {:>10}  {}\n",
                index + 1,
                size,
                truncate(&file.display_path, available)
            ));
        }
    }
    if let Some(note) = &detail.details.note {
        output.push_str(&format!("{}\n", truncate(note, width)));
    }
}

fn section_heading(focused: bool, title: &str, width: usize) -> String {
    format!(
        "{} {}",
        if focused { '›' } else { ' ' },
        truncate(title, width.saturating_sub(2))
    )
}

fn network_control(controls: ControlState) -> &'static str {
    if controls.blocked {
        "[b]unblock"
    } else if controls.filter_state == FilterState::Ready {
        "[b]lock"
    } else {
        "[b]lock×"
    }
}

fn process_control(controls: ControlState) -> &'static str {
    if controls.paused {
        "[u]npause"
    } else {
        "[p]ause"
    }
}

fn list_footer(controls: ControlState, width: usize) -> String {
    let full = format!(
        "[↑/↓] select  [enter/→] details  {}  {}  [s]ort  [r]eset  [q]uit",
        network_control(controls),
        process_control(controls)
    );
    if full.chars().count() <= width {
        full
    } else {
        truncate(
            &format!(
                "[↑/↓] [enter/→] {} {} [s]ort [r]eset [q]uit",
                network_control(controls),
                process_control(controls)
            ),
            width,
        )
    }
}

fn detail_footer(controls: ControlState, width: usize) -> String {
    let full = format!(
        "[↑/↓] scroll  [tab] section  [c]opy  [esc/←] back  {}  {}  [r]eset  [q]uit",
        network_control(controls),
        process_control(controls)
    );
    if full.chars().count() <= width {
        full
    } else {
        truncate(
            &format!(
                "[↑/↓] [tab] [c]opy [esc/←] {} {} [r]eset [q]uit",
                network_control(controls),
                process_control(controls)
            ),
            width,
        )
    }
}

fn chart_height(terminal_rows: usize) -> usize {
    if terminal_rows < 24 {
        4
    } else if terminal_rows < 38 {
        5
    } else {
        6
    }
}

fn chart_lines(
    history: &[RateSample],
    width: usize,
    height: usize,
    colour_enabled: bool,
) -> Vec<String> {
    let label_width = 10;
    let plot_width = width.saturating_sub(label_width + 3).max(12);
    let pixel_width = plot_width * 2;
    let visible: Vec<_> = history
        .iter()
        .rev()
        .take(pixel_width)
        .copied()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    let upper_height = (height / 2).max(2);
    let lower_height = (height - upper_height).max(2);
    let rx_peak = visible
        .iter()
        .map(|sample| sample.received)
        .fold(1.0_f64, f64::max);
    let tx_peak = visible
        .iter()
        .map(|sample| sample.sent)
        .fold(1.0_f64, f64::max);
    let mut rx = vec![vec![0u8; plot_width]; upper_height];
    let mut tx = vec![vec![0u8; plot_width]; lower_height];
    draw_braille_line(
        &visible
            .iter()
            .map(|sample| sample.received)
            .collect::<Vec<_>>(),
        rx_peak,
        pixel_width,
        upper_height * 4,
        false,
        &mut rx,
    );
    draw_braille_line(
        &visible.iter().map(|sample| sample.sent).collect::<Vec<_>>(),
        tx_peak,
        pixel_width,
        lower_height * 4,
        true,
        &mut tx,
    );

    let empty_label = " ".repeat(label_width);
    let mut result = vec![format!(
        "{:>label_width$} ┌{}┐",
        rate(rx_peak),
        "─".repeat(plot_width)
    )];
    for row in rx {
        result.push(format!(
            "{empty_label} │{}│",
            braille_row(&row, 36, colour_enabled)
        ));
    }
    result.push(format!(
        "{:>label_width$} ├{}┤",
        "0 B/s",
        "─".repeat(plot_width)
    ));
    for row in tx {
        result.push(format!(
            "{empty_label} │{}│",
            braille_row(&row, 35, colour_enabled)
        ));
    }
    result.push(format!(
        "{:>label_width$} └{}┘",
        format!("−{}", rate(tx_peak)),
        "─".repeat(plot_width)
    ));
    result
}

fn draw_braille_line(
    values: &[f64],
    peak: f64,
    pixel_width: usize,
    pixel_height: usize,
    inverted: bool,
    canvas: &mut [Vec<u8>],
) {
    if values.is_empty() {
        return;
    }
    let point = |index: usize| {
        let x = if values.len() == 1 {
            pixel_width - 1
        } else {
            ((index as f64 * (pixel_width - 1) as f64 / (values.len() - 1) as f64).round()) as usize
        };
        let scaled = (values[index] / peak).clamp(0.0, 1.0);
        let magnitude = (scaled * (pixel_height - 1) as f64).round() as usize;
        let y = if inverted {
            magnitude
        } else {
            pixel_height - 1 - magnitude
        };
        (x, y)
    };
    if values.len() == 1 {
        if values[0] > 0.0 {
            set_braille_dot(point(0), canvas);
        }
        return;
    }
    for index in 1..values.len() {
        if values[index - 1] == 0.0 && values[index] == 0.0 {
            continue;
        }
        draw_segment(point(index - 1), point(index), canvas);
    }
}

fn draw_segment(start: (usize, usize), end: (usize, usize), canvas: &mut [Vec<u8>]) {
    let (mut x, mut y) = (start.0 as isize, start.1 as isize);
    let (end_x, end_y) = (end.0 as isize, end.1 as isize);
    let dx = (end_x - x).abs();
    let step_x = if x < end_x { 1 } else { -1 };
    let dy = -(end_y - y).abs();
    let step_y = if y < end_y { 1 } else { -1 };
    let mut error = dx + dy;
    loop {
        set_braille_dot((x as usize, y as usize), canvas);
        if x == end_x && y == end_y {
            break;
        }
        let doubled = error * 2;
        if doubled >= dy {
            error += dy;
            x += step_x;
        }
        if doubled <= dx {
            error += dx;
            y += step_y;
        }
    }
}

fn set_braille_dot(point: (usize, usize), canvas: &mut [Vec<u8>]) {
    const BITS: [[u8; 2]; 4] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]];
    let row = point.1 / 4;
    let column = point.0 / 2;
    if row < canvas.len() && column < canvas.first().map_or(0, Vec::len) {
        canvas[row][column] |= BITS[point.1 % 4][point.0 % 2];
    }
}

fn braille_row(masks: &[u8], colour_code: u8, colour_enabled: bool) -> String {
    let row: String = masks
        .iter()
        .map(|mask| {
            if *mask == 0 {
                ' '
            } else {
                char::from_u32(0x2800 + u32::from(*mask)).unwrap_or(' ')
            }
        })
        .collect();
    if colour_enabled {
        format!("\x1b[{colour_code}m{row}\x1b[0m")
    } else {
        row
    }
}

fn bytes(value: u64) -> String {
    quantity(value as f64, false)
}

fn rate(value: f64) -> String {
    format!("{}/s", quantity(value, true))
}

fn short_rate(value: f64) -> String {
    format!("{}/s", short_quantity(value))
}

fn short_quantity(value: f64) -> String {
    let units = ["B", "K", "M", "G", "T"];
    let mut scaled = value;
    let mut unit = 0;
    while scaled >= 1024.0 && unit < units.len() - 1 {
        scaled /= 1024.0;
        unit += 1;
    }
    if scaled >= 100.0 || unit == 0 {
        format!("{scaled:.0}{}", units[unit])
    } else if scaled >= 10.0 {
        format!("{scaled:.1}{}", units[unit])
    } else {
        format!("{scaled:.2}{}", units[unit])
    }
}

fn quantity(value: f64, compact: bool) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"];
    let mut scaled = value;
    let mut unit = 0;
    while scaled >= 1024.0 && unit < units.len() - 1 {
        scaled /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{scaled:.0} {}", units[unit])
    } else if compact || scaled >= 100.0 {
        format!("{scaled:.1} {}", units[unit])
    } else {
        format!("{scaled:.2} {}", units[unit])
    }
}

fn duration(value: Duration) -> String {
    let seconds = value.as_secs();
    format!(
        "{:02}:{:02}:{:02}",
        seconds / 3600,
        (seconds / 60) % 60,
        seconds % 60
    )
}

fn short_duration(value: Duration) -> String {
    let seconds = value.as_secs();
    if seconds < 60 {
        format!("{seconds}s")
    } else {
        format!("{}m {}s", seconds / 60, seconds % 60)
    }
}

fn truncate(value: &str, width: usize) -> String {
    if value.chars().count() <= width {
        return value.to_owned();
    }
    value
        .chars()
        .take(width.saturating_sub(1))
        .collect::<String>()
        + "…"
}

fn terminal_size() -> (usize, usize) {
    let mut size = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let result = unsafe { libc::ioctl(io::stdout().as_raw_fd(), libc::TIOCGWINSZ, &mut size) };
    if result == 0 && size.ws_col > 0 && size.ws_row > 0 {
        (size.ws_col as usize, size.ws_row as usize)
    } else {
        (100, 30)
    }
}

fn install_signal_handlers() {
    unsafe {
        let handler = request_termination as *const () as libc::sighandler_t;
        libc::signal(libc::SIGINT, handler);
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGHUP, handler);
        libc::signal(libc::SIGQUIT, handler);
    }
}

struct TerminalGuard {
    original: libc::termios,
}

impl TerminalGuard {
    fn activate() -> Result<Self, String> {
        let fd = io::stdin().as_raw_fd();
        let mut original = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(fd, &mut original) } != 0 {
            return Err(format!(
                "could not read terminal settings: {}",
                io::Error::last_os_error()
            ));
        }
        let mut immediate = original;
        immediate.c_lflag &= !(libc::ICANON | libc::ECHO);
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &immediate) } != 0 {
            return Err(format!(
                "could not configure terminal: {}",
                io::Error::last_os_error()
            ));
        }
        Ok(Self { original })
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(io::stdin().as_raw_fd(), libc::TCSANOW, &self.original);
        }
        println!("\x1b[?25h\x1b[0m");
        let _ = io::stdout().flush();
    }
}

fn print_help() {
    println!(
        "Traffic Ctrl\n\n\
         Usage: traffic-ctrl [options]\n\n\
           -i, --interval SECONDS  Sampling interval (default: 1, minimum: 0.2)\n\
           -n, --limit COUNT       Maximum process rows\n\
               --external          Public Internet only (default)\n\
               --all-external      Include other external traffic\n\
               --sort MODE         total or live\n\
               --plain             Do not clear the terminal\n\
               --once              Print the first interval and exit\n\
           -h, --help              Show this help\n\
           -V, --version           Show the version"
    );
}

#[cfg(test)]
mod tests {
    use super::{Action, endpoint_header, parse_input, table_header, truncate};

    #[test]
    fn parses_rapid_repeated_navigation_without_waiting_for_a_sample() {
        let mut input = b"\x1b[B\x1b[B\x1b[A\r\tcsrq".to_vec();
        let actions = parse_input(&mut input, false);
        assert_eq!(
            actions,
            [
                Action::Down,
                Action::Down,
                Action::Up,
                Action::Details,
                Action::CycleFocus,
                Action::Copy,
                Action::Sort,
                Action::Reset,
                Action::Quit,
            ]
        );
        assert!(input.is_empty());
    }

    #[test]
    fn distinguishes_right_and_left_navigation() {
        let mut input = b"\x1b[C\x1b[D".to_vec();
        assert_eq!(
            parse_input(&mut input, false),
            [Action::Details, Action::Back]
        );
    }

    #[test]
    fn responsive_header_fits_narrow_terminals() {
        assert!(table_header(40).chars().count() <= 40);
        assert!(table_header(80).chars().count() <= 80);
        assert!(endpoint_header(40).chars().count() <= 40);
        assert!(endpoint_header(120).chars().count() <= 120);
        assert_eq!(truncate("abcdefgh", 5), "abcd…");
    }
}
