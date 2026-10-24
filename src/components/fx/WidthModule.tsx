import { useMemo } from "react";
import { Knob } from "../Knob.tsx";
import { FxModule } from "./FxModule.tsx";
import { bassMonoAmount, fmtHz, fmtWidth, type WidthParams } from "../../lib/fx.ts";

const W = 300;
const H = 62;
const CX = W / 2;
const CY = H / 2;

function mulberry32(seed: number) {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

interface WidthModuleProps {
  params: WidthParams;
  onChange: (patch: Partial<WidthParams>) => void;
}

export function WidthModule({ params, onChange }: WidthModuleProps) {
  const points = useMemo(() => {
    const random = mulberry32(0x5eed);
    return Array.from({ length: 130 }, () => {
      const angle = random() * Math.PI * 2;
      const radius = Math.sqrt(random());
      return { x: Math.cos(angle) * radius, y: Math.sin(angle) * radius };
    });
  }, []);

  const spread = 0.04 + (params.width / 2) * 0.88;
  const rx = (W / 2 - 12) * spread;
  const ry = (H / 2 - 5) * 0.95;
  const sideDb = params.width > 0.01 ? 20 * Math.log10(params.width) : -60;
  const bassMono = bassMonoAmount(params.width);

  return (
    <FxModule
      name="WIDTH"
      index={4}
      enabled={params.enabled}
      onToggle={() => onChange({ enabled: !params.enabled })}
      ariaLabel="Stereo widener"
      footer={
        <>
          <span className="fx-readout">SIDE {sideDb >= 0 ? "+" : "−"}{Math.abs(sideDb).toFixed(1)} dB</span>
          <span className="fx-readout fx-readout--dim">
            {bassMono > 0 ? `MONO < ${fmtHz(params.bassHz)}` : "FULL RANGE"}
          </span>
        </>
      }
      knobs={
        <>
          <Knob
            value={params.width}
            onChange={(v) => onChange({ width: v })}
            label="WIDTH"
            ariaLabel="Stereo width"
            min={0}
            max={2}
            step={0.01}
            defaultValue={1.25}
            format={fmtWidth}
            disabled={!params.enabled}
          />
          <Knob
            value={params.bassHz}
            onChange={(v) => onChange({ bassHz: v })}
            label="BASS"
            ariaLabel="Bass mono crossover"
            min={40}
            max={400}
            step={5}
            taper="log"
            defaultValue={140}
            format={fmtHz}
            disabled={!params.enabled}
          />
        </>
      }
    >
      <div className="width-visual">
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden="true">
          <line x1={CX} y1="4" x2={CX} y2={H - 4} className="fx-grid fx-grid--zero" />
          <line x1="8" y1={H - 6} x2={W - 8} y2="6" className="width-axis" />
          <line x1="8" y1="6" x2={W - 8} y2={H - 6} className="width-axis" />
          <ellipse cx={CX} cy={CY} rx={rx} ry={ry} className="width-shell" />
          {points.map((point, i) => (
            <circle
              key={i}
              cx={CX + point.x * rx}
              cy={CY + point.y * ry}
              r="1.1"
              className="width-dot"
            />
          ))}
        </svg>
        <span className="width-visual__mono">M</span>
      </div>
    </FxModule>
  );
}
