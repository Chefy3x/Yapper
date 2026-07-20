import React from "react";
import { AbsoluteFill, Sequence } from "remotion";
import { Backdrop, Grain, SpliceFlash } from "./components/Atmosphere";
import { SceneHook } from "./scenes/SceneHook";
import { ScenePivot } from "./scenes/ScenePivot";
import { SceneDeck } from "./scenes/SceneDeck";
import { SceneStickers } from "./scenes/SceneStickers";
import { SceneOutro } from "./scenes/SceneOutro";

export const SCENES = [
  { id: "hook", dur: 140, Comp: SceneHook },
  { id: "pivot", dur: 118, Comp: ScenePivot },
  { id: "deck", dur: 262, Comp: SceneDeck },
  { id: "stickers", dur: 220, Comp: SceneStickers },
  { id: "outro", dur: 200, Comp: SceneOutro },
] as const;

export const TOTAL_DURATION = SCENES.reduce((sum, s) => sum + s.dur, 0);

const offsets = SCENES.reduce<number[]>((acc, s, i) => {
  acc.push(i === 0 ? 0 : acc[i - 1] + SCENES[i - 1].dur);
  return acc;
}, []);

export const YapperPromo: React.FC = () => {
  return (
    <AbsoluteFill style={{ overflow: "hidden" }}>
      <Backdrop />
      {SCENES.map((s, i) => (
        <Sequence
          key={s.id}
          from={offsets[i]}
          durationInFrames={s.dur}
          premountFor={60}
        >
          <s.Comp />
        </Sequence>
      ))}
      {/* projector splice-flashes on the two hard cuts into stickers + outro */}
      <SpliceFlash at={[offsets[3], offsets[4]]} />
      <Grain opacity={0.07} />
    </AbsoluteFill>
  );
};
