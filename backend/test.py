import requests
import json

with open("sample_images/normal.jpg", "rb") as f:
    response = requests.post(
        "http://localhost:8000/analyze",
        files={"file": f}
    )

result = response.json()
print("Risk Skoru:", result["risk_score"])
print("Metrikler:", json.dumps(result["metrics"], indent=2))
print("Görüntüler döndürüldü:", list(result["images"].keys()))
