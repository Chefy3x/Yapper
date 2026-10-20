# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "scipy", "soundfile", "torch"]
# ///
"""Viseme reader: a small causal net that reads mouth SHAPES from mic audio, one per 10 ms hop.

The live reader (reader_live.py) already knows how open the mouth is (J), how wide or round (W) and
whether the teeth meet (T). This adds what it can't hear from loudness and formants: lips sealed for
m/b/p, the lower lip tucked for f/v, rounded for oo/w, spread for ee, and so on. The syllable jaw
keeps control of how open; this net only picks the shape.

Features match the reader: 16 kHz mono, 25 ms Hamming window, 10 ms hop, 512-point FFT, 40 log-mel
bands, then a running per-band mean (3 s) is taken off so mic gain and EQ drop out. The net is a
stack of 1-D convolutions that hears 350 ms of the past and LOOKAHEAD hops (40 ms) of the future, so
its answer for a hop comes 40 ms after the reader's, inside MouthTimeline's 45 ms playout.

Yapper/Mouth/MouthVisemes.swift is a line-for-line port of `Features` and `Net.stream`;
YapperTests/MouthVisemesTests.swift checks the two agree on the reader's synthetic test signal.
Regenerate its fixture with `fixture` after retraining.

Training data is LibriTTS (CC BY 4.0, openslr.org/60) with the Montreal Forced Aligner phone
alignments from huggingface.co/datasets/cdminix/libritts-aligned. None of it lives in the repo: pass
the data folder with --data or YAPPER_MOUTH_DATA. Expected layout under it:
  LibriTTS/<split>/<speaker>/<chapter>/<utt>.wav      (tarballs from openslr, extracted)
  align/<split_with_underscore>/<speaker>/<utt>.TextGrid

Every run scores the same 14 held-out speakers (EVAL_SPEAKERS, from dev-clean and test-clean) and never
trains on them, so runs on more data compare.

The shipped net is distilled: a big teacher that may look further ahead (it never ships) is trained
first, then the app-sized student learns from the teacher's softened answers plus the hard labels.

Usage (from the repo root):
  uv run tools/mouth/visemes.py prep  --data DIR dev-clean test-clean train-clean-100
  uv run tools/mouth/visemes.py train --data DIR [--epochs 40] [--out DIR/runs/name]
  uv run tools/mouth/visemes.py train --data DIR --layers K:D:LA,… --ch N …   (a teacher: any size or look-ahead)
  uv run tools/mouth/visemes.py train --data DIR --teacher DIR/runs/teacher …  (a student distilled from it)
  uv run tools/mouth/visemes.py export --data DIR --run DIR/runs/name     (writes Yapper/Resources/visemes.bin)
  uv run tools/mouth/visemes.py fixture                                    (writes YapperTests/Fixtures/mouth_visemes_synth.json)
  uv run tools/mouth/visemes.py read --wav in.wav                          (prints the classes per hop)
"""
import argparse, glob, json, math, os, re, struct, sys, time
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
RESOURCE = REPO / "Yapper/Resources/visemes.bin"
FIXTURE = REPO / "YapperTests/Fixtures/mouth_visemes_synth.json"

# ---- features (mirrored in MouthVisemes.swift) ----
SR, WIN, HOP, NFFT = 16000, 400, 160, 512
N_MELS, F_MIN, F_MAX = 40, 60.0, 7600.0
LOG_EPS = 1e-6
EMA = 1.0 / 300.0        # running mean of each band: ~3 s


# ---- classes: what the rig can show ----
CLASSES = ["rest", "MBP", "FV", "OO", "OH", "EE", "AH", "teeth", "L_TH", "SH"]
PHONE_CLASS = {
    "": 0, "sil": 0, "sp": 0, "spn": 0,
    "M": 1, "B": 1, "P": 1,
    "F": 2, "V": 2,
    "UW": 3, "UH": 3, "W": 3,
    "OW": 4, "AO": 4, "OY": 4, "ER": 4, "R": 4,
    "IY": 5, "IH": 5, "EY": 5, "Y": 5,
    "AA": 6, "AE": 6, "AH": 6, "AY": 6, "AW": 6, "EH": 6,
    "S": 7, "Z": 7, "T": 7, "D": 7, "N": 7, "K": 7, "G": 7, "NG": 7,
    "TH": 8, "DH": 8, "L": 8,
    "SH": 9, "ZH": 9, "CH": 9, "JH": 9,
    # HH takes the shape of the sound it leads into (see labels())
}

# ---- the net: (kernel, dilation, lookahead) per conv layer; all but the first are residual ----
LAYERS = [(5, 1, 2), (3, 1, 1), (3, 2, 1), (3, 4, 0), (3, 8, 0)]
LOOKAHEAD = sum(l[2] for l in LAYERS)
CH = 80
# what MouthVisemes.swift and its tests accept: the shapes land inside MouthTimeline's 45 ms playout
MAX_LOOKAHEAD, MAX_WEIGHTS = 4, 150_000

# The fixed held-out speakers (all from dev-clean and test-clean): never trained on, always scored, so
# runs on more data stay comparable. They are what split_speakers(seed 1) drew for the first net.
EVAL_SPEAKERS = [121, 777, 1462, 1919, 1993, 2428, 2803, 2902, 5105, 6241, 6930, 7021, 7729, 8842]


def parse_layers(spec):
    """"5:1:2,3:1:1,…" → [(kernel, dilation, lookahead), …]"""
    return [tuple(int(v) for v in l.split(":")) for l in spec.split(",")]


