use std::collections::{HashMap, HashSet};
use std::process::Command;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

pub struct HostnameResolver {
    requests: Sender<String>,
    results: Receiver<(String, Option<String>)>,
    cache: HashMap<String, Option<String>>,
    requested: HashSet<String>,
}

impl HostnameResolver {
    pub fn start() -> Result<Self, String> {
        let (request_tx, request_rx) = mpsc::channel::<String>();
        let (result_tx, result_rx) = mpsc::channel();
        thread::Builder::new()
            .name("traffic-ctrl-resolver".into())
            .spawn(move || {
                while let Ok(address) = request_rx.recv() {
                    let hostname = resolve(&address);
                    if result_tx.send((address, hostname)).is_err() {
                        break;
                    }
                }
            })
            .map_err(|error| format!("could not start hostname resolver: {error}"))?;
        Ok(Self {
            requests: request_tx,
            results: result_rx,
            cache: HashMap::new(),
            requested: HashSet::new(),
        })
    }

    pub fn request<'a>(&mut self, addresses: impl IntoIterator<Item = &'a str>) {
        for address in addresses {
            if self.requested.insert(address.to_owned()) {
                let _ = self.requests.send(address.to_owned());
            }
        }
    }

    pub fn drain(&mut self) -> bool {
        let mut changed = false;
        while let Ok((address, hostname)) = self.results.try_recv() {
            self.cache.insert(address, hostname);
            changed = true;
        }
        changed
    }

    pub fn get(&self, address: &str) -> Option<&str> {
        self.cache.get(address).and_then(Option::as_deref)
    }
}

#[cfg(target_os = "macos")]
fn resolve(address: &str) -> Option<String> {
    let output = Command::new("/usr/bin/dscacheutil")
        .args(["-q", "host", "-a", "ip_address", address])
        .output()
        .ok()?;
    output.status.success().then_some(())?;
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find_map(|line| line.trim().strip_prefix("name: ").map(str::to_owned))
}

#[cfg(target_os = "linux")]
fn resolve(address: &str) -> Option<String> {
    let output = Command::new("getent")
        .args(["hosts", address])
        .output()
        .ok()?;
    output.status.success().then_some(())?;
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .nth(1)
        .map(str::to_owned)
}
