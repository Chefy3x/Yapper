#!/usr/bin/env python3
"""Live mouth reader: drives the Loud Mouth from the mic, one frame per 10 ms hop, using only past audio.

This is the causal twin of the offline reader (v3) the look was tuned with. Same analysis per hop
(25 ms Hamming window, low-band level, hiss ratio, voicing, LPC formants), but everything that v3 did
with the whole clip is replaced by something that runs as the audio arrives:

  - noise floor: the minimum level over the last 2 s (blocks of 250 ms), not a clip percentile
  - speaker normalisation: running formant and loudness stats, seeded from typical adult values and
    saved between sessions (SpeakerStats), not Lobanov stats over the clip
  - jaw: a continuous envelope of the level above the floor, plus an onset "pop" when the low band
    jumps, not one key per syllable
  - width: soft vowel classes (v3's decision list made smooth), hiss pulls the teeth together
  - speech gate with a 60 ms hangover, then the phrase-end fade (300 ms)
  - the same near-critical springs (J 9/10.5 Hz z0.85, W 7 Hz z0.9, T 10 Hz z0.9); no lead
  - formants come from peak-picking the LPC envelope, so the Swift port needs no polynomial roots

Yapper/Mouth/MouthReader.swift is a line-for-line port. YapperTests/MouthReaderTests.swift checks the
two agree on a synthetic vowel signal; regenerate its fixture with --fixture after changing anything here.

Usage:
  python3 -I reader_live.py in.wav out.json [--fps=30] [--stats=in.json] [--save-stats=out.json]
  python3 -I reader_live.py --fixture YapperTests/Fixtures/mouth_reader_synth.json
"""
import json, math, sys
from dataclasses import dataclass, asdict

import numpy as np

# ---- tuning (all times in 10 ms hops unless named otherwise) ----
GATE_DB = 10.0          # speech when the level is this far above the 2 s minimum
HANG = 6                # speech gate hangover, 60 ms
FADE = 30               # phrase-end fade, 300 ms
FLOOR_BLOCK, FLOOR_BLOCKS = 25, 24  # 24 blocks of 250 ms = 6 s minimum window: talk rarely goes 6 s without a dip
FLOOR_SKIP = 30         # the mic's first 300 ms are often near-silent while it opens: no floor from them
FLOOR_RISE = 3.0        # dB/s: the floor drops at once but climbs slowly, so 2 s of talking without a
                        # pause doesn't drag it up to the voice (the mouth would stop opening)
QUIET_K = 0.5           # below the speaker's average level the jaw scales half as steeply: low talk still opens
VOICED_FM = 0.45        # voicing needed to read formants
J_FLOOR = 0.1           # jaw never shuts fully inside speech (coarticulation)
J_BASE, J_SLOPE = 0.32, 0.55        # envelope: J_BASE at the speaker's average level, +J_SLOPE per std
POP_DB, POP_K, POP_TAU = 9.0, 0.30, 5.0    # onset pop: low band rising this fast in 40 ms, size, decay
LOUD_TAU = 2.0          # the level is eased over 20 ms before it drives the jaw
SHAPE_TAU = 1.0         # vowel width eases to a new vowel over ~10 ms
JM_TAU = 4.0            # the vowel's jaw multiplier (ah wider, ee narrower) eases slower, ~40 ms
FM_MEDIAN = 3           # vowel read from the median of this many recent formant readings
VW_LO, VW_HI = 0.30, 0.60   # voicing range over which the vowel width takes over from consonant width
STATS_MAX = 1500.0      # formant stats never weigh more than this many frames (keeps adapting)
LOUD_MAX = 150.0        # loudness follows mic distance and gain, so it forgets faster (~1.5 s of speech)
WIDTH = {"D": 0.0, "F": -0.95, "E": -0.55, "W": 0.9, "C": 0.3}   # v3's widths per vowel class
SOFT = 0.18             # softness of the vowel-class boundaries, in z units
W_GAIN = 1.5            # soft classes blend towards the middle; this pushes widths out to the extremes
HISS_LO, HISS_HI = 0.07, 0.20   # share of energy above 4 kHz over which a frame counts as hiss
CLOSE_LO, CLOSE_HI, CLOSE_T = 0.12, 0.30, 0.5   # jaw envelope below which teeth meet (consonant gaps)
HISS_CLOSE = 0.3        # s / sh / f: the jaw closes this much of the way, teeth together


