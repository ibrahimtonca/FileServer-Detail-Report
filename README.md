# File Server Detaylı Analiz ve Raporlama Scripti

Dosya sunucularında depolama alanlarının, klasör yapılarının ve dosya dağılımlarının düzenli olarak analiz edilmesi hem kapasite planlaması hem de veri yönetimi açısından büyük önem taşımaktadır. Bu amaçla hazırladığım PowerShell scripti, File Server ortamlarını detaylı şekilde analiz ederek kapsamlı bir HTML raporu oluşturmaktadır.

Zaman içerisinde dosya sunucularında gereksiz büyüme, eski dosya birikimi, boş klasörler, büyük boyutlu dosyalar ve erişim yönetimi ile ilgili çeşitli problemler oluşabilmektedir. Bu bilgilerin manuel olarak takip edilmesi oldukça zaman alıcıdır. Bu script sayesinde tüm bu veriler tek bir rapor altında toplanarak daha kolay analiz edilebilir hale gelmektedir.

Script çalıştırıldığında belirtilen paylaşım alanını tarar, dosya ve klasör yapılarını analiz eder, kapasite bilgilerini toplar ve sonuçları HTML formatında raporlar. İsteğe bağlı olarak oluşturulan rapor e-posta ile ilgili kişilere otomatik olarak gönderilebilir.

Bu script ile genel olarak aşağıdaki raporları alabiliyoruz:

* Genel durum özeti raporu
* Disk kapasite ve kullanım raporu
* Ana klasör ve birinci seviye klasör yetki raporu
* En büyük klasörler raporu
* En büyük dosyalar raporu
* Boş klasörler raporu
* Boş dosyalar raporu
* Uzantıya göre dosya dağılımı raporu
* Kategori bazlı dosya özeti raporu
* Son değiştirilen dosyalar raporu
* Eski dosyalar raporu
* Uzun yol uyarısı raporu
* Aynı isimli dosya analizi raporu
* Aylık değişiklik aktivitesi raporu
* En derin klasörler raporu
* HTML mail raporu

Bu script Windows PowerShell 5.1 üzerinde hazırlanmıştır. Windows Server ve Windows istemci işletim sistemlerinde kullanılabilir. PowerShell 7 üzerinde kullanılacaksa uyumluluk testlerinin ayrıca yapılması önerilir.

Kullanım detayları için blog yazısını ziyaret edebilirsiniz:

https://www.ibrahimtonca.com/file-server-detayli-analiz-ve-raporlama-scripti-mail-raporlama/
