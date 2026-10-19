import fs from "fs";

const SR = 44100, DUR = 30.0, N = Math.round(SR * DUR);
const L = new Float32Array(N), R = new Float32Array(N);

const BPM = 80, BEAT = 60 / BPM, BAR = BEAT * 4;          // 0.75s beat, 3.0s bar
const hz = (m) => 440 * Math.pow(2, (m - 69) / 12);
const rnd = (() => { let s = 12345; return () => (s = (s * 1664525 + 1013904223) >>> 0) / 4294967296; })();

function add(buf, i, v) { if (i >= 0 && i < N) buf[i] += v; }
function stereo(i, v, pan = 0) { add(L, i, v * (1 - Math.max(0, pan))); add(R, i, v * (1 + Math.min(0, pan))); }

// ---- Rhodes-ish tine: sine fundamental + bell-ish partial, fast attack, long decay, tremolo
function rhodes(tStart, midi, dur, amp, pan = 0) {
  const f = hz(midi), i0 = Math.round(tStart * SR), n = Math.round(dur * SR);
  const det = 1 + (rnd() - 0.5) * 0.0016;                  // slight per-note detune
  for (let k = 0; k < n; k++) {
    const t = k / SR;
    const env = Math.min(1, t / 0.006) * Math.exp(-t * 1.9);
    const bell = Math.exp(-t * 7.5);
    const ph = 2 * Math.PI * f * det * t;
    let v = Math.sin(ph) + 0.30 * bell * Math.sin(ph * 4.02) + 0.12 * Math.sin(ph * 2.01);
    v *= env * amp * (1 + 0.05 * Math.sin(2 * Math.PI * 4.7 * t));   // tremolo
    stereo(i0 + k, v, pan);
  }
}

// ---- Bass: soft triangle-ish with quick decay
function bass(tStart, midi, dur, amp) {
  const f = hz(midi), i0 = Math.round(tStart * SR), n = Math.round(dur * SR);
  for (let k = 0; k < n; k++) {
    const t = k / SR;
    const env = Math.min(1, t / 0.012) * Math.exp(-t * 2.2);
    const ph = 2 * Math.PI * f * t;
    const v = (Math.sin(ph) + 0.22 * Math.sin(ph * 2) + 0.07 * Math.sin(ph * 3)) * env * amp;
    stereo(i0 + k, v, 0);
  }
}

function kick(tStart, amp) {
  const i0 = Math.round(tStart * SR), n = Math.round(0.34 * SR);
  for (let k = 0; k < n; k++) {
    const t = k / SR;
    const f = 118 * Math.exp(-t * 26) + 44;                // pitch sweep
    const env = Math.exp(-t * 9.5);
    stereo(i0 + k, Math.sin(2 * Math.PI * f * t) * env * amp, 0);
  }
}
function snare(tStart, amp) {
  const i0 = Math.round(tStart * SR), n = Math.round(0.20 * SR);
  let lp = 0;
  for (let k = 0; k < n; k++) {
    const t = k / SR;
    const env = Math.exp(-t * 19);
    const nz = rnd() * 2 - 1;
    lp += (nz - lp) * 0.45;                                 // dull the noise
    const body = Math.sin(2 * Math.PI * 182 * t) * Math.exp(-t * 26) * 0.5;
    stereo(i0 + k, (lp * 0.9 + body) * env * amp, 0);
  }
}
function hat(tStart, amp, open = false) {
  const i0 = Math.round(tStart * SR), n = Math.round((open ? 0.16 : 0.045) * SR);
  let hp = 0, prev = 0;
  for (let k = 0; k < n; k++) {
    const t = k / SR;
    const env = Math.exp(-t * (open ? 16 : 55));
    const nz = rnd() * 2 - 1;
    hp = 0.85 * (hp + nz - prev); prev = nz;                // one-pole highpass
    stereo(i0 + k, hp * env * amp, (rnd() - 0.5) * 0.3);
  }
}

// ---- Arrangement: 10 bars (30s). 4-bar harmonic loop in D minor.
const CHORDS = [
  { notes: [50, 53, 57, 60], root: 38 },   // Dm7
  { notes: [46, 50, 53, 60], root: 34 },   // Bb6/9
  { notes: [43, 46, 50, 53], root: 31 },   // Gm7
  { notes: [45, 52, 55, 62], root: 33 },   // A7sus
];