@dataclass
class SpeakerStats:
    """Running speaker normalisation. Seeds are typical adult values; save it after a session and
    load it next time so the mouth starts already tuned to this voice and mic."""
    f1Mean: float = 520.0       # Hz, LPC F1 on voiced speech
    f1Std: float = 160.0
    f2Mean: float = 1550.0      # Hz, LPC F2
    f2Std: float = 400.0
    loudMean: float = 24.0      # dB above the noise floor, on speech
    loudStd: float = 9.0
    floorDb: float = -40.0      # noise floor the gate starts from
    weight: float = 50.0        # how many frames of evidence the values above carry

    @staticmethod
    def load(path):
        with open(path) as f: return SpeakerStats(**json.load(f))

    def save(self, path):
        with open(path, "w") as f: json.dump(asdict(self), f, indent=1)


def _update(mean, std, x, w):
    """Exponentially weighted mean and std, weight w for the new sample."""
    d = x - mean
    mean += w * d
    var = (1.0 - w) * (std * std + w * d * d)
    return mean, math.sqrt(var)


def _sig(x):
    return 1.0 / (1.0 + math.exp(-min(60.0, max(-60.0, x))))


def _smooth(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


class Spring:
    """Second-order follower, semi-implicit Euler with two 5 ms substeps per hop."""
    def __init__(self, f_up, f_down, zeta):
        self.f_up, self.f_down, self.z = f_up, f_down, zeta
        self.x = self.v = 0.0

    def step(self, target, dt):
        w0 = 2.0 * math.pi * (self.f_up if target > self.x else self.f_down)
        h = dt / 2.0
        for _ in range(2):
            self.v += (w0 * w0 * (target - self.x) - 2.0 * self.z * w0 * self.v) * h
            self.x += self.v * h
        return self.x


class LiveReader:
    def __init__(self, sample_rate=16000.0, stats=None):
        sr = self.sr = float(sample_rate)
        self.hop, self.win = int(round(0.010 * sr)), int(round(0.025 * sr))
        self.nfft = 1 << (self.win - 1).bit_length()
        self.order = 2 + int(sr) // 1000
        n = np.arange(self.win)
        self.hamm = 0.54 - 0.46 * np.cos(2.0 * math.pi * n / (self.win - 1))
        df = sr / self.nfft
        self.lo_band = (int(math.ceil(150.0 / df)), int(math.ceil(1000.0 / df)))   # [a, b) bins
        self.hi_band = int(math.ceil(4000.0 / df))
        self.lag_lo, self.lag_hi = int(sr / 400), int(sr / 75)                      # [lo, hi) lags
        self.fm_lo, self.fm_hi = int(200.0 / df), int(math.ceil(3600.0 / df))       # peak search bins
        self.stats = stats or SpeakerStats()
        self.reset()
        self.trace = None                 # set to a list to record per-hop internals (tuning only)

    def reset(self):
        """Start over for a new dictation; keeps the learned speaker stats."""
        self.buf = np.zeros(0)
        self.hops = 0
        # gate
        self.blocks = [self.stats.floorDb] * FLOOR_BLOCKS
        self.block_min, self.block_n = math.inf, 0
        self.floor = self.stats.floorDb
        self.hang, self.fade_n, self.speaking = 0, FADE, False
        # features held across hops
        self.lows = [-120.0] * 4
        self.fms = []                     # last FM_MEDIAN formant readings (F1, F2)
        self.pop = 0.0
        self.loud_s = 0.0
        self.w_vowel, self.j_mul = 0.0, 1.0       # latest vowel reading
        self.w_s, self.jm_s = 0.0, 1.0            # eased towards it every hop
        self.last = (0.0, 0.0, 0.0)       # last speaking targets, faded at phrase end
        self.sj, self.sw, self.st = Spring(9.0, 10.5, 0.85), Spring(7.0, 7.0, 0.9), Spring(10.0, 10.0, 0.9)

    # ---------------- analysis ----------------
    def spectrum(self, seg):
        X = np.fft.rfft(seg * self.hamm, self.nfft)
        m2 = X.real * X.real + X.imag * X.imag
        tot = float(m2.sum())
        low = float(m2[self.lo_band[0]:self.lo_band[1]].sum())
        hi = float(m2[self.hi_band:].sum())
        db = 10.0 * math.log10(tot / self.win + 1e-12)
        low_db = 10.0 * math.log10(low / self.win + 1e-12)
        return db, low_db, hi / (tot + 1e-12)

    def voicing(self, seg):
        s = seg - seg.mean()
        n = len(s)
        ac0 = float(np.dot(s, s))
        if ac0 <= 0.0: return 0.0
        best = max(float(np.dot(s[:n - k], s[k:])) for k in range(self.lag_lo, self.lag_hi))
        return best / ac0

    def formants(self, seg):
        y = np.empty_like(seg)
        y[0] = seg[0]
        y[1:] = seg[1:] - 0.97 * seg[:-1]
        y *= self.hamm
        n, p = len(y), self.order
        r = np.array([float(np.dot(y[:n - k], y[k:])) for k in range(p + 1)])
        if r[0] <= 1e-10: return None
        # Levinson-Durbin
        a = np.zeros(p + 1); a[0] = 1.0; e = r[0]
        for i in range(1, p + 1):
            acc = r[i]
            for j in range(1, i): acc += a[j] * r[i - j]
            k = -acc / e
            prev = a.copy()
            for j in range(1, i): a[j] = prev[j] + k * prev[i - j]
            a[i] = k
            e *= (1.0 - k * k)
            if e <= 0.0: return None
        # envelope 1/|A|^2 in dB, peak-picked
        A = np.fft.rfft(a, self.nfft)
        env = -10.0 * np.log10(A.real * A.real + A.imag * A.imag + 1e-20)
        df = self.sr / self.nfft
        out = []
        for k in range(max(1, self.fm_lo), min(len(env) - 1, self.fm_hi + 1)):
            if not (env[k] > env[k - 1] and env[k] >= env[k + 1]): continue
            den = env[k - 1] - 2.0 * env[k] + env[k + 1]
            d = 0.5 * (env[k - 1] - env[k + 1]) / den if den < 0.0 else 0.0
            f = (k + d) * df
            if not (200.0 < f < 3600.0): continue
            bw = self._bandwidth(env, k) * df
            if bw < 400.0: out.append(float(f))
            if len(out) == 2: break
        return (out[0], out[1]) if len(out) == 2 else None

    @staticmethod
    def _bandwidth(env, k):
        """-3 dB width of the envelope peak at bin k, in bins. A side that turns upward again before
        dropping 3 dB doesn't count; with neither side resolved the peak is too broad to be a formant."""
        top = env[k] - 3.0
        sides = []
        for step in (-1, 1):
            j = k
            while 0 < j < len(env) - 1:
                nj = j + step
                if env[nj] <= top:
                    sides.append(abs(j - k) + (env[j] - top) / (env[j] - env[nj]))
                    break
                if env[nj] > env[j]: break
                j = nj
        if not sides: return math.inf
        return sides[0] + sides[1] if len(sides) == 2 else 2.0 * sides[0]

    # ---------------- per hop ----------------
    def hop_frame(self, seg):
        st = self.stats
        dt = self.hop / self.sr
        db, low_db, hiss = self.spectrum(seg)
        voiced = self.voicing(seg)

        # noise floor: minimum over the last 2 s; digital silence doesn't count
        if db > -90.0 and self.hops >= FLOOR_SKIP: self.block_min = min(self.block_min, db)
        self.block_n += 1
        floor = min(min(self.blocks), self.block_min)
        if self.block_n == FLOOR_BLOCK:
            self.blocks = self.blocks[1:] + [self.block_min if self.block_min < math.inf else self.blocks[-1]]
            self.block_min, self.block_n = math.inf, 0
        floor = max(floor, -85.0)
        floor = self.floor = min(floor, self.floor + FLOOR_RISE * dt)
        above = db > floor + GATE_DB
        if above: self.hang = HANG
        elif self.hang > 0: self.hang -= 1
        speaking = above or self.hang > 0

        loud = db - floor
        self.loud_s += (loud - self.loud_s) * (1.0 - math.exp(-1.0 / LOUD_TAU))
        rise = low_db - min(self.lows)
        self.lows = self.lows[1:] + [low_db]

        # running stats (only from real speech)
        w = 1.0 / min(st.weight + 1.0, STATS_MAX)
        if above:
            st.loudMean, st.loudStd = _update(st.loudMean, st.loudStd, loud, 1.0 / min(st.weight + 1.0, LOUD_MAX))
            st.weight = min(st.weight + 1.0, STATS_MAX)
        fm = self.formants(seg) if (speaking and voiced > VOICED_FM) else None
        if fm is not None:
            st.f1Mean, st.f1Std = _update(st.f1Mean, st.f1Std, fm[0], w)
            st.f2Mean, st.f2Std = _update(st.f2Mean, st.f2Std, fm[1], w)
            self.fms = (self.fms + [fm])[-FM_MEDIAN:]
        if speaking: st.floorDb = floor

        if speaking:
            self.fade_n = 0
            # jaw: a continuous envelope of the level against this speaker's running average
            u = (self.loud_s - st.loudMean) / max(st.loudStd, 1.0)
            if u < 0: u *= QUIET_K
            env = J_FLOOR + (1.0 - J_FLOOR) * min(1.0, max(0.0, J_BASE + J_SLOPE * u))
            # onset pop: a fast rise in the low band kicks the jaw open, then it cushions back
            if rise > POP_DB and voiced > 0.3:
                self.pop = max(self.pop, POP_K * min(1.0, (rise - POP_DB) / 8.0 + 0.5))
            # vowel shape from the median of the last few formant readings
            if fm is not None and len(self.fms) >= 2:
                f1 = float(np.median([q[0] for q in self.fms])); f2 = float(np.median([q[1] for q in self.fms]))
                z1 = (f1 - st.f1Mean) / max(st.f1Std, 30.0); z2 = (f2 - st.f2Mean) / max(st.f2Std, 60.0)
                self.w_vowel, self.j_mul = self.vowel(z1, z2)
            a = 1.0 - math.exp(-1.0 / SHAPE_TAU)
            self.w_s += (W_GAIN * self.w_vowel - self.w_s) * a
            self.jm_s += (self.j_mul - self.jm_s) * (1.0 - math.exp(-1.0 / JM_TAU))
            hissy = _smooth(HISS_LO, HISS_HI, hiss)
            vw = _smooth(VW_LO, VW_HI, voiced) * (1.0 - hissy)
            jt = min(1.2, (env + self.pop) * self.jm_s) * (1.0 - HISS_CLOSE * hissy)
            wt = vw * self.w_s + (1.0 - vw) * 0.15 * hissy
            closure = 1.0 - _smooth(CLOSE_LO, CLOSE_HI, env)
            tt = max(0.85 * hissy, CLOSE_T * closure) * (1.0 - vw * (1.0 - closure))
            self.last = (jt, wt, tt)
        else:
            # phrase end: fade the jaw shut over 300 ms, width and teeth relax with it
            self.fade_n = min(FADE, self.fade_n + 1)
            k = 1.0 - self.fade_n / FADE
            jt, wt, tt = self.last[0] * k, self.last[1] * k, 0.0
            if self.fade_n == FADE: self.fms = []
        self.pop *= math.exp(-1.0 / POP_TAU)
        self.speaking = speaking
        if self.trace is not None:
            self.trace.append(dict(db=db, low=low_db, floor=floor, loud=loud, hiss=hiss, voiced=voiced, fm=fm,
                                   jt=jt, wt=wt, tt=tt, wv=self.w_s, sp=speaking,
                                   above=above, pop=self.pop, jm=self.jm_s, lm=st.loudMean, ls=st.loudStd))

        J = min(1.2, max(0.0, self.sj.step(jt, dt)))
        W = min(1.0, max(-1.0, self.sw.step(wt, dt)))
        T = min(1.0, max(0.0, self.st.step(tt, dt)))
        self.hops += 1
        return {"t": round(((self.hops - 1) * self.hop + self.win) / self.sr, 4),
                "J": J, "W": W, "T": T, "speaking": speaking}

    @staticmethod
    def vowel(z1, z2):
        """v3's vowel decision list, made soft: returns (width, jaw multiplier)."""
        s = SOFT
        pD = _sig((z1 - 0.55) / s)                          # ah: jaw wide
        rem = 1.0 - pD
        c = _sig((-0.75 - z2) / s) * _sig((0.0 - z1) / s)   # oo / ow / w: pucker
        pF = rem * c; rem *= 1.0 - c
        c = _sig((-0.25 - z2) / s)                          # oh / aw / er: round
        pE = rem * c; rem *= 1.0 - c
        c = _sig((z2 - 0.6) / s) * _sig((0.1 - z1) / s)     # ee / ih: wide lips
        pW = rem * c; pC = rem * (1.0 - c)                  # eh / ae / uh: open, relaxed
        width = pD * WIDTH["D"] + pF * WIDTH["F"] + pE * WIDTH["E"] + pW * WIDTH["W"] + pC * WIDTH["C"]
        return width, 1.0 + 0.12 * pD - 0.3 * pW

    def feed(self, samples):
        """Feed any number of samples; returns one frame per completed 10 ms hop."""
        self.buf = np.concatenate([self.buf, np.asarray(samples, dtype=np.float64)])
        out, i = [], 0
        while len(self.buf) - i >= self.win:
            out.append(self.hop_frame(self.buf[i:i + self.win]))
            i += self.hop
        self.buf = self.buf[i:]
        return out


# ---------------- synthetic test signal (mirrored in MouthReaderTests.swift) ----------------
SYNTH = [("sil", 0.30), ("a", 0.40), ("s", 0.16), ("i", 0.40), ("sil", 0.30), ("u", 0.40), ("s", 0.16),
         ("a", 0.36), ("sil", 0.40), ("i", 0.36), ("u", 0.40), ("sil", 0.30)]
VOWELS = {"a": (730.0, 1090.0, 2440.0), "i": (270.0, 2290.0, 3010.0), "u": (300.0, 870.0, 2240.0)}


def synth(sr=16000):
    """Formant-synthesised a/i/u vowels and s noise. Pure double arithmetic and an integer LCG, so the
    Swift test builds the same samples."""
    out = []
    seed = 12345
    ph = 0.0
    f0 = 120.0
    for name, dur in SYNTH:
        n = int(round(dur * sr))
        ramp = int(0.015 * sr)
        if name in VOWELS:
            res = []
            for f, bw in zip(VOWELS[name], (80.0, 100.0, 120.0)):
                r = math.exp(-math.pi * bw / sr)
                a1, a2 = 2.0 * r * math.cos(2.0 * math.pi * f / sr), -r * r
                res.append([1.0 - a1 - a2, a1, a2, 0.0, 0.0])
        for i in range(n):
            if name == "sil":
                out.append(0.0); continue
            g = min(1.0, i / ramp, (n - 1 - i) / ramp)
            if name in VOWELS:
                ph += f0 / sr
                x = 0.0
                if ph >= 1.0: ph -= 1.0; x = 1.0
                for q in res:
                    y = q[0] * x + q[1] * q[3] + q[2] * q[4]
                    q[4] = q[3]; q[3] = y; x = y
                out.append(0.5 * g * x)
            else:
                seed = (seed * 1103515245 + 12345) % 2147483648
                nz = seed / 1073741824.0 - 1.0
                out.append(0.03 * g * nz)
    # a quiet constant hiss under everything, so the floor is not digital silence
    for i in range(len(out)):
        seed = (seed * 1103515245 + 12345) % 2147483648
        out[i] += 0.0005 * (seed / 1073741824.0 - 1.0)
    return out


def write_fixture(path):
    x = np.array(synth(), dtype=np.float32).astype(np.float64)     # Swift feeds Float
    rd = LiveReader()
    frames = []
    for i in range(0, len(x), 250): frames += rd.feed(x[i:i + 250])  # odd chunking on purpose
    fx = {"note": "Expected LiveReader output for the synthetic a/i/u/s signal; regenerate with "
                  "python3 -I tools/mouth/reader_live.py --fixture <this file>",
          "samples": len(x), "sampleSum": round(float(x.sum()), 6), "sampleAbsSum": round(float(np.abs(x).sum()), 4),
          "segments": [[n, d] for n, d in SYNTH],
          "frames": [[f["t"], round(f["J"], 5), round(f["W"], 5), round(f["T"], 5), int(f["speaking"])] for f in frames]}
    with open(path, "w") as f:
        json.dump(fx, f, separators=(",", ":"))
    return frames


# ---------------- CLI ----------------
def read_wav(path):
    import wave
    with wave.open(path) as w:
        sr, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    dt = {2: np.int16, 4: np.int32}[sw]
    x = np.frombuffer(raw, dtype=dt).astype(np.float64) / float(np.iinfo(dt).max)
    if ch > 1: x = x.reshape(-1, ch).mean(axis=1)
    return x.astype(np.float32).astype(np.float64), sr


def run(x, sr, stats=None, chunk=256):
    rd = LiveReader(sr, stats)
    frames = []
    for i in range(0, len(x), chunk): frames += rd.feed(x[i:i + chunk])
    return frames, rd


def to_track(frames, dur, fps=30.0):
    """Resample hop frames to a video track: at time t show the newest frame whose window has ended.
    Adds a render-only head nod (lift when the jaw opens past its recent average); not part of the
    reader's output, the app's renderer can derive the same from J."""
    ts = np.array([f["t"] for f in frames])
    track, head, hv, slow = [], 0.0, 0.0, 0.0
    for fi in range(int(dur * fps)):
        t = fi / fps
        k = int(np.searchsorted(ts, t, side="right")) - 1
        f = frames[k] if k >= 0 else {"J": 0.0, "W": 0.0, "T": 0.0, "speaking": False}
        slow += (f["J"] - slow) * (1.0 - math.exp(-1.0 / (0.35 * fps)))
        tgt = 3.0 * max(0.0, f["J"] - slow - 0.1)
        w0 = 2 * math.pi * 3.0
        for _ in range(4):
            hv += (w0 * w0 * (tgt - head) - 2 * 0.7 * w0 * hv) / fps / 4; head += hv / fps / 4
        track.append({"t": round(t, 4), "kind": "live" if f["speaking"] else "pause",
                      "J": round(f["J"], 3), "W": round(f["W"], 3), "T": round(f["T"], 3), "head": round(head, 3)})
    return {"fps": fps, "frames": track}


def main(argv):
    opts = {a.split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else "") for a in argv if a.startswith("--")}
    pos = [a for a in argv if not a.startswith("--")]
    if "--fixture" in opts:
        frames = write_fixture(pos[0])
        print(f"fixture: {len(frames)} frames -> {pos[0]}")
        return
    x, sr = read_wav(pos[0])
    stats = SpeakerStats.load(opts["--stats"]) if opts.get("--stats") else None
    frames, rd = run(x, sr, stats)
    json.dump(to_track(frames, len(x) / sr, float(opts.get("--fps") or 30)), open(pos[1], "w"))
    if opts.get("--save-stats"): rd.stats.save(opts["--save-stats"])
    spk = sum(f["speaking"] for f in frames) / 100.0
    print(f"{len(frames)} hops, speaking {spk:.1f}s; stats {asdict(rd.stats)}")


if __name__ == "__main__":
    main(sys.argv[1:])
