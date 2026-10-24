import { Knob } from "../Knob.tsx";
import { FxModule, GrMeter } from "./FxModule.tsx";
import { fmtDb, fmtMs, type LimiterParams } from "../../lib/fx.ts";

const W = 300;
const H = 56;
const CENTER = H / 2;

interface LimiterModuleProps {
  params: LimiterParams;
  onChange: (patch: Partial<LimiterParams>) => void;
  gr: number;
  peakGr: number;
  peakDb: number;
}

/** Static waveform hitting the ceiling, so the ceiling is visible, not just a number. */
function waveform(ceilingDb: number) {
  const ceilingY = CENTER - Math.min(0.9, 10 ** (ceilingDb / 20)) * (H / 2 - 6);
  let path = "";
  for (let i = 0; i <= 180; i += 1) {
    const t = i / 180;
    const envelope = Math.exp(-((t - 0.34) ** 2) / 0.012) + 0.28;
    const signal =
      Math.sin(t * Math.PI * 34) * 0.72 + Math.sin(t * Math.PI * 91 + 1.2) * 0.28;
    const rawY = CENTER - signal * envelope * (H / 2 - 8);
    const y = Math.max(ceilingY, Math.min(H - CENTER, rawY));
    path += `${i === 0 ? "M" : "L"}${((i / 180) * W).toFixed(1)},${y.toFixed(1)}`;
  }
  return { path, ceilingY };
}

export function LimiterModule({ params, onChange, gr, peakGr, peakDb }: LimiterModuleProps) {
  const { path, ceilingY } = waveform(params.ceilingDb);

  return (
    <FxModule
      name="LIMITER"
      index={5}
      enabled={params.enabled}
      onToggle={() => onChange({ enabled: !params.enabled })}
      ariaLabel="Master limiter"
      footer={
        <>
          <GrMeter grDb={gr} peakDb={peakGr} label="GR" />
          <span className="fx-readout fx-readout--dim">PEAK {fmtDb(peakDb)}</span>
        </>
      }
      knobs={
        <>
          <Knob
            value={params.ceilingDb}
            onChange={(v) => onChange({ ceilingDb: v })}
            label="CEILING"
            ariaLabel="Limiter ceiling"
            min={-12}
            max={0}
            step={0.1}
            defaultValue={-0.3}
            format={(v) => fmtDb(v, 1)}
            disabled={!params.enabled}
          />
          <Knob
            value={params.releaseMs}
            onChange={(v) => onChange({ releaseMs: v })}
            label="RELEASE"
            ariaLabel="Limiter release"
            min={10}
            max={1_000}
            step={1}
            taper="log"
            defaultValue={120}
            format={fmtMs}
            disabled={!params.enabled}
          />
          <Knob
            value={params.lookaheadMs}
            onChange={(v) => onChange({ lookaheadMs: v })}
            label="LOOK"
            ariaLabel="Limiter lookahead"
            min={0.5}
            max={20}
            step={0.1}
            defaultValue={5}
            format={fmtMs}
            disabled={!params.enabled}
          />
        </>
      }
    >
      <div className="limiter-visual">
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden="true">
          <line x1="0" y1={CENTER} x2={W} y2={CENTER} className="fx-grid fx-grid--zero" />
          <path d={path} className="limiter-wave" />
          <line x1="0" y1={ceilingY} x2={W} y2={ceilingY} className="limiter-ceiling" />
        </svg>
        <span className="limiter-visual__tag">{params.ceilingDb.toFixed(1)} dB</span>
      </div>
    </FxModule>
  );
}
