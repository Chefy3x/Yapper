# Mouth reader v3: audio in, a cartoon mouth track out, built on how real lip-sync works
# (Rhubarb's shape rules and timing, JALI's per-syllable jaw, uLipSync's dB window).
#
#  1. Analyse at 10 ms hops (25 ms windows): level in dB, low-band (voiced) level, hiss ratio,
#     voicing, and formants F1/F2 on voiced frames.
#  2. Find syllables: peaks of the low-band level. Each syllable gets ONE vowel shape, picked from
#     its formants normalised to this speaker (Lobanov z-scores), and ONE jaw size from how loud it
#     is against the clip (JALI: quiet 0.15, average 0.45, loud 0.8).
#  3. Between syllables the mouth goes to a consonant shape: lips shut (A) for a deep dip, clenched
#     teeth (B) for hiss or a shallow dip. Pauses: <120 ms hold, <350 ms relax, longer rest.
#  4. Timing: every shape holds >= 80 ms, the mouth leads the sound by 80 ms, it pops open in one
#     frame and closes over ~3 frames.
# Usage: python3 reader_offline.py in.wav out.json [fps] [--natural]
# Offline: it looks at the whole clip (and ahead of each frame), so it renders demo clips; the app
# needs a reader that only uses past audio.
import json, math, sys, wave
import numpy as np

path, out = sys.argv[1], sys.argv[2]
FPS = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
with wave.open(path) as w:
    sr = w.getframerate(); raw = w.readframes(w.getnframes()); ch = w.getnchannels(); sw = w.getsampwidth()
dt = {2: np.int16, 4: np.int32}[sw]
x = np.frombuffer(raw, dtype=dt).astype(np.float64) / float(np.iinfo(dt).max)
if ch > 1: x = x.reshape(-1, ch).mean(axis=1)
dur = len(x) / sr

HOP, WIN = int(0.010 * sr), int(0.025 * sr)
hamm = np.hamming(WIN)
freqs = np.fft.rfftfreq(WIN, 1 / sr)
def db_of(e): return 10 * math.log10(e + 1e-12)

def formants(seg):
    y = np.append(seg[0], seg[1:] - 0.97 * seg[:-1]) * hamm
    order = 2 + sr // 1000
    r = np.correlate(y, y, "full")[len(y) - 1: len(y) + order]
    if r[0] <= 1e-10: return None
    a = np.zeros(order + 1); a[0] = 1.0; e = r[0]
    for i in range(1, order + 1):
        k = -(r[i] + np.dot(a[1:i], r[i - 1:0:-1])) / e
        a[1:i + 1] = a[1:i + 1] + k * np.append(a[i - 1:0:-1], 1.0)
        e *= (1 - k * k)
        if e <= 0: return None
    c = sorted(f for f, bw in ((math.atan2(z.imag, z.real) * sr / (2 * math.pi), -sr / math.pi * math.log(abs(z)))
                               for z in np.roots(a) if z.imag > 0) if 200 < f < 3600 and bw < 400)
    return (c[0], c[1]) if len(c) >= 2 else None

def voicing(seg, want_f0=False):
    s = seg - seg.mean()
    ac = np.correlate(s, s, "full")[len(s) - 1:]
    if ac[0] <= 0: return (0.0, 0.0) if want_f0 else 0.0
    lo, hi = int(sr / 400), int(sr / 75)
    k = int(np.argmax(ac[lo:hi])) + lo
    v = float(ac[k] / ac[0])
    return (v, sr / k) if want_f0 else v

# ---- 1. analysis frames ----
F = []
for start in range(0, len(x) - WIN, HOP):
    seg = x[start:start + WIN]
    mag2 = np.abs(np.fft.rfft(seg * hamm)) ** 2
    tot = mag2.sum(); low = mag2[(freqs >= 150) & (freqs < 1000)].sum(); hi = mag2[freqs >= 4000].sum()
    F.append(dict(t=(start + WIN / 2) / sr, db=db_of(tot / WIN), low=db_of(low / WIN),
                  hiss=hi / (tot + 1e-12), voiced=voicing(seg), f0=voicing(seg, True)[1], fm=None, seg=start))
N = len(F)
dbs = np.array([f["db"] for f in F]); low = np.array([f["low"] for f in F])
floor = float(np.percentile(dbs, 10))
speech = dbs > floor + 12
# hangover so short gaps inside words stay speech
for i in range(N):
    if speech[i]: continue
    j0, j1 = max(0, i - 6), min(N, i + 7)
    if speech[j0:i].any() and speech[i:j1].any(): speech[i] = True

for i, f in enumerate(F):
    if speech[i] and f["voiced"] > 0.45:
        f["fm"] = formants(x[f["seg"]:f["seg"] + WIN])

