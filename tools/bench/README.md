# Model benchmark

Compares translation models for quality and speed on the same test set. Works with any OpenAI-compatible server: Ollama, `llama-server` (llama.cpp), `mlx_lm.server`.

```bash
# Ollama
uv run tools/bench/bench.py --model gemma4 --label gemma4-e4b-ollama

# llama.cpp
llama-server -m model.gguf --port 8080 &
uv run tools/bench/bench.py --base-url http://localhost:8080/v1 --model x --label translategemma-4b-llamacpp --template translategemma

# Table
uv run tools/bench/report.py > tools/bench/RESULTS.md
```

| Option | Description |
|---|---|
| `--template` | `generic` (system instruction) or `translategemma` (the prompt from the model card) |
| `--pairs` | Default `tr-en,en-tr,tr-de,de-tr,en-de,de-en` |
| `--limit N` | Only the first N sentences |
| `--think` | Leave thinking mode on (default: off) |

## Metrics

- **chrF++ / BLEU** (sacrebleu): similarity to the reference translation. chrF++ is more meaningful than BLEU for agglutinative languages such as Turkish.
- **TTFT:** time to first token (median). Determines how responsive the popup and inline suggestions feel.
- **tok/s:** generation speed (median).
- **Memory:** Ollama only (`/api/ps`).

## Test set

[`data/testset.jsonl`](data/testset.jsonl): 30 parallel sentences in TR/EN/DE. Domains: chat, email, UI text, technical, business, idioms, number/date formats, paragraphs.

Limitations: each sentence has a single reference, and the references were written for this project. Correct but different translations of idioms score low. For a definitive decision, a large set such as FLORES+ and the COMET metric should be added.
