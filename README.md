# DiscordAltyazı

macOS menü çubuğu uygulaması. Mac'in **sistem sesini** canlı yakalar, Apple'ın
**cihaz üzerinde çalışan** SpeechAnalyzer motoruyla İngilizceye döker, Türkçeye
çevirir ve ekranın altında şeffaf bir altyazı bandında gösterir.

Discord'da İngilizce konuşan insanları anlamak için yazıldı.

- **Konuşma tanıma:** %100 yerel (Apple SpeechAnalyzer / SpeechTranscriber). Ağa çıkmaz.
- **45 kaynak dil:** İngilizce, Fransızca, İspanyolca, Almanca… menüden seçilir.
- **Müzik filtresi:** şarkı sözleri altyazıya düşmez (Apple SoundAnalysis, yerel).
- **Konuşmacı adı:** altyazı "Mert: bu adam uçuyor" şeklinde, kimin konuştuğuyla birlikte.
- **Çeviri (varsayılan):** kullanıcının kurulu `claude` CLI'ı — kendi aboneliği üzerinden.
- **Çeviri (yedek):** Apple Translation (en → tr), tamamen yerel.
- Ücretli API anahtarı yok, üçüncü parti Swift paketi yok.

---

## Gereksinimler

| | |
|---|---|
| macOS | 26 veya üzeri |
| Command Line Tools | Xcode 26+ (SDK'da `SpeechAnalyzer` olmalı) |
| `claude` CLI | kurulu **ve giriş yapılmış** (sadece varsayılan backend için) |

CLT sürümünü kontrol et:

```bash
ls /Library/Developer/CommandLineTools/SDKs/
# MacOSX26.sdk (veya üstü) görünmeli
```

Görünmüyorsa:

```bash
sudo softwareupdate -i "Command Line Tools for Xcode 27.2-27.2"
```

---

## Derleme

```bash
cd ~/Desktop/DiscordAltyazi
./build.sh              # release
./build.sh debug        # debug
```

Çıktı: `build/DiscordAltyazi.app`

```bash
open build/DiscordAltyazi.app                      # normal çalıştırma
build/DiscordAltyazi.app/Contents/MacOS/DiscordAltyazi   # logları görmek için
```

İkinci komut uygulamayı terminalden başlatır; gecikme ölçümleri, hot swap ve
fallback olayları doğrudan konsola düşer.

---

## İzinler

### Ekran Kaydı (zorunlu)

Sistem sesi ScreenCaptureKit ile yakalanıyor; macOS bunu Ekran Kaydı izni
altında tutuyor. Uygulama ilk açılışta izin panelini tetikler.

**Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı** → DiscordAltyazı açık.
İzni verdikten sonra **uygulamayı yeniden başlat**.

> **Geliştirme sırasında:** uygulamayı terminalden çalıştırıyorsan izin
> `Terminal`'e (veya `iTerm`'e) verilmeli, uygulamaya değil. `.app`'i her
> yeniden derlediğinde ad-hoc imza değiştiği için macOS izni tekrar sorabilir.

### Konuşma tanıma

İlk kullanımda `en-US` dil modeli yoksa otomatik indirilir; overlay'de
"Dil modeli indiriliyor…" yazar. Tek seferlik, birkaç yüz MB.

### Apple Çeviri paketi

`en → tr` paketi kurulu değilse ilk çalıştırmada indirilir.

---

## Kullanım

Menü çubuğundaki altyazı ikonundan:

| Menü | Ne yapar |
|---|---|
| Yakalamayı Başlat / Durdur | sistem sesini dinlemeye başlar/durur |
| Overlay'i Göster / Gizle | altyazı bandını açar/kapatır |
| **Kaynak Dil: …** | konuşulan dili seçer (45 dil). `⬇` = model henüz inmemiş, seçince iner. `· yalnız Claude` = Apple bu dilden Türkçeye çeviremiyor |
| Çeviri: … | aktif backend durumu (Claude ısınıyor/hazır, Apple) |
| Çeviri Backend'i | Claude CLI ↔ Apple Çeviri |
| Yazı Boyutu | Küçük (22pt) / Orta (28pt) / Büyük (36pt) |
| Konum | Alt / Üst |
| **Hızlı Mod** | Apple anında bassın, Claude sonra düzeltsin (varsayılan açık) |
| **Müziği Çevirme** | şarkı sözlerini altyazıya basma (varsayılan açık) |
| **Hızlı Tanıma** | STT cümleyi erken kesinleştirsin (varsayılan açık) |
| Çıkış | tüm CLI süreçlerini kapatıp çıkar |

