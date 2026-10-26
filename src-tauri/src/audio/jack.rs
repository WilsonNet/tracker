use ringbuf::traits::*;
use ringbuf::HeapProd;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use super::device::AudioDevice;

/// JACK client name used by the app. Ports are exposed as `tracker:in_1`, ...
const CLIENT_NAME: &str = "tracker";
const PLAYBACK_CLIENT_NAME: &str = "tracker-out";
const PROBE_NAME: &str = "tracker-probe";
const AUDIO_PORT_TYPE: &str = "32 bit float mono audio";

/// Clean up a single JACK port name into a human-friendly channel label.
/// e.g. "Focusrite Scarlett 2i2 2nd Gen Input 1 Mic/Inst/Line:capture_MONO" -> "Input 1 Mic/Inst/Line"
/// e.g. "Focusrite Scarlett 2i2 2nd Gen 0:capture_AUX0" -> "IN 1 (AUX0)"
/// e.g. "Ryzen HD Audio Controller Stereo Microphone:capture_FL" -> "Stereo Mic L"
pub fn clean_port_label(device_prefix: &str, full_port: &str, index: usize) -> String {
    let Some((client, port)) = full_port.split_once(':') else {
        return format!("IN {}", index + 1);
    };
    let sub_client = client
        .strip_prefix(device_prefix)
        .unwrap_or(client)
        .trim();
    let suffix = port.strip_prefix("capture_").unwrap_or(port).trim();

    // If the sub-client has a descriptive profile (like "Input 1 Mic/Inst/Line")
    if !sub_client.is_empty() && !sub_client.chars().all(|c| c.is_ascii_digit()) {
        if suffix.eq_ignore_ascii_case("MONO") {
            return sub_client.to_string();
        }
        return format!("{sub_client} ({suffix})");
    }

    match suffix {
        "FL" => "IN 1 (L)".to_string(),
        "FR" => "IN 2 (R)".to_string(),
        "MONO" => format!("IN {}", index + 1),
        s if s.starts_with("AUX") => {
            if let Ok(n) = s.trim_start_matches("AUX").parse::<usize>() {
                format!("IN {} ({s})", n + 1)
            } else {
                format!("IN {} ({s})", index + 1)
            }
        }
        other => format!("IN {} ({other})", index + 1),
    }
}

/// Strip trailing PipeWire profile/index suffixes so related JACK clients from the
/// same hardware interface can be grouped or ranked cleanly.
fn hardware_base_name(client: &str) -> String {
    if let Some((base, _)) = client.split_once(" Input ") {
        return base.trim().to_string();
    }
    if let Some((base, tail)) = client.rsplit_once(' ') {
        if tail.chars().all(|c| c.is_ascii_digit()) {
            return base.trim().to_string();
        }
    }
    client.trim().to_string()
}

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

/// Capture ports for a target `node`.
/// Supports:
/// - `@group:<BaseName>` which aggregates all individual mono `Input N` ports (or multichannel ports) of a card
/// - Exact JACK client name (e.g. `Focusrite Scarlett 2i2 2nd Gen 0`)
pub fn capture_ports(node: &str) -> Vec<String> {
    let groups = capture_port_groups();
    if let Some(base) = node.strip_prefix("@group:") {
        // Prefer the multi-channel raw node if it exists and has >=2 ports, OR collect all mono Input N ports in order
        let mut mono_inputs: Vec<(usize, String)> = Vec::new();
        let mut multi_ports: Vec<String> = Vec::new();

        for (client_name, ports) in &groups {
            if hardware_base_name(client_name) != base {
                continue;
            }
            if let Some((_, after)) = client_name.split_once(" Input ") {
                let num = after
                    .split_whitespace()
                    .next()
                    .and_then(|s| s.parse::<usize>().ok())
                    .unwrap_or(99);
                for p in ports {
                    mono_inputs.push((num, p.clone()));
                }
            } else if ports.len() > multi_ports.len() {
                multi_ports = ports.clone();
            }
        }
        mono_inputs.sort_by_key(|(num, _)| *num);
        if mono_inputs.len() >= multi_ports.len() && !mono_inputs.is_empty() {
            return mono_inputs.into_iter().map(|(_, p)| p).collect();
        }
        if !multi_ports.is_empty() {
            return multi_ports;
        }
    }

    groups
        .into_iter()
        .find(|(name, _)| name == node)
        .map(|(_, ports)| ports)
        .unwrap_or_default()
}

