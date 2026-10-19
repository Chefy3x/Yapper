/**
 * Frame map for the "real flow" promo.
 *
 * Every number under VO comes from the actual ElevenLabs River render in
 * public/audio/read.mp3, measured with ffmpeg silencedetect — so the on-screen
 * sentence highlight tracks the voice instead of guessing at it.
 */

export const FPS = 30;
export const TOTAL = 890; // 29.67s — the music bed is 30s

const s = (sec: number) => Math.round(sec * FPS);

/** Scene boundaries (start frame, inclusive). */
export const SC = {
  deck: 0, //     cold open on the object itself
  wall: 87, //    the reply that nobody is going to read
  key: 162, //    the Right ⌥ tap
  dock: 216, //   deck slides into the corner
  read: 270, //   Yapper reads it (VO starts exactly here)
  stabs: 691, //  what else it does
  end: 781, //    tape-label end card
} as const;

export const LEN = {
  deck: SC.wall - SC.deck,
  wall: SC.key - SC.wall,
  key: SC.dock - SC.key,
  dock: SC.read - SC.dock,
  read: SC.stabs - SC.read,
  stabs: SC.end - SC.stabs,
  end: TOTAL - SC.end,
} as const;

/** Voice-over placement. */
export const VO_START = SC.read;
export const VO_LEN = s(13.096);
export const TAG_START = 800;
export const TAG_LEN = s(2.462);

/**
 * Sentence windows inside read.mp3, in seconds, from silencedetect:
 *   gaps at 3.711–4.247, 7.153–7.653, 9.526–10.107, tail from 12.708.
 */
export const SENTENCES: { from: number; to: number }[] = [
  { from: s(0.0), to: s(3.711) },
  { from: s(4.247), to: s(7.153) },
  { from: s(7.653), to: s(9.526) },
  { from: s(10.107), to: s(12.708) },
].map((x) => ({ from: x.from + VO_START, to: x.to + VO_START }));

/** Which sentence is being spoken at an absolute frame, or -1 between them. */
export const spokenAt = (frame: number): number =>
  SENTENCES.findIndex((x) => frame >= x.from && frame < x.to);

/** How far through the whole read we are, 0..1. */
export const readProgress = (frame: number): number =>
  Math.min(1, Math.max(0, (frame - VO_START) / VO_LEN));

/** The read sub-beats, cut on sentence boundaries. */
export const READ_A = SC.read; //  docked + push in, sentence 1
export const READ_B = 397; //      screen falls away, sentence 2
export const READ_C = 500; //      deck hero, sentences 3 + 4

/** Feature stabs, one per 30 frames. */
export const STAB = [SC.stabs, SC.stabs + 30, SC.stabs + 60] as const;

/** mm:ss timecode for the deck counter, counting the read. */
export const timecode = (frame: number, startFrame: number): string => {
  const t = Math.max(0, (frame - startFrame) / FPS);
  const m = Math.floor(t / 60);
  const sec = Math.floor(t % 60);
  return `${m}:${String(sec).padStart(2, "0")}`;
};
