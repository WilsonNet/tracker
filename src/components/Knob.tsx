import { useCallback, useRef, useState } from "react";

type KnobSize = "sm" | "md";

interface KnobProps {
  value: number;
  onChange?: (value: number) => void;
  label: string;
  ariaLabel: string;
  min?: number;
  max?: number;
  step?: number;
  defaultValue?: number;
  /** Display formatter for the value readout. */
  format?: (value: number) => string;
  size?: KnobSize;
  disabled?: boolean;
  /** Log taper for frequency/time style controls (min must be > 0). */
  taper?: "linear" | "log";
  accent?: "amber" | "teal";
}

const DRAG_RANGE_PX = 170;

function toNorm(value: number, min: number, max: number, taper: "linear" | "log") {
  const v = clamp(value, min, max);
  if (taper === "log") {
    const lo = Math.log(Math.max(min, 1e-6));
    const hi = Math.log(Math.max(max, min + 1e-6));
    return (Math.log(Math.max(v, 1e-6)) - lo) / (hi - lo);
  }
  return max === min ? 0 : (v - min) / (max - min);
}

function fromNorm(norm: number, min: number, max: number, taper: "linear" | "log") {
  const n = clamp(norm, 0, 1);
  if (taper === "log") {
    const lo = Math.log(Math.max(min, 1e-6));
    const hi = Math.log(Math.max(max, min + 1e-6));
    return Math.exp(lo + (hi - lo) * n);
  }
  return min + (max - min) * n;
}

function clamp(v: number, min: number, max: number) {
  return Math.min(max, Math.max(min, v));
}

function snap(value: number, step: number) {
  if (!step) return value;
  return Math.round(value / step) * step;
}

export function Knob({
  value,
  onChange,
  label,
  ariaLabel,
  min = 0,
  max = 1,
  step = 0.01,
  defaultValue,
  format,
  size = "md",
  disabled = false,
  taper = "linear",
  accent = "amber",
}: KnobProps) {
  const [dragging, setDragging] = useState(false);
  const dragRef = useRef({ startY: 0, startX: 0, norm: 0, moved: false });

  const norm = toNorm(value, min, max, taper);
  const interactive = !disabled && Boolean(onChange);

  const commit = useCallback(
    (n: number) => {
      const raw = fromNorm(n, min, max, taper);
      const stepped = snap(raw, step);
      onChange?.(clamp(stepped, min, max));
    },
    [fromNorm, max, min, onChange, step, taper],
  );

  const onPointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    if (!interactive) return;
    event.preventDefault();
    event.currentTarget.focus();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = {
      startY: event.clientY,
      startX: event.clientX,
      norm,
      moved: false,
    };
    setDragging(true);
  };

  const onPointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    if (!dragging || !interactive) return;
    const fine = event.shiftKey ? 0.12 : 1;
    const dy = (dragRef.current.startY - event.clientY) / DRAG_RANGE_PX;
    const dx = (event.clientX - dragRef.current.startX) / (DRAG_RANGE_PX * 2);
    dragRef.current.moved = true;
    commit(dragRef.current.norm + (dy + dx) * fine);
  };

  const endDrag = (event: React.PointerEvent<HTMLDivElement>) => {
    if (!dragging) return;
    setDragging(false);
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  };

  const onWheel = (event: React.WheelEvent<HTMLDivElement>) => {
    if (!interactive) return;
    event.preventDefault();
    const fine = event.shiftKey ? 0.2 : 1;
    const delta = (event.deltaY > 0 ? -1 : 1) * 0.015 * fine;
    commit(norm + delta);
  };

  const onKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (!interactive) return;
    const fine = event.shiftKey ? 0.15 : 1;
    let next = norm;
    switch (event.key) {
      case "ArrowUp":
      case "ArrowRight":
        next = norm + 0.01 * fine;
        break;
      case "PageUp":
        next = norm + 0.1 * fine;
        break;
      case "ArrowDown":
      case "ArrowLeft":
        next = norm - 0.01 * fine;
        break;
      case "PageDown":
        next = norm - 0.1 * fine;
        break;
      case "Home":
        next = 0;
        break;
      case "End":
        next = 1;
        break;
      default:
        return;
    }
    event.preventDefault();
    event.stopPropagation();
    commit(next);
  };

  const onDoubleClick = () => {
    if (!interactive || defaultValue === undefined) return;
    onChange?.(clamp(defaultValue, min, max));
  };

  const display = format ? format(value) : value.toFixed(2);
  const diameter = size === "sm" ? 30 : 38;
  const radius = diameter / 2 - 3;
  const center = diameter / 2;
  const circumference = 2 * Math.PI * radius;
  const arcLength = circumference * 0.75 * (Number.isFinite(norm) ? norm : 0);
  const angle = (135 + 270 * (Number.isFinite(norm) ? norm : 0)) * (Math.PI / 180);
  const pointerInner = radius - 6;
  const pointerOuter = radius - 1;

  return (
    <div
      className={[
        "knob",
        `knob--${size}`,
        `knob--${accent}`,
        dragging ? "knob--dragging" : "",
        disabled ? "knob--disabled" : "",
        interactive ? "" : "knob--static",
      ]
        .filter(Boolean)
        .join(" ")}
      role="slider"
      tabIndex={disabled ? -1 : 0}
      aria-label={ariaLabel}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={Number(value.toFixed(4))}
      aria-valuetext={display}
      aria-disabled={disabled || undefined}
      title={`${ariaLabel} — drag or use arrow keys · shift = fine · double-click to reset`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
      onWheel={onWheel}
      onKeyDown={onKeyDown}
      onDoubleClick={onDoubleClick}
    >
      <svg
        className="knob__dial"
        width={diameter}
        height={diameter}
        viewBox={`0 0 ${diameter} ${diameter}`}
        aria-hidden="true"
      >
        <circle
          className="knob__track"
          cx={center}
          cy={center}
          r={radius}
          fill="none"
          strokeWidth={2}
          strokeLinecap="round"
          strokeDasharray={`${circumference * 0.75} ${circumference}`}
          transform={`rotate(135 ${center} ${center})`}
        />
        <circle
          className="knob__arc"
          cx={center}
          cy={center}
          r={radius}
          fill="none"
          strokeWidth={2}
          strokeLinecap="round"
          strokeDasharray={`${arcLength} ${circumference}`}
          transform={`rotate(135 ${center} ${center})`}
        />
        <line
          className="knob__pointer"
          x1={center + Math.cos(angle) * pointerInner}
          y1={center + Math.sin(angle) * pointerInner}
          x2={center + Math.cos(angle) * pointerOuter}
          y2={center + Math.sin(angle) * pointerOuter}
          strokeWidth={1.5}
          strokeLinecap="round"
        />
      </svg>
      <span className="knob__label">{label}</span>
      <span className="knob__value">{display}</span>
    </div>
  );
}
