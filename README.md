# EE471 Disaster Drone Decision Support System

Flutter + FastAPI based disaster drone decision support prototype.

## Run With Docker

```bash
docker compose up --build
```

Then open:

- Backend API: http://localhost:8000

The Flutter web/mobile app is run separately and points to the backend URL.

For a physical mobile device on the same Wi-Fi, run the Flutter app with your PC IP:

```bash
flutter run --dart-define=BACKEND_URL=http://YOUR_PC_IP:8000
```

## Local Backend

```powershell
cd backend
..\.venv\Scripts\python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

## Local Flutter

```powershell
cd frontend\drone_app
$env:PUB_CACHE='C:\pro1\.pub-cache'
flutter run -d chrome --web-browser-flag "--disable-web-security"
```
