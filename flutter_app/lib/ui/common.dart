import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ReorderableListView, Theme;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/list_settings.dart';
import '../core/money.dart';
import 'reference_icons.dart';

export 'package:flutter/cupertino.dart';
export 'package:flutter_riverpod/flutter_riverpod.dart';
export 'package:go_router/go_router.dart';

export '../core/app_controller.dart';
export '../core/transaction_ordering.dart';

typedef RecordData = Map<String, dynamic>;
String tr(BuildContext context, String key) => ProviderScope.containerOf(
  context,
  listen: false,
).read(appControllerProvider).t(key);
const brand = Color(0xffd43f3f);
const chartPalette = <Color>[
  Color(0xffcc4a66),
  Color(0xffe3564a),
  Color(0xfffc892c),
  Color(0xffffc349),
  Color(0xff4dd291),
  Color(0xff24ceb3),
  Color(0xff2ab4d0),
  Color(0xff065786),
  Color(0xff713670),
  Color(0xff8e1d51),
];
List<Color> appChartColors(AppController app) {
  return effectiveChartColors(
    string(app.settings['chartColors']),
    chartPalette
        .map((color) => color.toARGB32().toRadixString(16).substring(2))
        .toList(),
  ).map(itemColor).toList();
}

int number(dynamic value) => value is int ? value : int.tryParse('$value') ?? 0;
String string(dynamic value) => value?.toString() ?? '';
List<RecordData> records(dynamic value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
    : <RecordData>[];
List<RecordData> flatten(List<RecordData> items, String children) => [
  for (final item in items) ...[
    item,
    ...flatten(records(item[children]), children),
  ],
];
Set<String> expandSelection(
  Iterable<String> selected,
  List<RecordData> roots,
  String children,
) {
  final result = selected.toSet();
  for (final item in flatten(roots, children)) {
    if (result.contains(string(item['id']))) {
      result.addAll(
        flatten(
          records(item[children]),
          children,
        ).map((child) => string(child['id'])),
      );
    }
  }
  return result;
}

RecordData lookup(List<RecordData> items, dynamic id) =>
    items.where((item) => string(item['id']) == string(id)).firstOrNull ?? {};
String recordName(List<RecordData> items, dynamic id) =>
    string(lookup(items, id)['name']);
DateTime storedTransactionDate(RecordData item) =>
    DateTime.fromMillisecondsSinceEpoch(
      number(item['time']) * 1000,
      isUtc: true,
    ).add(Duration(minutes: number(item['utcOffset'])));
String isoDate(DateTime value) => DateFormat('yyyy-MM-dd').format(value);
String transactionType(int value) =>
    const {
      1: 'Modify Balance',
      2: 'Income',
      3: 'Expense',
      4: 'Transfer',
    }[value] ??
    'Transaction';
Color itemColor(dynamic hex) => Color(
  0xff000000 |
      (int.tryParse(string(hex).replaceFirst('#', ''), radix: 16) ?? 0xd43f3f),
);
Color amountColor(AppController app, int type, [BuildContext? context]) {
  if (type != 2 && type != 3) {
    return context == null
        ? CupertinoColors.label
        : CupertinoColors.label.resolveFrom(context);
  }
  final selected = number(
    app.user[type == 2 ? 'incomeAmountColor' : 'expenseAmountColor'],
  );
  final color =
      const {
        1: Color(0xff009688),
        2: Color(0xffd43f3f),
        3: Color(0xffe2b60a),
        4: CupertinoDynamicColor.withBrightness(
          color: Color(0xff413935),
          darkColor: Color(0xfffaf0ed),
        ),
      }[selected] ??
      (type == 2
          ? const Color(0xffd43f3f)
          : type == 3
          ? const Color(0xff009688)
          : brand);
  return context == null
      ? color
      : CupertinoDynamicColor.resolve(color, context);
}

List<RecordData> leafAccounts(AppController app) =>
    visibleLeaves(app.accounts, 'subAccounts')
        .where(
          (item) =>
              records(item['subAccounts']).isEmpty && item['hidden'] != true,
        )
        .toList();
List<RecordData> leafCategories(AppController app, int type) =>
    visibleLeaves(app.categories, 'subCategories')
        .where(
          (item) =>
              number(item['type']) == type - 1 &&
              records(item['subCategories']).isEmpty &&
              item['hidden'] != true &&
              string(item['parentId']) != '0',
        )
        .toList();

List<RecordData> visibleLeaves(List<RecordData> roots, String children) => [
  for (final item in roots.where((item) => item['hidden'] != true))
    if (records(item[children]).isEmpty)
      item
    else
      ...visibleLeaves(records(item[children]), children),
];

abstract class NativeState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  AppController get app => ref.read(appControllerProvider);
  bool busy = false;
  String t(String value) => app.t(value);
  String amount(dynamic value, [String currency = '']) => app.formatter.amount(
    value,
    currency: currency.isEmpty ? null : currency,
    showCurrency: currency.isNotEmpty,
  );
  int parseAmount(String value) => app.formatter.parseAmount(value);
  String dateText(DateTime value, {bool time = false}) =>
      app.formatter.date(value, withTime: time);
  DateTime transactionDate(RecordData item) =>
      app.formatter.transactionDate(item);
  Widget buildPage(BuildContext context);
  @override
  Widget build(BuildContext context) {
    ref.watch(appControllerProvider);
    return buildPage(context);
  }

  Future<bool> run(
    Future<void> Function() action, {
    bool success = false,
  }) async {
    if (busy) return false;
    setState(() => busy = true);
    try {
      await action();
      if (success && mounted) await inform(context, t('Success'));
      return true;
    } catch (error) {
      if (mounted) await inform(context, app.errorText(error));
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> onlineMutation(String path, RecordData body) async {
    if (app.pendingCount > 0) {
      await app.refresh();
      if (app.pendingCount > 0) {
        throw StateError(t('Please synchronize pending transactions first'));
      }
    }
    await app.post(path, body);
    await app.refreshAfterMutation();
  }
}

class NativePage extends StatelessWidget {
  const NativePage({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.subnavbar,
    this.bottom,
    this.floating,
    this.onRefresh,
    this.onTitleTap,
    this.titleKey,
    this.busy = false,
    this.back = true,
  });
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  final Widget? subnavbar;
  final Widget? bottom;
  final Widget? floating;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onTitleTap;
  final Key? titleKey;
  final bool busy;
  final bool back;
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    child: DefaultTextStyle(
      style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
        inherit: false,
        color: CupertinoColors.label.resolveFrom(context),
        fontSize: 17,
        decoration: TextDecoration.none,
      ),
      child: SafeArea(
        child: Column(
          children: [
            CupertinoTheme(
              data: CupertinoTheme.of(context).copyWith(
                primaryColor: CupertinoColors.label.resolveFrom(context),
              ),
              child: SizedBox(
                height: 60,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(
                        left: MediaQuery.sizeOf(context).width < 360
                            ? (back && Navigator.of(context).canPop() ? 68 : 16)
                            : (trailing == null ? 68 : 104),
                        right: trailing == null ? 68 : 104,
                      ),
                      child: GestureDetector(
                        key: titleKey,
                        onTap: onTitleTap,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (onTitleTap != null) ...[
                              const SizedBox(width: 4),
                              Icon(
                                CupertinoIcons.chevron_down_circle_fill,
                                size: 14,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (back && Navigator.of(context).canPop())
                      Positioned(
                        left: 16,
                        child: Container(
                          decoration: BoxDecoration(
                            color: CupertinoColors.tertiarySystemFill
                                .resolveFrom(context),
                            shape: BoxShape.circle,
                          ),
                          child: iconButton(
                            CupertinoIcons.chevron_left,
                            tr(context, 'Back'),
                            () => Navigator.of(context).maybePop(),
                          ),
                        ),
                      ),
                    if (busy || trailing != null)
                      Positioned(
                        right: 16,
                        child: Container(
                          decoration: BoxDecoration(
                            color: CupertinoColors.tertiarySystemFill
                                .resolveFrom(context),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: busy
                              ? const Padding(
                                  padding: EdgeInsets.all(14),
                                  child: CupertinoActivityIndicator(),
                                )
                              : trailing!,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            ?subnavbar,
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomScrollView(
                    slivers: [
                      if (onRefresh != null)
                        CupertinoSliverRefreshControl(onRefresh: onRefresh),
                      SliverPadding(
                        padding: EdgeInsets.only(
                          bottom: floating == null ? 24 : 88,
                        ),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate(children),
                        ),
                      ),
                    ],
                  ),
                  ?floating,
                ],
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    ),
  );
}

class Section extends StatelessWidget {
  const Section({
    super.key,
    this.title,
    required this.children,
    this.footer,
    this.margin = const EdgeInsets.fromLTRB(12, 4, 12, 8),
  });
  final String? title;
  final String? footer;
  final List<Widget> children;
  final EdgeInsetsGeometry margin;
  @override
  Widget build(BuildContext context) => children.isEmpty
      ? const SizedBox.shrink()
      : CupertinoListSection.insetGrouped(
          margin: margin,
          decoration: BoxDecoration(
            color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
              context,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          header: title == null ? null : Text(title!),
          footer: footer == null ? null : Text(footer!),
          children: children,
        );
}

class ItemRow extends StatelessWidget {
  const ItemRow(
    this.title, {
    super.key,
    this.value,
    this.subtitle,
    this.subtitleMaxLines = 2,
    this.leading,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.color,
    this.padding = const EdgeInsetsDirectional.fromSTEB(14, 6, 12, 6),
    this.titleWeight,
  });
  final String title;
  final String? value;
  final String? subtitle;
  final int? subtitleMaxLines;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final Color? color;
  final EdgeInsetsGeometry? padding;
  final FontWeight? titleWeight;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          value != null &&
          value!.isNotEmpty &&
          (constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(17) > 21);
      final valueWidget = stacked || value == null || value!.isEmpty
          ? null
          : ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.42,
              ),
              child: Text(
                value!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
              ),
            );
      final actionWidget =
          trailing ?? (onTap == null ? null : const CupertinoListTileChevron());
      final trailingWidget = valueWidget == null && actionWidget == null
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?valueWidget,
                  if (valueWidget != null && actionWidget != null)
                    const SizedBox(width: 8),
                  ?actionWidget,
                ],
              ),
            );
      return CupertinoListTile.notched(
        padding: padding,
        title: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: destructive
                          ? CupertinoColors.destructiveRed
                          : color,
                      fontWeight: titleWeight,
                    ),
                  ),
                  Text(
                    value!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ],
              )
            : Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: destructive ? CupertinoColors.destructiveRed : color,
                  fontWeight: titleWeight,
                ),
              ),
        subtitle: subtitle == null || subtitle!.isEmpty
            ? null
            : Text(
                subtitle!,
                maxLines: subtitleMaxLines,
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
        leading: leading,
        trailing: trailingWidget,
        onTap: onTap,
      );
    },
  );
}

