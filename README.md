# Translater (geçici ad)

macOS için açık kaynaklı, ücretsiz ve **tamamen yerel** çalışan bir çeviri uygulaması.

- **⌘C+C** ile her uygulamada seçili metni çevirir (DeepL tarzı).
- **⌘⇧C+C** ile seçili metni çevirir, önizletir ve ↩ ile yerine yazar.
- Kısayollar Ayarlar'dan değiştirilebilir (çift basış ya da ⌃⌥C gibi tek basış).
- Resmi/samimi hitap seçimi (siz/sen, Sie/du…).
- İsteğe bağlı çeviri geçmişi; yalnızca bu Mac'te, yalnızca kullanıcının okuyabildiği bir dosyada.
- Menü çubuğundan açılan iki panelli çeviri penceresi: yazarken çevirir, dili otomatik algılar.
- Çeviriler bilgisayarına indirdiğin bir AI modeliyle yapılır; metinlerin cihazdan çıkmaz.
- **Satır içi öneri** (Cotypist tarzı): Kural eklediğin uygulamada ya da sitede başka bir dilde yazınca imlecin altında çeviri önerisi çıkar; ⇥ ile paragraf çeviriyle değişir.

> Durum: **Faz 3 (geliştirme aşamasında).**

## Gereksinimler

- Apple Silicon Mac, macOS 14+
- Xcode 16+ (Swift 6)
- Çeviri motoru olarak şunlardan biri:
  - **Yerleşik:** `brew install llama.cpp` (uygulama `llama-server`'ı kendisi başlatır, modeli Ayarlar → Modeller'den indirirsin)
  - **Ollama:** Çalışan bir Ollama ve yüklü bir model (ör. `ollama pull gemma4`)

## Derleme ve çalıştırma

```bash
scripts/build-app.sh          # build/Translater.app (release)
open build/Translater.app
```

İlk açılışta kurulum asistanı Erişilebilirlik iznini ve model seçimini adım adım ister. İzin, kısayolları algılamak ve seçili metni okuyup yazmak için gerekli.

## Test

```bash
swift test
TRANSLATER_NETWORK_TESTS=1 swift test                   # gerçek indirme + SHA-256 doğrulama (~60 MB)
TRANSLATER_TEST_GGUF=/yol/model.gguf swift test          # llama-server entegrasyonu
```

## Klasörler

| Klasör | İçerik |
|---|---|
| [Sources](Sources) | Uygulama ve modüller (yapı için bkz. mimari §7) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Mimari plan ve yol haritası |
| [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) | Uygulama uyumluluk matrisi |
| [models/catalog.json](models/catalog.json) | İndirilebilir model kataloğu |
| [tools/bench](tools/bench) | Çeviri modeli karşılaştırma aracı |
| [prototypes/ax-probe](prototypes/ax-probe) | Faz 0 kısayol + Accessibility prototipi |
