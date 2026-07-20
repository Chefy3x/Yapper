import React from "react";
import {
  AbsoluteFill,
  Audio,
  Sequence,
  Series,
  random,
  staticFile,
  useCurrentFrame,
} from "remotion";
import { C, F } from "./tokens";
import { ENTER, GLIDE, POP, clamp01, ramp } from "./util";
import { CassetteDeck, reelAngleAt } from "./components/CassetteDeck";

/**
 * SIDE A — a 9.4s quick-cut promo built from the spec and the tape label.
 * Nine hard cuts: yap wall → label cards → Right ⌘ → deck hero →
 * three feature stabs → end card. All type, paper, and the real deck art.
 */

export const SIDE_A_FRAMES = 282;
const W = 1920;
const H = 1080;

// Shot lengths (frames @30fps). Must sum to SIDE_A_FRAMES.
const SHOTS = [34, 22, 22, 30, 66, 21, 21, 24, 42] as const;
const cutAt = (n: number) => SHOTS.slice(0, n).reduce((a, b) => a + b, 0);

// ---------------------------------------------------------------------------
// Shared dressing
// ---------------------------------------------------------------------------

/** Gentle push-in that runs the length of a shot — keeps every cut alive. */
const PushIn: React.FC<{
  dur: number;
  amount?: number;
  children: React.ReactNode;
}> = ({ dur, amount = 0.045, children }) => {
  const frame = useCurrentFrame();
  const scale = 1 + (frame / dur) * amount;
  return <AbsoluteFill style={{ transform: `scale(${scale})` }}>{children}</AbsoluteFill>;
};

const GRAIN_TILE =
  `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='140' height='140'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='140' height='140' filter='url(%23n)' opacity='0.6'/%3E%3C/svg%3E")`;

/** Static-free film grain + vignette, over everything. */
const Grade: React.FC = () => {
  const frame = useCurrentFrame();
  const jx = (frame * 37) % 140;
  const jy = (frame * 61) % 140;
  return (
    <>
      <AbsoluteFill
        style={{
          backgroundImage: GRAIN_TILE,
          backgroundPosition: `${jx}px ${jy}px`,
          opacity: 0.07,
          mixBlendMode: "overlay",
          pointerEvents: "none",
        }}
      />
      <AbsoluteFill
        style={{
          background:
            "radial-gradient(ellipse 88% 78% at 50% 46%, rgba(0,0,0,0) 58%, rgba(0,0,0,0.42) 100%)",
          pointerEvents: "none",
        }}
      />
    </>
  );
};

/** Two-frame cream flash on every cut — sells the hard edit. */
const CutFlash: React.FC = () => {
  const frame = useCurrentFrame();
  const cuts = SHOTS.slice(0, -1).map((_, i) => cutAt(i + 1));
  const hit = cuts.some((c) => frame === c || frame === c + 1);
  const fading = cuts.some((c) => frame === c + 2);
  if (!hit && !fading) return null;
  return (
    <AbsoluteFill
      style={{ background: C.cream, opacity: hit ? 0.16 : 0.06, pointerEvents: "none" }}
    />
  );
};

/** Corner index chip — "01 · SIDE A" — the editorial system tying cuts together. */
const IndexChip: React.FC<{ n: number; light?: boolean }> = ({ n, light = false }) => {
  const frame = useCurrentFrame();
  return (
    <div
      style={{
        position: "absolute",
        top: 44,
        left: 56,
        fontFamily: F.mono,
        fontWeight: 600,
        fontSize: 26,
        letterSpacing: 6,
        color: light ? C.inkSoft : C.dust,
        opacity: ramp(frame, [2, 8], [0, 1]),
      }}
    >
      {String(n).padStart(2, "0")} · SIDE A
    </div>
  );
};

