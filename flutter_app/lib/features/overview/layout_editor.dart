part of 'home.dart';

class _OverviewLayoutState extends NativeState<OverviewLayoutPage> {
  RecordData definitions = {};
  late List<RecordData> widgets = records(
    jsonDecode(jsonEncode(overviewLayout(app)))['widgets'],
  );
  String original = '';
  bool closing = false;
  String get serialized =>
      jsonEncode(normalizeMobileLayout({'widgets': widgets}, definitions));
  bool get modified => definitions.isNotEmpty && serialized != original;
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        definitions = Map<String, dynamic>.from(
          jsonDecode(
            await rootBundle.loadString(
              'assets/reference/overview_widgets.json',
            ),
          ),
        );
        original = serialized;
      }),
    );
  }

  Future<void> close() async {
    if (modified &&
        !await confirm(context, t('Discard unsaved layout changes?'))) {
      return;
    }
    if (!mounted) return;
    setState(() => closing = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) context.pop();
  }

  Future<void> save() async {
    if (!modified || busy) return;
    final saved = await run(() async {
      final text = serialized;
      final defaults = jsonEncode(
        normalizeMobileLayout(defaultOverview, definitions),
      );
      await app.setPreference(
        'mobileOverviewPageLayout',
        text == defaults ? '' : text,
      );
      original = text;
    });
    if (saved && mounted) await close();
  }

  Future<void> add() async {
    if (widgets.length >= 100) {
      await inform(context, t('Too many widgets'));
      return;
    }
    final type = await choose(context, t('Add Widget'), {
      for (final entry in definitions.entries)
        entry.key: t(string(entry.value['name'])),
    });
    if (type != null && mounted) {
      setState(
        () => widgets.add({
          'id': 'native-${DateTime.now().microsecondsSinceEpoch}',
          'type': type,
          'settings': jsonDecode(
            jsonEncode(definitions[type]['defaultSettings']),
          ),
        }),
      );
    }
  }

  Future<void> widgetActions(RecordData item) async {
    final action = await choose(
      context,
      t(string(definitions[item['type']]?['name'])),
      {
        if (records(definitions[item['type']]?['supportsSettings']).isNotEmpty)
          'settings': t('Settings'),
        'duplicate': t('Duplicate'),
        'delete': t('Delete'),
      },
    );
    if (action == null || !mounted) return;
    if (action == 'delete') setState(() => widgets.remove(item));
    if (action == 'duplicate') {
      if (widgets.length >= 100) {
        await inform(context, t('Too many widgets'));
        return;
      }
      setState(
        () => widgets.insert(widgets.indexOf(item) + 1, {
          ...Map<String, dynamic>.from(jsonDecode(jsonEncode(item))),
          'id': 'native-${DateTime.now().microsecondsSinceEpoch}',
        }),
      );
    }
    if (action == 'settings') {
      final value = await Navigator.of(context).push<RecordData>(
        nativeRoute(
          context,
          builder: (_) => OverviewWidgetSettingsPage(
            definition: Map<String, dynamic>.from(definitions[item['type']]),
            settings: Map<String, dynamic>.from(item['settings'] ?? {}),
          ),
        ),
      );
      if (value != null && mounted) setState(() => item['settings'] = value);
    }
  }

  Future<void> more() async {
    final action = await choose(context, t('More'), {
      'add': t('Add Widget'),
      'reset': t('Reset to Default'),
      if (widgets.isNotEmpty) 'clear': t('Clear Layout'),
      'import': t('Import Layout'),
      'export': t('Export Layout'),
    });
    if (action == null || !mounted) return;
    if (action == 'add') await add();
    if (!mounted) return;
    if (action == 'reset' || action == 'clear') {
      if (await confirm(
            context,
            t(
              action == 'reset'
                  ? 'Reset the layout to its default value?'
                  : 'Clear all widgets from the layout?',
            ),
          ) &&
          mounted) {
        setState(
          () => widgets = action == 'reset'
              ? records(jsonDecode(jsonEncode(defaultOverview))['widgets'])
              : [],
        );
      }
    }
    if (mounted && (action == 'import' || action == 'export')) {
      final imported = await showCupertinoModalPopup<String>(
        context: context,
        builder: (_) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .85,
          child: LayoutTextSheet(
            exportText: action == 'export'
                ? const JsonEncoder.withIndent('  ')
                      .convert(jsonDecode(serialized))
                : null,
          ),
        ),
      );
      if (action == 'import' && imported != null && mounted) {
        await run(() async {
          try {
            widgets = records(
              normalizeMobileLayout(
                jsonDecode(imported),
                definitions,
              )['widgets'],
            );
          } catch (_) {
            throw const FormatException(
              'Layout import failed. Please make sure the layout is valid and try again.',
            );
          }
        });
      }
    }
  }

  @override
  Widget buildPage(BuildContext _) => PopScope(
    canPop: closing || !modified,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) close();
    },
    child: NativePage(
      title: t('Home Page Layout'),
      busy: busy,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconButton(CupertinoIcons.ellipsis, t('More'), busy ? null : more),
          iconButton(
            CupertinoIcons.check_mark,
            t('Save'),
            modified && !busy ? save : null,
          ),
        ],
      ),
      children: [
        if (widgets.isEmpty)
          Section(
            children: [
              ItemRow(t('No widgets')),
              ItemRow(t('Add Widget'), onTap: add),
            ],
          ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: widgets.length,
          onReorderItem: (from, to) => setState(() {
            widgets.insert(to, widgets.removeAt(from));
          }),
          itemBuilder: (context, index) {
            final item = widgets[index];
            return ReorderableDelayedDragStartListener(
              key: ValueKey(item['id']),
              index: index,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widgetActions(item),
                child: IgnorePointer(child: HomePage(previewWidget: item)),
              ),
            );
          },
        ),
      ],
    ),
  );
}

class LayoutTextSheet extends ConsumerStatefulWidget {
  const LayoutTextSheet({super.key, this.exportText});
  final String? exportText;
  @override
  ConsumerState<LayoutTextSheet> createState() => _LayoutTextState();
}

class _LayoutTextState extends NativeState<LayoutTextSheet> {
  late final controller = TextEditingController(text: widget.exportText ?? '');
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(BuildContext _) => NativePage(
    title: t(widget.exportText == null ? 'Import Layout' : 'Export Layout'),
    children: [
      Section(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: CupertinoTextField(
              controller: controller,
              readOnly: widget.exportText != null,
              minLines: 12,
              maxLines: 15,
              placeholder: '{"widgets": []}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: CupertinoColors.label.resolveFrom(context),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
      if (widget.exportText == null)
        CupertinoButton.filled(
          onPressed: controller.text.isEmpty
              ? null
              : () => Navigator.pop(context, controller.text),
          child: Text(t('Import')),
        )
      else
        actionButton(t('Copy'), () async {
          await Clipboard.setData(ClipboardData(text: controller.text));
          if (mounted) await inform(context, t('Data copied'));
        }),
    ],
  );
}
