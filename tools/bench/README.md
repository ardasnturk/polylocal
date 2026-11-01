# Model karşılaştırma aracı

Çeviri modellerini aynı test setiyle kalite ve hız açısından karşılaştırır. OpenAI uyumlu her sunucuyla çalışır: Ollama, `llama-server` (llama.cpp), `mlx_lm.server`.

```bash
# Ollama
uv run tools/bench/bench.py --model gemma4 --label gemma4-e4b-ollama

# llama.cpp
llama-server -m model.gguf --port 8080 &
uv run tools/bench/bench.py --base-url http://localhost:8080/v1 --model x --label translategemma-4b-llamacpp --template translategemma

# Tablo
uv run tools/bench/report.py > tools/bench/RESULTS.md
```

| Seçenek | Açıklama |
|---|---|
| `--template` | `generic` (sistem talimatı) veya `translategemma` (model kartındaki prompt) |
| `--pairs` | Varsayılan `tr-en,en-tr,tr-de,de-tr,en-de,de-en` |
| `--limit N` | Yalnızca ilk N cümle |
| `--think` | Düşünme modunu açık bırak (varsayılan: kapalı) |

## Ölçülenler

- **chrF++ / BLEU** (sacrebleu): Referans çeviriye benzerlik. chrF++ Türkçe gibi eklemeli dillerde BLEU'dan daha anlamlıdır.
- **TTFT:** İlk kelimenin gelme süresi (medyan). Popup ve satır içi öneri hissini belirler.
- **tok/s:** Üretim hızı (medyan).
- **Bellek:** Yalnızca Ollama için (`/api/ps`).

## Test seti

[`data/testset.jsonl`](data/testset.jsonl): TR/EN/DE dillerinde 30 paralel cümle. Alanlar: sohbet, e-posta, arayüz metni, teknik, iş, deyim, sayı/tarih biçimi, paragraf.

Sınırlar: Her cümle için tek referans var ve referanslar bu proje için yazıldı. Deyimlerde doğru ama farklı çeviriler düşük puan alır. Kesin karar için FLORES+ gibi büyük bir set ve COMET metriği eklenmeli.
