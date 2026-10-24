import { useCallback, useEffect, useRef, useState } from "react";
import type { TrackData } from "../types/types.ts";
import type { FxState, TrackFxSettings } from "../lib/fx.ts";
import { masterModuleCount, trackFxBadges, fxModuleCount } from "../lib/fx.ts";
import { EqModule } from "./fx/EqModule.tsx";
import { CompModule } from "./fx/CompModule.tsx";
import { SendModule } from "./fx/SendModule.tsx";
import { ReverbModule } from "./fx/ReverbModule.tsx";
import { DelayModule } from "./fx/DelayModule.tsx";
import { WidthModule } from "./fx/WidthModule.tsx";
import { LimiterModule } from "./fx/LimiterModule.tsx";

export type FxTab = number | "master";

export interface FxMeterState {
  playing: boolean;
  trackGr: number[];
  trackPeakGr: number[];
  masterGr: number;
  masterPeakGr: number;
  limiterGr: number;
  limiterPeakGr: number;
  peakDb: number;
}

interface FxRackProps {
  open: boolean;
  tab: FxTab;
  state: FxState;
  tracks: TrackData[];
  bpm: number;
  meters: FxMeterState;
  onTabChange: (tab: FxTab) => void;
  onChange: (next: FxState) => void;
  onClose: () => void;
}

