# Karşılaştırma Sonuçları

Donanım: Apple M4 Pro, 24 GB · macOS 27.0.1 · Ollama 0.20.3 (Q4_K_M) · test seti: 30 cümle × 6 yön · sıcaklık 0

| Model | Şablon | tr-en chrF++ | en-tr chrF++ | tr-de chrF++ | de-tr chrF++ | en-de chrF++ | de-en chrF++ | Ort. chrF++ | TTFT (ms) | tok/s | Bellek |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gemma4-e4b-ollama | generic | 80.0 | 77.2 | 73.7 | 78.2 | 77.4 | 79.7 | **77.7** | 188 | 53 | 10.7 GB |
| translategemma-4b-ollama | translategemma | 71.3 | 69.3 | 67.5 | 65.6 | 69.5 | 75.9 | **69.9** | 169 | 69 | 4.3 GB |
| qwen3-4b-instruct-ollama | generic | 68.5 | 56.0 | 60.3 | 53.7 | 69.4 | 75.0 | **63.8** | 110 | 71 | 3.5 GB |

## Notlar

- **gemma4-e4b:** Açık ara en iyi kalite; özellikle Türkçeye çeviride diğerlerinden 8–25 puan önde. Ancak deyimleri kelimesi kelimesine çeviriyor ("Ayağını yorganına göre uzat" → "Stretch your leg according to your blanket"). Bellek değeri, modelin görüntü ve ses bileşenlerini de içeriyor; yalnızca metin bileşeniyle yüklenirse daha az bellek kullanılabilir.
- **translategemma-4b:** Kendi prompt formatıyla ölçüldü. Gemma 3 tabanlı olduğu için daha yeni Gemma 4'ün gerisinde kalıyor. Hatalarına örnekler:
  - Bir cümlede tekrar döngüsüne girdi ("Trenç, trenç, trenç…").
  - "Saat üç"ü "13'e" çevirdi.
  - Olmayan kelimeler ekledi ("Sundaki teklifimizi…").
- **qwen3-4b-instruct (2507):** En hızlısı (ilk kelime ~110 ms), ama Türkçe çıktıları dilbilgisi açısından sık sık bozuk ("Bizi sabah üçte birlikte toplantıya taşıyabilir misiniz?"). EN↔DE yönlerinde kabul edilebilir.

## Faz 0 kararı (geçici)

- **Varsayılan model: Gemma 4 E4B.** İlk kelime ~190 ms'de geliyor; hem popup hem satır içi öneri için yeterince hızlı.
- 4B sınıfında TranslateGemma ve Qwen 3 varsayılan olmamalı.
- Sırada ölçülecekler: TranslateGemma 12B, Gemma 4 26B-A4B (kalite modu adayları), llama.cpp ve MLX hız karşılaştırması.
