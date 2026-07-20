import React from "react";
import {
  AbsoluteFill,
  Audio,
  Easing,
  Img,
  Sequence,
  interpolate,
  random,
  staticFile,
  useCurrentFrame,
} from "remotion";
import {loadFont} from "@remotion/fonts";

loadFont({family: "Anton", url: staticFile("fonts/anton-400.woff2"), weight: "400"});
loadFont({family: "IBM Plex Mono", url: staticFile("fonts/plexmono-600.woff2"), weight: "600"});
loadFont({family: "Marker", url: staticFile("fonts/marker-400.woff2"), weight: "400"});

export const PROMO_FRAMES = 270; // 9 seconds at 30fps

const INK = "#100e0b";
const PAPER = "#dec979";
const CREAM = "#f0e9d6";
const RED = "#e04432";
const ACID = "#b8d52b";
const MONO = "'IBM Plex Mono', monospace";
const IMPACT = "Anton, Impact, sans-serif";
const MARKER = "Marker, cursive";

const ease = Easing.bezier(0.16, 1, 0.3, 1);
const r = (
  frame: number,
  input: [number, number],
  output: [number, number],
  easing = ease,
) =>
  interpolate(frame, input, output, {
    easing,
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

const clamp = (n: number) => Math.max(0, Math.min(1, n));
const pulse = (frame: number, at: number, length = 9) =>
  clamp(r(frame, [at, at + 2], [0, 1]) - r(frame, [at + length - 3, at + length], [0, 1]));

const CutLabel: React.FC<{children: React.ReactNode; invert?: boolean}> = ({
  children,
  invert = false,
}) => (
  <div
    style={{
      position: "absolute",
      top: 42,
      left: 48,
      padding: "10px 15px",
      border: `2px solid ${invert ? INK : CREAM}`,
      color: invert ? INK : CREAM,
      fontFamily: MONO,
      fontSize: 20,
      letterSpacing: 2.4,
    }}
  >
    {children}
  </div>
);

const Scanlines: React.FC<{light?: boolean}> = ({light = false}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill
      style={{
        pointerEvents: "none",
        opacity: light ? 0.1 : 0.16,
        backgroundImage: `repeating-linear-gradient(0deg, transparent 0 5px, ${
          light ? INK : CREAM
        } 5px 6px)`,
        backgroundPositionY: frame % 6,
        mixBlendMode: light ? "multiply" : "screen",
      }}
    />
  );
};

const SceneOverflow: React.FC = () => {
  const frame = useCurrentFrame();
  const lines = [
    "Here’s a comprehensive breakdown of the architecture,",
    "including the trade-offs, edge cases, implementation notes,",
    "testing strategy, migration plan, and a few alternatives…",
    "First, let’s establish the core constraints and assumptions.",
    "The important thing to understand is that the system…",
  ];
  const shove = r(frame, [0, 22], [80, -120], Easing.linear);
  const stamp = r(frame, [8, 14], [2.2, 1], Easing.bezier(0.2, 1.7, 0.4, 1));

  return (
    <AbsoluteFill style={{background: CREAM, color: INK, overflow: "hidden"}}>
      <CutLabel invert>AI ANSWER // 1,842 WORDS</CutLabel>
      <div style={{position: "absolute", left: 88, top: 190, width: 1600, transform: `translateY(${shove}px)`}}>
        {lines.map((line, i) => (
          <div
            key={line}
            style={{
              fontFamily: IMPACT,
              fontSize: 104,
              lineHeight: 0.98,
              textTransform: "uppercase",
              opacity: 0.18 + i * 0.13,
              whiteSpace: "nowrap",
              transform: `translateX(${(random(`overflow-${i}`) - 0.5) * 30}px)`,
            }}
          >
            {line}
          </div>
        ))}
      </div>
      <div
        style={{
          position: "absolute",
          right: 96,
          bottom: 86,
          background: RED,
          color: CREAM,
          padding: "22px 34px 16px",
          fontFamily: IMPACT,
          fontSize: 92,
          lineHeight: 1,
          transform: `rotate(-4deg) scale(${stamp})`,
          boxShadow: "12px 12px 0 rgba(16,14,11,.22)",
        }}
      >
        TOO MUCH SCREEN.
      </div>
      <Scanlines light />
    </AbsoluteFill>
  );
};

const SceneCommand: React.FC = () => {
  const frame = useCurrentFrame();
  const hit = r(frame, [0, 7], [3, 1], Easing.bezier(0.15, 1.45, 0.35, 1));
  const keyDown = pulse(frame, 10, 10);
  const split = r(frame, [12, 27], [0, 100]);

  return (
    <AbsoluteFill style={{background: INK, overflow: "hidden"}}>
      <div
        style={{
          position: "absolute",
          inset: 0,
          background: PAPER,
          clipPath: `polygon(0 0, ${split}% 0, ${Math.max(0, split - 15)}% 100%, 0 100%)`,
        }}
      />
      <div style={{position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", gap: 52}}>
        <div style={{fontFamily: IMPACT, fontSize: 132, color: CREAM, letterSpacing: 2}}>TAP RIGHT</div>
        <div
          style={{
            width: 238,
            height: 220,
            borderRadius: 28,
            background: CREAM,
            color: INK,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontFamily: MONO,
            fontSize: 138,
            transform: `translateY(${keyDown * 20}px) scale(${hit - keyDown * 0.04}) rotate(-2deg)`,
            boxShadow: `0 ${22 - keyDown * 16}px 0 #8c836f, 0 34px 70px rgba(0,0,0,.55)`,
          }}
        >
          ⌘
        </div>
      </div>
      <div style={{position: "absolute", bottom: 58, width: "100%", textAlign: "center", fontFamily: MONO, fontSize: 24, letterSpacing: 5, color: CREAM}}>
        ONE KEY. NO COPY. NO PASTE.
      </div>
      <Scanlines />
    </AbsoluteFill>
  );
};

const Reel: React.FC<{side: "left" | "right"; angle: number}> = ({side, angle}) => {
  const g = side === "left" ? {x: 35.15, y: 47.56, size: 9.4} : {x: 66.92, y: 47.33, size: 9.68};
  return (
    <div
      style={{
        position: "absolute",
        left: `${g.x}%`,
        top: `${g.y}%`,
        width: `${g.size}%`,
        aspectRatio: "1",
        transform: `translate(-50%, -50%) rotate(${angle}deg)`,
      }}
    >
      <Img src={staticFile(`cassette-reel-${side}.png`)} style={{width: "100%", height: "100%"}} />
    </div>
  );
};

const Deck: React.FC<{frame: number}> = ({frame}) => {
  const play = r(frame, [4, 9], [0, 1]);
  const angle = Math.max(0, frame - 5) * 16;
  return (
    <div style={{position: "relative", width: 1320}}>
      <Img src={staticFile("cassette-deck.png")} style={{width: "100%", display: "block"}} />
      <Reel side="left" angle={angle} />
      <Reel side="right" angle={-angle * 1.06} />
      <div
        style={{
          position: "absolute",
          left: "40.74%",
          top: "91.08%",
          width: "10.43%",
          height: "13.57%",
          transform: `translate(-50%, calc(-50% + ${play * 13}%))`,
          filter: `brightness(${1 - play * 0.25})`,
        }}
      >
        <Img src={staticFile("cassette-cap-play.png")} style={{width: "100%", height: "100%"}} />
      </div>
    </div>
  );
};

const WaveRibbon: React.FC<{frame: number}> = ({frame}) => (
  <svg viewBox="0 0 1920 1080" style={{position: "absolute", inset: 0, width: "100%", height: "100%"}}>
    <path d="M -80 360 C 280 160, 400 620, 720 410 S 1110 220, 1390 430 S 1730 640, 2010 330" fill="none" stroke="rgba(240,233,214,.14)" strokeWidth="112" />
    <path
      d="M -80 360 C 280 160, 400 620, 720 410 S 1110 220, 1390 430 S 1730 640, 2010 330"
      fill="none"
      stroke={PAPER}
      strokeWidth="8"
      strokeLinecap="round"
      strokeDasharray="20 24"
      strokeDashoffset={-frame * 18}
    />
  </svg>
);

const SceneRoute: React.FC = () => {
  const frame = useCurrentFrame();
  const deckIn = r(frame, [2, 14], [1.45, 1]);
  const deckX = r(frame, [0, 18], [440, 170]);
  const words = ["TEXT", "BECOMES", "VOICE"];

  return (
    <AbsoluteFill style={{background: INK, overflow: "hidden"}}>
      <WaveRibbon frame={frame} />
      <CutLabel>SIGNAL ROUTING // LIVE</CutLabel>
      <div style={{position: "absolute", left: 84, top: 170, zIndex: 2}}>
        {words.map((word, i) => {
          const on = r(frame, [5 + i * 7, 10 + i * 7], [0, 1]);
          return (
            <div key={word} style={{fontFamily: IMPACT, fontSize: 124, lineHeight: 0.88, color: i === 2 ? PAPER : CREAM, opacity: on, transform: `translateX(${(1 - on) * -80}px)`}}>
              {word}
            </div>
          );
        })}
      </div>
      <div
        style={{
          position: "absolute",
          right: -deckX,
          bottom: -150,
          transform: `scale(${deckIn}) rotate(-7deg)`,
          filter: "drop-shadow(0 40px 80px rgba(0,0,0,.75))",
        }}
      >
        <Deck frame={frame} />
      </div>
      <Scanlines />
    </AbsoluteFill>
  );
};

const Bars: React.FC<{frame: number}> = ({frame}) => (
  <div style={{display: "flex", gap: 12, height: 220, alignItems: "center"}}>
    {Array.from({length: 25}).map((_, i) => {
      const height = 24 + Math.abs(Math.sin(frame * 0.45 + i * 0.73)) * (80 + random(`bar-${i}`) * 115);
      return <div key={i} style={{width: 13, height, borderRadius: 8, background: i % 6 === 0 ? RED : INK}} />;
    })}
  </div>
);

const ScenePromise: React.FC = () => {
  const frame = useCurrentFrame();
  const out = r(frame, [31, 39], [1, 0]);
  const pop = r(frame, [0, 7], [1.4, 1], Easing.bezier(0.2, 1.6, 0.4, 1));
  return (
    <AbsoluteFill style={{background: PAPER, color: INK, overflow: "hidden"}}>
      <CutLabel invert>YAPPER // NOW SPEAKING</CutLabel>
      <div style={{position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", opacity: out, transform: `scale(${pop})`}}>
        <div style={{fontFamily: IMPACT, fontSize: 190, lineHeight: 0.88, textAlign: "center"}}>READS YOUR AI</div>
        <div style={{fontFamily: IMPACT, fontSize: 234, lineHeight: 0.92, color: RED, textAlign: "center"}}>OUT LOUD.</div>
        <Bars frame={frame} />
      </div>
      <Scanlines light />
    </AbsoluteFill>
  );
};

const SourceCard: React.FC<{name: string; frame: number; at: number; color: string}> = ({name, frame, at, color}) => {
  const scale = r(frame, [at, at + 4], [1.7, 1], Easing.bezier(0.18, 1.55, 0.35, 1));
  const gone = frame >= at + 12;
  if (frame < at || gone) return null;
  return (
    <AbsoluteFill style={{background: color, color: color === INK ? CREAM : INK, alignItems: "center", justifyContent: "center"}}>
      <div style={{fontFamily: IMPACT, fontSize: 300, transform: `scale(${scale}) rotate(${(random(name) - 0.5) * 4}deg)`}}>{name}</div>
      <div style={{position: "absolute", bottom: 86, fontFamily: MONO, fontSize: 27, letterSpacing: 5}}>ANSWER IN → VOICE OUT</div>
    </AbsoluteFill>
  );
};

const SceneSources: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{background: INK}}>
      <SourceCard name="CLAUDE" frame={frame} at={0} color={CREAM} />
      <SourceCard name="CHATGPT" frame={frame} at={12} color={ACID} />
      <SourceCard name="CODEX" frame={frame} at={24} color={INK} />
      {frame >= 36 ? (
        <AbsoluteFill style={{background: RED, color: CREAM, alignItems: "center", justifyContent: "center"}}>
          <div style={{fontFamily: IMPACT, fontSize: 204, lineHeight: 0.9, textAlign: "center"}}>OR ANYTHING<br />YOU HIGHLIGHT.</div>
          <div style={{position: "absolute", right: 95, top: 90, fontFamily: MARKER, fontSize: 48, transform: "rotate(7deg)"}}>any app ↘</div>
        </AbsoluteFill>
      ) : null}
    </AbsoluteFill>
  );
};

const SceneEnd: React.FC = () => {
  const frame = useCurrentFrame();
  const label = r(frame, [0, 8], [1.35, 1], Easing.bezier(0.2, 1.55, 0.4, 1));
  const sub = r(frame, [9, 18], [0, 1]);
  const key = pulse(frame, 20, 12);
  return (
    <AbsoluteFill style={{background: INK, color: CREAM, alignItems: "center", justifyContent: "center", overflow: "hidden"}}>
      <div style={{position: "absolute", width: 1450, height: 460, background: PAPER, transform: `rotate(-2deg) scale(${label})`, boxShadow: "24px 28px 0 #070604"}}>
        <div style={{position: "absolute", left: 64, top: 35, fontFamily: MONO, fontSize: 22, color: INK, letterSpacing: 4}}>SIDE A // MACOS</div>
        <div style={{position: "absolute", left: 58, top: 82, fontFamily: IMPACT, fontSize: 278, lineHeight: 1, color: INK}}>YAPPER</div>
        <div style={{position: "absolute", right: 58, bottom: 46, background: INK, color: CREAM, padding: "11px 18px", fontFamily: IMPACT, fontSize: 30, letterSpacing: 2}}>READS ALOUD</div>
      </div>
      <div style={{position: "absolute", bottom: 72, display: "flex", alignItems: "center", gap: 24, opacity: sub, fontFamily: MONO, fontSize: 31, letterSpacing: 3}}>
        <span>TAP RIGHT</span>
        <span style={{display: "inline-flex", width: 64, height: 62, border: `2px solid ${CREAM}`, borderRadius: 10, alignItems: "center", justifyContent: "center", transform: `translateY(${key * 7}px)`, boxShadow: `0 ${7 - key * 5}px 0 rgba(240,233,214,.35)`}}>⌘</span>
        <span>AND WALK AWAY.</span>
      </div>
      <Scanlines />
    </AbsoluteFill>
  );
};

const CUTS = [24, 54, 102, 144, 228];

export const FreshPromo: React.FC = () => {
  const frame = useCurrentFrame();
  const flash = CUTS.some((cut) => frame === cut);
  return (
    <AbsoluteFill style={{background: INK}}>
      <Sequence from={0} durationInFrames={24}><SceneOverflow /></Sequence>
      <Sequence from={24} durationInFrames={30}><SceneCommand /></Sequence>
      <Sequence from={54} durationInFrames={48}><SceneRoute /></Sequence>
      <Sequence from={102} durationInFrames={42}><ScenePromise /></Sequence>
      <Sequence from={144} durationInFrames={84}><SceneSources /></Sequence>
      <Sequence from={228} durationInFrames={42}><SceneEnd /></Sequence>

      {[0, 24, 54, 102, 144, 156, 168, 180, 228].map((at, i) => (
        <Sequence key={at} from={at} durationInFrames={20}>
          <Audio src={staticFile(i % 3 === 0 ? "sfx/whoosh.wav" : i % 3 === 1 ? "sfx/switch.wav" : "sfx/whip.wav")} volume={i === 1 ? 0.45 : 0.26} />
        </Sequence>
      ))}
      {flash ? <AbsoluteFill style={{background: CREAM, opacity: 0.72}} /> : null}
    </AbsoluteFill>
  );
};
