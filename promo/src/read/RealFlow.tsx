import React from "react";
import {
  AbsoluteFill,
  Audio,
  Img,
  Sequence,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { C, F } from "../tokens";
import { GLIDE, POP, ramp, clamp01 } from "../util";
import { CassetteDeck, reelAngleAt } from "../components/CassetteDeck";
import { Chip } from "../components/bits";
import { ChatWindow } from "./ChatWindow";
import { WORD_COUNT } from "./content";
import { Desk, Flash, Keycap, MenuBar, Paper, TrackChip, VoiceBars } from "./pieces";
import {
  LEN,
  READ_B,
  READ_C,
  SC,
  SENTENCES,
  STAB,
  TAG_START,
  TOTAL,
  VO_LEN,
  VO_START,
  spokenAt,
  timecode,
} from "./timing";

const UI = `-apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif`;

const WIN = { w: 1560, h: 908, x: 180, y: 58 };
const DECK_ASPECT = 1064 / 656;
const PRESS_FRAME = 192; // the Right ⌥ tap
const DECK_IN = 217; //     deck starts sliding up
const PLAY_FRAME = 238; //  PLAY sinks, reels spin

/** Sentence text, for the bottom caption in the hero beat. */
const SENTENCE_TEXT = [
  "Redis keeps everything in memory, so reads come back in microseconds.",
  "Postgres writes to disk first, so it survives anything.",
  "For a session cache, use Redis.",
  "For anything you'd be upset to lose, use Postgres.",
];

/* ============================================ scene 1 — the object, cold open */

const SceneDeckOpen: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const rise = spring({ frame, fps, config: { damping: 18, mass: 1.1 } });
  const push = ramp(frame, [0, LEN.deck], [0.92, 1.02], GLIDE);
  const w = 880;
  // a single raking highlight travelling across the shell, like a light rig move
  const sweep = ramp(frame, [8, 62], [-40, 140], GLIDE);

  return (
    <Desk glow={0.55}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div
          style={{
            position: "relative",
            width: w,
            transform: `scale(${push}) translateY(${(1 - rise) * 40}px)`,
            filter: "drop-shadow(0 46px 90px rgba(0,0,0,0.85))",
            opacity: ramp(frame, [0, 14], [0, 1]),
          }}
        >
          <CassetteDeck width={w} reelAngle={0} />
          <div
            style={{
              position: "absolute",
              inset: 0,
              background: `linear-gradient(104deg, rgba(255,255,255,0) ${sweep - 26}%, rgba(255,246,222,0.16) ${sweep}%, rgba(255,255,255,0) ${sweep + 26}%)`,
              mixBlendMode: "screen",
              pointerEvents: "none",
            }}
          />
        </div>

        <div
          style={{
            marginTop: 58,
            fontFamily: F.mono,
            fontSize: 25,
            letterSpacing: 7,
            color: C.dust,
            textTransform: "uppercase",
            opacity: ramp(frame, [22, 40], [0, 1]),
            transform: `translateY(${ramp(frame, [22, 44], [16, 0], GLIDE)}px)`,
          }}
        >
          a menu-bar tape deck for macOS
        </div>
      </AbsoluteFill>
      <TrackChip n="01" label="SIDE A" />
    </Desk>
  );
};

/* ================================== scene 2 — the reply nobody is going to read */

const SceneWall: React.FC = () => {
  const frame = useCurrentFrame();
  const reveal = 1;
  const scrollY = ramp(frame, [0, LEN.wall], [40, 1180], [0.28, 0, 0.35, 1]);
  const scale = ramp(frame, [0, LEN.wall], [1.0, 1.035], GLIDE);
  const words = 1962;

  return (
    <Desk>
      <MenuBar width={1920} />
      <div
        style={{
          position: "absolute",
          left: WIN.x,
          top: WIN.y,
          transform: `scale(${scale})`,
          transformOrigin: "50% 44%",
        }}
      >
        <ChatWindow width={WIN.w} height={WIN.h} reveal={reveal} scrollY={scrollY} />
      </div>

      {/* the site's own line, over the scroll */}
      <div
        style={{
          position: "absolute",
          left: 96,
          bottom: 132,
          opacity: ramp(frame, [8, 22], [0, 1]),
          transform: `translateY(${ramp(frame, [8, 26], [22, 0], GLIDE)}px)`,
        }}
      >
        <div
          style={{
            fontFamily: F.impact,
            fontSize: 96,
            lineHeight: 0.9,
            color: C.cream,
            textTransform: "uppercase",
            letterSpacing: -1,
            textShadow: "0 8px 40px rgba(0,0,0,0.9)",
          }}
        >
          your AI won't
          <br />
          shut up.
        </div>
        <div style={{ marginTop: 20, display: "flex", gap: 12 }}>
          <Chip size={20}>{words.toLocaleString("en-US")} WORDS</Chip>
          <Chip size={20}>9 MIN READ</Chip>
        </div>
      </div>
      <Flash at={0} />
      <TrackChip n="02" label="THE WALL" />
    </Desk>
  );
};