/// JACK exposes every PipeWire input as a client with readable port names, so
/// the device list is built from the graph itself (Ardour-style).
/// When a hardware card is split into multiple mono `Input N` JACK clients by a
/// HiFi/Pro profile, we also synthesize a unified multi-channel device entry so
/// the user sees all inputs (e.g. IN 1 + IN 2) at once without hunting for "0".
pub fn enumerate_devices() -> Vec<AudioDevice> {
    let default_client = pipewire_default_client_name();
    let groups = capture_port_groups();
    if groups.is_empty() {
        return Vec::new();
    }

    // Group clients by hardware base name to detect split mono / Aux nodes
    let mut by_base: BTreeMap<String, Vec<(String, Vec<String>)>> = BTreeMap::new();
    for (node, ports) in &groups {
        let base = hardware_base_name(node);
        by_base.entry(base).or_default().push((node.clone(), ports.clone()));
    }

    let mut devices: Vec<AudioDevice> = Vec::new();

    for (base, client_list) in &by_base {
        if client_list.len() > 1 {
            // Synthesize a unified multi-channel device for this hardware card
            let group_node = format!("@group:{base}");
            let ports = capture_ports(&group_node);
            if ports.len() > 1 {
                let any_default = client_list.iter().any(|(n, _)| {
                    default_client.as_deref() == Some(n.as_str())
                });
                let channel_names: Vec<String> = ports
                    .iter()
                    .enumerate()
                    .map(|(i, p)| clean_port_label(base, p, i))
                    .collect();
                devices.push(AudioDevice {
                    id: group_node.clone(),
                    name: format!("{base} (All Inputs)"),
                    input_channels: ports.len() as u16,
                    channel_names,
                    is_default: any_default,
                    backend: "PipeWire JACK".into(),
                    pcm_id: "jack".into(),
                    node: Some(group_node),
                });
            }
        }
    }

    for (node, ports) in groups {
        let base = hardware_base_name(&node);
        let channel_names: Vec<String> = ports
            .iter()
            .enumerate()
            .map(|(i, p)| clean_port_label(&base, p, i))
            .collect();
        let is_default = default_client.as_deref() == Some(node.as_str())
            && !devices.iter().any(|d| d.is_default);
        devices.push(AudioDevice {
            id: node.clone(),
            name: node.clone(),
            input_channels: ports.len() as u16,
            channel_names,
            is_default,
            backend: "PipeWire JACK".into(),
            pcm_id: "jack".into(),
            node: Some(node),
        });
    }

    // Ensure at least one default is marked
    if !devices.is_empty() && !devices.iter().any(|d| d.is_default) {
        devices[0].is_default = true;
    }

    devices
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

/// The JACK client name of the PipeWire default sink (output), e.g.
/// "Focusrite Scarlett 2i2 2nd Gen Headphones / Line 1-2".
pub fn pipewire_default_sink_client_name() -> Option<String> {
    let out = std::process::Command::new("pactl")
        .args(["get-default-sink"])
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
        .args(["-f", "json", "list", "sinks"])
        .output()
        .ok()?;
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    for sink in json.as_array()? {
        if sink["name"].as_str() != Some(default.as_str()) {
            continue;
        }
        let props = &sink["properties"];
        let desc = props["device.description"].as_str()?;
        let profile = props["device.profile.description"].as_str().unwrap_or("");
        return Some(format!("{desc} {profile}").trim().to_string());
    }
    None
}

/// Real-time playback callback through PipeWire JACK — completely cooperative,
/// never touches ALSA or steals hardware from browsers/YouTube.
pub struct JackPlaybackHandler {
    out_l: jack::Port<jack::AudioOut>,
    out_r: jack::Port<jack::AudioOut>,
    samples: Vec<f32>,
    position: Arc<std::sync::atomic::AtomicUsize>,
}

impl jack::ProcessHandler for JackPlaybackHandler {
    fn process(&mut self, _client: &jack::Client, ps: &jack::ProcessScope) -> jack::Control {
        let l_slice = self.out_l.as_mut_slice(ps);
        let r_slice = self.out_r.as_mut_slice(ps);
        let frames = l_slice.len().min(r_slice.len());
        let total_frames = self.samples.len() / 2;
        let mut p = self.position.load(Ordering::Relaxed);

        for i in 0..frames {
            if p < total_frames {
                l_slice[i] = self.samples[p * 2];
                r_slice[i] = self.samples[p * 2 + 1];
            } else {
                l_slice[i] = 0.0;
                r_slice[i] = 0.0;
            }
            p += 1;
        }
        self.position.store(p, Ordering::Relaxed);
        jack::Control::Continue
    }
}

/// Start cooperative stereo playback through PipeWire JACK.
/// Returns the active client and total resampled frames.
pub fn start_playback(
    samples: Vec<f32>,
    render_rate: u32,
    position: Arc<std::sync::atomic::AtomicUsize>,
) -> Result<(jack::AsyncClient<(), JackPlaybackHandler>, usize), String> {
    let (client, _status) =
        jack::Client::new(PLAYBACK_CLIENT_NAME, jack::ClientOptions::NO_START_SERVER)
            .map_err(|e| format!("JACK playback client: {e}"))?;
    let jack_rate = client.sample_rate() as u32;

    let samples = if jack_rate != render_rate {
        super::engine::resample_linear(&samples, render_rate, jack_rate, 2)
    } else {
        samples
    };
    let total_frames = samples.len() / 2;

    let out_l = client
        .register_port("out_L", jack::AudioOut::default())
        .map_err(|e| format!("JACK out_L: {e}"))?;
    let out_r = client
        .register_port("out_R", jack::AudioOut::default())
        .map_err(|e| format!("JACK out_R: {e}"))?;

    // Find playback ports for the default PipeWire sink (or first available sink)
    let all_pb_ports = client.ports(
        Some(".*:playback_.*"),
        Some(AUDIO_PORT_TYPE),
        jack::PortFlags::IS_INPUT,
    );
    let default_sink = pipewire_default_sink_client_name();
    let mut target_ports: Vec<String> = Vec::new();
    if let Some(ref sink_name) = default_sink {
        for p in &all_pb_ports {
            if let Some((node, _)) = p.split_once(':') {
                if node == sink_name {
                    target_ports.push(p.clone());
                }
            }
        }
    }
    if target_ports.is_empty() {
        // Fallback to first sink group
        if let Some(first) = all_pb_ports.first() {
            if let Some((first_node, _)) = first.split_once(':') {
                for p in &all_pb_ports {
                    if p.starts_with(&format!("{first_node}:")) {
                        target_ports.push(p.clone());
                    }
                }
            }
        }
    }

    let l_name = format!("{}:out_L", client.name());
    let r_name = format!("{}:out_R", client.name());

    let handler = JackPlaybackHandler {
        out_l,
        out_r,
        samples,
        position,
    };
    let active = client
        .activate_async((), handler)
        .map_err(|e| format!("JACK playback activate: {e}"))?;

    if let Some(t0) = target_ports.first() {
        let _ = active.as_client().connect_ports_by_name(&l_name, t0);
    }
    if let Some(t1) = target_ports.get(1).or_else(|| target_ports.first()) {
        let _ = active.as_client().connect_ports_by_name(&r_name, t1);
    }

    Ok((active, total_frames))
}
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
        let devices = enumerate_devices();
        for d in &devices {
            println!("device: {:?} (id={:?}, ch={}, names={:?})", d.name, d.id, d.input_channels, d.channel_names);
        }
        let dev = devices
            .iter()
            .find(|d| d.input_channels >= 2 && d.name.contains("Scarlett"))
            .or_else(|| devices.iter().find(|d| d.input_channels >= 2))
            .expect("no multi-channel capture device");
        let node = dev.node.clone().unwrap();
        let channels = dev.input_channels as usize;
        println!("capturing {node:?} ({}) channels={channels}", dev.name);

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
