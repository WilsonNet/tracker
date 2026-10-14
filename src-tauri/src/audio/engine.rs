use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use hound::WavWriter;
use ringbuf::traits::*;
use ringbuf::{HeapCons, HeapRb};
use serde::Serialize;
use std::io::BufWriter;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

use super::device::{enumerate_input_devices, AudioDevice};

#[derive(Debug, Clone, Serialize)]
pub struct LevelUpdatePayload {
    pub input_peaks: Vec<f32>,
    pub input_rms: Vec<f32>,
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

type TrackWriter = Option<(WavWriter<BufWriter<std::fs::File>>, usize)>;

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
    arm_channels: Mutex<Vec<usize>>,
    sample_rate: Mutex<u32>,
    #[cfg(target_os = "linux")]
    jack_client: Mutex<Option<jack::AsyncClient<(), super::jack::JackHandler>>>,
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
            arm_channels: Mutex::new((0..4).collect()),
            sample_rate: Mutex::new(48000),
            #[cfg(target_os = "linux")]
            jack_client: Mutex::new(None),
        }
    }

    pub fn arm_track(&self, id: usize, armed: bool, channel: usize) {
        if let Ok(mut state) = self.arm_state.lock() {
            if id < state.len() {
                state[id] = armed;
            }
        }
        if let Ok(mut channels) = self.arm_channels.lock() {
            if id < channels.len() {
                channels[id] = channel;
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

        let track_channels = self.arm_channels.lock().map(|c| c.clone()).unwrap_or_default();
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
                let channel = track_channels.get(i).copied().unwrap_or(i);
                writers.push(Some((writer, channel)));
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
                if let Some((writer, _)) = w.take() {
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

        #[cfg(target_os = "linux")]
        if dev_info.pcm_id == "jack" {
            return self.start_jack_capture(dev_info, app);
        }

        self.start_cpal_capture(dev_info, app)
    }

    /// Capture through pipewire-jack: connect input ports to the selected
    /// device's capture ports (Ardour-style, cooperative with other clients).
    #[cfg(target_os = "linux")]
    fn start_jack_capture(&self, dev_info: &AudioDevice, app: AppHandle) -> Result<(), String> {
        let node = dev_info
            .node
            .clone()
            .ok_or_else(|| "Missing JACK client name".to_string())?;
        let channels = (dev_info.input_channels as usize).max(1);

        let sample_rate = {
            let (probe, _status) =
                jack::Client::new("tracker-probe", jack::ClientOptions::NO_START_SERVER)
                    .map_err(|e| format!("JACK server: {e}"))?;
            probe.sample_rate()
        };
        *self.rec_sample_rate.lock().unwrap() = sample_rate;
        *self.sample_rate.lock().unwrap() = sample_rate;

        let ring_capacity = sample_rate as usize * channels / 2;
        let rb = HeapRb::<f32>::new(ring_capacity);
        let (producer, consumer) = rb.split();

        self.running.store(true, Ordering::SeqCst);
        self.spawn_level_thread(consumer, app, channels, sample_rate)?;

        let client = super::jack::start(
            &node,
            channels,
            producer,
            self.running.clone(),
            self.overruns.clone(),
        )?;
        *self.jack_client.lock().unwrap() = Some(client);
        Ok(())
    }

    fn start_cpal_capture(&self, dev_info: &AudioDevice, app: AppHandle) -> Result<(), String> {
        let device = super::device::find_cpal_device(dev_info)?;

        let supported = device
            .default_input_config()
            .map_err(|e| format!("Failed to get input config: {e}"))?;

        let sample_rate: u32 = supported.sample_rate();
        let mut config: cpal::StreamConfig = supported.config();
        // Capture all hardware channels so each track can pick its own input
        config.channels = dev_info.input_channels.max(1);
        if dev_info.pcm_id == "pipewire" {
            // The pipewire ALSA plugin under-delivers with the default buffer size
            config.buffer_size = cpal::BufferSize::Fixed(1024);
        }
        let channels = config.channels;

        *self.rec_sample_rate.lock().unwrap() = sample_rate;
        *self.sample_rate.lock().unwrap() = sample_rate;

        let ring_capacity = (sample_rate as usize) * (channels as usize) / 2;
        let rb = HeapRb::<f32>::new(ring_capacity);
        let (mut producer, consumer) = rb.split();

        let running = self.running.clone();
        let overruns = self.overruns.clone();

        running.store(true, Ordering::SeqCst);

        // Target a specific PipeWire source cooperatively (pipewire ALSA plugin).
        #[cfg(target_os = "linux")]
        if let Some(node) = &dev_info.node {
            std::env::set_var("PIPEWIRE_NODE", node);
        }

        let err_name = dev_info.name.clone();
        let stream_result = device.build_input_stream(
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
        );

        #[cfg(target_os = "linux")]
        std::env::remove_var("PIPEWIRE_NODE");

        let stream =
            stream_result.map_err(|e| format!("Failed to build input stream: {e}"))?;

        stream.play().map_err(|e| format!("Failed to start stream: {e}"))?;
        *self.stream.lock().unwrap() = Some(stream);

        self.spawn_level_thread(consumer, app, channels as usize, sample_rate)?;

        Ok(())
    }

    /// Consume interleaved samples, write armed tracks' channels to WAV and
    /// stream per-channel levels to the UI. Shared by the cpal and JACK paths.
    fn spawn_level_thread(
        &self,
        consumer: HeapCons<f32>,
        app: AppHandle,
        channels: usize,
        sample_rate: u32,
    ) -> Result<(), String> {
        let running = self.running.clone();
        let underruns = self.underruns.clone();
        let overruns = self.overruns.clone();
        let rec_active = self.rec_active.clone();
        let rec_writers = self.rec_writers.clone();

        thread::Builder::new()
            .name("audio-engine".into())
            .spawn(move || {
                let mut consumer = consumer;
                let interval = Duration::from_millis(50);

                while running.load(Ordering::Relaxed) {
                    thread::sleep(interval);

                    let available = consumer.occupied_len();
                    if available == 0 {
                        underruns.fetch_add(1, Ordering::Relaxed);
                        let _ = app.emit("level-update", zero_levels(
                            underruns.load(Ordering::Relaxed),
                            overruns.load(Ordering::Relaxed),
                            interval,
                        ));
                        continue;
                    }

                    let ch = channels;
                    let samples_per_read = (available / ch) * ch;
                    let mut buf = vec![0.0_f32; samples_per_read];
                    consumer.pop_slice(&mut buf);

                    // Write to WAV for armed + recording tracks
                    if rec_active.load(Ordering::Relaxed) {
                        if let Ok(mut guard) = rec_writers.lock() {
                            for (writer, track_ch) in guard.iter_mut().flatten() {
                                let track_ch = *track_ch % ch;
                                for (idx, &s) in buf.iter().enumerate() {
                                    if idx % ch == track_ch {
                                        let _ = writer.write_sample(s);
                                    }
                                }
                            }
                        }
                    }

                    // Compute levels and emit event
                    let (peaks, rms) = compute_levels(&buf, ch);

                    let is_rec = rec_active.load(Ordering::Relaxed);
                    let _ = app.emit("level-update", LevelUpdatePayload {
                        input_peaks: peaks,
                        input_rms: rms,
                        recording: is_rec,
                        armed_tracks: vec![false; 4],
                        metrics: MetricsPayload {
                            underruns: underruns.load(Ordering::Relaxed),
                            overruns: overruns.load(Ordering::Relaxed),
                            callback_interval_ms: interval.as_secs_f64() * 1000.0,
                        },
                    });

                    let read_dur = buf.len() as f64 / (sample_rate as f64 * channels as f64);
                    if read_dur > interval.as_secs_f64() * 1.5 {
                        overruns.fetch_add(1, Ordering::Relaxed);
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
        #[cfg(target_os = "linux")]
        {
            *self.jack_client.lock().unwrap() = None;
        }
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
        input_peaks: Vec::new(),
        input_rms: Vec::new(),
        recording: false,
        armed_tracks: vec![false; 4],
        metrics: MetricsPayload {
            underruns,
            overruns,
            callback_interval_ms: interval.as_secs_f64() * 1000.0,
        },
    }
}

fn compute_levels(buf: &[f32], channels: usize) -> (Vec<f32>, Vec<f32>) {
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

    let peak_db = peaks.iter().map(|&p| to_dbfs(p)).collect();
    let rms_db = sq_sums
        .iter()
        .zip(counts.iter())
        .map(|(&s, &n)| to_dbfs((s / n.max(1) as f32).sqrt()))
        .collect();

    (peak_db, rms_db)
}