/* =================================================================== scene 3 */

const SceneKey: React.FC = () => {
  const frame = useCurrentFrame();
  const local = PRESS_FRAME - SC.key; // 31
  const enter = spring({ frame, fps: 30, config: { damping: 14, mass: 0.7 } });
  const press =
    frame < local ? 0 : frame < local + 3 ? (frame - local) / 3 : clamp01(1 - (frame - local - 3) / 7);
  const ring = clamp01((frame - local) / 22);

  return (
    <Desk glow={0.5}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div
          style={{
            fontFamily: F.impact,
            fontSize: 74,
            color: C.cream,
            letterSpacing: 1,
            textTransform: "uppercase",
            opacity: ramp(frame, [2, 14], [0, 1]),
            transform: `translateY(${ramp(frame, [2, 16], [22, 0], GLIDE)}px)`,
            marginBottom: 46,
          }}
        >
          one key.
        </div>

        <div style={{ position: "relative", transform: `scale(${0.72 + enter * 0.28})` }}>
          {ring > 0 && ring < 1 ? (
            <div
              style={{
                position: "absolute",
                left: "50%",
                top: "50%",
                width: 300 + ring * 520,
                height: 300 + ring * 520,
                marginLeft: -(150 + ring * 260),
                marginTop: -(150 + ring * 260),
                borderRadius: "50%",
                border: `2px solid rgba(221,201,139,${0.55 * (1 - ring)})`,
              }}
            />
          ) : null}
          <Keycap size={300} press={press} label="⌥" sub="option" />
        </div>

        <div
          style={{
            marginTop: 52,
            fontFamily: F.mono,
            fontSize: 27,
            letterSpacing: 5,
            color: C.paper,
            opacity: ramp(frame, [local - 2, local + 8], [0.35, 1]),
          }}
        >
          RIGHT ⌥ — TAP IT
        </div>
      </AbsoluteFill>
      <Flash at={0} />
      <TrackChip n="03" label="THE YAPPER KEY" />
    </Desk>
  );
};

/* ========================================= scenes 4 + 5 share one live stage */