# speaker-normalised formants (Lobanov): the vowel map adapts to this voice
fm = np.array([f["fm"] for f in F if f["fm"]])
m1, s1 = fm[:, 0].mean(), fm[:, 0].std() + 1e-9
m2, s2 = fm[:, 1].mean(), fm[:, 1].std() + 1e-9

# ---- 2. syllable nuclei: peaks of smoothed low-band level ----
import os
SYL_FLOOR = float(os.environ.get("SYL_FLOOR", "12")); SYL_PROM = float(os.environ.get("SYL_PROM", "1.5"))
SYL_GAP = int(os.environ.get("SYL_GAP", "8")); SYL_VOICED = float(os.environ.get("SYL_VOICED", "0.3"))
k = np.ones(3) / 3
lows = np.convolve(low, k, mode="same")
nuclei = []
for i in range(2, N - 2):
    if not speech[i] or F[i]["voiced"] < SYL_VOICED: continue
    if lows[i] < lows[i - 1] or lows[i] < lows[i + 1]: continue
    if lows[i] < floor + SYL_FLOOR: continue
    # prominence: at least 3 dB above the lowest point to the nearest neighbouring nucleus side
    lft = lows[max(0, i - 15):i].min() if i > 0 else lows[i]
    rgt = lows[i + 1:min(N, i + 16)].min()
    if lows[i] - max(lft, rgt) < SYL_PROM and nuclei: continue
    if nuclei and i - nuclei[-1] < SYL_GAP:          # syllables at least 100 ms apart: keep the louder
        if lows[i] > lows[nuclei[-1]]: nuclei[-1] = i
        continue
    nuclei.append(i)

loud = np.array([lows[i] for i in nuclei])
lm, ls = loud.mean(), loud.std() + 1e-9

def vowel_shape(i):
    pts = [F[j]["fm"] for j in range(max(0, i - 3), min(N, i + 4)) if F[j]["fm"]]
    if not pts: return "C"
    f1 = np.median([p[0] for p in pts]); f2 = np.median([p[1] for p in pts])
    z1, z2 = (f1 - m1) / s1, (f2 - m2) / s2
    if z1 > 0.55: return "D"                    # ah: jaw wide
    if z2 < -0.75 and z1 < 0.0: return "F"      # oo / ow / w: pucker
    if z2 < -0.25: return "E"                   # oh / aw / er: round
    if z2 > 0.6 and z1 < 0.1: return "W"        # ee / ih: wide lips
    return "C"                                  # eh / ae / uh: open, relaxed

def jaw_size(i):
    z = (lows[i] - lm) / ls
    return 0.15 if z < -0.8 else (0.8 if z > 0.8 else 0.45 + 0.35 * z / 0.8 * (1 if z > 0 else 0.86))

# ---- 3. syllables -> two channels (Osipa): jaw (open/close) and width (wide/narrow) ----
# Jaw: one key per syllable. Stressed syllables (loud x long) get the full open, at most about four
# a second; the rest open less. Width: from the vowel, held for the syllable. Consonants between
# syllables: jaw nearly shut, teeth together (Rhubarb B); audio can't tell m from t reliably, so the
# lips only seal in real pauses.
syl = []
for n, i in enumerate(nuclei):
    a = (nuclei[n - 1] + i) // 2 if n > 0 else max(0, i - 15)
    b = (i + nuclei[n + 1]) // 2 if n + 1 < len(nuclei) else min(N - 1, i + 15)
    s_, e_ = i, i
    while s_ > a and lows[s_ - 1] > lows[i] - 9 and speech[s_ - 1]: s_ -= 1
    while e_ < b and lows[e_ + 1] > lows[i] - 9 and speech[e_ + 1]: e_ += 1
    syl.append(dict(peak=i, s=s_, e=e_, v=vowel_shape(i), loud=lows[i], dur=(e_ - s_ + 1)))
L_ = np.array([q["loud"] for q in syl]); D_ = np.array([q["dur"] for q in syl], float)
stress = (L_ - L_.mean()) / (L_.std() + 1e-9) + 0.5 * (D_ - D_.mean()) / (D_.std() + 1e-9)
order = np.argsort(-stress)
accent = set(); taken = []
for idx in order:
    if stress[idx] < 0.2: break
    t_ = syl[idx]["peak"] * 0.010
    if all(abs(t_ - u) >= 0.25 for u in taken): accent.add(int(idx)); taken.append(t_)
