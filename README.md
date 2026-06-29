# EE471 — Disaster Drone Decision Support System

> UAV tabanlı afet karar destek sistemi. Gerçek zamanlı görüntü analizi, ML tabanlı afet sınıflandırması, GPS haritası ve sesli komut desteğiyle donatılmış Flutter uygulaması.

---

## Proje Açıklaması

Bu sistem, afet bölgelerinde görev yapan İHA (drone)'lardan alınan görüntüleri analiz ederek sahaya destek sağlar. Görüntüler MobileNetV2 tabanlı ML modeli ve OpenCV ile işlenir; deprem, yangın, sel ve trafik kazası sınıflandırması yapılır. Operatöre risk skoru, hava durumu, tahliye rotası ve sesli komut arayüzü sunulur.

---

## Mimari

```
Flutter App (mobil + web)
        │
        ▼
Backend 1 — Local Orchestration (FastAPI)
  • Telemetry yönetimi
  • Sesli komut / mission report
  • /analyze isteklerini Backend 2'ye yönlendirir
        │
        ▼
Backend 2 — Cloud ML (Hugging Face Spaces)
  • OpenCV metrikleri
  • MobileNetV2 afet sınıflandırması
  • Risk skoru hesaplama
  • İşlenmiş görüntü çıktıları
```

**Cloud Backend URL:**
```
https://ilhan112-disaster-drone-api.hf.space
```

---

## Teknoloji Stack

| Katman | Teknoloji |
|---|---|
| Frontend | Flutter (Dart) |
| Harita | flutter_map + OpenStreetMap |
| Hava durumu | Open-Meteo (ücretsiz) |
| Rota | OSRM (ücretsiz) |
| Backend 1 | FastAPI + uvicorn |
| Backend 2 | FastAPI + PyTorch MobileNetV2 + OpenCV |
| Cloud | Hugging Face Spaces (Docker) |
| CI/CD | GitHub Actions |
| Containerization | Docker + Docker Compose |

---

## Kurulum ve Çalıştırma

### Backend 1 — Local (Mac/Linux)

```bash
cd backend
python3 -m venv ../.venv
source ../.venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

Backend 2 adresini değiştirmek için:
```bash
BACKEND2_URL=https://ilhan112-disaster-drone-api.hf.space uvicorn main:app --host 0.0.0.0 --port 8000
```

### Flutter Web — Local Backend ile

```bash
cd frontend/drone_app
flutter pub get
flutter run -d chrome --dart-define=BACKEND_URL=http://localhost:8000
```

### Flutter Web — Cloud Backend ile (direkt)

```bash
cd frontend/drone_app
flutter pub get
flutter run -d chrome --dart-define=BACKEND_URL=https://ilhan112-disaster-drone-api.hf.space
```

### Flutter Mobile — Android

```bash
cd frontend/drone_app
flutter pub get
flutter run --dart-define=BACKEND_URL=https://ilhan112-disaster-drone-api.hf.space
```

### Flutter Mobile — iOS (Mac + Xcode gerekir)

```bash
cd frontend/drone_app
flutter pub get
flutter run -d ios --dart-define=BACKEND_URL=https://ilhan112-disaster-drone-api.hf.space
```

> **iOS gereksinimleri:** Mac, Xcode, iOS Simulator veya fiziksel iPhone, Apple signing ayarı.

---

## Docker ile Çalıştırma

```bash
# Proje kökünde
docker compose up --build
```

Backend 1 `http://localhost:8000` adresinde ayağa kalkar.

Test:
```bash
curl http://localhost:8000/
# {"status":"ok","layer":"backend1","cloud_backend":"https://ilhan112-disaster-drone-api.hf.space"}
```

---

## API Endpoints

### Backend 1 (Local — port 8000)

| Method | Endpoint | Açıklama |
|---|---|---|
| `GET` | `/` | Sağlık kontrolü |
| `GET` | `/health` | Backend 1 + Backend 2 sağlık durumu |
| `GET` | `/samples` | Örnek görselleri Backend 2'den proxy'ler |
| `POST` | `/analyze` | Görüntüyü Backend 2'ye iletir, sonucu döndürür |
| `POST` | `/report` | Mission report üretir |

### Backend 2 (Cloud — Hugging Face)

| Method | Endpoint | Açıklama |
|---|---|---|
| `GET` | `/` | Sağlık kontrolü |
| `GET` | `/samples` | Örnek görsel görseller (base64) |
| `POST` | `/analyze` | ML + OpenCV analizi, risk skoru |
| `POST` | `/report` | Mission report |

**`POST /analyze` örnek yanıt:**
```json
{
  "risk_score": 72,
  "disaster_probs": {
    "Deprem": 85.3,
    "Hasarsiz": 10.1,
    "Yangin": 3.2,
    "Sel": 1.0,
    "Trafik": 0.4
  },
  "metrics": {
    "edge_density": 0.1823,
    "brightness": 112.4,
    "blur_score": 340.2,
    "fire_ratio": 0.0021,
    "water_ratio": 0.0015,
    "contrast": 48.7
  },
  "images": {
    "original": "<base64>",
    "grayscale": "<base64>",
    "edges": "<base64>"
  }
}
```

---

## CI/CD

GitHub Actions ile otomatik test:

| Workflow | Tetikleyici | Yapılanlar |
|---|---|---|
| `backend.yml` | `backend/` değişikliği | Python 3.11, pip install, import test, smoke test |
| `flutter.yml` | `frontend/` değişikliği | Flutter stable, pub get, analyze, web build |

Workflow durumunu GitHub → Actions sekmesinden takip edebilirsiniz.

---

## Test Görselleri

Backend `sample_images/` klasöründe demo görseller bulunur:

| Anahtar | Açıklama |
|---|---|
| `normal` | Hasarsız alan |
| `deprem` | Çökmüş yapı |
| `sehir` | Kentsel havadan görüntü |

---

## Takım Üyeleri

- <!-- İsim 1 -->
- <!-- İsim 2 -->
- <!-- İsim 3 -->
- <!-- İsim 4 -->

EE471 — Bilkent Üniversitesi

---

## GitHub

```
https://github.com/ilhantaskin/EE471-Final-Project
```
