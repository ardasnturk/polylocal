# Uyumluluk Matrisi

`prototypes/ax-probe` ile test edilir. Her satır, bir uygulamada metnin hangi yolla okunup yazılabildiğini gösterir.

| Uygulama | Bundle ID | Okuma (⌘C+C) | Yerine yazma (⌘⇧C+C) | Seçim konumu | Not | Test |
|---|---|---|---|---|---|---|
| TextEdit | com.apple.TextEdit | ✅ AX | ✅ AX | ✅ | Sistem geneli sorgu başarısız (-25204); öndeki uygulama üzerinden çalışıyor | 2026-11-01, macOS 27.0.1 |

**Simgeler:** ✅ AX ile çalışıyor · 🟡 yalnızca pano/yapıştırma yedeğiyle · ❌ çalışmıyor · — test edilmedi

Sıradaki adaylar: Safari, Chrome, Slack, Mail, Notes, Notion, VS Code, WhatsApp, Teams, Word.
