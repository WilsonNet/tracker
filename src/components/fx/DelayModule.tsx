import { Knob } from "../Knob.tsx";
import { FxChip, FxModule } from "./FxModule.tsx";
import {
  DELAY_DIVISIONS,
  effectiveDelayMs,
  fmtMs,
  fmtPct,
  fmtSec,
  type DelayParams,
} from "../../lib/fx.ts";

const W = 300;
const H = 62;
const CENTER = H / 2;
const AMP = H / 2 - 6;

interface DelayModuleProps {
  params: DelayParams;
  bpm: number;
  onChange: (patch: Partial<DelayParams>) => void;
}

export function DelayModule({ params, bpm, onChange }: DelayModuleProps) {
  const timeMs = effectiveDelayMs(params, bpm);
  const timeSec = timeMs / 1000;
  const tailSec = Math.max(1.2, Math.min(9, timeSec * 7));
  const division = DELAY_DIVISIONS[Math.max(0, Math.min(DELAY_DIVISIONS.length - 1, params.division))];

  const echoes = Array.from({ length: 6 }, (_, i) => {
    const n = i + 1;
    const x = Math.min(W - 2, (n * timeSec * W) / tailSec);
    const amp = Math.max(0.16, Math.pow(params.feedback, n - 1) * 1.05);
    const lane = params.pingPong ? (n % 2 === 1 ? -1 : 1) : 0;
    return { n, x, amp, lane };
  });

  const dryX = 2;

  return (
    <FxModule
      name="DELAY"
      index={3}
      enabled={params.enabled}
      onToggle={() => onChange({ enabled: !params.enabled })}
      ariaLabel="Delay"
      actions={
        <>
          <FxChip
            active={params.pingPong}
            onClick={() => onChange({ pingPong: !params.pingPong })}
            title="Alternate repeats between left and right"
          >
            P·P
          </FxChip>
          <FxChip
            active={params.sync}
            onClick={() => onChange({ sync: !params.sync })}
            title="Lock the delay time to the transport tempo"
          >
            SYNC
          </FxChip>
        </>
      }
      footer={
        <>
          <span className="fx-readout">
            {params.sync ? `${division.label} · ` : ""}
            {fmtMs(timeMs)}
          </span>
          <span className="fx-readout fx-readout--dim">
            {params.pingPong ? "L/R alternating" : "stereo"} · {fmtSec(tailSec)} tail
          </span>
        </>
      }
      knobs={
        <>
          {params.sync ? (
            <Knob
              value={params.division}
              onChange={(v) => onChange({ division: Math.round(v) })}
              label="DIV"
              ariaLabel="Delay note division"
              min={0}
              max={DELAY_DIVISIONS.length - 1}
              step={1}
              defaultValue={2}
              format={(v) => DELAY_DIVISIONS[Math.round(v)]?.label ?? "1/8"}
              disabled={!params.enabled}
            />
          ) : (
            <Knob
              value={params.timeMs}
              onChange={(v) => onChange({ timeMs: v })}
              label="TIME"
              ariaLabel="Delay time"
              min={1}
              max={2_000}
              step={1}
              taper="log"
              defaultValue={320}
              format={fmtMs}
              disabled={!params.enabled}
            />
          )}
          <Knob
            value={params.feedback}
            onChange={(v) => onChange({ feedback: v })}
            label="FEEDBACK"
            ariaLabel="Delay feedback"
            min={0}
            max={0.9}
            step={0.01}
            defaultValue={0.35}
            format={fmtPct}
            disabled={!params.enabled}
          />
          <Knob
            value={params.tone}
            onChange={(v) => onChange({ tone: v })}
            label="TONE"
            ariaLabel="Delay tone"
            min={0}
            max={1}
            step={0.01}
            defaultValue={0.55}
            format={fmtPct}
            disabled={!params.enabled}
          />
          <Knob
            value={params.returnLevel}
            onChange={(v) => onChange({ returnLevel: v })}
            label="RETURN"
            ariaLabel="Delay return level"
            min={0}
            max={1}
            step={0.01}
            defaultValue={0.35}
            format={fmtPct}
            disabled={!params.enabled}
          />
        </>
      }
    >
      <div className="delay-visual">
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden="true">
          <line x1="0" y1={CENTER} x2={W} y2={CENTER} className="fx-grid fx-grid--zero" />
          <line x1={dryX} y1={CENTER - AMP} x2={dryX} y2={CENTER + AMP} className="delay-dry" />
          {echoes.map((echo) => {
            const top = echo.lane === 0 ? CENTER - echo.amp * AMP : echo.lane < 0 ? CENTER - echo.amp * AMP : CENTER + 2;
            const bottom = echo.lane === 0 ? CENTER + echo.amp * AMP : echo.lane < 0 ? CENTER - 2 : CENTER + echo.amp * AMP;
            return (
              <g key={echo.n} className="delay-echo">
                <line x1={echo.x} y1={top} x2={echo.x} y2={bottom} />
                <circle cx={echo.x} cy={top} r="1.4" />
                <circle cx={echo.x} cy={bottom} r="1.4" />
              </g>
            );
          })}
          <line x1="0" y1={CENTER} x2={W} y2={CENTER} className="delay-timeline" />
        </svg>
        <span className="delay-visual__tag">{fmtMs(timeMs)}</span>
        <span className="delay-visual__lanes" aria-hidden="true">
          L
        </span>
      </div>
    </FxModule>
  );
}
