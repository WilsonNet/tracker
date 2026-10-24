use ringbuf::traits::*;
use ringbuf::HeapProd;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use super::device::AudioDevice;

/// JACK client name used by the app. Ports are exposed as `tracker:in_1`, ...
const CLIENT_NAME: &str = "tracker";
const PROBE_NAME: &str = "tracker-probe";
const AUDIO_PORT_TYPE: &str = "32 bit float mono audio";

/// All capture ports on the JACK graph, grouped by owning client and kept in
/// the order PipeWire reports them (front-left, front-right, rear-left, ...).
pub fn capture_port_groups() -> Vec<(String, Vec<String>)> {
    let (client, _status) =
        match jack::Client::new(PROBE_NAME, jack::ClientOptions::NO_START_SERVER) {
            Ok(client) => client,
            Err(_) => return Vec::new(),
        };
    let ports = client.ports(
        Some(".*:capture_.*"),
        Some(AUDIO_PORT_TYPE),
        jack::PortFlags::empty(),
    );

    let mut groups: Vec<(String, Vec<String>)> = Vec::new();
    for port in ports {
        let Some((node, _)) = port.split_once(':') else {
            continue;
        };
        match groups.iter_mut().find(|(name, _)| name == node) {
            Some((_, list)) => list.push(port),
            None => groups.push((node.to_string(), vec![port])),
        }
    }
    groups
}

/// Capture ports of one JACK client, in graph order.
pub fn capture_ports(node: &str) -> Vec<String> {
    capture_port_groups()
        .into_iter()
        .find(|(name, _)| name == node)
        .map(|(_, ports)| ports)
        .unwrap_or_default()
}

/// JACK exposes every PipeWire input as a client with readable port names, so
/// the device list is built from the graph itself (Ardour-style).
pub fn enumerate_devices() -> Vec<AudioDevice> {
    let default_client = pipewire_default_client_name();
    capture_port_groups()
        .into_iter()
        .map(|(node, ports)| AudioDevice {
            id: node.clone(),
            name: node.clone(),
            input_channels: ports.len() as u16,
            is_default: default_client.as_deref() == Some(node.as_str()),
            pcm_id: "jack".into(),
            node: Some(node),
        })
        .collect()
}