WIDTH = {"W": 0.9, "C": 0.3, "D": 0.0, "E": -0.55, "F": -0.95}
for n, q in enumerate(syl):
    z = stress[n]
    q["jaw"] = (0.85 + 0.15 * min(1, max(0, z - 0.2))) if n in accent else float(np.clip(0.38 + 0.12 * z, 0.22, 0.55))
    q["width"] = WIDTH.get(q["v"], 0.0)
    if q["v"] == "D": q["jaw"] = min(1.0, q["jaw"] * 1.12)        # ah is the jaw's widest vowel
    if q["v"] == "W": q["jaw"] *= 0.7                              # ee keeps the teeth closer
    q["jaw"] = min(1.0, q["jaw"] * float(os.environ.get("JGAIN", "1.4")))

# ---- 4. per-frame targets, with lead, pop-open and cushion-back ----
NATURAL = "--natural" in sys.argv
LEAD, HEAD_LEAD = (0.11 if NATURAL else 0.083), 0.15   # mouth leads (more when a spring lags it), head 4.5 frames
frames = int(dur * FPS)
def at(t): return min(N - 1, max(0, int(round((t - F[0]["t"]) / 0.010))))
J_t, W_t, T_t, kind = [0.0] * frames, [0.0] * frames, [0.0] * frames, ["X"] * frames
owner = [-1] * N
for n, q in enumerate(syl):
    for j in range(q["s"], q["e"] + 1): owner[j] = n
for fi in range(frames):
    j = at(fi / FPS + LEAD)
    n = owner[j]
    if n >= 0:
        q = syl[n]
        # cushion back after the accent: full at the onset, easing to 70% by the end of the vowel
        u = (j - q["s"]) / max(1, q["e"] - q["s"])
        J_t[fi] = q["jaw"] * (1 - 0.3 * u); W_t[fi] = q["width"]; kind[fi] = q["v"]
    elif speech[j]:
        J_t[fi] = 0.06; W_t[fi] = 0.15 if F[j]["hiss"] > 0.18 else 0.0
        T_t[fi] = 0.85 if F[j]["hiss"] > 0.18 else 0.6; kind[fi] = "B"
    else:
        kind[fi] = "pause"

# pauses: <120 ms hold the previous shape, <350 ms relaxed half-open, longer close to rest
fi = 0
while fi < frames:
    if kind[fi] != "pause": fi += 1; continue
    k = fi
    while k < frames and kind[k] == "pause": k += 1
    ms = (k - fi) / FPS * 1000
    for q in range(fi, k):
        if fi > 0 and ms < 120: J_t[q], W_t[q], T_t[q] = J_t[fi - 1] * 0.8, W_t[fi - 1], T_t[fi - 1]
        elif fi > 0 and k < frames and ms < 350: J_t[q], W_t[q], T_t[q] = 0.18, 0.0, 0.2
        else: J_t[q], W_t[q], T_t[q] = 0.0, 0.0, 0.0
    fi = k

# minimum hold: a consonant gap shorter than 2 frames keeps the jaw where it was (no flicker)
for fi in range(1, frames - 1):
    if kind[fi] == "B" and kind[fi - 1] not in ("B", "pause", "X") and kind[fi + 1] not in ("B", "pause", "X"):
        J_t[fi] = 0.5 * (J_t[fi - 1] + J_t[fi + 1]) * 0.75; T_t[fi] = 0.0

if NATURAL:
    # Coarticulation: inside a voiced run the jaw keeps a floor instead of slamming shut, and quick
    # syllables (<~180 ms apart) only dip part way between them rather than doing a full cycle.
    fi = 0
    while fi < frames:
        if kind[fi] != "B": fi += 1; continue
        k = fi
        while k < frames and kind[k] == "B": k += 1
        a_, b_ = fi - 1, k
        if a_ >= 0 and b_ < frames and kind[a_] not in ("B", "pause", "X") and kind[b_] not in ("B", "pause", "X"):
            DIPK, JFLOOR = float(os.environ.get("DIPK", "0.25")), float(os.environ.get("JFLOOR", "0.06"))
            dip = DIPK * min(J_t[a_], J_t[b_]) if (k - fi) <= 3 else JFLOOR
            for q in range(fi, k): J_t[q] = max(dip, JFLOOR)
        else:
            for q in range(fi, k): J_t[q] = max(J_t[q], 0.12)
        fi = k
    # end of a phrase: fade the jaw shut over ~300 ms instead of snapping
    for fi in range(1, frames):
        if kind[fi] in ("pause", "X") and kind[fi - 1] not in ("pause", "X"):
            j0 = J_t[fi - 1]
            for q in range(fi, min(frames, fi + 9)):
                if kind[q] not in ("pause", "X"): break
                J_t[q] = max(J_t[q], j0 * (1 - (q - fi + 1) / 9))
    # blend each target with its neighbours (Gaussian, ~+-80 ms)
    def blur(a, sigma=1.3):
        r = int(3 * sigma); kk = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2); kk /= kk.sum()
        return list(np.convolve(np.pad(a, r, mode="edge"), kk, mode="valid"))
    J_t, W_t, T_t = blur(J_t, float(os.environ.get("JBLUR", "0.8"))), blur(W_t, 1.8), blur(T_t)

