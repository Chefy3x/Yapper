import React from "react";
import { random, useCurrentFrame } from "remotion";
import { C, F } from "../tokens";
import { envelopeAt } from "./envelope";
import { clamp01, ramp } from "../util";

/* ------------------------------------------------------------------ desktop */

/** Warm near-black desk with a soft key light and a faint film grain. */
export const Desk: React.FC<{ children?: React.ReactNode; glow?: number }> = ({
  children,
  glow = 1,
}) => {
  const frame = useCurrentFrame();
  return (
    <div style={{ position: "absolute", inset: 0, background: "#0a0908", overflow: "hidden" }}>
      <div
        style={{
          position: "absolute",
          inset: 0,
          background: `radial-gradient(120% 90% at 50% 8%, rgba(72,62,46,${0.5 * glow}) 0%, rgba(20,17,14,${0.9 * glow}) 46%, #090807 100%)`,
        }}
      />
      {/* grain */}
      <div style={{ position: "absolute", inset: 0, opacity: 0.05 }}>
        {new Array(150).fill(0).map((_, i) => {
          const t = Math.floor(frame / 2);
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                left: `${random(`gx-${i}-${t}`) * 100}%`,
                top: `${random(`gy-${i}-${t}`) * 100}%`,
                width: 2,
                height: 2,
                background: C.cream,
              }}
            />
          );
        })}
      </div>
      {children}
      {/* vignette */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          background: "radial-gradient(75% 70% at 50% 50%, rgba(0,0,0,0) 40%, rgba(0,0,0,0.62) 100%)",
          pointerEvents: "none",
        }}
      />
    </div>
  );
};

/* ----------------------------------------------------------------- menu bar */

/** The real menu-bar presence: SF Symbol "waveform", which lights up while reading. */
export const MenuBar: React.FC<{ reading?: boolean; width: number }> = ({
  reading = false,
  width,
}) => {
  const frame = useCurrentFrame();
  const bars = [0.42, 0.72, 1, 0.66, 0.34];
  return (
    <div
      style={{
        position: "absolute",
        top: 0,
        left: 0,
        width,
        height: 34,
        background: "rgba(14,12,10,0.72)",
        backdropFilter: "blur(18px)",
        borderBottom: "1px solid rgba(255,255,255,0.06)",
        display: "flex",
        alignItems: "center",
        justifyContent: "flex-end",
        gap: 20,
        paddingRight: 26,
      }}
    >
      <div style={{ display: "flex", alignItems: "flex-end", gap: 3, height: 17 }}>
        {bars.map((h, i) => {
          const lit = reading ? clamp01(Math.sin((frame / 5 - i * 0.7) % 6.283) + 0.45) : 0;
          return (
            <div
              key={i}
              style={{
                width: 2.6,
                height: 17 * h,
                borderRadius: 2,
                background: reading
                  ? `rgba(221,201,139,${0.42 + lit * 0.58})`
                  : "rgba(236,227,203,0.72)",
              }}
            />
          );
        })}
      </div>
      <div style={{ fontFamily: F.mono, fontSize: 12, color: "rgba(236,227,203,0.62)" }}>
        Tue 11:19
      </div>
    </div>
  );
};

/* ------------------------------------------------------------------- keycap */

export const Keycap: React.FC<{
  size: number;
  press: number; // 0..1
  label?: string;
  sub?: string;
}> = ({ size, press, label = "⌥", sub = "option" }) => {
  const travel = size * 0.035 * press;
  return (
    <div style={{ position: "relative", width: size, height: size }}>
      {/* well */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          borderRadius: size * 0.17,
          background: "#0b0a08",
          boxShadow: "inset 0 2px 8px rgba(0,0,0,0.9)",
        }}
      />
      <div
        style={{
          position: "absolute",
          inset: 0,
          transform: `translateY(${travel}px)`,
          borderRadius: size * 0.17,
          background: `linear-gradient(175deg, #3b3630 0%, #272420 46%, #191714 100%)`,
          border: "1px solid rgba(255,255,255,0.09)",
          boxShadow: `0 ${size * 0.055 * (1 - press)}px ${size * 0.09}px rgba(0,0,0,0.75), inset 0 1px 0 rgba(255,255,255,0.12)`,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          filter: `brightness(${1 - press * 0.16})`,
        }}
      >
        <div
          style={{
            fontFamily: UIFONT,
            fontSize: size * 0.42,
            lineHeight: 1,
            color: C.cream,
            fontWeight: 300,
          }}
        >
          {label}
        </div>
        <div
          style={{
            marginTop: size * 0.07,
            fontFamily: F.mono,
            fontSize: size * 0.1,
            letterSpacing: size * 0.012,
            color: C.dust,
            textTransform: "lowercase",
          }}
        >
          {sub}
        </div>
      </div>
    </div>
  );
};

