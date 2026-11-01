# Benchmark Results

Hardware: Apple M4 Pro, 24 GB · macOS 27.0.1 · test set: 30 sentences × 6 directions · temperature 0
Ollama 0.20.3 (Q4_K_M) · llama.cpp/llama-server 0.8.0 (Q4_0, Metal)

| Model | Template | tr-en chrF++ | en-tr chrF++ | tr-de chrF++ | de-tr chrF++ | en-de chrF++ | de-en chrF++ | Avg. chrF++ | TTFT (ms) | tok/s | Memory |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gemma4-e4b-q4_0-llamacpp | generic | 81.1 | 77.9 | 75.3 | 79.5 | 78.5 | 77.1 | **78.2** | 120 | 60 | 5.2 GB |
| gemma4-e4b-ollama | generic | 80.0 | 77.2 | 73.7 | 78.2 | 77.4 | 79.7 | **77.7** | 188 | 53 | 10.7 GB |
| translategemma-4b-ollama | translategemma | 71.3 | 69.3 | 67.5 | 65.6 | 69.5 | 75.9 | **69.9** | 169 | 69 | 4.3 GB |
| qwen3-4b-instruct-ollama | generic | 68.5 | 56.0 | 60.3 | 53.7 | 69.4 | 75.0 | **63.8** | 110 | 71 | 3.5 GB |

Memory: `/api/ps` for Ollama; RSS of the `llama-server` process for llama.cpp.

## Notes

- **gemma4-e4b (llama.cpp, Q4_0):** the app's built-in engine. Quality matches the same model on Ollama (the difference is within measurement noise), but:
  - First token in ~120 ms (~190 ms on Ollama).
  - Generation at ~60 tok/s (~53 on Ollama).
  - ~5 GB memory (10.7 GB on Ollama). Ollama also loads the model's vision and audio components; llama.cpp loads only the text model.
- **gemma4-e4b (Ollama):** translates idioms word for word ("Ayağını yorganına göre uzat" → "Stretch your leg according to your blanket"). The llama.cpp build has the same problem.
- **translategemma-4b:** measured with its own prompt format. Being based on Gemma 3, it falls behind the newer Gemma 4. Examples of its errors:
  - Got stuck in a repetition loop in one sentence ("Trenç, trenç, trenç…").
  - Translated "three o'clock" ("Saat üç") as "13".
  - Added words that do not exist ("Sundaki teklifimizi…").
- **qwen3-4b-instruct (2507):** the fastest, but its Turkish output is often grammatically broken ("Bizi sabah üçte birlikte toplantıya taşıyabilir misiniz?"). Acceptable for EN↔DE.

## Decisions

- **Default model: Gemma 4 E4B (Q4_0).**
- **Default engine: llama.cpp (`llama-server`).** Same quality, faster, and about half the memory. Ollama remains a second option for people who already use it.
- To measure next: Gemma 4 26B-A4B and TranslateGemma 12B (quality-mode candidates), MLX.
