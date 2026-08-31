use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::os::fd::FromRawFd;
use std::process::{Child, Command, Stdio};

use traffic_ctrl_core::{
    NetworkCounters, ProcessId, TrafficCollector, TrafficDelta, is_public_address,
};

pub struct NettopCollector {
    child: Child,
    lines: BufReader<File>,
    current_sample: Option<Vec<String>>,
    discarded_initial_sample: bool,
    public_only: bool,
}

impl NettopCollector {
    pub fn new(interval_seconds: f64, public_only: bool) -> Result<Self, String> {
        let mut master = -1;
        let mut slave = -1;
        let result = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if result != 0 {
            return Err(format!(
                "could not create nettop PTY: {}",
                std::io::Error::last_os_error()
            ));
        }

        let reader = unsafe { File::from_raw_fd(master) };
        let writer = unsafe { File::from_raw_fd(slave) };
        let child = Command::new("/usr/bin/nettop")
            .args([
                "-L",
                "0",
                "-d",
                "-x",
                "-n",
                "-s",
                &interval_seconds.to_string(),
                "-t",
                "external",
                "-J",
                "bytes_in,bytes_out",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::from(writer))
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("could not start nettop: {error}"))?;

        Ok(Self {
            child,
            lines: BufReader::new(reader),
            current_sample: None,
            discarded_initial_sample: false,
            public_only,
        })
    }

    fn next_sample(&mut self) -> Result<Vec<String>, String> {
        loop {
            let mut line = String::new();
            let count = self
                .lines
                .read_line(&mut line)
                .map_err(|error| format!("could not read nettop output: {error}"))?;
            if count == 0 {
                let status = self.child.wait().map_err(|error| error.to_string())?;
                let mut message = String::new();
                if let Some(stderr) = &mut self.child.stderr {
                    let _ = stderr.read_to_string(&mut message);
                }
                let message = message.trim();
                return Err(if message.is_empty() {
                    format!("nettop stopped unexpectedly ({status})")
                } else {
                    format!("nettop stopped unexpectedly ({status}): {message}")
                });
            }
            let line = line.trim_end_matches(['\r', '\n']).to_owned();
            if line.starts_with(",bytes_in,bytes_out") {
                let complete = self.current_sample.replace(Vec::new());
                if let Some(complete) = complete {
                    return Ok(complete);
                }
            } else if let Some(sample) = &mut self.current_sample {
                sample.push(line);
            }
        }
    }

    pub(crate) fn parse_sample(lines: &[String], public_only: bool) -> TrafficDelta {
        let mut delta = TrafficDelta::default();
        let mut current_process = None;
        for line in lines {
            let fields: Vec<_> = line.split(',').collect();
            if fields.len() < 3 {
                continue;
            }
            let descriptor = fields[0];
            if is_connection(descriptor) {
                let Some(id) = current_process.clone() else {
                    continue;
                };
                let Some(remote) = remote_address(descriptor) else {
                    continue;
                };
                if public_only && !is_public_address(&remote) {
                    continue;
                }
                let (Ok(received), Ok(sent)) = (fields[1].parse(), fields[2].parse()) else {
                    continue;
                };
                delta.add(id, Some(&remote), NetworkCounters { received, sent });
            } else {
                current_process = parse_process_id(descriptor);
                if public_only {
                    continue;
                }
                let (Some(id), Ok(received), Ok(sent)) = (
                    current_process.clone(),
                    fields[1].parse(),
                    fields[2].parse(),
                ) else {
                    continue;
                };
                delta.add(id, None, NetworkCounters { received, sent });
            }
        }
        delta
    }
}

impl TrafficCollector for NettopCollector {
    fn name(&self) -> &'static str {
        "macOS nettop"
    }

    fn limitations(&self) -> &'static str {
        "Monitoring is active; network block requires the separately signed macOS filter service"
    }

    fn next_delta(&mut self) -> Result<TrafficDelta, String> {
        loop {
            let sample = self.next_sample()?;
            if !self.discarded_initial_sample {
                self.discarded_initial_sample = true;
                continue;
            }
            return Ok(Self::parse_sample(&sample, self.public_only));
        }
    }

    fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for NettopCollector {
    fn drop(&mut self) {
        self.stop();
    }
}

fn parse_process_id(value: &str) -> Option<ProcessId> {
    let (name, pid) = value.rsplit_once('.')?;
    let pid = pid.parse().ok()?;
    (!name.is_empty()).then(|| ProcessId::new(name, pid))
}

fn is_connection(value: &str) -> bool {
    ["tcp4 ", "tcp6 ", "udp4 ", "udp6 "]
        .iter()
        .any(|prefix| value.starts_with(prefix))
}

fn remote_address(descriptor: &str) -> Option<String> {
    let (_, endpoint) = descriptor.split_once("<->")?;
    let endpoint = endpoint.trim();
    let without_port = if descriptor.starts_with("tcp4 ") || descriptor.starts_with("udp4 ") {
        endpoint.rsplit_once(':')?.0
    } else {
        endpoint.rsplit_once('.')?.0
    };
    let address = without_port.split('%').next()?.trim_matches(['[', ']']);
    (!address.is_empty() && address != "*").then(|| address.to_owned())
}

#[cfg(test)]
mod tests {
    use super::NettopCollector;

    #[test]
    fn parses_public_process_and_endpoint_totals() {
        let lines = vec![
            "curl.42,999,999".to_owned(),
            "tcp4 10.0.0.2:50000<->1.1.1.1:443,100,40".to_owned(),
            "tcp4 10.0.0.2:50001<->192.168.1.2:80,50,20".to_owned(),
        ];
        let delta = NettopCollector::parse_sample(&lines, true);
        let counters = delta.processes.values().next().unwrap();
        assert_eq!(counters.received, 100);
        assert_eq!(counters.sent, 40);
        assert_eq!(delta.endpoints.values().next().unwrap().len(), 1);
    }
}
