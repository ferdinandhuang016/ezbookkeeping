import 'dart:math';

List<String> effectiveChartColors(String value, List<String> defaults) {
  final colors = value
      .split(',')
      .map((color) => color.trim().toLowerCase())
      .where((color) => RegExp(r'^[0-9a-f]{6}$').hasMatch(color))
      .toList();
  return colors.isEmpty ? [...defaults] : colors;
}

List<String> importChartColors(String value) {
  final colors = value
      .split(RegExp('[,\n]'))
      .map((color) => color.trim().toLowerCase().replaceFirst(RegExp('^#'), ''))
      .where((color) => RegExp(r'^[0-9a-f]{6}$').hasMatch(color))
      .toList();
  if (colors.isEmpty) throw const FormatException('No valid colors found');
  return colors;
}

bool settingOrderModified(List<String> current, List<String> saved) =>
    current.join(',') != saved.join(',');

String encodeSettingOrder(List<String> current, List<String> defaults) =>
    settingOrderModified(current, defaults) ? current.join(',') : '';

double settingsListViewportHeight({
  required double availableHeight,
  required int itemCount,
  required double fontSize,
}) => min(
  max(0.0, availableHeight),
  max(0, itemCount) * max(64.0, fontSize * 2 + 24),
);
