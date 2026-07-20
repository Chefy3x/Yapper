import React from "react";
import {
  AbsoluteFill,
  Audio,
  Sequence,
  random,
  staticFile,
  useCurrentFrame,
} from "remotion";
import { C, F } from "../tokens";
import { ramp, clamp01, GLIDE } from "../util";
import { CassetteDeck, reelAngleAt } from "../components/CassetteDeck";

const PLAY_AT = 24;
const SWAP_AT = 118;
const FF1 = 150;
const FF2 = 166;
const SPEED_STEPS = [
  { frame: FF1 + 4, mult: 1.25 },
  { frame: FF2 + 4, mult: 1.5 },
];

/** Integrated waveform phase so the bars visibly dance faster after each FF press. */
const wavePhaseAt = (frame: number): number => {
  let phase = 0;
  for (let f = 0; f < frame; f++) {
    let mult = 1;
    for (const s of SPEED_STEPS) if (f >= s.frame) mult = s.mult;
    phase += 0.3 * mult;
  }
  return phase;
};

const pulse = (frame: number, at: number): number =>
  frame < at
    ? 0
    : clamp01(ramp(frame, [at, at + 4], [0, 1]) - ramp(frame, [at + 8, at + 14], [0, 1]));

const Keycap: React.FC<{ dip: number }> = ({ dip }) => (
  <span
    style={{
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      width: 118,
      height: 118,
      marginLeft: 10,
      borderRadius: 22,
      background: C.panel2,
      border: `2px solid ${C.line}`,
      boxShadow: `0 ${10 - dip * 7}px 0 rgba(0,0,0,0.5), inset 0 2px 0 rgba(236,227,203,0.10)`,
      transform: `translateY(${dip * 7}px) scale(${1 - dip * 0.04})`,
      fontFamily: `${F.mono}, -apple-system, "Apple Symbols", sans-serif`,
      fontSize: 66,
      color: C.cream,
      verticalAlign: "middle",
    }}
  >
    ⌘
  </span>
);

const Waveform: React.FC<{ frame: number; opacity: number }> = ({ frame, opacity }) => {
  const phase = wavePhaseAt(frame);
  return (
    <div style={{ position: "absolute", right: 100, top: 250, opacity, textAlign: "right" }}>
      <div
        style={{
          fontFamily: F.mono,
          fontSize: 20,
          letterSpacing: 3,
          color: C.faint,
          marginBottom: 16,
        }}
      >
        NOW SPEAKING — CLAUDE&apos;S ANSWER
      </div>
      <div
        style={{
          display: "flex",
          gap: 5,
          alignItems: "flex-end",
          height: 46,
          justifyContent: "flex-end",
        }}
      >
        {Array.from({ length: 18 }).map((_, i) => {
          const h = 7 + Math.abs(Math.sin(phase + i * 0.87)) * (12 + random(`bar-${i}`) * 26);
          return (
            <div
              key={i}
              style={{
                width: 7,
                height: h,
                borderRadius: 3,
                background: C.cream,
                opacity: 0.75,
              }}
            />
          );
        })}
      </div>
    </div>
  );
};