/** The desk, the window and the deck, driven by one camera across the read. */
const Stage: React.FC = () => {
  const frame = useCurrentFrame(); // absolute (this lives outside a Sequence)
  const fps = 30;

  // ---- deck geometry -------------------------------------------------------
  const slide = spring({ frame: frame - DECK_IN, fps, config: { damping: 15, mass: 0.85 } });
  const dockedW = 560;
  const dockedCx = 1920 - 124 - dockedW / 2;
  const dockedCy = 1080 - 150 - dockedW / DECK_ASPECT / 2;

  const HERO_W = 940;
  const HERO_CY = 430;
  const deckW = frame < READ_C ? dockedW : ramp(frame, [READ_C, READ_C + 46], [dockedW, HERO_W], GLIDE);
  const deckH = deckW / DECK_ASPECT;
  const cx = frame < READ_C ? dockedCx : ramp(frame, [READ_C, READ_C + 46], [dockedCx, 960], GLIDE);
  const cy =
    frame < READ_C
      ? dockedCy + (1 - slide) * 520
      : ramp(frame, [READ_C, READ_C + 46], [dockedCy, HERO_CY], GLIDE);

  const reelAngle = reelAngleAt(frame, PLAY_FRAME);
  const playDepth = ramp(frame, [PLAY_FRAME, PLAY_FRAME + 4], [0, 1]);

  // ---- window --------------------------------------------------------------
  const sentence = spokenAt(frame);
  // Yapper reads from the top of the reply, so the view sits on the opening
  // paragraphs and drifts only slightly — the spoken line is always on screen.
  const scrollY = ramp(frame, [VO_START, READ_C], [0, 82], GLIDE);
  const winOpacity = frame < READ_B ? 1 : ramp(frame, [READ_B + 8, READ_B + 46], [1, 0.07], GLIDE);
  const winScale = frame < READ_B ? 1 : ramp(frame, [READ_B + 10, READ_B + 60], [1, 0.9], GLIDE);
  const winDrift = frame < READ_B ? 0 : ramp(frame, [READ_B + 10, READ_B + 60], [0, -78], GLIDE);
  const winBlur = frame < READ_B ? 0 : ramp(frame, [READ_B + 8, READ_B + 44], [0, 11], GLIDE);
  const winGone = ramp(frame, [READ_C - 20, READ_C + 6], [1, 0]);

  // ---- camera --------------------------------------------------------------
  // The app's real type is small at 1080p, so the read pushes in on the text
  // column (origin sits on the paragraph being spoken), then eases back out as
  // the screen stops mattering.
  // Enough push to make the type comfortable at 1080p, not so much that the
  // window's own left edge gets bisected mid-word.
  const camScale =
    frame < READ_B
      ? ramp(frame, [VO_START, READ_B], [1.0, 1.18], GLIDE)
      : ramp(frame, [READ_B, READ_B + 70], [1.18, 1.03], GLIDE);
  const camY = 0;

  const reading = frame >= PLAY_FRAME && frame < VO_START + VO_LEN + 24;
  const relFrame = frame - VO_START;
  const heroIn = ramp(frame, [READ_C + 26, READ_C + 46], [0, 1]);

  return (
    <Desk>
      <MenuBar width={1920} reading={reading} />

      <AbsoluteFill
        style={{ transform: `scale(${camScale}) translateY(${camY}px)`, transformOrigin: "54% 33%" }}
      >
        {/* the answer on screen */}
        <div
          style={{
            position: "absolute",
            left: WIN.x,
            top: WIN.y,
            opacity: winOpacity * winGone,
            transform: `scale(${winScale}) translate(${winDrift}px, ${winDrift * 0.35}px)`,
            transformOrigin: "50% 40%",
            filter: winBlur > 0.05 ? `blur(${winBlur}px) saturate(0.6)` : "none",
          }}
        >
          <ChatWindow width={WIN.w} height={WIN.h} reveal={1} scrollY={scrollY} highlight={sentence} />
        </div>

      </AbsoluteFill>

        {/* the deck */}
        <div
          style={{
            position: "absolute",
            left: cx,
            top: cy,
            width: deckW,
            transform: "translate(-50%, -50%)",
            filter: `drop-shadow(0 ${deckH * 0.09}px ${deckH * 0.22}px rgba(0,0,0,0.72))`,
          }}
        >
          <CassetteDeck width={deckW} reelAngle={reelAngle} capDepths={{ play: playDepth }} />

          {/* counter + level strip riding under the deck */}
          {frame >= PLAY_FRAME ? (
            <div
              style={{
                position: "absolute",
                left: 0,
                right: 0,
                top: "100%",
                marginTop: deckW * 0.045,
                display: "flex",
                alignItems: "center",
                gap: deckW * 0.03,
                opacity: ramp(frame, [PLAY_FRAME + 4, PLAY_FRAME + 18], [0, 1]),
              }}
            >
              <div
                style={{
                  fontFamily: F.mono,
                  fontSize: deckW * 0.044,
                  color: C.paper,
                  letterSpacing: 2,
                  minWidth: deckW * 0.14,
                }}
              >
                {timecode(Math.min(frame, VO_START + VO_LEN), VO_START)}
              </div>
              <VoiceBars width={deckW * 0.72} height={deckW * 0.105} bars={52} relFrame={relFrame} />
            </div>
          ) : null}
        </div>

      {/* "go do something else." — the walk-away beat */}
      {frame >= READ_B + 14 && frame < READ_C - 2 ? (
        <div
          style={{
            position: "absolute",
            left: 150,
            top: 372,
            width: 900,
            opacity:
              ramp(frame, [READ_B + 14, READ_B + 30], [0, 1]) *
              ramp(frame, [READ_C - 10, READ_C - 2], [1, 0]),
            transform: `translateY(${ramp(frame, [READ_B + 14, READ_B + 34], [26, 0], GLIDE)}px)`,
          }}
        >
          <div
            style={{
              fontFamily: F.impact,
              fontSize: 126,
              lineHeight: 0.92,
              color: C.cream,
              textTransform: "uppercase",
              letterSpacing: -1,
            }}
          >
            it keeps
            <br />
            reading.
          </div>
          <div style={{ marginTop: 28, fontFamily: F.marker, fontSize: 44, color: C.paper }}>
            go do something else
          </div>
        </div>
      ) : null}

      {/* caption of the line being spoken, in the hero beat */}
      {frame >= READ_C + 26 && sentence >= 0 ? (
        <div
          style={{
            position: "absolute",
            left: 0,
            right: 0,
            bottom: 92,
            display: "flex",
            justifyContent: "center",
            padding: "0 220px",
            opacity: ramp(frame, [READ_C + 26, READ_C + 40], [0, 1]),
          }}
        >
          <div
            style={{
              fontFamily: UI,
              fontSize: 37,
              lineHeight: 1.4,
              color: C.cream,
              textAlign: "center",
              background: "rgba(10,8,6,0.6)",
              border: `1px solid ${C.line}`,
              borderRadius: 10,
              padding: "14px 26px",
            }}
          >
            {SENTENCE_TEXT[sentence]}
          </div>
        </div>
      ) : null}

      {frame >= SC.dock && frame < VO_START ? <TrackChip n="04" label="TAP" /> : null}
      {frame >= VO_START ? <TrackChip n="05" label="IT READS IT" /> : null}
      <Flash at={SC.dock} />
    </Desk>
  );
};

