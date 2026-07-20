import React from "react";
import { AbsoluteFill, random, useCurrentFrame } from "remotion";
import { C } from "../tokens";

/** The room the whole video lives in: charcoal void with a soft panel-glow center. */
export const Backdrop: React.FC = () => (
  <AbsoluteFill
    style={{
      background: `radial-gradient(120% 90% at 50% 40%, ${C.panel} 0%, ${C.void} 58%, #0b0908 100%)`,
    }}
  />
);

/** Animated film grain — feTurbulence jittered per frame, blended over the scene. */
export const Grain: React.FC<{ opacity?: number }> = ({ opacity = 0.07 }) => {
  const frame = useCurrentFrame();
  const ox = Math.floor(random(`gx-${frame}`) * 260);
  const oy = Math.floor(random(`gy-${frame}`) * 260);
  return (
    <AbsoluteFill style={{ pointerEvents: "none", opacity, mixBlendMode: "overlay" }}>
      <svg width="100%" height="100%">
        <filter id="yap-grain">
          <feTurbulence
            type="fractalNoise"
            baseFrequency="0.82"
            numOctaves="2"
            stitchTiles="stitch"
          />
          <feColorMatrix type="saturate" values="0" />
        </filter>
        <rect
          x={-ox}
          y={-oy}
          width={1920 + 300}
          height={1080 + 300}
          filter="url(#yap-grain)"
        />
      </svg>
    </AbsoluteFill>
  );
};

/** A 2-frame paper splice-flash at a global cut point. */
export const SpliceFlash: React.FC<{ at: number[] }> = ({ at }) => {
  const frame = useCurrentFrame();
  const hit = at.some((a) => frame === a || frame === a + 1);
  if (!hit) return null;
  return <AbsoluteFill style={{ background: C.paper, opacity: 0.85 }} />;
};
