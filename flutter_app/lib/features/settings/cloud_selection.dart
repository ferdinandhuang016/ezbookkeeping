/// Draft cloud-setting selection. Remote refreshes update the saved keys without
/// discarding a user's unsubmitted changes; related keys follow their main item.
class CloudSettingsSelection {
  CloudSettingsSelection(this.groups);
  final List<Map<String, dynamic>> groups;
  final selected = <String>{};
  final saved = <String>{};
  bool enabled = false;

  Iterable<Map<String, dynamic>> get items => groups.expand(
    (group) => (group['items'] as List).cast<Map<String, dynamic>>(),
  );
  Iterable<String> itemKeys(Map<String, dynamic> item) => [
    item['settingKey'] as String,
    ...(item['relatedSettingKeys'] as List? ?? []).cast<String>(),
  ];
  Set<String> get allowed => items.expand(itemKeys).toSet();
  bool get changed =>
      selected.length != saved.length || !selected.containsAll(saved);
  bool? groupValue(Map<String, dynamic> group) {
    final rows = (group['items'] as List).cast<Map<String, dynamic>>();
    final count = rows
        .where((item) => selected.contains(item['settingKey']))
        .length;
    return count == 0
        ? false
        : count == rows.length
        ? true
        : null;
  }

  void selectItem(Map<String, dynamic> item, bool value) {
    value
        ? selected.addAll(itemKeys(item))
        : selected.removeAll(itemKeys(item));
  }

  void selectGroup(Map<String, dynamic> group, bool value) {
    for (final item in (group['items'] as List).cast<Map<String, dynamic>>()) {
      selectItem(item, value);
    }
  }

  void selectAll(bool value) {
    for (final item in items) {
      selectItem(item, value);
    }
  }

  void invert() {
    for (final item in items) {
      selectItem(item, !selected.contains(item['settingKey']));
    }
  }

  Set<String> remoteKeys(dynamic rows) {
    if (rows != false && rows is! List) {
      throw const FormatException(
        'Unable to retrieve user synchronized application settings',
      );
    }
    return rows is List
        ? rows
              .whereType<Map>()
              .map((row) => row['settingKey'].toString())
              .toSet()
              .intersection(allowed)
        : <String>{};
  }

  void acceptRemote(dynamic rows, {bool preserveDraft = true}) {
    final keys = remoteKeys(rows);
    final keep = preserveDraft && changed;
    saved
      ..clear()
      ..addAll(keys);
    enabled = rows is List && rows.isNotEmpty;
    if (!keep) {
      selected
        ..clear()
        ..addAll(keys);
    }
  }
}
