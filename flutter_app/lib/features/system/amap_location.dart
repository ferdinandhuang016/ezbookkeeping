import 'package:flutter/services.dart';

import '../../ui/common.dart';
import 'map_contract.dart';

const _amapPrivacyAcceptedKey = 'amapLocationPrivacyAccepted';
const _nativeChannel = MethodChannel('ezbookkeeping/native');

Future<String> reverseGeocodeNative(double latitude, double longitude) async {
  final name = await _nativeChannel
      .invokeMethod<String>('reverseGeocode', {
        'latitude': latitude,
        'longitude': longitude,
      })
      .timeout(const Duration(seconds: 10));
  final locationName = name?.trim() ?? '';
  return locationName.length > 255
      ? locationName.substring(0, 255)
      : locationName;
}

Future<Map<String, dynamic>> getAmapCurrentLocation(
  BuildContext context,
  AppController app,
) async {
  if (app.settings[_amapPrivacyAcceptedKey] != true) {
    final accepted = await confirm(
      context,
      app.t('Allow AMap to provide location?'),
      message: app.t(
        'AMap will process device and location data to obtain your current position. You can continue bookkeeping without allowing it.',
      ),
    );
    if (!accepted) throw StateError('Location permission denied');
    await app.setPreference(_amapPrivacyAcceptedKey, true);
  }

  final position = await _nativeChannel
      .invokeMapMethod<String, dynamic>('getAmapLocation')
      .timeout(const Duration(seconds: 25));
  final latitude = (position?['latitude'] as num?)?.toDouble();
  final longitude = (position?['longitude'] as num?)?.toDouble();
  if (latitude == null || longitude == null) {
    throw StateError(app.t('Unable to get current geographic location'));
  }
  final coordinate = gcj02ToWgs84(latitude, longitude);
  final locationName = position?['name'] is String
      ? (position!['name'] as String).trim()
      : '';
  return {
    ...coordinate,
    if (locationName.isNotEmpty)
      'name': locationName.length > 255
          ? locationName.substring(0, 255)
          : locationName,
  };
}
