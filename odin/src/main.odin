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

VERSION :: "1.0.0"

MAX_CLI_SECONDS :: 3_600.0
MAX_CLI_CHANNELS :: 32
MAX_CLI_RATE :: 192_000
// The window, ui-shot and ui-test share the layout's minimum frame; below it
// the header and the fourth strip are clipped.
MIN_CLI_WIDTH :: ui.UI_MIN_WIDTH
MIN_CLI_HEIGHT :: ui.UI_MIN_HEIGHT
MAX_CLI_DIM :: 4_096
MAX_CLI_TONE_SAMPLES :: 64_000_000

main :: proc() {
	args := os.args
	if len(args) < 2 {
		usage(os.stderr)
		os.exit(1)
	}

	ok := true
	switch args[1] {
	case "devices":
		ok = len(args) == 2 && list_capture_devices()
		if len(args) != 2 {
			fmt.eprintln("devices takes no arguments")
		}
	case "record":
		ok = run_record(args[2:])
	case "tone":
		ok = run_tone(args[2:])
	case "render":
		ok = run_render(args[2:])
	case "info":
		if len(args) != 3 {
			fmt.eprintln("usage: tracker-odin info FILE.wav")
			ok = false
		} else {
			ok = wav_print_info(args[2])
		}
	case "selftest":
		if len(args) != 2 {
			fmt.eprintln("selftest takes no arguments")
			ok = false
		} else {
			ok = run_selftest()
		}
	case "ui":
		if !validate_flags(args[2:], []string{"--session", "--width", "--height", "--ui-scale", "--open", "--latency-ms", "--control-port"}, []string{"--demo", "--jack", "--a11y-log"}) ||
		   !validate_numbers(args[2:], []string{"--ui-scale", "--latency-ms"}, []string{"--width", "--height", "--control-port"}) {
			ok = false
		} else {
			w := flag_int(args[2:], "--width", 1180)
			h := flag_int(args[2:], "--height", 760)
			if !cli_window_size_ok(w, h) {
				ok = false
			} else if session, has_session := flag_value(args[2:], "--session"); has_session && !ensure_dir(session) {
				ok = false
			} else {
				ok = run_ui_window(args[2:])
			}
		}
	case "ui-shot":
		ok = run_ui_shot(args[2:])
	case "ui-test":
		ok = run_ui_test(args[2:])
	case "bounce":
		ok = run_bounce(args[2:])
	case "comp":
		ok = run_comp(args[2:])
	case "version", "--version":
		fmt.printfln("tracker-odin %s", VERSION)
	case "help", "--help", "-h":
		usage()
	case:
		fmt.eprintfln("unknown command: %s", args[1])
		fmt.eprintln("run `tracker-odin help` for usage")
		ok = false
	}

	if !ok {
		os.exit(1)
	}
}