class InputRow extends StatefulWidget {
  const InputRow(
    this.label, {
    super.key,
    this.value = '',
    required this.onChanged,
    this.secret = false,
    this.lines = 1,
    this.keyboard,
    this.readOnly = false,
    this.placeholder,
  });
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool secret;
  final int lines;
  final TextInputType? keyboard;
  final bool readOnly;
  final String? placeholder;
  @override
  State<InputRow> createState() => _InputRowState();
}

class _InputRowState extends State<InputRow> {
  late final controller = TextEditingController(text: widget.value);
  @override
  void didUpdateWidget(InputRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != controller.text) {
      controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 13,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 5),
        CupertinoTextField.borderless(
          style: TextStyle(
            fontSize: 17,
            color: CupertinoColors.label.resolveFrom(context),
          ),
          placeholderStyle: TextStyle(
            fontSize: 17,
            color: CupertinoColors.placeholderText.resolveFrom(context),
          ),
          controller: controller,
          onChanged: widget.onChanged,
          obscureText: widget.secret,
          maxLines: widget.lines,
          keyboardType: widget.keyboard,
          readOnly: widget.readOnly,
          placeholder: widget.placeholder ?? widget.label,
          padding: EdgeInsets.zero,
        ),
      ],
    ),
  );
}

