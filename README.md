File Server Detaylı Durum Raporu

Windows File Server ortamlarını analiz eden ve kapsamlı HTML raporları oluşturan PowerShell scripti.

Özellikler
Genel File Server durum özeti
Disk kapasite ve kullanım analizi
Klasör erişim yetkileri raporu
En büyük klasörlerin analizi
En büyük dosyaların analizi
Boş klasör tespiti
Boş dosya tespiti
Uzantıya göre dosya dağılımı
Kategori bazlı dosya analizi
Son değiştirilen dosyalar raporu
Eski dosya analizi
Uzun yol uyarısı tespiti
Aynı isimli dosya analizi
Aylık değişiklik aktivitesi
Derin klasör yapısı analizi
HTML rapor oluşturma
E-posta ile otomatik rapor gönderimi
Gereksinimler
Windows Server veya Windows İstemci İşletim Sistemi
PowerShell 5.1 veya üzeri
Yönetici yetkisi
Taranacak paylaşım alanına erişim yetkisi
Kullanım

PowerShell'i yönetici olarak açın ve aşağıdaki komutu çalıştırın:

.\FileServer-Detail-Report.ps1

Yapılandırma

Script çalıştırılmadan önce aşağıdaki alanlar ortamınıza göre düzenlenmelidir.

Rapor Başlığı

$HtmlReportTitle = "FIRMA-ADI - $($ServerInfo.CihazAdi) Raporu"

Taranacak Paylaşım Alanı

$RootPath = "\FILESERVER\PAYLASIM"

Rapor Klasörü

$ReportFolder = "C:\Raporlar"

Mail Gönderim Durumu

$SendMailReport = $true

SMTP Ayarları

$SmtpServer = "smtp.example.local"

$SmtpPort = 25

$MailFrom = "rapor@example.local"

Mail Alıcıları

$MailTo = @(
"alici1@example.local",
"alici2@example.local"
)

Çıktı

Script çalıştırıldıktan sonra detaylı HTML raporu oluşturulur ve isteğe bağlı olarak e-posta ile gönderilebilir.

Kullanım Detayları

Kullanım detayları ve ekran görüntüleri için aşağıdaki blog yazısını ziyaret edebilirsiniz:

https://www.ibrahimtonca.com/file-server-detayli-analiz-ve-raporlama-scripti-mail-raporlama/

Lisans

Bu proje kaynak gösterilmeden paylaşılamaz, çoğaltılamaz veya farklı platformlarda yayınlanamaz.

Scriptin kullanımı ve doğabilecek sonuçlar tamamen kullanıcının sorumluluğundadır.