export function FxRack({
  open,
  tab,
  state,
  tracks,
  bpm,
  meters,
  onTabChange,
  onChange,
  onClose,
}: FxRackProps) {
  const chainRef = useRef<HTMLDivElement>(null);
  const [canLeft, setCanLeft] = useState(false);
  const [canRight, setCanRight] = useState(false);

  const updateScroll = useCallback(() => {
    const el = chainRef.current;
    if (!el) return;
    setCanLeft(el.scrollLeft > 4);
    setCanRight(el.scrollLeft + el.clientWidth < el.scrollWidth - 4);
  }, []);

  useEffect(() => {
    if (!open) return;
    updateScroll();
    const el = chainRef.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(updateScroll);
    observer.observe(el);
    return () => observer.disconnect();
  }, [open, tab, updateScroll]);

  useEffect(() => {
    if (!open) return;
    const el = chainRef.current;
    if (el) el.scrollLeft = 0;
    updateScroll();
  }, [open, tab, updateScroll]);

  if (!open) return null;

  const scrollChain = (direction: 1 | -1) => {
    const el = chainRef.current;
    if (!el) return;
    el.scrollLeft += direction * Math.max(240, el.clientWidth * 0.65);
  };

  const tabs: Array<{ id: FxTab; label: string; lit: boolean }> = [
    ...tracks.map((track, i) => ({
      id: i as FxTab,
      label: String(track.id + 1),
      lit: state.tracks[i] ? fxModuleCount(state.tracks[i]) > 0 : false,
    })),
    { id: "master" as FxTab, label: "MST", lit: masterModuleCount(state) > 0 },
  ];

  const updateTrack = (index: number, patch: Partial<TrackFxSettings>) => {
    onChange({
      ...state,
      tracks: state.tracks.map((track, i) => (i === index ? { ...track, ...patch } : track)),
    });
  };

  const updateComp = (index: number, patch: Partial<TrackFxSettings["comp"]>) => {
    const current = state.tracks[index];
    updateTrack(index, { comp: { ...current.comp, ...patch } });
  };

  const trackIndex = typeof tab === "number" ? tab : 0;
  const trackFx = state.tracks[trackIndex];
  const isMaster = tab === "master";
  const activeTrack = tracks[trackIndex];

  const summary = isMaster
    ? "MASTER"
    : `TRACK ${activeTrack ? activeTrack.id + 1 : trackIndex + 1}`;

  return (
    <section className="fx-rack" aria-label="Effects rack">
      <header className="fx-rack__head">
        <span className="fx-rack__title">FX</span>
        <div className="fx-tabs" role="tablist" aria-label="Effects channel">
          {tabs.map((t) => (
            <button
              key={String(t.id)}
              type="button"
              role="tab"
              aria-selected={tab === t.id}
              className={`fx-tab ${tab === t.id ? "fx-tab--active" : ""} ${t.lit ? "fx-tab--lit" : ""}`}
              onClick={() => onTabChange(t.id)}
              title={t.id === "master" ? "Master bus" : `Track ${Number(t.id) + 1} effects`}
            >
              {t.label}
              {t.lit ? <span className="fx-tab__dot" aria-hidden="true" /> : null}
            </button>
          ))}
        </div>
        <span className="fx-rack__channel">{summary}</span>
        <span className="fx-rack__hint">drag / scroll · shift = fine · dbl-click = reset</span>
        <button type="button" className="fx-rack__close" onClick={onClose} aria-label="Close effects rack" title="Close (x)">
          ✕
        </button>
      </header>

      <div className="fx-chain-wrap">
        <div
          className="fx-chain"
          role="tabpanel"
          aria-label={`${summary} effects chain`}
          ref={chainRef}
          onScroll={updateScroll}
          onWheel={(event) => {
            const el = event.currentTarget;
            if (el.scrollWidth <= el.clientWidth) return;
            if (Math.abs(event.deltaY) > Math.abs(event.deltaX)) {
              el.scrollLeft += event.deltaY;
            }
          }}
        >
          {isMaster ? (
          <>
            <CompModule
              name="COMP"
              index={1}
              params={state.masterComp}
              onChange={(patch) =>
                onChange({ ...state, masterComp: { ...state.masterComp, ...patch } })
              }
              gr={meters.masterGr}
              peakGr={meters.masterPeakGr}
            />
            <ReverbModule
              params={state.reverb}
              onChange={(patch) => onChange({ ...state, reverb: { ...state.reverb, ...patch } })}
            />
            <DelayModule
              params={state.delay}
              bpm={bpm}
              onChange={(patch) => onChange({ ...state, delay: { ...state.delay, ...patch } })}
            />
            <WidthModule
              params={state.width}
              onChange={(patch) => onChange({ ...state, width: { ...state.width, ...patch } })}
            />
            <LimiterModule
              params={state.limiter}
              peakDb={meters.peakDb}
              gr={meters.limiterGr}
              peakGr={meters.limiterPeakGr}
              onChange={(patch) => onChange({ ...state, limiter: { ...state.limiter, ...patch } })}
            />
          </>
        ) : (
          <>
            <EqModule
              params={trackFx.eq}
              onChange={(patch) => updateTrack(trackIndex, { eq: { ...trackFx.eq, ...patch } })}
            />
            <CompModule
              params={trackFx.comp}
              onChange={(patch) => updateComp(trackIndex, patch)}
              gr={meters.trackGr[trackIndex] ?? 0}
              peakGr={meters.trackPeakGr[trackIndex] ?? 0}
            />
            <SendModule
              fx={trackFx}
              onChange={(patch) => updateTrack(trackIndex, patch)}
              reverbOn={state.reverb.enabled}
              delayOn={state.delay.enabled}
            />
          </>
        )}
        </div>

        {canLeft ? (
          <button
            type="button"
            className="fx-chain__nav fx-chain__nav--left"
            onClick={() => scrollChain(-1)}
            aria-label="Scroll effects left"
            title="Previous modules"
          >
            ‹
          </button>
        ) : null}
        {canRight ? (
          <button
            type="button"
            className="fx-chain__nav fx-chain__nav--right"
            onClick={() => scrollChain(1)}
            aria-label="Scroll effects right"
            title="More modules"
          >
            ›
          </button>
        ) : null}
      </div>

      <footer className="fx-rack__foot">
        <span className="fx-rack__badges">
          {isMaster
            ? [
                state.masterComp.enabled ? "COMP" : null,
                state.reverb.enabled ? "REV" : null,
                state.delay.enabled ? "DLY" : null,
                state.width.enabled ? "WIDTH" : null,
                state.limiter.enabled ? "LIM" : null,
              ]
                .filter(Boolean)
                .join(" · ") || "ALL BYPASSED"
            : trackFxBadges(trackFx).join(" · ") || "NO INSERTS"}
        </span>
        <span className="fx-rack__status">
          {meters.playing ? "LIVE METERS" : "PLAY MIX TO AUDITION · x CLOSES"}
        </span>
      </footer>
    </section>
  );
}
