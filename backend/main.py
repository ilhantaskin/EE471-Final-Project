"""
EE471 Disaster Drone Decision Support System
Backend 1 — Local Orchestration Layer

Mimari:
    Flutter App
        |
        v
    Backend 1 (bu dosya) — telemetry, ses komutu, mission report yönetir
        |
        v
    Backend 2 (Cloud — Hugging Face) — ML + OpenCV + risk score yapar

Backend 1 görevleri:
  - /analyze: görüntüyü Backend 2'ye iletir, sonucu Flutter'a döndürür
  - /report:  mission report üretir (sesli komut + telemetri + analiz birleşimi)
  - /health:  iki backend'in sağlık durumunu raporlar
  - /samples: Backend 2'den örnek görselleri proxy'ler
"""

from fastapi import FastAPI, File, UploadFile
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import httpx
import os
import json

app = FastAPI(
    title="EE471 Disaster Drone — Backend 1",
    description="Local orchestration layer. Forwards image analysis to the cloud ML backend.",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Backend 2 (cloud) adresi — ortam değişkeniyle override edilebilir
BACKEND2_URL = os.environ.get(
    "BACKEND2_URL",
    "https://ilhan112-disaster-drone-api.hf.space",
)

# Backend 2'ye istek atarken kullanılacak timeout (saniye)
CLOUD_TIMEOUT = 30.0


# ──────────────────────────────────────────────────────────────────────────────
# Root
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/")
def root():
    """Backend 1 sağlık kontrolü."""
    return {"status": "ok", "layer": "backend1", "cloud_backend": BACKEND2_URL}


# ──────────────────────────────────────────────────────────────────────────────
# Health — her iki backend'in durumunu raporla
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    """Backend 1 ve Backend 2'nin anlık sağlık durumunu döndürür."""
    b2_status = "unknown"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{BACKEND2_URL}/")
            b2_status = "ok" if r.status_code == 200 else f"http_{r.status_code}"
    except Exception as exc:
        b2_status = f"unreachable ({exc})"

    return {
        "backend1": "ok",
        "backend2": b2_status,
        "backend2_url": BACKEND2_URL,
    }


# ──────────────────────────────────────────────────────────────────────────────
# Samples — Backend 2'den proxy
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/samples")
async def get_samples():
    """
    Backend 2'deki örnek görselleri Flutter'a proxy'ler.
    Backend 2 erişilemezse boş dict döner (Flutter bunu tolere ediyor).
    """
    try:
        async with httpx.AsyncClient(timeout=CLOUD_TIMEOUT) as client:
            r = await client.get(f"{BACKEND2_URL}/samples")
            if r.status_code == 200:
                return r.json()
    except Exception:
        pass
    return {}


# ──────────────────────────────────────────────────────────────────────────────
# Analyze — görüntüyü Backend 2'ye ilet, sonucu döndür
# ──────────────────────────────────────────────────────────────────────────────

@app.post("/analyze")
async def analyze_image(file: UploadFile = File(...)):
    """
    Flutter'dan gelen görüntüyü Backend 2 (Cloud ML) katmanına iletir.
    Backend 2; OpenCV metrikleri, MobileNetV2 sınıflandırması ve risk skoru döndürür.
    Backend 1 bu sonucu değiştirmeden Flutter'a iletir.
    """
    try:
        contents = await file.read()
        async with httpx.AsyncClient(timeout=CLOUD_TIMEOUT) as client:
            response = await client.post(
                f"{BACKEND2_URL}/analyze",
                files={"file": (file.filename or "image.jpg", contents, "image/jpeg")},
            )
        if response.status_code == 200:
            return response.json()
        return JSONResponse(
            status_code=response.status_code,
            content={"error": f"Backend 2 returned {response.status_code}"},
        )
    except httpx.TimeoutException:
        return JSONResponse(
            status_code=504,
            content={"error": "Backend 2 (cloud) timeout. Check Hugging Face Space status."},
        )
    except Exception as exc:
        return JSONResponse(
            status_code=502,
            content={"error": f"Backend 2 unreachable: {exc}"},
        )


# ──────────────────────────────────────────────────────────────────────────────
# Report — mission report üret (Backend 1'de işlenir)
# ──────────────────────────────────────────────────────────────────────────────

@app.post("/report")
async def generate_report(request: dict):
    """
    Sesli komut, telemetri ve analiz sonuçlarını birleştirerek mission report üretir.
    Bu endpoint Backend 1'de çalışır; Backend 2'ye bağımlılığı yoktur.
    """
    stt_text = request.get("command", "")
    telemetry = request.get("telemetry", {})
    analysis = request.get("analysis", {})
    disaster_probs = request.get("disaster_probs", {})

    risk = analysis.get("risk_score", 0)
    sector = telemetry.get("sector", "Unknown")
    battery = telemetry.get("battery", 0)
    altitude = telemetry.get("altitude", 0)

    if risk >= 60:
        level = "HIGH"
        action = "Immediate rescue team deployment required. Prioritize search operations."
    elif risk >= 30:
        level = "MEDIUM"
        action = "Proceed with caution. Secondary team on standby."
    else:
        level = "LOW"
        action = "Area appears stable. Continue monitoring."

    # Sesli komuta özel aksiyon ekle
    cmd_lower = stt_text.lower()
    if "survivor" in cmd_lower or "rescue" in cmd_lower:
        action += " Focus on survivor detection and extraction."
    if "flood" in cmd_lower or "water" in cmd_lower:
        action += " Monitor water levels and evacuation routes."
    if "fire" in cmd_lower or "smoke" in cmd_lower:
        action += " Coordinate with fire response units immediately."
    if "building" in cmd_lower or "collapse" in cmd_lower:
        action += " Structural assessment team required."

    if disaster_probs:
        top_disaster = max(disaster_probs, key=disaster_probs.get)
        top_prob = disaster_probs[top_disaster]
        disaster_line = f"Probable disaster type: {top_disaster} ({top_prob}%). "
    else:
        disaster_line = ""

    report = (
        f"Sector {sector} risk assessment: {level} (score: {risk}/100). "
        f"Drone telemetry nominal - altitude {altitude}m, battery {battery}%. "
        f"{disaster_line}"
        f"Image analysis: edge density {analysis.get('edge_density')}, "
        f"brightness {analysis.get('brightness')}, contrast {analysis.get('contrast')}. "
        f"Operator command: '{stt_text}'. "
        f"{action}"
    )

    return {"report": report, "disaster_probs": disaster_probs}
