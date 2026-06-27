import { createTauriTest } from '@srsholmes/tauri-playwright';
import type { AudioDeviceInfo, LevelUpdate, RecordingStatus } from '../src/types/types.ts';

const mockDevices: AudioDeviceInfo[] = [
  { id: 'scarlett_0', name: 'Scarlett 2i2 USB', input_channels: 2, is_default: true },
  { id: 'builtin_1', name: 'Built-in Audio', input_channels: 2, is_default: false },
];

export const { test, expect } = createTauriTest({
  devUrl: 'http://localhost:1420',
  ipcMocks: {
    list_audio_devices: () => mockDevices,
    capture_status: () => false,
    recording_status: () => ({ active: false, armed: [false, false, false, false], file_count: 0, output_dir: '/tmp/tracker_recordings' }),
    start_capture: () => {},
    stop_capture: () => {},
    arm_track: () => {},
    start_recording: () => {},
    stop_recording: () => {},
    bounce_tracks: () => '/tmp/tracker_recordings/bounce.wav',
    start_playback: () => {},
    stop_playback: () => {},
  },
});
