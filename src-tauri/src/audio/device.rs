use cpal::traits::{DeviceTrait, HostTrait};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
    pub input_channels: u16,
    pub is_default: bool,
}

pub fn enumerate_input_devices() -> Result<Vec<AudioDevice>, String> {
    let host = cpal::default_host();
    let default_device = host.default_input_device();

    let mut devices = Vec::new();
    for device in host.input_devices().map_err(|e| format!("Failed to list devices: {e}"))? {
        let desc = device.description().map_err(|e| format!("Failed to get device name: {e}"))?;
        let name = desc.name().to_string();
        let device_id = format!("{name}_{}", devices.len());

        let ch: u16 = device
            .supported_input_configs()
            .map(|mut configs| configs.next().map(|c| c.channels()).unwrap_or(0))
            .unwrap_or(0);

        let is_default = default_device
            .as_ref()
            .map(|d| {
                d.description()
                    .ok()
                    .map(|d2| d2.name().to_string())
                    .as_deref()
                    == Some(&name)
            })
            .unwrap_or(false);

        devices.push(AudioDevice {
            id: device_id,
            name,
            input_channels: ch,
            is_default,
        });
    }

    Ok(devices)
}
