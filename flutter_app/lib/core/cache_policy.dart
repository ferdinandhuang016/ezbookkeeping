import 'dart:convert';

const mapCacheExpirations = [
  -1,
  86400,
  604800,
  2592000,
  7776000,
  15552000,
  31536000,
  0,
];
const exchangeRatesCacheExpirations = [-1, 86400, 604800, 2592000, 0];

bool cacheExpired(num expiration, num cachedAt, int now) =>
    expiration < 0 || (expiration > 0 && now - cachedAt >= expiration);

bool canSetMapCacheExpiration(Map<String, dynamic> config) =>
    (config['mapProvider'] as String? ?? '').isNotEmpty &&
    !['googlemap', 'baidumap', 'amap'].contains(config['mapProvider']) &&
    config['enableMapDataFetchProxy'] == true;

int serializedCacheBytes(dynamic value) =>
    value == null || (value is Map && value.isEmpty)
    ? 0
    : utf8.encode(jsonEncode(value)).length;

enum AppCache { pictures, map, customIcons, files, exchangeRates, all }

/// Only disposable caches are passed here. Ledger databases, operation queues,
/// staged pictures and WebView authentication/storage are not deletion targets.
Future<void> clearAppCaches(
  AppCache cache, {
  required Future<void> Function() clearPictures,
  required Future<void> Function() clearWebView,
  required Future<void> Function(String, dynamic) writePreference,
  required void Function() clearDecodedImages,
}) async {
  final files = cache == AppCache.files || cache == AppCache.all;
  if (files || cache == AppCache.map) {
    await clearWebView();
    await writePreference('nativeMapCacheUpdated', 0);
  }
  if (files || cache == AppCache.pictures) await clearPictures();
  if (files || cache == AppCache.customIcons) {
    await writePreference('cachedCustomIconImages', null);
  }
  if (cache == AppCache.all || cache == AppCache.exchangeRates) {
    await writePreference('cachedExchangeRates', null);
    await writePreference('exchangeRatesCachedAt', 0);
  }
  if (files || cache == AppCache.pictures || cache == AppCache.customIcons) {
    clearDecodedImages();
  }
}
