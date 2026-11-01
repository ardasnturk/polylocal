# ax-probe

Faz 0 prototipi. Mimarideki sistem entegrasyonu kısmını doğrular: global kısayol, seçili metni okuma, yerine yazma ve yerel modelle çeviri.

| Kısayol | Ne yapar |
|---|---|
| ⌘C+C | Seçili metni okur, TR↔EN çevirir ve terminale yazar |
| ⌘⇧C+C | Seçili metni çevirir ve uygulamadaki metnin yerine yazar |

## Çalıştırma

```bash
cd prototypes/ax-probe
swift run ax-probe            # kısayolları dinle
swift run ax-probe --dry      # yalnızca yakala, model çağırma
swift run ax-probe --inspect  # 3 sn sonra odaktaki elemanın tüm AX özelliklerini döker
```

Terminal uygulamana **Accessibility** izni vermen gerekir (Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik). Bazı sistemlerde **Input Monitoring** izni de istenir.

Ortam değişkenleri:

| Değişken | Varsayılan |
|---|---|
| `TRANSLATER_BASE_URL` | `http://localhost:11434/v1` (Ollama) |
| `TRANSLATER_MODEL` | `gemma4` |
| `TRANSLATER_PAIR` | `tr,en` (dil algılanır, diğer dile çevrilir) |

## Bulgular (2026-11-01, macOS 27.0.1, M4 Pro)

- **Çift ⌘C algılama** yalnızca dinleyen (`listenOnly`) bir event tap ile güvenilir çalışıyor. Uygulamanın kendi kopyalama davranışı bozulmuyor.
- **Sistem geneli odak sorgusu** (`AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`) `-25204` (`kAXErrorCannotComplete`) hatası veriyor. **Öndeki uygulamanın** `AXUIElement`'ine sormak çalışıyor. Uygulama bu sırayı izlemeli.
- TextEdit'te okuma, seçim konumu ve AX ile yerine yazma çalışıyor.
- Model soğukken ilk çeviri ~1,1 sn sürdü, ısınınca ilk kelime ~380 ms'de geldi. Uygulamada modeli önceden ısıtmak gerekiyor.

## Bilinen eksikler

- ⌘⇧C+C'de AX seçimi okuyamazsa yedek yol yok. Uygulama sahte bir ⌘C gönderip panodan okumalı.
- Çeviri yalnızca terminale yazılıyor, popup yok (Faz 1).
