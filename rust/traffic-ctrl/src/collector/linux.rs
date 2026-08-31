use std::collections::HashMap;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use traffic_ctrl_core::{
    NetworkCounters, ProcessId, TrafficCollector, TrafficDelta, is_public_address,
};

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct SocketId {
    process: ProcessId,
    local: String,
    remote: String,
}

pub struct SocketCollector {
    interval: Duration,
    next_sample: Instant,
    previous: HashMap<SocketId, NetworkCounters>,
    public_only: bool,
    has_baseline: bool,
}

impl SocketCollector {
    pub fn new(interval_seconds: f64, public_only: bool) -> Result<Self, String> {
        let available = Command::new("ss")
            .arg("--version")
            .output()
            .map_err(|_| "Linux preview requires `ss` from iproute2".to_owned())?;
        if !available.status.success() {
            return Err("Linux `ss` command is installed but unavailable".into());
        }
        Ok(Self {
            interval: Duration::from_secs_f64(interval_seconds),
            next_sample: Instant::now(),
            previous: HashMap::new(),
            public_only,
            has_baseline: false,
        })
    }

    fn sample(&self) -> Result<HashMap<SocketId, NetworkCounters>, String> {
        let output = Command::new("ss")
            .args(["-tniHpO"])
            .output()
            .map_err(|error| format!("could not run Linux socket collector: {error}"))?;
        if !output.status.success() {
            return Err(format!(
                "Linux socket collector failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        Ok(parse_ss(
            &String::from_utf8_lossy(&output.stdout),
            self.public_only,
        ))
    }
}

impl TrafficCollector for SocketCollector {
    fn name(&self) -> &'static str {
        "Linux ss TCP preview"
    }

    fn limitations(&self) -> &'static str {
        "Linux preview counts attributed TCP sockets only; UDP and block/unblock require eBPF"
    }

    fn next_delta(&mut self) -> Result<TrafficDelta, String> {
        let now = Instant::now();
        if now < self.next_sample {
            thread::sleep(self.next_sample - now);
        }
        self.next_sample = Instant::now() + self.interval;
        let current = self.sample()?;
        if !self.has_baseline {
            self.has_baseline = true;
            self.previous = current;
            return self.next_delta();
        }

        let mut delta = TrafficDelta::default();
        for (socket, counters) in &current {
            let Some(previous) = self.previous.get(socket) else {
                continue;
            };
            let received = counters.received.saturating_sub(previous.received);
            let sent = counters.sent.saturating_sub(previous.sent);
            if received > 0 || sent > 0 {
                delta.add(
                    socket.process.clone(),
                    Some(&socket.remote),
                    NetworkCounters { received, sent },
                );
            }
        }
        self.previous = current;
        Ok(delta)
    }
}

fn parse_ss(output: &str, public_only: bool) -> HashMap<SocketId, NetworkCounters> {
    let mut result = HashMap::new();
    for line in output.lines() {
        let Some((name, pid)) = parse_process(line) else {
            continue;
        };
        let Some((local, remote)) = parse_endpoints(line) else {
            continue;
        };
        let remote_address = endpoint_address(&remote);
        if public_only && !is_public_address(&remote_address) {
            continue;
        }
        let sent = token_number(line, "bytes_sent:")
            .or_else(|| token_number(line, "bytes_acked:"))
            .unwrap_or(0);
        let received = token_number(line, "bytes_received:").unwrap_or(0);
        result.insert(
            SocketId {
                process: ProcessId::new(name, pid),
                local,
                remote: remote_address,
            },
            NetworkCounters { received, sent },
        );
    }
    result
}

fn parse_process(line: &str) -> Option<(String, u32)> {
    let users = line.split("users:((\"").nth(1)?;
    let (name, rest) = users.split_once("\"")?;
    let pid = rest
        .split("pid=")
        .nth(1)?
        .split(|character: char| !character.is_ascii_digit())
        .next()?;
    Some((name.to_owned(), pid.parse().ok()?))
}

fn parse_endpoints(line: &str) -> Option<(String, String)> {
    let before_users = line.split("users:(").next()?;
    let tokens: Vec<_> = before_users.split_whitespace().collect();
    if tokens.len() < 2 {
        return None;
    }
    Some((
        tokens[tokens.len() - 2].to_owned(),
        tokens[tokens.len() - 1].to_owned(),
    ))
}

fn endpoint_address(endpoint: &str) -> String {
    if let Some(rest) = endpoint.strip_prefix('[') {
        return rest.split(']').next().unwrap_or(rest).to_owned();
    }
    endpoint
        .rsplit_once(':')
        .map_or(endpoint, |value| value.0)
        .to_owned()
}

fn token_number(line: &str, token: &str) -> Option<u64> {
    line.split(token)
        .nth(1)?
        .split(|character: char| !character.is_ascii_digit())
        .next()?
        .parse()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::parse_ss;

    #[test]
    fn parses_attributed_public_tcp_socket() {
        let output = r#"ESTAB 0 0 10.0.0.2:50000 1.1.1.1:443 users:(("curl",pid=42,fd=3)) cubic bytes_sent:140 bytes_received:900"#;
        let sockets = parse_ss(output, true);
        let (id, counters) = sockets.iter().next().unwrap();
        assert_eq!(id.process.name, "curl");
        assert_eq!(id.process.pid, 42);
        assert_eq!(id.remote, "1.1.1.1");
        assert_eq!(counters.sent, 140);
        assert_eq!(counters.received, 900);
    }
}
