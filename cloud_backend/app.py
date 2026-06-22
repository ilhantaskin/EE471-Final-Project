from fastapi import FastAPI, File, UploadFile
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import cv2
import numpy as np
import base64
import os
import json
import torch
import torchvision.transforms as transforms
from torchvision import models
from PIL import Image
import io

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ML Model yükle
with open("disaster_classes.json") as f:
    CLASSES = json.load(f)

ml_model = models.mobilenet_v2()
ml_model.classifier[1] = torch.nn.Linear(ml_model.last_channel, len(CLASSES))
ml_model.load_state_dict(torch.load("disaster_model.pth", map_location="cpu"))
ml_model.eval()

transform = transforms.Compose([
    transforms.Resize((224, 224)),
    transforms.ToTensor(),
    transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])
])

LABEL_MAP = {
    "collapsed_building": "Deprem",
    "fire": "Yangin",
    "flooded_areas": "Sel",
    "normal": "Hasarsiz",
    "traffic_incident": "Trafik",
}

SAMPLE_IMAGES = {
    "normal": {"file": "sample_images/normal.jpg", "label": "Normal Area", "description": "No damage detected"},
    "deprem": {"file": "sample_images/deprem.jpg", "label": "Earthquake Damage", "description": "Collapsed structures"},
    "sehir": {"file": "sample_images/sehir.jpg", "label": "Urban Aerial", "description": "Dense urban area"},
}

@app.get("/")
def root():
    return {"status": "ok"}

@app.get("/samples")
def get_samples():
    result = {}
    for key, info in SAMPLE_IMAGES.items():
        if os.path.exists(info["file"]):
            with open(info["file"], "rb") as f:
                data = base64.b64encode(f.read()).decode("utf-8")
            result[key] = {
                "label": info["label"],
                "description": info["description"],
                "base64": data
            }
    return result

@app.post("/analyze")
async def analyze_image(file: UploadFile = File(...)):
    contents = await file.read()
    np_arr = np.frombuffer(contents, np.uint8)
    img = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)

    if img is None:
        return JSONResponse(status_code=400, content={"error": "Goruntu okunamadi"})

    # OpenCV metrikleri
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 100, 200)
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)

    edge_density = float(np.count_nonzero(edges) / edges.size)
    brightness = float(gray.mean())
    blur_score = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    contrast = float(gray.std())

    lower_fire1 = np.array([0, 170, 170])
    upper_fire1 = np.array([18, 255, 255])
    lower_fire2 = np.array([165, 170, 170])
    upper_fire2 = np.array([180, 255, 255])
    fire_mask = cv2.inRange(hsv, lower_fire1, upper_fire1) | cv2.inRange(hsv, lower_fire2, upper_fire2)
    fire_ratio = float(np.count_nonzero(fire_mask) / fire_mask.size)

    lower_blue = np.array([90, 40, 40])
    upper_blue = np.array([130, 255, 255])
    lower_mud = np.array([15, 50, 100])
    upper_mud = np.array([25, 160, 210])
    water_mask = cv2.inRange(hsv, lower_blue, upper_blue) | cv2.inRange(hsv, lower_mud, upper_mud)
    water_ratio = float(np.count_nonzero(water_mask) / water_mask.size)

    # ML model tahmini
    pil_img = Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    tensor = transform(pil_img).unsqueeze(0)
    with torch.no_grad():
        output = ml_model(tensor)
        probs = torch.softmax(output, dim=1)[0]

    disaster_probs = {}
    for i, cls in enumerate(CLASSES):
        label = LABEL_MAP.get(cls, cls)
        disaster_probs[label] = round(probs[i].item() * 100, 1)

    top_disaster = max(disaster_probs, key=disaster_probs.get)
    top_prob = disaster_probs[top_disaster]

    # Risk skoru - ML tabanlı + OpenCV destekli
    if top_disaster == "Yangin":
        base_risk = top_prob * 0.9
        extra = min(fire_ratio * 200, 10)
        risk_score = int(min(base_risk + extra, 100))

    elif top_disaster == "Sel":
        base_risk = top_prob * 0.8
        extra = min(water_ratio * 150, 10)
        risk_score = int(min(base_risk + extra, 100))

    elif top_disaster == "Deprem":
        base_risk = top_prob * 0.85
        edge_extra = min(edge_density * 50, 10)
        risk_score = int(min(base_risk + edge_extra, 100))

    elif top_disaster == "Trafik":
        risk_score = int(top_prob * 0.6)

    else:  # Hasarsiz
        risk_score = int(max(5, top_prob * 0.1))

    risk_score = max(0, min(risk_score, 100))

    def to_base64(image):
        _, buffer = cv2.imencode(".jpg", image)
        return base64.b64encode(buffer).decode("utf-8")

    edges_colored = cv2.cvtColor(edges, cv2.COLOR_GRAY2BGR)

    return {
        "risk_score": risk_score,
        "disaster_probs": disaster_probs,
        "metrics": {
            "edge_density": round(edge_density, 4),
            "brightness": round(brightness, 2),
            "blur_score": round(blur_score, 2),
            "fire_ratio": round(fire_ratio, 4),
            "water_ratio": round(water_ratio, 4),
            "contrast": round(contrast, 2),
        },
        "images": {
            "original": to_base64(img),
            "grayscale": to_base64(gray),
            "edges": to_base64(edges_colored)
        }
    }

@app.post("/report")
async def generate_report(request: dict):
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

    # Komuta özel aksiyon
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
