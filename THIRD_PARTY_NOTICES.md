# Third-party notices

Yapper is built on these projects and models. Speech and formatting models are downloaded on first use, never bundled.

| Component | Use in Yapper | License |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) and OpenAI Whisper models | Speech to text (Whisper models) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Speech to text on the Neural Engine, number conversion | Apache-2.0 |
| [NVIDIA Parakeet TDT](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | Speech model (default on Apple Silicon) | CC-BY-4.0 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Runs the on-device formatting model | MIT |
| [Qwen3.5 2B](https://huggingface.co/Qwen/Qwen3.5-2B) | On-device formatting model | Apache-2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | App updates | MIT |
| [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) | Pausing other apps' media | BSD-3-Clause |
| [LibriTTS](https://www.openslr.org/60/) with [Montreal Forced Aligner alignments](https://huggingface.co/datasets/cdminix/libritts-aligned) | Training data for the Loud Mouth's mouth-shape model (bundled weights only, no audio) | CC-BY-4.0 |
| [Speech Commands v0.02](https://www.tensorflow.org/datasets/catalog/speech_commands) (Warden, Google) | Training data for the mouth-shape model; its MFA alignments are in `tools/mouth/alignments/` (no audio) | CC-BY-4.0 |
| [The People's Speech](https://huggingface.co/datasets/MLCommons/peoples_speech) (MLCommons), "clean" subset | Training data for the mouth-shape model; its MFA alignments, which include its transcripts, are in `tools/mouth/alignments/` (no audio) | CC-BY (2.0–4.0) |
| [OpenSLR 28 room impulse responses and noises](https://www.openslr.org/28/) (RWCP, REVERB 2014, AIR; MUSAN noises) | Simulated phones and rooms for training the mouth-shape model (nothing ships) | Apache-2.0 |
| [Montreal Forced Aligner](https://montreal-forced-aligner.readthedocs.io/) with its english_us_arpa models | Aligning the new training corpora (a tool, nothing ships) | MIT / CC-BY-4.0 |

Parakeet TDT is by NVIDIA, licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/); Yapper uses FluidAudio's Core ML conversion unmodified.

The Loud Mouth's mouth-shape model (`Yapper/Resources/vibecode.bin`, and the experimental `tools/mouth/vibecode-lead30.bin`) was trained by Yapper on the dev-clean, test-clean and train-clean-100 subsets of LibriTTS by Heiga Zen et al. (Google), derived from LibriSpeech and LibriVox, licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/), with phone alignments from cdminix/libritts-aligned (CC BY 4.0). No audio from the corpus ships with Yapper.
