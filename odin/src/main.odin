// tracker-odin: native multitrack recorder core.
//
// Phase 1 vertical slice: device enumeration, hardware capture to per-channel
// float WAVs, an offline EQ -> compressor -> fader/pan -> master comp ->
// limiter mixdown, and WAV inspection. The graphical shell comes next; see
// odin/ROADMAP.md.

package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import dsp "dsp"
import ui "ui"

VERSION :: "0.1.0-phase1"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		usage()
		os.exit(1)
	}

	ok := true
	switch args[1] {
	case "devices":
		ok = list_capture_devices()
	case "record":
		ok = run_record(args[2:])
	case "tone":
		ok = run_tone(args[2:])
	case "render":
		ok = run_render(args[2:])
	case "info":
		if len(args) < 3 {
			fmt.eprintln("usage: tracker-odin info FILE.wav")
			ok = false
		} else {
			ok = wav_print_info(args[2])
		}
	case "selftest":
		ok = run_selftest()
	case "ui":
		ok = run_ui_window(args[2:])
	case "ui-shot":
		ok = run_ui_shot(args[2:])
	case "ui-test":
		ok = run_ui_test(args[2:])
	case "bounce":
		ok = run_bounce(args[2:])
	case "version", "--version":
		fmt.printfln("tracker-odin %s", VERSION)
	case "help", "--help", "-h":
		usage()
	case:
		fmt.eprintfln("unknown command: %s", args[1])
		usage()
		ok = false
	}

	if !ok {
		os.exit(1)
	}
}

usage :: proc() {
	fmt.println(`tracker-odin - native multitrack recorder core

usage:
  tracker-odin devices
  tracker-odin record --seconds 5 --out DIR [--channels 2] [--device INDEX] [--rate 48000]
  tracker-odin tone   --out FILE [--seconds 3] [--freq 440] [--amp 0.5] [--channels 1]
  tracker-odin render --in DIR_OR_FILE --out FILE [chain options]
  tracker-odin bounce --session DIR [--out FILE]
  tracker-odin info   FILE.wav
  tracker-odin selftest
  tracker-odin ui
  tracker-odin ui-shot --out FILE [--fx|--palette|--io|--bounce|--playing|--recording]
  tracker-odin ui-test --script FILE.json --out DIR
  tracker-odin version

chain options for render:
  --level 0.8          track fader (unity = 1.0)
  --pan 0              -1 left .. 0 centre .. +1 right
  --eq-low 0           low shelf gain, dB (110 Hz)
  --eq-mid 0           mid bell gain, dB
  --eq-mid-hz 1000     mid bell centre, Hz
  --eq-mid-q 1         mid bell width
  --eq-high 0          high shelf gain, dB (7.5 kHz)
  --comp-threshold -18 compressor threshold, dBFS
  --comp-ratio 3       compressor ratio
  --comp-attack 12     compressor attack, ms
  --comp-release 180   compressor release, ms
  --ceiling -0.3       limiter ceiling, dBFS
  --no-comp            bypass track compressor
  --no-limiter         bypass master limiter
  --flat               bypass EQ, compressor and limiter`)
}

// ---------------------------------------------------------------- arguments

@(private)
flag_value :: proc(args: []string, name: string) -> (string, bool) {
	for arg, i in args {
		if arg == name {
			if i + 1 < len(args) {
				return args[i + 1], true
			}
			return "", false
		}
		if len(arg) > len(name) && arg[len(name)] == '=' && strings.has_prefix(arg, name) {
			return arg[len(name) + 1:], true
		}
	}
	return "", false
}

@(private)
has_flag :: proc(args: []string, name: string) -> bool {
	for arg in args {
		if arg == name {
			return true
		}
	}
	return false
}

@(private)
flag_string :: proc(args: []string, name: string, fallback: string) -> string {
	if value, ok := flag_value(args, name); ok {
		return value
	}
	return fallback
}

