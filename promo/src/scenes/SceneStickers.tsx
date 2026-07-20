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
import { AdvisoryPatch } from "../components/bits";

/** A sticker slapped onto the shell: overshoot scale, fixed rotation, heavy shadow. */
const Slap: React.FC<{
  at: number;
  x: number;
  y: number;
  rotate: number;
  children: React.ReactNode;
}> = ({ at, x, y, rotate, children }) => {
  const frame = useCurrentFrame();
  const s = ramp(frame, [at, at + 9], [1.45, 1], POP);
  const o = ramp(frame, [at, at + 3], [0, 1]);
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        opacity: o,
        transform: `translate(-50%, -50%) rotate(${rotate}deg) scale(${s})`,
        filter: "drop-shadow(0 20px 32px rgba(0,0,0,0.5))",
      }}
    >
      {children}
    </div>
  );
};

const PaperLabel: React.FC<{
  width: number;
  title: React.ReactNode;
  sub: string;
  titleSize?: number;
}> = ({ width, title, sub, titleSize = 58 }) => (
  <div
    style={{
      width,
      background: `linear-gradient(160deg, ${C.paperHi}, ${C.paper} 55%, ${C.paperLo})`,
      borderRadius: 12,
      padding: "34px 40px 30px",
      boxShadow: "inset 0 0 0 1px rgba(24,18,6,0.18)",
    }}
  >
    <div
      style={{
        fontFamily: F.impact,
        fontSize: titleSize,
        lineHeight: 0.98,
        color: C.ink,
        letterSpacing: 0.5,
      }}
    >
      {title}
    </div>
    <div
      style={{
        marginTop: 14,
        fontFamily: F.mono,
        fontWeight: 500,
        fontSize: 24,
        color: C.inkSoft,
        letterSpacing: 0.5,
      }}
    >
      {sub}
    </div>
  </div>
);

export const SceneStickers: React.FC = () => {
  const frame = useCurrentFrame();
  const headIn = ramp(frame, [4, 16], [0, 1]);
  const chipIn = ramp(frame, [172, 186], [0, 1]);

  return (
    <AbsoluteFill>
      {[10, 52, 94, 136].map((at, i) => (
        <Sequence key={at} from={at}>
          <Audio
            src={staticFile(i % 2 === 0 ? "sfx/whip.wav" : "sfx/switch.wav")}
            volume={0.26}
          />
        </Sequence>
      ))}

      <div
        style={{
          position: "absolute",
          top: 78,
          left: 110,
          fontFamily: F.marker,
          fontSize: 44,
          color: C.dust,
          opacity: headIn,
          transform: `rotate(-1.6deg) translateY(${(1 - headIn) * 14}px)`,
        }}
      >
        what&apos;s on the tape —
      </div>

      <Slap at={10} x={545} y={340} rotate={-2.4}>
        <PaperLabel
          width={700}
          title={
            <>
              READS CLAUDE,
              <br />
              CHATGPT &amp; CODEX
            </>
          }
          sub="— or anything you highlight, in any app"
        />
      </Slap>

      <Slap at={52} x={1355} y={318} rotate={1.8}>
        <AdvisoryPatch top="SKIPS THE" bottom="CODE BLOCKS" width={430} />
      </Slap>

      <Slap at={94} x={560} y={702} rotate={1.2}>
        <div
          style={{
            width: 700,
            background: C.panel2,
            border: `1px solid ${C.line}`,
            borderRadius: 12,
            padding: "34px 40px",
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 22 }}>
            <div
              style={{
                width: 26,
                height: 26,
                flexShrink: 0,
                borderRadius: "50%",
                background: C.redHot,
                boxShadow: `0 0 16px ${C.redHot}`,
              }}
            />
            <div
              style={{
                fontFamily: F.impact,
                fontSize: 45,
                color: C.cream,
                letterSpacing: 1,
                whiteSpace: "nowrap",
              }}
            >
              REC = CONVERSATION MODE
            </div>
          </div>
          <div
            style={{
              marginTop: 14,
              fontFamily: F.marker,
              fontSize: 30,
              color: C.paper,
            }}
          >
            every new answer, read aloud. hands off.
          </div>
        </div>
      </Slap>

      <Slap at={136} x={1360} y={700} rotate={-1.6}>
        <PaperLabel
          width={520}
          titleSize={54}
          title="HISTORY ON TAPE"
          sub="replay anything · rolls off after 24h"
        />
      </Slap>

      <div
        style={{
          position: "absolute",
          bottom: 64,
          width: "100%",
          display: "flex",
          justifyContent: "center",
          opacity: chipIn,
        }}
      >
        <div
          style={{
            fontFamily: F.mono,
            fontWeight: 500,
            fontSize: 25,
            letterSpacing: 1.5,
            color: C.dust,
            border: `1px solid ${C.line}`,
            borderRadius: 999,
            padding: "14px 34px",
            background: "rgba(22,19,16,0.7)",
          }}
        >
          offline? it drops to the native voice — a read never fails silent
        </div>
      </div>
    </AbsoluteFill>
  );
};
