import { loadFont } from "@remotion/fonts";
import { staticFile } from "remotion";

// Self-hosted (public/fonts) so renders never depend on fonts.gstatic.com.
// @remotion/fonts wires delayRender internally — no frame paints unfonted.
const load = (family: string, file: string, weight: string) =>
  loadFont({ family, url: staticFile(`fonts/${file}`), weight });

load("Anton", "anton-400.woff2", "400");
load("Permanent Marker", "marker-400.woff2", "400");
load("IBM Plex Mono", "plexmono-400.woff2", "400");
load("IBM Plex Mono", "plexmono-500.woff2", "500");
load("IBM Plex Mono", "plexmono-600.woff2", "600");

// Yapper tape-label identity — mirrors site/styleguide.html custom properties.
export const C = {
  void: "#0f0d0b",
  panel: "#161310",
  panel2: "#1c1814",
  cream: "#ece3cb",
  dust: "rgba(236,227,203,0.60)",
  faint: "rgba(236,227,203,0.34)",
  paper: "#ddc98b",
  paperHi: "#eadfae",
  paperLo: "#c9b06a",
  ink: "#181206",
  inkSoft: "rgba(24,18,6,0.72)",
  red: "#a53a2e",
  redHot: "#c74537",
  acid: "#a8c636",
  line: "rgba(236,227,203,0.14)",
} as const;

export const F = {
  impact: "Anton",
  marker: "'Permanent Marker'",
  mono: "'IBM Plex Mono'",
} as const;
