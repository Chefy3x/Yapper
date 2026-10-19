# Third-party notices

Yapper is built on these projects and models. Models are downloaded on first use, never bundled.

| Component | Use in Yapper | License |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) and OpenAI Whisper models | Speech to text (Whisper models) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Speech to text on the Neural Engine, number conversion | Apache-2.0 |
| [NVIDIA Parakeet TDT](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | Speech model (default on Apple Silicon) | CC-BY-4.0 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Runs the on-device formatting model | MIT |
| [Qwen3.5 2B](https://huggingface.co/Qwen/Qwen3.5-2B) | On-device formatting model | Apache-2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | App updates | MIT |
| [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) | Pausing other apps' media | BSD-3-Clause |

Parakeet TDT is by NVIDIA, licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/); Yapper uses FluidAudio's Core ML conversion unmodified.