Widget toggleRow(String title, bool value, ValueChanged<bool>? onChanged) =>
    ItemRow(
      title,
      trailing: CupertinoSwitch(
        value: value,
        onChanged: onChanged,
        activeTrackColor: brand,
      ),
    );
Widget actionButton(
  String title,
  VoidCallback action, {
  bool destructive = false,
}) => CupertinoButton(
  onPressed: action,
  child: Text(
    title,
    style: TextStyle(
      color: destructive ? CupertinoColors.destructiveRed : brand,
    ),
  ),
);
Widget iconButton(IconData icon, String label, VoidCallback? action) =>
    Semantics(
      label: label,
      button: true,
      enabled: action != null,
      child: CupertinoButton(
        padding: const EdgeInsets.all(8),
        onPressed: action,
        child: Icon(icon, size: 24),
      ),
    );
Widget emptyState(String message) => Builder(
  builder: (context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Center(
      child: Text(
        message,
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    ),
  ),
);
Widget recordIcon(
  RecordData item, {
  IconData fallback = CupertinoIcons.square_grid_2x2,
}) => Builder(
  builder: (context) => SizedBox(
    width: 32,
    height: 32,
    child: number(item['iconType']) == 1
        ? _CustomRecordIcon(
            id: string(item['icon']),
            color: string(item['color']) == '000000'
                ? CupertinoColors.label.resolveFrom(context)
                : itemColor(item['color']),
          )
        : Icon(
            referenceIcons[item.containsKey('currency')
                    ? 'account'
                    : 'category']?[string(item['icon'])] ??
                fallback,
            color: string(item['color']) == '000000'
                ? CupertinoColors.label.resolveFrom(context)
                : itemColor(item['color']),
            size: 28,
          ),
  ),
);

class _CustomRecordIcon extends ConsumerStatefulWidget {
  const _CustomRecordIcon({required this.id, required this.color});
  final String id;
  final Color color;
  @override
  ConsumerState<_CustomRecordIcon> createState() => _CustomRecordIconState();
}

class _CustomRecordIconState extends ConsumerState<_CustomRecordIcon> {
  Uint8List? bytes;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(_CustomRecordIcon old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) load();
  }

  Future<void> load() async {
    final app = ref.read(appControllerProvider);
    final cache = Map<String, dynamic>.from(
      app.settings['cachedCustomIconImages'] as Map? ?? {},
    );
    bytes = null;
    try {
      if (cache[widget.id] is String) {
        bytes = base64Decode(cache[widget.id]);
      } else {
        final response = await app.api.authenticatedRequest(
          () => app.api.dio.get<List<int>>(
            '${app.serverUrl}icons/${Uri.encodeComponent(widget.id)}.png',
            options: app.api.options.copyWith(responseType: ResponseType.bytes),
          ),
        );
        bytes = Uint8List.fromList(response.data!);
        await app.setPreference('cachedCustomIconImages', {
          ...Map<String, dynamic>.from(
            app.settings['cachedCustomIconImages'] as Map? ?? {},
          ),
          widget.id: base64Encode(bytes!),
        });
      }
    } catch (_) {
      bytes = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => bytes == null
      ? const Icon(CupertinoIcons.photo, size: 24)
      : Image.memory(
          bytes!,
          width: 24,
          height: 24,
          color: CupertinoDynamicColor.resolve(widget.color, context),
          colorBlendMode: BlendMode.srcIn,
          errorBuilder: (_, _, _) => const Icon(CupertinoIcons.photo, size: 24),
        );
}

Future<void> inform(BuildContext context, String message) =>
    showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'OK')),
          ),
        ],
      ),
    );
