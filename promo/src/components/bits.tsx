import React from "react";
import { random, useCurrentFrame } from "remotion";
import { C, F } from "../tokens";

/** Small mono chip, like the site's [MACOS 26+] tags. */
export const Chip: React.FC<{
  children: React.ReactNode;
  dark?: boolean;
  size?: number;
  style?: React.CSSProperties;
}> = ({ children, dark = false, size = 22, style }) => (
  <span
    style={{
      display: "inline-block",
      fontFamily: F.mono,
      fontWeight: 500,
      fontSize: size,
      letterSpacing: 2,
      color: dark ? C.ink : C.dust,
      background: dark ? "rgba(24,18,6,0.08)" : "transparent",
      border: `1px solid ${dark ? "rgba(24,18,6,0.45)" : C.line}`,
      borderRadius: 6,
      padding: `${size * 0.32}px ${size * 0.62}px`,
      whiteSpace: "nowrap",
      ...style,
    }}
  >
    {children}
  </span>
);

/** Black parental-advisory-style patch. */
export const AdvisoryPatch: React.FC<{
  top: string;
  bottom: string;
  width?: number;
  style?: React.CSSProperties;
}> = ({ top, bottom, width = 300, style }) => (
  <div
    style={{
      width,
      background: "#0a0806",
      border: "3px solid #f2ead2",
      outline: "3px solid #0a0806",
      padding: `${width * 0.05}px ${width * 0.06}px`,
      textAlign: "center",
      ...style,
    }}
  >
    <div
      style={{
        fontFamily: F.impact,
        color: "#f2ead2",
        fontSize: width * 0.115,
        letterSpacing: width * 0.008,
        lineHeight: 1.05,
        whiteSpace: "nowrap",
      }}
    >
      {top}
    </div>
    <div
      style={{
        marginTop: width * 0.025,
        borderTop: "2px solid #f2ead2",
        paddingTop: width * 0.035,
        fontFamily: F.impact,
        color: "#f2ead2",
        fontSize: width * 0.088,
        letterSpacing: width * 0.012,
        whiteSpace: "nowrap",
      }}
    >
      {bottom}
    </div>
  </div>
);

/** The acid skull sticker — the one green accent the identity allows. */
export const SkullSticker: React.FC<{ size?: number; style?: React.CSSProperties }> = ({
  size = 110,
  style,
}) => (
  <div
    style={{
      width: size,
      height: size,
      borderRadius: "50%",
      background: C.acid,
      boxShadow: "0 10px 22px rgba(0,0,0,0.45)",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      ...style,
    }}
  >
    <svg width={size * 0.58} height={size * 0.58} viewBox="0 0 40 40">
      <path
        d="M20 4c-8 0-13 5.4-13 12.6 0 4.4 2 7.6 5 9.6V31a2.4 2.4 0 0 0 2.4 2.4h.8V36a1.6 1.6 0 1 0 3.2 0v-2.6h3.2V36a1.6 1.6 0 1 0 3.2 0v-2.6h.8A2.4 2.4 0 0 0 28 31v-4.8c3-2 5-5.2 5-9.6C33 9.4 28 4 20 4Z"
        fill={C.ink}
      />
      <circle cx="14.5" cy="17.5" r="3.4" fill={C.acid} />
      <circle cx="25.5" cy="17.5" r="3.4" fill={C.acid} />
      <rect x="18.6" y="23" width="2.8" height="4.6" rx="1.2" fill={C.acid} />
    </svg>
  </div>
);

/** Per-word paste-up jitter: shifts a hair every few frames, like a loose photocopy. */
export const useJitter = (tag: string, every = 6, amp = 1.6) => {
  const frame = useCurrentFrame();
  const t = Math.floor(frame / every);
  return {
    x: (random(`${tag}-x-${t}`) - 0.5) * 2 * amp,
    y: (random(`${tag}-y-${t}`) - 0.5) * 2 * amp,
  };
};