/* =================================================================== scene 6 */

const STABS = [
  {
    big: "reads anything\nwith words in it.",
    note: "Right ⌥ tap — the newest reply, out loud",
    chips: ["CLAUDE", "CHATGPT", "CODEX", "SAFARI", "MAIL", "PDFS"],
    art: "deck" as const,
  },
  {
    big: "or just\nhighlight it.",
    note: "Right ⌥ + S — read the selection, in any app",
    chips: ["EMAILS", "DOCS", "A 40-PAGE CHANGELOG"],
    art: "selection" as const,
  },
  {
    big: "or talk\nback.",
    note: "Right ⌥ + Return — replies auto-play",
    chips: ["HOLD TO TALK", "QUEUES IN ORDER"],
    art: "rec" as const,
    rec: true,
  },
];

/** The right-hand third of each stab, so the frame reads as designed, not empty. */
const StabArt: React.FC<{ kind: "deck" | "selection" | "rec"; local: number }> = ({
  kind,
  local,
}) => {
  const inn = ramp(local, [4, 18], [0, 1], GLIDE);
  const common: React.CSSProperties = {
    position: "absolute",
    right: 150,
    top: "50%",
    opacity: inn,
    transform: `translateY(-50%) scale(${0.92 + inn * 0.08})`,
  };

  if (kind === "deck") {
    return (
      <div
        style={{
          ...common,
          width: 470,
          transform: `translateY(-50%) rotate(-4deg) scale(${0.92 + inn * 0.08})`,
          filter: "drop-shadow(0 26px 54px rgba(0,0,0,0.8)) brightness(1.12)",
        }}
      >
        <CassetteDeck width={470} reelAngle={local * 9} capDepths={{ play: 1 }} />
      </div>
    );
  }

  if (kind === "selection") {
    const rows = [0.92, 0.78, 1, 0.64, 0.86, 0.72];
    return (
      <div
        style={{
          ...common,
          width: 520,
          padding: 34,
          background: "rgba(24,21,17,0.9)",
          border: `1px solid ${C.line}`,
          borderRadius: 12,
        }}
      >
        {rows.map((w, i) => {
          const picked = i === 2 || i === 3;
          return (
            <div
              key={i}
              style={{
                height: 15,
                width: `${w * 100}%`,
                marginBottom: 15,
                borderRadius: 3,
                background: picked ? C.paper : "rgba(236,227,203,0.22)",
                opacity: picked ? 0.92 : 1,
              }}
            />
          );
        })}
        <div
          style={{
            marginTop: 8,
            fontFamily: F.mono,
            fontSize: 19,
            letterSpacing: 2,
            color: C.paper,
          }}
        >
          SELECTED — NOW AUDIO
        </div>
      </div>
    );
  }

  // rec
  const pulse = 0.55 + 0.45 * Math.abs(Math.sin(local * 0.3));
  return (
    <div style={{ ...common, width: 360, textAlign: "center" }}>
      <div
        style={{
          width: 360,
          height: 360,
          borderRadius: "50%",
          border: `2px solid rgba(199,69,55,${0.25 + pulse * 0.4})`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          boxShadow: `0 0 ${60 * pulse}px rgba(199,69,55,${0.28 * pulse})`,
        }}
      >
        <div
          style={{
            width: 150,
            height: 150,
            borderRadius: "50%",
            background: C.redHot,
            boxShadow: `0 0 ${70 * pulse}px rgba(199,69,55,0.85)`,
          }}
        />
      </div>
      <div
        style={{
          marginTop: 26,
          fontFamily: F.mono,
          fontSize: 22,
          letterSpacing: 5,
          color: C.redHot,
        }}
      >
        REC
      </div>
    </div>
  );
};

