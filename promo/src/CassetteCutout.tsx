import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { C } from "./tokens";
import { ramp, clamp01, GLIDE } from "./util";
import { CassetteDeck, reelAngleAt } from "./components/CassetteDeck";

// 3 seconds @ 30fps — just the cassette, working.
export const CUTOUT_DURATION = 90;
export const CUTOUT_W = 1280;
export const CUTOUT_H = 800;

const DECK_W = 1120;

const PLAY_AT = 12; // press Play — reels spin up
const FF_AT = 58; // tap FF — reels kick faster
const SPEED_STEPS = [{ frame: FF_AT + 4, mult: 1.5 }];

/** Momentary key dip: down fast, back up — for the FF tap. */
const pulse = (frame: number, at: number): number =>
  frame < at
    ? 0
    : clamp01(ramp(frame, [at, at + 4], [0, 1]) - ramp(frame, [at + 9, at + 15], [0, 1]));

export type CutoutProps = {
  /** Transparent alpha output — no backdrop, no floor shadow. */
  transparent?: boolean;
};

export const CassetteCutout: React.FC<CutoutProps> = ({ transparent = false }) => {
  const frame = useCurrentFrame();

  // Deck settles in, then breathes with a whisper of wobble so it feels alive.
  const deckIn = ramp(frame, [0, 10], [0, 1]);
  const settle = ramp(frame, [0, 14], [1.035, 1], GLIDE);
  const wobble = Math.sin(frame * 0.045) * 0.12;

  const angle = reelAngleAt(frame, PLAY_AT, SPEED_STEPS);
  const playDepth = ramp(frame, [PLAY_AT, PLAY_AT + 6], [0, 1]); // latches down
  const ffDepth = pulse(frame, FF_AT); // momentary

  return (
    <AbsoluteFill
      style={{
        background: transparent
          ? "transparent"
          : `radial-gradient(ellipse 70% 60% at 50% 42%, #1e1e1e 0%, #141414 52%, #0c0c0c 100%)`,
      }}
    >
      {/* Soft floor shadow so the deck is grounded — only meaningful over a backdrop */}
      {transparent ? null : (
        <div
          style={{
            position: "absolute",
            left: "50%",
            top: 752,
            width: DECK_W * 0.82,
            height: 54,
            transform: "translate(-50%, -50%)",
            borderRadius: "50%",
            background:
              "radial-gradient(ellipse at center, rgba(0,0,0,0.72) 0%, rgba(0,0,0,0) 70%)",
            filter: "blur(14px)",
            opacity: deckIn * 0.9,
          }}
        />
      )}

      {/* The deck itself — the cutout, working */}
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: "47%",
          opacity: deckIn,
          transform: `translate(-50%, -50%) scale(${settle}) rotate(${wobble}deg)`,
          // Keep the deck's own shadow (it travels with the object); trim it in
          // transparent mode so it never clips the frame edge on composite.
          filter: transparent
            ? "drop-shadow(0 20px 30px rgba(0,0,0,0.45))"
            : "drop-shadow(0 32px 46px rgba(0,0,0,0.6))",
        }}
      >
        <CassetteDeck
          width={DECK_W}
          reelAngle={angle}
          capDepths={{ play: playDepth, ff: ffDepth }}
        />
      </div>
    </AbsoluteFill>
  );
};
