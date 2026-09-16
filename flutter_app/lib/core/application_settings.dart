import 'dart:convert';

dynamic settingValue(Map<String, dynamic> settings, String key) {
  dynamic value = settings;
  for (final part in key.split('.')) {
    value = value is Map ? value[part] : null;
  }
  return value;
}

void putSetting(Map<String, dynamic> settings, String key, dynamic value) {
  final parts = key.split('.');
  if (parts.length == 1) {
    settings[key] = value;
  } else {
    final group = Map<String, dynamic>.from(settings[parts.first] ?? {});
    group[parts.last] = value;
    settings[parts.first] = group;
  }
}

String encodeCloudValue(dynamic value) =>
    value is String ? value : jsonEncode(value);

dynamic decodeCloudValue(String value, String type) {
  switch (type) {
    case 'string':
      return value;
    case 'number':
      final number = num.tryParse(value);
      if (number == null || !number.isFinite) {
        throw const FormatException('Invalid cloud setting number');
      }
      return number;
    case 'boolean':
      if (value != 'true' && value != 'false') {
        throw const FormatException('Invalid cloud setting boolean');
      }
      return value == 'true';
    case 'string_boolean_map':
      final map = jsonDecode(value);
      if (map is! Map || map.values.any((value) => value is! bool)) {
        throw const FormatException('Invalid cloud setting filter');
      }
      return Map<String, dynamic>.from(map);
    default:
      throw const FormatException('Unknown cloud setting type');
  }
}

Map<String, dynamic> mergeSettings(
  Map<String, dynamic> defaults,
  Map<String, dynamic> saved,
) {
  final fresh = Map<String, dynamic>.from(jsonDecode(jsonEncode(defaults)));
  return {
    ...fresh,
    ...saved,
    if (fresh['statistics'] is Map || saved['statistics'] is Map)
      'statistics': {
        ...?fresh['statistics'] as Map?,
        ...?saved['statistics'] as Map?,
      },
  };
}
