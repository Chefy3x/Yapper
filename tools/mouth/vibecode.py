# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "scipy", "soundfile", "torch"]
# ///
"""Vibecode reader: a small causal net that reads mouth SHAPES from mic audio, one per 10 ms hop.

The live reader (reader_live.py) already knows how open the mouth is (J), how wide or round (W) and
whether the teeth meet (T). This adds what it can't hear from loudness and formants: lips sealed for
m/b/p, the lower lip tucked for f/v, rounded for oo/w, spread for ee, and so on. The syllable jaw
keeps control of how open; this net only picks the shape.

Features match the reader: 16 kHz mono, 25 ms Hamming window, 10 ms hop, 512-point FFT, 40 log-mel
bands, then a running per-band mean (3 s) is taken off so mic gain and EQ drop out. The net is a
stack of 1-D convolutions that hears 350 ms of the past and LOOKAHEAD hops (40 ms) of the future, so
its answer for a hop comes 40 ms after the reader's, inside MouthTimeline's 45 ms playout.

Yapper/Mouth/MouthVibecode.swift is a line-for-line port of `Features` and `Net.stream`;
YapperTests/MouthVibecodeTests.swift checks the two agree on the reader's synthetic test signal.
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
  uv run tools/mouth/vibecode.py prep  --data DIR dev-clean test-clean train-clean-100
  uv run tools/mouth/vibecode.py train --data DIR [--epochs 40] [--out DIR/runs/name]
  uv run tools/mouth/vibecode.py train --data DIR --layers K:D:LA,… --ch N …   (a teacher: any size or look-ahead)
  uv run tools/mouth/vibecode.py train --data DIR --teacher DIR/runs/teacher …  (a student distilled from it)
  uv run tools/mouth/vibecode.py export --data DIR --run DIR/runs/name     (writes Yapper/Resources/vibecode.bin)
  uv run tools/mouth/vibecode.py fixture                                    (writes YapperTests/Fixtures/mouth_vibecode_synth.json)
  uv run tools/mouth/vibecode.py read --wav in.wav                          (prints the classes per hop)
"""
import argparse, glob, json, math, os, re, struct, sys, time
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
RESOURCE = REPO / "Yapper/Resources/vibecode.bin"
FIXTURE = REPO / "YapperTests/Fixtures/mouth_vibecode_synth.json"

# ---- features (mirrored in MouthVibecode.swift) ----
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
# what MouthVibecode.swift and its tests accept: the shapes land inside MouthTimeline's 45 ms playout
MAX_LOOKAHEAD, MAX_WEIGHTS = 4, 1_000_000

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


# sounds a person can hold (a long "mmm", "fff", "ooo"): continuants and vowels, not stops or affricates
HOLDABLE = {"M", "N", "NG", "F", "V", "S", "Z", "SH", "ZH", "TH", "DH", "L", "R",
            "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"}


def labels(phones, n, shift=0.0, holdable=False):
    """Class per hop, read at the hop window's centre (+ shift seconds). HH takes the next phone's class.
    With `holdable`, also an int per hop: 1 + the phone's index where that phone is HOLDABLE, else 0."""
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
    if not holdable: return out
    hold = np.zeros(n, dtype=np.int32)
    can = np.array([p in HOLDABLE for _, _, p in phones])
    sel = ok & can[np.clip(k, 0, len(can) - 1)]
    hold[sel] = k[sel] + 1
    return out, hold


# Corpora besides LibriTTS, aligned with MFA (english_us_arpa): audio under <data>/<dir>/<speaker>/<stem>.{wav,flac},
# TextGrids under <data>/align/<name>/<speaker>/<stem>.TextGrid. Each holds its own speakers out (see held_out).
CORPORA = {"speech-commands": ("sc_mfa", "sc"), "peoples-speech": ("ps_mfa", "ps")}
DEVICE = "-device"           # LibriTTS split + this: the same utterances through a simulated phone or laptop (cmd_device)


def corpus_files(root, split):
    """(audio, TextGrid, speaker name) for a split: a LibriTTS split, its -device copy's source, or a CORPORA name."""
    base = split[:-len(DEVICE)] if split.endswith(DEVICE) else split
    if base in CORPORA:
        d, a = CORPORA[base]
        files = sorted(glob.glob(str(root / d / "*" / "*.wav")) + glob.glob(str(root / d / "*" / "*.flac")))
        rej = root / "align" / a / "rejected.txt"
        if rej.exists():
            drop = set(rej.read_text().split()); files = [f for f in files if Path(f).stem not in drop]
        return [(f, root / "align" / a / Path(f).parent.name / (Path(f).stem + ".TextGrid"), Path(f).parent.name) for f in files]
    files = sorted(glob.glob(str(root / "LibriTTS" / base / "*" / "*" / "*.wav")) + glob.glob(str(root / "LibriTTS" / base / "*" / "*" / "*.flac")))
    align = root / "align" / base.replace("-", "_")
    return [(f, align / Path(f).stem.split("_")[0] / (Path(f).stem + ".TextGrid"), Path(f).stem.split("_")[0]) for f in files]