İkon yakalama açıkken dolu ve yeşil görünür.

### Kısayollar

| Kısayol | İşlev |
|---|---|
| `⌘⇧T` | yakalamayı aç/kapat — Discord dışı sesleri hızlıca susturmak için |
| `⌘⇧H` | overlay'i göster/gizle |

### Kalibrasyon araçları

`tools/` altında, Discord arayüzü değişirse yeniden ayarlamak için:

```bash
cd tools
swiftc -O -o sesprobe sesprobe.swift && ./sesprobe 30      # AX ağacında ne değişiyor
swiftc -O -parse-as-library -framework ImageIO -o halka halka.swift && ./halka
                                                            # üye satırları + yeşil halka oranı
```

Kısayollar global; hangi uygulamada olursan ol çalışır. (Carbon
`RegisterEventHotKey` kullanılıyor, Erişilebilirlik izni istemez.)

Ayarlar `UserDefaults`'ta saklanır, uygulama kapanınca kaybolmaz.

---

## Nasıl çalışıyor

```
ScreenCaptureKit (sistem sesi, kendi sesimiz hariç)
        ↓  CMSampleBuffer → AVAudioConverter
SpeechAnalyzer + SpeechTranscriber (yerel, en-US)
        ↓  volatile (soluk İngilizce)  →  overlay alt satır
        ↓  final (kesin cümle)         →  çeviri kuyruğu
FallbackTranslator
        ├─ ClaudeCLITranslator  (varsayılan, kalıcı süreç)
        └─ AppleTranslator      (yedek, yerel)
        ↓
Overlay (şeffaf NSPanel, ekranın altı, son 3 cümle)
```

### Claude CLI backend

Her cümle için yeni süreç açmak yerine **tek kalıcı süreç** kullanılır:

```
claude -p --input-format stream-json --output-format stream-json --verbose \
       --model haiku --effort low --tools "" --no-session-persistence \
       --strict-mcp-config --setting-sources "" --disable-slash-commands \
       --system-prompt "<altyazı çevirmeni promptu>"
```

- API anahtarı kullanılmaz, OAuth token'ı okunmaz. Sadece CLI çağrılır →
  kullanıcının kendi aboneliği üzerinden çalışır.
- `MAX_THINKING_TOKENS=0` ile model düşünmeyi atlar: çeviri **~2–4 sn yerine
  ~0.9 sn**.
- Araçlar, MCP sunucuları, ayar dosyaları ve slash komutları kapalı — başlangıç
  hızlı, bağlam temiz. Süreç boş bir geçici dizinde çalışır ki proje
  `CLAUDE.md`'si yüklenmesin.
- Her istekte son 3 final cümle bağlam olarak gider:
  `ÖNCEKİ: … | … | … / ÇEVİR: …`

### Ön ısıtma

Uygulama açılır açılmaz, yakalama daha başlamadan Claude süreci ayağa kalkar ve
sessiz bir `ÇEVİR: Hello.` isteğiyle ısınır. Yanıt atılır — ekrana basılmaz,
sayaca ve bağlam geçmişine eklenmez. Menüde "Claude (ısınıyor…)" → "Claude
(hazır)". Isınma 10 sn'yi aşarsa Claude hazır sayılmaz, 30 sn sonra tekrar
denenir; o sürede gelen cümleler beklemez, Apple'a düşer.

### Kesintisiz süreç yenileme (hot swap)

Kalıcı süreçte bağlam birikir (ölçüldü: 417 → 551 → 669 token). Bu yüzden:

1. Aktif süreç **35. çeviriye** geldiğinde arka planda yeni bir süreç başlar.
2. Yeni süreç aynı ön ısıtma akışından geçer, hazır olunca "yedek" olarak bekler.
3. Aktif süreç işlediği isteği bitirir, **sonra** yeni istekler yedeğe gider.
   Altyazıda boşluk olmaz, kuyruktaki istek kaybolmaz.
4. Eski süreç temiz kapatılır: stdin kapanır, 2 sn içinde çıkmazsa `terminate`,
   hâlâ duruyorsa `SIGKILL`. Zombi süreç kalmaz.
5. Yedek 10 sn'de hazır olmazsa geçiş iptal, eski süreçle devam (sayaç 40'ı
   aşabilir, sorun değil), 30 sn sonra tekrar denenir.
6. Aynı anda **en fazla 2 süreç** yaşar.

Aktif süreç ölürse: yedek hazırsa anında devralır, değilse Apple'a düşülür ve
yeni süreç kurulur.

### Gecikme

