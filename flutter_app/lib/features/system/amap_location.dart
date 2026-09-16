import 'package:flutter/services.dart';

import '../../ui/common.dart';
import 'map_contract.dart';

const _amapPrivacyAcceptedKey = 'amapLocationPrivacyAccepted';
const _nativeChannel = MethodChannel('ezbookkeeping/native');

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
  final name = position?['name'];
  final locationName = name is String ? name.trim() : '';
  return {
    ...coordinate,
    if (locationName.isNotEmpty)
      'name': locationName.length > 255
          ? locationName.substring(0, 255)
          : locationName,
  };
}
