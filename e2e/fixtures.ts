import { createTauriTest } from '@srsholmes/tauri-playwright';

// NOTE: mock handlers are serialised with `toString()` and evaluated inside the
// page, so every handler must be self-contained — no references to module
// constants or helper functions.

export const { test, expect } = createTauriTest({
  devUrl: 'http://localhost:1420',
  ipcMocks: {
    list_audio_devices: () => [
      {
        id: 'scarlett_0',
        name: 'Scarlett 2i2 USB',
        input_channels: 2,
        channel_names: ['Input 1 Mic/Inst/Line', 'Input 2 Mic/Inst/Line'],
        is_default: true,
        backend: 'PipeWire JACK',
      },
      {
        id: 'builtin_1',
        name: 'Built-in Audio',
        input_channels: 2,
        channel_names: ['IN 1 (L)', 'IN 2 (R)'],
        is_default: false,
        backend: 'PipeWire JACK',
      },
    ],
    capture_status: () => false,
    recording_status: () => ({
      active: false,
      armed: [false, false, false, false],
      file_count: 0,
      output_dir: '/tmp/tracker_recordings',
    }),
    start_capture: () => {},
    stop_capture: () => {},
    arm_track: () => {},
    start_recording: () => {},
    stop_recording: () => {},
    bounce_tracks: () => ({
      path: '/tmp/tracker_recordings/bounce.wav',
      frames: 288000,
      durationSec: 6,
      peakDb: -0.3,
      trackGr: [-4.2, 0, 0, 0],
      masterGr: 0,
      limiterGr: -1.2,
      trackGrTimeline: [
        Array.from({ length: 120 }, (_, i) => -2.4 - 1.8 * Math.abs(Math.sin(i / 7))),
        Array(120).fill(0),
        Array(120).fill(0),
        Array(120).fill(0),
      ],
      masterGrTimeline: Array(120).fill(0),
      limiterGrTimeline: Array(120).fill(-1.2),
    }),
    preview_mix: () => ({
      path: null,
      frames: 288000,
      durationSec: 6,
      peakDb: -0.3,
      trackGr: [-4.2, 0, 0, 0],
      masterGr: 0,
      limiterGr: -1.2,
      trackGrTimeline: [
        Array.from({ length: 120 }, (_, i) => -2.4 - 1.8 * Math.abs(Math.sin(i / 7))),
        Array(120).fill(0),
        Array(120).fill(0),
        Array(120).fill(0),
      ],
      masterGrTimeline: Array(120).fill(0),
      limiterGrTimeline: Array(120).fill(-1.2),
    }),
    start_playback: () => {},
    stop_playback: () => {},
  },
});
