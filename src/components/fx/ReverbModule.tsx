import { useMemo } from "react";
import { Knob } from "../Knob.tsx";
import { FxModule } from "./FxModule.tsx";
import { fmtMs, fmtPct, fmtSec, reverbRt60, type ReverbParams } from "../../lib/fx.ts";

const W = 300;
const H = 62;
const CENTER = H / 2;
const AMP = H / 2 - 4;

interface ReverbModuleProps {
  params: ReverbParams;
  onChange: (patch: Partial<ReverbParams>) => void;
}

export function ReverbModule({ params, onChange }: ReverbModuleProps) {
  const rt60 = reverbRt60(params.decay);
  const { leftPath, rightPath, ticks } = useMemo(() => {
    const seconds = Math.max(0.5, Math.min(8, rt60));
    const pre = params.predelayMs / 1000;
    const points = 84;
    const xOf = (t: number) => Math.min(W, (t / seconds) * W);
    let l = "";
    let r = "";
    for (let i = 0; i <= points; i += 1) {
      const t = (i / points) * seconds;
      const active = t >= pre;
      const e = active ? Math.exp((-6.9 * (t - pre)) / rt60) : 0;
      const x = xOf(t);
      l += `${i === 0 ? "M" : "L"}${x.toFixed(1)},${(CENTER - e * AMP).toFixed(1)}`;
      r += `${i === 0 ? "M" : "L"}${x.toFixed(1)},${(CENTER + e * AMP * 0.92).toFixed(1)}`;
    }
    const early = [0.011, 0.017, 0.024, 0.033, 0.047, 0.062];
    const tickMarks = early.map((offset, i) => ({
      x: xOf(pre + offset),
      height: (1 - i / (early.length + 1)) * AMP * 0.65,
    }));
    return { leftPath: `${l} L${W},${CENTER} L0,${CENTER} Z`, rightPath: `${r} L${W},${CENTER} L0,${CENTER} Z`, ticks: tickMarks };
  }, [params.predelayMs, rt60]);

  return (
    <FxModule
      name="REVERB"
      index={2}
      enabled={params.enabled}
      onToggle={() => onChange({ enabled: !params.enabled })}
      ariaLabel="Reverb"
      footer={
        <>
          <span className="fx-readout">RT60 {fmtSec(rt60)}</span>
          <span className="fx-readout fx-readout--dim">
            {fmtPct(params.size)} room · {fmtMs(params.predelayMs)} pre
          </span>
        </>
      }
      knobs={
        <>
          <Knob
            value={params.size}
            onChange={(v) => onChange({ size: v })}
            label="SIZE"
            ariaLabel="Reverb room size"
            min={0}
            max={1}
            step={0.01}
            defaultValue={0.62}
            format={fmtPct}
            disabled={!params.enabled}
          />
          <Knob
            value={params.decay}
            onChange={(v) => onChange({ decay: v })}
            label="DECAY"
            ariaLabel="Reverb decay"
            min={0}
            max={1}
            step={0.01}
            defaultValue={0.55}
            format={(v) => fmtSec(reverbRt60(v))}
            disabled={!params.enabled}
          />
          <Knob
            value={params.tone}
            onChange={(v) => onChange({ tone: v })}
            label="TONE"
            ariaLabel="Reverb tone"
            min={0}
            max={1}
            step={0.01}
            defaultValue={0.55}
            format={(v) => fmtPct(v)}
            disabled={!params.enabled}
          />
          <Knob
            value={params.predelayMs}
            onChange={(v) => onChange({ predelayMs: v })}
            label="PRE"
            ariaLabel="Reverb pre-delay"
            min={0}
            max={200}
            step={1}
            defaultValue={18}
            format={fmtMs}
            disabled={!params.enabled}
          />
          <Knob
            value={params.returnLevel}
            onChange={(v) => onChange({ returnLevel: v })}
            label="RETURN"
            ariaLabel="Reverb return level"
            min={0}
            max={1}
            step={0.01}
            defaultValue={0.45}
            format={fmtPct}
            disabled={!params.enabled}
          />
        </>
      }
    >
      <div className="tail-visual">
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden="true">
          <line x1="0" y1={CENTER} x2={W} y2={CENTER} className="fx-grid fx-grid--zero" />
          <path d={leftPath} className="tail-fill" />
          <path d={rightPath} className="tail-fill tail-fill--r" />
          <path d={leftPath} className="tail-line" />
          <path d={rightPath} className="tail-line tail-line--r" />
          {ticks.map((tick, i) => (
            <line
              key={i}
              x1={tick.x}
              y1={CENTER - tick.height}
              x2={tick.x}
              y2={CENTER + tick.height}
              className="tail-tick"
            />
          ))}
        </svg>
        <span className="tail-visual__tag">TAIL {fmtSec(rt60)}</span>
        <span className="tail-visual__lanes" aria-hidden="true">
          L / R
        </span>
      </div>
    </FxModule>
  );
}
