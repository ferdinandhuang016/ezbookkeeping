import 'dart:convert';

import 'package:flutter/services.dart';

import '../../ui/common.dart';

RecordData settingsReference = {};
Future<void> loadSettingsReference() async {
  if (settingsReference.isEmpty) {
    settingsReference = Map<String, dynamic>.from(
      jsonDecode(await rootBundle.loadString('assets/reference/settings.json')),
    );
  }
}

dynamic preference(AppController app, String key) {
  dynamic read(Map data) {
    dynamic value = data;
    for (final part in key.split('.')) {
      value = value is Map ? value[part] : null;
    }
    return value;
  }

  return read(app.settings) ?? read(settingsReference['defaults'] ?? {});
}

Future<void> writePreference(
  AppController app,
  String key,
  dynamic value,
) async {
  final parts = key.split('.');
  if (parts.length == 1) {
    await app.setPreference(key, value);
    return;
  }
  final group = Map<String, dynamic>.from(
    app.settings[parts.first] ??
        settingsReference['defaults']?[parts.first] ??
        {},
  );
  group[parts.last] = value;
  await app.setPreference(parts.first, group);
}

List<RecordData> settingOptions(String group, {bool defaultOption = false}) => [
  if (defaultOption) {'id': 0, 'name': 'Language Default'},
  ...records(settingsReference['options']?[group]),
];
String optionName(List<RecordData> options, dynamic id) => string(
  options.where((e) => string(e['id']) == string(id)).firstOrNull?['name'],
);

abstract class SettingsState<T extends ConsumerStatefulWidget>
    extends NativeState<T> {
  bool ready = false;
  @override
  void initState() {
    super.initState();
    loadSettingsReference().then((_) {
      if (mounted) setState(() => ready = true);
    });
  }

  Widget link(String label, String route) =>
      ItemRow(t(label), onTap: () => context.push(route));
  Widget toggle(String key, String label) => toggleRow(
    t(label),
    preference(app, key) == true,
    (value) => run(() => writePreference(app, key, value)),
  );
  Widget option(String key, String label, List<RecordData> options) => ItemRow(
    t(label),
    value: t(optionName(options, preference(app, key))),
    onTap: () async {
      final chosen = await choose<String>(context, t(label), {
        for (final e in options) string(e['id']): t(string(e['name'])),
      }, selected: string(preference(app, key)));
      if (chosen != null) {
        await run(
          () => writePreference(
            app,
            key,
            options.firstWhere((e) => string(e['id']) == chosen)['id'],
          ),
        );
      }
    },
  );
}
