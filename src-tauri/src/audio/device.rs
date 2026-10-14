use cpal::traits::{DeviceTrait, HostTrait};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
    pub input_channels: u16,
    pub is_default: bool,
    #[serde(skip)]
    pub pcm_id: String,
    #[serde(skip)]
    pub node: Option<String>,
}

/// "acp6x, " -> "acp6x", "Scarlett 4i4 USB, USB Audio" stays as-is.
fn clean_name(raw: &str) -> String {
    raw.trim().trim_end_matches(',').trim().to_string()
}

/// The PipeWire/Pulse default source node, e.g.
/// "alsa_input.usb-Focusrite_Scarlett_4i4_USB_D81ZWH323266D0-00.analog-surround-51".
#[cfg(target_os = "linux")]
fn pipewire_default_source() -> Option<String> {
    let out = std::process::Command::new("pactl")
        .args(["get-default-source"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let src = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if src.is_empty() {
        None
    } else {
        Some(src)
    }
}

/// Capture-capable PipeWire input sources, Ardour-style: these are the real
/// inputs on a PipeWire system, and they can be captured cooperatively (see
/// `PIPEWIRE_NODE` in the engine) while PipeWire or other apps hold the card.
#[cfg(target_os = "linux")]
fn enumerate_pipewire_sources() -> Vec<AudioDevice> {
    let out = match std::process::Command::new("pactl")
        .args(["-f", "json", "list", "sources"])
        .output()
    {
        Ok(out) if out.status.success() => out,
        _ => return Vec::new(),
    };
    let json: serde_json::Value = match serde_json::from_slice(&out.stdout) {
        Ok(json) => json,
        Err(_) => return Vec::new(),
    };
    let arr = match json.as_array() {
        Some(arr) => arr,
        None => return Vec::new(),
    };

    let default = pipewire_default_source();

    struct Source {
        name: String,
        description: String,
        profile: String,
        channels: u16,
        is_default: bool,
    }

    let mut sources: Vec<Source> = Vec::new();
    for s in arr {
        let name = s["name"].as_str().unwrap_or("").to_string();
        if name.is_empty() || name.ends_with(".monitor") {
            continue;
        }
        let channels = s["channel_map"]
            .as_str()
            .unwrap_or("")
            .split(',')
            .filter(|p| !p.trim().is_empty())
            .count() as u16;
        if channels == 0 {
            continue;
        }
        let props = &s["properties"];
        let description = props["device.description"]
            .as_str()
            .or_else(|| s["description"].as_str())
            .unwrap_or(&name)
            .to_string();
        let profile = props["device.profile.description"]
            .as_str()
            .unwrap_or("")
            .to_string();
        let is_default = default.as_deref() == Some(name.as_str());
        sources.push(Source {
            name,
            description,
            profile,
            channels,
            is_default,
        });
    }

    let mut devices = Vec::new();
    for s in &sources {
        let duplicated = sources
            .iter()
            .filter(|o| o.description == s.description)
            .count()
            > 1;
        let name = if duplicated && !s.profile.is_empty() {
            format!("{} ({})", s.description, s.profile)
        } else {
            s.description.clone()
        };
        devices.push(AudioDevice {
            id: s.name.clone(),
            name,
            input_channels: s.channels,
            is_default: s.is_default,
            pcm_id: "pipewire".into(),
            node: Some(s.name.clone()),
        });
    }
    devices
}

/// Hardware fallback (pure ALSA systems): capture-capable cards only.
/// On Linux only `plughw:CARD=n,DEV=n` PCMs are kept, never ALSA plugin
/// pseudo-devices (pulse, pipewire, dmix, surround converters, ...).
fn enumerate_hardware_devices() -> Result<Vec<AudioDevice>, String> {
    let host = cpal::default_host();
    let default_name = host
        .default_input_device()
        .and_then(|d| d.description().ok())
        .map(|d| d.name().to_string());

    let all_devices: Vec<cpal::Device> = host
        .input_devices()
        .map_err(|e| format!("Failed to list devices: {e}"))?
        .collect();

    // plughw reports a converted default (e.g. 2ch); the matching hw PCM knows the
    // card's real channel count (the Scarlett 4i4 exposes 6: 4 analog + loopback).
    let hw_channel_count = |pcm_id: &str| -> Option<u16> {
        let hw_id = pcm_id.replacen("plughw:", "hw:", 1);
        all_devices
            .iter()
            .find(|d| {
                d.description()
                    .ok()
                    .and_then(|desc| desc.driver().map(|s| s.to_string()))
                    .as_deref()
                    == Some(hw_id.as_str())
            })
            .and_then(|d| d.default_input_config().ok())
            .map(|c| c.channels())
    };

    let mut devices: Vec<AudioDevice> = Vec::new();
    let mut seen_names: Vec<String> = Vec::new();

    for device in &all_devices {
        let desc = match device.description() {
            Ok(d) => d,
            Err(_) => continue,
        };
        let pcm_id = desc.driver().unwrap_or("").to_string();

        #[cfg(target_os = "linux")]
        if !pcm_id.starts_with("plughw:") {
            continue;
        }

        let name = clean_name(desc.name());
        if name.is_empty() || seen_names.contains(&name) {
            continue;
        }

        let channels = if pcm_id.starts_with("plughw:") {
            hw_channel_count(&pcm_id)
        } else {
            None
        }
        .or_else(|| device.default_input_config().ok().map(|c| c.channels()))
        .or_else(|| {
            device
                .supported_input_configs()
                .ok()
                .and_then(|mut it| it.next().map(|c| c.channels()))
        })
        .unwrap_or(0);
        if channels == 0 {
            continue;
        }

        let is_default = default_name.as_deref() == Some(desc.name());

        let id = if pcm_id.is_empty() {
            format!("{name}_{}", devices.len())
        } else {
            pcm_id.clone()
        };

        seen_names.push(name.clone());
        devices.push(AudioDevice {
            id,
            name,
            input_channels: channels,
            is_default,
            pcm_id,
            node: None,
        });
    }

    if let Some(pos) = devices.iter().position(|d| d.is_default) {
        for (i, d) in devices.iter_mut().enumerate() {
            if i != pos {
                d.is_default = false;
            }
        }
    } else if let Some(first) = devices.first_mut() {
        first.is_default = true;
    }

    Ok(devices)
}

/// Enumerate capture devices. On Linux with PipeWire running, the list is the
/// JACK graph (every input as readable ports); otherwise the PipeWire ALSA
/// sources, and finally the raw hardware cards.
pub fn enumerate_input_devices() -> Result<Vec<AudioDevice>, String> {
    #[cfg(target_os = "linux")]
    {
        let jack_devices = super::jack::enumerate_devices();
        if !jack_devices.is_empty() {
            return Ok(jack_devices);
        }
        let sources = enumerate_pipewire_sources();
        if !sources.is_empty() {
            return Ok(sources);
        }
    }
    enumerate_hardware_devices()
}

/// Open the cpal device behind an enumerated `AudioDevice`.
pub fn find_cpal_device(dev: &AudioDevice) -> Result<cpal::Device, String> {
    let host = cpal::default_host();
    let devices = host
        .input_devices()
        .map_err(|e| format!("Failed to enumerate devices: {e}"))?;
    for device in devices {
        if let Ok(desc) = device.description() {
            if !dev.pcm_id.is_empty() && desc.driver() == Some(dev.pcm_id.as_str()) {
                return Ok(device);
            }
            if dev.pcm_id.is_empty() && desc.name() == dev.name {
                return Ok(device);
            }
        }
    }
    if dev.pcm_id == "pipewire" {
        if let Some(device) = host.default_input_device() {
            return Ok(device);
        }
    }
    Err(format!("Device '{}' no longer available", dev.name))
}
