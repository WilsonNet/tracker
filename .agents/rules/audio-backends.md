---
trigger: glob
globs:
  - odin/src/capture*.odin
  - odin/src/engine*.odin
  - odin/src/jack_*.odin
  - odin/src/monitor.odin
---

# Audio Backend Rules

1. **Primary engine (`vendor:miniaudio`)**:
   - Linux uses PipeWire / PulseAudio / ALSA. Capture configures `cfg.pulse.channelMap = capture_pulse_channel_map(channels)` inside `platform_audio_configure_capture` so multi-channel interfaces (e.g. Scarlett 4i4) are not speaker-remixed.
   - macOS uses CoreAudio natively with no PulseAudio remixing (`platform_audio_configure_capture` is a no-op).
   - Both OSes open devices at native width first (`capture_open_attempts`) and keep hardware inputs `1..N` in order (`capture_copy_frames`).

2. **Cooperative JACK**:
   - JACK is Linux-only (`platform_supports_jack()` returns `true` on Linux, `false` on macOS/other).
   - Keep JACK FFI and session ring/writer logic isolated in `jack_capture_linux.odin` and `jack_session_linux.odin`.

3. **Real-time callback safety**:
   - `proc "c"` callbacks (`capture_callback`, `recorder_callback`, `preview_callback`, `jack_session_process`) have no Odin context.
   - Helpers called from audio callbacks must be marked `proc "contextless"`, perform zero allocations, and avoid calling contextful procedures.
