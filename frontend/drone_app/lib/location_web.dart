// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import 'package:latlong2/latlong.dart';

Future<LatLng?> getDeviceLocation() async {
  final position = await html.window.navigator.geolocation.getCurrentPosition(
    enableHighAccuracy: true,
    timeout: const Duration(seconds: 10),
    maximumAge: const Duration(seconds: 30),
  );
  return LatLng(position.coords!.latitude!.toDouble(), position.coords!.longitude!.toDouble());
}
