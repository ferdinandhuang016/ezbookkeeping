import 'package:flutter/material.dart' show ReorderableListView, SelectableText;
import 'package:flutter/services.dart';

import '../../core/list_settings.dart';
import '../../ui/common.dart';
import 'data_settings.dart' show settingsNotice;

Future<void> editChartColor(
  BuildContext context,
  String color,
  ValueChanged<String> onChanged,
) => showCupertinoSheet<void>(
  context: context,
  showDragHandle: true,
  scrollableBuilder: (_, controller) =>
      _ChartColorPicker(color: color, onChanged: onChanged),
);

class _ChartColorPicker extends StatefulWidget {
  const _ChartColorPicker({required this.color, required this.onChanged});
  final String color;
  final ValueChanged<String> onChanged;
  @override
  State<_ChartColorPicker> createState() => _ChartColorPickerState();
}

class _ChartColorPickerState extends State<_ChartColorPicker> {
  late HSVColor color = HSVColor.fromColor(itemColor(widget.color));
  late final hex = TextEditingController(text: '#${widget.color}');
  bool invalid = false;

  String get value => color.toColor().toARGB32().toRadixString(16).substring(2);

  void update(HSVColor next) {
    setState(() {
      color = next;
      invalid = false;
      hex.text = '#$value';
    });
    widget.onChanged(value);
  }

  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NativePage(
    title: tr(context, 'Color'),
    back: false,
    trailing: iconButton(
      CupertinoIcons.xmark,
      tr(context, 'Close'),
      () => Navigator.pop(context),
    ),
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                void select(Offset point) => update(
                  color
                      .withSaturation(
                        (point.dx / constraints.maxWidth).clamp(0, 1),
                      )
                      .withValue((1 - point.dy / 180).clamp(0, 1)),
                );
                return Semantics(
                  label: tr(context, 'Color'),
                  value: '#$value',
                  child: GestureDetector(
                    onPanDown: (event) => select(event.localPosition),
                    onPanUpdate: (event) => select(event.localPosition),
                    child: SizedBox(
                      height: 180,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    CupertinoColors.white,
                                    HSVColor.fromAHSV(
                                      1,
                                      color.hue,
                                      1,
                                      1,
                                    ).toColor(),
                                  ],
                                ),
                              ),
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0x00000000),
                                      CupertinoColors.black,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: (color.saturation * constraints.maxWidth - 10)
                                .clamp(0, constraints.maxWidth - 20),
                            top: ((1 - color.value) * 180 - 10).clamp(0, 160),
                            child: _ColorThumb(color: color.toColor()),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                void select(Offset point) => update(
                  color.withHue(
                    (point.dx / constraints.maxWidth * 360).clamp(0, 360),
                  ),
                );
                return Semantics(
                  label: tr(context, 'Color'),
                  value: '#$value',
                  slider: true,
                  onIncrease: () =>
                      update(color.withHue((color.hue + 5).clamp(0, 360))),
                  onDecrease: () =>
                      update(color.withHue((color.hue - 5).clamp(0, 360))),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragDown: (event) =>
                        select(event.localPosition),
                    onHorizontalDragUpdate: (event) =>
                        select(event.localPosition),
                    child: SizedBox(
                      height: 48,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            height: 20,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              gradient: LinearGradient(
                                colors: [
                                  for (var hue = 0; hue <= 360; hue += 60)
                                    HSVColor.fromAHSV(
                                      1,
                                      hue.toDouble(),
                                      1,
                                      1,
                                    ).toColor(),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: (color.hue / 360 * constraints.maxWidth - 10)
                                .clamp(0, constraints.maxWidth - 20),
                            child: _ColorThumb(
                              color: HSVColor.fromAHSV(
                                1,
                                color.hue,
                                1,
                                1,
                              ).toColor(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: hex,
              placeholder: tr(context, 'Color'),
              style: const TextStyle(fontFamily: 'monospace'),
              autocorrect: false,
              padding: const EdgeInsets.all(14),
              onChanged: (input) {
                final next = input
                    .trim()
                    .replaceFirst(RegExp('^#'), '')
                    .toLowerCase();
                final valid = RegExp(r'^[0-9a-f]{6}$').hasMatch(next);
                setState(() {
                  invalid = !valid;
                  if (valid) color = HSVColor.fromColor(itemColor(next));
                });
                if (valid) widget.onChanged(next);
              },
            ),
            if (invalid)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr(context, 'Invalid color'),
                  style: const TextStyle(color: CupertinoColors.destructiveRed),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class _ColorThumb extends StatelessWidget {
  const _ColorThumb({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: CupertinoColors.white, width: 2),
      boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 2)],
    ),
  );
}

Future<List<String>?> importChartColorSheet(BuildContext context) =>
    showCupertinoSheet<List<String>>(
      context: context,
      showDragHandle: true,
      scrollableBuilder: (_, controller) => const _ChartColorImport(),
    );

class _ChartColorImport extends StatefulWidget {
  const _ChartColorImport();
  @override
  State<_ChartColorImport> createState() => _ChartColorImportState();
}

class _ChartColorImportState extends State<_ChartColorImport> {
  String input = '';
  String? error;
  @override
  Widget build(BuildContext context) => NativePage(
    title: tr(context, 'Import'),
    back: false,
    trailing: iconButton(
      CupertinoIcons.xmark,
      tr(context, 'Cancel'),
      () => Navigator.pop(context),
    ),
    children: [
      Section(
        children: [
          InputRow(
            tr(context, 'Chart Color Scheme'),
            lines: 8,
            keyboard: TextInputType.multiline,
            placeholder: tr(
              context,
              'Each line should be a hex color value (e.g. c67e48 or #c67e48)',
            ),
            onChanged: (value) => setState(() {
              input = value;
              error = null;
            }),
          ),
        ],
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            tr(context, error!),
            style: const TextStyle(color: CupertinoColors.destructiveRed),
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(20),
        child: CupertinoButton.filled(
          onPressed: input.isEmpty
              ? null
              : () {
                  try {
                    Navigator.pop(context, importChartColors(input));
                  } on FormatException catch (failure) {
                    setState(() => error = failure.message);
                  }
                },
          child: Text(tr(context, 'Import')),
        ),
      ),
      actionButton(tr(context, 'Cancel'), () => Navigator.pop(context)),
    ],
  );
}

Future<void> exportChartColorSheet(BuildContext context, List<String> colors) {
  final text = colors.map((color) => '#$color').join('\n');
  return showCupertinoSheet<void>(
    context: context,
    showDragHandle: true,
    scrollableBuilder: (sheet, controller) => NativePage(
      title: tr(context, 'Export'),
      back: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconButton(CupertinoIcons.doc_on_doc, tr(context, 'Copy'), () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (sheet.mounted) settingsNotice(sheet, tr(sheet, 'Data copied'));
          }),
          iconButton(
            CupertinoIcons.xmark,
            tr(context, 'Close'),
            () => Navigator.pop(sheet),
          ),
        ],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    ),
  );
}

class SettingsOrderList extends StatelessWidget {
  const SettingsOrderList({
    super.key,
    required this.children,
    required this.onReorder,
    this.controller,
  });
  final List<Widget> children;
  final void Function(int, int) onReorder;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // NativePage reserves a 60px navbar and 24px at the scroll content end.
    final available =
        media.size.height -
        media.padding.vertical -
        media.viewInsets.bottom -
        60 -
        24 -
        24;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: SizedBox(
        height: settingsListViewportHeight(
          availableHeight: available,
          itemCount: children.length,
          fontSize: media.textScaler.scale(17),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: ReorderableListView(
            scrollController: controller,
            primary: false,
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) => child,
            onReorderItem: onReorder,
            children: [
              for (final child in children)
                DecoratedBox(
                  key: child.key,
                  decoration: BoxDecoration(
                    color: CupertinoColors.secondarySystemGroupedBackground
                        .resolveFrom(context),
                    border: Border(
                      bottom: BorderSide(
                        color: CupertinoColors.separator.resolveFrom(context),
                        width: .3,
                      ),
                    ),
                  ),
                  child: child,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget settingDragHandle(BuildContext context, int index) =>
    ReorderableDragStartListener(
      index: index,
      child: Semantics(
        label: tr(context, 'Sort'),
        child: const SizedBox(
          width: 48,
          height: 48,
          child: Icon(CupertinoIcons.line_horizontal_3, size: 22),
        ),
      ),
    );
