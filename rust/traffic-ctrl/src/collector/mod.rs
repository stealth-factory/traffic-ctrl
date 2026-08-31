use std::sync::mpsc::{self, Receiver};
use std::thread::{self, JoinHandle};

use traffic_ctrl_core::{TrafficCollector, TrafficDelta};

#[cfg(any(target_os = "linux", test))]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

pub struct RunningCollector {
    pub name: &'static str,
    pub limitations: &'static str,
    pub sample_interval: f64,
    pub receiver: Receiver<Result<TrafficDelta, String>>,
    thread: Option<JoinHandle<()>>,
}

impl RunningCollector {
    pub fn start(interval_seconds: f64, public_only: bool) -> Result<Self, String> {
        let sample_interval = if cfg!(target_os = "macos") {
            interval_seconds.max(1.0)
        } else {
            interval_seconds
        };
        let collector = platform_collector(sample_interval, public_only)?;
        let name = collector.name();
        let limitations = collector.limitations();
        let (sender, receiver) = mpsc::sync_channel(8);
        let thread = thread::Builder::new()
            .name("traffic-ctrl-collector".into())
            .spawn(move || {
                let mut collector = collector;
                loop {
                    let sample = collector.next_delta();
                    let failed = sample.is_err();
                    if sender.send(sample).is_err() || failed {
                        collector.stop();
                        break;
                    }
                }
            })
            .map_err(|error| format!("could not start collector thread: {error}"))?;
        Ok(Self {
            name,
            limitations,
            sample_interval,
            receiver,
            thread: Some(thread),
        })
    }
}

impl Drop for RunningCollector {
    fn drop(&mut self) {
        // The process exits immediately after dropping this handle. Do not
        // block the input loop waiting for a platform sampler here.
        let _ = self.thread.take();
    }
}

fn platform_collector(
    interval_seconds: f64,
    public_only: bool,
) -> Result<Box<dyn TrafficCollector>, String> {
    #[cfg(target_os = "macos")]
    {
        return Ok(Box::new(macos::NettopCollector::new(
            interval_seconds,
            public_only,
        )?));
    }
    #[cfg(target_os = "linux")]
    {
        return Ok(Box::new(linux::SocketCollector::new(
            interval_seconds,
            public_only,
        )?));
    }
    #[allow(unreachable_code)]
    Err("Traffic Ctrl currently supports macOS and Linux".into())
}
