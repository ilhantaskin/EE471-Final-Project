import unittest
from fastapi.testclient import TestClient
from main import app

class TestDisasterDroneBackend(unittest.TestCase):
    def setUp(self):
        # Local test client that operates directly on the FastAPI app instance
        self.client = TestClient(app)

    def test_root_endpoint(self):
        """Tests that the root endpoint returns correct layer information."""
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["layer"], "backend1")

    def test_health_endpoint(self):
        """Verifies that the health check endpoint response structure is correct."""
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn("backend1", data)
        self.assertIn("backend2", data)

    def test_report_generation(self):
        """Tests the report generation logic and STT keyword-based instructions."""
        payload = {
            "command": "search for fire and survivors",
            "telemetry": {
                "sector": "B",
                "battery": 85,
                "altitude": 50
            },
            "analysis": {
                "risk_score": 75,
                "edge_density": 0.22,
                "brightness": 115.0,
                "contrast": 50.0
            },
            "disaster_probs": {
                "Yangin": 85.0,
                "Hasarsiz": 15.0
            }
        }
        response = self.client.post("/report", json=payload)
        self.assertEqual(response.status_code, 200)
        data = response.json()
        
        # Validate structure
        self.assertIn("report", data)
        report_text = data["report"].lower()
        
        # Verify custom actions based on voice command
        self.assertIn("fire", report_text)
        self.assertIn("survivor", report_text)
        self.assertIn("high", report_text)  # 75 risk score must map to HIGH

if __name__ == "__main__":
    unittest.main()
