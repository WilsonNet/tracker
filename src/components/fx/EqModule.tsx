import { useRef, useState } from "react";
import { Knob } from "../Knob.tsx";
import { FxModule } from "./FxModule.tsx";
import {
  HIGH_SHELF_HZ,
  LOW_SHELF_HZ,
  clamp,
  eqResponseDb,
  fmtDb,
  fmtHz,
  type EqParams,
} from "../../lib/fx.ts";

const W = 300;
const H = 78;
const ZERO = H / 2;
const SCALE = (H / 2 - 8) / 18;

function xOfFreq(freq: number) {
  return (Math.log10(freq / 20) / 3) * W;
}

function freqOfX(x: number) {
  return 20 * Math.pow(10, clamp(x / W, 0, 1) * 3);
}

function yOfDb(db: number) {
  return ZERO - clamp(db, -18, 18) * SCALE;
}

function curvePath(eq: EqParams) {
  const points = 160;
  let path = "";
  for (let i = 0; i < points; i += 1) {
    const x = (i / (points - 1)) * W;
    const db = eqResponseDb(eq, freqOfX(x));
    const y = yOfDb(db);
    path += `${i === 0 ? "M" : "L"}${x.toFixed(2)},${y.toFixed(2)}`;
  }
  return path;
}

type Band = "low" | "mid" | "high";

interface EqModuleProps {
  params: EqParams;
  onChange: (patch: Partial<EqParams>) => void;
}

