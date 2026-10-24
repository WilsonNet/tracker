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
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};

use super::device::{enumerate_input_devices, AudioDevice};
use super::fx::render::render_mix;
use super::fx::FxSettings;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MixRenderResult {
    pub path: Option<String>,
    pub frames: usize,
    pub duration_sec: f64,
    pub peak_db: f32,
    pub track_gr: Vec<f32>,
    pub master_gr: f32,
    pub limiter_gr: f32,
    pub track_gr_timeline: Vec<Vec<f32>>,
    pub master_gr_timeline: Vec<f32>,
    pub limiter_gr_timeline: Vec<f32>,
}

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
    /// Bumped on every preview/stop so stale watch threads exit.
    playback_generation: Arc<AtomicU64>,
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
            playback_generation: Arc::new(AtomicU64::new(0)),
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
        if !self.running.load(Ordering::SeqCst) {
            return Err("Start CAPTURE before recording".into());
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
                let mut last_flush = Instant::now();

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
                        // Checkpoint the header + data every second so a crash or
                        // kill still leaves a readable take.
                        if last_flush.elapsed() >= Duration::from_secs(1) {
                            if let Ok(mut guard) = rec_writers.lock() {
                                for (writer, _) in guard.iter_mut().flatten() {
                                    let _ = writer.flush();
                                }
                            }
                            last_flush = Instant::now();
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

    pub fn bounce_tracks(&self, settings: FxSettings) -> Result<MixRenderResult, String> {
        let dir = &self.output_dir;
        let sample_rate = *self.sample_rate.lock().unwrap();
        let audio = self.read_track_audio()?;
        if audio.iter().all(|t| t.is_empty()) {
            return Err("No recorded tracks to bounce".into());
        }

        let render = render_mix(&audio, &settings, sample_rate as f32);
        let bounce_path = dir.join("bounce.wav");
        let spec = hound::WavSpec {
            channels: 2,
            sample_rate,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        };
        let mut writer = hound::WavWriter::create(&bounce_path, spec)
            .map_err(|e| format!("Create bounce: {e}"))?;
        for &s in &render.samples {
            writer.write_sample(s).map_err(|e| format!("Write bounce: {e}"))?;
        }
        writer.finalize().map_err(|e| format!("Finalize bounce: {e}"))?;

        let duration = render.duration_seconds(sample_rate as f32) as f64;
        let frames = render.frames;
        let peak_db = render.peak_db;
        let stats = render.stats;
        Ok(MixRenderResult {
            path: Some(bounce_path.to_string_lossy().to_string()),
            frames,
            duration_sec: duration,
            peak_db,
            track_gr: stats.track_gr,
            master_gr: stats.master_gr,
            limiter_gr: stats.limiter_gr,
            track_gr_timeline: stats.track_gr_timeline,
            master_gr_timeline: stats.master_gr_timeline,
            limiter_gr_timeline: stats.limiter_gr_timeline,
        })
    }

    fn read_track_audio(&self) -> Result<Vec<Vec<f32>>, String> {
        let dir = &self.output_dir;
        let mut audio = Vec::with_capacity(4);
        for i in 0..4 {
            let path = dir.join(format!("track_{}.wav", i + 1));
            if !path.exists() {
                audio.push(Vec::new());
                continue;
            }
            let reader = hound::WavReader::open(&path)
                .map_err(|e| format!("Read track {}: {e}", i + 1))?;
            let spec = reader.spec();
            let mut samples: Vec<f32> = reader
                .into_samples::<f32>()
                .filter_map(|s| s.ok())
                .collect();
            // Older takes may be stereo; fold down to mono for the channel strip.
            if spec.channels > 1 {
                let ch = spec.channels as usize;
                samples = samples
                    .chunks(ch)
                    .map(|frame| frame.iter().sum::<f32>() / ch as f32)
                    .collect();
            }
            audio.push(samples);
        }
        Ok(audio)
    }

    /// Render the current mix with effects and play it, without writing a file.
    /// Returns the render stats so the UI can drive its meters.
    pub fn preview_mix(
        &self,
        settings: FxSettings,
        app: AppHandle,
    ) -> Result<MixRenderResult, String> {
        let sample_rate = *self.sample_rate.lock().unwrap();
        let audio = self.read_track_audio()?;
        if audio.iter().all(|t| t.is_empty()) {
            return Err("No recorded audio found. Record something first.".into());
        }
        let render = render_mix(&audio, &settings, sample_rate as f32);
        let frames = render.frames;
        let duration = render.duration_seconds(sample_rate as f32) as f64;
        let peak_db = render.peak_db;
        let stats = render.stats;
        self.play_stereo(render.samples, sample_rate, app)?;

        Ok(MixRenderResult {
            path: None,
            frames,
            duration_sec: duration,
            peak_db,
            track_gr: stats.track_gr,
            master_gr: stats.master_gr,
            limiter_gr: stats.limiter_gr,
            track_gr_timeline: stats.track_gr_timeline,
            master_gr_timeline: stats.master_gr_timeline,
            limiter_gr_timeline: stats.limiter_gr_timeline,
        })
    }

    /// Play interleaved stereo samples through the default output device,
    /// resampling to the device rate and spreading to however many channels
    /// the device wants.
    fn play_stereo(
        &self,
        samples: Vec<f32>,
        render_rate: u32,
        app: AppHandle,
    ) -> Result<(), String> {
        let out_device = cpal::default_host()
            .default_output_device()
            .ok_or_else(|| "No output device".to_string())?;
        let out_config = out_device
            .default_output_config()
            .map_err(|e| format!("Output config: {e}"))?;
        let out_rate = out_config.sample_rate();
        let config: cpal::StreamConfig = out_config.config();
        let channels = config.channels as usize;

        let samples = if out_rate != render_rate {
            resample_linear(&samples, render_rate, out_rate, 2)
        } else {
            samples
        };
        let total_frames = samples.len() / 2;
        let playback_samples = Arc::new(Mutex::new(samples));
        let position = Arc::new(std::sync::atomic::AtomicUsize::new(0));

        let stream_samples = playback_samples.clone();
        let stream_pos = position.clone();
        let stream = out_device
            .build_output_stream::<f32, _, _>(
                config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    let guard = stream_samples.lock().unwrap();
                    let mut p = stream_pos.load(Ordering::Relaxed);
                    let frames_out = data.len() / channels.max(1);
                    for frame in 0..frames_out {
                        let (l, r) = if p < total_frames {
                            (guard[p * 2], guard[p * 2 + 1])
                        } else {
                            (0.0, 0.0)
                        };
                        p += 1;
                        for c in 0..channels {
                            data[frame * channels + c] = match channels {
                                1 => (l + r) * 0.5,
                                _ if c % 2 == 0 => l,
                                _ => r,
                            };
                        }
                    }
                    stream_pos.store(p, Ordering::Relaxed);
                },
                move |err| eprintln!("Playback error: {err}"),
                None,
            )
            .map_err(|e| format!("Output stream: {e}"))?;

        stream.play().map_err(|e| format!("Play start: {e}"))?;
        *self.playback_stream.lock().unwrap() = Some(stream);
        let generation = self.playback_generation.fetch_add(1, Ordering::SeqCst) + 1;
        self.spawn_playback_watch(position, total_frames, app.clone(), generation);
        let _ = app.emit("playback-started", true);
        Ok(())
    }

    fn spawn_playback_watch(
        &self,
        position: Arc<std::sync::atomic::AtomicUsize>,
        total_frames: usize,
        app: AppHandle,
        generation: u64,
    ) {
        let current = self.playback_generation.clone();
        thread::Builder::new()
            .name("playback-watch".into())
            .spawn(move || loop {
                thread::sleep(Duration::from_millis(150));
                // Superseded by a newer preview or an explicit stop.
                if current.load(Ordering::SeqCst) != generation {
                    break;
                }
                if position.load(Ordering::Relaxed) >= total_frames {
                    let _ = app.emit("playback-ended", true);
                    break;
                }
            })
            .ok();
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
        let spec = reader.spec();
        let raw: Vec<f32> = reader
            .into_samples::<f32>()
            .filter_map(|s| s.ok())
            .collect();
        let channels = spec.channels.max(1) as usize;
        let stereo: Vec<f32> = if channels >= 2 {
            raw.chunks(channels)
                .flat_map(|frame| [frame[0], frame[1]])
                .collect()
        } else {
            raw.iter().flat_map(|&s| [s, s]).collect()
        };
        self.play_stereo(stereo, spec.sample_rate, app)
    }

    pub fn stop_playback(&self) {
        self.playback_generation.fetch_add(1, Ordering::SeqCst);
        *self.playback_stream.lock().unwrap() = None;
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Relaxed)
    }
}