/** Anton slam: scales down into place with a bit of attitude. */
const Slam: React.FC<{
  at: number;
  size: number;
  color: string;
  children: React.ReactNode;
  rotate?: number;
  overshoot?: boolean;
  style?: React.CSSProperties;
}> = ({ at, size, color, children, rotate = 0, overshoot = false, style }) => {
  const frame = useCurrentFrame();
  const p = ramp(frame, [at, at + 8], [0, 1], overshoot ? POP : ENTER);
  const scale = 1.9 - p * 0.9;
  return (
    <div
      style={{
        fontFamily: F.impact,
        fontSize: size,
        color,
        lineHeight: 0.94,
        letterSpacing: 2,
        opacity: p,
        transform: `scale(${scale}) rotate(${rotate}deg)`,
        textTransform: "uppercase",
        ...style,
      }}
    >
      {children}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Shot 1 — the yap wall
// ---------------------------------------------------------------------------

const YAP_LINES = [
  "Great question — let's break this down into twelve sections.",
  "Certainly! Here's a comprehensive, nuanced overview of everything.",
  "It depends on several factors, which I will now enumerate at length.",
  "## Step 1: Understanding the fundamentals before the fundamentals",
  "In conclusion, the trade-offs are nuanced and context-dependent.",
  "Here's the revised version, with additional caveats and disclaimers.",
  "Would you like me to elaborate further on any of these 47 points?",
  "TL;DR — except it's somehow longer than the original answer.",
];

const YapWall: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.void, overflow: "hidden" }}>
      <PushIn dur={SHOTS[0]}>
        {/* Ribbons of AI filler streaming like tape paths */}
        {YAP_LINES.map((line, i) => {
          const dir = i % 2 === 0 ? -1 : 1;
          const speed = 5 + random(`yap-${i}`) * 5;
          const x = ((frame * speed * dir) % 1200) - (dir === 1 ? 1200 : 0);
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                top: 100 + i * 126,
                left: -400,
                width: 3600,
                whiteSpace: "nowrap",
                fontFamily: F.mono,
                fontWeight: 500,
                fontSize: 44,
                color: C.faint,
                transform: `translateX(${x}px)`,
                filter: "blur(0.6px)",
              }}
            >
              {line} — {line}
            </div>
          );
        })}
        <AbsoluteFill
          style={{
            justifyContent: "center",
            alignItems: "center",
            flexDirection: "column",
            gap: 10,
          }}
        >
          <Slam at={3} size={150} color={C.cream}>
            Your AI
          </Slam>
          <Slam at={10} size={290} color={C.paper} rotate={-2} overshoot>
            Yaps.
          </Slam>
        </AbsoluteFill>
        <IndexChip n={1} />
      </PushIn>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// Shots 2 & 3 — label cards
// ---------------------------------------------------------------------------

/** Ruled tape-label paper, like the deck's yellow strip. */
const LabelPaper: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <AbsoluteFill
    style={{
      background: `linear-gradient(168deg, ${C.paperHi} 0%, ${C.paper} 46%, ${C.paperLo} 100%)`,
    }}
  >
    {/* Handwriting rules */}
    {Array.from({ length: 5 }).map((_, i) => (
      <div
        key={i}
        style={{
          position: "absolute",
          left: 90,
          right: 90,
          top: 300 + i * 130,
          height: 3,
          background: "rgba(24,18,6,0.16)",
        }}
      />
    ))}
    {children}
  </AbsoluteFill>
);

const DontReadIt: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ overflow: "hidden" }}>
      <PushIn dur={SHOTS[1]}>
        <LabelPaper>
          {/* Circled side-A badge, like the label's corner mark */}
          <div
            style={{
              position: "absolute",
              top: 52,
              right: 72,
              width: 86,
              height: 86,
              borderRadius: "50%",
              border: `5px solid ${C.ink}`,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontFamily: F.marker,
              fontSize: 52,
              color: C.ink,
              transform: "rotate(6deg)",
              opacity: ramp(frame, [4, 10], [0, 1]),
            }}
          >
            A
          </div>
          <AbsoluteFill
            style={{
              justifyContent: "center",
              alignItems: "flex-start",
              paddingLeft: 150,
              flexDirection: "column",
              gap: 6,
            }}
          >
            <Slam at={0} size={230} color={C.ink}>
              Don't
            </Slam>
            <Slam at={5} size={230} color={C.ink} style={{ paddingLeft: 120 }}>
              read it.
            </Slam>
          </AbsoluteFill>
          <IndexChip n={2} light />
        </LabelPaper>
      </PushIn>
    </AbsoluteFill>
  );
};

