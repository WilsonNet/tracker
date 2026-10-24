import type { ReactNode } from "react";

interface FxModuleProps {
  name: string;
  index: number;
  enabled: boolean;
  onToggle: () => void;
  actions?: ReactNode;
  children: ReactNode;
  knobs: ReactNode;
  footer?: ReactNode;
  ariaLabel: string;
  wide?: boolean;
  /** Modules that are always active (e.g. sends) hide the power switch. */
  power?: boolean;
}

/** Shared shell for every effect: numbered header, power switch, visual, knobs. */
export function FxModule({
  name,
  index,
  enabled,
  onToggle,
  actions,
  children,
  knobs,
  footer,
  ariaLabel,
  wide,
  power = true,
}: FxModuleProps) {
  return (
    <section
      className={`fx-mod ${enabled ? "fx-mod--on" : "fx-mod--bypassed"} ${wide ? "fx-mod--wide" : ""}`}
      aria-label={ariaLabel}
      data-module={name.toLowerCase()}
      data-enabled={enabled}
    >
      <header className="fx-mod__head">
        <span className="fx-mod__index">{String(index).padStart(2, "0")}</span>
        <h3 className="fx-mod__name">{name}</h3>
        {actions ? <div className="fx-mod__actions">{actions}</div> : null}
        {power ? (
          <button
            type="button"
            className={`fx-power ${enabled ? "fx-power--on" : ""}`}
            onClick={onToggle}
            aria-pressed={enabled}
            aria-label={`${enabled ? "Bypass" : "Enable"} ${name}`}
            title={`${enabled ? "Bypass" : "Enable"} ${name}`}
          >
            {enabled ? "ON" : "BYP"}
          </button>
        ) : null}
      </header>
      <div className="fx-mod__visual">{children}</div>
      <div className="fx-mod__knobs">{knobs}</div>
      {footer ? <div className="fx-mod__foot">{footer}</div> : null}
    </section>
  );
}

interface GrMeterProps {
  /** Current reduction, dB ≤ 0. */
  grDb: number;
  /** Peak reduction since the last render, dB ≤ 0. */
  peakDb?: number;
  range?: number;
  label?: string;
}

/** Gain-reduction meter. Fills right-to-left, the way hardware GR meters do. */
export function GrMeter({ grDb, peakDb, range = 24, label = "GR" }: GrMeterProps) {
  const value = Number.isFinite(grDb) ? Math.abs(Math.min(0, grDb)) : 0;
  const peak = Number.isFinite(peakDb ?? 0) ? Math.abs(Math.min(0, peakDb ?? 0)) : 0;
  const pct = Math.min(100, (value / range) * 100);
  const peakPct = Math.min(100, (peak / range) * 100);
  return (
    <div className="gr-meter" role="meter" aria-label={`${label} gain reduction`} aria-valuemin={0} aria-valuemax={range} aria-valuenow={Number(value.toFixed(1))}>
      <div className="gr-meter__head">
        <span className="gr-meter__label">{label}</span>
        <span className="gr-meter__value">{value < 0.05 ? "0.0" : `−${value.toFixed(1)}`} dB</span>
      </div>
      <div className="gr-meter__track">
        {peak > 0.05 ? <span className="gr-meter__peak" style={{ width: `${peakPct}%` }} /> : null}
        <span className="gr-meter__fill" style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

/** Tiny toggle chip used for AUTO / SYNC / PING-PONG style switches. */
export function FxChip({
  active,
  onClick,
  children,
  title,
}: {
  active: boolean;
  onClick: () => void;
  children: ReactNode;
  title?: string;
}) {
  return (
    <button
      type="button"
      className={`fx-chip ${active ? "fx-chip--on" : ""}`}
      onClick={onClick}
      aria-pressed={active}
      title={title}
    >
      {children}
    </button>
  );
}