fn zero_levels(underruns: u64, overruns: u64, interval: Duration) -> LevelUpdatePayload {    LevelUpdatePayload {
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

/// Linear-interpolation resampler for interleaved audio. Only used to match the
/// output device rate; the render itself stays at the capture rate.
fn resample_linear(samples: &[f32], from: u32, to: u32, channels: usize) -> Vec<f32> {
    if from == to || samples.is_empty() || channels == 0 {
        return samples.to_vec();
    }
    let frames_in = samples.len() / channels;
    if frames_in == 0 {
        return Vec::new();
    }
    let ratio = to as f64 / from as f64;
    let frames_out = (frames_in as f64 * ratio).round() as usize;
    let mut out = Vec::with_capacity(frames_out * channels);
    for i in 0..frames_out {
        let src = i as f64 / ratio;
        let i0 = (src.floor() as usize).min(frames_in - 1);
        let frac = (src - i0 as f64) as f32;
        let i1 = (i0 + 1).min(frames_in - 1);
        for c in 0..channels {
            let a = samples[i0 * channels + c];
            let b = samples[i1 * channels + c];
            out.push(a + (b - a) * frac);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::fx::{DelayParams, EqParams, ReverbParams, TrackMix, WidthParams};

    fn write_tone(dir: &std::path::Path, index: usize, freq: f32, seconds: f32) {
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 48_000,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        };
        let path = dir.join(format!("track_{}.wav", index + 1));
        let mut writer = hound::WavWriter::create(path, spec).unwrap();
        for i in 0..(48_000.0 * seconds) as usize {
            let t = i as f32 / 48_000.0;
            let sample = (t * freq * std::f32::consts::TAU).sin() * 0.7;
            writer.write_sample(sample).unwrap();
        }
        writer.finalize().unwrap();
    }

    #[test]
    fn bounce_renders_stereo_with_the_full_chain() {
        let dir = std::env::temp_dir().join(format!("tracker_bounce_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for (i, freq) in [220.0, 330.0, 440.0, 660.0].iter().enumerate() {
            write_tone(&dir, i, *freq, 1.0);
        }

        let mut engine = AudioEngine::new();
        engine.output_dir = dir.clone();

        let settings = FxSettings {
            tracks: (0..4)
                .map(|i| TrackMix {
                    level: 0.9,
                    pan: -0.6 + i as f32 * 0.4,
                    send_reverb: 0.5,
                    send_delay: 0.25,
                    eq: EqParams { low_db: 4.0, mid_db: -3.0, high_db: 2.0, ..EqParams::default() },
                    comp: crate::audio::fx::CompParams { enabled: true, ..Default::default() },
                    ..TrackMix::default()
                })
                .collect(),
            reverb: ReverbParams { enabled: true, ..Default::default() },
            delay: DelayParams { enabled: true, ..Default::default() },
            width: WidthParams { enabled: true, width: 1.4, ..Default::default() },
            ..FxSettings::default()
        };

        let result = engine.bounce_tracks(settings).expect("bounce failed");
        assert_eq!(result.track_gr_timeline.len(), 4);
        assert!(result.frames > 48_000, "tail should extend past the source");
        assert!(result.peak_db <= -0.29, "peak above ceiling: {}", result.peak_db);

        let path = result.path.expect("bounce path");
        let reader = hound::WavReader::open(&path).expect("open bounce");
        assert_eq!(reader.spec().channels, 2);
        assert_eq!(reader.spec().sample_rate, 48_000);
        let samples: Vec<f32> = reader.into_samples::<f32>().filter_map(|s| s.ok()).collect();
        assert_eq!(samples.len(), result.frames * 2);
        for s in &samples {
            assert!(s.is_finite());
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ui_payload_deserializes_with_ui_only_fields() {
        let json = serde_json::json!({
            "tracks": [{
                "eq": { "enabled": true, "lowDb": 3.0, "midDb": 0.0, "midHz": 1000.0, "midQ": 1.0, "highDb": -2.0 },
                "comp": { "enabled": true, "thresholdDb": -18.0, "ratio": 3.0, "attackMs": 12.0,
                          "releaseMs": 180.0, "kneeDb": 8.0, "makeupDb": 0.0, "mix": 1.0,
                          "autoMakeup": true },
                "sendReverb": 0.4,
                "sendDelay": 0.1,
                "level": 0.8,
                "pan": 0.0,
                "muted": false
            }],
            "masterComp": { "enabled": false, "thresholdDb": -14.0, "ratio": 2.5, "attackMs": 20.0,
                            "releaseMs": 250.0, "kneeDb": 10.0, "makeupDb": 5.0, "mix": 1.0,
                            "autoMakeup": true },
            "reverb": { "enabled": true, "size": 0.6, "decay": 0.5, "tone": 0.5,
                        "predelayMs": 18.0, "returnLevel": 0.45 },
            "delay": { "enabled": true, "timeMs": 320.0, "feedback": 0.35, "tone": 0.55,
                       "pingPong": true, "returnLevel": 0.3, "sync": true, "division": 2 },
            "width": { "enabled": true, "width": 1.25, "bassHz": 140.0 },
            "limiter": { "enabled": true, "ceilingDb": -0.3, "releaseMs": 120.0, "lookaheadMs": 5.0 }
        });
        let settings: FxSettings = serde_json::from_value(json).expect("payload shape");
        assert_eq!(settings.tracks.len(), 1);
        assert_eq!(settings.tracks[0].eq.low_db, 3.0);
        assert!(settings.reverb.enabled);
        assert_eq!(settings.delay.time_ms, 320.0);
        assert!(settings.limiter.enabled);
    }
}
