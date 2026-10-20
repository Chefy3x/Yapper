# Mouth-shape (Vibecode) training checkpoints

PyTorch checkpoints from `tools/mouth/vibecode.py train`, one folder per run, with the run's log as `train.log`
(data paths shown as `$YAPPER_MOUTH_DATA`). Each `.pt` is a dict: `net` (state dict), `mu0` and `sd` (the
feature normalisation), `layers` (kernel, dilation, look-ahead per conv), `ch`, `classes`, `shift` (label
shift in seconds), `held` (held-out LibriTTS speakers), and on `best.pt` also `splits` and `teacher`; `last.pt`
also has `epoch`. Optimizer and scheduler state were not saved, so a run can be continued as a fine-tune from
`net`, not resumed exactly. Load with `torch.load(path, weights_only=False)` and `vibecode.torch_net(ck["layers"], ck["ch"])`.

`best.pt` is the best epoch that passed the app's synthetic check; `last.pt` is the last epoch run.

| run | what it is |
|---|---|
| `teacher` | 10 layers × 256, 200 ms look-ahead, 1.83M weights; clean LibriTTS (dev/test-clean + train-clean-100). Every student here distils from it |
| `teacher-ep5` | the same teacher after 5 of 8 epochs |
| `base` | v1's size (5 × 80), all LibriTTS, no teacher |
| `trial` | 6 × 88 student from `teacher-ep5`, stopped at epoch 3 |
| `s0-noeq`, `lead30-noeq` | 6 × 88 students, no mic EQ (fail the synthetic test's cold start) |
| `s0-eq6`, `lead30-eq6` | ± 6 dB EQ, stopped early |
| `s0-eq12-ungated`, `lead30-eq12-nopause` | ± 12 dB EQ |
| `s0-gated-nopause` | ± 12 dB EQ, synthetic gate, stopped at epoch 9 |
| `s0-pause35`, `lead30-pause35` | noise floors up to −35 dBFS with no cap and pauses (failed the old synthetic check) |
| `quick-cap` | 4-epoch test of floors capped 20 dB under the speech |
| `s0`, `lead30` | floors capped, pauses: the runs PR 3 shipped from (`last.pt`, epoch 20) |
| `s0-ship`, `lead30-ship` | exactly what PR 3 shipped (`visemes.bin` / `visemes-lead30.bin` there) |
| `rm` | PR 4's real-mic student: 8 × 192, 819k weights, 40 ms look-ahead, on LibriTTS + device copies + Speech Commands + People's Speech, held sounds, MBP/FV/L_TH weighted. Pushed while still training |