Canlı altyazıda asıl mesele gecikme. Ölçülen kırılım ve alınan önlemler:

| Kaynak | Önlem | Ölçüm |
|---|---|---|
| STT cümleyi geç kesinleştiriyor | `ReportingOption.fastResults` | final gecikmesi **339–739 ms** |
| Claude çevirisi ~1.2 sn | **Hızlı mod**: Apple yerel çeviri anında basar, Claude gelince aynı satır düzeltilir | ilk görünme **~45–60 ms** |
| Apple oturumu boşta soğuyor | yakalama açıkken 15 sn'de bir sessiz ısıtma | 826 ms → **43 ms** |
| İlk `⌘⇧T` saniyelerce sürüyor | `SCShareableContent` sorgusu bu makinede **7.8 sn** sürüyor (`startCapture` ise 0.2 sn); ekran açılışta bir kez alınıp saklanıyor | 9.0 sn → **0.4 sn** |
| Arka arkaya cümleler sıra bekliyor | çift hatlı kuyruk (hızlı + kaliteli ayrı) | 2.6 sn bekleme ortadan kalktı |
| Claude düşünme token'ı harcıyor | `MAX_THINKING_TOKENS=0` | 2–4 sn → **~0.9 sn** |

Konuşma bittikten sonra altyazının ekrana düşmesi: **~0.7–1.0 sn**. Claude'un
düzeltmesi bunun üstüne ~0.8–1.5 sn sonra, satırı yerinde değiştirerek gelir.

`.fastResults` doğruluktan biraz veriyor. Aynı ses dosyası iki modda
karşılaştırıldığında farklar küçük ("head shot" → "head shit" gibi) ve asıl
büyük hatalar iki modda da aynı çıkıyor. Yine de menüden kapatılabilir.

### Müzik filtresi

Apple'ın SoundAnalysis sınıflandırıcısı (303 ses sınıfı, yerel) her ~0.5 sn'de
sesi etiketler. Son 3 saniyedeki en yüksek **konuşma** ve **müzik** skorlarına
bakılır; konuşma 0.25'i geçiyorsa veya müzikten yüksekse cümle çevrilir, aksi
hâlde atılır. Ölçülen ayrım net:

| Örnek | Konuşma | Müzik | Karar |
|---|---|---|---|
| Konuşma kaydı | 0.915 | 0.090 | kabul |
| Müzik kaydı | 0.003 | 0.896 | red |

Müzik üstüne konuşulduğunda konuşma kazanır — altyazı kesilmez. Sınıflandırma
henüz gelmediyse engelleme yapılmaz; konuşma kaybetmek birkaç şarkı sözü
göstermekten kötü.

### Kaynak dil

Menüdeki liste `SpeechTranscriber.supportedLocales`'ten canlı üretilir (bu
Mac'te **45 dil**). Dil değişince sırayla: yakalama durur, gerekiyorsa konuşma
modeli iner, Apple oturumu yenilenir, Claude süreçleri yeni sistem promptuyla
(prompt dil adını içeriyor) yeniden kurulur, yakalama kaldığı yerden devam eder.

### Konuşmacı adı

Altyazıya kimin konuştuğu yazılır. Apple'ın çerçevelerinde konuşmacı ayrımı
(diarization) API'si yok ve sistem sesi Discord'dan tek karışık akış olarak
geliyor; bu yüzden bilgi Discord'un kendisinden okunur — iki kaynağı birleştirerek:

**1. Erişilebilirlik ağacı — isimler ve koordinatlar.**
Electron uygulamaları içeriklerini normalde açmaz; `AXManualAccessibility`
niteliği bunu açıyor (ölçüldü: ağaç 2 düğümden 162 düğüme çıkıyor). Sesli
kanaldaki üyeler `315x32` boyutunda `AXButton` satırları olarak geliyor, ekran
koordinatlarıyla birlikte. Susturulmuş kişiler de ad ekinden anlaşılıyor.

**2. Piksel — konuşma anı.**
Discord'un yeşil konuşma halkası erişilebilirlik ağacına **yansımıyor** (60 sn
canlı sohbette ölçüldü: ağaçta yalnızca çağrı süresi sayacı ve ping değişiyor).
Halka salt görsel, ama ScreenCaptureKit pencereyi **arkadayken de** yakalayabiliyor.
Her üyenin avatar kutusundaki yeşil piksel oranı ölçülür:

| | Konuşan | Diğerleri |
|---|---|---|
| Yeşil piksel oranı | **%8.9** | %0.0 – %0.4 |