/// The JACK client name of the PipeWire default source, e.g.
/// "Scarlett 4i4 USB Analog Surround 5.1" (device description + profile).
fn pipewire_default_client_name() -> Option<String> {
    let out = std::process::Command::new("pactl")
        .args(["get-default-source"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let default = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if default.is_empty() {
        return None;
    }

    let out = std::process::Command::new("pactl")
        .args(["-f", "json", "list", "sources"])
        .output()
        .ok()?;
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    for source in json.as_array()? {
        if source["name"].as_str() != Some(default.as_str()) {
            continue;
        }
        let props = &source["properties"];
        let desc = props["device.description"].as_str()?;
        let profile = props["device.profile.description"].as_str().unwrap_or("");
        return Some(format!("{desc} {profile}").trim().to_string());
    }
    None
}

/// Real-time process callback: interleaves the capture ports into the same
/// ring buffer the cpal path feeds, so levels/recording stay unchanged.
pub struct JackHandler {
    ports: Vec<jack::Port<jack::AudioIn>>,
    producer: HeapProd<f32>,
    out: Vec<f32>,
    running: Arc<AtomicBool>,
    overruns: Arc<AtomicU64>,
}

impl jack::ProcessHandler for JackHandler {
    fn process(&mut self, _client: &jack::Client, ps: &jack::ProcessScope) -> jack::Control {
        if !self.running.load(Ordering::Relaxed) || self.ports.is_empty() {
            return jack::Control::Continue;
        }
        let channels = self.ports.len();
        let frames = self.ports[0].as_slice(ps).len();
        let needed = frames * channels;
        if self.out.len() < needed {
            self.out.resize(needed, 0.0);
        }
        for (port_index, port) in self.ports.iter().enumerate() {
            let slice = port.as_slice(ps);
            let n = slice.len().min(frames);
            for i in 0..n {
                self.out[i * channels + port_index] = slice[i];
            }
        }
        let written = self.producer.push_slice(&self.out[..needed]);
        if written < needed {
            self.overruns.fetch_add(1, Ordering::Relaxed);
        }
        jack::Control::Continue
    }
}

/// Connect `channels` input ports of a new client to the capture ports of
/// `node` and activate it. The returned client must be kept alive.
pub fn start(
    node: &str,
    channels: usize,
    producer: HeapProd<f32>,
    running: Arc<AtomicBool>,
    overruns: Arc<AtomicU64>,
) -> Result<jack::AsyncClient<(), JackHandler>, String> {
    let (client, _status) = jack::Client::new(CLIENT_NAME, jack::ClientOptions::NO_START_SERVER)
        .map_err(|e| format!("JACK client: {e}"))?;
    let buffer_size = client.buffer_size().max(1) as usize;

    let mut ports = Vec::with_capacity(channels);
    for i in 0..channels {
        let port = client
            .register_port(&format!("in_{}", i + 1), jack::AudioIn::default())
            .map_err(|e| format!("JACK port {}: {e}", i + 1))?;
        ports.push(port);
    }

    let targets = capture_ports(node);
    if targets.is_empty() {
        return Err(format!("No capture ports on '{node}'"));
    }
    for i in 0..channels.min(targets.len()) {
        client
            .connect_ports_by_name(&targets[i], &format!("{}:in_{}", client.name(), i + 1))
            .map_err(|e| format!("JACK connect '{}': {e}", targets[i]))?;
    }

    let handler = JackHandler {
        ports,
        producer,
        out: vec![0.0; buffer_size * channels.max(1)],
        running,
        overruns,
    };
    client
        .activate_async((), handler)
        .map_err(|e| format!("JACK activate: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ringbuf::traits::{Consumer, Split};
    use ringbuf::HeapRb;
    use std::thread;
    use std::time::{Duration, Instant};

    /// Live hardware check: capture 3 s from the first multi-channel input,
    /// write input 2 to a mono WAV and report per-channel peaks.
    /// `cargo test --lib live_capture -- --ignored --nocapture`
    #[test]
    #[ignore = "requires a live PipeWire/JACK input device"]
    fn live_capture_writes_input_2() {
        let groups = capture_port_groups();
        for (node, ports) in &groups {
            println!("group {node:?} -> {ports:?}");
        }
        let (node, ports) = groups
            .iter()
            .find(|(n, p)| p.len() >= 2 && n.contains("Scarlett"))
            .or_else(|| groups.iter().find(|(_, p)| p.len() >= 2))
            .map(|(n, p)| (n.clone(), p.clone()))
            .expect("no multi-channel capture device");
        let channels = ports.len();
        println!("capturing {node:?} channels={channels}");

        let rb = HeapRb::<f32>::new(48_000 * channels);
        let (producer, mut consumer) = rb.split();
        let running = Arc::new(AtomicBool::new(true));
        let overruns = Arc::new(AtomicU64::new(0));
        let client = start(
            &node,
            channels,
            producer,
            running.clone(),
            overruns.clone(),
        )
        .expect("start jack capture");

        let mut samples: Vec<f32> = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut buf = vec![0.0_f32; 8192 * channels];
        while Instant::now() < deadline {
            thread::sleep(Duration::from_millis(50));
            let n = consumer.pop_slice(&mut buf);
            samples.extend_from_slice(&buf[..n]);
        }
        running.store(false, Ordering::SeqCst);
        drop(client);

        assert!(!samples.is_empty(), "captured no samples");
        let frames = samples.len() / channels;
        println!(
            "captured {} frames, {:.2}s, overruns={}",
            frames,
            frames as f32 / 48_000.0,
            overruns.load(Ordering::Relaxed)
        );
        assert!(frames > 48_000, "captured less than one second");

        let mut peaks = vec![0.0_f32; channels];
        for frame in samples.chunks(channels) {
            for (c, &s) in frame.iter().enumerate() {
                peaks[c] = peaks[c].max(s.abs());
            }
        }
        let db = |x: f32| if x <= 0.0 { -120.0 } else { 20.0 * x.log10() };
        for (c, &p) in peaks.iter().enumerate() {
            println!("input {} peak {:.1} dBFS", c + 1, db(p));
        }

        let dir = std::env::temp_dir().join("tracker_live_capture");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("input_2.wav");
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 48_000,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        };
        let mut writer = hound::WavWriter::create(&path, spec).unwrap();
        for frame in samples.chunks(channels) {
            writer.write_sample(frame[1]).unwrap();
        }
        writer.finalize().unwrap();
        let size = std::fs::metadata(&path).unwrap().len();
        println!("wrote {} ({} bytes)", path.display(), size);
        assert!(size > 44, "wav has no samples");

        let mut reader = hound::WavReader::open(&path).unwrap();
        let written: Vec<f32> = reader.samples::<f32>().map(|s| s.unwrap()).collect();
        assert_eq!(written.len(), frames);
        println!("read back {} samples", written.len());
    }
}
