# Karşılaştırma Sonuçları

Donanım: Apple M4 Pro, 24 GB · macOS 27.0.1 · test seti: 30 cümle × 6 yön · sıcaklık 0
Ollama 0.20.3 (Q4_K_M) · llama.cpp/llama-server 0.8.0 (Q4_0, Metal)

| Model | Şablon | tr-en chrF++ | en-tr chrF++ | tr-de chrF++ | de-tr chrF++ | en-de chrF++ | de-en chrF++ | Ort. chrF++ | TTFT (ms) | tok/s | Bellek |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gemma4-e4b-q4_0-llamacpp | generic | 81.1 | 77.9 | 75.3 | 79.5 | 78.5 | 77.1 | **78.2** | 120 | 60 | 5.2 GB |
| gemma4-e4b-ollama | generic | 80.0 | 77.2 | 73.7 | 78.2 | 77.4 | 79.7 | **77.7** | 188 | 53 | 10.7 GB |
| translategemma-4b-ollama | translategemma | 71.3 | 69.3 | 67.5 | 65.6 | 69.5 | 75.9 | **69.9** | 169 | 69 | 4.3 GB |
| qwen3-4b-instruct-ollama | generic | 68.5 | 56.0 | 60.3 | 53.7 | 69.4 | 75.0 | **63.8** | 110 | 71 | 3.5 GB |

Bellek: Ollama için `/api/ps`, llama.cpp için `llama-server` sürecinin RSS değeri.

## Notlar

- **gemma4-e4b (llama.cpp, Q4_0):** Uygulamanın yerleşik motoru. Ollama'daki aynı modelle kalite aynı seviyede (fark ölçüm gürültüsü içinde), ama:
  - İlk kelime ~120 ms (Ollama'da ~190 ms).
  - Üretim hızı ~60 tok/s (Ollama'da ~53).
  - Bellek ~5 GB (Ollama'da 10,7 GB). Ollama modelin görüntü ve ses bileşenlerini de yüklüyor; llama.cpp yalnızca metin modelini yüklüyor.
- **gemma4-e4b (Ollama):** Deyimleri kelimesi kelimesine çeviriyor ("Ayağını yorganına göre uzat" → "Stretch your leg according to your blanket"). Bu sorun llama.cpp sürümünde de var.
- **translategemma-4b:** Kendi prompt formatıyla ölçüldü. Gemma 3 tabanlı olduğu için daha yeni Gemma 4'ün gerisinde kalıyor. Hatalarına örnekler:
  - Bir cümlede tekrar döngüsüne girdi ("Trenç, trenç, trenç…").
  - "Saat üç"ü "13'e" çevirdi.
  - Olmayan kelimeler ekledi ("Sundaki teklifimizi…").
- **qwen3-4b-instruct (2507):** En hızlısı, ama Türkçe çıktıları dilbilgisi açısından sık sık bozuk ("Bizi sabah üçte birlikte toplantıya taşıyabilir misiniz?"). EN↔DE yönlerinde kabul edilebilir.

## Kararlar

- **Varsayılan model: Gemma 4 E4B (Q4_0).**
- **Varsayılan motor: llama.cpp (`llama-server`).** Aynı kalitede daha hızlı ve yarı bellekle çalışıyor. Ollama, zaten kullananlar için ikinci seçenek olarak kalıyor.
- Sırada ölçülecekler: Gemma 4 26B-A4B ve TranslateGemma 12B (kalite modu adayları), MLX.
