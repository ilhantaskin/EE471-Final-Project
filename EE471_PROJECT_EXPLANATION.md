# 🚁 EE471 Disaster Drone Decision Support System (Afet Karar Destek Sistemi)

Bu proje, afet bölgelerinde (deprem, yangın, sel, trafik kazaları) görev yapan İHA (drone) sistemlerinden gelen verileri analiz ederek, arama-kurtarma ekiplerine gerçek zamanlı rota, risk ve afet türü bilgisi sağlayan **Yapay Zeka Destekli bir Karar Destek Sistemi**'dir.

---

## 1. Sistem Mimarisi ve Veri Akışı

Proje, akademik teklife (proposal) uygun olarak **3 katmanlı** ve dağıtık bir yapıda çalışmaktadır:

```
[📱 Flutter Mobil/Web Uygulaması] 
        │
        │ 1. Fotoğraf + Telemetri + Ses
        ▼
[🖥️ Backend 1: Local Orchestration (FastAPI)] 
        │
        │ 2. Fotoğrafı İletir
        ▼
[☁️ Backend 2: Cloud ML Backend (Hugging Face)] 
        │
        │ 3. Yapay Zeka + OpenCV Analizi
        ▼
[🖥️ Backend 1: Local Orchestration] 
        │
        │ 4. Sonuçları Birleştirir & Rapor Üretir
        ▼
[📱 Flutter Mobil/Web Uygulaması]
```

### Katmanların Görevleri:
1. **📱 Frontend (Flutter App):** Operatörün kullandığı arayüzdür. Harita, canlı telemetri simülasyonu, sesli komut alıcısı ve görsel analiz ekranlarını içerir.
2. **🖥️ Katman 1 (Backend 1 - Local FastAPI):** Operatör ile bulut arasında bir orkestrasyon katmanıdır. Telemetriyi yönetir, sesli komutları yorumlar ve nihai **Mission Report (Görev Raporu)** çıktısını üretir.
3. **☁️ Katman 2 (Backend 2 - Cloud ML Hugging Face):** İşlem gücü yüksek olan yapay zeka katmanıdır. Görüntüyü alır, derin öğrenme modeli (MobileNetV2) ve OpenCV algoritmalarıyla analiz edip risk skoru üretir.

---

## 2. Teknik Özellikler ve Yapay Zeka Detayları

### A. Yapay Zeka ve Görüntü Sınıflandırma
Sistemde kullanılan **MobileNetV2** modeli, hava fotoğraflarından afet tespiti yapmak üzere eğitilmiştir ve şu sınıfları ayırt eder:
* **Deprem (Collapsed Building):** Çökmüş binaları ve enkaz alanlarını tespit eder.
* **Yangin (Fire):** Alev ve yoğun duman içeren bölgeleri algılar.
* **Sel (Flooded Areas):** Su birikintilerini ve çamurlu su havzalarını bulur.
* **Trafik (Traffic Incident):** Yol üzerindeki kaza ve tıkanıklıkları tespit eder.
* **Hasarsiz (Normal):** Herhangi bir afet belirtisi olmayan stabil bölgeleri raporlar.

### B. OpenCV Destekli Hibrit Risk Skoru
Sadece yapay zekaya güvenilmemiş, OpenCV görüntü işleme metrikleriyle risk skoru desteklenmiştir:
* **Kenar Yoğunluğu (Edge Density):** Enkazlardaki düzensiz hatları bulmak için deprem analizinde kullanılır.
* **HSV Renk Maskeleme (Fire/Water Ratios):** Yangındaki kırmızı/turuncu pikselleri ve seldeki mavi/çamur rengi pikselleri oranlayarak risk skoruna ek puan ekler.
* **Lapis Filtresi (Blur Score):** Drone kamerasının sarsıntı durumunu (bulanıklık) ölçer.

---

## 3. Coğrafi Karar Destek Arayüzü (Digital Twin)

Uygulamanın harita arayüzü Google Maps yerine **ücretsiz OpenStreetMap** altyapısıyla çalışır ve şu dinamik modelleri barındırır:
* **Risk Çemberi:** Afetin şiddetine göre (risk skoru 0-100 arası) haritada dinamik bir risk yarıçapı çizer.
* **Afet Yayılım Alanı (Poligon):** Rüzgar yönüne göre (yangın durumunda) veya coğrafi eğime göre (sel durumunda) afetin yayılacağı muhtemel alanı haritada boyayarak gösterir.
* **Güvenli Bölge Tahliye Rotası:** OSRM (Open Source Routing Machine) kullanarak afet çemberinin dışında kalan en yakın güvenli bölgeye otomatik tahliye rotası çizer.
* **Hava Durumu Telemetrisi:** Open-Meteo entegrasyonu ile drone'un bulunduğu konumun rüzgar hızını, yönünü, sıcaklığını ve görüş mesafesini canlı olarak çeker.

---

## 4. Sesli Komut (Voice Control) Sistemi

Operatör, mikrofona basılı tutarak İngilizce sesli komutlar verebilir:
* **Sektör Geçişi:** `"switch to sector B"` dediğinde drone'un telemetrisindeki aktif arama sektörü B olarak güncellenir.
* **Akıllı Raporlama:** `"analyze collapsed building"` dediğinde analiz tetiklenir ve üretilen raporda enkaz ekibine özel yönlendirme talimatları eklenir.

---

## 5. Docker ve CI/CD Altyapısı (Bugün Eklenenler)

### 🐳 Dockerize Backend
Projenin çalıştırılmasını kolaylaştırmak için yerel backend Dockerize edildi:
* **`Dockerfile`:** `python:3.11-slim` tabanında, gereksiz bağımlılıklar arındırılarak hazırlandı.
* **`docker-compose.yml`:** Tek bir `docker compose up --build` komutuyla yerel sunucuyu `8000:8000` portundan ayağa kaldırır.

### ⚙️ GitHub Actions (CI/CD) ve Otomatik Versiyonlama
* **`backend.yml`:** Backend kodlarında hata olup olmadığını her push işleminde test eder.
* **`flutter.yml`:** Flutter projesinin bütünlüğünü tarar ve web build'ini alır. Her başarılı derlemede build numarasını otomatik artırır (Örn: `1.0.0+1`, `1.0.0+2`).
* **`release.yml`:** Proje tamamlandığında `git tag v1.1.0` gibi bir etiket atıldığında otomatik olarak dökümantasyonu ve stabil sürümü paketler.

---

## 6. Projeyi Çalıştırma Adımları

### 🌐 Web Tarayıcısında Çalıştırma
```bash
cd frontend/drone_app
flutter pub get
flutter run -d chrome --dart-define=BACKEND_URL=https://ilhan112-disaster-drone-api.hf.space
```

### 📱 iOS Cihazda (iPhone) Çalıştırma
1. **İmzalama:** Xcode'da `Runner.xcworkspace` projesini açın ➔ `Signing & Capabilities` sekmesinden Apple ID'nizi `Team` olarak seçin ➔ `Bundle Identifier` kısmını benzersiz yapın.
2. **Güvenme:** Telefonunuzu USB ile bağlayıp şu komutu çalıştırın:
```bash
flutter run --release -d <iPhone_Cihaz_Kodu> --dart-define=BACKEND_URL=https://ilhan112-disaster-drone-api.hf.space
```
3. **Onaylama:** Yükleme bittikten sonra iPhone'da `Ayarlar ➔ Genel ➔ VPN ve Cihaz Yönetimi` adımlarından profilinizi onaylayın.