@(private)
flag_f32 :: proc(args: []string, name: string, fallback: f32) -> f32 {
	if value, ok := flag_value(args, name); ok {
		if parsed, pok := strconv.parse_f32(value); pok {
			return parsed
		}
		fmt.eprintfln("ignoring non-numeric %s=%s", name, value)
	}
	return fallback
}

@(private)
flag_int :: proc(args: []string, name: string, fallback: int) -> int {
	if value, ok := flag_value(args, name); ok {
		if parsed, pok := strconv.parse_int(value); pok {
			return parsed
		}
		fmt.eprintfln("ignoring non-integer %s=%s", name, value)
	}
	return fallback
}

// ---------------------------------------------------------------- commands

@(private)
ensure_dir :: proc(path: string) {
	if !os.exists(path) {
		_ = os.make_directory(path)
	}
}

@(private)
run_tone :: proc(args: []string) -> bool {
	out := flag_string(args, "--out", "tone.wav")
	seconds := flag_f32(args, "--seconds", 3.0)
	freq := flag_f32(args, "--freq", 440.0)
	amp := clamp(flag_f32(args, "--amp", 0.5), 0.0, 1.0)
	channels := max(flag_int(args, "--channels", 1), 1)
	rate := u32(max(flag_int(args, "--rate", 48_000), 8_000))

	if seconds <= 0.0 {
		fmt.eprintln("--seconds must be positive")
		return false
	}

	frames := int(seconds * f32(rate))
	buf := make([]f32, frames * channels)
	defer delete(buf)

	fade := min(int(0.01 * f32(rate)), frames / 2)
	for i in 0 ..< frames {
		gain: f32 = 1.0
		if i < fade {
			gain = f32(i) / f32(fade)
		} else if i >= frames - fade {
			gain = f32(frames - i) / f32(fade)
		}
		v := amp * gain * math.sin(f32(i) * freq * f32(math.TAU) / f32(rate))
		for c in 0 ..< channels {
			buf[i * channels + c] = v
		}
	}

	if !wav_write(out, rate, u32(channels), buf) {
		fmt.eprintfln("cannot write %s", out)
		return false
	}
	fmt.printfln("wrote %s  %d Hz  %d ch  %.2f s  %.1f Hz", out, rate, channels, seconds, freq)
	return true
}

@(private)
run_record :: proc(args: []string) -> bool {
	out := flag_string(args, "--out", "session")
	seconds := flag_f32(args, "--seconds", 5.0)
	channels := max(flag_int(args, "--channels", 2), 1)
	rate := u32(max(flag_int(args, "--rate", 48_000), 8_000))
	device := flag_int(args, "--device", -1)
	use_jack := has_flag(args, "--jack")

	ensure_dir(out)
	if use_jack {
		fmt.printfln("recording %.1f s, %d channel(s) at %d Hz from JACK into %s", seconds, channels, rate, out)
	} else {
		fmt.printfln("recording %.1f s, %d channel(s) at %d Hz into %s", seconds, channels, rate, out)
	}

	result: Capture_Result
	ok: bool
	if use_jack {
		ports := jack_port_names()
		defer {
			for p in ports {
				delete(p)
			}
			delete(ports)
		}
		result, ok = jack_record(seconds, channels, rate, ports)
	} else {
		result, ok = capture_record(seconds, channels, rate, device)
	}
	if !ok {
		return false
	}
	defer capture_destroy(&result)

	fmt.printfln("captured %d frames at %d Hz (short by %d)", result.frames, result.rate, result.short)
	if !write_capture_tracks(&result, out) {
		return false
	}
	peak, rms := dsp.peak_rms_db(result.samples, result.channels)
	fmt.printfln("session peak %.2f dBFS  rms %.2f dBFS", peak, rms)
	return true
}

@(private)
collect_track_paths :: proc(spec: string) -> []string {
	if strings.has_suffix(spec, ".wav") {
		paths := make([]string, 1)
		paths[0] = strings.clone(spec)
		return paths
	}
	count := 0
	for i in 1 ..= 16 {
		if os.exists(fmt.tprintf("%s/track%d.wav", spec, i)) {
			count += 1
		}
	}
	paths := make([]string, count)
	n := 0
	for i in 1 ..= 16 {
		path := fmt.aprintf("%s/track%d.wav", spec, i)
		if os.exists(path) {
			paths[n] = path
			n += 1
		} else {
			delete(path)
		}
	}
	return paths
}

