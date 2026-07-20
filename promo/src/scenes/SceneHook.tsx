import React from "react";
import {
  AbsoluteFill,
  Audio,
  Sequence,
  staticFile,
  useCurrentFrame,
} from "remotion";
import { C, F } from "../tokens";
import { ramp, ENTER } from "../util";
import { useJitter } from "../components/bits";

const TOPLINE = "KEEPCO TAPE CO. — RECORDED ON A MAC, 2026";

const Slam: React.FC<{
  at: number;
  children: React.ReactNode;
  fontSize: number;
  color: string;
  rotate?: number;
  jitterTag: string;
}> = ({ at, children, fontSize, color, rotate = 0, jitterTag }) => {
  const frame = useCurrentFrame();
  const scale = ramp(frame, [at, at + 8], [1.6, 1]);
  const opacity = ramp(frame, [at, at + 3], [0, 1]);
  const j = useJitter(jitterTag, 6, 1.4);
  const settled = frame >= at + 8;
  return (
    <div
      style={{
        fontFamily: F.impact,
        fontSize,
        color,
        lineHeight: 0.94,
        letterSpacing: 1,
        opacity,
        transform: `scale(${scale}) rotate(${rotate}deg) translate(${settled ? j.x : 0}px, ${settled ? j.y : 0}px)`,
      }}
    >
      {children}
    </div>
  );
};

export const SceneHook: React.FC = () => {
  const frame = useCurrentFrame();

  const typed = TOPLINE.slice(0, Math.max(0, Math.floor((frame - 4) * 2.2)));
  const kicker = ramp(frame, [10, 26], [0, 1]);

  // camera thump when SHUT UP. lands
  const thump = frame < 44 ? 0 : ramp(frame, [44, 54], [12, 0]);
  const drift = ramp(frame, [0, 140], [1, 1.02], [0.45, 0, 0.55, 1]);

  return (
    <AbsoluteFill>
      <Sequence from={24}>
        <Audio src={staticFile("sfx/whip.wav")} volume={0.28} />
      </Sequence>
      <Sequence from={42}>
        <Audio src={staticFile("sfx/whip.wav")} volume={0.36} />
      </Sequence>

      <AbsoluteFill style={{ transform: `scale(${drift})` }}>
        {/* studio slate, top-left */}
        <div
          style={{
            position: "absolute",
            top: 64,
            left: 96,
            fontFamily: F.mono,
            fontWeight: 500,
            fontSize: 24,
            letterSpacing: 3,
            color: C.faint,
          }}
        >
          {typed}
          {typed.length < TOPLINE.length && frame > 4 ? (
            <span style={{ color: C.paper }}>▊</span>
          ) : null}
        </div>

        <AbsoluteFill
          style={{
            alignItems: "center",
            justifyContent: "center",
            transform: `translateY(${thump}px)`,
          }}
        >
          <div
            style={{
              fontFamily: F.marker,
              fontSize: 36,
              letterSpacing: 4,
              color: C.paper,
              opacity: kicker,
              transform: `translateY(${(1 - kicker) * 18}px) rotate(-1deg)`,
              marginBottom: 34,
            }}
          >
            A MENU-BAR TAPE DECK FOR MACOS
          </div>

          <Slam at={26} fontSize={152} color={C.cream} rotate={-1.1} jitterTag="l1">
            YOUR AI WON&apos;T
          </Slam>
          <div style={{ height: 18 }} />
          <Slam at={44} fontSize={300} color={C.paper} rotate={0.4} jitterTag="l2">
            SHUT UP.
          </Slam>

          <div
            style={{
              fontFamily: F.marker,
              fontSize: 40,
              color: C.dust,
              opacity: ramp(frame, [74, 86], [0, 1]),
              transform: `rotate(-2deg) translateY(${ramp(frame, [74, 86], [14, 0], ENTER)}px)`,
              marginTop: 44,
            }}
          >
            (finally, that&apos;s a feature.)
          </div>
        </AbsoluteFill>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
