# NetEkran

GB-2411FF HDMI monitörü için Türkçe, hafif bir macOS menü çubuğu uygulaması. BetterDisplay veya ücretli bir çalışma zamanı bağımlılığı olmadan belirli bir görüntü profilini uygular ve doğrular.

**Hedef:** 1920×1080 masaüstü, 3840×2160 HiDPI çizim, 100 Hz, kanal başına 10-bit SDR RGB Tam Aralık. HDR ve yansıtma kapalıdır. Yaklaşık çözünürlük, LoDPI, düşük yenileme veya doğrulanamayan renk çıkışı başarı sayılmaz.

## Gereksinimler ve derleme

- Apple Silicon Mac ve Xcode komut satırı araçları.
- Renk yapılandırma yolu macOS **26.6.2** için sınırlandırılmıştır. Farklı sürüm veya ekran desteği varsayılmaz.
- Harici monitörde hedef modun sunulması gerekir. Bu proje genel amaçlı bir ekran yöneticisi değildir.

```sh
./build.sh
open build/NetEkran.app
```

Betik uygulamayı derler, ad-hoc imzalar ve beş test programını çalıştırır. Harici paket indirmez. Üretilen uygulama notarize edilmemiştir.

## Kullanım

Menü çubuğundaki ekran simgesinden:

- **Harici monitör kaydırıcısı:** monitörün DDC/CI üzerinden bildirdiği gerçek değeri gösterir; sürükleyince yalnız fiziksel monitör parlaklığını değiştirir ve geri okuyarak doğrular. Monitörde DDC/CI açık olmalıdır. DDC/CI geçerli yanıt vermezse bağlı ekran için kaydırıcı **Harici monitör (yazılımsal)** olarak çalışır. Bu yöntem fiziksel arka ışığı değiştirmez; tıklamaları engellemeyen siyah bir katmanla görüntüyü karartır. Tam kararmayı önlemek için aralık %15–100’dür; ICC/gamma ayarı değiştirilmez. %100’e getirip menüyü yeniden açmak donanım kontrolünü yeniden dener. Karartma yalnız uygulama açıkken geçerlidir; çıkışta kalkar, bağlantı kesilince gizlenir ve aynı ekran döndüğünde yeniden konumlanır.
- **Mac ekranı kaydırıcısı:** yerleşik ekranın macOS parlaklığını bağımsız olarak ayarlar. Kapak kapalıysa veya yerleşik ekran kullanılamıyorsa pasif kalır.
- **Otomatik parlaklık (Mac ekranı):** macOS'un ortam ışığına göre parlaklık ayarını açar/kapatır; işaret doğrudan sistemden okunur. Desteklenmeyen veya okunamayan ayar pasif ve belirsiz işaretle gösterilir. Elle parlaklık ayarlamak otomatik ayarı değiştirmez.
- **Net görüntüyü uygula:** hedef profili uygular ve gerçek çıkışı yeniden okur. 20 saniye içinde **Bu ayarları koru** seçilmezse önceki profile döner.
- **Ayarları otomatik koru:** doğrulanmış profil için kullanıcı tarafından etkinleştirilir. Bağlantı/uyanma bildirimleri ve sınırlı aralıklı kontroller kullanır; doğru ayara yeniden yazmaz.
- **Oturum açılışında başlat:** macOS giriş öğesi olarak kullanıcı isteğiyle etkinleşir.
- **Önceki ayarlara dön:** son elle uygulamadan önceki profil ve ICC seçimini geri getirir.
- **Uygulamanın yaptığı değişiklikleri kaldır:** otomatik korumayı/giriş öğesini kapatır, kendi ICC seçimini geri alır ve yalnız kendi override değişikliğini kaldırır. Dışarıdan değiştirilmiş dosyaların üzerine yazmaz.

**Tek HiDPI kaydını yeniden oluştur** yalnız gerekli ekran kaydını ekler; diğer kayıtları korur. Sistem dosyası işlemi macOS yönetici izni ister. Dosyanın yüklenmesi için yeniden bağlantı veya yeniden başlatma gerekebilir; uygulama yeniden başlatmayı/oturum kapatmayı kendiliğinden yapmaz.

## Uygulama ve geri alma