@(private)
run_render :: proc(args: []string) -> bool {
	in_spec, has_in := flag_value(args, "--in")
	out, has_out := flag_value(args, "--out")
	if !has_in || !has_out {
		fmt.eprintln("render needs --in DIR_OR_FILE and --out FILE")
		return false
	}

	paths := collect_track_paths(in_spec)
	defer {
		for path in paths {
			delete(path)
		}
		delete(paths)
	}
	if len(paths) == 0 {
		fmt.eprintfln("no track WAVs found in %s", in_spec)
		return false
	}

	tracks := make([][]f32, len(paths))
	defer {
		for track in tracks {
			delete(track)
		}
		delete(tracks)
	}

	rate: u32
	for path, i in paths {
		wav, ok := wav_read(path)
		if !ok {
			fmt.eprintfln("cannot read %s", path)
			return false
		}
		if i == 0 {
			rate = wav.sample_rate
		} else if wav.sample_rate != rate {
			fmt.eprintfln("%s is %d Hz, expected %d Hz", path, wav.sample_rate, rate)
			wav_destroy(&wav)
			return false
		}

		mono := make([]f32, wav.frames)
		channels := int(wav.channels)
		for frame in 0 ..< wav.frames {
			sum: f32 = 0.0
			for ch in 0 ..< channels {
				sum += wav.samples[frame * channels + ch]
			}
			mono[frame] = sum / f32(channels)
		}
		tracks[i] = mono
		wav_destroy(&wav)
	}

	flat := has_flag(args, "--flat")
	settings := dsp.fx_settings_default()
	settings.limiter.enabled = !flat && !has_flag(args, "--no-limiter")
	settings.limiter.ceiling_db = flag_f32(args, "--ceiling", settings.limiter.ceiling_db)
	settings.tracks = make([]dsp.Track_Mix, len(tracks))
	defer delete(settings.tracks)

	level := flag_f32(args, "--level", 0.8)
	pan := clamp(flag_f32(args, "--pan", 0.0), -1.0, 1.0)
	eq_low := flag_f32(args, "--eq-low", 0.0)
	eq_mid := flag_f32(args, "--eq-mid", 0.0)
	eq_high := flag_f32(args, "--eq-high", 0.0)

	for i in 0 ..< len(tracks) {
		tm := dsp.track_mix_default()
		tm.level = level
		tm.pan = pan
		tm.comp = dsp.comp_params_default()
		tm.comp.enabled = !flat && !has_flag(args, "--no-comp")
		tm.comp.threshold_db = flag_f32(args, "--comp-threshold", tm.comp.threshold_db)
		tm.comp.ratio = flag_f32(args, "--comp-ratio", tm.comp.ratio)
		tm.comp.attack_ms = flag_f32(args, "--comp-attack", tm.comp.attack_ms)
		tm.comp.release_ms = flag_f32(args, "--comp-release", tm.comp.release_ms)
		tm.eq = dsp.Eq_Params {
			enabled  = !flat,
			low_db   = eq_low,
			mid_db   = eq_mid,
			mid_hz   = flag_f32(args, "--eq-mid-hz", 1_000.0),
			mid_q    = flag_f32(args, "--eq-mid-q", 1.0),
			high_db  = eq_high,
		}
		settings.tracks[i] = tm
	}

	out_mix := dsp.render_mix(tracks, settings, f32(rate))
	defer dsp.render_destroy(&out_mix)

	if !wav_write(out, rate, 2, out_mix.samples) {
		fmt.eprintfln("cannot write %s", out)
		return false
	}

	fmt.printfln("rendered %s  %d Hz  stereo  %.3f s", out, rate, f32(out_mix.frames) / f32(rate))
	fmt.printfln("  peak %.2f dBFS", out_mix.peak_db)
	for gr, i in out_mix.stats.track_gr {
		fmt.printfln("  track %d comp GR %.2f dB", i + 1, gr)
	}
	fmt.printfln("  master comp GR %.2f dB", out_mix.stats.master_gr)
	fmt.printfln("  limiter GR %.2f dB", out_mix.stats.limiter_gr)
	return true
}