def speaker_id(root, split, name):
    """An int per speaker, unique across corpora and the -device copies; LibriTTS keeps its own numbers."""
    import hashlib
    base = split[:-len(DEVICE)] if split.endswith(DEVICE) else split
    if base in CORPORA:
        n = (2 + list(CORPORA).index(base)) * 10 ** 8 + int(hashlib.md5(name.encode()).hexdigest(), 16) % 10 ** 8
    else:
        n = int(name)
    return n + (10 ** 8 if split.endswith(DEVICE) and base not in CORPORA else 0)


def held_out(root, split, name):
    """The fixed held-out speakers: EVAL_SPEAKERS for LibriTTS (and its -device copy), Speech Commands' own
    test-list speakers, and one People's Speech recording in ten (by name)."""
    import hashlib
    base = split[:-len(DEVICE)] if split.endswith(DEVICE) else split
    if base == "speech-commands":
        if not hasattr(held_out, "sc"):
            held_out.sc = {l.split("/")[1].split("_")[0] for l in (root / "sc" / "testing_list.txt").read_text().split()}
        return name in held_out.sc
    if base == "peoples-speech": return int(hashlib.md5(name.encode()).hexdigest(), 16) % 10 == 0
    return int(name) in EVAL_SPEAKERS


def read_audio(path):
    import soundfile as sf
    from scipy.signal import resample_poly
    x, sr = sf.read(path, dtype="float64")
    if x.ndim > 1: x = x[:, 0]
    if sr != SR:
        g = math.gcd(SR, sr); x = resample_poly(x, SR // g, sr // g)
    return x


def prep_split(root, split, transform=None, share=1.0, jobs=1):
    """Log-mel and phones of every aligned utterance in a split → cache/<split>.npz. `transform(x, rng)` runs
    on the 16 kHz audio first (the device simulation); `share` keeps that fraction of utterances."""
    t0 = time.time()
    items = [it for it in corpus_files(root, split) if it[1].exists()]
    missing = len(corpus_files(root, split)) - len(items)
    if share < 1:
        import hashlib
        items = [it for it in items if int(hashlib.md5(Path(it[0]).stem.encode()).hexdigest(), 16) % 1000 < share * 1000]
    work = [(root, split, it, transform) for it in items]
    if jobs > 1:
        import multiprocessing as mp
        with mp.Pool(jobs) as pool: done = pool.map(prep_one, work, chunksize=16)
    else:
        done = [prep_one(w) for w in work]
    done = [d for d in done if d is not None]
    mels, phones_out, spk, utt, held = zip(*done)
    lens = np.array([len(m) for m in mels])
    out = root / "cache" / f"{split}.npz"
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez(out, mel=np.concatenate(mels), lens=lens, speaker=np.array(spk), utt=np.array(utt),
             phones=np.array(phones_out), held=np.array(held))
    print(f"{split}: {len(mels)} utterances, {lens.sum() / 360000:.2f} h, {len(set(spk))} speakers "
          f"({len(set(s for s, h in zip(spk, held) if h))} held out), {missing} without alignment, "
          f"{time.time() - t0:.0f} s → {out}", flush=True)


def prep_one(w):
    root, split, (audio, tg, name), transform = w
    x = read_audio(audio)
    if transform is not None:
        x = transform(x, np.random.default_rng(int.from_bytes(Path(audio).stem.encode()[-8:], "little")))
    lm = log_mel(x)
    if len(lm) < 20: return None
    return lm.astype(np.float16), json.dumps(read_textgrid(tg)), speaker_id(root, split, name), Path(audio).stem, held_out(root, split, name)


class Device:
    """A random phone or laptop between the talker and the features, on 16 kHz audio: a room (a real or
    simulated impulse response from OpenSLR 28, some taken with a phone in the hand), real background
    noise, a small mic's EQ (low cut, presence peak, sometimes a band limit), sometimes a phone's noise
    suppression and level control, sometimes a lossy codec round trip (AAC, Opus or MP3 through ffmpeg).
    The direct path and the codec delay are lined back up, so the phone alignments still hold."""
    def __init__(self, rirs_dir):
        r = Path(rirs_dir)
        listed = lambda f: [str(r.parent / l.split()[-1]) for l in (r / "real_rirs_isotropic_noises" / f).read_text().splitlines() if l.strip()]
        self.real = [f for f in listed("rir_list") if os.path.exists(f)]
        self.phone = [f for f in self.real if "phone" in f]
        self.sim = sorted(glob.glob(str(r / "simulated_rirs" / "*room" / "*" / "*.wav")))
        self.noise = [f for f in listed("noise_list") if os.path.exists(f)] + sorted(glob.glob(str(r / "pointsource_noises" / "*.wav")))
        if not (self.real and self.sim and self.noise): sys.exit(f"no RIRs/noises under {rirs_dir} (OpenSLR 28 RIRS_NOISES)")

    def __call__(self, x, rng):
        import soundfile as sf
        from scipy.signal import fftconvolve, butter, sosfilt, lfilter
        n = len(x)
        speech = np.sqrt(np.mean(x[np.abs(x) > 0.1 * np.abs(x).max()] ** 2) + 1e-12)
        if rng.random() < 0.6:                                   # a room
            pool = self.phone if rng.random() < 0.25 else self.real if rng.random() < 0.6 else self.sim
            h, _ = sf.read(pool[rng.integers(len(pool))], dtype="float64")
            h = h[:, 0] if h.ndim > 1 else h
            pk = int(np.argmax(np.abs(h)))
            h = h[max(0, pk - 16):] / np.abs(h[pk])
            x = fftconvolve(x, h)[min(pk, 16):min(pk, 16) + n]
        if rng.random() < 0.6:                                   # background noise
            v, _ = sf.read(self.noise[rng.integers(len(self.noise))], dtype="float64")
            v = v[:, 0] if v.ndim > 1 else v
            v = np.resize(v[rng.integers(len(v)):] if len(v) > n else v, n)
            if np.any(v):
                x = x + v / np.sqrt(np.mean(v ** 2)) * speech * 10 ** (-rng.uniform(5, 30) / 20)
        # the mic: a low cut, a presence peak, sometimes a band limit (narrowband calls at 3.4 kHz)
        x = sosfilt(butter(2, rng.uniform(60, 300), "highpass", fs=SR, output="sos"), x)
        f0, gain, q = rng.uniform(1500, 5000), rng.uniform(-4, 8), rng.uniform(0.7, 2.0)
        A, w = 10 ** (gain / 40), 2 * math.pi * f0 / SR
        al = math.sin(w) / (2 * q)
        bq = np.array([1 + al * A, -2 * math.cos(w), 1 - al * A]); aq = np.array([1 + al / A, -2 * math.cos(w), 1 - al / A])
        x = lfilter(bq / aq[0], aq / aq[0], x)
        if rng.random() < 0.35:
            x = sosfilt(butter(6, 3400 if rng.random() < 0.3 else rng.uniform(4500, 7500), "lowpass", fs=SR, output="sos"), x)
        if rng.random() < 0.4: x = self.suppress(x, rng)
        if rng.random() < 0.3:                                   # level control: quiet parts up, loud parts down
            env = np.sqrt(np.convolve(x ** 2, np.ones(1600) / 1600, "same") + 1e-8)
            x = x * np.clip((speech / env) ** rng.uniform(0.2, 0.5), 0.3, 4.0)
        x = x / (np.sqrt(np.mean(x ** 2)) + 1e-12) * 10 ** (rng.uniform(-38, -18) / 20)
        x = np.clip(x, -1, 1)
        if rng.random() < 0.5: x = self.codec(x, rng)
        return x

    @staticmethod
    def suppress(x, rng):
        """A phone's noise suppression, roughly: a per-bin noise estimate (a low percentile over time) and a
        smoothed Wiener-ish gain with a floor."""
        from scipy.signal import stft, istft
        _, _, Z = stft(x, SR, nperseg=512, noverlap=384)
        P = np.abs(Z) ** 2
        N = np.percentile(P, 10, axis=1, keepdims=True)
        g = np.maximum(10 ** (-rng.uniform(12, 25) / 20), 1 - rng.uniform(1, 3) * N / (P + 1e-12))
        for t in range(1, g.shape[1]): g[:, t] = np.maximum(g[:, t], 0.6 * g[:, t - 1])     # quick attack, slow release
        _, y = istft(Z * g, SR, nperseg=512, noverlap=384)
        return np.resize(y, len(x))

    @staticmethod
    def codec(x, rng):
        """A lossy round trip through ffmpeg, then lined back up with the input (codec delay) by cross-correlation."""
        import subprocess, tempfile, soundfile as sf
        kind = ["aac", "opus", "mp3"][rng.integers(3)]
        rate = {"aac": [24, 32, 48, 64, 96], "opus": [12, 16, 24, 32], "mp3": [32, 48, 64, 96]}[kind][rng.integers(4)]
        ext, enc = {"aac": ("m4a", "aac"), "opus": ("ogg", "libopus"), "mp3": ("mp3", "libmp3lame")}[kind]
        with tempfile.TemporaryDirectory(dir="/dev/shm" if os.path.isdir("/dev/shm") else None) as d:
            sf.write(f"{d}/in.wav", x, SR, subtype="PCM_16")
            r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", f"{d}/in.wav", "-c:a", enc, "-b:a", f"{rate}k", f"{d}/c.{ext}"])
            r2 = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", f"{d}/c.{ext}", "-ar", str(SR), "-ac", "1", f"{d}/out.wav"])
            if r.returncode or r2.returncode: return x
            y, _ = sf.read(f"{d}/out.wav", dtype="float64")
        m = min(len(x), len(y), SR * 2)
        L = 3000
        c = np.correlate(np.pad(y[:m + L], (0, max(0, m + L - len(y)))), x[:m], "valid")[:2 * L] if len(y) > m else np.zeros(1)
        lag = int(np.argmax(c)) if len(c) > 1 else 0
        y = y[lag:]
        return np.pad(y, (0, max(0, len(x) - len(y))))[:len(x)]


def cmd_device(args):
    root = data_dir(args)
    dev = Device(args.rirs or root / "rir" / "RIRS_NOISES")
    for split in args.splits:
        prep_split(root, split + DEVICE, dev, args.share, args.jobs)


def align_stats(audio, tg):
    """How believable one alignment is: dB from the silences to the phones (hop energy), the share of phones
    at MFA's 30 ms minimum, the speech's length and the share of unknown-word phones."""
    ph = read_textgrid(tg)
    e = np.log(np.exp(log_mel(read_audio(audio))).sum(1) + 1e-9) * 10 / math.log(10)
    t = (HOP * np.arange(len(e)) + WIN / 2) / SR
    sp = np.zeros(len(e), bool)
    for a, b, p in ph:
        if p not in ("", "sil", "sp"): sp |= (t >= a) & (t < b)
    real = [(a, b, p) for a, b, p in ph if p not in ("", "sil", "sp")]
    if not real or sp.all() or not sp.any(): return dict(contrast=np.nan, short=1.0, speech=0.0, unk=1.0)
    return dict(contrast=float(np.median(e[sp]) - np.median(e[~sp])), short=float(np.mean([b - a <= 0.031 for a, b, _ in real])),
                speech=float(sum(b - a for a, b, _ in real)), unk=float(np.mean([p == "spn" for _, _, p in real])))


def cmd_check_align(args):
    """Alignment quality on a sample of a corpus (and LibriTTS's alignments for reference); writes the
    clear failures of the whole corpus to align/<name>/rejected.txt, which prep skips."""
    root = data_dir(args)
    rng = np.random.default_rng(0)
    def sample(split, n):
        items = [it for it in corpus_files(root, split) if it[1].exists()]
        return [items[i] for i in rng.choice(len(items), min(n, len(items)), replace=False)]
    def summary(name, st):
        c = np.array([x["contrast"] for x in st]); sh = np.array([x["short"] for x in st])
        print(f"{name:16s} n {len(st):5d}  speech/silence contrast median {np.nanmedian(c):5.1f} dB (10th pct {np.nanpercentile(c, 10):5.1f}),"
              f" phones at 30 ms {100 * np.mean(sh):4.1f}%, unknown words {100 * np.mean([x['unk'] for x in st]):4.1f}%,"
              f" rejected {100 * np.mean([bad(x) for x in st]):4.1f}%")
    bad = lambda x: not (x["contrast"] >= args.min_contrast) or x["short"] > 0.5 or x["unk"] > 0.3 or x["speech"] < 0.1
    summary("LibriTTS (ref)", [align_stats(a, t) for a, t, _ in sample("dev-clean", 300)])
    for name in args.corpora:
        print(f"{name}: sample", flush=True)
        summary(name, [align_stats(a, t) for a, t, _ in sample(name, args.sample)])
        if args.write:
            items = [it for it in corpus_files(root, name) if it[1].exists()]
            import multiprocessing as mp
            with mp.Pool(args.jobs) as pool: st = pool.starmap(align_stats, [(a, t) for a, t, _ in items], chunksize=64)
            rej = [Path(a).stem for (a, _, _), x in zip(items, st) if bad(x)]
            (root / "align" / CORPORA[name][1] / "rejected.txt").write_text("\n".join(rej) + "\n")
            print(f"{name}: {len(rej)} of {len(items)} rejected → align/{CORPORA[name][1]}/rejected.txt", flush=True)


def cmd_prep(args):
    root = data_dir(args)
    for split in args.splits: prep_split(root, split, jobs=args.jobs)


def load(root, splits, shift, extra=False, held_ids=None):
    """Every utterance's log-mel, labels and speaker; with `extra`, also whether its speaker is held out (the
    cache's own flag, else `held_ids`), the split it came from, which hops are holdable (see labels) and its name."""
    held_ids = set(EVAL_SPEAKERS if held_ids is None else held_ids)
    mel, lab, spk, held, src, hold, utt = [], [], [], [], [], [], []
    for s in splits:
        z = dict(np.load(root / "cache" / f"{s}.npz"))      # read each array once
        off = np.concatenate([[0], np.cumsum(z["lens"])])
        for i, n in enumerate(z["lens"]):
            mel.append(z["mel"][off[i]:off[i + 1]])
            l, h = labels(json.loads(str(z["phones"][i])), n, shift, holdable=True)
            lab.append(l); hold.append(h)
            spk.append(int(z["speaker"][i]))
            held.append(bool(z["held"][i]) if "held" in z else int(z["speaker"][i]) in held_ids)
            src.append(s); utt.append(str(z["utt"][i]))
    if extra: return mel, lab, np.array(spk), np.array(held), src, hold, utt
    return mel, lab, np.array(spk)


def split_speakers(spk, n_eval, seed=1):
    ids = sorted(set(spk.tolist()))
    rng = np.random.default_rng(seed)
    return set(rng.choice(ids, n_eval, replace=False).tolist())


def make_streams(mel, lab, spk, hflag, src, hold, utt):
    """One stream per (split, speaker): each speaker's utterances end to end (the pauses between are real).
    Returns the training streams and the held-out ones, as dicts (log-mel m, labels l, holdable phones h,
    utterance names and lengths, split)."""
    by = {}
    for i in range(len(mel)): by.setdefault((src[i], spk[i]), []).append(i)
    def stream(ix):
        hs = [np.where(hold[i] > 0, hold[i] + 1000 * j, 0) for j, i in enumerate(ix)]   # phones of different utterances stay apart
        return dict(m=np.concatenate([mel[i] for i in ix]), l=np.concatenate([lab[i] for i in ix]), h=np.concatenate(hs),
                    utt=[utt[i] for i in ix], lens=[len(lab[i]) for i in ix], src=src[ix[0]])
    return [stream(ix) for ix in by.values() if not hflag[ix[0]]], [stream(ix) for ix in by.values() if hflag[ix[0]]]


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


FLOOR_SNR = 20.0       # dB


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


def floor_under(n, rng, floors, kind=None, db=None, cap=np.inf):
    """n hops of one floor (a random colour, sometimes two, at -70 to -35 dBFS), mel power, turned down
    if need be so its mean power (summed over the bands) stays under `cap`."""
    kinds = sorted(floors)
    out = np.zeros((n, N_MELS), np.float32)
    for k in ([kind] if kind else [kinds[i] for i in rng.choice(len(kinds), 1 + (rng.random() < 0.3), replace=False)]):
        F = floors[k]
        idx = (rng.integers(0, len(F)) + np.arange(n)) % len(F)
        out += F[idx] * 10 ** ((db if db is not None else rng.uniform(-70, -35)) / 10)
    return out * min(1.0, cap / out.sum(1).mean())


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
        # at least FLOOR_SNR under the speech's loud half: a floor that drowns the voice isn't a pause's floor,
        # and a noise burst a vowel's height from it is a fricative
        e = p.sum(-1)
        loud = (e * (e >= e.median(1, keepdim=True).values)).sum(1) / (e >= e.median(1, keepdim=True).values).sum(1)
        cap = loud.cpu().numpy() * 10 ** (-FLOOR_SNR / 10)
        p = p + torch.tensor(np.stack([floor_under(T, rng, floors, cap=c) for c in cap]), device=dev)
    p = p + level * torch.exp(gain) * noise_mel[None, None] * torch.tensor(rng.uniform(0.5, 1.5, (B, T, 1)), device=dev, dtype=torch.float32)
    return torch.log(p + LOG_EPS)


def hold_walk(core, n, rng):
    """n hops of a held sound from the hops of one phone's steady middle: a random walk through them (so the
    sound wobbles as a held one does) with a slow level drift of a dB or two."""
    i = rng.integers(len(core)); idx = np.empty(n, int)
    for t in range(n):
        idx[t] = i
        i = int(np.clip(i + rng.integers(-1, 2), 0, len(core) - 1))
    drift = np.cumsum(rng.normal(0, 0.02, n)); drift -= drift.mean()
    return core[idx] + np.clip(drift, -0.5, 0.5)[:, None].astype(np.float32)


def phone_runs(h):
    """(start, end) of each holdable phone in a hold array (see labels): runs of one nonzero value."""
    edges = np.flatnonzero(np.diff(np.concatenate([[0], h, [0]])) != 0)
    return [(a, b) for a, b in zip(edges[:-1], edges[1:]) if h[a] != 0]


def class_factors(spec):
    """"MBP:2,FV:2" → {class index: factor}"""
    return {CLASSES.index(k): float(v) for k, v in (kv.split(":") for kv in spec.split(","))} if spec else {}


def crop(m, l, z, T, rng, pause_p, h=None, hold_p=0.0, focus=(), focus_p=0.0):
    """A training crop of T hops. With probability hold_p, one holdable phone in it is held: stretched to
    0.3-1.5 s (hold_walk), with probability focus_p one of the `focus` classes when the crop has one. With probability pause_p, one or two stretches of nothing (0.2-3 s, at most 4 s
    in all, labelled rest) are spliced in, for the floor to fill. Returns log-mel, labels, teacher logits (or
    None) and a mask that is 0 on the made-up hops (the teacher never heard them)."""
    gaps = rng.integers(20, 301, rng.integers(1, 3)) if rng.random() < pause_p else np.zeros(0, int)
    if gaps.sum() > min(400, T // 2): gaps = gaps[:1]
    need = T - int(gaps.sum())
    a = rng.integers(0, max(1, len(l) - need))
    x, y, k = m[a:a + need].astype(np.float32), l[a:a + need], np.ones(need, np.float32)
    zt = None if z is None else z[a:a + need].astype(np.float32)
    if h is not None and rng.random() < hold_p:
        runs = [(p, q) for p, q in phone_runs(h[a:a + need]) if q - p >= 3 and p > 0 and q < need]
        pick = [r for r in runs if y[r[0]] in focus]
        if pick and rng.random() < focus_p: runs = pick
        if runs:
            # a class first, evenly, then one of its phones: being held must say nothing about which shape it is
            cs = sorted({int(y[r[0]]) for r in runs}); c = cs[rng.integers(len(cs))]
            runs = [r for r in runs if y[r[0]] == c]
            p, q = runs[rng.integers(len(runs))]
            cut = max(1, (q - p) // 5)
            core = x[p + cut - 1:q - cut + 1] if q - p > 4 else x[p:q]
            n = max(int(rng.integers(30, 151)), q - p + 10)
            x = np.concatenate([x[:p], hold_walk(core, n, rng), x[q:]])[:need]
            y = np.concatenate([y[:p], np.full(n, y[p], y.dtype), y[q:]])[:need]
            k = np.concatenate([k[:p], np.zeros(n, np.float32), k[q:]])[:need]
            if zt is not None: zt = np.concatenate([zt[:p], np.zeros((n, zt.shape[1]), np.float32), zt[q:]])[:need]
    for g, at in zip(gaps, np.sort(rng.integers(0, need, len(gaps)))[::-1]):      # last first: earlier places hold
        x = np.concatenate([x[:at], np.full((g, N_MELS), math.log(1e-9), np.float32), x[at:]])
        y = np.concatenate([y[:at], np.zeros(g, y.dtype), y[at:]])
        k = np.concatenate([k[:at], np.zeros(g, np.float32), k[at:]])
        if zt is not None: zt = np.concatenate([zt[:at], np.zeros((g, zt.shape[1]), np.float32), zt[at:]])
    return x, y, zt, k


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
    mel, lab, spk, hflag, src, hold, utt = load(root, args.splits, args.shift, extra=True, held_ids=args.held or None)
    held = set(args.held) if args.held else split_speakers(spk[[s in LIBRI for s in src]], args.eval_speakers)
    if not args.held: hflag = np.array([f if s not in LIBRI else k in held for f, s, k in zip(hflag, src, spk)])
    missing = held - set(spk[[s in LIBRI for s in src]].tolist())
    if missing and any(s in LIBRI for s in src): sys.exit(f"held-out speakers not in the loaded splits: {sorted(missing)}")
    train_d, eval_d = make_streams(mel, lab, spk, hflag, src, hold, utt)
    del mel, lab, hold
    train_s = [(d["m"], d["l"]) for d in train_d]
    eval_s = [(d["m"], d["l"]) for d in eval_d if d["src"] in LIBRI and not d["src"].endswith(DEVICE)]
    groups = {}
    for d in eval_d: groups.setdefault(corpus_group(d["src"]), []).append((d["m"], d["l"]))
    held_items = held_sounds(eval_d)
    alll = np.concatenate([l for _, l in train_s])
    mu0 = np.zeros(N_MELS)                       # where the running mean settles
    for m, _ in train_s: mu0 += m.astype(np.float64).sum(0)
    mu0 /= len(alll)
    # the spread once the running mean comes off
    sd = np.concatenate([normalise(m[:6000].astype(np.float64), mu0, np.ones(N_MELS)) for m, _ in train_s[:8]]).std(0) + 1e-3
    counts = np.bincount(alll, minlength=len(CLASSES))
    print(f"train {len(train_s)} streams {len(alll) / 360000:.2f} h; held out: " +
          ", ".join(f"{g} {len(v)} streams {sum(len(l) for _, l in v) / 360000:.2f} h" for g, v in groups.items()) +
          f"; classes {dict(zip(CLASSES, (counts / counts.sum()).round(3)))}", flush=True)
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
        # the teacher hears clean LibriTTS; its answers per utterance also serve the same utterance's -device
        # copy (privileged: it heard the clean audio). Other corpora get the hard labels only.
        t0 = time.time()
        clean = [d for d in train_d if d["src"] in LIBRI and not d["src"].endswith(DEVICE)]
        zs = teacher_logits(args.teacher, [(d["m"], d["l"]) for d in clean], args.shift, held,
                            [s for s in args.splits if s in LIBRI and not s.endswith(DEVICE)], dev)
        per = {}
        for d, z in zip(clean, zs):
            for u, piece in zip(d["utt"], np.split(z, np.cumsum(d["lens"])[:-1])): per[u] = piece
        teach = [np.concatenate([per[u] for u in d["utt"]]) if all(u in per for u in d["utt"]) else None for d in train_d]
        got = [i for i, z in enumerate(teach) if z is not None]
        acc = np.mean(np.concatenate([teach[i].argmax(1) for i in got]) == np.concatenate([train_s[i][1] for i in got]))
        print(f"teacher {args.teacher}: logits for {sum(len(teach[i]) for i in got)} hops in {time.time() - t0:.0f} s, "
              f"agrees with the labels on {acc:.3f}; KD weight {args.kd}, temperature {args.temp}", flush=True)
    opt = torch.optim.AdamW(net.parameters(), lr=args.lr, weight_decay=args.wd)
    T = args.crop
    keep = [i for i, st in enumerate(train_s) if len(st[1]) > T]
    train_s = [train_s[i] for i in keep]
    holds = [train_d[i]["h"] for i in keep]
    if teach: teach = [teach[i] for i in keep]
    lens = np.array([len(l) for _, l in train_s])
    steps_per_epoch = args.steps or int(len(alll) / (args.batch * T))
    total = steps_per_epoch * args.epochs
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, args.lr, total_steps=total, pct_start=0.1)
    w = torch.tensor((counts.sum() / (counts + 1)) ** args.balance, device=dev, dtype=torch.float32)
    for c, f in class_factors(args.class_weight).items(): w[c] *= f
    w = w / (w * torch.tensor(counts / counts.sum(), device=dev, dtype=torch.float32)).sum()
    rng = np.random.default_rng(args.seed)
    torch.manual_seed(args.seed)
    focus = {CLASSES.index(c) for c in args.hold_classes.split(",")} if args.hold_classes else set()
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
            xs, ys, zs, ks = zip(*(crop(*train_s[s], teach[s] if teach else None, T, rng, args.pauses, holds[s], args.holds,
                                        focus, args.hold_focus) for s in si))
            if teach:       # streams the teacher didn't hear (other corpora): hard labels only
                ks = [k if z is not None else np.zeros_like(k) for k, z in zip(ks, zs)]
                zs = [z if z is not None else np.zeros((T, len(CLASSES)), np.float32) for z in zs]
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
        per = {g: evaluate(net, v, mu0, sd, dev) for g, v in groups.items()}
        score = np.mean([b for _, b, _ in per.values()])          # what picks the best epoch: every corpus counts
        # the app's tests also read the synthetic vowels; a net that fails them can't ship (teachers don't)
        synth_ok = not ships or synth_check(synth_probs(net, mu0, sd, dev), quiet=True)
        print(f"epoch {ep + 1:2d}  loss {tl / steps_per_epoch:.3f}  eval acc {acc:.3f}  balanced {bal:.3f}  "
              + (f"synthetic {'ok' if synth_ok else 'FAILS ' + ', '.join(synth_check.fails)}  " if ships else "") + f"{time.time() - t0:.0f} s", flush=True)
        if len(per) > 1: print("          " + "  ".join(f"{g} {a:.3f}/{b:.3f}" for g, (a, b, _) in per.items()) + f"  mean balanced {score:.3f}", flush=True)
        if ships: print("          " + pause_line(pause_eval(torch_predict(net, mu0, sd, dev), eval_s, eval_floors, (-45,))), flush=True)
        if ships: print("          " + held_line(held_eval(torch_predict(net, mu0, sd, dev), held_items)), flush=True)
        torch.save({"net": net.state_dict(), "mu0": mu0, "sd": sd, "layers": layers, "ch": ch, "classes": CLASSES,
                    "shift": args.shift, "held": sorted(held), "epoch": ep + 1}, out / "last.pt")
        if score > best and synth_ok:
            best = score
            torch.save({"net": net.state_dict(), "mu0": mu0, "sd": sd, "layers": layers, "ch": ch,
                        "classes": CLASSES, "shift": args.shift, "held": sorted(held),
                        "splits": args.splits, "teacher": args.teacher and Path(args.teacher).name}, out / "best.pt")
            np.save(out / "confusion.npy", cm)
            for g, (_, _, c) in per.items(): np.save(out / f"confusion {g}.npy", c)
    if best:
        report(out)
        for g in groups:
            if g != "LibriTTS": print(f"\n== {g}"); report(out, f"confusion {g}.npy")
        if ships:
            ck = torch.load(out / "best.pt", weights_only=False); net.load_state_dict(ck["net"])
            res = pause_eval(torch_predict(net, mu0, sd, dev), eval_s, eval_floors)
            print(pause_line(res)); print("  " + "  ".join(f"{k} {100 * r:.0f}" for k, (r, _) in res.items()))
            hr = held_eval(torch_predict(net, mu0, sd, dev), held_items)
            print(held_line(hr)); print("  " + "  ".join(f"{k} {100 * f:.0f}%/{100 * g:.0f}% ({n})" for k, (f, g, n) in hr.items()) + "   (held hops / held sounds)")
    else: print("no epoch's net read the synthetic sounds as the app's tests want: nothing saved")


class _Libri:
    """`split in LIBRI`: a LibriTTS split or its -device copy (not one of CORPORA)."""
    def __contains__(self, s): return (s[:-len(DEVICE)] if s.endswith(DEVICE) else s) not in CORPORA
LIBRI = _Libri()


def corpus_group(src):
    if src in LIBRI: return "LibriTTS device" if src.endswith(DEVICE) else "LibriTTS"
    return {"speech-commands": "Speech Commands", "peoples-speech": "People's Speech"}.get(src, src)


def held_sounds(eval_d, per_class=120, seed=5, pre=300, hold=100, post=30):
    """The held-sound check: steady 1 s sounds made from held-out speakers' long phones (hold_walk over
    the phone's middle), each after 3 s of that speaker's own speech so the running mean is where it would
    be. Returns (log-mel, class, first held hop) per item, at most per_class per class."""
    rng = np.random.default_rng(seed)
    cands = {}
    for d in eval_d:
        if d["src"] not in LIBRI: continue
        for p, q in phone_runs(d["h"]):
            if q - p >= 6 and p >= pre and q + post <= len(d["l"]):
                cands.setdefault(int(d["l"][p]), []).append((d, p, q))
    items = []
    for c in sorted(cands):
        for j in rng.permutation(len(cands[c]))[:per_class]:
            d, p, q = cands[c][j]
            cut = max(1, (q - p) // 5)
            core = d["m"][p + cut:q - cut].astype(np.float32)
            items.append((np.concatenate([d["m"][p - pre:p].astype(np.float32), hold_walk(core, hold, rng),
                                          d["m"][q:q + post].astype(np.float32)]), c, pre))
    return items


def held_eval(predict, items, hold=100, settle=10):
    """Per class: share of the held hops (after the first `settle`) read as the class, and share of held
    sounds whose majority reading is right."""
    res = {}
    for lm, c, a in items:
        pr = predict(lm)[a + settle:a + hold]
        f, g = res.get(c, (0, 0, 0, 0))[:2], res.get(c, (0, 0, 0, 0))[2:]
        res[c] = (f[0] + int((pr == c).sum()), f[1] + len(pr), g[0] + int(np.bincount(pr, minlength=len(CLASSES)).argmax() == c), g[1] + 1)
    return {CLASSES[c]: (a / b, e / n, n) for c, (a, b, e, n) in sorted(res.items())}


def held_line(res):
    fr = {k: v[0] for k, v in res.items()}
    worst = min(fr, key=fr.get)
    return f"held sounds: {100 * np.mean(list(fr.values())):.1f}% of held hops right (worst {worst} {100 * fr[worst]:.0f}%)"


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


def report(run, name="confusion.npy"):
    cm = np.load(Path(run) / name)
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
    _, eval_d = make_streams(*load(data_dir(args), args.splits, args.shift, extra=True, held_ids=args.held))
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    groups = {}
    for d in eval_d: groups.setdefault(corpus_group(d["src"]), []).append((d["m"], d["l"]))
    for g, v in groups.items():
        cm = np.zeros((len(CLASSES), len(CLASSES)), dtype=np.int64)
        for m, l in v: np.add.at(cm, (l, predict(m)), 1)
        name = "confusion.npy" if g == "LibriTTS" else f"confusion {g}.npy"
        np.save(out / name, cm)
        print(f"\n== {g}"); report(out, name)
    if "LibriTTS" in groups:
        res = pause_eval(predict, groups["LibriTTS"], noise_floors(seed=8))
        print(pause_line(res)); print("  " + "  ".join(f"{k} {100 * r:.0f}" for k, (r, _) in res.items()))
    hr = held_eval(predict, held_sounds(eval_d))
    if hr: print(held_line(hr)); print("  " + "  ".join(f"{k} {100 * f:.0f}%/{100 * g:.0f}% ({n})" for k, (f, g, n) in hr.items()) + "   (held hops / held sounds)")


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
    """MouthVibecodeTests.soundsComeOutAsTheirShapes on the Python side: each synthetic sound's mean shape."""
    sys.path.insert(0, str(Path(__file__).parent))
    from reader_live import SYNTH
    c = {k: CLASSES.index(k) for k in ("rest", "FV", "OO", "OH", "EE", "AH", "teeth", "SH")}
    t = (np.arange(len(probs)) * HOP + WIN / 2) / SR
    ok, start, fails = True, 0.0, []
    for name, dur in SYNTH:
        lo, hi = start + min(0.06, 0.3 * dur), start + dur - 0.04
        start += dur
        p = probs[(t >= lo) & (t <= hi)].mean(0)
        # the synthetic a sits on the ah/oh line and the s is white noise, as much an f as an s
        want = {"a": (p[c["AH"]] + p[c["OH"]], 0.5), "i": (p[c["EE"]], 0.5), "u": (p[c["OO"]] + p[c["OH"]], 0.5),
                "s": (p[c["teeth"]] + p[c["SH"]] + p[c["FV"]], 0.4)}.get(name, (p[c["rest"]], 0.5))
        ok &= bool(want[0] > want[1])
        if want[0] <= want[1]: fails.append(f"{name} {want[0]:.2f}")
        if not quiet: print(f"  {name:>3}: {want[0]:.2f} (needs > {want[1]})" + ("" if want[0] > want[1] else "  FAILS"))
    synth_check.fails = fails
    return ok


def cmd_fixture(args):
    x = synth()
    lm = log_mel(x)
    st = Stream(RESOURCE)
    lookahead = sum(L["la"] for L in st.layers)
    probs = [p for p in (st.feed(r) for r in lm) if p is not None]
    if not synth_check(np.array(probs)): print("the synthetic sounds don't come out as their shapes: MouthVibecodeTests will fail")
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
    p = sub.add_parser("prep"); p.add_argument("--data"); p.add_argument("--jobs", type=int, default=1)
    p.add_argument("splits", nargs="+", help=f"LibriTTS splits (dev-clean, …) or {', '.join(CORPORA)}")
    p = sub.add_parser("check-align", help="alignment quality of MFA-aligned corpora; --write rejects the clear failures")
    p.add_argument("--data"); p.add_argument("--sample", type=int, default=400); p.add_argument("--jobs", type=int, default=2)
    p.add_argument("--min-contrast", type=float, default=6.0, help="dB the aligned speech must stand above the aligned silence")
    p.add_argument("--write", action="store_true"); p.add_argument("corpora", nargs="+")
    p = sub.add_parser("device", help="LibriTTS splits through simulated phones and laptops → cache/<split>-device.npz")
    p.add_argument("--data"); p.add_argument("--jobs", type=int, default=1); p.add_argument("--rirs", help="OpenSLR 28 RIRS_NOISES (default <data>/rir/RIRS_NOISES)")
    p.add_argument("--share", type=float, default=1.0, help="fraction of each split's utterances to simulate")
    p.add_argument("splits", nargs="+")
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
    p.add_argument("--holds", type=float, default=0.3, help="share of crops with one phone held 0.3-1.5 s")
    p.add_argument("--hold-classes", default="MBP,FV,L_TH", help="classes the held phone is drawn from first (m, f/v, th/l)")
    p.add_argument("--hold-focus", type=float, default=0.0,
                   help="how often the held phone comes from --hold-classes when the crop has one (otherwise: any class, evenly). "
                        "0.7 taught the net that a held sound is one of them")
    p.add_argument("--class-weight", default="", help='extra loss weight per class, e.g. "MBP:2,FV:2,L_TH:1.5"')
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
    dict(prep=cmd_prep, device=cmd_device, **{"check-align": cmd_check_align}, train=cmd_train, report=lambda a: report(a.run), export=cmd_export,
         fixture=cmd_fixture, read=cmd_read, score=cmd_score)[args.cmd](args)


if __name__ == "__main__":
    main()