const SceneStabs: React.FC = () => {
  const frame = useCurrentFrame();
  const i = Math.min(2, Math.floor(frame / 30));
  const local = frame - i * 30;
  const s = STABS[i];
  const inn = ramp(local, [0, 12], [0, 1], GLIDE);

  return (
    <Desk glow={0.42}>
      <StabArt kind={s.art} local={local} />
      <AbsoluteFill
        style={{
          alignItems: "flex-start",
          justifyContent: "center",
          padding: "0 140px",
        }}
      >
        <div style={{ width: 900 }}>
          <div
            style={{
              fontFamily: F.impact,
              fontSize: 118,
              lineHeight: 0.9,
              color: C.cream,
              textTransform: "uppercase",
              letterSpacing: -1.5,
              whiteSpace: "pre-line",
              opacity: inn,
              transform: `translateY(${(1 - inn) * 30}px)`,
            }}
          >
            {s.big}
          </div>
          <div
            style={{
              marginTop: 32,
              fontFamily: F.mono,
              fontSize: 27,
              color: s.rec ? C.redHot : C.paper,
              letterSpacing: 1.2,
              opacity: ramp(local, [3, 11], [0, 1]),
            }}
          >
            {s.note}
          </div>
          <div
            style={{
              marginTop: 26,
              display: "flex",
              gap: 12,
              flexWrap: "wrap",
              opacity: ramp(local, [5, 13], [0, 1]),
            }}
          >
            {s.chips.map((c) => (
              <Chip key={c} size={20}>
                {c}
              </Chip>
            ))}
          </div>
        </div>
      </AbsoluteFill>
      <Flash at={i * 30} />
      <TrackChip n={`0${6 + i}`} label="ALSO" />
    </Desk>
  );
};

/* =================================================================== scene 7 */

