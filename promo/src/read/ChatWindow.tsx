import React from "react";
import { ANSWER, ANSWER_CHARS, Block, PROMPT, Run, SIDEBAR } from "./content";
import { C } from "../tokens";

const UI = `-apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif`;
const MONO = `"SF Mono", ui-monospace, Menlo, monospace`;

/**
 * Palette sampled straight off a real capture of the app (flat regions of
 * promo reference shot, via ImageMagick) rather than guessed:
 *   main #151515 · rail #131313 · composer #181818 · body #EBEAE7
 *   muted #80807F · dim #61605B
 */
const W = {
  main: "#151515",
  rail: "#131313",
  composer: "#181818",
  hair: "rgba(255,255,255,0.07)",
  text: "#EBEAE7",
  muted: "#80807F",
  dim: "#61605B",
  hover: "rgba(255,255,255,0.055)",
  chip: "rgba(255,255,255,0.08)",
  accent: "#C96442",
};

/* --------------------------------------------------------------- tiny icons */

const Ico: React.FC<{ d: string; s: number; c?: string; fill?: boolean }> = ({
  d,
  s,
  c = W.muted,
  fill = false,
}) => (
  <svg width={s} height={s} viewBox="0 0 24 24" style={{ flex: "0 0 auto", display: "block" }}>
    <path
      d={d}
      fill={fill ? c : "none"}
      stroke={fill ? "none" : c}
      strokeWidth={1.7}
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

const P = {
  search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zm9 16l-4.2-4.2",
  plus: "M12 5v14M5 12h14",
  folder: "M3 7a2 2 0 0 1 2-2h4l2 2h6a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
  artifact: "M12 3l2.6 5.7L21 9.6l-4.5 4.3 1.1 6.1L12 17.2 6.4 20l1.1-6.1L3 9.6l6.4-.9z",
  clock: "M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16zm0 4v4l3 2",
  sliders: "M4 8h10M18 8h2M4 16h4M12 16h8M14 5v6M8 13v6",
  chevR: "M9 6l6 6-6 6",
  chevD: "M6 9l6 6 6-6",
  panel: "M4 5h16v14H4zM10 5v14",
  back: "M15 6l-6 6 6 6",
  fwd: "M9 6l6 6-6 6",
  chat: "M20 12a8 8 0 1 1-3.1-6.3L20 5l-.6 3.2A8 8 0 0 1 20 12z",
  code: "M9 8l-4 4 4 4M15 8l4 4-4 4",
  globe: "M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16zM4 12h16M12 4c2.5 2.5 2.5 13 0 16M12 4c-2.5 2.5-2.5 13 0 16",
  dots: "M12 6h.01M12 12h.01M12 18h.01",
  term: "M5 7l4 4-4 4M12 15h7",
  mic: "M12 4a2.5 2.5 0 0 1 2.5 2.5v5a2.5 2.5 0 0 1-5 0v-5A2.5 2.5 0 0 1 12 4zM6 11a6 6 0 0 0 12 0M12 17v3",
  ret: "M9 10H7a3 3 0 0 0 0 6h2M15 7v9M15 16l-3-3M15 16l3-3",
  win: "M4 6h16v12H4zM4 10h16",
};

/* ------------------------------------------------------------ text plumbing */

const visibleRuns = (block: Block, budget: number): { runs: Run[]; used: number } => {
  if (block.kind === "code") {
    const all = block.lines.join("\n");
    const take = Math.max(0, Math.min(all.length, budget));
    return { runs: [{ t: all.slice(0, take), code: true }], used: take };
  }
  const out: Run[] = [];
  let used = 0;
  for (const r of block.runs) {
    const left = budget - used;
    if (left <= 0) break;
    const take = Math.min(r.t.length, left);
    out.push({ ...r, t: r.t.slice(0, take) });
    used += take;
    if (take < r.t.length) break;
  }
  return { runs: out, used };
};

const RunSpan: React.FC<{ run: Run; highlight: number; focusing: boolean; fs: number }> = ({
  run,
  highlight,
  focusing,
  fs,
}) => {
  const live = run.s !== undefined && run.s === highlight;
  const dim = focusing && !live;
  if (run.code) {
    return (
      <code
        style={{
          fontFamily: MONO,
          fontSize: fs * 0.88,
          background: dim ? "rgba(255,255,255,0.03)" : "rgba(255,255,255,0.07)",
          color: dim ? "rgba(235,234,231,0.3)" : "#E4C9A8",
          padding: `${fs * 0.1}px ${fs * 0.26}px`,
          borderRadius: 4,
        }}
      >
        {run.t}
      </code>
    );
  }
  return (
    <span
      style={{
        background: live ? "rgba(221,201,139,0.22)" : "transparent",
        boxShadow: live ? "0 0 0 4px rgba(221,201,139,0.22)" : undefined,
        borderRadius: 3,
        color: live ? "#FBF4E0" : dim ? "rgba(235,234,231,0.26)" : W.text,
      }}
    >
      {run.t}
    </span>
  );
};

/* ------------------------------------------------------------------- window */

export type ChatWindowProps = {
  width: number;
  height: number;
  reveal?: number;
  scrollY?: number;
  highlight?: number;
  caret?: boolean;
  style?: React.CSSProperties;
};

export const ChatWindow: React.FC<ChatWindowProps> = ({
  width,
  height,
  reveal = 1,
  scrollY = 0,
  highlight = -1,
  caret = false,
  style,
}) => {
  const budget = Math.round(reveal * ANSWER_CHARS);
  const focusing = highlight >= 0;
  const railW = Math.round(width * 0.163);
  // The reference capture is 2103px wide with ~17.5px body text. Holding that
  // ratio exactly gives unreadable type at 1080p, so the window runs at 1.6x
  // the app's default text scale — believable (people do bump it) and legible
  // once the camera pushes in on the paragraph being read.
  const fs = Math.round(17.5 * (width / 2103) * 1.6);
  const pad = Math.round(width * 0.038);

  let spent = 0;
  const body = ANSWER.map((block, i) => {
    const left = budget - spent;
    if (left <= 0) return null;
    const { runs, used } = visibleRuns(block, left);
    spent += used;
    if (!runs.length) return null;
    const last = spent >= budget;

    if (block.kind === "code") {
      return (
        <pre
          key={i}
          style={{
            margin: `${fs * 0.85}px 0`,
            padding: `${fs * 0.7}px ${fs * 0.85}px`,
            background: "rgba(255,255,255,0.035)",
            border: `1px solid ${W.hair}`,
            borderRadius: 7,
            fontFamily: MONO,
            fontSize: fs * 0.8,
            lineHeight: 1.6,
            color: focusing ? "rgba(235,234,231,0.24)" : "rgba(235,234,231,0.78)",
            whiteSpace: "pre-wrap",
          }}
        >
          {runs[0].t}
          {caret && last ? <Caret /> : null}
        </pre>
      );
    }

    const isH = block.kind === "h";
    const isLi = block.kind === "li";
    return (
      <div
        key={i}
        style={{
          margin: isH ? `${fs * 1.3}px 0 ${fs * 0.55}px` : `0 0 ${fs * 0.82}px`,
          paddingLeft: isLi ? fs * 1.3 : 0,
          position: "relative",
          fontSize: isH ? fs * 1.03 : fs,
          fontWeight: isH ? 600 : 400,
          lineHeight: 1.66,
          color: W.text,
          letterSpacing: 0.05,
        }}
      >
        {isLi ? (
          <span
            style={{
              position: "absolute",
              left: fs * 0.42,
              top: fs * 0.76,
              width: fs * 0.22,
              height: fs * 0.22,
              borderRadius: "50%",
              background: focusing ? "rgba(235,234,231,0.2)" : "rgba(235,234,231,0.5)",
            }}
          />
        ) : null}
        {runs.map((r, j) => (
          <RunSpan key={j} run={r} highlight={highlight} focusing={focusing} fs={fs} />
        ))}
        {caret && last ? <Caret /> : null}
      </div>
    );
  });

  const navRow = (icon: string, label: string, pill?: string) => (
    <div
      key={label}
      style={{
        display: "flex",
        alignItems: "center",
        gap: fs * 0.52,
        padding: `${fs * 0.26}px ${fs * 0.4}px`,
        borderRadius: 6,
        fontSize: fs * 0.8,
        color: W.text,
      }}
    >
      <Ico d={icon} s={fs * 0.92} />
      <span>{label}</span>
      {pill ? (
        <span
          style={{
            fontSize: fs * 0.58,
            color: W.muted,
            background: W.chip,
            borderRadius: 4,
            padding: `${fs * 0.08}px ${fs * 0.26}px`,
          }}
        >
          {pill}
        </span>
      ) : null}
    </div>
  );

  return (
    <div
      style={{
        width,
        height,
        borderRadius: Math.round(width * 0.0095),
        overflow: "hidden",
        display: "flex",
        background: W.main,
        border: `1px solid rgba(255,255,255,0.09)`,
        boxShadow: `0 ${height * 0.055}px ${height * 0.14}px rgba(0,0,0,0.66)`,
        ...style,
      }}
    >
      {/* ------------------------------------------------------------ rail */}
      <div
        style={{
          width: railW,
          flex: "0 0 auto",
          background: W.rail,
          borderRight: `1px solid ${W.hair}`,
          display: "flex",
          flexDirection: "column",
          overflow: "hidden",
          padding: `${fs * 0.6}px ${fs * 0.5}px ${fs * 0.4}px`,
          fontFamily: UI,
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: fs * 0.42 }}>
          {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
            <div key={c} style={{ width: fs * 0.52, height: fs * 0.52, borderRadius: "50%", background: c }} />
          ))}
          <div style={{ width: fs * 0.35 }} />
          <Ico d={P.panel} s={fs * 0.84} />
          <Ico d={P.back} s={fs * 0.84} />
          <Ico d={P.fwd} s={fs * 0.84} />
          <div style={{ flex: 1 }} />
          <Ico d={P.chat} s={fs * 0.84} />
          <span style={{ background: W.hover, borderRadius: 5, padding: fs * 0.12, display: "flex" }}>
            <Ico d={P.code} s={fs * 0.84} c={W.text} />
          </span>
        </div>

        <div
          style={{
            marginTop: fs * 0.72,
            display: "flex",
            alignItems: "center",
            gap: fs * 0.45,
            background: "rgba(255,255,255,0.045)",
            border: `1px solid ${W.hair}`,
            borderRadius: 7,
            padding: `${fs * 0.3}px ${fs * 0.45}px`,
            fontSize: fs * 0.78,
            color: W.muted,
          }}
        >
          <Ico d={P.search} s={fs * 0.82} />
          Search
        </div>

        <div style={{ marginTop: fs * 0.5 }}>
          {navRow(P.plus, "New")}
          {navRow(P.folder, "Projects", "Beta")}
          {navRow(P.artifact, "Artifacts")}
          {navRow(P.clock, "Routines")}
          {navRow(P.sliders, "Customize")}
        </div>

        {["Routines", "Pinned"].map((t) => (
          <div
            key={t}
            style={{
              marginTop: fs * 0.7,
              display: "flex",
              alignItems: "center",
              gap: fs * 0.2,
              padding: `0 ${fs * 0.4}px`,
              fontSize: fs * 0.75,
              color: W.muted,
            }}
          >
            {t}
            <Ico d={P.chevR} s={fs * 0.66} />
          </div>
        ))}

        <div
          style={{
            marginTop: fs * 0.85,
            display: "flex",
            alignItems: "center",
            padding: `0 ${fs * 0.4}px`,
            fontSize: fs * 0.75,
            color: W.muted,
          }}
        >
          Projects
          <div style={{ flex: 1 }} />
          <Ico d={P.plus} s={fs * 0.7} />
        </div>

        <div style={{ marginTop: fs * 0.35, flex: "1 1 0", minHeight: 0, overflow: "hidden" }}>
          {SIDEBAR.map((group) => (
            <div key={group.label} style={{ marginTop: fs * 0.6 }}>
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  padding: `0 ${fs * 0.4}px`,
                  fontSize: fs * 0.72,
                  color: W.muted,
                }}
              >
                {group.label}
                <div style={{ flex: 1 }} />
                <Ico d={P.plus} s={fs * 0.66} />
              </div>
              {group.items.map((it, k) => {
                const active = group.label === "Infra" && k === 0;
                return (
                  <div
                    key={it}
                    style={{
                      marginTop: fs * 0.2,
                      display: "flex",
                      alignItems: "center",
                      gap: fs * 0.42,
                      padding: `${fs * 0.22}px ${fs * 0.4}px`,
                      borderRadius: 6,
                      background: active ? W.hover : "transparent",
                      fontSize: fs * 0.76,
                      color: active ? W.text : "rgba(235,234,231,0.72)",
                      whiteSpace: "nowrap",
                      overflow: "hidden",
                      textOverflow: "ellipsis",
                    }}
                  >
                    <span
                      style={{
                        width: fs * 0.34,
                        height: fs * 0.34,
                        borderRadius: "50%",
                        border: `1.5px solid ${W.dim}`,
                        flex: "0 0 auto",
                      }}
                    />
                    <span style={{ overflow: "hidden", textOverflow: "ellipsis" }}>{it}</span>
                  </div>
                );
              })}
            </div>
          ))}
        </div>

        <div
          style={{
            flex: "0 0 auto",
            marginTop: fs * 0.45,
            borderTop: `1px solid ${W.hair}`,
            paddingTop: fs * 0.45,
            display: "flex",
            alignItems: "center",
            gap: fs * 0.42,
            fontSize: fs * 0.76,
            color: W.text,
          }}
        >
          <span
            style={{
              width: fs * 1.05,
              height: fs * 1.05,
              borderRadius: "50%",
              background: "#3b3a37",
              color: W.text,
              fontSize: fs * 0.5,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              letterSpacing: 0.4,
            }}
          >
            YP
          </span>
          You
          <span style={{ color: W.dim, fontSize: fs * 0.66 }}>· Max</span>
          <Ico d={P.chevD} s={fs * 0.62} />
        </div>
      </div>

      {/* ------------------------------------------------------------ main */}
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <div
          style={{
            height: Math.round(height * 0.055),
            flex: "0 0 auto",
            display: "flex",
            alignItems: "center",
            gap: fs * 0.42,
            padding: `0 ${fs * 0.8}px`,
            fontFamily: UI,
            fontSize: fs * 0.8,
            color: W.text,
          }}
        >
          <Ico d={P.win} s={fs * 0.86} />
          Session storage tradeoffs
          <Ico d={P.chevD} s={fs * 0.62} />
          <span
            style={{
              fontSize: fs * 0.66,
              color: W.muted,
              background: W.chip,
              borderRadius: 5,
              padding: `${fs * 0.1}px ${fs * 0.34}px`,
            }}
          >
            Infra
          </span>
          <div style={{ flex: 1 }} />
          <Ico d={P.term} s={fs * 0.84} />
          <Ico d={P.panel} s={fs * 0.84} />
          <Ico d={P.globe} s={fs * 0.84} />
          <Ico d={P.dots} s={fs * 0.84} />
        </div>

        <div style={{ flex: 1, overflow: "hidden", position: "relative" }}>
          <div
            style={{
              position: "absolute",
              inset: 0,
              padding: `${fs * 0.7}px ${pad}px 0`,
              transform: `translateY(${-scrollY}px)`,
              fontFamily: UI,
            }}
          >
            <div style={{ maxWidth: "64%", margin: "0 auto" }}>
            <div style={{ display: "flex", justifyContent: "flex-end", marginBottom: fs * 1.5 }}>
              <div
                style={{
                  background: "rgba(255,255,255,0.055)",
                  borderRadius: 11,
                  padding: `${fs * 0.5}px ${fs * 0.8}px`,
                  fontSize: fs * 0.97,
                  color: focusing ? "rgba(235,234,231,0.35)" : W.text,
                  maxWidth: "70%",
                }}
              >
                {PROMPT}
              </div>
            </div>
            {body}
            </div>
          </div>
          <div
            style={{
              position: "absolute",
              left: 0,
              right: 0,
              bottom: 0,
              height: height * 0.11,
              background: `linear-gradient(to top, ${W.main}, rgba(21,21,21,0))`,
            }}
          />
        </div>

        <div style={{ flex: "0 0 auto", padding: `0 ${pad}px ${fs * 0.8}px`, fontFamily: UI }}>
          <div style={{ maxWidth: "64%", margin: "0 auto" }}>
          <div
            style={{
              border: `1px solid rgba(255,255,255,0.1)`,
              background: W.composer,
              borderRadius: 11,
              padding: `${fs * 0.55}px ${fs * 0.7}px`,
              display: "flex",
              alignItems: "center",
              fontSize: fs * 0.87,
              color: W.muted,
            }}
          >
            Reply to Claude…
            <div style={{ flex: 1 }} />
            <Ico d={P.ret} s={fs * 0.8} />
          </div>
          <div
            style={{
              marginTop: fs * 0.42,
              display: "flex",
              alignItems: "center",
              gap: fs * 0.55,
              fontSize: fs * 0.74,
              color: W.muted,
            }}
          >
            <Ico d={P.plus} s={fs * 0.8} />
            <Ico d={P.mic} s={fs * 0.8} />
            <Ico d={P.chevD} s={fs * 0.62} />
            <span>Auto</span>
            <div style={{ flex: 1 }} />
            <span style={{ color: "rgba(235,234,231,0.78)" }}>Opus 5</span>
            <span>Extra</span>
          </div>
          </div>
        </div>
      </div>
    </div>
  );
};

const Caret: React.FC = () => (
  <span
    style={{
      display: "inline-block",
      width: "0.46em",
      height: "1em",
      marginLeft: "0.1em",
      verticalAlign: "-0.14em",
      background: C.paper,
      borderRadius: 1,
    }}
  />
);
