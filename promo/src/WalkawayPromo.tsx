import React from "react";
import {loadFont} from "@remotion/fonts";
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

loadFont({family: "WalkAnton", url: staticFile("fonts/anton-400.woff2"), weight: "400"});
loadFont({family: "WalkMono", url: staticFile("fonts/plexmono-600.woff2"), weight: "600"});
loadFont({family: "WalkMarker", url: staticFile("fonts/marker-400.woff2"), weight: "400"});

export const WALKAWAY_FRAMES = 285; // 9.5 seconds at 30fps

const NIGHT = "#11130f";
const OAT = "#f0e7ce";
const TAPE = "#d8c477";
const ORANGE = "#ff5635";
const BLUE = "#80a8ff";
const OLIVE = "#829239";
const ANTON = "WalkAnton, Impact, sans-serif";
const MONO = "WalkMono, monospace";
const MARKER = "WalkMarker, cursive";

const interpolateClamped = (
  frame: number,
  input: [number, number],
  output: [number, number],
  easing = Easing.bezier(0.16, 1, 0.3, 1),
) =>
  interpolate(frame, input, output, {
    easing,
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

const Film: React.FC<{dark?: boolean}> = ({dark = false}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill
      style={{
        pointerEvents: "none",
        opacity: dark ? 0.11 : 0.07,
        backgroundImage: `repeating-linear-gradient(0deg, transparent 0 4px, ${dark ? OAT : NIGHT} 4px 5px)`,
        backgroundPositionY: frame % 5,
        mixBlendMode: dark ? "screen" : "multiply",
      }}
    />
  );
};

const CornerCode: React.FC<{children: React.ReactNode; light?: boolean}> = ({children, light = false}) => (
  <div
    style={{
      position: "absolute",
      left: 45,
      top: 38,
      fontFamily: MONO,
      fontSize: 18,
      letterSpacing: 3,
      color: light ? OAT : NIGHT,
      borderBottom: `2px solid ${light ? OAT : NIGHT}`,
      paddingBottom: 8,
    }}
  >
    {children}
  </div>
);

const ReplyLine: React.FC<{width: number; delay: number}> = ({width, delay}) => {
  const frame = useCurrentFrame();
  const reveal = interpolateClamped(frame, [delay, delay + 7], [0, width]);
  return <div style={{height: 20, width: reveal, borderRadius: 10, background: NIGHT, opacity: 0.2}} />;
};

const AnswerReady: React.FC = () => {
  const frame = useCurrentFrame();
  const cardY = interpolateClamped(frame, [0, 10], [120, 0]);
  const cardScale = interpolateClamped(frame, [0, 10], [0.92, 1]);
  const ready = interpolateClamped(frame, [17, 24], [1.9, 1], Easing.bezier(0.2, 1.55, 0.4, 1));
  return (
    <AbsoluteFill style={{background: OAT, color: NIGHT, overflow: "hidden"}}>
      <CornerCode>CHAT // RESPONSE COMPLETE</CornerCode>
      <div
        style={{
          position: "absolute",
          left: 170,
          top: 150,
          width: 1580,
          height: 690,
          background: "#fffaf0",
          border: `4px solid ${NIGHT}`,
          borderRadius: 34,
          boxShadow: "20px 24px 0 rgba(17,19,15,.15)",
          transform: `translateY(${cardY}px) scale(${cardScale}) rotate(-0.7deg)`,
          padding: "75px 85px",
          boxSizing: "border-box",
        }}
      >
        <div style={{display: "flex", alignItems: "center", gap: 20, marginBottom: 48}}>
          <div style={{width: 34, height: 34, borderRadius: "50%", background: OLIVE}} />
          <div style={{fontFamily: MONO, fontSize: 24, letterSpacing: 2}}>ASSISTANT</div>
        </div>
        <div style={{display: "flex", flexDirection: "column", gap: 24}}>
          <ReplyLine width={1240} delay={1} />
          <ReplyLine width={1370} delay={4} />
          <ReplyLine width={1080} delay={7} />
          <ReplyLine width={1290} delay={10} />
          <ReplyLine width={840} delay={13} />
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          right: 86,
          bottom: 72,
          background: ORANGE,
          color: OAT,
          fontFamily: ANTON,
          fontSize: 102,
          padding: "18px 34px 12px",
          transform: `rotate(3deg) scale(${ready})`,
          boxShadow: `10px 12px 0 ${NIGHT}`,
        }}
      >
        ANSWER READY.
      </div>
      <Film />
    </AbsoluteFill>
  );
};

