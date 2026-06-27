use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use hound::WavWriter;
use ringbuf::traits::*;
use ringbuf::HeapRb;
use serde::Serialize;
use std::io::BufWriter;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

use super::device::enumerate_input_devices;

#[derive(Debug, Clone, Serialize)]
pub struct LevelUpdatePayload {
    pub input_a_peak: f32,
    pub input_a_rms: f32,
    pub input_b_peak: f32,
    pub input_b_rms: f32,
    pub recording: bool,
    pub armed_tracks: Vec<bool>,
    pub metrics: MetricsPayload,
}

#[derive(Debug, Clone, Serialize)]
pub struct MetricsPayload {
    pub underruns: u64,
    pub overruns: u64,
    pub callback_interval_ms: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct RecordingStatus {
    pub active: bool,
    pub armed: Vec<bool>,
    pub file_count: usize,
    pub output_dir: String,
}

type TrackWriter = Option<WavWriter<BufWriter<std::fs::File>>>;

pub struct AudioEngine {
    running: Arc<AtomicBool>,
    stream: Mutex<Option<cpal::Stream>>,
    playback_stream: Mutex<Option<cpal::Stream>>,
    underruns: Arc<AtomicU64>,
    overruns: Arc<AtomicU64>,
    rec_active: Arc<AtomicBool>,
    rec_writers: Arc<Mutex<Vec<TrackWriter>>>,
    rec_sample_rate: Mutex<u32>,
    output_dir: PathBuf,
    arm_state: Mutex<Vec<bool>>,
    sample_rate: Mutex<u32>,
}

impl AudioEngine {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            stream: Mutex::new(None),
            playback_stream: Mutex::new(None),
            underruns: Arc::new(AtomicU64::new(0)),
            overruns: Arc::new(AtomicU64::new(0)),
            rec_active: Arc::new(AtomicBool::new(false)),
            rec_writers: Arc::new(Mutex::new(Vec::new())),
            rec_sample_rate: Mutex::new(48000),
            output_dir: std::env::temp_dir().join("tracker_recordings"),
            arm_state: Mutex::new(vec![false; 4]),
            sample_rate: Mutex::new(48000),
        }
    }

    pub fn arm_track(&self, id: usize, armed: bool) {
        if let Ok(mut state) = self.arm_state.lock() {
            if id < state.len() {
                state[id] = armed;
            }
        }
    }

    pub fn get_arm_state(&self) -> Vec<bool> {
        self.arm_state.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn start_recording(&self) -> Result<(), String> {
        if self.rec_active.load(Ordering::SeqCst) {
            return Ok(());
        }
        let armed = self.get_arm_state();
        if !armed.iter().any(|&a| a) {
            return Err("No tracks armed".into());
        }
        let sr = *self.rec_sample_rate.lock().unwrap();
        let dir = &self.output_dir;
        std::fs::create_dir_all(dir).map_err(|e| format!("Output dir: {e}"))?;

        let mut writers: Vec<TrackWriter> = Vec::with_capacity(armed.len());
        for (i, &is_armed) in armed.iter().enumerate() {
            if is_armed {
                let path = dir.join(format!("track_{}.wav", i + 1));
                let spec = hound::WavSpec {
                    channels: 1,
                    sample_rate: sr,
                    bits_per_sample: 32,
                    sample_format: hound::SampleFormat::Float,
                };
                let file =
                    std::fs::File::create(&path).map_err(|e| format!("Create {}: {e}", path.display()))?;
                let writer =
                    WavWriter::new(BufWriter::new(file), spec).map_err(|e| format!("WAV init: {e}"))?;
                writers.push(Some(writer));
            } else {
                writers.push(None);
            }
        }
        if let Ok(mut guard) = self.rec_writers.lock() {
            *guard = writers;
        }
        self.rec_active.store(true, Ordering::SeqCst);
        Ok(())
    }

    pub fn stop_recording(&self) -> Result<(), String> {
        self.rec_active.store(false, Ordering::SeqCst);
        if let Ok(mut guard) = self.rec_writers.lock() {
            for w in guard.iter_mut() {
                if let Some(writer) = w.take() {
                    let _ = writer.finalize();
                }
            }
            guard.clear();
        }
        Ok(())
    }

    pub fn recording_status(&self) -> RecordingStatus {
        let writers = self.rec_writers.lock().unwrap();
        let file_count = writers.iter().filter(|w| w.is_some()).count();
        RecordingStatus {
            active: self.rec_active.load(Ordering::Relaxed),
            armed: self.get_arm_state(),
            file_count,
            output_dir: self.output_dir.to_string_lossy().to_string(),
        }
    }

    pub fn start_capture(&self, device_name: &str, app: AppHandle) -> Result<(), String> {
        if self.running.load(Ordering::SeqCst) {
            return Ok(());
        }

        let devices = enumerate_input_devices()?;
        let dev_info = devices
            .iter()
            .find(|d| d.name == device_name)
            .ok_or_else(|| format!("Device not found: {device_name}"))?;

        let host = cpal::default_host();
        let device: cpal::Device = host
            .input_devices()
            .map_err(|e| format!("Failed to enumerate devices: {e}"))?
            .find(|d| {
                d.description()
                    .ok()
                    .map(|desc| desc.name().to_string())
                    .as_deref()
                    == Some(&dev_info.name)
            })
            .ok_or_else(|| format!("Device '{device_name}' no longer available"))?;

        let supported = device
            .default_input_config()
            .map_err(|e| format!("Failed to get input config: {e}"))?;

        let sample_rate: u32 = supported.sample_rate();
        let channels = supported.channels();
        let config: cpal::StreamConfig = supported.config();

        *self.rec_sample_rate.lock().unwrap() = sample_rate;
        *self.sample_rate.lock().unwrap() = sample_rate;

        let ring_capacity = (sample_rate as usize) * (channels as usize) / 2;
        let rb = HeapRb::<f32>::new(ring_capacity);
        let (mut producer, consumer) = rb.split();

        let running = self.running.clone();
        let compute_running = running.clone();
        let overruns = self.overruns.clone();
        let rec_active = self.rec_active.clone();
        let rec_writers = self.rec_writers.clone();

        running.store(true, Ordering::SeqCst);

        let err_name = dev_info.name.clone();
        let stream = device
            .build_input_stream(
                config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    if !running.load(Ordering::Relaxed) {
                        return;
                    }
                    let written = producer.push_slice(data);
                    if written < data.len() {
                        overruns.fetch_add(1, Ordering::Relaxed);
                    }
                },
                move |err| {
                    eprintln!("Audio error on {err_name}: {err}");
                },
                None,
            )
            .map_err(|e| format!("Failed to build input stream: {e}"))?;

        stream.play().map_err(|e| format!("Failed to start stream: {e}"))?;
        *self.stream.lock().unwrap() = Some(stream);

        let compute_underruns = self.underruns.clone();
        let compute_overruns = self.overruns.clone();

        thread::Builder::new()
            .name("audio-engine".into())
            .spawn(move || {
                let mut consumer = consumer;
                let interval = Duration::from_millis(50);

                while compute_running.load(Ordering::Relaxed) {
                    thread::sleep(interval);

                    let available = consumer.occupied_len();
                    if available == 0 {
                        compute_underruns.fetch_add(1, Ordering::Relaxed);
                        let _ = app.emit("level-update", zero_levels(
                            compute_underruns.load(Ordering::Relaxed),
                            compute_overruns.load(Ordering::Relaxed),
                            interval,
                        ));
                        continue;
                    }

                    let ch = channels as usize;
                    let samples_per_read = (available / ch) * ch;
                    let mut buf = vec![0.0_f32; samples_per_read];
                    consumer.pop_slice(&mut buf);

                    // Write to WAV for armed + recording tracks
                    if rec_active.load(Ordering::Relaxed) {
                        if let Ok(mut guard) = rec_writers.lock() {
                            for writer in guard.iter_mut().flatten() {
                                for &s in &buf {
                                    let _ = writer.write_sample(s);
                                }
                            }
                        }
                    }

                    // Compute levels and emit event
                    let (a_peak, a_rms, b_peak, b_rms) = compute_levels(&buf, ch);

                    let is_rec = rec_active.load(Ordering::Relaxed);
                    let _ = app.emit("level-update", LevelUpdatePayload {
                        input_a_peak: a_peak,
                        input_a_rms: a_rms,
                        input_b_peak: b_peak,
                        input_b_rms: b_rms,
                        recording: is_rec,
                        armed_tracks: vec![false; 4],
                        metrics: MetricsPayload {
                            underruns: compute_underruns.load(Ordering::Relaxed),
                            overruns: compute_overruns.load(Ordering::Relaxed),
                            callback_interval_ms: interval.as_secs_f64() * 1000.0,
                        },
                    });

                    let read_dur = buf.len() as f64 / (sample_rate as f64 * channels as f64);
                    if read_dur > interval.as_secs_f64() {
                        compute_overruns.fetch_add(1, Ordering::Relaxed);
                    }
                }
            })
            .map_err(|e| format!("Failed to spawn engine thread: {e}"))?;

        Ok(())
    }

    pub fn stop_capture(&self) {
        let _ = self.stop_recording();
        self.stop_playback();
        self.running.store(false, Ordering::SeqCst);
        *self.stream.lock().unwrap() = None;
    }

    pub fn bounce_tracks(&self) -> Result<String, String> {
        let dir = &self.output_dir;
        let sr = *self.sample_rate.lock().unwrap();

        let mut track_data: Vec<Vec<f32>> = Vec::new();
        for i in 0..4 {
            let path = dir.join(format!("track_{}.wav", i + 1));
            if !path.exists() { continue; }
            let reader = hound::WavReader::open(&path)
                .map_err(|e| format!("Read track {}: {e}", i + 1))?;
            let samples: Vec<f32> = reader.into_samples::<f32>()
                .filter_map(|s| s.ok())
                .collect();
            if !samples.is_empty() {
                track_data.push(samples);
            }
        }

        if track_data.is_empty() {
            return Err("No recorded tracks to bounce".into());
        }

        let max_len = track_data.iter().map(|t| t.len()).max().unwrap_or(0);
        let num_tracks = track_data.len();
        let mut mixed = vec![0.0_f32; max_len];
        for track in &track_data {
            for (i, &sample) in track.iter().enumerate() {
                mixed[i] += sample / num_tracks as f32;
            }
        }

        let bounce_path = dir.join("bounce.wav");
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: sr,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        };
        let mut writer = hound::WavWriter::create(&bounce_path, spec)
            .map_err(|e| format!("Create bounce: {e}"))?;
        for &s in &mixed {
            writer.write_sample(s).map_err(|e| format!("Write bounce: {e}"))?;
        }
        writer.finalize().map_err(|e| format!("Finalize bounce: {e}"))?;

        Ok(bounce_path.to_string_lossy().to_string())
    }

    pub fn start_playback(&self, app: AppHandle) -> Result<(), String> {
        let dir = &self.output_dir;
        let bounce_path = dir.join("bounce.wav");
        let track_path = dir.join("track_1.wav");
        
        let path = if bounce_path.exists() { bounce_path } else { track_path };
        if !path.exists() {
            return Err("No recorded audio found. Record something first.".into());
        }

        let reader = hound::WavReader::open(&path)
            .map_err(|e| format!("Open playback file: {e}"))?;
        let _spec = reader.spec();
        let samples: Vec<f32> = reader.into_samples::<f32>()
            .filter_map(|s| s.ok())
            .collect();
        let total = samples.len();

        let host = cpal::default_host();
        let device = host.default_output_device()
            .ok_or_else(|| "No output device".to_string())?;
        let out_config = device.default_output_config()
            .map_err(|e| format!("Output config: {e}"))?;
        let config: cpal::StreamConfig = out_config.config();

        let pos = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let playback_samples = Arc::new(Mutex::new(samples));

        let stream_pos = pos.clone();
        let stream_samples = playback_samples.clone();
        let stream = device.build_output_stream::<f32, _, _>(
            config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let samples_guard = stream_samples.lock().unwrap();
                let p = stream_pos.load(std::sync::atomic::Ordering::Relaxed);
                let remaining = total.saturating_sub(p);
                let to_write = data.len().min(remaining);
                data[..to_write].copy_from_slice(&samples_guard[p..p + to_write]);
                for s in data[to_write..].iter_mut() { *s = 0.0; }
                stream_pos.store(p + to_write, std::sync::atomic::Ordering::Relaxed);
            },
            move |err| { eprintln!("Playback error: {err}"); },
            None,
        ).map_err(|e| format!("Output stream: {e}"))?;

        stream.play().map_err(|e| format!("Play start: {e}"))?;
        *self.playback_stream.lock().unwrap() = Some(stream);
        let _ = app.emit("playback-started", true);
        Ok(())
    }

    pub fn stop_playback(&self) {
        *self.playback_stream.lock().unwrap() = None;
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Relaxed)
    }
}

