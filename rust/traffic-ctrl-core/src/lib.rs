//! Portable process traffic model and accounting for Traffic Ctrl.

mod address;
mod model;
mod monitor;

pub use address::is_public_address;
pub use model::{
    EndpointTraffic, NetworkCounters, ProcessId, ProcessTraffic, RateSample, TrafficDelta,
};
pub use monitor::TrafficMonitor;

/// Platform collectors emit interval deltas. They must never pass lifetime
/// counters to the monitor because doing so would count traffic from before
/// Traffic Ctrl launched.
pub trait TrafficCollector: Send {
    fn name(&self) -> &'static str;
    fn limitations(&self) -> &'static str;
    fn next_delta(&mut self) -> Result<TrafficDelta, String>;
    fn stop(&mut self) {}
}