Future<bool> confirm(
  BuildContext context,
  String title, {
  String? message,
  bool destructive = false,
}) async =>
    await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'Cancel')),
          ),
          CupertinoDialogAction(
            isDestructiveAction: destructive,
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'Confirm')),
          ),
        ],
      ),
    ) ??
    false;
Future<String?> prompt(
  BuildContext context,
  String title, {
  String initial = '',
  bool secret = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showCupertinoDialog<String>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(title),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: CupertinoTextField(
          controller: controller,
          autofocus: true,
          obscureText: secret,
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'Cancel')),
        ),
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(tr(context, 'Save')),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

CupertinoPageRoute<T> nativeRoute<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final settings = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appControllerProvider).settings;
  return _PreferencePageRoute<T>(
    builder: builder,
    animate: settings['animate'] != false,
    swipeBack: settings['swipeBack'] != false,
  );
}

class _PreferencePageRoute<T> extends CupertinoPageRoute<T> {
  _PreferencePageRoute({
    required super.builder,
    required this.animate,
    required this.swipeBack,
  });
  final bool animate;
  final bool swipeBack;
  @override
  bool get popGestureEnabled => swipeBack && super.popGestureEnabled;
  @override
  Duration get transitionDuration =>
      animate ? super.transitionDuration : Duration.zero;
}

Future<T?> choose<T>(
  BuildContext context,
  String title,
  Map<T, String> choices, {
  T? selected,
}) => showCupertinoModalPopup<T>(
  context: context,
  builder: (sheetContext) => choices.length <= 12
      ? CupertinoActionSheet(
          title: Text(title),
          actions: [
            for (final entry in choices.entries)
              CupertinoActionSheetAction(
                isDefaultAction: entry.key == selected,
                onPressed: () => Navigator.pop(sheetContext, entry.key),
                child: SizedBox(
                  width: double.infinity,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (entry.key == selected)
                        const PositionedDirectional(
                          start: 0,
                          child: Icon(CupertinoIcons.check_mark, size: 18),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(
                          entry.value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheetContext),
            child: Text(tr(context, 'Cancel')),
          ),
        )
      : SizedBox(
          height: MediaQuery.sizeOf(context).height * .82,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: SelectionPage<T>(
              title: title,
              choices: choices,
              selected: selected,
            ),
          ),
        ),
);

/// Original mobile popovers open toward the available side of their anchor.
Future<T?> anchoredPopover<T>(
  BuildContext anchor,
  WidgetBuilder builder, {
  double maxHeight = 400,
}) {
  final box = anchor.findRenderObject()! as RenderBox;
  final position = box.localToGlobal(Offset.zero);
  final media = MediaQuery.of(anchor);
  final width = math.min(260.0, media.size.width - 32);
  final left = (position.dx + box.size.width / 2 - width / 2).clamp(
    16.0,
    media.size.width - width - 16,
  );
  final anchorBottom = position.dy + box.size.height;
  final below = position.dy + box.size.height / 2 < media.size.height / 2;
  final availableHeight = below
      ? media.size.height -
            media.padding.bottom -
            media.viewInsets.bottom -
            anchorBottom -
            24
      : position.dy - media.padding.top - 24;
  final height = math.max(0.0, math.min(maxHeight, availableHeight));
  return showCupertinoModalPopup<T>(
    context: anchor,
    builder: (context) => Stack(
      children: [
        Positioned(
          left: left,
          top: below ? anchorBottom + 8 : null,
          bottom: below ? null : media.size.height - position.dy + 8,
          width: width,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: CupertinoColors.secondarySystemGroupedBackground
                  .resolveFrom(context),
              borderRadius: BorderRadius.circular(32),
            ),
            constraints: BoxConstraints(maxHeight: height),
            child: SingleChildScrollView(child: builder(context)),
          ),
        ),
        Positioned(
          left: (position.dx + box.size.width / 2 - 7).clamp(
            left + 28,
            left + width - 42,
          ),
          top: below ? anchorBottom + 1 : null,
          bottom: below ? null : media.size.height - position.dy + 1,
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 14,
              height: 14,
              color: CupertinoColors.secondarySystemGroupedBackground
                  .resolveFrom(context),
            ),
          ),
        ),
      ],
    ),
  );
}