const Keyboard: React.FC = () => {
  const frame = useCurrentFrame();
  const zoom = interpolateClamped(frame, [0, 10], [1.4, 1]);
  const press = interpolateClamped(frame, [13, 17], [0, 1]) - interpolateClamped(frame, [22, 27], [0, 1]);
  const keys = Array.from({length: 28});
  return (
    <AbsoluteFill style={{background: BLUE, color: NIGHT, overflow: "hidden"}}>
      <CornerCode>KEYBOARD MAP // RIGHT SIDE</CornerCode>
      <div style={{position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", transform: `scale(${zoom}) rotate(5deg)`}}>
        <div style={{width: 1500, display: "grid", gridTemplateColumns: "repeat(10, 1fr)", gap: 18}}>
          {keys.map((_, i) => {
            const target = i === 27;
            return (
              <div
                key={i}
                style={{
                  height: 130,
                  borderRadius: 18,
                  border: `4px solid ${NIGHT}`,
                  background: target ? ORANGE : "rgba(240,231,206,.3)",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  fontFamily: MONO,
                  fontSize: target ? 74 : 24,
                  transform: target ? `translateY(${press * 14}px)` : undefined,
                  boxShadow: `0 ${target ? 13 - press * 10 : 10}px 0 rgba(17,19,15,.55)`,
                }}
              >
                {target ? "⌘" : i % 5 === 0 ? "·" : ""}
              </div>
            );
          })}
        </div>
      </div>
      <div style={{position: "absolute", left: 70, bottom: 58, fontFamily: ANTON, fontSize: 118, lineHeight: 0.9}}>
        RIGHT COMMAND.<br />THAT&apos;S THE WHOLE MOVE.
      </div>
      <Film />
    </AbsoluteFill>
  );
};

const CassetteReel: React.FC<{side: "left" | "right"; frame: number}> = ({side, frame}) => {
  const position = side === "left" ? {left: 35.15, top: 47.56, size: 9.4} : {left: 66.92, top: 47.33, size: 9.68};
  const angle = Math.max(0, frame - 6) * (side === "left" ? 15 : -16.5);
  return (
    <div style={{position: "absolute", left: `${position.left}%`, top: `${position.top}%`, width: `${position.size}%`, aspectRatio: "1", transform: `translate(-50%, -50%) rotate(${angle}deg)`}}>
      <Img src={staticFile(`cassette-reel-${side}.png`)} style={{width: "100%", height: "100%"}} />
    </div>
  );
};

const AnimatedDeck: React.FC<{frame: number}> = ({frame}) => (
  <div style={{position: "relative", width: 1120}}>
    <Img src={staticFile("cassette-deck.png")} style={{width: "100%", display: "block"}} />
    <CassetteReel side="left" frame={frame} />
    <CassetteReel side="right" frame={frame} />
  </div>
);

const TapeRibbon: React.FC<{frame: number}> = ({frame}) => {
  const draw = interpolateClamped(frame, [0, 24], [1, 0], Easing.linear);
  return (
    <svg viewBox="0 0 1920 1080" style={{position: "absolute", inset: 0, width: "100%", height: "100%"}}>
      <path
        d="M -100 190 C 300 120, 320 410, 650 340 S 880 120, 1120 260 S 1310 520, 1520 480 S 1800 270, 2040 430"
        fill="none"
        stroke={OAT}
        strokeWidth="92"
        opacity="0.1"
      />
      <path
        d="M -100 190 C 300 120, 320 410, 650 340 S 880 120, 1120 260 S 1310 520, 1520 480 S 1800 270, 2040 430"
        fill="none"
        stroke={ORANGE}
        strokeWidth="10"
        strokeLinecap="round"
        pathLength="1"
        strokeDasharray="1"
        strokeDashoffset={draw}
      />
      <path
        d="M -100 190 C 300 120, 320 410, 650 340 S 880 120, 1120 260 S 1310 520, 1520 480 S 1800 270, 2040 430"
        fill="none"
        stroke={TAPE}
        strokeWidth="3"
        strokeDasharray="18 26"
        strokeDashoffset={-frame * 16}
      />
    </svg>
  );
};

const Spooling: React.FC = () => {
  const frame = useCurrentFrame();
  const deckIn = interpolateClamped(frame, [0, 14], [540, 0]);
  const caption = interpolateClamped(frame, [19, 29], [0, 1]);
  const fragments = ["Here’s the plan…", "First, we’ll…", "The key trade-off…"];
  return (
    <AbsoluteFill style={{background: NIGHT, color: OAT, overflow: "hidden"}}>
      <TapeRibbon frame={frame} />
      <CornerCode light>VOICE TRACK // SIDE A</CornerCode>
      {fragments.map((fragment, i) => (
        <div
          key={fragment}
          style={{
            position: "absolute",
            left: 100 + i * 420,
            top: 140 + (i % 2) * 130,
            fontFamily: MONO,
            fontSize: 23,
            color: OAT,
            opacity: interpolateClamped(frame, [i * 5, i * 5 + 8], [0, 0.72]),
            transform: `translateX(${frame * 7}px) rotate(${i % 2 ? 4 : -3}deg)`,
          }}
        >
          {fragment}
        </div>
      ))}
      <div style={{position: "absolute", left: "50%", bottom: -160, transform: `translateX(-50%) translateY(${deckIn}px) rotate(2deg)`, filter: "drop-shadow(0 35px 80px rgba(0,0,0,.8))"}}>
        <AnimatedDeck frame={frame} />
      </div>
      <div style={{position: "absolute", right: 80, top: 68, fontFamily: ANTON, fontSize: 112, lineHeight: 0.88, textAlign: "right", color: TAPE, opacity: caption}}>
        THE ANSWER<br />KEEPS ROLLING.
      </div>
      <Film dark />
    </AbsoluteFill>
  );
};

const Equalizer: React.FC<{frame: number; color?: string}> = ({frame, color = OAT}) => (
  <div style={{display: "flex", alignItems: "center", gap: 8, height: 70}}>
    {Array.from({length: 22}).map((_, i) => (
      <div
        key={i}
        style={{
          width: 8,
          height: 10 + Math.abs(Math.sin(frame * 0.55 + i * 0.82)) * (22 + random(`walk-eq-${i}`) * 42),
          borderRadius: 5,
          background: i % 7 === 0 ? ORANGE : color,
        }}
      />
    ))}
  </div>
);

const WalkCut: React.FC = () => {
  const frame = useCurrentFrame();
  const index = Math.min(2, Math.floor(frame / 17));
  const cards = [
    {verb: "REFILL.", note: "coffee counts", bg: ORANGE, fg: OAT},
    {verb: "STRETCH.", note: "your neck will thank you", bg: OLIVE, fg: OAT},
    {verb: "LOOK AWAY.", note: "the screen can cope", bg: OAT, fg: NIGHT},
  ];
  const card = cards[index];
  const local = frame - index * 17;
  const slam = interpolateClamped(local, [0, 5], [1.7, 1], Easing.bezier(0.2, 1.5, 0.4, 1));
  return (
    <AbsoluteFill style={{background: card.bg, color: card.fg, overflow: "hidden"}}>
      <div style={{position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", fontFamily: ANTON, fontSize: index === 2 ? 248 : 330, transform: `scale(${slam}) rotate(${index - 1}deg)`}}>
        {card.verb}
      </div>
      <div style={{position: "absolute", right: 64, top: 58, fontFamily: MARKER, fontSize: 42, transform: "rotate(4deg)"}}>{card.note}</div>
      <div style={{position: "absolute", left: 70, bottom: 48, display: "flex", alignItems: "center", gap: 30}}>
        <Equalizer frame={frame} color={card.fg} />
        <div style={{fontFamily: MONO, fontSize: 20, letterSpacing: 3}}>YAPPER IS STILL READING</div>
      </div>
      <Film dark={card.fg === OAT} />
    </AbsoluteFill>
  );
};

const AcrossRoom: React.FC = () => {
  const frame = useCurrentFrame();
  const travel = interpolateClamped(frame, [0, 42], [0, 1], Easing.linear);
  const ring = (frame * 12) % 240;
  return (
    <AbsoluteFill style={{background: NIGHT, color: OAT, overflow: "hidden"}}>
      <CornerCode light>PLAYBACK RANGE // THE WHOLE ROOM</CornerCode>
      <svg viewBox="0 0 1920 1080" style={{position: "absolute", inset: 0, width: "100%", height: "100%"}}>
        <path d="M 310 700 C 650 360, 1080 770, 1600 330" fill="none" stroke="rgba(240,231,206,.18)" strokeWidth="5" strokeDasharray="14 18" />
        <circle cx={310 + 1290 * travel} cy={700 - 370 * travel + Math.sin(travel * Math.PI) * -120} r="16" fill={ORANGE} />
        {[0, 80, 160].map((offset) => (
          <circle key={offset} cx="310" cy="700" r={(ring + offset) % 240} fill="none" stroke={TAPE} strokeWidth="5" opacity={1 - ((ring + offset) % 240) / 240} />
        ))}
      </svg>
      <div style={{position: "absolute", left: 92, bottom: 90, fontFamily: ANTON, fontSize: 170, lineHeight: 0.88}}>
        THE ANSWER<br /><span style={{color: TAPE}}>FOLLOWS.</span>
      </div>
      <div style={{position: "absolute", right: 90, top: 190, width: 250, height: 380}}>
        <div style={{position: "absolute", left: 75, top: 0, width: 92, height: 92, borderRadius: "50%", background: OAT}} />
        <div style={{position: "absolute", left: 52, top: 94, width: 140, height: 230, borderRadius: "70px 70px 24px 24px", background: OAT, transform: "rotate(-8deg)"}} />
        <div style={{position: "absolute", left: 8, bottom: 0, fontFamily: MARKER, fontSize: 34, color: ORANGE, transform: "rotate(-5deg)"}}>you, elsewhere</div>
      </div>
      <Film dark />
    </AbsoluteFill>
  );
};

const SideBEnd: React.FC = () => {
  const frame = useCurrentFrame();
  const card = interpolateClamped(frame, [0, 9], [1.4, 1], Easing.bezier(0.2, 1.5, 0.4, 1));
  const line = interpolateClamped(frame, [10, 22], [0, 1]);
  return (
    <AbsoluteFill style={{background: OAT, color: NIGHT, alignItems: "center", justifyContent: "center", overflow: "hidden"}}>
      <div style={{width: 1510, height: 570, background: OLIVE, border: `6px solid ${NIGHT}`, boxShadow: `24px 26px 0 ${NIGHT}`, transform: `scale(${card}) rotate(-1.2deg)`, position: "relative"}}>
        <div style={{position: "absolute", left: 55, top: 42, fontFamily: MONO, fontSize: 21, letterSpacing: 4}}>YAPPER // SIDE B // MACOS</div>
        <div style={{position: "absolute", left: 45, top: 78, fontFamily: ANTON, fontSize: 300, lineHeight: 1}}>YAPPER</div>
        <div style={{position: "absolute", right: 50, top: 58, width: 112, height: 112, background: ORANGE, borderRadius: "50%", display: "flex", alignItems: "center", justifyContent: "center", fontFamily: ANTON, fontSize: 43}}>PLAY</div>
        <div style={{position: "absolute", left: 58, bottom: 44, fontFamily: ANTON, fontSize: 74, letterSpacing: 1, opacity: line}}>YOUR AI, OFF SCREEN.</div>
        <div style={{position: "absolute", right: 48, bottom: 50, fontFamily: MONO, fontSize: 20, letterSpacing: 2}}>RIGHT ⌘ → WALK AWAY</div>
      </div>
      <Film />
    </AbsoluteFill>
  );
};

const HARD_CUTS = [32, 68, 128, 179, 235];

export const WalkawayPromo: React.FC = () => {
  const frame = useCurrentFrame();
  const flash = HARD_CUTS.some((cut) => frame === cut);
  return (
    <AbsoluteFill style={{background: NIGHT}}>
      <Sequence from={0} durationInFrames={32}><AnswerReady /></Sequence>
      <Sequence from={32} durationInFrames={36}><Keyboard /></Sequence>
      <Sequence from={68} durationInFrames={60}><Spooling /></Sequence>
      <Sequence from={128} durationInFrames={51}><WalkCut /></Sequence>
      <Sequence from={179} durationInFrames={56}><AcrossRoom /></Sequence>
      <Sequence from={235} durationInFrames={50}><SideBEnd /></Sequence>

      {[0, 32, 68, 128, 145, 162, 179, 235].map((at, i) => (
        <Sequence key={at} from={at} durationInFrames={18}>
          <Audio src={staticFile(i % 2 === 0 ? "sfx/whip.wav" : "sfx/switch.wav")} volume={i === 1 ? 0.42 : 0.25} />
        </Sequence>
      ))}
      {flash ? <AbsoluteFill style={{background: OAT, opacity: 0.58}} /> : null}
    </AbsoluteFill>
  );
};
