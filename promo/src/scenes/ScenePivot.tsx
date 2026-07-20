import React from "react";
import {
  AbsoluteFill,
  Audio,
  Sequence,
  staticFile,
  useCurrentFrame,
} from "remotion";
import { C, F } from "../tokens";
import { ramp, POP } from "../util";

export const ScenePivot: React.FC = () => {
  const frame = useCurrentFrame();

  const good = ramp(frame, [6, 14], [0, 1], POP);
  const stop = ramp(frame, [18, 26], [0, 1]);
  const strike = ramp(frame, [30, 44], [0, 1], [0.7, 0, 0.84, 0]);
  const listenWipe = ramp(frame, [52, 70], [0, 1]);
  const listenRise = ramp(frame, [52, 68], [26, 0]);
  const drift = ramp(frame, [0, 118], [1, 1.018], [0.45, 0, 0.55, 1]);

  return (
    <AbsoluteFill>
      <Sequence from={42}>
        <Audio src={staticFile("sfx/switch.wav")} volume={0.4} />
      </Sequence>
      <Sequence from={52}>
        <Audio src={staticFile("sfx/whoosh.wav")} volume={0.22} />
      </Sequence>

      <AbsoluteFill
        style={{
          alignItems: "center",
          justifyContent: "center",
          transform: `scale(${drift})`,
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "baseline",
            gap: 42,
            fontFamily: F.marker,
            fontSize: 96,
            color: C.cream,
          }}
        >
          <span
            style={{
              opacity: good,
              transform: `scale(${0.8 + good * 0.2}) rotate(-1.5deg)`,
              display: "inline-block",
            }}
          >
            good —
          </span>
          <span
            style={{
              position: "relative",
              display: "inline-block",
              opacity: stop,
              transform: "rotate(0.6deg)",
              color: C.dust,
            }}
          >
            stop reading
            <div
              style={{
                position: "absolute",
                left: "-3%",
                top: "52%",
                width: "106%",
                height: 11,
                borderRadius: 6,
                background: C.redHot,
                transformOrigin: "left center",
                transform: `scaleX(${strike}) rotate(-2.2deg)`,
                boxShadow: "0 2px 6px rgba(0,0,0,0.35)",
              }}
            />
          </span>
        </div>

        <div
          style={{
            marginTop: 40,
            fontFamily: F.marker,
            fontSize: 148,
            color: C.paper,
            transform: `rotate(-1.2deg) translateY(${listenRise}px)`,
            clipPath: `inset(-20% ${(1 - listenWipe) * 100}% -20% -5%)`,
          }}
        >
          start listening.
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