class SelectionPage<T> extends StatefulWidget {
  const SelectionPage({
    super.key,
    required this.title,
    required this.choices,
    this.selected,
  });
  final String title;
  final Map<T, String> choices;
  final T? selected;
  @override
  State<SelectionPage<T>> createState() => _SelectionPageState<T>();
}

class _SelectionPageState<T> extends State<SelectionPage<T>> {
  String filter = '';
  @override
  Widget build(BuildContext context) => NativePage(
    title: widget.title,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: CupertinoSearchTextField(
          onChanged: (value) => setState(() => filter = value),
        ),
      ),
      Section(
        children: [
          for (final entry in widget.choices.entries.where(
            (entry) => entry.value.toLowerCase().contains(filter.toLowerCase()),
          ))
            ItemRow(
              entry.value,
              trailing: entry.key == widget.selected
                  ? const Icon(CupertinoIcons.check_mark, color: brand)
                  : null,
              onTap: () => Navigator.pop(context, entry.key),
            ),
        ],
      ),
    ],
  );
}

Future<String?> chooseGroupedRecord(
  BuildContext context,
  String title,
  List<RecordData> groups, {
  required String childrenKey,
  required String selected,
  required String emptyText,
  bool showGroupHeaders = true,
}) => showCupertinoModalPopup<String>(
  context: context,
  builder: (sheetContext) => SizedBox(
    height: MediaQuery.sizeOf(sheetContext).height * .5,
    child: ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: _GroupedRecordSelectionPage(
        title: title,
        groups: groups,
        childrenKey: childrenKey,
        selected: selected,
        emptyText: emptyText,
        showGroupHeaders: showGroupHeaders,
      ),
    ),
  ),
);

class _GroupedRecordSelectionPage extends StatefulWidget {
  const _GroupedRecordSelectionPage({
    required this.title,
    required this.groups,
    required this.childrenKey,
    required this.selected,
    required this.emptyText,
    required this.showGroupHeaders,
  });
  final String title;
  final List<RecordData> groups;
  final String childrenKey;
  final String selected;
  final String emptyText;
  final bool showGroupHeaders;

  @override
  State<_GroupedRecordSelectionPage> createState() =>
      _GroupedRecordSelectionPageState();
}

