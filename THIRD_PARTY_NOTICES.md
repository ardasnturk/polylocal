# Third-party notices

## Bundled software

### llama.cpp (`llama-server`)

Release builds of Polylocal include a `llama-server` binary built from
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) (pinned tag in
`scripts/build-llama-server.sh`). It is distributed under the MIT License;
the full license text ships in the app as `Contents/Resources/llama.cpp-LICENSE`.

## Models (not bundled)

Polylocal does not ship any model weights. Models are downloaded by the user
from Hugging Face on first use and remain subject to their own licenses:

| Model | License |
|---|---|
| Gemma 4 E2B / E4B / 26B-A4B (GGUF by ggml-org) | Apache License 2.0 |
| TranslateGemma 4B (GGUF by bullerwins) | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) — the app asks for acceptance before downloading |

See `models/catalog.json` for exact files and checksums.
