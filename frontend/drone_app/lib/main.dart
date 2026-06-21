import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'dart:convert';
import 'dart:async';

import 'location_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drone Tactical System',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF050A05),
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: 'monospace',
        ),
      ),
      home: const DronePanel(),
    );
  }
}

class DronePanel extends StatefulWidget {
  const DronePanel({super.key});
  @override
  State<DronePanel> createState() => _DronePanelState();
}

class _DronePanelState extends State<DronePanel> {
  final SpeechToText _speech = SpeechToText();
  final MapController _mapController = MapController();
  final Distance _distance = const Distance();
  String _command = '';
  String _report = '';
  String _status = 'SYSTEM READY';
  bool _isListening = false;
  bool _isLoading = false;
  String? _originalBase64;
  String? _grayscaleBase64;
  String? _edgesBase64;
  String? _fileName;
  int _riskScore = 0;
  Map<String, dynamic> _disasterProbs = {};
  Map<String, dynamic> _samples = {};
  Timer? _telemetryTimer;
  Timer? _batteryTimer;
  bool _blink = true;
  bool _isWeatherLoading = false;
  bool _isLocating = false;
  bool _mapPickEnabled = false;
  bool _isRouteLoading = false;
  LatLng _incidentPoint = const LatLng(38.4237, 27.1428);
  LatLng _safeZonePoint = const LatLng(38.4310, 27.1540);
  List<LatLng> _osrmRoute = [];
  DateTime? _lastRouteRequest;
  Map<String, dynamic> _weather = {};
  String _weatherSource = 'SIMULATED';
  String _locationSource = 'DEFAULT';
  String _routeSource = 'STANDBY';

  final Map<String, dynamic> _telemetry = {
    'altitude': 45,
    'battery': 78,
    'sector': 'B',
    'speed': 12,
  };

  final String _backendUrl = 'http://localhost:8000';

  static const Color milGreen = Color(0xFF4ADE80);
  static const Color milGreenDark = Color(0xFF166534);
  static const Color milGreenMid = Color(0xFF22C55E);
  static const Color milBg = Color(0xFF050A05);
  static const Color milBgCard = Color(0xFF0A150A);
  static const Color milBorder = Color(0xFF1A4A1A);
  static const Color milRed = Color(0xFFEF4444);
  static const Color milAmber = Color(0xFFFACC15);
  static const Color milText = Color(0xFF4A7A4A);

  @override
  void initState() {
    super.initState();
    _loadSamples();
    _loadWeather();
    _startTelemetrySimulation();
    Timer.periodic(const Duration(milliseconds: 800), (t) {
      setState(() => _blink = !_blink);
    });
  }

