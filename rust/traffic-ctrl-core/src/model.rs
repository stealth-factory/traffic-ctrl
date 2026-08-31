use std::collections::HashMap;

#[derive(Clone, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ProcessId {
    pub name: String,
    pub pid: u32,
}

impl ProcessId {
    pub fn new(name: impl Into<String>, pid: u32) -> Self {
        Self {
            name: name.into(),
            pid,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct NetworkCounters {
    pub received: u64,
    pub sent: u64,
}

impl NetworkCounters {
    pub fn total(self) -> u64 {
        self.received.saturating_add(self.sent)
    }

    pub fn add_assign(&mut self, other: Self) {
        self.received = self.received.saturating_add(other.received);
        self.sent = self.sent.saturating_add(other.sent);
    }
}

#[derive(Clone, Debug, Default)]
pub struct TrafficDelta {
    pub processes: HashMap<ProcessId, NetworkCounters>,
    pub endpoints: HashMap<ProcessId, HashMap<String, NetworkCounters>>,
}

impl TrafficDelta {
    pub fn add(&mut self, id: ProcessId, endpoint: Option<&str>, counters: NetworkCounters) {
        self.processes
            .entry(id.clone())
            .or_default()
            .add_assign(counters);
        if let Some(endpoint) = endpoint {
            self.endpoints
                .entry(id)
                .or_default()
                .entry(endpoint.to_owned())
                .or_default()
                .add_assign(counters);
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RateSample {
    pub received: f64,
    pub sent: f64,
}

#[derive(Clone, Debug, Default)]
pub struct ProcessTraffic {
    pub id: ProcessId,
    pub received: u64,
    pub sent: u64,
    pub receive_rate: f64,
    pub send_rate: f64,
}

impl ProcessTraffic {
    pub fn total(&self) -> u64 {
        self.received.saturating_add(self.sent)
    }

    pub fn total_rate(&self) -> f64 {
        self.receive_rate + self.send_rate
    }
}

#[derive(Clone, Debug, Default)]
pub struct EndpointTraffic {
    pub address: String,
    pub received: u64,
    pub sent: u64,
    pub receive_rate: f64,
    pub send_rate: f64,
}

impl EndpointTraffic {
    pub fn total(&self) -> u64 {
        self.received.saturating_add(self.sent)
    }

    pub fn total_rate(&self) -> f64 {
        self.receive_rate + self.send_rate
    }
}
