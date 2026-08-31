use std::collections::HashMap;
use std::time::Duration;

use crate::{EndpointTraffic, ProcessId, ProcessTraffic, RateSample, TrafficDelta};

const HISTORY_LIMIT: usize = 240;

#[derive(Default)]
pub struct TrafficMonitor {
    traffic: HashMap<ProcessId, ProcessTraffic>,
    endpoints: HashMap<ProcessId, HashMap<String, EndpointTraffic>>,
    aggregate_history: Vec<RateSample>,
    process_history: HashMap<ProcessId, Vec<RateSample>>,
    endpoint_history: HashMap<ProcessId, HashMap<String, Vec<RateSample>>>,
}

impl TrafficMonitor {
    pub fn reset(&mut self) {
        self.traffic.clear();
        self.endpoints.clear();
        self.aggregate_history.clear();
        self.process_history.clear();
        self.endpoint_history.clear();
    }

    pub fn ingest(&mut self, delta: TrafficDelta, elapsed: Duration) {
        let seconds = elapsed.as_secs_f64();
        for item in self.traffic.values_mut() {
            item.receive_rate = 0.0;
            item.send_rate = 0.0;
        }
        for values in self.endpoints.values_mut() {
            for item in values.values_mut() {
                item.receive_rate = 0.0;
                item.send_rate = 0.0;
            }
        }

        for (id, counters) in delta.processes {
            let item = self
                .traffic
                .entry(id.clone())
                .or_insert_with(|| ProcessTraffic {
                    id,
                    ..ProcessTraffic::default()
                });
            item.received = item.received.saturating_add(counters.received);
            item.sent = item.sent.saturating_add(counters.sent);
            item.receive_rate = rate(counters.received, seconds);
            item.send_rate = rate(counters.sent, seconds);
        }

        for (id, endpoint_delta) in delta.endpoints {
            for (address, counters) in endpoint_delta {
                let item = self
                    .endpoints
                    .entry(id.clone())
                    .or_default()
                    .entry(address.clone())
                    .or_insert_with(|| EndpointTraffic {
                        address,
                        ..EndpointTraffic::default()
                    });
                item.received = item.received.saturating_add(counters.received);
                item.sent = item.sent.saturating_add(counters.sent);
                item.receive_rate = rate(counters.received, seconds);
                item.send_rate = rate(counters.sent, seconds);
            }
        }

        let aggregate = self
            .traffic
            .values()
            .fold(RateSample::default(), |mut total, item| {
                total.received += item.receive_rate;
                total.sent += item.send_rate;
                total
            });
        append_history(&mut self.aggregate_history, aggregate);

        for (id, item) in &self.traffic {
            append_history(
                self.process_history.entry(id.clone()).or_default(),
                RateSample {
                    received: item.receive_rate,
                    sent: item.send_rate,
                },
            );
        }
        for (id, endpoints) in &self.endpoints {
            for (address, endpoint) in endpoints {
                append_history(
                    self.endpoint_history
                        .entry(id.clone())
                        .or_default()
                        .entry(address.clone())
                        .or_default(),
                    RateSample {
                        received: endpoint.receive_rate,
                        sent: endpoint.send_rate,
                    },
                );
            }
        }
    }

    pub fn processes(&self) -> impl Iterator<Item = &ProcessTraffic> {
        self.traffic.values()
    }

    pub fn process(&self, id: &ProcessId) -> Option<&ProcessTraffic> {
        self.traffic.get(id)
    }

    pub fn endpoints(&self, id: &ProcessId) -> impl Iterator<Item = &EndpointTraffic> {
        self.endpoints
            .get(id)
            .into_iter()
            .flat_map(|items| items.values())
    }

    pub fn process_history(&self, id: &ProcessId) -> &[RateSample] {
        self.process_history.get(id).map_or(&[], Vec::as_slice)
    }

    pub fn endpoint_history(&self, id: &ProcessId, address: &str) -> &[RateSample] {
        self.endpoint_history
            .get(id)
            .and_then(|items| items.get(address))
            .map_or(&[], Vec::as_slice)
    }

    pub fn aggregate_history(&self) -> &[RateSample] {
        &self.aggregate_history
    }
}

fn rate(bytes: u64, seconds: f64) -> f64 {
    if seconds > 0.0 {
        bytes as f64 / seconds
    } else {
        0.0
    }
}

fn append_history(history: &mut Vec<RateSample>, sample: RateSample) {
    history.push(sample);
    if history.len() > HISTORY_LIMIT {
        history.drain(..history.len() - HISTORY_LIMIT);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use crate::{NetworkCounters, ProcessId, TrafficDelta, TrafficMonitor};

    #[test]
    fn accumulates_deltas_and_resets_rates() {
        let id = ProcessId::new("curl", 42);
        let mut first = TrafficDelta::default();
        first.add(
            id.clone(),
            Some("1.1.1.1"),
            NetworkCounters {
                received: 100,
                sent: 40,
            },
        );
        let mut monitor = TrafficMonitor::default();
        monitor.ingest(first, Duration::from_secs(2));

        let item = monitor.processes().next().unwrap();
        assert_eq!(item.total(), 140);
        assert_eq!(item.receive_rate, 50.0);

        monitor.ingest(TrafficDelta::default(), Duration::from_secs(1));
        let item = monitor.processes().next().unwrap();
        assert_eq!(item.total(), 140);
        assert_eq!(item.total_rate(), 0.0);
    }
}
