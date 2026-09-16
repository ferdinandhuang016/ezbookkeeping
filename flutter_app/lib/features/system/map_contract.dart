import 'dart:math' as math;

/// Native credentials are injected once into this exact server map document.
bool isNativeMapUrl(Uri mapUri, String candidate) {
  final uri = Uri.tryParse(candidate);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.origin == mapUri.origin &&
      uri.path == mapUri.path &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

Map<String, dynamic>? mapCoordinate(dynamic message) {
  final location = mapLocation(message);
  if (location == null) return null;
  return {'latitude': location['latitude'], 'longitude': location['longitude']};
}

Map<String, dynamic>? mapLocation(dynamic message) {
  if (message is! Map || message['type'] != 'coordinate') return null;
  final latitude = message['latitude'], longitude = message['longitude'];
  if (latitude is! num ||
      longitude is! num ||
      !latitude.isFinite ||
      !longitude.isFinite ||
      latitude.abs() > 90 ||
      longitude.abs() > 180) {
    return null;
  }
  final name = message['name'];
  if (name != null && (name is! String || name.length > 255)) return null;
  return {
    'latitude': latitude,
    'longitude': longitude,
    if (name is String && name.trim().isNotEmpty) 'name': name.trim(),
  };
}

const _gcj02EllipsoidSemiMajorAxis = 6378245.0;
const _gcj02EllipsoidEccentricitySquared = 0.006693421622965943;

Map<String, double> gcj02ToWgs84(double latitude, double longitude) {
  if (longitude < 72.004 ||
      longitude > 137.8347 ||
      latitude < 0.8293 ||
      latitude > 55.8271) {
    return {'latitude': latitude, 'longitude': longitude};
  }

  final longitudeOffset = longitude - 105.0;
  final latitudeOffset = latitude - 35.0;
  var latitudeDelta =
      -100.0 +
      2.0 * longitudeOffset +
      3.0 * latitudeOffset +
      0.2 * latitudeOffset * latitudeOffset +
      0.1 * longitudeOffset * latitudeOffset +
      0.2 * math.sqrt(longitudeOffset.abs());
  var longitudeDelta =
      300.0 +
      longitudeOffset +
      2.0 * latitudeOffset +
      0.1 * longitudeOffset * longitudeOffset +
      0.1 * longitudeOffset * latitudeOffset +
      0.1 * math.sqrt(longitudeOffset.abs());
  latitudeDelta +=
      (20.0 * math.sin(6.0 * longitudeOffset * math.pi) +
          20.0 * math.sin(2.0 * longitudeOffset * math.pi)) *
      2.0 /
      3.0;
  latitudeDelta +=
      (20.0 * math.sin(latitudeOffset * math.pi) +
          40.0 * math.sin(latitudeOffset / 3.0 * math.pi)) *
      2.0 /
      3.0;
  latitudeDelta +=
      (160.0 * math.sin(latitudeOffset / 12.0 * math.pi) +
          320.0 * math.sin(latitudeOffset * math.pi / 30.0)) *
      2.0 /
      3.0;
  longitudeDelta +=
      (20.0 * math.sin(6.0 * longitudeOffset * math.pi) +
          20.0 * math.sin(2.0 * longitudeOffset * math.pi)) *
      2.0 /
      3.0;
  longitudeDelta +=
      (20.0 * math.sin(longitudeOffset * math.pi) +
          40.0 * math.sin(longitudeOffset / 3.0 * math.pi)) *
      2.0 /
      3.0;
  longitudeDelta +=
      (150.0 * math.sin(longitudeOffset / 12.0 * math.pi) +
          300.0 * math.sin(longitudeOffset / 30.0 * math.pi)) *
      2.0 /
      3.0;

  final radianLatitude = latitude / 180.0 * math.pi;
  var magic = math.sin(radianLatitude);
  magic = 1 - _gcj02EllipsoidEccentricitySquared * magic * magic;
  final squareRootMagic = math.sqrt(magic);
  latitudeDelta =
      latitudeDelta *
      180.0 /
      ((_gcj02EllipsoidSemiMajorAxis *
              (1 - _gcj02EllipsoidEccentricitySquared)) /
          (magic * squareRootMagic) *
          math.pi);
  longitudeDelta =
      longitudeDelta *
      180.0 /
      (_gcj02EllipsoidSemiMajorAxis /
          squareRootMagic *
          math.cos(radianLatitude) *
          math.pi);

  return {
    'latitude': latitude - latitudeDelta,
    'longitude': longitude - longitudeDelta,
  };
}

String formatNativeCoordinate(
  Map<String, dynamic> coordinate,
  int displayType,
) {
  final latitude = (coordinate['latitude'] as num?)?.toDouble();
  final longitude = (coordinate['longitude'] as num?)?.toDouble();
  if (latitude == null || longitude == null) return '';
  final type = displayType >= 1 && displayType <= 6 ? displayType : 1;
  String format(double value, String positive, String negative) {
    if (type <= 2) return value.toStringAsFixed(6);
    final absolute = value.abs(), degrees = value.abs().truncate();
    final direction = value >= 0 ? positive : negative;
    if (type <= 4) {
      return '$degrees°${((absolute - degrees) * 60).toStringAsFixed(5)}\'$direction';
    }
    final minutes = ((absolute - degrees) * 60).truncate();
    return '$degrees°$minutes\'${((absolute - degrees - minutes / 60) * 3600).toStringAsFixed(4)}"$direction';
  }

  final lat = format(latitude.clamp(-90, 90), 'N', 'S');
  final lon = format(((longitude + 180) % 360 + 360) % 360 - 180, 'E', 'W');
  return type.isOdd ? '$lat, $lon' : '$lon, $lat';
}