CoreGraphics/SkyLight sistem yolu gerçek görüntü çıkışını yapılandırır. IOAV, EDID/video çıkışı okuması ve DDC/CI parlaklık iletişimi için kullanılır; doğrudan video bağlantısı yazıcısı yoktur. Özel API sembolleri ve desteklenen sürüm çalışma anında kontrol edilir. SIP veya Gatekeeper kapatılmaz.

Sistem RGB geçişinde fabrika ICC dosyasını yeniden üretebildiği için özgün dosyanın **bayt bayt aynı kopyası** yerelde saklanır ve ColorSync ile seçilir. ICC seçimi gerçek RGB yapılandırmasının yerine kullanılmaz. ICC içeriği, gamma tablosu, dithering, parlaklık ve font ayarı karşılaştırılır; otomatik profil uygulaması bu değerleri değiştirmez. Parlaklık kaydırıcısıyla yapılan açık kullanıcı isteği monitörün VCP `0x10` parlaklık değerini değiştirir; ICC ve gamma içeriğine dokunmaz. İkinci kaydırıcı ve otomatik parlaklık seçeneği yalnız yerleşik ekranın DisplayServices ayarlarını değiştirir. Sistem tarafından değiştirilen ICC oluşturulma tarihi içerik karşılaştırmasında ayrılır; ham veriler yerel işlem kayıtlarında korunur.

Bağımsız gözetmen arayüz çöktüğünde de geri dönüşü yürütür. Çekirdekte takılan bir ekran sürücüsünün kurtarılması garanti edilemez; böyle durumda başarı yerine `recoveryRequired` bildirilir ve çakışan yazımlar engellenir.

## Test kapsamı

Parlaklık işlemleri arayüzü bekletmeyen, süre sınırı olan ayrı bir süreçte yürütülür. İki ekranın istekleri ayrı kuyruklarda yürütülür ve sürükleme istekleri birleştirilir. Harici DDC kontrolü ekran profili işlemleriyle ortak kilit kullanır. Yerleşik ekran yalnız CoreGraphics `CGDisplayIsBuiltin` ile seçilir. DisplayServices sembolleri çalışma anında kontrol edilir; bu özel macOS API’si değişirse kontrol hata bildirir. Otomatik parlaklık, uygulamanın kendi zamanlayıcısıyla taklit edilmez. DDC/CI paket biçimi için [ddcutil birincil uygulama örneği](https://github.com/rockowitz/ddcutil/issues/585) incelenmiştir; çalışma zamanı bağımlılığı eklenmemiştir.

`./build.sh`; sınırlı DDC tekrarları/bozuk veya başarısız yanıt reddi/karartma alt sınırı, DDC paketleri/parlaklık aralıkları/alt süreç zaman aşımı, yerleşik ekran ve otomatik parlaklık isteklerinin ayrılması/geçersiz değer reddi, hedef profil reddi, ICC koruması, bağımsız gözetmen zaman aşımı/çökme senaryoları ve geçici dosyalarla override ekle/kaldır testlerini çalıştırır. Bu otomatik testler ekran ayarını değiştirmez.

Desteklenen yapılandırmada gerçek profil uygulaması, 20 saniyelik geri alma, arayüz çökmesi, HDMI yeniden bağlantısı, uyku/uyanma ve hedef kaydın yeniden oluşturulması da donanım üzerinde kontrol edilmiştir. Bu sonuçlar farklı donanımlar veya temiz macOS kurulumu için uyumluluk garantisi değildir. Kendi ekranınızda görsel netliği ve renkleri ayrıca kontrol edin.

## Gizlilik

Uygulama verileri `~/Library/Application Support/NetEkran/` altında yerelde tutulur. Tanılama çıktıları cihaz kimlikleri, EDID, yerel yollar ve renk profili bilgileri içerebilir; paylaşmadan önce temizleyin.

Bu repo yalnız kaynak kodu, sentetik testler ve derleme yönergelerini içerir. Gerçek tanılamalar, ICC dosyaları, cihaz seri/UUID kayıtları, kullanıcı yolları, yerel geliştirme planları ve derleme çıktıları yayın kapsamı dışındadır. `.gitignore` varsayılan olarak kökteki yeni dosyaları da dışarıda bırakır; yayınlanacak yeni dosyaları açıkça izin listesine ekleyin.
