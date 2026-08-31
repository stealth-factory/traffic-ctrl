use std::collections::HashMap;
use std::time::{Duration, Instant};

use traffic_ctrl_core::ProcessId;

pub struct PauseManager {
    paused: HashMap<ProcessId, Instant>,
}

impl PauseManager {
    pub fn new() -> Self {
        Self {
            paused: HashMap::new(),
        }
    }

    pub fn pause(&mut self, id: ProcessId) -> Result<(), String> {
        pause(&id)?;
        self.paused
            .insert(id, Instant::now() + Duration::from_secs(30));
        Ok(())
    }

    pub fn resume(&mut self, id: &ProcessId) -> Result<(), String> {
        resume(id)?;
        self.paused.remove(id);
        Ok(())
    }

    pub fn is_paused(&self, id: &ProcessId) -> bool {
        self.paused.contains_key(id)
    }

    pub fn seconds_remaining(&self, id: &ProcessId) -> Option<u64> {
        self.paused.get(id).map(|deadline| {
            deadline
                .saturating_duration_since(Instant::now())
                .as_secs()
                .saturating_add(1)
        })
    }

    pub fn resume_expired(&mut self) -> Vec<(ProcessId, Result<(), String>)> {
        let now = Instant::now();
        let expired: Vec<_> = self
            .paused
            .iter()
            .filter_map(|(id, deadline)| (now >= *deadline).then_some(id.clone()))
            .collect();
        expired
            .into_iter()
            .map(|id| {
                let result = resume(&id);
                self.paused.remove(&id);
                (id, result)
            })
            .collect()
    }

    pub fn resume_all(&mut self) {
        for id in self.paused.keys() {
            let _ = resume(id);
        }
        self.paused.clear();
    }
}

impl Drop for PauseManager {
    fn drop(&mut self) {
        self.resume_all();
    }
}

pub fn pause(id: &ProcessId) -> Result<(), String> {
    if id.pid <= 1 {
        return Err("Refusing to pause a critical system process".into());
    }
    if id.pid == std::process::id() {
        return Err("Refusing to pause Traffic Ctrl itself".into());
    }
    send(id, libc::SIGSTOP, "pause")
}

pub fn resume(id: &ProcessId) -> Result<(), String> {
    send(id, libc::SIGCONT, "resume")
}

fn send(id: &ProcessId, signal: libc::c_int, action: &str) -> Result<(), String> {
    if unsafe { libc::kill(id.pid as libc::pid_t, signal) } == 0 {
        Ok(())
    } else {
        Err(format!(
            "Could not {action} {} (PID {}): {}",
            id.name,
            id.pid,
            std::io::Error::last_os_error()
        ))
    }
}