export const SceneDeck: React.FC = () => {
  const frame = useCurrentFrame();

  const slideY = ramp(frame, [0, 20], [520, 0], GLIDE);
  const deckIn = ramp(frame, [0, 8], [0, 1]);

  const playDepth = ramp(frame, [PLAY_AT, PLAY_AT + 6], [0, 1]);
  const ffDepth = clamp01(pulse(frame, FF1) + pulse(frame, FF2));
  const angle = reelAngleAt(frame, PLAY_AT, SPEED_STEPS);

  const keyDip = pulse(frame, PLAY_AT - 2);

  const h1In = ramp(frame, [10, 18], [1.5, 1]);
  const h1Op = ramp(frame, [10, 13], [0, 1]) - ramp(frame, [SWAP_AT - 4, SWAP_AT], [0, 1]);
  const h2In = ramp(frame, [SWAP_AT + 2, SWAP_AT + 10], [1.5, 1]);
  const h2Op = ramp(frame, [SWAP_AT + 2, SWAP_AT + 5], [0, 1]);

  const subIn = ramp(frame, [34, 48], [0, 1]);
  const waveIn = ramp(frame, [40, 52], [0, 1]);

  const speedLabel = frame >= FF2 + 4 ? "1.5×" : frame >= FF1 + 4 ? "1.25×" : "1×";
  const speedPop = clamp01(pulse(frame, FF1 + 4) + pulse(frame, FF2 + 4));

  const annIn = ramp(frame, [174, 186], [0, 1]);
  const arrowDraw = ramp(frame, [176, 194], [0, 1]);
  const footIn = ramp(frame, [210, 224], [0, 1]);

  const wobble = Math.sin(frame * 0.045) * 0.12;

  return (
    <AbsoluteFill>
      <Sequence from={0}>
        <Audio src={staticFile("sfx/whoosh.wav")} volume={0.34} />
      </Sequence>
      <Sequence from={PLAY_AT}>
        <Audio src={staticFile("sfx/switch.wav")} volume={0.45} />
      </Sequence>
      <Sequence from={SWAP_AT}>
        <Audio src={staticFile("sfx/whip.wav")} volume={0.26} />
      </Sequence>
      <Sequence from={FF1}>
        <Audio src={staticFile("sfx/switch.wav")} volume={0.32} />
      </Sequence>
      <Sequence from={FF2}>
        <Audio src={staticFile("sfx/switch.wav")} volume={0.32} />
      </Sequence>

      {/* headline: TAP RIGHT ⌘. → WALK AWAY. */}
      <div
        style={{
          position: "absolute",
          top: 88,
          width: "100%",
          textAlign: "center",
        }}
      >
        <div style={{ position: "relative", height: 170 }}>
          <div
            style={{
              position: "absolute",
              width: "100%",
              fontFamily: F.impact,
              fontSize: 128,
              color: C.cream,
              letterSpacing: 1,
              opacity: h1Op,
              transform: `scale(${h1In}) rotate(-0.6deg)`,
            }}
          >
            TAP RIGHT
            <Keycap dip={keyDip} />
            <span style={{ color: C.paper, marginLeft: 16 }}>.</span>
          </div>
          <div
            style={{
              position: "absolute",
              width: "100%",
              fontFamily: F.impact,
              fontSize: 150,
              color: C.cream,
              opacity: h2Op,
              transform: `scale(${h2In}) rotate(0.4deg)`,
            }}
          >
            WALK <span style={{ color: C.paper }}>AWAY.</span>
          </div>
        </div>
        <div
          style={{
            fontFamily: F.marker,
            fontSize: 42,
            color: C.dust,
            opacity: subIn,
            transform: `translateY(${(1 - subIn) * 16}px) rotate(-1deg)`,
            marginTop: 12,
          }}
        >
          the answer follows you across the room
        </div>
      </div>

      <Waveform frame={frame} opacity={waveIn} />

      {/* the deck itself */}
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: "61.5%",
          opacity: deckIn,
          transform: `translate(-50%, -50%) translateY(${slideY}px) rotate(${-1.2 + wobble}deg)`,
          filter: "drop-shadow(0 44px 70px rgba(0,0,0,0.55))",
        }}
      >
        <CassetteDeck
          width={1060}
          reelAngle={angle}
          capDepths={{ play: playDepth, ff: ffDepth }}
          speedLabel={frame >= PLAY_AT ? speedLabel : null}
          speedPop={speedPop}
        />
      </div>

      {/* FF annotation */}
      <div
        style={{
          position: "absolute",
          right: 70,
          top: 600,
          width: 400,
          textAlign: "center",
          fontFamily: F.marker,
          fontSize: 40,
          color: C.paper,
          opacity: annIn,
          transform: `rotate(2deg) translateY(${(1 - annIn) * 14}px)`,
        }}
      >
        FF really does
        <br />
        play it faster
      </div>
      <svg
        width={1920}
        height={1080}
        viewBox="0 0 1920 1080"
        style={{ position: "absolute", inset: 0, pointerEvents: "none", opacity: annIn }}
      >
        <path
          d="M 1520 748 Q 1330 908 1108 892"
          fill="none"
          stroke={C.paper}
          strokeWidth={7}
          strokeLinecap="round"
          pathLength={1}
          strokeDasharray={1}
          strokeDashoffset={1 - arrowDraw}
        />
        <g opacity={arrowDraw >= 1 ? 1 : 0}>
          <path
            d="M 1108 892 l 34 -20 M 1108 892 l 32 16"
            fill="none"
            stroke={C.paper}
            strokeWidth={7}
            strokeLinecap="round"
          />
        </g>
      </svg>

      <div
        style={{
          position: "absolute",
          bottom: 42,
          width: "100%",
          textAlign: "center",
          fontFamily: F.mono,
          fontSize: 25,
          letterSpacing: 2,
          color: C.dust,
          opacity: footIn,
        }}
      >
        REW slows it back down · STOP closes · it&apos;s a real tape deck
      </div>
    </AbsoluteFill>
  );
};