Eşik %2. Tüm pencere değil, yalnızca üye listesini kapsayan ince dikdörtgen
yakalanır — uygulamanın toplam CPU kullanımı **%0.9**.

Kendi kullanıcın hariç tutulur: Discord kendi sesini geri çalmadığı için senin
konuşman zaten yakaladığımız seste yok. Kendi adın, alt paneldeki metinlerle
üye listesi kesiştirilerek bulunur.

Bir cümle kesinleştiğinde son 3.5 saniyede en çok konuşan kişiye etiketlenir.
Menüden **Konuşmacı Adını Göster** ile kapatılabilir.

**Gerekli izin:** Sistem Ayarları → Gizlilik ve Güvenlik → **Erişilebilirlik**.
İzin yoksa altyazı isimsiz çalışmaya devam eder.

**Sınır:** iki kişi gerçekten aynı anda konuşursa ses zaten karışık geliyor;
ne biz ne Apple ayırabilir. Çözülen şey sırayla konuşurken kimin söylediğini
etiketlemek — Discord'da vakaların çoğu bu.

### Fallback kuralları

- Claude 3 sn içinde dönmezse veya hata verirse o cümle Apple'a gider.
- Art arda 3 hatada Claude 60 sn devre dışı kalır, sonra tekrar denenir.
- Apple da çevirmezse orijinal İngilizce metin gösterilir — uygulama çökmez.
- Çok kısa / dolgu ifadeler ("uh", "yeah", "hmm") çeviriye hiç gönderilmez.
- Çeviriler sıraya girer, aynı anda tek istek işlenir, sırayla ekrana düşer.

---

## Loglar

```
[03:14:22.418] [STT] FINAL: that was an insane clutch
[03:14:23.302] [CEVIRI] Claude · 884 ms · "that was an insane clutch" -> "Resmen inanılmaz bir clutch'tı"
[03:14:23.305] [OVERLAY] Ekrana düştü (Claude, 884 ms)
[03:16:05.112] [HOTSWAP] 35. çeviri — yedek süreç arka planda hazırlanıyor
[03:16:07.904] [HOTSWAP] Yedek süreç hazır — ısınma 2792 ms
[03:16:11.233] [HOTSWAP] Yedek süreç devraldı, eski süreç kapatılıyor
```

Ölçülen gecikme: final cümle geldi → çeviri ekrana düştü, backend adıyla.

---

## Abonelik kullanımı hakkında not

Claude backend'i her cümle için bir istek atar. Yoğun bir Discord sohbetinde bu
dakikada 10–20 istek demek; 5 saatlik kullanım limitini hatırı sayılır şekilde
yer. Haiku seçilmesinin sebebi bu (hem ucuz hem hızlı), ama yine de:

- Uzun seanslarda limit dolabilir. Doldu mu, fallback devreye girer ve altyazı
  Apple çevirisiyle devam eder — kesinti olmaz, kalite düşer.
- Dinlemediğin anlarda `⌘⇧T` ile yakalamayı kapat. Kapalıyken istek gitmez.

---

## Bilinen sınırlar

- Ekran Kaydı izni zorunlu; macOS sistem sesini başka türlü vermiyor.
- `~/.claude/CLAUDE.md` (kullanıcı hafızası) CLI tarafından yine de yükleniyor.
  Bunu kapatan tek bayrak `--bare`, ama o OAuth'u okumuyor (API anahtarı
  istiyor) — aboneliği bozacağı için kullanılmadı.
- Her yeniden derlemede ad-hoc imza değişir; macOS Ekran Kaydı iznini tekrar
  sorabilir.
- Bu makinede SwiftUI'sız `TranslationSession(installedSource:target:)` "Unable
  to Translate" veriyor; uygulama otomatik olarak gizli SwiftUI host yoluna
  düşüyor (log: `[APPLE] Doğrudan oturum kurulamadı … SwiftUI yoluna geçiliyor`).
  Çalışma açısından fark yok.
- `@State` artık bir makro ve makro eklentisi Command Line Tools ile gelmiyor;
  bu yüzden SwiftUI host view'ı `@State` kullanmadan yazıldı. Xcode kurulu
  değilse bunu bozmamaya dikkat et.
- **Konuşmacı adı Discord'un arayüzüne bağlı.** Discord düzenini veya temasını
  değiştirirse üye satırı ölçüleri (`315x32`) ve yeşil ton kayabilir.
  `tools/sesprobe` ve `tools/halka` bu değerleri yeniden kalibre etmek için var.
- Sesli kanal kenar çubuğunda görünmüyorsa (kanal kapalıysa) ad okunamaz.

---

© 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır. Bkz. `LICENSE`.
