import React from "react";
import { Img, staticFile } from "remotion";
import { C, F } from "../tokens";

/**
 * The real Yapper deck, rebuilt from the app's registered sprite cutouts.
 * All geometry comes from CassettePlayerView.swift — fractions of the deck
 * face (the body PNG's alpha bbox), measured there from the shared canvas.
 */

const REELS = {
  left: { cx: 35.15, cy: 47.56, d: 9.4 },
  right: { cx: 66.92, cy: 47.33, d: 9.68 },
} as const;

export type CapName = "rew" | "play" | "stop" | "ff" | "rec";

const CAPS: Record<CapName, { cx: number; cy: number; w: number; h: number }> = {
  rew: { cx: 31.02, cy: 90.78, w: 9.96, h: 13.26 },
  play: { cx: 40.74, cy: 91.08, w: 10.43, h: 13.57 },
  stop: { cx: 50.8, cy: 90.93, w: 10.62, h: 13.26 },
  ff: { cx: 60.86, cy: 90.85, w: 10.43, h: 13.11 },
  rec: { cx: 71.24, cy: 90.85, w: 9.96, h: 13.11 },
};

const Reel: React.FC<{
  side: "left" | "right";
  angle: number;
}> = ({ side, angle }) => {
  const r = REELS[side];
  return (
    <>
      {/* Dark backing disc so body pixels never peek out from behind the spinning cutout */}
      <div
        style={{
          position: "absolute",
          left: `${r.cx}%`,
          top: `${r.cy}%`,
          width: `${r.d * 1.08}%`,
          aspectRatio: "1 / 1",
          transform: "translate(-50%, -50%)",
          borderRadius: "50%",
          background: "#0a0806",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: `${r.cx}%`,
          top: `${r.cy}%`,
          width: `${r.d}%`,
          aspectRatio: "1 / 1",
          transform: `translate(-50%, -50%) rotate(${angle}deg)`,
        }}
      >
        <Img
          src={staticFile(`cassette-reel-${side}.png`)}
          style={{ width: "100%", height: "100%" }}
        />
      </div>
    </>
  );
};

const Cap: React.FC<{
  name: CapName;
  depth: number; // 0 = at rest, 1 = fully sunk
  deckWidth: number;
}> = ({ name, depth, deckWidth }) => {
  const c = CAPS[name];
  const radius = deckWidth * 0.018;
  return (
    <>
      {/* Recess revealed as the cap sinks — hidden at rest, the sprite covers it exactly */}
      <div
        style={{
          position: "absolute",
          left: `${c.cx}%`,
          top: `${c.cy}%`,
          width: `${c.w}%`,
          height: `${c.h}%`,
          transform: "translate(-50%, -50%)",
          borderRadius: radius,
          background: "#070503",
          opacity: 0.92 * depth,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: `${c.cx}%`,
          top: `${c.cy}%`,
          width: `${c.w}%`,
          height: `${c.h}%`,
          transform: `translate(-50%, calc(-50% + ${depth * 13}%)) scale(${1 - depth * 0.02})`,
          filter: `brightness(${1 - depth * 0.28})`,
        }}
      >
        <Img
          src={staticFile(`cassette-cap-${name}.png`)}
          style={{ width: "100%", height: "100%" }}
        />
      </div>
    </>
  );
};

export type DeckProps = {
  width: number;
  reelAngle: number;
  capDepths?: Partial<Record<CapName, number>>;
  speedLabel?: string | null;
  speedPop?: number; // 0..1 scale-pop progress when the pill changes
  style?: React.CSSProperties;
};

export const CassetteDeck: React.FC<DeckProps> = ({
  width,
  reelAngle,
  capDepths = {},
  speedLabel = null,
  speedPop = 0,
  style,
}) => {
  return (
    <div style={{ position: "relative", width, ...style }}>
      <Img
        src={staticFile("cassette-deck.png")}
        style={{ width: "100%", display: "block" }}
      />
      <Reel side="left" angle={reelAngle} />
      <Reel side="right" angle={reelAngle} />
      {(Object.keys(CAPS) as CapName[]).map((name) => (
        <Cap
          key={name}
          name={name}
          depth={capDepths[name] ?? 0}
          deckWidth={width}
        />
      ))}
      {speedLabel ? (
        <div
          style={{
            position: "absolute",
            right: "5.2%",
            bottom: "6.5%",
            transform: `scale(${1 + speedPop * 0.18})`,
            background: "rgba(10,8,6,0.88)",
            border: `1px solid ${C.line}`,
            color: C.cream,
            fontFamily: F.mono,
            fontWeight: 600,
            fontSize: width * 0.026,
            padding: `${width * 0.006}px ${width * 0.016}px`,
            borderRadius: 999,
            letterSpacing: 1,
          }}
        >
          {speedLabel}
        </div>
      ) : null}
    </div>
  );
};

/**
 * Reel rotation, integrated per frame like the app does it: spin-up ramp at
 * pressFrame, then speed multiplier steps (FF presses). Pause-clean and exact.
 */
export const reelAngleAt = (
  frame: number,
  pressFrame: number,
  speedSteps: { frame: number; mult: number }[] = [],
): number => {
  const degPerSecond = 210;
  let angle = 0;
  for (let f = 0; f < frame; f++) {
    const spinUp = Math.min(1, Math.max(0, (f - pressFrame) / 18));
    let mult = 1;
    for (const s of speedSteps) {
      if (f >= s.frame) mult = s.mult;
    }
    angle += (degPerSecond / 30) * spinUp * mult;
  }
  return angle;
};
