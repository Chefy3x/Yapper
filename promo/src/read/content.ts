/**
 * The on-screen answer. Runs carrying `s` are the four sentences that the
 * ElevenLabs render actually speaks, so the highlight and the voice agree.
 * Everything else is there to make the wall feel like a real reply.
 */

export type Run = { t: string; s?: number; dim?: boolean; code?: boolean };
export type Block =
  | { kind: "p"; runs: Run[] }
  | { kind: "h"; runs: Run[] }
  | { kind: "li"; runs: Run[] }
  | { kind: "code"; lines: string[] };

export const PROMPT = "redis or postgres for session state?";

export const ANSWER: Block[] = [
  {
    kind: "p",
    runs: [{ t: "Short answer: it depends on what breaks if the process dies." }],
  },
  {
    kind: "p",
    runs: [
      { t: "Redis keeps everything in memory, so reads come back in microseconds.", s: 0 },
      { t: " A restart without persistence configured loses the lot, so treat it as a cache and never as the record." },
    ],
  },
  {
    kind: "p",
    runs: [
      { t: "Postgres writes to disk first, so it survives anything.", s: 1 },
      { t: " You pay a few milliseconds a query for that, plus connection overhead if you aren't pooling." },
    ],
  },
  { kind: "h", runs: [{ t: "Rule of thumb" }] },
  {
    kind: "p",
    runs: [
      { t: "For a session cache, use Redis.", s: 2 },
      { t: " " },
      { t: "For anything you'd be upset to lose, use Postgres.", s: 3 },
    ],
  },
  { kind: "li", runs: [{ t: "Redis", code: true }, { t: " — sub-millisecond reads, TTL eviction built in, no schema to migrate" }] },
  { kind: "li", runs: [{ t: "Postgres", code: true }, { t: " — durable by default, transactional, one fewer service to run" }] },
  { kind: "li", runs: [{ t: "Both", code: true }, { t: " — Redis in front, Postgres behind, write through on session end" }] },
  { kind: "code", lines: ["SET sess:{id} {payload} EX 1800", "-- and the durable copy", "INSERT INTO sessions (id, payload, seen_at)"] },
  {
    kind: "p",
    runs: [
      { t: "Under about ten thousand concurrent sessions, honestly just use Postgres with a partial index on the expiry column — you will not notice the difference, and you get to delete a whole service from the diagram." },
    ],
  },
  {
    kind: "p",
    runs: [
      { t: "The moment you do need Redis, the shape of the change is small: the same read path, a different client, and a background job that flushes anything still warm back into the table before it expires." },
    ],
  },
];

/** Total characters, for the streaming reveal in the opening shot. */
export const ANSWER_CHARS = ANSWER.reduce((n, b) => {
  if (b.kind === "code") return n + b.lines.join("\n").length;
  return n + b.runs.reduce((m, r) => m + r.t.length, 0);
}, 0);

export const WORD_COUNT = ANSWER.reduce((n, b) => {
  const text = b.kind === "code" ? b.lines.join(" ") : b.runs.map((r) => r.t).join(" ");
  return n + text.trim().split(/\s+/).length;
}, 0);

/** Sidebar groups — invented project names, never the real ones on this machine. */
export const SIDEBAR: { label: string; items: string[] }[] = [
  { label: "Infra", items: ["Session storage tradeoffs", "Index strategy review", "Why is the p99 spiking"] },
  { label: "Docs", items: ["Migration plan draft", "Runbook rewrite"] },
  { label: "Personal", items: ["Weekend reading list"] },
];
