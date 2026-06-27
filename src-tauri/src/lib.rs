mod audio;

use audio::device::AudioDevice;
use audio::engine::RecordingStatus;
use audio::AudioEngine;
use std::sync::Mutex;

#[tauri::command]
fn list_audio_devices(state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<Vec<AudioDevice>, String> {
    let _state = state.lock().map_err(|e| e.to_string())?;
    audio::device::enumerate_input_devices()
}

#[tauri::command]
fn start_capture(
    app: tauri::AppHandle,
    device_name: String,
    state: tauri::State<'_, Mutex<AudioEngine>>,
) -> Result<(), String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    engine.start_capture(&device_name, app)
}

#[tauri::command]
fn stop_capture(state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<(), String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    engine.stop_capture();
    Ok(())
}

#[tauri::command]
fn capture_status(state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<bool, String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    Ok(engine.is_running())
}

#[tauri::command]
fn arm_track(id: usize, armed: bool, state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<(), String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    engine.arm_track(id, armed);
    Ok(())
}

#[tauri::command]
fn start_recording(state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<(), String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    engine.start_recording()
}

#[tauri::command]
fn stop_recording(state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<(), String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    engine.stop_recording()
}

#[tauri::command]
fn recording_status(state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<RecordingStatus, String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    Ok(engine.recording_status())
}

#[tauri::command]
fn bounce_tracks(state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<String, String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    engine.bounce_tracks()
}

#[tauri::command]
fn start_playback(
    app: tauri::AppHandle,
    state: tauri::State<'_, Mutex<AudioEngine>>,
) -> Result<(), String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    engine.start_playback(app)
}

#[tauri::command]
fn stop_playback(state: tauri::State<'_, Mutex<AudioEngine>>) -> Result<(), String> {
    let engine = state.lock().map_err(|e| e.to_string())?;
    engine.stop_playback();
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default()
        .manage(Mutex::new(AudioEngine::new()))
        .invoke_handler(tauri::generate_handler![
            list_audio_devices,
            start_capture,
            stop_capture,
            capture_status,
            arm_track,
            start_recording,
            stop_recording,
            recording_status,
            bounce_tracks,
            start_playback,
            stop_playback,
        ]);

    #[cfg(feature = "e2e-testing")]
    let builder = builder.plugin(tauri_plugin_playwright::init());

    builder
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