export function EqModule({ params, onChange }: EqModuleProps) {
  const svgRef = useRef<SVGSVGElement>(null);
  const [active, setActive] = useState<Band | null>(null);
  const path = curvePath(params);

  const pointerDb = (clientY: number) => {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) return 0;
    const y = ((clientY - rect.top) / rect.height) * H;
    return Math.round(clamp((ZERO - y) / SCALE, -18, 18) * 2) / 2;
  };

  const pointerFreq = (clientX: number) => {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) return params.midHz;
    const x = ((clientX - rect.left) / rect.width) * W;
    const freq = freqOfX(x);
    return Math.round(clamp(freq, 150, 8_000) / 10) * 10;
  };

  const begin = (band: Band) => (event: React.PointerEvent<SVGGElement>) => {
    event.preventDefault();
    event.stopPropagation();
    event.currentTarget.setPointerCapture(event.pointerId);
    setActive(band);
  };

  const move = (band: Band) => (event: React.PointerEvent<SVGGElement>) => {
    if (!event.currentTarget.hasPointerCapture(event.pointerId)) return;
    const db = pointerDb(event.clientY);
    if (band === "low") onChange({ lowDb: db });
    else if (band === "high") onChange({ highDb: db });
    else onChange({ midDb: db, midHz: pointerFreq(event.clientX) });
  };

  const end = (event: React.PointerEvent<SVGGElement>) => {
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    setActive(null);
  };

  const nodes: Array<{ band: Band; x: number; y: number; db: number; freq: number }> = [
    { band: "low", x: xOfFreq(LOW_SHELF_HZ), y: yOfDb(params.lowDb), db: params.lowDb, freq: LOW_SHELF_HZ },
    { band: "mid", x: xOfFreq(params.midHz), y: yOfDb(params.midDb), db: params.midDb, freq: params.midHz },
    { band: "high", x: xOfFreq(HIGH_SHELF_HZ), y: yOfDb(params.highDb), db: params.highDb, freq: HIGH_SHELF_HZ },
  ];

  return (
    <FxModule
      name="EQ"
      index={1}
      enabled={params.enabled}
      onToggle={() => onChange({ enabled: !params.enabled })}
      ariaLabel="Three-band equalizer"
      wide
      footer={
        <span className="fx-readout">
          110 Hz shelf · bell {fmtHz(params.midHz)} · 7.5 kHz shelf
        </span>
      }
      knobs={
        <>
          <Knob
            value={params.lowDb}
            onChange={(v) => onChange({ lowDb: v })}
            label="LOW"
            ariaLabel="Low shelf gain"
            min={-18}
            max={18}
            step={0.5}
            defaultValue={0}
            format={(v) => fmtDb(v)}
            disabled={!params.enabled}
          />
          <Knob
            value={params.midDb}
            onChange={(v) => onChange({ midDb: v })}
            label="MID"
            ariaLabel="Mid bell gain"
            min={-18}
            max={18}
            step={0.5}
            defaultValue={0}
            format={(v) => fmtDb(v)}
            disabled={!params.enabled}
          />
          <Knob
            value={params.midHz}
            onChange={(v) => onChange({ midHz: v })}
            label="FREQ"
            ariaLabel="Mid bell frequency"
            min={150}
            max={8_000}
            step={10}
            taper="log"
            defaultValue={1_000}
            format={fmtHz}
            disabled={!params.enabled}
          />
          <Knob
            value={params.midQ}
            onChange={(v) => onChange({ midQ: v })}
            label="Q"
            ariaLabel="Mid bell width"
            min={0.3}
            max={8}
            step={0.05}
            taper="log"
            defaultValue={1}
            format={(v) => v.toFixed(2)}
            disabled={!params.enabled}
          />
          <Knob
            value={params.highDb}
            onChange={(v) => onChange({ highDb: v })}
            label="HIGH"
            ariaLabel="High shelf gain"
            min={-18}
            max={18}
            step={0.5}
            defaultValue={0}
            format={(v) => fmtDb(v)}
            disabled={!params.enabled}
          />
        </>
      }
    >
      <div className={`eq-visual ${active ? "eq-visual--active" : ""}`}>
        <svg
          ref={svgRef}
          viewBox={`0 0 ${W} ${H}`}
          preserveAspectRatio="none"
          className="eq-visual__svg"
          aria-hidden="true"
        >
          <line x1="0" y1={yOfDb(12)} x2={W} y2={yOfDb(12)} className="eq-grid" />
          <line x1="0" y1={yOfDb(0)} x2={W} y2={yOfDb(0)} className="eq-grid eq-grid--zero" />
          <line x1="0" y1={yOfDb(-12)} x2={W} y2={yOfDb(-12)} className="eq-grid" />
          {[100, 1_000, 10_000].map((f) => (
            <line
              key={f}
              x1={xOfFreq(f)}
              y1="0"
              x2={xOfFreq(f)}
              y2={H}
              className="eq-grid"
            />
          ))}
          <path d={`${path} L${W},${ZERO} L0,${ZERO} Z`} className="eq-fill" />
          <path d={path} className="eq-curve" />
          {nodes.map((node) => (
            <g
              key={node.band}
              className={`eq-node ${active === node.band ? "eq-node--active" : ""}`}
              onPointerDown={begin(node.band)}
              onPointerMove={move(node.band)}
              onPointerUp={end}
              onPointerCancel={end}
              onDoubleClick={(e) => {
                e.stopPropagation();
                if (node.band === "low") onChange({ lowDb: 0 });
                else if (node.band === "high") onChange({ highDb: 0 });
                else onChange({ midDb: 0 });
              }}
              style={{ cursor: node.band === "mid" ? "grab" : "ns-resize" }}
            >
              <title>
                {node.band.toUpperCase()} {fmtDb(node.db)} · {fmtHz(node.freq)} — drag to adjust
              </title>
              <circle cx={node.x} cy={node.y} r="9" className="eq-node__hit" />
              <circle cx={node.x} cy={node.y} r="3.5" className="eq-node__dot" />
            </g>
          ))}
        </svg>
        <div className="eq-visual__scale" aria-hidden="true">
          <span style={{ left: `${(xOfFreq(100) / W) * 100}%` }}>100</span>
          <span style={{ left: `${(xOfFreq(1_000) / W) * 100}%` }}>1k</span>
          <span style={{ left: `${(xOfFreq(10_000) / W) * 100}%` }}>10k</span>
        </div>
      </div>
    </FxModule>
  );
}
