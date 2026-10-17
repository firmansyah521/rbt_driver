import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RouteResult {
  final List<LatLng> points;
  final double distanceKm;
  final int durationMinutes;

  const RouteResult({
    required this.points,
    required this.distanceKm,
    required this.durationMinutes,
  });
}

class DriverRoutingService {
  static const String _osrmBaseUrl =
      'https://router.project-osrm.org/route/v1/driving';

  static Future<RouteResult> getRoute(LatLng start, LatLng end) async {
    final String url =
        '$_osrmBaseUrl/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=geojson';

    try {
      final response = await http
          .get(Uri.parse(url), headers: {'User-Agent': 'RBTDriverPidie/1.0'})
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final double distanceMeters = (route['distance'] as num).toDouble();
          final double durationSeconds = (route['duration'] as num).toDouble();
          final List coords = route['geometry']['coordinates'] as List;

          final List<LatLng> polylinePoints = coords.map((c) {
            final double lon = (c[0] as num).toDouble();
            final double lat = (c[1] as num).toDouble();
            return LatLng(lat, lon);
          }).toList();

          return RouteResult(
            points: polylinePoints,
            distanceKm: distanceMeters / 1000.0,
            durationMinutes: (durationSeconds / 60).round(),
          );
        }
      }
    } catch (_) {}

    // Fallback Geodesi: Hitung jarak Haversine & interpolasi
    final double haversineDist = _haversineDistance(start, end);
    final double roadDist = math.max(0.5, haversineDist * 1.25);
    final List<LatLng> interpolated = _generateInterpolatedPoints(start, end);

    return RouteResult(
      points: interpolated,
      distanceKm: roadDist,
      durationMinutes: ((roadDist / 30) * 60).round() + 3,
    );
  }

  static double _haversineDistance(LatLng start, LatLng end) {
    const r = 6371.0;
    final dLat = (end.latitude - start.latitude) * math.pi / 180.0;
    final dLon = (end.longitude - start.longitude) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(start.latitude * math.pi / 180.0) *
            math.cos(end.latitude * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static List<LatLng> _generateInterpolatedPoints(LatLng start, LatLng end) {
    const int segments = 12;
    final List<LatLng> list = [];

    final double midLat = (start.latitude + end.latitude) / 2;
    final double midLng = (start.longitude + end.longitude) / 2;
    final double offsetLat = (end.longitude - start.longitude) * 0.08;
    final double offsetLng = (start.latitude - end.latitude) * 0.08;

    for (int i = 0; i <= segments; i++) {
      final double t = i / segments;
      final double lat = (1 - t) * (1 - t) * start.latitude +
          2 * (1 - t) * t * (midLat + offsetLat) +
          t * t * end.latitude;
      final double lng = (1 - t) * (1 - t) * start.longitude +
          2 * (1 - t) * t * (midLng + offsetLng) +
          t * t * end.longitude;
      list.add(LatLng(lat, lng));
    }
    return list;
  }
}