fn zero_levels(underruns: u64, overruns: u64, interval: Duration) -> LevelUpdatePayload {
    LevelUpdatePayload {
        input_a_peak: -96.0,
        input_a_rms: -96.0,
        input_b_peak: -96.0,
        input_b_rms: -96.0,
        recording: false,
        armed_tracks: vec![false; 4],
        metrics: MetricsPayload {
            underruns,
            overruns,
            callback_interval_ms: interval.as_secs_f64() * 1000.0,
        },
    }
}

fn compute_levels(buf: &[f32], channels: usize) -> (f32, f32, f32, f32) {
    let mut peaks = vec![0.0_f32; channels];
    let mut sq_sums = vec![0.0_f32; channels];
    let mut counts = vec![0_usize; channels];

    for (i, &sample) in buf.iter().enumerate() {
        let c = i % channels;
        let abs = sample.abs();
        if abs > peaks[c] {
            peaks[c] = abs;
        }
        sq_sums[c] += sample * sample;
        counts[c] += 1;
    }

    let to_dbfs = |v: f32| -> f32 {
        if v <= 0.0 { -96.0 } else { (20.0 * v.log10()).max(-96.0) }
    };

    let a_peak = to_dbfs(peaks.first().copied().unwrap_or(0.0));
    let a_rms = to_dbfs(
        (sq_sums.first().copied().unwrap_or(0.0) / counts.first().copied().unwrap_or(1).max(1) as f32).sqrt(),
    );
    let b_peak = to_dbfs(peaks.get(1).copied().unwrap_or(0.0));
    let b_rms = to_dbfs(
        (sq_sums.get(1).copied().unwrap_or(0.0) / counts.get(1).copied().unwrap_or(1).max(1) as f32).sqrt(),
    );

    (a_peak, a_rms, b_peak, b_rms)
}
