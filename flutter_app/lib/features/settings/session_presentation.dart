import 'package:ua_parser/ua_parser.dart';

enum SessionDevice { api, mcp, phone, wearable, tablet, tv, desktop }

class SessionPresentation {
  const SessionPresentation(this.name, this.details, this.device);
  final String name, details;
  final SessionDevice device;
}

/// Port of src/lib/session.ts using UAParser's Dart port with original v1.0.41
/// compatibility rules. https://pub.dev/documentation/ua_parser/1.0.0/
SessionPresentation presentSession(Map<String, dynamic> token) {
  final agent = '${token['userAgent'] ?? ''}';
  final type = int.tryParse('${token['tokenType']}') ?? 0;
  if (type == 8) {
    return SessionPresentation('API Token', agent, SessionDevice.api);
  }
  if (type == 5) {
    return SessionPresentation('MCP Token', agent, SessionDevice.mcp);
  }
  final name = token['isCurrent'] == true ? 'Current' : 'Other Device';
  final nativeVersion = RegExp(r'^(?:ezBookkeeping|DangguiExpense)/([\d.]+).*Android')
      .firstMatch(agent);
  if (nativeVersion != null) {
    return SessionPresentation(
      name,
      'Android (Danggui Expense ${nativeVersion[1]})',
      SessionDevice.phone,
    );
  }
  final parsed = UaParser.parse(agent);
  var device = switch (parsed.device.type) {
    'mobile' => SessionDevice.phone,
    'wearable' => SessionDevice.wearable,
    'tablet' => SessionDevice.tablet,
    'smarttv' => SessionDevice.tv,
    _ => SessionDevice.desktop,
  };
  var details = parsed.device.model ?? '';
  // UAParser.js 1.0.41 rules absent from the Dart port: windowsVersionMap,
  // Apple Macintosh, watch models, and Mobile Safari browser labels.
  final watch = RegExp(
    r'(asus|google|lg|oppo) ((pixel |zen)?watch[\w ]*)( bui|\))',
    caseSensitive: false,
  ).firstMatch(agent);
  if (watch != null) {
    details = watch[2]!.trim();
    device = SessionDevice.wearable;
  } else if (RegExp(r'(macintosh);', caseSensitive: false).hasMatch(agent)) {
    details = 'Macintosh';
  }
  if (details.isEmpty) {
    var os = parsed.os.name, version = parsed.os.version;
    if (os?.startsWith('Windows') == true) {
      final windows = RegExp(
        r'windows (NT [\d.]+|ARM|4\.90)',
        caseSensitive: false,
      ).firstMatch(agent);
      if (windows != null) {
        os = 'Windows';
        version =
            const {
              '4.90': 'ME',
              'NT 3.51': 'NT 3.11',
              'NT 4.0': 'NT 4.0',
              'NT 5.0': '2000',
              'NT 5.1': 'XP',
              'NT 5.2': 'XP',
              'NT 6.0': 'Vista',
              'NT 6.1': '7',
              'NT 6.2': '8',
              'NT 6.3': '8.1',
              'NT 6.4': '10',
              'NT 10.0': '10',
              'ARM': 'RT',
            }[windows[1]!.toUpperCase()] ??
            version;
      }
    }
    details = [
      os,
      version,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' ');
  }
  var browserName = parsed.browser.name,
      browserVersion = parsed.browser.version;
  if (browserName == 'Safari' &&
      RegExp(
        r'version/[\w.,]+ .*mobile/\w+ safari',
        caseSensitive: false,
      ).hasMatch(agent)) {
    browserName = 'Mobile Safari';
  } else if (browserName == 'Mozilla' &&
      RegExp(r'webkit.+?safari/', caseSensitive: false).hasMatch(agent)) {
    browserName = 'Safari';
    browserVersion = null;
  }
  if (browserName?.isNotEmpty == true) {
    final browser = [
      browserName,
      browserVersion,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    details = details.isEmpty ? browser : '$details ($browser)';
  }
  return SessionPresentation(
    name,
    details.isEmpty ? 'Unknown Device' : details,
    device,
  );
}