  void _startTelemetrySimulation() {
    _telemetryTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      setState(() {
        _telemetry['altitude'] = 40 + (DateTime.now().second % 20);
        _telemetry['speed'] = 8 + (DateTime.now().second % 8);
      });
    });
    _batteryTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      setState(() {
        if (_telemetry['battery'] > 10) {
          _telemetry['battery'] = (_telemetry['battery'] as int) - 1;
        }
      });
    });
  }

  @override
  void dispose() {
    _telemetryTimer?.cancel();
    _batteryTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSamples() async {
    try {
      final response = await http.get(Uri.parse('$_backendUrl/samples'));
      if (response.statusCode == 200) {
        setState(() => _samples = json.decode(response.body));
      }
    } catch (e) {
      // Sample imagery is optional when the backend is offline.
    }
  }

  String _topDisaster() {
    if (_disasterProbs.isEmpty) return 'Hasarsiz';
    final sorted = _disasterProbs.entries.toList()
      ..sort((a, b) => (b.value as num).compareTo(a.value as num));
    return sorted.first.key.toString();
  }

  double _numWeather(String key, double fallback) {
    final value = _weather[key];
    if (value is num) return value.toDouble();
    return fallback;
  }

  Future<void> _loadWeather({bool simulationOnly = false}) async {
    setState(() => _isWeatherLoading = true);

    if (!simulationOnly) {
      try {
        final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
          'latitude': _incidentPoint.latitude.toStringAsFixed(5),
          'longitude': _incidentPoint.longitude.toStringAsFixed(5),
          'current': 'temperature_2m,relative_humidity_2m,wind_speed_10m,wind_direction_10m,precipitation,visibility',
          'wind_speed_unit': 'kmh',
          'timezone': 'auto',
        });
        final response = await http.get(uri).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final data = json.decode(response.body) as Map<String, dynamic>;
          final current = data['current'] as Map<String, dynamic>;
          setState(() {
            _weather = {
              'temperature': current['temperature_2m'],
              'humidity': current['relative_humidity_2m'],
              'windSpeed': current['wind_speed_10m'],
              'windDirection': current['wind_direction_10m'],
              'precipitation': current['precipitation'],
              'visibility': current['visibility'],
            };
            _weatherSource = 'OPEN-METEO';
            _safeZonePoint = _autoSafeZone();
            _isWeatherLoading = false;
          });
          await _refreshRoute();
          return;
        }
      } catch (e) {
        // Live weather is optional; the mission panel falls back to simulation.
      }
    }

    setState(() {
      _weather = _simulatedWeather();
      _weatherSource = 'SIMULATED';
      _safeZonePoint = _autoSafeZone();
      _isWeatherLoading = false;
    });
    await _refreshRoute();
  }

  Map<String, dynamic> _simulatedWeather() {
    final disaster = _topDisaster();
    final minute = DateTime.now().minute;
    final windDirection = [45.0, 90.0, 135.0, 180.0, 225.0, 270.0][minute % 6];

    if (disaster == 'Yangin') {
      return {
        'temperature': 34 + (minute % 5),
        'humidity': 22 + (minute % 8),
        'windSpeed': 18 + (minute % 12),
        'windDirection': windDirection,
        'precipitation': 0,
        'visibility': 5200,
      };
    }
    if (disaster == 'Sel') {
      return {
        'temperature': 19 + (minute % 4),
        'humidity': 82 + (minute % 10),
        'windSpeed': 10 + (minute % 8),
        'windDirection': windDirection,
        'precipitation': 18 + (minute % 12),
        'visibility': 3400,
      };
    }
    if (disaster == 'Deprem') {
      return {
        'temperature': 25 + (minute % 5),
        'humidity': 46 + (minute % 15),
        'windSpeed': 8 + (minute % 8),
        'windDirection': windDirection,
        'precipitation': 0,
        'visibility': 6800,
      };
    }
    return {
      'temperature': 24 + (minute % 4),
      'humidity': 50 + (minute % 12),
      'windSpeed': 7 + (minute % 7),
      'windDirection': windDirection,
      'precipitation': 0,
      'visibility': 9000,
    };
  }

  void _setIncidentPoint(LatLng point) {
    if (!_mapPickEnabled) {
      setState(() => _status = 'GPS LOCKED // MAP PICK DISABLED');
      return;
    }
    setState(() {
      _incidentPoint = point;
      _safeZonePoint = _autoSafeZone();
      _locationSource = 'MAP PICK';
      _status = 'INCIDENT LOCATION UPDATED';
    });
    _loadWeather();
  }

  Future<void> _useDeviceLocation() async {
    setState(() {
      _isLocating = true;
      _status = 'REQUESTING DEVICE GPS...';
    });

    try {
      final point = await getDeviceLocation();
      if (point == null) {
        setState(() {
          _isLocating = false;
          _locationSource = 'UNAVAILABLE';
          _status = 'GPS UNAVAILABLE // MAP PICK ACTIVE';
        });
        return;
      }

      setState(() {
        _incidentPoint = point;
        _safeZonePoint = _autoSafeZone();
        _locationSource = 'DEVICE GPS';
        _mapPickEnabled = false;
        _isLocating = false;
        _status = 'DEVICE GPS LOCKED';
      });
      _mapController.move(point, 15);
      await _loadWeather();
    } catch (e) {
      setState(() {
        _isLocating = false;
        _locationSource = 'DENIED';
        _status = 'GPS DENIED // MAP PICK ACTIVE';
      });
    }
  }

  double _riskRadiusMeters() {
    return (220 + (_riskScore * 8)).clamp(260, 1150).toDouble();
  }

  bool _hasActiveThreat() {
    return _riskScore >= 30 && _topDisaster() != 'Hasarsiz';
  }

  Color _threatColorFor(String label, bool isTop) {
    if (label == 'Hasarsiz') return isTop ? milGreenMid : milGreenDark;
    if (!isTop) return milGreenDark;
    return _riskColor();
  }

  Color _mapThreatFillColor() {
    final disaster = _topDisaster();
    if (disaster == 'Sel') return const Color(0xFF38BDF8);
    if (disaster == 'Deprem') return const Color(0xFFF97316);
    return milAmber;
  }

  String _mapModelLabel() {
    final disaster = _topDisaster();
    if (!_hasActiveThreat()) return 'NO ACTIVE SPREAD';
    if (disaster == 'Sel') return 'FLOOD BASIN';
    if (disaster == 'Deprem') return 'IMPACT ZONE';
    return 'WIND SPREAD ${_spreadBearing().toStringAsFixed(0)} DEG';
  }

  String _environmentDriverLabel() {
    final disaster = _topDisaster();
    if (disaster == 'Sel') {
      final rainfall = _numWeather('precipitation', 0);
      final modelRainfall = rainfall < 5 ? 24.0 : rainfall;
      return 'FLOOD RAIN ${modelRainfall.toStringAsFixed(1)} MM';
    }
    if (disaster == 'Deprem') return 'IMPACT RADIUS';
    return 'WIND ${_numWeather('windSpeed', 0).toStringAsFixed(1)} KMH';
  }

  double _spreadBearing() {
    final windDirection = _numWeather('windDirection', 90);
    if (_topDisaster() == 'Sel') {
      return 180;
    }
    return windDirection % 360;
  }

  LatLng _autoSafeZone() {
    if (_topDisaster() == 'Sel') {
      return _distance.offset(_incidentPoint, _riskRadiusMeters() + 1650, 285);
    }
    final evacuationBearing = (_spreadBearing() + 155) % 360;
    return _distance.offset(_incidentPoint, _riskRadiusMeters() + 950, evacuationBearing);
  }

  List<LatLng> _spreadPolygon() {
    final disaster = _topDisaster();
    if (disaster == 'Deprem') {
      return [];
    }
    final multiplier = disaster == 'Yangin'
        ? 2.0
        : disaster == 'Sel'
            ? 1.35
            : 1.05;
    final distance = _riskRadiusMeters() * multiplier;
    final bearing = _spreadBearing();
    if (disaster == 'Sel') {
      return [
        _distance.offset(_incidentPoint, distance * 0.70, bearing - 58),
        _distance.offset(_incidentPoint, distance * 1.05, bearing - 22),
        _distance.offset(_incidentPoint, distance * 1.15, bearing + 18),
        _distance.offset(_incidentPoint, distance * 0.72, bearing + 56),
        _distance.offset(_incidentPoint, distance * 0.30, bearing + 96),
        _distance.offset(_incidentPoint, distance * 0.24, bearing - 104),
      ];
    }
    return [
      _incidentPoint,
      _distance.offset(_incidentPoint, distance * 0.72, bearing - 26),
      _distance.offset(_incidentPoint, distance, bearing),
      _distance.offset(_incidentPoint, distance * 0.72, bearing + 26),
    ];
  }

  List<LatLng> _evacuationRoute() {
    if (_osrmRoute.isNotEmpty) return _osrmRoute;
    return _fallbackEvacuationRoute();
  }

  List<LatLng> _fallbackEvacuationRoute() {
    if (_topDisaster() == 'Sel') {
      final highGround = _distance.offset(_incidentPoint, _riskRadiusMeters() + 620, 265);
      final ridgeLine = _distance.offset(_incidentPoint, _riskRadiusMeters() + 1120, 292);
      return [_incidentPoint, highGround, ridgeLine, _safeZonePoint];
    }
    final awayBearing = (_spreadBearing() + 180) % 360;
    final firstLeg = _distance.offset(_incidentPoint, _riskRadiusMeters() + 260, awayBearing);
    final bypass = _distance.offset(firstLeg, 420, awayBearing + 35);
    return [_incidentPoint, firstLeg, bypass, _safeZonePoint];
  }

  bool _isPointInsidePolygon(LatLng point, List<LatLng> polygon) {
    var inside = false;
    var j = polygon.length - 1;
    for (var i = 0; i < polygon.length; i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;
      final denominator = (yj - yi).abs() < 0.000001 ? 0.000001 : yj - yi;
      final crosses = ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude < (xj - xi) * (point.latitude - yi) / denominator + xi);
      if (crosses) inside = !inside;
      j = i;
    }
    return inside;
  }

  double _routeDistanceMeters(List<LatLng> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += _distance(points[i - 1], points[i]);
    }
    return total;
  }

  double _routeRiskScore(List<LatLng> points) {
    final riskRadius = _riskRadiusMeters();
    final spreadZone = _spreadPolygon();
    var score = _routeDistanceMeters(points) / 1000;

    for (final point in points) {
      if (_distance(_incidentPoint, point) < riskRadius) score += 80;
      if (_isPointInsidePolygon(point, spreadZone)) score += _topDisaster() == 'Sel' ? 130 : 90;
    }

    return score;
  }

  Future<void> _refreshRoute() async {
    if (!_hasActiveThreat()) {
      setState(() {
        _osrmRoute = [];
        _routeSource = 'STANDBY';
        _isRouteLoading = false;
      });
      return;
    }

    if (_topDisaster() == 'Sel') {
      setState(() {
        _osrmRoute = [];
        _routeSource = 'HIGH GROUND CORRIDOR';
        _isRouteLoading = false;
      });
      return;
    }

    final now = DateTime.now();
    final last = _lastRouteRequest;
    if (last != null && now.difference(last).inMilliseconds < 1200) {
      await Future.delayed(Duration(milliseconds: 1200 - now.difference(last).inMilliseconds));
    }
    _lastRouteRequest = DateTime.now();

    setState(() {
      _isRouteLoading = true;
      _routeSource = 'OSRM...';
    });

    try {
      final coords = '${_incidentPoint.longitude.toStringAsFixed(6)},${_incidentPoint.latitude.toStringAsFixed(6)};'
          '${_safeZonePoint.longitude.toStringAsFixed(6)},${_safeZonePoint.latitude.toStringAsFixed(6)}';
      final uri = Uri.https('router.project-osrm.org', '/route/v1/driving/$coords', {
        'overview': 'full',
        'geometries': 'geojson',
        'alternatives': 'true',
        'steps': 'false',
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 7));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final routes = data['routes'] as List<dynamic>;
        if (routes.isNotEmpty) {
          List<LatLng> bestRoute = [];
          var bestScore = double.infinity;

          for (final route in routes) {
            final geometry = route['geometry'] as Map<String, dynamic>;
            final coordinates = geometry['coordinates'] as List<dynamic>;
            final points = coordinates.map((item) {
              final pair = item as List<dynamic>;
              return LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble());
            }).toList();
            final score = _routeRiskScore(points);
            if (points.length >= 2 && score < bestScore) {
              bestRoute = points;
              bestScore = score;
            }
          }

          if (bestRoute.isNotEmpty) {
            setState(() {
              _osrmRoute = bestRoute;
              _routeSource = 'OSRM SAFE ROAD';
              _isRouteLoading = false;
            });
            return;
          }
        }
      }
    } catch (e) {
      // Public OSRM is optional; fallback corridor keeps the demo available.
    }

    setState(() {
      _osrmRoute = [];
      _routeSource = 'FALLBACK CORRIDOR';
      _isRouteLoading = false;
    });
  }

  List<LatLng> _blockedRoadPoints(double bearingShift) {
    final center = _distance.offset(_incidentPoint, _riskRadiusMeters() * 0.72, _spreadBearing() + bearingShift);
    return [
      _distance.offset(center, 120, _spreadBearing() + bearingShift + 85),
      _distance.offset(center, 120, _spreadBearing() + bearingShift - 85),
    ];
  }

  String _geoActionLine() {
    final disaster = _topDisaster().toUpperCase();
    final windSpeed = _numWeather('windSpeed', 0).toStringAsFixed(1);
    final windDirection = _numWeather('windDirection', 0).toStringAsFixed(0);
    final lat = _incidentPoint.latitude.toStringAsFixed(5);
    final lng = _incidentPoint.longitude.toStringAsFixed(5);
    if (!_hasActiveThreat()) {
      return 'Geo decision support: incident mapped at $lat,$lng. '
          'No active spread model is triggered because current risk is low. '
          'Continue patrol and keep safe zone route on standby.';
    }
    if (_topDisaster() == 'Sel') {
      return 'Geo decision support: incident mapped at $lat,$lng. '
          'Flood model uses rainfall, humidity and terrain basin assumptions from $_weatherSource telemetry. '
          'Evacuation corridor is routed toward inland high ground away from low-lying flood accumulation zones.';
    }
    if (_topDisaster() == 'Deprem') {
      return 'Geo decision support: incident mapped at $lat,$lng. '
          'Earthquake model uses impact radius and blocked-road assumptions. '
          'Evacuation corridor is routed toward the nearest safe zone outside structural-risk radius.';
    }
    return 'Geo decision support: incident mapped at $lat,$lng. '
        '$disaster spread model uses $_weatherSource weather telemetry; wind $windSpeed km/h at $windDirection degrees. '
        'Evacuation corridor is routed away from predicted spread toward safe zone.';
  }

  void _selectSample(String key) {
    final sample = _samples[key];
    if (sample != null) {
      setState(() {
        _originalBase64 = sample['base64'];
        _fileName = sample['label'];
        _grayscaleBase64 = null;
        _edgesBase64 = null;
        _report = '';
        _riskScore = 0;
        _disasterProbs = {};
        _status = '${sample['label']} LOADED';
      });
    }
  }

  Future<void> _startListening() async {
    bool available = await _speech.initialize();
    if (available) {
      setState(() => _isListening = true);
      _speech.listen(
        onResult: (result) {
          setState(() => _command = result.recognizedWords);
        },
      );
    }
  }

  void _stopListening() {
    _speech.stop();
    setState(() => _isListening = false);
    if (_command.isNotEmpty) {
      _processCommand(_command);
    }
  }

  void _processCommand(String command) {
    final cmd = command.toLowerCase();
    if (cmd.contains('sector a') || cmd.contains('switch a')) {
      setState(() => _telemetry['sector'] = 'A');
    } else if (cmd.contains('sector b') || cmd.contains('switch b')) {
      setState(() => _telemetry['sector'] = 'B');
    } else if (cmd.contains('sector c') || cmd.contains('switch c')) {
      setState(() => _telemetry['sector'] = 'C');
    } else if (cmd.contains('sector d') || cmd.contains('switch d')) {
      setState(() => _telemetry['sector'] = 'D');
    }
    if (cmd.contains('analyze') || cmd.contains('assess') ||
        cmd.contains('check') || cmd.contains('scan')) {
      if (_originalBase64 != null) {
        _analyze();
      } else {
        setState(() => _status = 'SELECT IMAGE FIRST');
      }
    }
  }

  Future<void> _pickImage() async {
    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result != null && result.files.single.bytes != null) {
      final bytes = result.files.single.bytes!;
      setState(() {
        _originalBase64 = base64Encode(bytes);
        _fileName = result.files.single.name;
        _grayscaleBase64 = null;
        _edgesBase64 = null;
        _report = '';
        _riskScore = 0;
        _disasterProbs = {};
        _status = 'IMAGE LOADED // READY TO ANALYZE';
      });
    }
  }

  Future<void> _analyze() async {
    if (_originalBase64 == null) {
      setState(() => _status = 'NO IMAGE SELECTED');
      return;
    }
    setState(() {
      _isLoading = true;
      _status = 'ANALYZING SECTOR...';
    });
    try {
      final bytes = base64Decode(_originalBase64!);
      var request = http.MultipartRequest('POST', Uri.parse('$_backendUrl/analyze'));
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: _fileName ?? 'image.jpg'));
      var response = await request.send();
      var body = await response.stream.bytesToString();
      var analyzeResult = json.decode(body);

      setState(() {
        _riskScore = analyzeResult['risk_score'];
        _grayscaleBase64 = analyzeResult['images']['grayscale'];
        _edgesBase64 = analyzeResult['images']['edges'];
        _disasterProbs = analyzeResult['disaster_probs'] ?? {};
        _status = 'GENERATING REPORT...';
      });
      await _loadWeather();

      var reportResponse = await http.post(
        Uri.parse('$_backendUrl/report'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'command': _command,
          'telemetry': _telemetry,
          'disaster_probs': _disasterProbs,
          'analysis': {
            'edge_density': analyzeResult['metrics']['edge_density'],
            'brightness': analyzeResult['metrics']['brightness'],
            'blur_score': analyzeResult['metrics']['blur_score'],
            'fire_ratio': analyzeResult['metrics']['fire_ratio'],
            'water_ratio': analyzeResult['metrics']['water_ratio'],
            'contrast': analyzeResult['metrics']['contrast'],
            'risk_score': _riskScore,
          },
        }),
      );
      var reportResult = json.decode(reportResponse.body);

      setState(() {
        _report = '${reportResult['report']} ${_geoActionLine()}'.toUpperCase();
        _status = 'ANALYSIS COMPLETE';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _status = 'ERROR: $e';
        _isLoading = false;
      });
    }
  }

  Color _riskColor() {
    if (_riskScore >= 60) return milRed;
    if (_riskScore >= 30) return milAmber;
    return milGreenMid;
  }

  String _riskLabel() {
    if (_riskScore >= 60) return 'HIGH RISK';
    if (_riskScore >= 30) return 'MEDIUM RISK';
    return 'LOW RISK';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: milBg,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 10),
            _buildTelemetry(),
            const SizedBox(height: 10),
            _buildRiskScore(),
            const SizedBox(height: 10),
            _buildGeoDecisionSupport(),
            const SizedBox(height: 10),
            if (_disasterProbs.isNotEmpty) _buildThreatClassification(),
            if (_disasterProbs.isNotEmpty) const SizedBox(height: 10),
            _buildOperatorCommand(),
            const SizedBox(height: 10),
            if (_samples.isNotEmpty) _buildSamples(),
            if (_samples.isNotEmpty) const SizedBox(height: 10),
            _buildImageSection(),
            const SizedBox(height: 10),
            if (_report.isNotEmpty) _buildMissionReport(),

            const SizedBox(height: 10),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _milBox({required Widget child, Color borderColor = milBorder, Color bgColor = milBgCard}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Stack(
        children: [
          Positioned(top: 0, left: 0, child: Container(width: 10, height: 10, decoration: BoxDecoration(border: Border(top: BorderSide(color: borderColor, width: 2), left: BorderSide(color: borderColor, width: 2))))),
          Positioned(top: 0, right: 0, child: Container(width: 10, height: 10, decoration: BoxDecoration(border: Border(top: BorderSide(color: borderColor, width: 2), right: BorderSide(color: borderColor, width: 2))))),
          Positioned(bottom: 0, left: 0, child: Container(width: 10, height: 10, decoration: BoxDecoration(border: Border(bottom: BorderSide(color: borderColor, width: 2), left: BorderSide(color: borderColor, width: 2))))),
          Positioned(bottom: 0, right: 0, child: Container(width: 10, height: 10, decoration: BoxDecoration(border: Border(bottom: BorderSide(color: borderColor, width: 2), right: BorderSide(color: borderColor, width: 2))))),
          child,
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return _milBox(
      borderColor: milGreen,
      bgColor: const Color(0xFF050A05),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('◉ DISASTER DRONE SYSTEM', style: TextStyle(color: milGreen, fontSize: 13, letterSpacing: 3, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                Text('UAV TACTICAL OPERATIONS // ACTIVE', style: TextStyle(color: milText, fontSize: 9, letterSpacing: 2, fontFamily: 'monospace')),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('SYS: ${DateTime.now().hour.toString().padLeft(2,'0')}:${DateTime.now().minute.toString().padLeft(2,'0')}Z', style: TextStyle(color: milGreen, fontSize: 9, letterSpacing: 2, fontFamily: 'monospace')),
                Row(children: [
                  AnimatedOpacity(opacity: _blink ? 1.0 : 0.0, duration: Duration.zero, child: Text('● ', style: TextStyle(color: milGreenMid, fontSize: 9))),
                  Text('SIGNAL STRONG', style: TextStyle(color: milText, fontSize: 9, letterSpacing: 1, fontFamily: 'monospace')),
                ]),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetry() {
    final items = [
      {'label': 'ALTITUDE', 'value': '${_telemetry['altitude']}m', 'color': milGreen},
      {'label': 'BATTERY', 'value': '${_telemetry['battery']}%', 'color': (_telemetry['battery'] as int) < 30 ? milRed : milAmber},
      {'label': 'SECTOR', 'value': _telemetry['sector'], 'color': milGreen},
      {'label': 'SPEED', 'value': '${_telemetry['speed']}m/s', 'color': milGreen},
    ];
    return Row(
      children: items.map((item) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: _milBox(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item['label'] as String, style: TextStyle(color: milText, fontSize: 8, letterSpacing: 2, fontFamily: 'monospace')),
                  const SizedBox(height: 2),
                  Text(item['value'] as String, style: TextStyle(color: item['color'] as Color, fontSize: 18, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ),
      )).toList(),
    );
  }

  Widget _buildRiskScore() {
    return _milBox(
      borderColor: _riskColor(),
      bgColor: const Color(0xFF050A05),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('■ THREAT LEVEL', style: TextStyle(color: milText, fontSize: 9, letterSpacing: 3, fontFamily: 'monospace')),
            const SizedBox(height: 4),
            Text('$_riskScore', style: TextStyle(color: _riskColor(), fontSize: 52, fontFamily: 'monospace', fontWeight: FontWeight.bold, height: 1)),
            Text('/100 — ${_riskLabel()}', style: TextStyle(color: milText, fontSize: 9, letterSpacing: 2, fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Container(
              height: 6,
              decoration: BoxDecoration(border: Border.all(color: milBorder)),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: _riskScore / 100,
                child: Container(color: _riskColor()),
              ),
            ),
            const SizedBox(height: 6),
            Text(_status, style: TextStyle(color: milText, fontSize: 9, letterSpacing: 2, fontFamily: 'monospace')),
          ],
        ),
      ),
    );
  }

  Widget _buildThreatClassification() {
    final sorted = _disasterProbs.entries.toList()..sort((a, b) => (b.value as num).compareTo(a.value as num));
    return _milBox(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('▶ THREAT CLASSIFICATION', style: TextStyle(color: milText, fontSize: 8, letterSpacing: 3, fontFamily: 'monospace')),
            const SizedBox(height: 8),
            ...sorted.map((entry) {
              final pct = (entry.value as num).toDouble();
              final isTop = entry == sorted.first;
              final threatColor = _threatColorFor(entry.key.toString(), isTop);
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(width: 80, child: Text(entry.key.toUpperCase(), style: TextStyle(color: isTop ? threatColor : milText, fontSize: 9, fontFamily: 'monospace'))),
                    Expanded(
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(border: Border.all(color: milBorder)),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: pct / 100,
                          child: Container(color: threatColor),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(width: 44, child: Text('${pct.toStringAsFixed(1)}%', textAlign: TextAlign.right, style: TextStyle(color: isTop ? threatColor : milText, fontSize: 9, fontFamily: 'monospace'))),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildGeoMetric(String label, String value, Color color) {
    return Expanded(
      child: Container(
        height: 50,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: const Color(0xFF071207),
          border: Border.all(color: milBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: milText, fontSize: 7, letterSpacing: 1.5, fontFamily: 'monospace')),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: TextStyle(color: color, fontSize: 13, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeoDecisionSupport() {
    final temperature = _numWeather('temperature', 0).toStringAsFixed(1);
    final humidity = _numWeather('humidity', 0).toStringAsFixed(0);
    final radius = _riskRadiusMeters();
    final hasThreat = _hasActiveThreat();
    final showSpreadPolygon = hasThreat && _spreadPolygon().isNotEmpty;
    final mapAlertColor = hasThreat ? _riskColor() : milGreenMid;

    final terrainBands = [
      CircleMarker(
        point: _incidentPoint,
        radius: radius * 1.55,
        useRadiusInMeter: true,
        color: const Color(0xFF1B4332).withValues(alpha: 0.10),
        borderColor: const Color(0xFF4ADE80).withValues(alpha: 0.16),
        borderStrokeWidth: 1,
      ),
      CircleMarker(
        point: _incidentPoint,
        radius: radius * 1.15,
        useRadiusInMeter: true,
        color: const Color(0xFF31572C).withValues(alpha: 0.10),
        borderColor: const Color(0xFFA3C45A).withValues(alpha: 0.18),
        borderStrokeWidth: 1,
      ),
    ];

    return _milBox(
      borderColor: const Color(0xFF2A5A5A),
      bgColor: const Color(0xFF050D0D),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.public, color: const Color(0xFF5EEAD4), size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('GEO DISASTER TWIN // OPEN MAP', style: TextStyle(color: const Color(0xFF5EEAD4), fontSize: 9, letterSpacing: 3, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                ),
                GestureDetector(
                  onTap: _isLocating ? null : _useDeviceLocation,
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF082020),
                      border: Border.all(color: const Color(0xFF2A5A5A)),
                    ),
                    child: Row(
                      children: [
                        _isLocating
                            ? SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: const Color(0xFF5EEAD4)))
                            : Icon(Icons.my_location, color: const Color(0xFF5EEAD4), size: 14),
                        const SizedBox(width: 5),
                        Text('GPS', style: TextStyle(color: const Color(0xFF5EEAD4), fontSize: 8, letterSpacing: 1.5, fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _mapPickEnabled = !_mapPickEnabled;
                      _status = _mapPickEnabled ? 'MAP PICK ENABLED' : 'MAP PICK DISABLED';
                    });
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                    decoration: BoxDecoration(
                      color: _mapPickEnabled ? const Color(0xFF123012) : const Color(0xFF082020),
                      border: Border.all(color: _mapPickEnabled ? milGreen : const Color(0xFF2A5A5A)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.touch_app, color: _mapPickEnabled ? milGreen : const Color(0xFF5EEAD4), size: 14),
                        const SizedBox(width: 5),
                        Text('MAP', style: TextStyle(color: _mapPickEnabled ? milGreen : const Color(0xFF5EEAD4), fontSize: 8, letterSpacing: 1.5, fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _isWeatherLoading ? null : () => _loadWeather(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF082020),
                      border: Border.all(color: const Color(0xFF2A5A5A)),
                    ),
                    child: Row(
                      children: [
                        _isWeatherLoading
                            ? SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: const Color(0xFF5EEAD4)))
                            : Icon(Icons.refresh, color: const Color(0xFF5EEAD4), size: 14),
                        const SizedBox(width: 5),
                        Text('WX', style: TextStyle(color: const Color(0xFF5EEAD4), fontSize: 8, letterSpacing: 1.5, fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _buildGeoMetric(_locationSource, '${_incidentPoint.latitude.toStringAsFixed(4)}, ${_incidentPoint.longitude.toStringAsFixed(4)}', const Color(0xFF5EEAD4)),
                const SizedBox(width: 6),
                _buildGeoMetric('WEATHER', _weatherSource, _weatherSource == 'OPEN-METEO' ? milGreen : milAmber),
                const SizedBox(width: 6),
                _buildGeoMetric('DRIVER', _environmentDriverLabel(), milAmber),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _buildGeoMetric('TEMP', '$temperature C', milGreen),
                const SizedBox(width: 6),
                _buildGeoMetric('HUMIDITY', '$humidity%', const Color(0xFF60A5FA)),
                const SizedBox(width: 6),
                _buildGeoMetric(_isRouteLoading ? 'ROUTE' : 'ROUTE', _isRouteLoading ? 'OSRM...' : _routeSource, _routeSource.startsWith('OSRM') ? milGreen : const Color(0xFF38BDF8)),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 520,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF2A5A5A)),
                color: const Color(0xFF031010),
              ),
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _incidentPoint,
                      initialZoom: 14,
                      minZoom: 4,
                      maxZoom: 18,
                      onTap: (tapPosition, point) => _setIncidentPoint(point),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.drone_app',
                      ),
                      CircleLayer(
                        circles: [
                          ...terrainBands,
                          CircleMarker(
                            point: _incidentPoint,
                            radius: radius,
                            useRadiusInMeter: true,
                            color: mapAlertColor.withValues(alpha: hasThreat ? 0.22 : 0.14),
                            borderColor: mapAlertColor,
                            borderStrokeWidth: 2,
                          ),
                        ],
                      ),
                      if (showSpreadPolygon)
                        PolygonLayer(
                          polygons: [
                            Polygon(
                              points: _spreadPolygon(),
                              color: _mapThreatFillColor().withValues(alpha: 0.30),
                              borderColor: _riskColor(),
                              borderStrokeWidth: 2,
                            ),
                          ],
                        ),
                      PolylineLayer(
                        polylines: [
                          if (hasThreat) Polyline(points: _evacuationRoute(), color: milGreen, strokeWidth: 4),
                          if (hasThreat) Polyline(points: _blockedRoadPoints(-18), color: milRed, strokeWidth: 5),
                          if (hasThreat) Polyline(points: _blockedRoadPoints(26), color: milRed, strokeWidth: 5),
                        ],
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _incidentPoint,
                            width: 44,
                            height: 44,
                            child: Container(
                              decoration: BoxDecoration(
                                color: mapAlertColor.withValues(alpha: 0.22),
                                border: Border.all(color: mapAlertColor, width: 2),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(hasThreat ? Icons.warning_amber_rounded : Icons.visibility, color: mapAlertColor, size: 24),
                            ),
                          ),
                          if (hasThreat)
                            Marker(
                              point: _safeZonePoint,
                              width: 42,
                              height: 42,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: milGreen.withValues(alpha: 0.22),
                                  border: Border.all(color: milGreen, width: 2),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(Icons.health_and_safety, color: milGreen, size: 22),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                      color: const Color(0xCC050A05),
                      child: Text('OPENSTREETMAP CONTRIBUTORS', style: TextStyle(color: milText, fontSize: 7, letterSpacing: 1, fontFamily: 'monospace')),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xCC050A05),
                        border: Border.all(color: const Color(0xFF2A5A5A)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(hasThreat && _topDisaster() == 'Yangin' ? Icons.arrow_upward : hasThreat ? Icons.layers : Icons.check_circle_outline, color: hasThreat ? _mapThreatFillColor() : milGreen, size: 13),
                          const SizedBox(width: 4),
                          Text(_mapModelLabel(), style: TextStyle(color: hasThreat ? _mapThreatFillColor() : milGreen, fontSize: 7, letterSpacing: 1, fontFamily: 'monospace')),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(
              hasThreat
                  ? 'RISK RADIUS ${radius.toStringAsFixed(0)}M // $_routeSource ${_evacuationRoute().length} POINTS // CLOSED ROAD MARKS ACTIVE'
                  : 'OBSERVATION RADIUS ${radius.toStringAsFixed(0)}M // GPS OBSERVATION LOCKED // NO ROUTE OR CLOSED ROAD MARKS',
              style: TextStyle(color: milText, fontSize: 8, letterSpacing: 1.5, fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOperatorCommand() {
    return _milBox(
      borderColor: const Color(0xFF1A3A4A),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('▶ OPERATOR COMMAND', style: TextStyle(color: const Color(0xFF4A7A9A), fontSize: 8, letterSpacing: 3, fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _command.isEmpty ? 'AWAITING VOICE COMMAND...' : _command.toUpperCase(),
                    style: TextStyle(color: _command.isEmpty ? milText : milGreen, fontSize: 11, fontFamily: 'monospace', letterSpacing: 1),
                  ),
                ),
                GestureDetector(
                  onTapDown: (_) => _startListening(),
                  onTapUp: (_) => _stopListening(),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _isListening ? milRed.withValues(alpha: 0.2) : const Color(0xFF0A1A2A),
                      border: Border.all(color: _isListening ? milRed : const Color(0xFF1A3A4A), width: 1),
                    ),
                    child: Icon(_isListening ? Icons.mic : Icons.mic_none, color: _isListening ? milRed : const Color(0xFF4A7A9A), size: 20),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSamples() {
    if (_samples.isEmpty) return const SizedBox.shrink();
    return _milBox(
      borderColor: const Color(0xFF3A4A1A),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('▶ SAMPLE IMAGERY', style: TextStyle(color: const Color(0xFF6A8A3A), fontSize: 8, letterSpacing: 3, fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Row(
              children: _samples.entries.map((entry) {
                final isSelected = _fileName == entry.value['label'];
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: GestureDetector(
                      onTap: () => _selectSample(entry.key),
                      child: Column(
                        children: [
                          Container(
                            height: 100,
                            decoration: BoxDecoration(
                              border: Border.all(color: isSelected ? milGreen : milBorder, width: isSelected ? 2 : 1),
                            ),
                            child: entry.value['base64'] != null
                              ? Image.memory(base64Decode(entry.value['base64']), fit: BoxFit.cover, width: double.infinity)
                              : Center(child: Icon(Icons.image, color: milText, size: 24)),
                          ),
                          const SizedBox(height: 4),
                          Text(entry.value['label'].toString().toUpperCase(), textAlign: TextAlign.center, style: TextStyle(color: isSelected ? milGreen : milText, fontSize: 7, fontFamily: 'monospace', letterSpacing: 1)),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSection() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _pickImage,
                child: _milBox(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.upload_file, color: milText, size: 16),
                        const SizedBox(width: 6),
                        Text(_fileName != null ? _fileName!.toUpperCase() : 'LOAD IMAGE', style: TextStyle(color: milText, fontSize: 9, fontFamily: 'monospace', letterSpacing: 1)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: _isLoading ? null : _analyze,
                child: _milBox(
                  borderColor: milGreen,
                  bgColor: const Color(0xFF0A1A0A),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _isLoading
                            ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: milGreen))
                            : Icon(Icons.radar, color: milGreen, size: 16),
                        const SizedBox(width: 6),
                        Text(_isLoading ? 'SCANNING...' : 'ANALYZE SECTOR', style: TextStyle(color: milGreen, fontSize: 9, fontFamily: 'monospace', letterSpacing: 1)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_originalBase64 != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _milBox(
                child: Column(children: [
                  Padding(padding: const EdgeInsets.all(4), child: Text('ORIGINAL', style: TextStyle(color: milText, fontSize: 7, letterSpacing: 2, fontFamily: 'monospace'))),
                  AspectRatio(aspectRatio: 1, child: Image.memory(base64Decode(_originalBase64!), fit: BoxFit.cover, width: double.infinity)),
                ]),
              )),
              const SizedBox(width: 6),
              Expanded(child: _milBox(
                child: Column(children: [
                  Padding(padding: const EdgeInsets.all(4), child: Text('GRAYSCALE', style: TextStyle(color: milText, fontSize: 7, letterSpacing: 2, fontFamily: 'monospace'))),
                  AspectRatio(aspectRatio: 1, child: _grayscaleBase64 != null
                    ? Image.memory(base64Decode(_grayscaleBase64!), fit: BoxFit.cover, width: double.infinity)
                    : Container(color: const Color(0xFF0A150A))),
                ]),
              )),
              const SizedBox(width: 6),
              Expanded(child: _milBox(
                child: Column(children: [
                  Padding(padding: const EdgeInsets.all(4), child: Text('EDGE DETECT', style: TextStyle(color: milText, fontSize: 7, letterSpacing: 2, fontFamily: 'monospace'))),
                  AspectRatio(aspectRatio: 1, child: _edgesBase64 != null
                    ? Image.memory(base64Decode(_edgesBase64!), fit: BoxFit.cover, width: double.infinity)
                    : Container(color: const Color(0xFF0A150A))),
                ]),
              )),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMissionReport() {
    return _milBox(
      borderColor: const Color(0xFFA3C45A),
      bgColor: const Color(0xFF050805),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(width: 4, height: 14, color: const Color(0xFFA3C45A)),
              const SizedBox(width: 8),
              Text('MISSION REPORT', style: TextStyle(color: const Color(0xFFA3C45A), fontSize: 10, letterSpacing: 4, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 10),
            Container(height: 1, color: const Color(0xFF3A4A1A)),
            const SizedBox(height: 10),
            Text(_report, style: TextStyle(color: const Color(0xFF9ABA5A), fontSize: 11, fontFamily: 'monospace', height: 1.8, letterSpacing: 0.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        AnimatedOpacity(
          opacity: _blink ? 1.0 : 0.3,
          duration: Duration.zero,
          child: Text('● SYSTEM ACTIVE', style: TextStyle(color: milGreen, fontSize: 8, letterSpacing: 2, fontFamily: 'monospace')),
        ),
        Text('UAV-OPS v2.1 // CLASSIFIED', style: TextStyle(color: milBorder, fontSize: 8, letterSpacing: 2, fontFamily: 'monospace')),
      ],
    );
  }
}