const UIFONT = `-apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif`;

/* --------------------------------------------------------- audio-reactive UI */

/**
 * Real bars off the real voice: driven by READ_ENVELOPE, the measured per-frame
 * RMS of public/audio/read.mp3. The meter moves because the voice does, and it
 * goes still in the gaps between sentences — including the real 0.6s pause
 * before the last line.
 */
export const VoiceBars: React.FC<{
  width: number;
  height: number;
  bars?: number;
  /** frame relative to the start of read.mp3 */
  relFrame: number;
  color?: string;
}> = ({ width, height, bars = 48, relFrame, color = C.paper }) => {
  // perceptual lift: RMS is normalised to the track peak, so mid-level speech
  // sits near 0.25 and would otherwise barely register.
  const level = Math.min(1, Math.pow(envelopeAt(relFrame), 0.62) * 1.22);
  const mid = (bars - 1) / 2;
  const gap = width / bars;

  return (
    <div
      style={{ width, height, display: "flex", alignItems: "center", justifyContent: "space-between" }}
    >
      {new Array(bars).fill(0).map((_, i) => {
        const p = Math.abs(i - mid) / mid; // 0 centre → 1 edge
        const hump = Math.pow(Math.cos((p * Math.PI) / 2), 0.72);
        const wobble = 0.58 + 0.42 * Math.abs(Math.sin(i * 1.73 + relFrame * 0.62));
        const lvl = level * hump * wobble;
        return (
          <div
            key={i}
            style={{
              width: gap * 0.5,
              height: Math.max(height * 0.06, lvl * height),
              borderRadius: gap * 0.3,
              background: color,
              opacity: 0.3 + Math.min(1, lvl * 1.7) * 0.7,
            }}
          />
        );
      })}
    </div>
  );
};

/* -------------------------------------------------------------- paper cards */

/** A torn strip of tape-label paper. Ink type goes on this. */
export const Paper: React.FC<{
  width: number;
  children: React.ReactNode;
  rotate?: number;
  style?: React.CSSProperties;
}> = ({ width, children, rotate = 0, style }) => (
  <div
    style={{
      width,
      background: `linear-gradient(168deg, ${C.paperHi} 0%, ${C.paper} 58%, ${C.paperLo} 100%)`,
      boxShadow: "0 22px 48px rgba(0,0,0,0.55)",
      transform: `rotate(${rotate}deg)`,
      padding: width * 0.055,
      ...style,
    }}
  >
    {children}
  </div>
);

/** Index chip that rides every shot, like a track number on a tape sleeve. */
export const TrackChip: React.FC<{ n: string; label: string }> = ({ n, label }) => (
  <div
    style={{
      position: "absolute",
      left: 64,
      bottom: 56,
      display: "flex",
      alignItems: "center",
      gap: 12,
      fontFamily: F.mono,
      fontSize: 19,
      letterSpacing: 2.6,
      color: C.faint,
    }}
  >
    <span style={{ color: C.paper }}>{n}</span>
    <span style={{ width: 26, height: 1, background: C.line }} />
    <span>{label}</span>
  </div>
);

/** Two-frame white flash on a cut. */
export const Flash: React.FC<{ at: number }> = ({ at }) => {
  const frame = useCurrentFrame();
  const o = ramp(frame, [at, at + 3], [0.3, 0], [0.4, 0, 1, 1]);
  if (frame < at || o <= 0.002) return null;
  return <div style={{ position: "absolute", inset: 0, background: C.cream, opacity: o }} />;
};
