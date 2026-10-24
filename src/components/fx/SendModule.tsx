import { Knob } from "../Knob.tsx";
import { FxModule } from "./FxModule.tsx";
import { fmtPct, type TrackFxSettings } from "../../lib/fx.ts";

interface SendModuleProps {
  fx: TrackFxSettings;
  onChange: (patch: Partial<TrackFxSettings>) => void;
  reverbOn: boolean;
  delayOn: boolean;
}

/** Post-fader sends into the shared reverb and delay buses. */
export function SendModule({ fx, onChange, reverbOn, delayOn }: SendModuleProps) {
  const rows = [
    { key: "sendReverb" as const, label: "REV", bus: "REVERB BUS", value: fx.sendReverb, on: reverbOn },
    { key: "sendDelay" as const, label: "DLY", bus: "DELAY BUS", value: fx.sendDelay, on: delayOn },
  ];
  const mutedBus =
    (fx.sendReverb > 0.001 && !reverbOn) || (fx.sendDelay > 0.001 && !delayOn);

  return (
    <FxModule
      name="SEND"
      index={3}
      enabled
      onToggle={() => {}}
      power={false}
      ariaLabel="Effect sends"
      footer={
        <span className={`fx-readout ${mutedBus ? "fx-readout--warn" : ""}`}>
          {mutedBus ? "BUS BYPASSED — ENABLE ON MST" : "POST-FADER → SHARED BUSES"}
        </span>
      }
      knobs={
        <>
          <Knob
            value={fx.sendReverb}
            onChange={(v) => onChange({ sendReverb: v })}
            label="REVERB"
            ariaLabel="Reverb send"
            min={0}
            max={1}
            step={0.01}
            defaultValue={0}
            format={fmtPct}
          />
          <Knob
            value={fx.sendDelay}
            onChange={(v) => onChange({ sendDelay: v })}
            label="DELAY"
            ariaLabel="Delay send"
            min={0}
            max={1}
            step={0.01}
            defaultValue={0}
            format={fmtPct}
          />
        </>
      }
    >
      <div className="send-visual" aria-hidden="true">
        {rows.map((row) => (
          <div className="send-visual__row" key={row.key}>
            <span className="send-visual__label">{row.label}</span>
            <span className="send-visual__track">
              <span className="send-visual__fill" style={{ width: `${row.value * 100}%` }} />
            </span>
            <span className="send-visual__value">{row.value > 0 ? fmtPct(row.value) : "OFF"}</span>
            <span className="send-visual__bus">{row.bus}</span>
          </div>
        ))}
      </div>
    </FxModule>
  );
}