usage :: proc(f: ^os.File = os.stdout) {
	fmt.fprintln(f, `tracker-odin - native multitrack recorder core

usage:
  tracker-odin devices
  tracker-odin record --seconds 5 --out DIR [--channels 2] [--device INDEX] [--rate 48000] [--jack]
  tracker-odin tone   --out FILE [--seconds 3] [--freq 440] [--amp 0.5] [--channels 1]
  tracker-odin render --in DIR_OR_FILE --out FILE [chain options]
  tracker-odin bounce --session DIR [--out FILE]
  tracker-odin comp --session DIR --track N --list
  tracker-odin comp --session DIR --track N --select ID
  tracker-odin comp --session DIR --track N --take ID --start FRAME --end FRAME
  tracker-odin comp --session DIR --track N --clear
  tracker-odin info   FILE.wav
  tracker-odin selftest
  tracker-odin ui [--session DIR] [--ui-scale 1|1.25|1.5|2|3] [--demo] [--open FILE]
                  [--jack] [--a11y-log] [--latency-ms N] [--width W --height H]
                  [--control-port PORT]
  tracker-odin ui-shot --out FILE [--scale 1|1.25|1.5|2|3] [--width W --height H]
                  [--fx [--master]|--palette|--io|--bounce] [--playing|--recording]
                  [--three] [--click]
  tracker-odin ui-test --script FILE.json --out DIR [--scale 1|1.25|1.5|2|3]
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

// Validate the shape of a command line before touching the filesystem. Value
// options accept `--key value` and `--key=value`; switch options take neither.
// Negative numbers and paths containing spaces are ordinary single arguments.
@(private)
flag_name_in :: proc(names: []string, name: string) -> bool {
	for n in names {
		if n == name {
			return true
		}
	}
	return false
}

@(private)
validate_flags :: proc(args: []string, values, switches: []string) -> bool {
	i := 0
	for i < len(args) {
		arg := args[i]
		if !strings.has_prefix(arg, "--") {
			fmt.eprintfln("unexpected argument %q", arg)
			return false
		}

		name := arg
		value: string
		has_value := false
		if eq := strings.index_byte(arg, '='); eq >= 0 {
			name = arg[:eq]
			value = arg[eq + 1:]
			has_value = true
		}

		if flag_name_in(switches, name) {
			if has_value {
				fmt.eprintfln("%s takes no value", name)
				return false
			}
			i += 1
			continue
		}
		if !flag_name_in(values, name) {
			fmt.eprintfln("unknown option %s", name)
			return false
		}
		if has_value {
			if value == "" {
				fmt.eprintfln("missing value for %s", name)
				return false
			}
			i += 1
		} else {
			if i + 1 >= len(args) || args[i + 1] == "" || strings.has_prefix(args[i + 1], "--") {
				fmt.eprintfln("missing value for %s", name)
				return false
			}
			i += 2
		}
	}
	return true
}

// Rejects present-but-malformed numeric options (non-numeric, NaN, Inf)
// before a command acts on them. flag_f32/flag_int fall back to a default for
// a bad value, which is right for project data but wrong for a command line:
// `tone --seconds abc` must not silently write a 3 s file.
@(private)
validate_numbers :: proc(args: []string, floats, ints: []string) -> bool {
	for name in floats {
		value, present := flag_value(args, name)
		if !present {
			continue
		}
		parsed, pok := strconv.parse_f32(value)
		if !pok || !f32_is_finite(parsed) {
			fmt.eprintfln("%s needs a finite number, got %q", name, value)
			return false
		}
	}
	for name in ints {
		value, present := flag_value(args, name)
		if !present {
			continue
		}
		if _, pok := strconv.parse_int(value, 10); !pok {
			fmt.eprintfln("%s needs an integer, got %q", name, value)
			return false
		}
	}
	return true
}

@(private)
cli_window_size_ok :: proc(w, h: int) -> bool {
	if w < MIN_CLI_WIDTH || w > MAX_CLI_DIM || h < MIN_CLI_HEIGHT || h > MAX_CLI_DIM {
		fmt.eprintfln("--width must be %d..%d and --height %d..%d", MIN_CLI_WIDTH, MAX_CLI_DIM, MIN_CLI_HEIGHT, MAX_CLI_DIM)
		return false
	}
	return true
}

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
f32_is_finite :: proc(v: f32) -> bool {
	return !math.is_nan(v) && !math.is_inf(v)
}

@(private)
flag_f32 :: proc(args: []string, name: string, fallback: f32) -> f32 {
	if value, ok := flag_value(args, name); ok {
		if parsed, pok := strconv.parse_f32(value); pok {
			if !f32_is_finite(parsed) {
				fmt.eprintfln("ignoring non-finite %s=%s", name, value)
				return fallback
			}
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

// Create a directory and any missing parents. Existing directories are fine;
// an existing non-directory is an error so callers do not fail later with a
// confusing write error.
@(private)
ensure_dir :: proc(path: string) -> bool {
	if path == "" {
		fmt.eprintln("cannot create an empty directory path")
		return false
	}
	if os.exists(path) {
		if os.is_directory(path) {
			return true
		}
		fmt.eprintfln("%s exists and is not a directory", path)
		return false
	}
	if err := os.make_directory_all(path); err != nil {
		fmt.eprintfln("cannot create %s: %v", path, err)
		return false
	}
	return true
}

@(private)
run_tone :: proc(args: []string) -> bool {
	if !validate_flags(args, []string{"--out", "--seconds", "--freq", "--amp", "--channels", "--rate"}, nil) ||
	   !validate_numbers(args, []string{"--seconds", "--freq", "--amp"}, []string{"--channels", "--rate"}) {
		return false
	}
	out := flag_string(args, "--out", "tone.wav")
	seconds := flag_f32(args, "--seconds", 3.0)
	freq := flag_f32(args, "--freq", 440.0)
	amp := flag_f32(args, "--amp", 0.5)
	channels := flag_int(args, "--channels", 1)
	rate_arg := flag_int(args, "--rate", 48_000)

	if seconds <= 0.0 || seconds > MAX_CLI_SECONDS {
		fmt.eprintfln("--seconds must be positive and at most %.0f", MAX_CLI_SECONDS)
		return false
	}
	if amp < 0.0 || amp > 1.0 {
		fmt.eprintln("--amp must be between 0 and 1")
		return false
	}
	if channels < 1 || channels > MAX_CLI_CHANNELS {
		fmt.eprintfln("--channels must be between 1 and %d", MAX_CLI_CHANNELS)
		return false
	}
	// Range-check before narrowing: u32(-1) or u32(2^32 + 48000) would wrap.
	if rate_arg < int(PROJECT_SAMPLE_RATE_MIN) || rate_arg > MAX_CLI_RATE {
		fmt.eprintfln("--rate must be between %d and %d", PROJECT_SAMPLE_RATE_MIN, MAX_CLI_RATE)
		return false
	}
	rate := u32(rate_arg)
	if freq < 0 || freq > f32(rate) * 0.5 {
		fmt.eprintln("--freq must be between 0 and half the sample rate")
		return false
	}
	frames := int(seconds * f32(rate))
	if frames <= 0 {
		fmt.eprintln("requested tone is shorter than one sample")
		return false
	}
	if frames * channels > MAX_CLI_TONE_SAMPLES {
		fmt.eprintln("requested tone is too large to synthesize")
		return false
	}
	if !ensure_parent_dir(out) {
		return false
	}
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
	if !validate_flags(args, []string{"--out", "--seconds", "--channels", "--rate", "--device"}, []string{"--jack"}) ||
	   !validate_numbers(args, []string{"--seconds"}, []string{"--channels", "--rate", "--device"}) {
		return false
	}
	out := flag_string(args, "--out", "session")
	seconds := flag_f32(args, "--seconds", 5.0)
	channels := flag_int(args, "--channels", 2)
	rate_arg := flag_int(args, "--rate", 48_000)
	device := flag_int(args, "--device", -1)
	use_jack := has_flag(args, "--jack")

	if seconds <= 0.0 || seconds > MAX_CLI_SECONDS {
		fmt.eprintfln("--seconds must be positive and at most %.0f", MAX_CLI_SECONDS)
		return false
	}
	if channels < 1 || channels > MAX_CLI_CHANNELS {
		fmt.eprintfln("--channels must be between 1 and %d", MAX_CLI_CHANNELS)
		return false
	}
	if rate_arg < int(PROJECT_SAMPLE_RATE_MIN) || rate_arg > MAX_CLI_RATE {
		fmt.eprintfln("--rate must be between %d and %d", PROJECT_SAMPLE_RATE_MIN, MAX_CLI_RATE)
		return false
	}
	rate := u32(rate_arg)
	if !ensure_dir(out) {
		return false
	}
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
		// Record from the chosen (or default) capture device's JACK client so
		// track N is that device's input N, not whichever device the graph
		// lists first. Fall back to every port only without a device match.
		names, default_index := capture_device_list()
		defer {
			for n in names {
				delete(n)
			}
			delete(names)
		}
		index := device if device >= 0 else default_index
		if device >= len(names) {
			fmt.eprintfln("device index %d out of range (0..%d)", device, len(names) - 1)
			return false
		}
		selected: []string
		if index >= 0 && index < len(names) {
			selected = jack_ports_for_device(ports[:], names[index])
		}
		defer delete(selected)
		if selected != nil {
			fmt.printfln("JACK source: %s (%d port(s))", names[index], len(selected))
			if len(selected) < channels {
				fmt.eprintfln("device has %d JACK port(s), requested %d; extra tracks stay silent", len(selected), channels)
			}
			result, ok = jack_record(seconds, channels, rate, selected)
		} else {
			if device >= 0 {
				fmt.eprintfln("device %q has no JACK ports", names[index])
				return false
			}
			result, ok = jack_record(seconds, channels, rate, ports)
		}
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
	if !validate_flags(args, []string{
		"--in", "--out", "--ceiling", "--level", "--pan",
		"--eq-low", "--eq-mid", "--eq-high", "--eq-mid-hz", "--eq-mid-q",
		"--comp-threshold", "--comp-ratio", "--comp-attack", "--comp-release",
	}, []string{"--flat", "--no-limiter", "--no-comp"}) || !validate_numbers(args, []string{
		"--ceiling", "--level", "--pan",
		"--eq-low", "--eq-mid", "--eq-high", "--eq-mid-hz", "--eq-mid-q",
		"--comp-threshold", "--comp-ratio", "--comp-attack", "--comp-release",
	}, nil) {
		return false
	}
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
		}

		mono := mono_from_wav(&wav)
		if wav.sample_rate != rate && len(mono) > 0 {
			// Same policy as `bounce`: later tracks follow the first track's rate.
			fmt.printfln("resampling %s from %d Hz to %d Hz", path, wav.sample_rate, rate)
			converted := dsp.resample(mono, wav.sample_rate, rate)
			delete(mono)
			mono = converted
		}
		tracks[i] = mono
		wav_destroy(&wav)
	}
	if !ensure_parent_dir(out) {
		return false
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

	tmp_dir, tmp_err := os.temp_directory(context.allocator)
	if tmp_err != nil {
		fmt.eprintln("FAIL: no temporary directory")
		return false
	}
	defer delete(tmp_dir)
	path := fmt.tprintf("%s/tracker-odin-selftest.wav", tmp_dir)
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
	if !validate_flags(args, []string{"--session", "--out"}, nil) {
		return false
	}
	// engine_init only makes one directory level; create nested explicit
	// session paths here so `--session a/b/c` works like other CLI paths.
	if session, has_session := flag_value(args, "--session"); has_session {
		if !ensure_dir(session) {
			return false
		}
	}

	e: Engine
	if !engine_init(&e, args) {
		return false
	}
	defer engine_destroy(&e)

	out_path := flag_string(args, "--out", e.bounce_path)

	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)
	if os.exists(e.project_path) {
		if !project_load_with_takes(&a, e.session_dir, e.project_path, e.takes[:]) {
			fmt.eprintln("cannot load project")
			return false
		}
		// Bounce at the project rate rather than the CLI default.
		e.sample_rate = a.sample_rate
	}
	if !engine_load_tracks(&e, &a) {
		fmt.eprintln("no tracks in session")
		return false
	}
	if !ensure_parent_dir(out_path) {
		return false
	}
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

// Each take's length in project frames (after resampling to `project_rate`),
// or 0 when the file is missing or unreadable. The caller owns the slice.
@(private)
comp_take_lengths :: proc(dir: string, list: ^Take_List, project_rate: u32) -> []Take_Length {
	lengths := make([]Take_Length, len(list.takes))
	for take, i in list.takes {
		lengths[i].take_id = take.id
		if !project_file_is_local(take.file) {
			continue
		}
		wav, ok := wav_read(fmt.tprintf("%s/%s", dir, take.file))
		if !ok {
			continue
		}
		frames := wav.frames
		if wav.sample_rate != project_rate && wav.sample_rate > 0 && project_rate > 0 {
			// Matches dsp.resample's output length: ceil(frames * dst / src).
			frames = (frames * int(project_rate) + int(wav.sample_rate) - 1) / int(wav.sample_rate)
		}
		lengths[i].frames = frames
		wav_destroy(&wav)
	}
	return lengths
}

@(private)
run_comp :: proc(args: []string) -> bool {
	if !validate_flags(args, []string{"--session", "--track", "--take", "--start", "--end", "--select"}, []string{"--clear", "--list"}) ||
	   !validate_numbers(args, nil, []string{"--track", "--take", "--start", "--end", "--select"}) {
		return false
	}
	session, has_session := flag_value(args, "--session")
	if !has_session {
		fmt.eprintln("comp needs --session DIR")
		return false
	}
	// comp edits an existing session; it must not create one as a side effect.
	if !os.is_directory(session) {
		fmt.eprintfln("session %s does not exist", session)
		return false
	}
	track := flag_int(args, "--track", 0)
	if track < 0 || track >= MAX_ENGINE_TRACKS {
		fmt.eprintfln("--track must be between 0 and %d", MAX_ENGINE_TRACKS - 1)
		return false
	}
	_, has_select := flag_value(args, "--select")
	_, has_take := flag_value(args, "--take")
	_, has_start := flag_value(args, "--start")
	_, has_end := flag_value(args, "--end")
	has_region := has_take || has_start || has_end
	mutates := has_select || has_region || has_flag(args, "--clear")
	if has_flag(args, "--list") && mutates {
		fmt.eprintln("--list cannot be combined with --select, --clear or --take/--start/--end")
		return false
	}
	if has_region && (!has_start || !has_end) {
		fmt.eprintln("a comp region needs both --start and --end")
		return false
	}

	e: Engine
	if !engine_init(&e, []string{"--session", session}) {
		return false
	}
	defer engine_destroy(&e)
	a: ui.App
	ui.app_init(&a, 1180, 760)
	defer ui.app_destroy(&a)

	if os.exists(e.project_path) {
		if !project_load_with_takes(&a, e.session_dir, e.project_path, e.takes[:]) {
			fmt.eprintln("cannot load project")
			return false
		}
		e.sample_rate = a.sample_rate
	} else {
		_ = engine_load_tracks(&e, &a)
	}
	list := &e.takes[track]
	if len(list.takes) == 0 {
		fmt.eprintfln("no takes on track %d (--track %d)", track + 1, track)
		return false
	}
	lengths := comp_take_lengths(e.session_dir, list, e.sample_rate)
	defer delete(lengths)

	if has_flag(args, "--list") {
		fmt.printfln("track %d: %d take(s), active %d", track + 1, len(list.takes), list.active)
		for take, i in list.takes {
			marker := "*" if take.id == list.active else " "
			if lengths[i].frames > 0 {
				fmt.printfln("  %s %d  %s  %s  %d frames", marker, take.id, take.name, take.file, lengths[i].frames)
			} else {
				fmt.printfln("  %s %d  %s  %s  (missing or unreadable)", marker, take.id, take.name, take.file)
			}
		}
		for region in list.comp {
			fmt.printfln("  comp: take %d  [%d, %d)", region.take_id, region.start_frame, region.end_frame)
		}
		if ok, bad := comp_validate(list, lengths); !ok {
			fmt.printfln("  warning: comp region %d does not fit its take; bounce uses the active take", bad)
		}
		return true
	}

	changed := false
	if has_select {
		id := flag_int(args, "--select", 0)
		// take_list_select treats 0 as "no active take"; the CLI only selects real takes.
		if id == TAKE_ID_NONE || !take_list_select(list, id) {
			fmt.eprintfln("unknown take id %d", id)
			return false
		}
		changed = true
	}
	if has_flag(args, "--clear") {
		comp_clear(list)
		changed = true
	}
	if has_region {
		take_id := flag_int(args, "--take", list.active)
		start := flag_int(args, "--start", 0)
		end := flag_int(args, "--end", 0)
		if end <= start {
			fmt.eprintln("--end must be greater than --start")
			return false
		}
		if !comp_add_region(list, take_id, start, end) {
			fmt.eprintln("invalid region (unknown take, negative start, or overlap)")
			return false
		}
		if ok, _ := comp_validate(list, lengths); !ok {
			for entry in lengths {
				if entry.take_id == take_id {
					fmt.eprintfln("region [%d, %d) does not fit take %d (%d frames)", start, end, take_id, entry.frames)
					break
				}
			}
			return false
		}
		changed = true
	}
	if !changed {
		fmt.eprintln("nothing to do (use --list, --select, --clear, or --take/--start/--end)")
		return false
	}
	if !project_save_with_takes(&a, e.takes[:], e.project_path) {
		fmt.eprintln("cannot save project")
		return false
	}
	fmt.printfln("track %d: active take %d, %d comp region(s)", track + 1, list.active, len(list.comp))
	return true
}