def spring_follow(target, f_open, f_close, z):
    """A second-order follower: speech jaw motion is a near-critically-damped system with
    bell-shaped velocity (smooth ease in and out); closes run a little faster than opens."""
    x_, v_, out_ = 0.0, 0.0, []
    h = 1.0 / FPS / 4
    for tg in target:
        w0 = 2 * math.pi * (f_open if tg > x_ else f_close)
        for _ in range(4):
            v_ += (w0 * w0 * (tg - x_) - 2 * z * w0 * v_) * h; x_ += v_ * h
        out_.append(x_)
    return out_
if NATURAL:
    JJ, WW, TT = spring_follow(J_t, 9.0, 10.5, 0.85), spring_follow(W_t, 7.0, 7.0, 0.9), spring_follow(T_t, 10.0, 10.0, 0.9)

# ---- 5. follow the targets: pop open in a frame, close over ~3, width a little softer ----
J = W = T = 0.0; track = []
for fi in range(frames):
    if NATURAL:
        jj, W, T = max(0.0, JJ[fi]), WW[fi], max(0.0, TT[fi])
        n_ = max(0.0, -W); w_ = max(0.0, W)
        track.append({"t": round(fi / FPS, 4), "kind": kind[fi], "J": round(jj, 3), "W": round(W, 3), "T": round(T, 3)})
        continue
    J += (J_t[fi] - J) * (0.9 if J_t[fi] > J else 0.55)
    W += (W_t[fi] - W) * 0.55
    T += (T_t[fi] - T) * (0.8 if T_t[fi] > T else 0.5)
    drift = 0.025 * math.sin(fi * 0.9) * min(1, J * 2)            # held shapes keep living
    jj = max(0.0, J + drift)
    n_ = max(0.0, -W); w_ = max(0.0, W)
    keys = {"open": jj * (1 - n_), "round": jj * n_ * 0.9, "pucker": n_ * (1 - jj),
            "wide": w_ * (1 - 0.45 * jj), "teeth": T * (1 - jj)}
    track.append({"t": round(fi / FPS, 4), "kind": kind[fi], "J": round(jj, 3), "W": round(W, 3), "T": round(T, 3),
                  **{k: round(min(1.0, v), 4) for k, v in keys.items()}})

# ---- 6. head: dips just before each accent, lifts on it, settles (leads the mouth) ----
head = [0.0] * frames
for n in accent:
    fa = int(round((syl[n]["s"] * 0.010 + F[0]["t"] - HEAD_LEAD) * FPS))
    for fi in range(max(0, fa - 4), min(frames, fa + 14)):
        d = fi - fa
        head[fi] += (-1.2 * math.sin(math.pi * (d + 4) / 4) if d < 0 else 2.6 * math.exp(-d / 5) * math.sin(math.pi * min(1, (d + 1) / 3) / 2))
for fi, fr in enumerate(track): fr["head"] = round(head[fi], 3)
f0s = np.array([f["f0"] if (speech[i] and f["voiced"] > 0.5) else np.nan for i, f in enumerate(F)])
ok = ~np.isnan(f0s); mu, sd = np.nanmean(f0s), np.nanstd(f0s) + 1e-9
z_ = np.where(ok, (f0s - mu) / sd, 0.0)
# hold the last voiced value through unvoiced gaps, then smooth over ~250 ms
last = 0.0
for i in range(N):
    if ok[i]: last = z_[i]
    else: z_[i] = last * 0.97; last = z_[i]
kz = np.exp(-0.5 * (np.arange(-30, 31) / 10.0) ** 2); kz /= kz.sum()
zs = np.convolve(np.pad(z_, 30, mode="edge"), kz, mode="valid")
for fi, fr in enumerate(track): fr["f0z"] = round(float(zs[at(fi / FPS)]), 3)

json.dump({"fps": FPS, "frames": track}, open(out, "w"))
print(f"{len(syl)} syllables in {dur:.2f}s, {len(accent)} accents ({len(accent)/dur:.1f}/s)")
print("vowels:", "".join(q["v"] for q in syl))
print("accents at:", sorted(round(syl[n]["peak"] * 0.01, 2) for n in accent))
Jv = np.array([f["J"] for f in track]); dv = np.diff(Jv)
print("jaw reversals/s:", round(np.sum(dv[1:] * dv[:-1] < -1e-4) / dur, 1), " median open while speaking:",
      round(float(np.median([f["J"] for f in track if f["kind"] not in ("pause", "X")])), 2))