const PressPlay: React.FC = () => {
  const frame = useCurrentFrame();
  const triIn = ramp(frame, [0, 9], [0, 1], POP);
  return (
    <AbsoluteFill style={{ background: C.panel, overflow: "hidden" }}>
      <PushIn dur={SHOTS[2]}>
        {/* Big flat play triangle — the tape vocabulary */}
        <div
          style={{
            position: "absolute",
            left: "50%",
            top: "50%",
            transform: `translate(-50%, -50%) scale(${0.4 + triIn * 0.6})`,
            width: 0,
            height: 0,
            borderTop: "260px solid transparent",
            borderBottom: "260px solid transparent",
            borderLeft: `440px solid ${C.paper}`,
            opacity: 0.2 * triIn,
          }}
        />
        <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
          <Slam at={4} size={250} color={C.cream} overshoot>
            Press play.
          </Slam>
        </AbsoluteFill>
        <IndexChip n={3} />
      </PushIn>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// Shot 4 — the Right ⌘ keycap
// ---------------------------------------------------------------------------

const KeyTap: React.FC = () => {
  const frame = useCurrentFrame();
  const enter = ramp(frame, [0, 8], [0, 1], GLIDE);
  // Press at f10: sink fast, release slow.
  const press =
    clamp01(ramp(frame, [10, 13], [0, 1]) - ramp(frame, [16, 22], [0, 1]));
  const KEY = 380;
  return (
    <AbsoluteFill style={{ background: C.void, overflow: "hidden" }}>
      <PushIn dur={SHOTS[3]}>
        <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
          {/* Tap ripples */}
          {[0, 1].map((i) => {
            const p = ramp(frame, [11 + i * 4, 26 + i * 4], [0, 1]);
            return (
              <div
                key={i}
                style={{
                  position: "absolute",
                  width: KEY + p * 560,
                  height: KEY + p * 560,
                  borderRadius: 76,
                  border: `3px solid ${C.paper}`,
                  opacity: (1 - p) * 0.55,
                }}
              />
            );
          })}
          {/* The keycap */}
          <div
            style={{
              width: KEY,
              height: KEY,
              borderRadius: 56,
              background: `linear-gradient(180deg, ${C.panel2} 0%, ${C.panel} 60%, #12100c 100%)`,
              border: `2px solid rgba(236,227,203,${0.18 + press * 0.25})`,
              boxShadow: `0 ${26 - press * 20}px ${60 - press * 40}px rgba(0,0,0,0.65), inset 0 2px 0 rgba(236,227,203,0.08)`,
              transform: `scale(${(0.86 + enter * 0.14) * (1 - press * 0.05)}) translateY(${press * 14}px)`,
              opacity: enter,
              display: "flex",
              flexDirection: "column",
              justifyContent: "space-between",
              padding: 34,
            }}
          >
            <div
              style={{
                fontFamily: F.mono,
                fontSize: 118,
                color: C.cream,
                lineHeight: 1,
                alignSelf: "flex-end",
              }}
            >
              ⌘
            </div>
            <div
              style={{
                fontFamily: F.mono,
                fontWeight: 500,
                fontSize: 40,
                letterSpacing: 3,
                color: C.dust,
                alignSelf: "flex-end",
              }}
            >
              command
            </div>
          </div>
        </AbsoluteFill>
        <div
          style={{
            position: "absolute",
            bottom: 96,
            width: "100%",
            textAlign: "center",
            fontFamily: F.mono,
            fontWeight: 600,
            fontSize: 40,
            letterSpacing: 8,
            color: C.paper,
            opacity: ramp(frame, [13, 19], [0, 1]),
          }}
        >
          RIGHT ⌘ — FROM ANY APP
        </div>
        <IndexChip n={4} />
      </PushIn>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// Shot 5 — deck hero
// ---------------------------------------------------------------------------

const TICKER = "CLAUDE — CHATGPT — CODEX — CLAUDE CODE — ANY SELECTED TEXT — ";

const DeckHero: React.FC = () => {
  const frame = useCurrentFrame();
  const PRESS = 8;
  const deckIn = ramp(frame, [0, 8], [0, 1], GLIDE);
  const playDepth = ramp(frame, [PRESS, PRESS + 5], [0, 1]);
  const angle = reelAngleAt(frame, PRESS + 2);
  const wave = clamp01(ramp(frame, [PRESS + 4, PRESS + 14], [0, 1]));
  const DECK_W = 1150;

  // Mirrored VU meters flanking the deck.
  const bars = (side: "l" | "r") =>
    Array.from({ length: 12 }).map((_, i) => {
      const seed = random(`vu-${side}-${i}`) * Math.PI * 2;
      const pulse =
        0.3 +
        0.7 *
          Math.abs(
            Math.sin(seed + frame * (0.16 + random(`vw-${side}-${i}`) * 0.12)),
          );
      const h = 30 + pulse * 200 * wave;
      const hot = pulse > 0.82;
      return (
        <div
          key={i}
          style={{
            width: 14,
            height: Math.max(8, h),
            borderRadius: 4,
            background: hot ? C.paper : C.cream,
            opacity: hot ? 0.95 : 0.28,
          }}
        />
      );
    });

  return (
    <AbsoluteFill style={{ background: C.void, overflow: "hidden" }}>
      <PushIn dur={SHOTS[4]} amount={0.035}>
        {/* Headline */}
        <div
          style={{
            position: "absolute",
            top: 74,
            width: "100%",
            display: "flex",
            justifyContent: "center",
          }}
        >
          <Slam at={PRESS + 4} size={124} color={C.cream}>
            Reads your AI{" "}
            <span style={{ color: C.paper }}>out loud.</span>
          </Slam>
        </div>

        {/* VU meters */}
        <div
          style={{
            position: "absolute",
            left: 62,
            top: 380,
            height: 460,
            display: "flex",
            alignItems: "center",
            gap: 10,
          }}
        >
          {bars("l")}
        </div>
        <div
          style={{
            position: "absolute",
            right: 62,
            top: 380,
            height: 460,
            display: "flex",
            alignItems: "center",
            gap: 10,
            flexDirection: "row-reverse",
          }}
        >
          {bars("r")}
        </div>

        {/* The deck — real art, registered moving parts */}
        <div
          style={{
            position: "absolute",
            left: "50%",
            top: 610 + (1 - deckIn) * 150,
            transform: `translate(-50%, -50%) scale(${0.96 + deckIn * 0.04})`,
            opacity: deckIn,
            filter: "drop-shadow(0 34px 50px rgba(0,0,0,0.62))",
          }}
        >
          <CassetteDeck
            width={DECK_W}
            reelAngle={angle}
            capDepths={{ play: playDepth }}
          />
        </div>

        {/* Source ticker */}
        <div
          style={{
            position: "absolute",
            bottom: 44,
            left: 0,
            right: 0,
            overflow: "hidden",
            whiteSpace: "nowrap",
            opacity: ramp(frame, [PRESS + 8, PRESS + 16], [0, 0.85]),
          }}
        >
          <div
            style={{
              display: "inline-block",
              fontFamily: F.mono,
              fontWeight: 600,
              fontSize: 34,
              letterSpacing: 6,
              color: C.dust,
              transform: `translateX(${-((frame * 4.4) % 1580)}px)`,
            }}
          >
            {TICKER}
            {TICKER}
            {TICKER}
          </div>
        </div>
        <IndexChip n={5} />
      </PushIn>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// Shots 6–8 — feature stabs
// ---------------------------------------------------------------------------

const CODE = [
  "```python",
  "def handle_every_edge_case():",
  "    for case in all_447_cases:",
  "        raise NotImplementedError",
  "```",
];

const SkipsCode: React.FC = () => {
  const frame = useCurrentFrame();
  const stampIn = ramp(frame, [5, 11], [0, 1], POP);
  const dim = ramp(frame, [7, 12], [1, 0.3]);
  return (
    <AbsoluteFill style={{ background: C.panel, overflow: "hidden" }}>
      <PushIn dur={SHOTS[5]}>
        <AbsoluteFill
          style={{
            justifyContent: "center",
            alignItems: "center",
            flexDirection: "column",
            gap: 8,
          }}
        >
          <div style={{ opacity: dim }}>
            {CODE.map((line, i) => (
              <div
                key={i}
                style={{
                  fontFamily: F.mono,
                  fontWeight: 500,
                  fontSize: 52,
                  color: C.dust,
                  whiteSpace: "pre",
                  lineHeight: 1.5,
                }}
              >
                {line}
              </div>
            ))}
          </div>
        </AbsoluteFill>
        {/* Stamp */}
        <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
          <div
            style={{
              fontFamily: F.impact,
              fontSize: 170,
              color: C.ink,
              background: C.paper,
              padding: "6px 60px 18px",
              transform: `rotate(-7deg) scale(${2.1 - stampIn * 1.1})`,
              opacity: stampIn,
              textTransform: "uppercase",
              boxShadow: "0 20px 50px rgba(0,0,0,0.5)",
            }}
          >
            Skipped.
          </div>
        </AbsoluteFill>
        <div
          style={{
            position: "absolute",
            bottom: 74,
            width: "100%",
            textAlign: "center",
            fontFamily: F.mono,
            fontWeight: 600,
            fontSize: 36,
            letterSpacing: 7,
            color: C.dust,
            opacity: ramp(frame, [9, 14], [0, 1]),
          }}
        >
          CODE BLOCKS? NEVER READ ALOUD
        </div>
        <IndexChip n={6} />
      </PushIn>
    </AbsoluteFill>
  );
};

const DoubleSpeed: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.void, overflow: "hidden" }}>
      <PushIn dur={SHOTS[6]}>
        {/* Streaming FF chevrons */}
        {Array.from({ length: 6 }).map((_, i) => {
          const y = 90 + i * 170;
          const speed = 26 + random(`ff-${i}`) * 18;
          const x = ((frame * speed) % 900) - 450;
          return (
            <div
              key={i}
              style={{
                position: "absolute",
                top: y,
                left: 0,
                width: "120%",
                fontFamily: F.impact,
                fontSize: 110,
                letterSpacing: 40,
                color: C.cream,
                opacity: 0.07,
                whiteSpace: "nowrap",
                transform: `translateX(${x}px)`,
              }}
            >
              {"▶▶ ".repeat(14)}
            </div>
          );
        })}
        <AbsoluteFill
          style={{
            justifyContent: "center",
            alignItems: "center",
            flexDirection: "row",
            gap: 50,
          }}
        >
          <Slam at={2} size={340} color={C.paper} overshoot>
            2×
          </Slam>
          <Slam at={6} size={110} color={C.cream} style={{ lineHeight: 1.05 }}>
            when you're
            <br />
            busy.
          </Slam>
        </AbsoluteFill>
        <div
          style={{
            position: "absolute",
            bottom: 74,
            width: "100%",
            textAlign: "center",
            fontFamily: F.mono,
            fontWeight: 600,
            fontSize: 36,
            letterSpacing: 7,
            color: C.dust,
            opacity: ramp(frame, [8, 13], [0, 1]),
          }}
        >
          FF STEPS THE SPEED — LIKE A REAL DECK
        </div>
        <IndexChip n={7} />
      </PushIn>
    </AbsoluteFill>
  );
};

const RecMode: React.FC = () => {
  const frame = useCurrentFrame();
  const dotIn = ramp(frame, [0, 5], [0, 1], POP);
  const blink = 0.72 + 0.28 * Math.abs(Math.sin(frame * 0.32));
  return (
    <AbsoluteFill style={{ background: C.void, overflow: "hidden" }}>
      <PushIn dur={SHOTS[7]}>
        <AbsoluteFill
          style={{
            justifyContent: "center",
            alignItems: "center",
            flexDirection: "column",
            gap: 44,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 40 }}>
            <div
              style={{
                width: 120,
                height: 120,
                borderRadius: "50%",
                background: C.redHot,
                opacity: blink * dotIn,
                transform: `scale(${dotIn})`,
                boxShadow: `0 0 ${60 * blink}px rgba(199,69,55,0.55)`,
              }}
            />
            <div
              style={{
                fontFamily: F.mono,
                fontWeight: 600,
                fontSize: 92,
                letterSpacing: 22,
                color: C.redHot,
                opacity: dotIn,
              }}
            >
              REC
            </div>
          </div>
          <Slam at={3} size={132} color={C.cream}>
            Auto-reads every reply.
          </Slam>
          <div
            style={{
              fontFamily: F.mono,
              fontWeight: 600,
              fontSize: 36,
              letterSpacing: 8,
              color: C.dust,
              opacity: ramp(frame, [8, 13], [0, 1]),
            }}
          >
            CONVERSATION MODE — YOU GO MAKE COFFEE
          </div>
        </AbsoluteFill>
        <IndexChip n={8} />
      </PushIn>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// Shot 9 — end card
// ---------------------------------------------------------------------------

const Chip: React.FC<{ at: number; children: React.ReactNode }> = ({ at, children }) => {
  const frame = useCurrentFrame();
  const p = ramp(frame, [at, at + 7], [0, 1], POP);
  return (
    <div
      style={{
        fontFamily: F.mono,
        fontWeight: 600,
        fontSize: 34,
        letterSpacing: 5,
        color: C.cream,
        border: `2px solid ${C.line}`,
        borderRadius: 999,
        padding: "14px 36px",
        opacity: p,
        transform: `scale(${0.7 + p * 0.3})`,
      }}
    >
      {children}
    </div>
  );
};

const EndCard: React.FC = () => {
  const frame = useCurrentFrame();
  const stripIn = ramp(frame, [0, 7], [0, 1], GLIDE);
  const hubAngle = reelAngleAt(frame + 40, 0); // already rolling
  const markIn = ramp(frame, [3, 10], [0, 1], POP);
  return (
    <AbsoluteFill style={{ background: C.void, overflow: "hidden" }}>
      <PushIn dur={SHOTS[8]} amount={0.03}>
        {/* The yellow label strip, cassette-window hubs and all */}
        <div
          style={{
            position: "absolute",
            left: "50%",
            top: "42%",
            width: 1560,
            height: 330,
            transform: `translate(-50%, -50%) rotate(-1.6deg) translateY(${(1 - stripIn) * 120}px)`,
            opacity: stripIn,
            background: `linear-gradient(168deg, ${C.paperHi} 0%, ${C.paper} 46%, ${C.paperLo} 100%)`,
            borderRadius: 10,
            boxShadow: "0 30px 70px rgba(0,0,0,0.55)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          {/* Spinning hubs flanking the wordmark */}
          {(["left", "right"] as const).map((side) => (
            <div
              key={side}
              style={{
                position: "absolute",
                [side]: 110,
                top: "50%",
                width: 150,
                height: 150,
                transform: `translateY(-50%) rotate(${hubAngle}deg)`,
                opacity: 0.92,
                borderRadius: "50%",
                overflow: "hidden",
              }}
            >
              <img
                src={staticFile(`cassette-reel-${side}.png`)}
                style={{ width: "100%", height: "100%" }}
              />
            </div>
          ))}
          <div
            style={{
              fontFamily: F.marker,
              fontSize: 210,
              color: C.ink,
              transform: `rotate(-2deg) scale(${0.7 + markIn * 0.3})`,
              opacity: markIn,
              textShadow: "4px 6px 0 rgba(24,18,6,0.18)",
            }}
          >
            YAPPER
          </div>
          {/* Label small print */}
          <div
            style={{
              position: "absolute",
              bottom: 18,
              right: 130,
              fontFamily: F.marker,
              fontSize: 34,
              color: C.inkSoft,
              transform: "rotate(-1deg)",
            }}
          >
            side A · rec '26
          </div>
        </div>

        <div
          style={{
            position: "absolute",
            top: "63%",
            width: "100%",
            textAlign: "center",
            fontFamily: F.mono,
            fontWeight: 600,
            fontSize: 44,
            letterSpacing: 9,
            color: C.cream,
            opacity: ramp(frame, [10, 16], [0, 1]),
          }}
        >
          READS YOUR AI OUT LOUD
        </div>

        <div
          style={{
            position: "absolute",
            top: "72.5%",
            width: "100%",
            display: "flex",
            justifyContent: "center",
            gap: 28,
          }}
        >
          <Chip at={14}>TAP RIGHT ⌘</Chip>
          <Chip at={17}>WALK AWAY</Chip>
          <Chip at={20}>MACOS</Chip>
        </div>
      </PushIn>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// The edit
// ---------------------------------------------------------------------------

const Sfx: React.FC = () => (
  <>
    <Sequence from={0} durationInFrames={30}>
      <Audio src={staticFile("sfx/whip.wav")} volume={0.55} />
    </Sequence>
    <Sequence from={cutAt(1)} durationInFrames={24}>
      <Audio src={staticFile("sfx/switch.wav")} volume={0.6} />
    </Sequence>
    <Sequence from={cutAt(2)} durationInFrames={24}>
      <Audio src={staticFile("sfx/whip.wav")} volume={0.5} />
    </Sequence>
    <Sequence from={cutAt(3) + 10} durationInFrames={24}>
      <Audio src={staticFile("sfx/switch.wav")} volume={0.7} />
    </Sequence>
    <Sequence from={cutAt(4)} durationInFrames={30}>
      <Audio src={staticFile("sfx/whoosh.wav")} volume={0.55} />
    </Sequence>
    <Sequence from={cutAt(4) + 14} durationInFrames={24}>
      <Audio src={staticFile("sfx/switch.wav")} volume={0.65} />
    </Sequence>
    <Sequence from={cutAt(5) + 5} durationInFrames={24}>
      <Audio src={staticFile("sfx/switch.wav")} volume={0.55} />
    </Sequence>
    <Sequence from={cutAt(6)} durationInFrames={24}>
      <Audio src={staticFile("sfx/whip.wav")} volume={0.5} />
    </Sequence>
    <Sequence from={cutAt(7)} durationInFrames={24}>
      <Audio src={staticFile("sfx/switch.wav")} volume={0.6} />
    </Sequence>
    <Sequence from={cutAt(8)} durationInFrames={40}>
      <Audio src={staticFile("sfx/whoosh.wav")} volume={0.6} />
    </Sequence>
  </>
);

export const SideAPromo: React.FC = () => {
  return (
    <AbsoluteFill style={{ background: C.void }}>
      <Series>
        <Series.Sequence durationInFrames={SHOTS[0]} premountFor={30}>
          <YapWall />
        </Series.Sequence>
        <Series.Sequence durationInFrames={SHOTS[1]} premountFor={30}>
          <DontReadIt />
        </Series.Sequence>
        <Series.Sequence durationInFrames={SHOTS[2]} premountFor={30}>
          <PressPlay />
        </Series.Sequence>
        <Series.Sequence durationInFrames={SHOTS[3]} premountFor={30}>
          <KeyTap />
        </Series.Sequence>
        <Series.Sequence durationInFrames={SHOTS[4]} premountFor={30}>
          <DeckHero />
        </Series.Sequence>
        <Series.Sequence durationInFrames={SHOTS[5]} premountFor={30}>
          <SkipsCode />
        </Series.Sequence>
        <Series.Sequence durationInFrames={SHOTS[6]} premountFor={30}>
          <DoubleSpeed />
        </Series.Sequence>
        <Series.Sequence durationInFrames={SHOTS[7]} premountFor={30}>
          <RecMode />
        </Series.Sequence>
        <Series.Sequence durationInFrames={SHOTS[8]} premountFor={30}>
          <EndCard />
        </Series.Sequence>
      </Series>
      <Sfx />
      <CutFlash />
      <Grade />
    </AbsoluteFill>
  );
};
