import React from "react";
import {
  AbsoluteFill,
  Audio,
  Img,
  Sequence,
  staticFile,
  useCurrentFrame,
} from "remotion";
import { C, F } from "../tokens";
import { ramp, POP } from "../util";
import { Chip, SkullSticker } from "../components/bits";

const BLACKOUT = 122;
const END_TYPE = "A MENU-BAR TAPE DECK FOR MACOS";

const InkChip: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <span
    style={{
      fontFamily: F.mono,
      fontWeight: 600,
      fontSize: 24,
      letterSpacing: 2,
      color: C.ink,
      border: "2px solid rgba(24,18,6,0.55)",
      borderRadius: 8,
      padding: "8px 16px",
      whiteSpace: "nowrap",
    }}
  >
    {children}
  </span>
);

export const SceneOutro: React.FC = () => {
  const frame = useCurrentFrame();

  const cardIn = ramp(frame, [8, 18], [1.3, 1], POP);
  const cardOp = ramp(frame, [8, 12], [0, 1]);
  const chips = ramp(frame, [24, 36], [0, 1]);
  const skullIn = ramp(frame, [36, 44], [0, 1], POP);
  const callback = ramp(frame, [52, 64], [0, 1]);
  const press = ramp(frame, [84, 94], [0, 1]);
  const capDepth = frame < 112 ? 0 : ramp(frame, [112, 117], [0, 1]);

  const flash = frame >= BLACKOUT - 2 && frame < BLACKOUT;
  const ended = frame >= BLACKOUT;

  const endTitle = ramp(frame, [BLACKOUT + 4, BLACKOUT + 12], [1.4, 1], POP);
  const endTitleOp = ramp(frame, [BLACKOUT + 4, BLACKOUT + 8], [0, 1]);
  const typed = END_TYPE.slice(
    0,
    Math.max(0, Math.floor((frame - (BLACKOUT + 14)) * 1.6)),
  );
  const endChips = ramp(frame, [BLACKOUT + 42, BLACKOUT + 54], [0, 1]);

  return (
    <AbsoluteFill>
      <Sequence from={6}>
        <Audio src={staticFile("sfx/whoosh.wav")} volume={0.3} />
      </Sequence>
      <Sequence from={14}>
        <Audio src={staticFile("sfx/switch.wav")} volume={0.3} />
      </Sequence>
      <Sequence from={36}>
        <Audio src={staticFile("sfx/whip.wav")} volume={0.22} />
      </Sequence>
      <Sequence from={112}>
        <Audio src={staticFile("sfx/switch.wav")} volume={0.45} />
      </Sequence>

      {!ended ? (
        <AbsoluteFill style={{ alignItems: "center" }}>
          {/* the tape label */}
          <div
            style={{
              position: "absolute",
              top: 150,
              opacity: cardOp,
              transform: `rotate(-1.2deg) scale(${cardIn})`,
              filter: "drop-shadow(0 34px 60px rgba(0,0,0,0.55))",
            }}
          >
            <div
              style={{
                width: 1280,
                borderRadius: 16,
                background: `linear-gradient(160deg, ${C.paperHi}, ${C.paper} 55%, ${C.paperLo})`,
                boxShadow: "inset 0 0 0 1px rgba(24,18,6,0.18)",
                padding: "54px 64px",
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                gap: 40,
              }}
            >
              <div
                style={{
                  fontFamily: F.impact,
                  fontSize: 190,
                  lineHeight: 0.9,
                  color: C.ink,
                  letterSpacing: 2,
                }}
              >
                YAPPER
              </div>
              <div
                style={{
                  display: "flex",
                  flexDirection: "column",
                  gap: 16,
                  alignItems: "flex-end",
                  opacity: chips,
                }}
              >
                <div style={{ display: "flex", gap: 14 }}>
                  <span
                    style={{
                      fontFamily: F.impact,
                      fontSize: 24,
                      letterSpacing: 2,
                      color: "#f2ead2",
                      background: "#0a0806",
                      padding: "10px 16px",
                    }}
                  >
                    PARENTAL ADVISORY
                  </span>
                  <InkChip>SIDE A</InkChip>
                </div>
                <div style={{ display: "flex", gap: 14 }}>
                  <InkChip>MIX 3</InkChip>
                  <InkChip>LO-FI</InkChip>
                  <InkChip>C-90</InkChip>
                </div>
              </div>
            </div>
            <div
              style={{
                position: "absolute",
                top: -34,
                right: -30,
                opacity: skullIn,
                transform: `rotate(9deg) scale(${0.6 + skullIn * 0.4})`,
              }}
            >
              <SkullSticker size={116} />
            </div>
          </div>

          <div
            style={{
              position: "absolute",
              top: 560,
              fontFamily: F.marker,
              fontSize: 62,
              color: C.cream,
              opacity: callback,
              transform: `rotate(-1deg) translateY(${(1 - callback) * 16}px)`,
            }}
          >
            stop reading. start listening.
          </div>

          {/* press play → floating play cap */}
          <div
            style={{
              position: "absolute",
              top: 724,
              display: "flex",
              alignItems: "center",
              gap: 34,
              opacity: press,
            }}
          >
            <div
              style={{
                fontFamily: F.marker,
                fontSize: 46,
                color: C.paper,
                transform: "rotate(-2deg)",
              }}
            >
              press play →
            </div>
            <div style={{ position: "relative", width: 170 }}>
              <div
                style={{
                  position: "absolute",
                  inset: "6% 3%",
                  borderRadius: 20,
                  background: "#070503",
                  opacity: 0.92 * capDepth,
                }}
              />
              <Img
                src={staticFile("cassette-cap-play.png")}
                style={{
                  width: "100%",
                  display: "block",
                  position: "relative",
                  transform: `translateY(${capDepth * 12}%)`,
                  filter: `brightness(${1 - capDepth * 0.25}) drop-shadow(0 14px 22px rgba(0,0,0,0.5))`,
                }}
              />
            </div>
          </div>
        </AbsoluteFill>
      ) : (
        <AbsoluteFill style={{ background: "#080604", alignItems: "center", justifyContent: "center" }}>
          <div
            style={{
              fontFamily: F.impact,
              fontSize: 130,
              color: C.cream,
              letterSpacing: 3,
              opacity: endTitleOp,
              transform: `scale(${endTitle})`,
            }}
          >
            YAPPER
          </div>
          <div
            style={{
              marginTop: 26,
              fontFamily: F.mono,
              fontWeight: 500,
              fontSize: 30,
              letterSpacing: 6,
              color: C.dust,
              minHeight: 40,
            }}
          >
            {typed}
            {typed.length < END_TYPE.length && frame > BLACKOUT + 14 ? (
              <span style={{ color: C.paper }}>▊</span>
            ) : null}
          </div>
          <div style={{ display: "flex", gap: 18, marginTop: 54, opacity: endChips }}>
            <Chip>KEEPCO TAPE CO.</Chip>
            <Chip>MACOS 26+</Chip>
            <Chip>REC &apos;26</Chip>
          </div>
        </AbsoluteFill>
      )}

      {flash ? <AbsoluteFill style={{ background: C.paper, opacity: 0.9 }} /> : null}
    </AbsoluteFill>
  );
};