const SceneEnd: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const pop = spring({ frame, fps, config: { damping: 14, mass: 0.8 } });
  const spin = frame * 3.2;

  return (
    <Desk glow={0.62}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div style={{ position: "relative", transform: `scale(${0.9 + pop * 0.1})` }}>
          {[-1, 1].map((side) => (
            <div
              key={side}
              style={{
                position: "absolute",
                top: "50%",
                left: side < 0 ? -230 : "auto",
                right: side > 0 ? -230 : "auto",
                width: 172,
                transform: `translateY(-50%) rotate(${spin * side}deg)`,
                opacity: ramp(frame, [8, 26], [0, 1]),
                filter: "drop-shadow(0 0 26px rgba(221,201,139,0.28)) brightness(1.5)",
              }}
            >
              <Img
                src={staticFile(side < 0 ? "cassette-reel-left.png" : "cassette-reel-right.png")}
                style={{ width: "100%" }}
              />
            </div>
          ))}

          <Paper width={1020} rotate={-0.8}>
            <div
              style={{
                fontFamily: F.impact,
                fontSize: 210,
                lineHeight: 0.86,
                color: C.ink,
                letterSpacing: -2,
                textTransform: "uppercase",
                textAlign: "center",
              }}
            >
              Yapper
            </div>
            <div
              style={{
                marginTop: 14,
                textAlign: "center",
                fontFamily: F.mono,
                fontSize: 29,
                letterSpacing: 6,
                color: "rgba(24,18,6,0.74)",
                textTransform: "uppercase",
              }}
            >
              reads your AI out loud
            </div>
          </Paper>
        </div>

        <div
          style={{
            marginTop: 54,
            fontFamily: F.impact,
            fontSize: 62,
            color: C.cream,
            textTransform: "uppercase",
            letterSpacing: 0.5,
            opacity: ramp(frame, [22, 40], [0, 1]),
            transform: `translateY(${ramp(frame, [22, 42], [20, 0], GLIDE)}px)`,
          }}
        >
          tap right ⌥ and walk away.
        </div>

        <div
          style={{
            marginTop: 28,
            display: "flex",
            gap: 16,
            alignItems: "center",
            opacity: ramp(frame, [36, 54], [0, 1]),
          }}
        >
          <Chip size={22}>useyapper.vercel.app</Chip>
          <Chip size={22}>FREE &amp; OPEN SOURCE</Chip>
          <Chip size={22}>macOS 13+</Chip>
        </div>
      </AbsoluteFill>
      <Flash at={0} />
    </Desk>
  );
};

/* ====================================================================== root */

export const RealFlow: React.FC = () => {
  const frame = useCurrentFrame();

  // Music bed sits back under the voice and comes up between the talking.
  const bedVol = (f: number) => {
    const duckRead = interpolate(f, [VO_START - 16, VO_START + 8], [1, 0.3], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    });
    const unduck = interpolate(f, [VO_START + VO_LEN - 8, VO_START + VO_LEN + 22], [0, 1], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    });
    const duckTag = interpolate(f, [TAG_START - 14, TAG_START + 6], [1, 0.38], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    });
    const base = duckRead + (1 - duckRead) * unduck;
    return 0.82 * Math.min(base, duckTag);
  };

  return (
    <AbsoluteFill style={{ background: "#090807" }}>
      {/* ---------- picture ---------- */}
      <Sequence from={SC.deck} durationInFrames={LEN.deck}>
        <SceneDeckOpen />
      </Sequence>
      <Sequence from={SC.wall} durationInFrames={LEN.wall}>
        <SceneWall />
      </Sequence>
      <Sequence from={SC.key} durationInFrames={LEN.key}>
        <SceneKey />
      </Sequence>
      {/* dock + read share one continuous stage, so the camera never cuts mid-voice */}
      {frame >= SC.dock && frame < SC.stabs ? <Stage /> : null}
      <Sequence from={SC.stabs} durationInFrames={LEN.stabs}>
        <SceneStabs />
      </Sequence>
      <Sequence from={SC.end} durationInFrames={LEN.end}>
        <SceneEnd />
      </Sequence>

      {/* ---------- sound ---------- */}
      <Audio src={staticFile("audio/bed.mp3")} volume={bedVol} />
      <Sequence from={VO_START}>
        <Audio src={staticFile("audio/read.mp3")} volume={1} />
      </Sequence>
      <Sequence from={TAG_START}>
        <Audio src={staticFile("audio/tag.mp3")} volume={1} />
      </Sequence>

      {/* transport + transitions, cut from the user's Epidemic Sound library */}
      <Sequence from={PRESS_FRAME - 1}>
        <Audio src={staticFile("audio/sfx/key.wav")} volume={0.95} />
      </Sequence>
      <Sequence from={DECK_IN}>
        <Audio src={staticFile("audio/sfx/clunk.wav")} volume={0.8} />
      </Sequence>
      {[SC.wall, SC.key, SC.stabs].map((f) => (
        <Sequence key={`w${f}`} from={f - 2}>
          <Audio src={staticFile("audio/sfx/whoosh.wav")} volume={0.42} />
        </Sequence>
      ))}
      <Sequence from={READ_C - 3}>
        <Audio src={staticFile("audio/sfx/swoosh.wav")} volume={0.38} />
      </Sequence>
      <Sequence from={SC.end - 26}>
        <Audio src={staticFile("audio/sfx/riser.wav")} volume={0.5} />
      </Sequence>
    </AbsoluteFill>
  );
};
