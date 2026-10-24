import { Knob } from "../Knob.tsx";
import { FxChip, FxModule, GrMeter } from "./FxModule.tsx";
import {
  autoMakeupDb,
  clamp,
  compTransferDb,
  fmtDb,
  fmtMs,
  fmtRatio,
  type CompParams,
} from "../../lib/fx.ts";

const W = 300;
const H = 78;
const PAD = 7;
const IN_MIN = -60;
const IN_MAX = 0;
const OUT_MIN = -60;
const OUT_MAX = 6;

function xOf(inputDb: number) {
  return PAD + ((inputDb - IN_MIN) / (IN_MAX - IN_MIN)) * (W - PAD * 2);
}

function yOf(outputDb: number) {
  return H - PAD - ((outputDb - OUT_MIN) / (OUT_MAX - OUT_MIN)) * (H - PAD * 2);
}

function transferPath(params: CompParams) {
  let path = "";
  for (let input = IN_MIN; input <= IN_MAX; input += 0.5) {
    const out = clamp(compTransferDb(params, input), OUT_MIN, OUT_MAX);
    path += `${input === IN_MIN ? "M" : "L"}${xOf(input).toFixed(2)},${yOf(out).toFixed(2)}`;
  }
  return path;
}

interface CompModuleProps {
  params: CompParams;
  onChange: (patch: Partial<CompParams>) => void;
  gr: number;
  peakGr: number;
  index?: number;
  name?: string;
}

export function CompModule({
  params,
  onChange,
  gr,
  peakGr,
  index = 2,
  name = "COMP",
}: CompModuleProps) {
  const curve = transferPath(params);
  const makeup = params.autoMakeup ? autoMakeupDb(params) : params.makeupDb;
  const displayed = { ...params, makeupDb: makeup };
  const area = `${curve} L${xOf(IN_MAX)},${yOf(IN_MAX)} L${xOf(IN_MIN)},${yOf(IN_MIN)} Z`;

  return (
    <FxModule
      name={name}
      index={index}
      enabled={params.enabled}
      onToggle={() => onChange({ enabled: !params.enabled })}
      ariaLabel={`${name} compressor`}
      actions={
        <FxChip
          active={params.autoMakeup}
          onClick={() => onChange({ autoMakeup: !params.autoMakeup })}
          title="Automatic makeup gain from threshold and ratio"
        >
          AUTO
        </FxChip>
      }
      footer={<GrMeter grDb={gr} peakDb={peakGr} label="GR" />}
      knobs={
        <>
          <Knob
            value={params.thresholdDb}
            onChange={(v) => onChange({ thresholdDb: v })}
            label="THR"
            ariaLabel="Compressor threshold"
            min={-60}
            max={0}
            step={0.5}
            defaultValue={-18}
            format={(v) => fmtDb(v)}
            disabled={!params.enabled}
          />
          <Knob
            value={params.ratio}
            onChange={(v) => onChange({ ratio: v })}
            label="RATIO"
            ariaLabel="Compressor ratio"
            min={1}
            max={20}
            step={0.1}
            taper="log"
            defaultValue={3}
            format={fmtRatio}
            disabled={!params.enabled}
          />
          <Knob
            value={params.attackMs}
            onChange={(v) => onChange({ attackMs: v })}
            label="ATTACK"
            ariaLabel="Compressor attack"
            min={0.1}
            max={300}
            step={0.1}
            taper="log"
            defaultValue={12}
            format={fmtMs}
            disabled={!params.enabled}
          />
          <Knob
            value={params.releaseMs}
            onChange={(v) => onChange({ releaseMs: v })}
            label="RELEASE"
            ariaLabel="Compressor release"
            min={5}
            max={2_000}
            step={1}
            taper="log"
            defaultValue={180}
            format={fmtMs}
            disabled={!params.enabled}
          />
          <Knob
            value={makeup}
            onChange={(v) => onChange({ makeupDb: v, autoMakeup: false })}
            label="MAKEUP"
            ariaLabel="Compressor makeup gain"
            min={-12}
            max={24}
            step={0.5}
            defaultValue={0}
            format={(v) => fmtDb(v)}
            disabled={!params.enabled || params.autoMakeup}
          />
        </>
      }
    >
      <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" className="comp-visual" aria-hidden="true">
        {[-48, -36, -24, -12].map((db) => (
          <g key={db}>
            <line x1={xOf(db)} y1={PAD} x2={xOf(db)} y2={H - PAD} className="fx-grid" />
            <line x1={PAD} y1={yOf(db)} x2={W - PAD} y2={yOf(db)} className="fx-grid" />
          </g>
        ))}
        <line x1={PAD} y1={yOf(0)} x2={W - PAD} y2={yOf(0)} className="fx-grid fx-grid--zero" />
        <line x1={xOf(IN_MIN)} y1={yOf(IN_MIN)} x2={xOf(IN_MAX)} y2={yOf(IN_MAX)} className="fx-ref" />
        <path d={area} className="comp-fill" />
        <path d={curve} className="comp-curve" />
        <line
          x1={xOf(params.thresholdDb)}
          y1={PAD}
          x2={xOf(params.thresholdDb)}
          y2={H - PAD}
          className="comp-threshold"
        />
        <circle
          cx={xOf(displayed.thresholdDb)}
          cy={yOf(compTransferDb(displayed, displayed.thresholdDb))}
          r="2.5"
          className="comp-dot"
        />
      </svg>
    </FxModule>
  );
}