const BARS = Math.ceil(DUR / BAR);
for (let b = 0; b < BARS; b++) {
  const t0 = b * BAR;
  if (t0 >= DUR) break;
  const ch = CHORDS[b % 4];
  // chord voicing, lightly rolled
  const chordAmp = b === 0 ? 0.20 : 0.155;
  ch.notes.forEach((m, j) => rhodes(t0 + j * 0.018, m, BAR * 1.05, chordAmp, (j - 1.5) * 0.18));
  // a second stab on the "and of 3" for movement, once the track is going
  if (b >= 2) ch.notes.forEach((m, j) => rhodes(t0 + BEAT * 2.5 + j * 0.014, m, BAR * 0.6, chordAmp * 0.55, (j - 1.5) * 0.18));

  if (b >= 1) { bass(t0, ch.root, BEAT * 1.6, 0.30); bass(t0 + BEAT * 2.5, ch.root + 12, BEAT * 0.9, 0.17); }

  // drums from bar 2 (~6s); filtered drop on bar 8 (21-24s) drops the kit
  const drumsOn = b >= 2 && b !== 7;
  if (drumsOn) {
    const step = BEAT / 4, swing = step * 0.12;
    const kickSteps = [0, 6, 10], snareSteps = [4, 12];
    kickSteps.forEach((s) => kick(t0 + s * step + (s % 2 ? swing : 0), 0.62));
    snareSteps.forEach((s) => snare(t0 + s * step, 0.34));
    for (let s = 0; s < 16; s += 2) hat(t0 + s * step + (s % 4 === 2 ? swing * 0.5 : 0), s % 4 === 0 ? 0.13 : 0.085, s === 14);
  }
}

// ---- Tape colour: wow/flutter (fractional-delay read), hiss, saturation, warm lowpass
function tapeWow(buf) {
  const out = new Float32Array(N);
  for (let i = 0; i < N; i++) {
    const t = i / SR;
    const wow = 0.0016 * Math.sin(2 * Math.PI * 0.55 * t) + 0.0006 * Math.sin(2 * Math.PI * 6.3 * t + 1.1);
    const rp = i - wow * SR * 12;
    const i0 = Math.floor(rp), fr = rp - i0;
    const a = i0 >= 0 && i0 < N ? buf[i0] : 0, bq = i0 + 1 >= 0 && i0 + 1 < N ? buf[i0 + 1] : 0;
    out[i] = a + (bq - a) * fr;
  }
  return out;
}
function finish(buf, seedHiss) {
  let x = tapeWow(buf);
  let lp = 0, lp2 = 0;
  const out = new Float32Array(N);
  for (let i = 0; i < N; i++) {
    let v = x[i] + (rnd() * 2 - 1) * 0.0022;               // tape hiss
    v = Math.tanh(v * 1.35) * 0.78;                        // soft saturation
    lp += (v - lp) * 0.34; lp2 += (lp - lp2) * 0.34;        // 2-pole lowpass ≈ warm/dull
    out[i] = lp2;
  }
  return out;
}
let outL = finish(L), outR = finish(R);

// ---- Macro shape: intro swell, drop dip at bar 8, tail fade
for (let i = 0; i < N; i++) {
  const t = i / SR;
  let g = 1;
  g *= Math.min(1, t / 1.6);                                // fade in
  if (t > DUR - 2.2) g *= Math.max(0, (DUR - t) / 2.2);      // fade out
  if (t > 21.0 && t < 24.0) g *= 0.62;                       // the drop
  outL[i] *= g; outR[i] *= g;
}

// normalise to about -16 dBFS peak so it sits under the voice
let peak = 0;
for (let i = 0; i < N; i++) peak = Math.max(peak, Math.abs(outL[i]), Math.abs(outR[i]));
const target = Math.pow(10, -9 / 20);
const gain = peak > 0 ? target / peak : 1;

const buf = Buffer.alloc(44 + N * 4);
buf.write("RIFF", 0); buf.writeUInt32LE(36 + N * 4, 4); buf.write("WAVE", 8);
buf.write("fmt ", 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22);
buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34);
buf.write("data", 36); buf.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) {
  const a = Math.max(-1, Math.min(1, outL[i] * gain)), b2 = Math.max(-1, Math.min(1, outR[i] * gain));
  buf.writeInt16LE(Math.round(a * 32767), 44 + i * 4);
  buf.writeInt16LE(Math.round(b2 * 32767), 44 + i * 4 + 2);
}
fs.writeFileSync(process.argv[2] || "bed.wav", buf);
console.log("wrote", DUR, "s  peakGain=", gain.toFixed(3));