@(private)
run_selftest :: proc() -> bool {
	rate: u32 = 48_000
	frames := int(2.0 * f32(rate))
	tracks := make([][]f32, 2)
	defer {
		for track in tracks {
			delete(track)
		}
		delete(tracks)
	}

	for ch in 0 ..< 2 {
		tracks[ch] = make([]f32, frames)
		freq := f32(220.0) if ch == 0 else f32(330.0)
		for i in 0 ..< frames {
			tracks[ch][i] = 0.7 * math.sin(f32(i) * freq * f32(math.TAU) / f32(rate))
		}
	}

	settings := dsp.fx_settings_default()
	settings.tracks = make([]dsp.Track_Mix, 2)
	defer delete(settings.tracks)
	for i in 0 ..< 2 {
		tm := dsp.track_mix_default()
		tm.level = 1.1
		tm.pan = -0.35 if i == 0 else 0.35
		tm.eq.low_db = 3.0
		tm.eq.high_db = -2.0
		settings.tracks[i] = tm
	}

	out := dsp.render_mix(tracks, settings, f32(rate))
	defer dsp.render_destroy(&out)

	ceiling_db := settings.limiter.ceiling_db
	if out.peak_db > ceiling_db + 0.01 {
		fmt.eprintfln("FAIL: peak %.2f dBFS exceeds ceiling %.2f dBFS", out.peak_db, ceiling_db)
		return false
	}
	if out.stats.limiter_gr > -1.0 {
		fmt.eprintfln("FAIL: limiter did not engage (GR %.2f dB)", out.stats.limiter_gr)
		return false
	}

	path := "/tmp/tracker-odin-selftest.wav"
	if !wav_write(path, rate, 2, out.samples) {
		fmt.eprintln("FAIL: cannot write selftest WAV")
		return false
	}
	readback, ok := wav_read(path)
	if !ok {
		fmt.eprintln("FAIL: cannot read selftest WAV")
		return false
	}
	defer wav_destroy(&readback)
	if readback.frames != out.frames {
		fmt.eprintfln("FAIL: readback has %d frames, expected %d", readback.frames, out.frames)
		return false
	}

	fmt.printfln("PASS: rendered %d frames, peak %.2f dBFS, limiter GR %.2f dB", out.frames, out.peak_db, out.stats.limiter_gr)
	fmt.printfln("      wrote %s", path)
	return true
}

@(private)
run_bounce :: proc(args: []string) -> bool {
	e: Engine
	if !engine_init(&e, args) {
		return false
	}
	defer engine_destroy(&e)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	if os.exists(e.project_path) {
		if !project_load(&a, e.session_dir, e.project_path) {
			fmt.eprintln("cannot load project")
			return false
		}
	}
	if !engine_load_tracks(&e, &a) {
		fmt.eprintln("no tracks in session")
		return false
	}
	out_path := flag_string(args, "--out", e.bounce_path)
	out, ok := engine_render_mix(&e, &a)
	if !ok {
		fmt.eprintln("nothing to render")
		return false
	}
	defer dsp.render_destroy(&out)
	if !wav_write(out_path, e.sample_rate, 2, out.samples) {
		fmt.eprintfln("cannot write %s", out_path)
		return false
	}
	fmt.printfln("bounced %s  %.2f s  peak %.2f dBFS", out_path, f32(out.frames) / f32(e.sample_rate), out.peak_db)
	for gr, i in out.stats.track_gr {
		fmt.printfln("  track %d comp GR %.2f dB", i + 1, gr)
	}
	fmt.printfln("  master GR %.2f dB  limiter GR %.2f dB", out.stats.master_gr, out.stats.limiter_gr)
	return true
}