def mel_bank():
    mel = lambda f: 2595.0 * math.log10(1.0 + f / 700.0)
    hz = lambda m: 700.0 * (10.0 ** (m / 2595.0) - 1.0)
    lo, hi = mel(F_MIN), mel(F_MAX)
    pts = [hz(lo + (hi - lo) * i / (N_MELS + 1)) for i in range(N_MELS + 2)]
    freqs = np.arange(NFFT // 2 + 1) * SR / NFFT
    bank = np.zeros((N_MELS, NFFT // 2 + 1))
    for i in range(N_MELS):
        a, b, c = pts[i], pts[i + 1], pts[i + 2]
        bank[i] = np.maximum(0.0, np.minimum((freqs - a) / (b - a), (c - freqs) / (c - b)))
    return bank


HAMMING = 0.54 - 0.46 * np.cos(2.0 * math.pi * np.arange(WIN) / (WIN - 1))
BANK = mel_bank()


def log_mel(x):
    """Log-mel per hop (frames, N_MELS), float64. Hop i covers samples [HOP*i, HOP*i + WIN)."""
    x = np.asarray(x, dtype=np.float64)
    n = 1 + (len(x) - WIN) // HOP if len(x) >= WIN else 0
    if n == 0: return np.zeros((0, N_MELS))
    idx = np.arange(WIN)[None, :] + HOP * np.arange(n)[:, None]
    p = np.abs(np.fft.rfft(x[idx] * HAMMING, NFFT)) ** 2
    return np.log(p @ BANK.T + LOG_EPS)


def normalise(lm, mu0, sd):
    """The running per-band mean taken off, then the training spread divided out. Streaming: the mean
    is updated with each hop before that hop is normalised."""
    out = np.empty_like(lm)
    mu = mu0.astype(np.float64).copy()
    for t in range(len(lm)):
        mu += EMA * (lm[t] - mu)
        out[t] = (lm[t] - mu) / sd
    return out


# ---- data ----

def data_dir(args):
    d = args.data or os.environ.get("YAPPER_MOUTH_DATA")
    if not d: sys.exit("pass --data or set YAPPER_MOUTH_DATA")
    return Path(d).expanduser()


def read_textgrid(path):
    """The phones tier: [(start, end, phone without stress digits)]."""
    text = Path(path).read_text()
    tier = text.split('name = "phones"')[1]
    out = []
    for m in re.finditer(r'xmin = ([\d.eE+-]+)\s*\n\s*xmax = ([\d.eE+-]+)\s*\n\s*text = "(.*)"', tier):
        out.append((float(m[1]), float(m[2]), re.sub(r"\d", "", m[3])))
    return out


def labels(phones, n, shift=0.0):
    """Class per hop, read at the hop window's centre (+ shift seconds). HH takes the next phone's class."""
    cls = []
    for i, (a, b, p) in enumerate(phones):
        if p == "HH":
            nxt = next((q for _, _, q in phones[i + 1:] if q != "HH"), "")
            p = nxt
        cls.append(PHONE_CLASS.get(p, 0))
    starts = np.array([a for a, _, _ in phones]); ends = np.array([b for _, b, _ in phones])
    t = (HOP * np.arange(n) + WIN / 2) / SR + shift
    k = np.searchsorted(starts, t, side="right") - 1
    out = np.zeros(n, dtype=np.uint8)
    ok = (k >= 0) & (t < ends[np.clip(k, 0, len(ends) - 1)])
    out[ok] = np.array(cls, dtype=np.uint8)[k[ok]]
    return out


def cmd_prep(args):
    import soundfile as sf
    from scipy.signal import resample_poly
    root = data_dir(args)
    for split in args.splits:
        wavs = sorted(glob.glob(str(root / "LibriTTS" / split / "*" / "*" / "*.wav")))
        align = root / "align" / split.replace("-", "_")
        mels, phones_out, spk, utt, missing = [], [], [], [], 0
        t0 = time.time()
        for w in wavs:
            name = Path(w).stem
            speaker = name.split("_")[0]
            tg = align / speaker / (name + ".TextGrid")
            if not tg.exists(): missing += 1; continue
            x, sr = sf.read(w, dtype="float64")
            if x.ndim > 1: x = x[:, 0]
            if sr != SR:
                g = math.gcd(SR, sr); x = resample_poly(x, SR // g, sr // g)
            lm = log_mel(x)
            if len(lm) < 20: continue
            mels.append(lm.astype(np.float16))
            phones_out.append(json.dumps(read_textgrid(tg)))
            spk.append(int(speaker)); utt.append(name)
        lens = np.array([len(m) for m in mels])
        out = root / "cache" / f"{split}.npz"
        out.parent.mkdir(parents=True, exist_ok=True)
        np.savez(out, mel=np.concatenate(mels), lens=lens, speaker=np.array(spk), utt=np.array(utt),
                 phones=np.array(phones_out))
        print(f"{split}: {len(mels)} utterances, {lens.sum() / 360000:.2f} h, {len(set(spk))} speakers, "
              f"{missing} without alignment, {time.time() - t0:.0f} s → {out}")


def load(root, splits, shift):
    mel, lab, spk = [], [], []
    for s in splits:
        z = dict(np.load(root / "cache" / f"{s}.npz"))      # read each array once
        off = np.concatenate([[0], np.cumsum(z["lens"])])
        for i, n in enumerate(z["lens"]):
            mel.append(z["mel"][off[i]:off[i + 1]])
            lab.append(labels(json.loads(str(z["phones"][i])), n, shift))
            spk.append(int(z["speaker"][i]))
    return mel, lab, np.array(spk)


def split_speakers(spk, n_eval, seed=1):
    ids = sorted(set(spk.tolist()))
    rng = np.random.default_rng(seed)
    return set(rng.choice(ids, n_eval, replace=False).tolist())


def streams(mel, lab, spk, keep):
    """Each speaker's utterances end to end, one long stream per speaker (the pauses between are real)."""
    by = {}
    for m, l, s in zip(mel, lab, spk):
        if s in keep: by.setdefault(s, []).append((m, l))
    return [(np.concatenate([m for m, _ in v]), np.concatenate([l for _, l in v])) for v in by.values()]


# ---- the net ----

def torch_net(layers=LAYERS, ch=CH, nc=len(CLASSES), drop=0.1):
    import torch, torch.nn as nn, torch.nn.functional as F

    class Net(nn.Module):
        def __init__(self):
            super().__init__()
            self.convs = nn.ModuleList()
            self.bns = nn.ModuleList()
            cin = N_MELS
            for k, d, _ in layers:
                self.convs.append(nn.Conv1d(cin, ch, k, dilation=d))
                self.bns.append(nn.BatchNorm1d(ch))
                cin = ch
            self.out = nn.Conv1d(ch, nc, 1)
            self.drop = nn.Dropout(drop)

        def forward(self, x):             # x: (B, N_MELS, T) → logits (B, nc, T); out[t] is hop t's shape
            for i, ((k, d, la), conv, bn) in enumerate(zip(layers, self.convs, self.bns)):
                h = F.pad(x, ((k - 1) * d - la, la))
                h = self.drop(F.relu(bn(conv(h))))
                x = h if i == 0 else x + h
            return self.out(x)

    return Net()


def ema_norm_torch(lm, mu0, sd):
    """`normalise` for a batch (B, T, N_MELS), in closed form so it runs on the GPU."""
    import torch
    B, T, _ = lm.shape
    r = 1.0 - EMA
    t = torch.arange(T, device=lm.device, dtype=torch.float32)
    # mu_t = r^(t+1) mu0 + EMA * sum_k<=t r^(t-k) x_k, done in chunks so r^-k stays in range
    out = torch.empty_like(lm)
    mu = mu0.expand(B, -1).clone()
    C = 128
    for s in range(0, T, C):
        x = lm[:, s:s + C]
        n = x.shape[1]
        tt = t[:n]
        acc = torch.cumsum(x * (r ** -(tt + 1))[None, :, None], 1) * EMA
        m = (r ** (tt + 1))[None, :, None] * (mu[:, None, :] + acc)
        out[:, s:s + n] = (x - m) / sd
        mu = m[:, -1]
    return out


def noise_floors(seconds=20, seed=7):
    """Mel power per hop of steady mic noise at 0 dBFS RMS, one (hops, N_MELS) array per colour: white,
    pink, brown, a high hiss and 50/60 Hz hum. Made as waveforms, so each band's hop-to-hop wobble is
    what a real floor's is (a smooth floor with jitter on top reads like a fricative)."""
    rng = np.random.default_rng(seed)
    n = SR * seconds
    f = np.fft.rfftfreq(n, 1.0 / SR)
    t = np.arange(n) / SR
    shaped = lambda g: np.fft.irfft(np.fft.rfft(rng.standard_normal(n)) * g, n)
    x = {"white": rng.standard_normal(n), "pink": shaped(1 / np.sqrt(np.maximum(f, 20))),
         "brown": shaped(1 / np.maximum(f, 20)), "hiss": shaped(np.clip(f / 4000, 0.03, 2.0))}
    for f0 in (50, 60):
        hum = sum(np.sin(2 * np.pi * f0 * k * t + rng.uniform(0, 2 * np.pi)) / k for k in range(1, 9))
        x[f"hum{f0}"] = hum / np.sqrt(np.mean(hum ** 2)) + 0.1 * rng.standard_normal(n)
    return {k: (np.exp(log_mel(v / np.sqrt(np.mean(v ** 2)))) - LOG_EPS).astype(np.float32) for k, v in x.items()}


def floor_under(n, rng, floors, kind=None, db=None):
    """n hops of one floor (a random colour, sometimes two, at -70 to -35 dBFS), mel power."""
    kinds = sorted(floors)
    out = np.zeros((n, N_MELS), np.float32)
    for k in ([kind] if kind else [kinds[i] for i in rng.choice(len(kinds), 1 + (rng.random() < 0.3), replace=False)]):
        F = floors[k]
        idx = (rng.integers(0, len(F)) + np.arange(n)) % len(F)
        out += F[idx] * 10 ** ((db if db is not None else rng.uniform(-70, -35)) / 10)
    return out


def augment(lm, rng, noise_mel, eq_db=12.0, floors=None):
    """Mic conditions in the mel-power domain: gain, a spectral tilt, a mic's EQ, a bit of room, a noise
    floor. The tilt and EQ also start the running mean off-colour, as a new mic does. With `floors`, the
    floor is a steady one (noise_floors) at its own level, and the old jittery white noise at a level
    relative to the speech comes in only sometimes."""
    import torch
    B, T, M = lm.shape
    dev = lm.device
    gain = torch.tensor(rng.uniform(-18, 12, (B, 1, 1)) * math.log(10) / 10, device=dev, dtype=torch.float32)
    tilt = torch.tensor(rng.uniform(-1, 1, (B, 1, 1)), device=dev, dtype=torch.float32) * torch.linspace(-1, 1, M, device=dev)[None, None]
    # a few smooth boosts and cuts across the bands
    m = np.arange(M)[None, None]
    c, wd, a = rng.uniform(0, M, (B, 3, 1)), rng.uniform(2, 8, (B, 3, 1)), rng.uniform(-eq_db, eq_db, (B, 3, 1))
    eq = torch.tensor((a * np.exp(-0.5 * ((m - c) / wd) ** 2)).sum(1)[:, None] * math.log(10) / 10, device=dev, dtype=torch.float32)
    p = torch.exp(lm + gain + 0.8 * tilt + eq)
    # late reverb on the power envelope: an exponential tail, sometimes
    rt = rng.uniform(0.0, 0.35, B) * (rng.uniform(0, 1, B) < 0.5)
    if rt.max() > 0:
        L = 40
        k = torch.tensor(np.stack([np.exp(-6.9 * np.arange(1, L + 1) * 0.01 / max(r, 1e-3)) * (0.3 if r > 0 else 0) for r in rt]),
                         device=dev, dtype=torch.float32)            # (B, L)
        pp = torch.nn.functional.pad(p, (0, 0, L, 0))
        tail = sum(k[:, j - 1, None, None] * pp[:, L - j:L - j + T] for j in range(1, L + 1))
        p = p + tail
    snr = rng.uniform(5, 45, (B, 1, 1))
    level = torch.exp(lm).mean((1, 2), keepdim=True) * torch.tensor(10 ** (-snr / 10), device=dev, dtype=torch.float32)
    if floors is not None:
        level = level * torch.tensor(rng.random((B, 1, 1)) < 0.3, device=dev, dtype=torch.float32)
        p = p + torch.tensor(np.stack([floor_under(T, rng, floors) for _ in range(B)]), device=dev)
    p = p + level * torch.exp(gain) * noise_mel[None, None] * torch.tensor(rng.uniform(0.5, 1.5, (B, T, 1)), device=dev, dtype=torch.float32)
    return torch.log(p + LOG_EPS)


def crop(m, l, z, T, rng, pause_p):
    """A training crop of T hops; with probability pause_p, one or two stretches of nothing (0.2-3 s, at
    most 4 s in all, labelled rest) are spliced in, for the floor to fill. Returns log-mel, labels, teacher logits (or
    None) and a mask that is 0 on the spliced hops (the teacher never heard them)."""
    gaps = rng.integers(20, 301, rng.integers(1, 3)) if rng.random() < pause_p else np.zeros(0, int)
    if gaps.sum() > min(400, T // 2): gaps = gaps[:1]
    need = T - int(gaps.sum())
    a = rng.integers(0, max(1, len(l) - need))
    x, y, k = m[a:a + need].astype(np.float32), l[a:a + need], np.ones(need, np.float32)
    zt = None if z is None else z[a:a + need].astype(np.float32)
    for g, at in zip(gaps, np.sort(rng.integers(0, need, len(gaps)))[::-1]):      # last first: earlier places hold
        x = np.concatenate([x[:at], np.full((g, N_MELS), math.log(1e-9), np.float32), x[at:]])
        y = np.concatenate([y[:at], np.zeros(g, y.dtype), y[at:]])
        k = np.concatenate([k[:at], np.zeros(g, np.float32), k[at:]])
        if zt is not None: zt = np.concatenate([zt[:at], np.zeros((g, zt.shape[1]), np.float32), zt[at:]])
    return x, y, zt, k


def held_speakers(args, spk):
    if args.held: return set(args.held)
    return split_speakers(spk, args.eval_speakers)


def teacher_logits(run, streams_, shift, held, splits, dev):
    """The teacher's logits over each (clean) training stream, moved so row t is the teacher's answer for
    the label the student is taught at hop t (the teacher may read its labels at another shift). Kept
    next to the teacher, so the next student skips this."""
    import torch
    ck = torch.load(Path(run) / "best.pt", weights_only=False)
    if set(ck["held"]) != held: sys.exit(f"{run} held out other speakers: it may have heard the ones scored here")
    cache = Path(run) / f"logits_{'+'.join(splits)}_{shift:g}.npy"
    lens = [len(l) for _, l in streams_]
    if cache.exists() and cache.stat().st_mtime > (Path(run) / "best.pt").stat().st_mtime:
        z = np.load(cache)
        if len(z) == sum(lens): return np.split(z, np.cumsum(lens)[:-1])
    net = torch_net(ck["layers"], ck["ch"]).to(dev); net.load_state_dict(ck["net"]); net.eval()
    off = int(round((shift - ck["shift"]) * SR / HOP))
    mu0, sd = torch.tensor(ck["mu0"], device=dev), torch.tensor(ck["sd"], device=dev, dtype=torch.float32)
    out = []
    with torch.no_grad():
        for m, _ in streams_:
            x = ema_norm_torch(torch.tensor(m.astype(np.float32), device=dev)[None], mu0, sd)
            z = net(x.transpose(1, 2))[0].T.cpu().numpy()
            if off > 0: z = np.concatenate([z[off:], np.repeat(z[-1:], off, 0)])
            if off < 0: z = np.concatenate([np.repeat(z[:1], -off, 0), z[:off]])
            out.append(z.astype(np.float16))
    np.save(cache, np.concatenate(out))
    return out


def cmd_train(args):
    import torch, torch.nn.functional as F
    root = data_dir(args)
    if args.threads: torch.set_num_threads(args.threads)
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    layers = parse_layers(args.layers) if args.layers else LAYERS
    ch = args.ch or CH
    lookahead = sum(l[2] for l in layers)
    mel, lab, spk = load(root, args.splits, args.shift)
    held = held_speakers(args, spk)
    missing = held - set(spk.tolist())
    if missing: sys.exit(f"held-out speakers not in the loaded splits: {sorted(missing)}")
    train_s = streams(mel, lab, spk, set(spk.tolist()) - held)
    eval_s = streams(mel, lab, spk, held)
    del mel, lab
    alll = np.concatenate([l for _, l in train_s])
    mu0 = np.zeros(N_MELS)                       # where the running mean settles
    for m, _ in train_s: mu0 += m.astype(np.float64).sum(0)
    mu0 /= len(alll)
    # the spread once the running mean comes off
    sd = np.concatenate([normalise(m[:6000].astype(np.float64), mu0, np.ones(N_MELS)) for m, _ in train_s[:8]]).std(0) + 1e-3
    counts = np.bincount(alll, minlength=len(CLASSES))
    print(f"train {len(train_s)} speakers {len(alll) / 360000:.2f} h, eval {len(eval_s)} speakers "
          f"{sum(len(l) for _, l in eval_s) / 360000:.2f} h; classes {dict(zip(CLASSES, (counts / counts.sum()).round(3)))}")
    # flat-spectrum (white) noise through the bank, normalised to unit mean
    noise_mel = torch.tensor(BANK.sum(1) / BANK.sum(1).mean(), device=dev, dtype=torch.float32)
    eval_floors = noise_floors(seed=8)                  # other noise than training's
    floors = noise_floors() if args.floors else None
    net = torch_net(layers, ch, drop=args.dropout).to(dev)
    nparams = sum(p.numel() for p in net.parameters() if p.requires_grad)
    ships = lookahead <= MAX_LOOKAHEAD and nparams - 2 * ch * len(layers) < MAX_WEIGHTS     # BatchNorm folds away
    print(f"net: {nparams} weights, {ch} channels, lookahead {lookahead} hops, receptive field "
          f"{1 + sum((k - 1) * d for k, d, _ in layers)} hops", flush=True)
    teach = None
    if args.teacher:
        t0 = time.time()
        teach = teacher_logits(args.teacher, train_s, args.shift, held, args.splits, dev)
        acc = np.mean(np.concatenate([z.argmax(1) for z in teach]) == alll)
        print(f"teacher {args.teacher}: logits for {len(alll)} hops in {time.time() - t0:.0f} s, "
              f"agrees with the labels on {acc:.3f}; KD weight {args.kd}, temperature {args.temp}", flush=True)
    opt = torch.optim.AdamW(net.parameters(), lr=args.lr, weight_decay=args.wd)
    T = args.crop
    keep = [i for i, st in enumerate(train_s) if len(st[1]) > T]
    train_s = [train_s[i] for i in keep]
    if teach: teach = [teach[i] for i in keep]
    lens = np.array([len(l) for _, l in train_s])
    steps_per_epoch = args.steps or int(len(alll) / (args.batch * T))
    total = steps_per_epoch * args.epochs
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, args.lr, total_steps=total, pct_start=0.1)
    w = torch.tensor((counts.sum() / (counts + 1)) ** args.balance, device=dev, dtype=torch.float32)
    w = w / (w * torch.tensor(counts / counts.sum(), device=dev, dtype=torch.float32)).sum()
    rng = np.random.default_rng(args.seed)
    torch.manual_seed(args.seed)
    mu0_t = torch.tensor(mu0, device=dev); sd_t = torch.tensor(sd, device=dev, dtype=torch.float32)
    out = Path(args.out or root / "runs" / time.strftime("%m%d-%H%M"))
    out.mkdir(parents=True, exist_ok=True)
    best = 0
    t0 = time.time()
    for ep in range(args.epochs):
        net.train()
        tl = 0
        for _ in range(steps_per_epoch):
            si = rng.choice(len(train_s), args.batch, p=lens / lens.sum())
            xs, ys, zs, ks = zip(*(crop(*train_s[s], teach[s] if teach else None, T, rng, args.pauses) for s in si))
            x = torch.tensor(np.stack(xs), device=dev)
            y = torch.tensor(np.stack(ys).astype(np.int64), device=dev)
            x = augment(x, rng, noise_mel, args.eq, floors)
            # the running mean starts from the training mean plus whatever the mic did to it
            x = ema_norm_torch(x, mu0_t, sd_t)
            with torch.autocast(dev.type, dtype=torch.bfloat16, enabled=args.bf16):
                logits = net(x.transpose(1, 2)).float()
            loss = F.cross_entropy(logits, y, weight=w, label_smoothing=0.05)
            if teach:
                # KL to the teacher's softened answer (the teacher heard the clean audio), each hop
                # weighted like its hard label so the rare shapes keep their pull
                zt = torch.tensor(np.stack(zs), device=dev).transpose(1, 2)
                kl = F.kl_div(F.log_softmax(logits / args.temp, 1), F.log_softmax(zt / args.temp, 1),
                              log_target=True, reduction="none").sum(1)
                k = torch.tensor(np.stack(ks), device=dev) * w[y]
                kd = (kl * k).sum() / k.sum().clamp_min(1e-6) * args.temp ** 2
                loss = args.kd * kd + (1 - args.kd) * loss
            opt.zero_grad(); loss.backward(); opt.step(); sched.step()
            tl += loss.item()
        acc, bal, cm = evaluate(net, eval_s, mu0, sd, dev)
        # the app's tests also read the synthetic vowels; a net that fails them can't ship (teachers don't)
        synth_ok = not ships or synth_check(synth_probs(net, mu0, sd, dev), quiet=True)
        print(f"epoch {ep + 1:2d}  loss {tl / steps_per_epoch:.3f}  eval acc {acc:.3f}  balanced {bal:.3f}  "
              + (f"synthetic {'ok' if synth_ok else 'FAILS'}  " if ships else "") + f"{time.time() - t0:.0f} s", flush=True)
        if ships: print("          " + pause_line(pause_eval(torch_predict(net, mu0, sd, dev), eval_s, eval_floors, (-45,))), flush=True)
        if bal > best and synth_ok:
            best = bal
            torch.save({"net": net.state_dict(), "mu0": mu0, "sd": sd, "layers": layers, "ch": ch,
                        "classes": CLASSES, "shift": args.shift, "held": sorted(held),
                        "splits": args.splits, "teacher": args.teacher and Path(args.teacher).name}, out / "best.pt")
            np.save(out / "confusion.npy", cm)
    if best:
        report(out)
        if ships:
            ck = torch.load(out / "best.pt", weights_only=False); net.load_state_dict(ck["net"])
            res = pause_eval(torch_predict(net, mu0, sd, dev), eval_s, eval_floors)
            print(pause_line(res)); print("  " + "  ".join(f"{k} {100 * r:.0f}" for k, (r, _) in res.items()))
    else: print("no epoch's net read the synthetic sounds as the app's tests want: nothing saved")


def torch_predict(net, mu0, sd, dev):
    import torch
    mu0_t, sd_t = torch.tensor(mu0, device=dev), torch.tensor(sd, device=dev, dtype=torch.float32)
    def predict(lm):
        net.eval()
        with torch.no_grad():
            x = ema_norm_torch(torch.tensor(lm, dtype=torch.float32, device=dev)[None], mu0_t, sd_t)
            return net(x.transpose(1, 2))[0].argmax(0).cpu().numpy()
    return predict


def evaluate(net, eval_s, mu0, sd, dev, clean=True):
    import torch
    net.eval()
    cm = np.zeros((len(CLASSES), len(CLASSES)), dtype=np.int64)
    with torch.no_grad():
        for m, l in eval_s:
            x = torch.tensor(m.astype(np.float32), device=dev)[None]
            x = ema_norm_torch(x, torch.tensor(mu0, device=dev), torch.tensor(sd, device=dev, dtype=torch.float32))
            p = net(x.transpose(1, 2))[0].argmax(0).cpu().numpy()
            np.add.at(cm, (l, p), 1)
    acc = np.trace(cm) / cm.sum()
    bal = np.mean(np.diag(cm) / np.maximum(1, cm.sum(1)))
    return acc, bal, cm


def with_pauses(eval_s, seed=3):
    """The held-out streams with a 0.5-3 s silence spliced into a natural pause about every 6 s: LibriTTS
    pauses are short, and in a long one the running mean sinks towards the mic's floor."""
    rng = np.random.default_rng(seed)
    out = []
    for m, l in eval_s:
        at = np.sort(rng.choice(np.flatnonzero(l == 0), max(1, len(l) // 600), replace=False))[::-1]
        for a in at:
            g = rng.integers(50, 301)
            m = np.concatenate([m[:a], np.full((g, N_MELS), math.log(1e-9), m.dtype), m[a:]])
            l = np.concatenate([l[:a], np.zeros(g, l.dtype), l[a:]])
        out.append((m, l))
    return out


def pause_eval(predict, eval_s, floors, levels=(-60, -45, -35)):
    """Each held-out stream, with long pauses (with_pauses), under each steady floor (colour x level):
    rest recall on the hops within 6 dB of the floor (the pauses, as a real mic hears them), and frame
    accuracy over everything."""
    rng = np.random.default_rng(3)
    eval_s = with_pauses(eval_s)
    res = {}
    for kind in sorted(floors):
        for db in levels:
            hit = tot = good = n = 0
            for m, l in eval_s:
                P = np.exp(m.astype(np.float32))
                fl = floor_under(len(m), rng, floors, kind, db)
                pred = predict(np.log(P + fl))
                r = ((P + fl).sum(1) <= fl.sum(1).mean() * 10 ** 0.6) & (l == 0)
                hit += int((pred[r] == 0).sum()); tot += int(r.sum()); good += int((pred == l).sum()); n += len(l)
            res[f"{kind} {db}"] = (hit / max(tot, 1), good / n)
    return res


def pause_line(res):
    rec = np.array([r for r, _ in res.values()]); acc = np.array([a for _, a in res.values()])
    worst = min(res, key=lambda k: res[k][0])
    return f"pauses: rest {100 * rec.mean():.1f}% (worst {worst} dBFS {100 * rec.min():.1f}%), accuracy under the floors {100 * acc.mean():.1f}%"


def report(run):
    cm = np.load(Path(run) / "confusion.npy")
    rec = np.diag(cm) / np.maximum(1, cm.sum(1))
    print(f"\nbest: frame accuracy {np.trace(cm) / cm.sum():.3f}, balanced {rec.mean():.3f}, "
          f"majority-class baseline {cm.sum(1).max() / cm.sum():.3f}")
    print("confusion (rows: truth, % of row; cols: predicted)")
    print("        " + " ".join(f"{c[:5]:>5}" for c in CLASSES) + "   share")
    for i, c in enumerate(CLASSES):
        row = 100 * cm[i] / max(1, cm[i].sum())
        print(f"{c:>7} " + " ".join(f"{v:5.0f}" for v in row) + f"   {100 * cm[i].sum() / cm.sum():4.1f}%")
    print("recall  " + " ".join(f"{100 * r:5.1f}" for r in rec))


# ---- export: BatchNorm folded into the convs, float32 little-endian ----

def folded(ck):
    sd = ck["net"]
    layers = []
    for i, (k, d, la) in enumerate(ck["layers"]):
        W = sd[f"convs.{i}.weight"].cpu().numpy().astype(np.float64)       # (out, in, k)
        b = sd[f"convs.{i}.bias"].cpu().numpy().astype(np.float64)
        g, beta = sd[f"bns.{i}.weight"].cpu().numpy(), sd[f"bns.{i}.bias"].cpu().numpy()
        rm, rv = sd[f"bns.{i}.running_mean"].cpu().numpy(), sd[f"bns.{i}.running_var"].cpu().numpy()
        s = g / np.sqrt(rv + 1e-5)
        layers.append(dict(k=k, d=d, la=la, W=(W * s[:, None, None]).astype(np.float32),
                           b=((b - rm) * s + beta).astype(np.float32)))
    out = dict(W=sd["out.weight"].cpu().numpy()[:, :, 0].astype(np.float32), b=sd["out.bias"].cpu().numpy().astype(np.float32))
    return layers, out


def write_bin(ck, path):
    """"MVIS", UInt32 version 1, UInt32 header length, JSON header, then float32 arrays in header order:
    mu0, sd, then per layer W (out, in, k, row-major) and b, then the output W (classes, ch) and b."""
    layers, out = folded(ck)
    header = dict(sampleRate=SR, win=WIN, hop=HOP, nfft=NFFT, mels=N_MELS, fmin=F_MIN, fmax=F_MAX, logEps=LOG_EPS,
                  ema=EMA, channels=ck["ch"], classes=ck["classes"],
                  layers=[dict(kernel=l["k"], dilation=l["d"], lookahead=l["la"]) for l in layers])
    blob = [np.asarray(ck["mu0"], np.float32), np.asarray(ck["sd"], np.float32)]
    for l in layers: blob += [l["W"], l["b"]]
    blob += [out["W"], out["b"]]
    hj = json.dumps(header, separators=(",", ":")).encode()
    hj += b" " * ((4 - len(hj) % 4) % 4)
    with open(path, "wb") as f:
        f.write(b"MVIS" + struct.pack("<II", 1, len(hj)) + hj)
        for a in blob: f.write(np.ascontiguousarray(a, dtype="<f4").tobytes())
    return sum(a.size for a in blob)


def read_bin(path):
    raw = Path(path).read_bytes()
    assert raw[:4] == b"MVIS"
    _, n = struct.unpack("<II", raw[4:12])
    h = json.loads(raw[12:12 + n])
    a = np.frombuffer(raw[12 + n:], dtype="<f4")
    o = 0
    def take(*shape):
        nonlocal o
        k = int(np.prod(shape)); v = a[o:o + k].reshape(shape); o += k; return v
    M, C, K = h["mels"], h["channels"], len(h["classes"])
    mu0, sd = take(M), take(M)
    layers, cin = [], M
    for L in h["layers"]:
        layers.append(dict(k=L["kernel"], d=L["dilation"], la=L["lookahead"], W=take(C, cin, L["kernel"]), b=take(C)))
        cin = C
    ow, ob = take(K, C), take(K)
    assert o == len(a)
    return h, mu0, sd, layers, ow, ob


class Stream:
    """The net run one hop at a time, float32, exactly as the Swift port does it: each layer keeps its
    last (k-1)*d+1 inputs, zeros before the start. Feeding hop n returns the probabilities for hop
    n - LOOKAHEAD (none for the first LOOKAHEAD hops)."""
    def __init__(self, path=RESOURCE):
        self.h, self.mu0, self.sd, self.layers, self.ow, self.ob = read_bin(path)
        self.reset()
        self.mu = self.mu0.astype(np.float64).copy()

    def reset(self):
        self.hist = [np.zeros(((L["k"] - 1) * L["d"] + 1, L["W"].shape[1]), np.float32) for L in self.layers]
        self.n = 0

    def feed(self, lm_row):
        """One hop's log-mel (float64) → class probabilities, or None while the look-ahead fills."""
        self.mu += EMA * (lm_row - self.mu)
        x = ((lm_row - self.mu) / self.sd).astype(np.float32)
        lag = 0
        for i, L in enumerate(self.layers):
            h = self.hist[i]
            h[:-1] = h[1:]; h[-1] = x
            lag += L["la"]
            if self.n < lag: self.n_inc(); return None
            taps = h[::L["d"]]                                       # oldest … newest, k of them
            y = L["b"] + np.einsum("oik,ki->o", L["W"], taps).astype(np.float32)
            y = np.maximum(y, 0).astype(np.float32)
            x = y if i == 0 else (h[-1 - L["la"]] + y).astype(np.float32)
        z = (self.ow @ x + self.ob).astype(np.float32)
        e = np.exp(z - z.max())
        self.n_inc()
        return (e / e.sum()).astype(np.float32)

    def n_inc(self): self.n += 1


def cmd_export(args):
    import torch
    ck = torch.load(Path(args.run) / "best.pt", weights_only=False)
    la = sum(l[2] for l in ck["layers"])
    n = sum(v.numel() for k, v in ck["net"].items() if not k.startswith("bns."))
    if la > MAX_LOOKAHEAD or n >= MAX_WEIGHTS:
        sys.exit(f"{args.run}: lookahead {la} hops, {n} weights; the app takes at most {MAX_LOOKAHEAD} and under {MAX_WEIGHTS}")
    dest = Path(args.out).resolve() if args.out else RESOURCE
    n = write_bin(ck, dest)
    print(f"{dest.relative_to(REPO) if dest.is_relative_to(REPO) else dest.name}: {n} weights, {dest.stat().st_size / 1024:.0f} KB")
    # the streaming float32 path must match the batch torch path
    root = data_dir(args)
    mel, lab, spk = load(root, args.splits, ck["shift"])
    i = next(j for j, s in enumerate(spk) if s in set(ck["held"]))
    lm = mel[i].astype(np.float64)
    st = Stream(dest)
    ps = [p for p in (st.feed(r) for r in lm) if p is not None]
    net = torch_net(ck["layers"], ck["ch"]); net.load_state_dict(ck["net"]); net.eval()
    x = torch.tensor(normalise(lm, ck["mu0"], ck["sd"]), dtype=torch.float32).T[None]
    ref = torch.softmax(net(x)[0], 0).T.detach().numpy()[:len(ps)]
    print(f"stream vs torch: max |dp| {np.abs(np.array(ps) - ref).max():.2e}, "
          f"argmax agree {np.mean(np.array(ps).argmax(1) == ref.argmax(1)):.4f}")


def cmd_score(args):
    """An exported .bin on the held-out speakers, batch float32 from its folded weights: the same numbers
    `train` prints for the run it came from, and a way to score nets whose runs are gone."""
    import torch, torch.nn.functional as F
    h, mu0, sd, layers, ow, ob = read_bin(args.bin)
    def predict(lm):
        with torch.no_grad():
            x = ema_norm_torch(torch.tensor(lm, dtype=torch.float32)[None], torch.tensor(mu0.astype(np.float64)),
                               torch.tensor(sd)).transpose(1, 2)
            for i, L in enumerate(layers):
                y = F.relu(F.conv1d(F.pad(x, ((L["k"] - 1) * L["d"] - L["la"], L["la"])), torch.tensor(L["W"]),
                                    torch.tensor(L["b"]), dilation=L["d"]))
                x = y if i == 0 else x + y
            return (torch.tensor(ow) @ x[0] + torch.tensor(ob)[:, None]).argmax(0).numpy()
    mel, lab, spk = load(data_dir(args), args.splits, args.shift)
    eval_s = streams(mel, lab, spk, set(args.held))
    cm = np.zeros((len(CLASSES), len(CLASSES)), dtype=np.int64)
    for m, l in eval_s: np.add.at(cm, (l, predict(m)), 1)
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    np.save(out / "confusion.npy", cm)
    report(out)
    res = pause_eval(predict, eval_s, noise_floors(seed=8))
    print(pause_line(res)); print("  " + "  ".join(f"{k} {100 * r:.0f}" for k, (r, _) in res.items()))


def synth():
    """The reader's synthetic test signal (reader_live.synth), so both parity tests share an input."""
    sys.path.insert(0, str(Path(__file__).parent))
    from reader_live import synth as s
    return np.asarray(s(), dtype=np.float64)


def synth_probs(net, mu0, sd, dev):
    """The net's shapes for the synthetic test signal, batch torch (what Stream gives, hop for hop)."""
    import torch
    net.eval()
    x = torch.tensor(normalise(log_mel(synth()), mu0, sd), dtype=torch.float32, device=dev).T[None]
    with torch.no_grad(): return torch.softmax(net(x)[0], 0).T.cpu().numpy()


def synth_check(probs, quiet=False):
    """MouthVisemesTests.soundsComeOutAsTheirShapes on the Python side: each synthetic sound's mean shape."""
    sys.path.insert(0, str(Path(__file__).parent))
    from reader_live import SYNTH
    c = {k: CLASSES.index(k) for k in ("rest", "OO", "OH", "EE", "AH", "teeth", "SH")}
    t = (np.arange(len(probs)) * HOP + WIN / 2) / SR
    ok, start = True, 0.0
    for name, dur in SYNTH:
        lo, hi = start + min(0.06, 0.3 * dur), start + dur - 0.04
        start += dur
        p = probs[(t >= lo) & (t <= hi)].mean(0)
        want = {"a": (p[c["AH"]], 0.5), "i": (p[c["EE"]], 0.5), "u": (p[c["OO"]] + p[c["OH"]], 0.5),
                "s": (p[c["teeth"]] + p[c["SH"]], 0.4)}.get(name, (p[c["rest"]], 0.5))
        ok &= bool(want[0] > want[1])
        if not quiet: print(f"  {name:>3}: {want[0]:.2f} (needs > {want[1]})" + ("" if want[0] > want[1] else "  FAILS"))
    return ok


def cmd_fixture(args):
    x = synth()
    lm = log_mel(x)
    st = Stream(RESOURCE)
    lookahead = sum(L["la"] for L in st.layers)
    probs = [p for p in (st.feed(r) for r in lm) if p is not None]
    if not synth_check(np.array(probs)): print("the synthetic sounds don't come out as their shapes: MouthVisemesTests will fail")
    fx = dict(samples=len(x), hops=len(lm), lookahead=lookahead,
              logMel=[[round(float(v), 5) for v in lm[i]] for i in (0, 50, 150, len(lm) - 1)],
              logMelRows=[0, 50, 150, len(lm) - 1],
              probs=[[round(float(v), 6) for v in p] for p in probs],
              classes=CLASSES)
    FIXTURE.write_text(json.dumps(fx, separators=(",", ":")) + "\n")
    print(f"{FIXTURE.relative_to(REPO)}: {len(probs)} hops; argmax {''.join(str(int(p.argmax())) for p in probs)}")


def cmd_read(args):
    import soundfile as sf
    from scipy.signal import resample_poly
    x, sr = sf.read(args.wav, dtype="float64")
    if x.ndim > 1: x = x[:, 0]
    if sr != SR:
        g = math.gcd(SR, sr); x = resample_poly(x, SR // g, sr // g)
    st = Stream(RESOURCE)
    ps = [p for p in (st.feed(r) for r in log_mel(x)) if p is not None]
    if args.json:
        Path(args.json).write_text(json.dumps([[round(float(v), 4) for v in p] for p in ps]))
    else:
        print(" ".join(CLASSES[int(p.argmax())] for p in ps))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prep"); p.add_argument("--data"); p.add_argument("splits", nargs="+")
    p = sub.add_parser("train"); p.add_argument("--data"); p.add_argument("--out")
    p.add_argument("--splits", nargs="+", default=["dev-clean", "test-clean"])
    p.add_argument("--epochs", type=int, default=40); p.add_argument("--batch", type=int, default=48)
    p.add_argument("--crop", type=int, default=600); p.add_argument("--lr", type=float, default=3e-3)
    p.add_argument("--held", type=int, nargs="*", default=EVAL_SPEAKERS,
                   help="held-out speaker ids (default: the fixed 14); pass --held with no ids to draw --eval-speakers at random")
    p.add_argument("--eval-speakers", type=int, default=14)
    p.add_argument("--balance", type=float, default=0.3, help="class weights ~ 1/frequency^balance")
    p.add_argument("--shift", type=float, default=0.0, help="read labels this many seconds after the hop's centre")
    p.add_argument("--layers", help="kernel:dilation:lookahead per conv layer, comma separated (default: the app's net)")
    p.add_argument("--ch", type=int, help=f"channels (default {CH})")
    p.add_argument("--dropout", type=float, default=0.1); p.add_argument("--wd", type=float, default=1e-3)
    p.add_argument("--steps", type=int, help="steps per epoch (default: one pass over the training hops)")
    p.add_argument("--teacher", help="a run to distil from: KL to its softened logits plus the hard labels")
    p.add_argument("--kd", type=float, default=0.7, help="weight of the teacher term")
    p.add_argument("--temp", type=float, default=2.0, help="softmax temperature for distillation")
    p.add_argument("--seed", type=int, default=0); p.add_argument("--threads", type=int)
    p.add_argument("--floors", action=argparse.BooleanOptionalAction, default=True,
                   help="steady mic noise floors (white/pink/brown/hiss/hum, -70 to -35 dBFS) under everything")
    p.add_argument("--pauses", type=float, default=0.5, help="share of crops with noise-only pauses spliced in")
    p.add_argument("--eq", type=float, default=12.0, help="largest mic-EQ boost or cut in the augmentation, dB")
    p.add_argument("--bf16", action="store_true", help="train in bfloat16 autocast (fast on CPUs with AMX); eval stays float32")
    p = sub.add_parser("report"); p.add_argument("run")
    p = sub.add_parser("export"); p.add_argument("--data"); p.add_argument("--run", required=True)
    p.add_argument("--out", help=f"where to write the weights (default {RESOURCE.relative_to(REPO)})")
    p.add_argument("--splits", nargs="+", default=["dev-clean", "test-clean"])
    p = sub.add_parser("score"); p.add_argument("--data"); p.add_argument("--bin", default=str(RESOURCE))
    p.add_argument("--splits", nargs="+", default=["dev-clean", "test-clean"])
    p.add_argument("--held", type=int, nargs="+", default=EVAL_SPEAKERS)
    p.add_argument("--shift", type=float, default=0.0); p.add_argument("--out", required=True, help="folder for confusion.npy")
    sub.add_parser("fixture")
    p = sub.add_parser("read"); p.add_argument("--wav", required=True); p.add_argument("--json")
    args = ap.parse_args()
    dict(prep=cmd_prep, train=cmd_train, report=lambda a: report(a.run), export=cmd_export,
         fixture=cmd_fixture, read=cmd_read, score=cmd_score)[args.cmd](args)


if __name__ == "__main__":
    main()