class _GroupedRecordSelectionPageState
    extends State<_GroupedRecordSelectionPage> {
  String filter = '';
  late String activeGroupId = _initialGroupId();

  String _initialGroupId() {
    for (final group in widget.groups) {
      if (records(group[widget.childrenKey])
          .any((item) => string(item['id']) == widget.selected)) {
        return string(group['id']);
      }
    }
    return widget.groups.isEmpty ? '' : string(widget.groups.first['id']);
  }

  Widget _choice(
    BuildContext context,
    RecordData item, {
    required bool selected,
    required VoidCallback onPressed,
  }) => Semantics(
    button: true,
    selected: selected,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.zero,
      minimumSize: const Size(48, 48),
      onPressed: onPressed,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: selected ? brand.withValues(alpha: .1) : const Color(0x00000000),
        child: Row(
          children: [
            ExcludeSemantics(child: recordIcon(item)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                string(item['name']),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? brand
                      : CupertinoColors.label.resolveFrom(context),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (selected && !widget.showGroupHeaders)
              const Padding(
                padding: EdgeInsetsDirectional.only(start: 4),
                child: Icon(CupertinoIcons.check_mark, color: brand, size: 20),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final query = filter.trim().toLowerCase();
    final visibleGroups = <RecordData>[];
    for (final group in widget.groups) {
      final groupMatches = string(group['name']).toLowerCase().contains(query);
      final childMatches = records(group[widget.childrenKey])
          .any((item) => string(item['name']).toLowerCase().contains(query));
      if (query.isEmpty || groupMatches || childMatches) {
        visibleGroups.add(group);
      }
    }
    final activeGroup =
        visibleGroups
            .where((group) => string(group['id']) == activeGroupId)
            .firstOrNull ??
        visibleGroups.firstOrNull;
    final groupMatches =
        activeGroup != null &&
        string(activeGroup['name']).toLowerCase().contains(query);
    final visibleChildren = activeGroup == null
        ? <RecordData>[]
        : records(activeGroup[widget.childrenKey]).where((item) {
            return query.isEmpty ||
                groupMatches ||
                string(item['name']).toLowerCase().contains(query);
          }).toList();
    final background = CupertinoColors.systemGroupedBackground.resolveFrom(
      context,
    );
    final surface = CupertinoColors.secondarySystemGroupedBackground
        .resolveFrom(context);
    return Container(
      color: background,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 64),
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    start: 8,
                    child: iconButton(
                      CupertinoIcons.xmark,
                      tr(context, 'Cancel'),
                      () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: CupertinoSearchTextField(
                onChanged: (value) => setState(() => filter = value),
              ),
            ),
            Expanded(
              child: visibleGroups.isEmpty
                  ? emptyState(widget.emptyText)
                  : widget.showGroupHeaders
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 5,
                          child: ColoredBox(
                            color: surface,
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              itemCount: visibleGroups.length,
                              itemBuilder: (context, index) {
                                final group = visibleGroups[index];
                                final selected =
                                    string(group['id']) ==
                                    string(activeGroup?['id']);
                                return _choice(
                                  context,
                                  group,
                                  selected: selected,
                                  onPressed: () => setState(
                                    () => activeGroupId = string(group['id']),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        Container(
                          width: .5,
                          color: CupertinoColors.separator.resolveFrom(context),
                        ),
                        Expanded(
                          flex: 6,
                          child: ListView.builder(
                            padding: EdgeInsets.zero,
                            itemCount: visibleChildren.length,
                            itemBuilder: (context, index) {
                              final item = visibleChildren[index];
                              return _choice(
                                context,
                                item,
                                selected: string(item['id']) == widget.selected,
                                onPressed: () =>
                                    Navigator.pop(context, string(item['id'])),
                              );
                            },
                          ),
                        ),
                      ],
                    )
                  : ColoredBox(
                      color: surface,
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: visibleChildren.length,
                        itemBuilder: (context, index) {
                          final item = visibleChildren[index];
                          return _choice(
                            context,
                            item,
                            selected: string(item['id']) == widget.selected,
                            onPressed: () =>
                                Navigator.pop(context, string(item['id'])),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<List<String>?> selectMany(
  BuildContext context,
  String title,
  List<RecordData> choices,
  Iterable<String> selected, {
  int minimumSelections = 0,
}) => showCupertinoModalPopup<List<String>>(
  context: context,
  builder: (_) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .82,
    child: ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: MultiSelectionPage(
        title: title,
        choices: choices,
        selected: selected.toSet(),
        minimumSelections: minimumSelections,
      ),
    ),
  ),
);

void updateTreeSelection(
  List<RecordData> choices,
  Set<String> selected,
  RecordData item,
  bool checked,
) {
  final childKey = item.containsKey('subAccounts')
      ? 'subAccounts'
      : 'subCategories';
  final descendants = flatten([
    item,
  ], childKey).map((value) => string(value['id'])).toSet();
  checked ? selected.addAll(descendants) : selected.removeAll(descendants);
  var parent = string(item['parentId']);
  final visited = <String>{};
  while (parent.isNotEmpty && parent != '0' && visited.add(parent)) {
    final record = lookup(choices, parent);
    if (record.isEmpty) break;
    final siblings = flatten(records(record[childKey]), childKey);
    if (checked &&
        siblings.every((sibling) => selected.contains(string(sibling['id'])))) {
      selected.add(parent);
    } else {
      selected.remove(parent);
    }
    parent = string(record['parentId']);
  }
}

class MultiSelectionPage extends StatefulWidget {
  const MultiSelectionPage({
    super.key,
    required this.title,
    required this.choices,
    required this.selected,
    this.minimumSelections = 0,
  });
  final String title;
  final List<RecordData> choices;
  final Set<String> selected;
  final int minimumSelections;
  @override
  State<MultiSelectionPage> createState() => _MultiSelectionPageState();
}

class _MultiSelectionPageState extends State<MultiSelectionPage> {
  late final selected = {...widget.selected};
  String filter = '';
  @override
  Widget build(BuildContext context) => NativePage(
    title: widget.title,
    trailing: iconButton(
      CupertinoIcons.check_mark,
      tr(context, 'Save'),
      selected.length < widget.minimumSelections
          ? null
          : () => Navigator.pop(context, selected.toList()),
    ),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: CupertinoSearchTextField(
          onChanged: (value) => setState(() => filter = value),
        ),
      ),
      Section(
        children: [
          for (final item in widget.choices.where(
            (item) =>
                string(item['name'])
                    .toLowerCase()
                    .contains(filter.toLowerCase()),
          ))
            toggleRow(
              string(item['name']),
              selected.contains(string(item['id'])),
              selected.contains(string(item['id'])) &&
                      selected.length <= widget.minimumSelections
                  ? null
                  : (checked) => setState(() {
                      updateTreeSelection(
                        widget.choices,
                        selected,
                        item,
                        checked,
                      );
                    }),
            ),
        ],
      ),
    ],
  );
}

Future<DateTime?> pickDate(
  BuildContext context,
  String title,
  DateTime initial, {
  bool time = true,
}) async {
  DateTime chosen = initial;
  var mode = time ? 1 : 0;
  final formatter = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appControllerProvider).formatter;
  final tokens = RegExp(r'HH|hh|mm|ss|H|h|m|s|A')
      .allMatches(formatter.timePattern(withSeconds: true))
      .map((match) => match[0]!)
      .toList();
  int initialIndex(String token) => switch (token[0]) {
    'H' => initial.hour,
    'h' => (initial.hour + 11) % 12,
    'm' => initial.minute,
    's' => initial.second,
    _ => initial.hour ~/ 12,
  };
  final controllers = [
    for (final token in tokens)
      FixedExtentScrollController(initialItem: initialIndex(token)),
  ];
  try {
    return await showCupertinoModalPopup<DateTime>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          height: 340,
          color: CupertinoColors.systemBackground.resolveFrom(context),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr(context, 'Cancel')),
                    ),
                    Expanded(child: Text(title, textAlign: TextAlign.center)),
                    CupertinoButton(
                      onPressed: () => Navigator.pop(context, chosen),
                      child: Text(tr(context, 'Done')),
                    ),
                  ],
                ),
                if (time)
                  CupertinoSlidingSegmentedControl<int>(
                    groupValue: mode,
                    children: {
                      0: Text(tr(context, 'Date')),
                      1: Text(tr(context, 'Time')),
                    },
                    onValueChanged: (value) {
                      if (value != null) setSheetState(() => mode = value);
                    },
                  ),
                Expanded(
                  child: mode == 0
                      ? CupertinoDatePicker(
                          mode: CupertinoDatePickerMode.date,
                          initialDateTime: chosen,
                          minimumYear: 1900,
                          maximumYear: 2200,
                          onDateTimeChanged: (value) =>
                              chosen = chosen.copyWith(
                                year: value.year,
                                month: value.month,
                                day: value.day,
                              ),
                        )
                      : Row(
                          children: [
                            for (var i = 0; i < tokens.length; i++)
                              Expanded(
                                child: CupertinoPicker(
                                  scrollController: controllers[i],
                                  itemExtent: 40,
                                  onSelectedItemChanged: (value) {
                                    chosen = switch (tokens[i][0]) {
                                      'H' => chosen.copyWith(hour: value),
                                      'h' => chosen.copyWith(
                                        hour:
                                            (value + 1) % 12 +
                                            chosen.hour ~/ 12 * 12,
                                      ),
                                      'm' => chosen.copyWith(minute: value),
                                      's' => chosen.copyWith(second: value),
                                      _ => chosen.copyWith(
                                        hour: chosen.hour % 12 + value * 12,
                                      ),
                                    };
                                  },
                                  children: [
                                    for (
                                      var value = 0;
                                      value <
                                          switch (tokens[i][0]) {
                                            'H' => 24,
                                            'h' => 12,
                                            'A' => 2,
                                            _ => 60,
                                          };
                                      value++
                                    )
                                      Center(
                                        child: Text(
                                          formatter.pattern(
                                            DateTime(
                                              2000,
                                              1,
                                              1,
                                              tokens[i][0] == 'h'
                                                  ? value + 1
                                                  : tokens[i][0] == 'A'
                                                  ? value * 12
                                                  : value,
                                              value,
                                              value,
                                            ),
                                            tokens[i],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } finally {
    for (final controller in controllers) {
      controller.dispose();
    }
  }
}

Future<List<RecordData>?> reorderItems(
  BuildContext context,
  String title,
  List<RecordData> items,
) => Navigator.of(context).push<List<RecordData>>(
  nativeRoute(
    context,
    builder: (_) => _ReorderPage(title: title, items: items),
  ),
);

class _ReorderPage extends StatefulWidget {
  const _ReorderPage({required this.title, required this.items});
  final String title;
  final List<RecordData> items;
  @override
  State<_ReorderPage> createState() => _ReorderPageState();
}

class _ReorderPageState extends State<_ReorderPage> {
  late final items = [...widget.items];
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(widget.title),
      trailing: iconButton(
        CupertinoIcons.check_mark,
        tr(context, 'Save'),
        () => Navigator.pop(context, items),
      ),
    ),
    child: SafeArea(
      child: ReorderableListView(
        onReorderItem: (oldIndex, newIndex) => setState(() {
          items.insert(newIndex, items.removeAt(oldIndex));
        }),
        children: [
          for (final item in items)
            ItemRow(
              string(item['name']),
              key: ValueKey(item['id']),
              trailing: const Icon(CupertinoIcons.line_horizontal_3),
            ),
        ],
      ),
    ),
  );
}

Future<int?> amountPad(
  BuildContext context,
  int initial, {
  bool instant = false,
}) {
  if (!instant) {
    return showCupertinoModalPopup<int>(
      context: context,
      builder: (_) => _AmountPad(initial),
    );
  }
  return Navigator.of(context, rootNavigator: true).push(
    _InstantCupertinoModalPopupRoute<int>(
      builder: (_) => _AmountPad(initial),
      barrierColor: CupertinoDynamicColor.resolve(
        kCupertinoModalBarrierColor,
        context,
      ),
    ),
  );
}

class _InstantCupertinoModalPopupRoute<T> extends CupertinoModalPopupRoute<T> {
  _InstantCupertinoModalPopupRoute({
    required super.builder,
    required super.barrierColor,
  });

  @override
  Duration get transitionDuration => Duration.zero;
}

class _AmountPad extends StatefulWidget {
  const _AmountPad(this.initial);
  final int initial;
  @override
  State<_AmountPad> createState() => _AmountPadState();
}

class _AmountPadState extends State<_AmountPad> {
  AppController get app => ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appControllerProvider);
  late String input = Money.format(widget.initial);
  int? accumulator;
  String? operator;
  bool replace = true;
  String? error;
  void press(String key) {
    setState(() {
      error = null;
      try {
        if (key == 'C') {
          input = '0';
          accumulator = null;
          operator = null;
          replace = true;
        } else if (key == '⌫') {
          input = input.length > 1 ? input.substring(0, input.length - 1) : '0';
        } else if (['+', '−', '×', '÷'].contains(key)) {
          final right = Money.parse(input);
          if (accumulator != null && operator != null && !replace) {
            final left = accumulator!;
            accumulator = Money.calculate(
              '${Money.format(left)}$operator${Money.format(right)}',
            );
            input = Money.format(accumulator!);
          } else {
            accumulator = right;
          }
          operator = key;
          replace = true;
        } else if (key == '±') {
          input = input.startsWith('-') ? input.substring(1) : '-$input';
        } else if (key == 'Done') {
          final value = accumulator != null && operator != null && !replace
              ? Money.calculate('${Money.format(accumulator!)}$operator$input')
              : Money.parse(input);
          Navigator.pop(context, value);
        } else {
          if (replace) {
            input = key == '.'
                ? '0.'
                : key == '00'
                ? '0'
                : key;
            replace = false;
          } else if (key != '.' || !input.contains('.')) {
            input = input == '0' && key != '.'
                ? key == '00'
                      ? '0'
                      : key
                : input + key;
          }
          if (input.contains('.') && input.split('.').last.length > 2) {
            input = input.substring(0, input.length - 1);
          }
        }
      } catch (e) {
        error = e.toString();
      }
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Container(
      color: CupertinoColors.systemBackground.resolveFrom(context),
      height: math.min(
        440,
        MediaQuery.sizeOf(context).height -
            MediaQuery.viewPaddingOf(context).vertical,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Text(
                    app.formatter.digits(
                      input.replaceAll('.', app.formatter.decimalSeparator),
                    ),
                    style: const TextStyle(fontSize: 34, color: brand),
                  ),
                ),
              ),
            ),
            if (error != null)
              Text(
                app.errorText(FormatException(error!)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: CupertinoColors.destructiveRed),
              ),
            for (final row in [
              ['C', '±', '⌫', '÷'],
              ['1', '2', '3', '×'],
              ['4', '5', '6', '−'],
              ['7', '8', '9', '+'],
              ['00', '0', '.', 'Done'],
            ])
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final key in row)
                      Expanded(
                        child: CupertinoButton(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(48, 48),
                          onPressed: () => press(key),
                          child: key == 'Done'
                              ? Icon(
                                  CupertinoIcons.check_mark,
                                  semanticLabel: app.t('Done'),
                                )
                              : Text(
                                  key == '.'
                                      ? app.formatter.decimalSeparator
                                      : app.formatter.digits(key),
                                  style: TextStyle(
                                    fontSize: math.min(
                                      key.length == 1 ? 26 : 18,
                                      26,
                                    ),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
