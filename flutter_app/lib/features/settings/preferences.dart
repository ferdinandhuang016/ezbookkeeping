import '../../core/application_settings.dart';
import '../../core/currency_selection.dart';
import '../../core/formatting.dart';
import '../../core/list_settings.dart';
import '../../ui/common.dart';
import 'chart_settings_sheets.dart';
import 'filter_selection.dart';
import 'cloud_selection.dart';
import 'data_settings.dart' show settingsNotice;
import 'settings_support.dart';

class PreferencesPage extends ConsumerStatefulWidget {
  const PreferencesPage({super.key});
  @override
  ConsumerState<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends SettingsState<PreferencesPage> {
  List<String> get enabledCurrencyCodes {
    final configured = preference(app, 'enabledCurrencies');
    final result = configured is Map
        ? configured.entries
              .where((entry) => entry.value == true)
              .map((entry) => '${entry.key}')
              .toList()
        : <String>['CNY', 'USD'];
    result.sort();
    return result;
  }

  Future<void> selectEnabledCurrencies() async {
    final choices = await currencyChoices();
    if (!mounted) return;
    final selected = await selectMany(
      context,
      t('Enabled Currencies'),
      choices,
      enabledCurrencyCodes,
    );
    if (selected == null) return;
    await run(
      () => writePreference(app, 'enabledCurrencies', {
        for (final choice in choices)
          '${choice['id']}': selected.contains('${choice['id']}'),
      }),
    );
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Preferences'),
    busy: busy,
    children: [
      Section(
        title: t('General Settings'),
        children: [
          toggle('showAccountBalance', 'Show Account Balance'),
          link(
            'Account Category Order',
            '/settings/account_category_display_order',
          ),
          link('Chart Color Scheme', '/settings/chart_color_scheme'),
          toggle(
            'autoUpdateExchangeRatesData',
            'Auto-update Exchange Rates Data',
          ),
          ItemRow(
            t('Enabled Currencies'),
            value: enabledCurrencyCodes.join(', '),
            onTap: selectEnabledCurrencies,
          ),
        ],
      ),
      Section(
        title: t('Overview Page'),
        children: [
          link('Home Page Layout', '/settings/overview_layout'),
          toggle('showAmountInHomePage', 'Show Amount'),
          option(
            'timezoneUsedForStatisticsInHomePage',
            'Timezone Used for Statistics',
            settingOptions('TimezoneTypeForStatistics'),
          ),
          link(
            'Accounts Included in Overview Statistics',
            '/settings/filter/account?type=homePageOverview',
          ),
          link(
            'Transaction Categories Included in Overview Statistics',
            '/settings/filter/category?type=homePageOverview&allowCategoryTypes=1,2',
          ),
        ],
      ),
      Section(
        title: t('Transaction List Page'),
        children: [
          toggle(
            'showTotalAmountInTransactionListPage',
            'Show Monthly Total Amount',
          ),
          toggle('showTagInTransactionListPage', 'Show Transaction Tags'),
          option(
            'defaultKeywordMatchModeInTransactionListPage',
            'Default Keyword Search Matching Mode',
            settingOptions('KeywordMatchMode'),
          ),
        ],
      ),
      Section(
        title: t('Transaction Edit Page'),
        children: [
          option(
            'quickSaveButtonStyleInMobileTransactionListPage',
            'Quick Save Button Style',
            settingOptions('TransactionQuickSaveButtonStyle'),
          ),
          option(
            'quickAddButtonActionInMobileTransactionEditPage',
            'Quick Add Button Action',
            settingOptions('TransactionQuickAddButtonActionType'),
          ),
          option('autoSaveTransactionDraft', 'Automatically Save Draft', [
            {'id': 'disabled', 'name': 'Disabled'},
            {'id': 'enabled', 'name': 'Enabled'},
            {'id': 'confirmation', 'name': 'Always Show Confirmation'},
          ]),
          toggle('autoGetCurrentGeoLocation', 'Automatically Add Geolocation'),
          if (app.config['enableTransactionPictures'] == true) ...[
            toggle(
              'alwaysShowTransactionPicturesInMobileTransactionEditPage',
              'Always Show Transaction Pictures',
            ),
            option(
              'transactionPictureQuality',
              'Transaction Picture Upload Quality',
              settingOptions('ImageUploadQualityType'),
            ),
          ],
        ],
      ),
      if (app.config['transactionFromAITextRecognition'] == true)
        Section(
          title: t('AI Clipboard Text Recognition'),
          children: [
            toggle(
              'alwaysRequireConfirmationOfClipboardContentBeforeSubmission',
              'Always Require Confirmation of Clipboard Content Before Submission',
            ),
          ],
        ),
      if (app.config['transactionFromAIImageRecognition'] == true &&
          app.config['enableTransactionPictures'] == true)
        Section(
          title: t('AI Image Recognition'),
          children: [
            toggle(
              'autoUploadTransactionPictureForAIRecognition',
              'Auto Upload AI Recognition Image as Transaction Picture',
            ),
          ],
        ),
      Section(
        title: t('Account List Page'),
        children: [
          link(
            'Accounts Included in Total',
            '/settings/filter/account?type=accountListTotalAmount',
          ),
          toggle(
            'hideCategoriesWithoutAccounts',
            'Hide Categories Without Accounts',
          ),
          option(
            'defaultCreditCardAmountDisplayTypeInMobile',
            'Default Credit Card Amount',
            settingOptions('CreditCardAmountDisplayType'),
          ),
          option(
            'reconciliationStatementPageDefaultDateRangeTypeInMobile',
            'Default Date Range for Reconciliation Statement Page',
            settingOptions('DateRange')
                .where(
                  (e) =>
                      (number(e['id']) < 100 || e['id'] == 255) &&
                      (e['isLastReconciledTimeRange'] != true ||
                          app.user['useLastReconciledTime'] == true),
                )
                .toList(),
          ),
        ],
      ),
      Section(
        title: t('Exchange Rates Data Page'),
        children: [
          option(
            'currencySortByInExchangeRatesPage',
            'Sort by',
            settingOptions('CurrencySortingType'),
          ),
        ],
      ),
    ],
  );
}

class TextSizePage extends ConsumerStatefulWidget {
  const TextSizePage({super.key});
  @override
  ConsumerState<TextSizePage> createState() => _TextSizeState();
}

class _TextSizeState extends NativeState<TextSizePage> {
  late double value = number(app.settings['fontSize']).toDouble();
  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Text Size'),
    trailing: iconButton(
      CupertinoIcons.check_mark,
      t('Save'),
      () => run(() async {
        await app.setPreference('fontSize', value.round());
        if (context.mounted) context.pop();
      }),
    ),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: BookkeepingTextScaler(
              system: MediaQuery.textScalerOf(context) is BookkeepingTextScaler
                  ? (MediaQuery.textScalerOf(
                      context,
                    ) as BookkeepingTextScaler).system
                  : MediaQuery.textScalerOf(context),
              fontSizeType: value.round(),
            ),
          ),
          child: Section(
            title: t('Preview'),
            children: [
              ItemRow(t('Expense'), value: '123.45 CNY'),
              ItemRow(t('Income'), subtitle: t('Transaction Categories')),
              InputRow(
                t('Description'),
                value: 'Danggui Expense',
                readOnly: true,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(20),
        child: CupertinoSlider(
          value: value,
          min: 0,
          max: 6,
          divisions: 6,
          onChanged: (v) => setState(() => value = v),
        ),
      ),
      actionButton(t('Reset to Default'), () => setState(() => value = 1)),
    ],
  );
}

class ChartColorsPage extends ConsumerStatefulWidget {
  const ChartColorsPage({super.key});
  @override
  ConsumerState<ChartColorsPage> createState() => _ChartColorsState();
}

class _ChartColorsState extends SettingsState<ChartColorsPage> {
  List<String>? colors;
  List<Key> colorKeys = [];
  final scrollController = ScrollController();
  List<String> get defaults =>
      (settingsReference['chartColors'] as List? ?? []).cast<String>();
  List<String> get saved =>
      effectiveChartColors(string(app.settings['chartColors']), defaults);
  List<String> get current {
    if (colors == null) replace(saved);
    return colors!;
  }

  void replace(List<String> next) {
    colors = [...next];
    colorKeys = [for (final _ in next) UniqueKey()];
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  Future<void> more() async {
    final action = await choose(context, t('More'), {
      'add': t('Add'),
      'import': t('Import'),
      'export': t('Export'),
      'reset': t('Reset to Default'),
    });
    if (!mounted) return;
    if (action == 'add') {
      setState(() {
        current.add('000000');
        colorKeys.add(UniqueKey());
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scrollController.hasClients) {
          final end = scrollController.position.maxScrollExtent;
          if (app.settings['animate'] == false) {
            scrollController.jumpTo(end);
          } else {
            scrollController.animateTo(
              end,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        }
      });
    } else if (action == 'import') {
      final imported = await importChartColorSheet(context);
      if (imported != null && mounted) {
        setState(() => replace(imported));
        settingsNotice(context, t('Chart color scheme imported'));
      }
    } else if (action == 'export') {
      await exportChartColorSheet(context, current);
    } else if (action == 'reset') {
      setState(() => replace(defaults));
    }
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Chart Color Scheme'),
    busy: busy,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        iconButton(CupertinoIcons.ellipsis, t('More'), ready ? more : null),
        iconButton(
          CupertinoIcons.check_mark,
          t('Save'),
          ready && current.isNotEmpty && settingOrderModified(current, saved)
              ? () => run(() async {
                  await app.setPreference(
                    'chartColors',
                    encodeSettingOrder(current, defaults),
                  );
                  if (context.mounted) {
                    settingsNotice(context, t('Chart color scheme saved'));
                    context.pop();
                  }
                })
              : null,
        ),
      ],
    ),
    children: [
      if (ready)
        SettingsOrderList(
          controller: scrollController,
          onReorder: (from, to) => setState(() {
            current.insert(to, current.removeAt(from));
            colorKeys.insert(to, colorKeys.removeAt(from));
          }),
          children: [
            for (var i = 0; i < current.length; i++)
              ItemRow(
                '#${current[i]}',
                key: colorKeys[i],
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: itemColor(current[i]),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onTap: () => editChartColor(context, current[i], (color) {
                  if (mounted) setState(() => current[i] = color);
                }),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      label: t('Remove'),
                      button: true,
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(48, 48),
                        onPressed: () => setState(() {
                          current.removeAt(i);
                          colorKeys.removeAt(i);
                        }),
                        child: const Icon(
                          CupertinoIcons.minus_circle_fill,
                          color: CupertinoColors.destructiveRed,
                          size: 24,
                        ),
                      ),
                    ),
                    settingDragHandle(context, i),
                  ],
                ),
              ),
          ],
        ),
    ],
  );
}

class AccountOrderPage extends ConsumerStatefulWidget {
  const AccountOrderPage({super.key});
  @override
  ConsumerState<AccountOrderPage> createState() => _AccountOrderState();
}

class _AccountOrderState extends SettingsState<AccountOrderPage> {
  List<RecordData>? items;
  List<RecordData> get saved {
    final defaults = settingOptions('AccountCategory');
    final saved = string(app.settings['accountCategoryOrders']).split(',');
    return [
      ...saved
          .map((id) => defaults.where((e) => string(e['id']) == id).firstOrNull)
          .whereType<RecordData>(),
      ...defaults.where((e) => !saved.contains(string(e['id']))),
    ];
  }

  List<RecordData> get current => items ??= saved;
  List<String> ids(List<RecordData> values) =>
      values.map((value) => string(value['id'])).toList();

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Account Category Order'),
    busy: busy,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        iconButton(
          CupertinoIcons.ellipsis,
          t('More'),
          ready
              ? () async {
                  final action = await choose(context, t('More'), {
                    'reset': t('Reset to Default'),
                  });
                  if (action == 'reset' && mounted) {
                    setState(() => items = settingOptions('AccountCategory'));
                  }
                }
              : null,
        ),
        iconButton(
          CupertinoIcons.check_mark,
          t('Save'),
          ready && settingOrderModified(ids(current), ids(saved))
              ? () => run(() async {
                  await app.setPreference(
                    'accountCategoryOrders',
                    encodeSettingOrder(
                      ids(current),
                      ids(settingOptions('AccountCategory')),
                    ),
                  );
                  if (context.mounted) {
                    settingsNotice(context, t('Account category order saved'));
                    context.pop();
                  }
                })
              : null,
        ),
      ],
    ),
    children: [
      if (ready)
        SettingsOrderList(
          onReorder: (from, to) => setState(() {
            current.insert(to, current.removeAt(from));
          }),
          children: [
            for (var i = 0; i < current.length; i++)
              ItemRow(
                t(string(current[i]['name'])),
                key: ValueKey(current[i]['id']),
                trailing: settingDragHandle(context, i),
              ),
          ],
        ),
    ],
  );
}

class FilterSettingsPage extends ConsumerStatefulWidget {
  const FilterSettingsPage({
    super.key,
    required this.kind,
    required this.query,
  });
  final String kind;
  final Map<String, String> query;
  @override
  ConsumerState<FilterSettingsPage> createState() => _FilterSettingsState();
}

class _FilterSettingsState extends SettingsState<FilterSettingsPage> {
  FilterSelection? selection;
  TagFilterSelection? tagSelection;
  final collapsed = <String>{};
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  bool searchReady = false, showHidden = false;
  String search = '';
  String get type => widget.query['type'] ?? 'custom';
  bool get isTag => widget.kind == 'tag';
  bool get isAccount => widget.kind == 'account';
  bool get allowHidden =>
      !isAccount ||
      (type != 'accountListTotalAmount' &&
          widget.query['disableHiddenAccount'] != 'true');
  String get key => isAccount
      ? switch (type) {
          'homePageOverview' => 'overviewAccountFilterInHomePage',
          'accountListTotalAmount' => 'totalAmountExcludeAccountIds',
          'statisticsDefault' => 'statistics.defaultAccountFilter',
          _ => '${type}AccountFilter',
        }
      : !isTag
      ? switch (type) {
          'homePageOverview' => 'overviewTransactionCategoryFilterInHomePage',
          'statisticsDefault' => 'statistics.defaultTransactionCategoryFilter',
          _ => '${type}CategoryFilter',
        }
      : '${type}TagFilter';
  List<RecordData> get items => isAccount
      ? app.accounts
      : isTag
      ? app.tags
      : app.categories
            .where(
              (item) =>
                  widget.query['allowCategoryTypes'] == null ||
                  widget.query['allowCategoryTypes']!
                      .split(',')
                      .contains(string(item['type'])),
            )
            .toList();
  List<RecordData> get visible => visibleFilterItems(
    items,
    isAccount ? 'subAccounts' : 'subCategories',
    showHidden: showHidden && allowHidden,
    search: search,
  );
  bool get initialized =>
      ready &&
      searchReady &&
      (isTag ? tagSelection != null : selection != null);

  @override
  void initState() {
    super.initState();
    searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
    loadFilterSearchCharacters().then((_) {
      if (mounted) setState(() => searchReady = true);
    });
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void initialize() {
    if (!ready || !searchReady || selection != null || tagSelection != null) {
      return;
    }
    final value = type == 'custom' ? null : preference(app, key);
    if (isTag) {
      tagSelection = TagFilterSelection(
        items,
        string(widget.query['tagFilter'] ?? value),
      );
    } else {
      selection = FilterSelection(
        items: items,
        account: isAccount,
        allowHidden: allowHidden,
        initialExcluded: value is Map
            ? value.map((key, value) => MapEntry(string(key), value == true))
            : {},
        selectedIds: widget.query.containsKey('selectedIds')
            ? widget.query['selectedIds']!
                  .split(',')
                  .where((id) => id.isNotEmpty)
                  .toList()
            : null,
      );
    }
  }

  Future<void> save() => run(() async {
    final result = isTag ? tagSelection!.encoded : selection!.savedExcluded;
    if (type != 'custom') await writePreference(app, key, result);
    if (mounted) context.pop(isTag ? result : selection!.selectedIds);
  });

  Future<void> more() async {
    FocusScope.of(context).unfocus();
    final available = visible.isNotEmpty;
    final labels = isTag
        ? ['Set All to Included', 'Set All to Default', 'Set All to Excluded']
        : ['Select All', 'Select None', 'Invert Selection'];
    final hiddenLabel = isAccount
        ? (showHidden ? 'Hide Hidden Accounts' : 'Show Hidden Accounts')
        : isTag
        ? (showHidden
              ? 'Hide Hidden Transaction Tags'
              : 'Show Hidden Transaction Tags')
        : (showHidden
              ? 'Hide Hidden Transaction Categories'
              : 'Show Hidden Transaction Categories');
    final action = await showCupertinoModalPopup<int>(
      context: context,
      builder: (sheet) {
        Widget group(List<Widget> children) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
              sheet,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0)
                  Container(
                    height: 0.5,
                    color: CupertinoColors.separator.resolveFrom(sheet),
                  ),
                children[index],
              ],
            ],
          ),
        );
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                group([
                  for (var index = 0; index < labels.length; index++)
                    Semantics(
                      enabled: available,
                      child: IgnorePointer(
                        ignoring: !available,
                        child: CupertinoButton(
                          minimumSize: const Size(double.infinity, 48),
                          onPressed: available
                              ? () => Navigator.pop(sheet, index)
                              : null,
                          child: Text(
                            t(labels[index]),
                            style: TextStyle(
                              fontSize: 15,
                              color: available
                                  ? null
                                  : CupertinoColors.inactiveGray.resolveFrom(
                                      sheet,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ]),
                if (allowHidden)
                  group([
                    CupertinoButton(
                      minimumSize: const Size(double.infinity, 48),
                      onPressed: () => Navigator.pop(sheet, 3),
                      child: Text(
                        t(hiddenLabel),
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                  ]),
                group([
                  CupertinoButton(
                    minimumSize: const Size(double.infinity, 48),
                    onPressed: () => Navigator.pop(sheet),
                    child: Text(
                      t('Cancel'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
    if (action == null || !mounted) return;
    setState(() {
      if (action == 3) {
        showHidden = !showHidden;
      } else if (isTag) {
        tagSelection!.setVisible(visible, [1, 0, 2][action]);
      } else {
        selection!.selectVisible(visible, action);
      }
    });
  }

  Widget itemIcon(RecordData item) => Stack(
    clipBehavior: Clip.none,
    children: [
      if (isTag)
        const SizedBox(
          width: 32,
          height: 32,
          child: Icon(CupertinoIcons.number, size: 28, color: brand),
        )
      else
        recordIcon(item),
      if (item['hidden'] == true)
        PositionedDirectional(
          end: -2,
          bottom: -2,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              color: CupertinoColors.systemGrey,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              CupertinoIcons.eye_slash_fill,
              size: 11,
              color: CupertinoColors.white,
            ),
          ),
        ),
    ],
  );

  Widget checkboxRow(
    RecordData item, {
    bool parent = false,
    bool nested = false,
  }) {
    final value = selection!.checkboxValue(item, parent: parent);
    void change() =>
        setState(() => selection!.select(item, value != true, parent: parent));
    return Semantics(
      checked: value == true,
      mixed: value == null,
      label: string(item['name']),
      onTap: change,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: change,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: EdgeInsetsDirectional.fromSTEB(nested ? 32 : 16, 8, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value != false ? brand : null,
                    border: Border.all(
                      color: value != false
                          ? brand
                          : CupertinoColors.systemGrey3.resolveFrom(context),
                    ),
                  ),
                  child: value == false
                      ? null
                      : Icon(
                          value == null
                              ? CupertinoIcons.minus
                              : CupertinoIcons.check_mark,
                          size: 16,
                          color: CupertinoColors.white,
                        ),
                ),
                const SizedBox(width: 16),
                itemIcon(item),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    string(item['name']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<int?> pickTagValue(
    BuildContext anchor,
    Map<int, String> choices,
    int selected,
  ) => anchoredPopover<int>(
    anchor,
    (menu) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final choice in choices.entries)
          ItemRow(
            t(choice.value),
            trailing: choice.key == selected
                ? const Icon(CupertinoIcons.check_mark, color: brand, size: 18)
                : const SizedBox.shrink(),
            onTap: () => Navigator.pop(menu, choice.key),
          ),
      ],
    ),
  );

  Widget tagRow(RecordData item) => Builder(
    builder: (anchor) {
      final id = string(item['id']),
          state = tagSelection!.states[string(item['id'])] ?? 0;
      return ItemRow(
        string(item['name']),
        leading: itemIcon(item),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t(['Default', 'Included', 'Excluded'][state]),
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            const SizedBox(width: 8),
            const CupertinoListTileChevron(),
          ],
        ),
        onTap: () async {
          final result = await pickTagValue(anchor, {
            1: 'Included',
            0: 'Default',
            2: 'Excluded',
          }, state);
          if (result != null && mounted) {
            setState(() => tagSelection!.states[id] = result);
          }
        },
      );
    },
  );

  Widget tagMode(String group, int side) => Builder(
    builder: (anchor) {
      final current = tagSelection!.modes[group]![side];
      final options = {
        for (final option in settingOptions('TransactionTagFilterType').where(
          (option) =>
              side == 0 ? number(option['id']) < 2 : number(option['id']) >= 2,
        ))
          number(option['id']): string(option['name']),
      };
      return ItemRow(
        t(options[current]!),
        onTap: () async {
          final mode = await pickTagValue(anchor, options, current);
          if (mode != null && mounted) {
            setState(() => tagSelection!.modes[group]![side] = mode);
          }
        },
      );
    },
  );

  Widget group(String id, String title, List<Widget> children) {
    final open = !collapsed.contains(id);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Semantics(
            button: true,
            expanded: open,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() {
                if (open) {
                  collapsed.add(id);
                } else {
                  collapsed.remove(id);
                }
              }),
              child: Container(
                constraints: const BoxConstraints(minHeight: 31),
                color: CupertinoTheme.brightnessOf(context) == Brightness.dark
                    ? const Color(0xff232323)
                    : const Color(0xfff7f7f7),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ),
                    Icon(
                      open
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 14,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 16),
                  child: Container(
                    height: 0.5,
                    color: CupertinoColors.separator.resolveFrom(context),
                  ),
                ),
              children[index],
            ],
        ],
      ),
    );
  }

  @override
  Widget buildPage(BuildContext context) {
    initialize();
    final filtered = initialized ? visible : <RecordData>[];
    final accountGroups = settingOptions('AccountCategory');
    final accountOrder = string(preference(app, 'accountCategoryOrders'))
        .split(',');
    final orderedAccountGroups = [
      for (final id in accountOrder)
        ...accountGroups.where((group) => string(group['id']) == id),
      ...accountGroups.where(
        (group) => !accountOrder.contains(string(group['id'])),
      ),
    ];
    final title = isAccount
        ? (type == 'statisticsDefault'
              ? 'Default Account Filter'
              : 'Filter Accounts')
        : isTag
        ? 'Filter Transaction Tags'
        : (type == 'statisticsDefault'
              ? 'Default Transaction Category Filter'
              : 'Filter Transaction Categories');
    final available = initialized && items.isNotEmpty;
    return NativePage(
      title: t(title),
      busy: busy,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconButton(
            CupertinoIcons.ellipsis,
            t('More'),
            available ? more : null,
          ),
          iconButton(
            CupertinoIcons.check_mark,
            t('Apply'),
            available ? save : null,
          ),
        ],
      ),
      subnavbar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: CupertinoSearchTextField(
                controller: searchController,
                focusNode: searchFocus,
                enabled: initialized,
                placeholder: t(
                  isAccount
                      ? 'Find account'
                      : isTag
                      ? 'Find tag'
                      : 'Find category',
                ),
                onChanged: (value) => setState(() => search = value),
              ),
            ),
            if (searchFocus.hasFocus)
              CupertinoButton(
                padding: const EdgeInsetsDirectional.only(start: 12),
                onPressed: () {
                  searchController.clear();
                  setState(() => search = '');
                  searchFocus.unfocus();
                },
                child: Text(t('Cancel')),
              ),
          ],
        ),
      ),
      children: [
        if (!initialized)
          const Padding(
            padding: EdgeInsets.all(32),
            child: CupertinoActivityIndicator(),
          )
        else if (filtered.isEmpty)
          Section(
            children: [
              ItemRow(
                t(
                  isAccount
                      ? 'No available account'
                      : isTag
                      ? 'No available tag'
                      : 'No available category',
                ),
              ),
            ],
          )
        else if (isTag) ...[
          for (final tagGroup in <RecordData>[
            {'id': '0', 'name': t('Default Group')},
            ...app.tagGroups,
          ])
            if (filtered.any(
              (item) => string(item['groupId']) == string(tagGroup['id']),
            ))
              group(string(tagGroup['id']), string(tagGroup['name']), [
                for (var side = 0; side < 2; side++)
                  if (tagSelection!.count(string(tagGroup['id']), side + 1) > 1)
                    tagMode(string(tagGroup['id']), side),
                for (final item in filtered.where(
                  (item) => string(item['groupId']) == string(tagGroup['id']),
                ))
                  tagRow(item),
              ]),
        ] else ...[
          for (final itemGroup
              in isAccount
                  ? orderedAccountGroups
                  : <RecordData>[
                      {'id': 1, 'name': 'Income Categories'},
                      {'id': 2, 'name': 'Expense Categories'},
                      {'id': 3, 'name': 'Transfer Categories'},
                    ])
            if (filtered.any(
              (item) =>
                  string(item[isAccount ? 'category' : 'type']) ==
                  string(itemGroup['id']),
            ))
              group(string(itemGroup['id']), t(string(itemGroup['name'])), [
                for (final item in filtered.where(
                  (item) =>
                      string(item[isAccount ? 'category' : 'type']) ==
                      string(itemGroup['id']),
                )) ...[
                  checkboxRow(
                    item,
                    parent: !isAccount || number(item['type']) == 2,
                  ),
                  for (final child in records(item[selection!.children]))
                    checkboxRow(child, nested: true),
                ],
              ]),
        ],
      ],
    );
  }
}

class CloudSettingsPage extends ConsumerStatefulWidget {
  const CloudSettingsPage({super.key});
  @override
  ConsumerState<CloudSettingsPage> createState() => _CloudSettingsState();
}

class _CloudSettingsState extends SettingsState<CloudSettingsPage> {
  CloudSettingsSelection? selection;
  bool fetched = false;
  String? loadingError;
  bool get available => fetched && !busy && app.authenticated;
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        await loadSettingsReference();
        selection = CloudSettingsSelection(
          records(settingsReference['cloudGroups']),
        );
        if (app.authenticated) await load();
      }),
    );
  }

  Future<void> load() async {
    try {
      final data = await app.get('v1/users/settings/cloud/get.json');
      selection!.remoteKeys(data);
      // Automatic cloud application protects queued local preference changes.
      await app.applyCloudSettings(data);
      selection!.acceptRemote(data);
      fetched = true;
      loadingError = null;
    } catch (error) {
      loadingError = app.errorText(error);
      rethrow;
    }
  }

  Future<void> upload() async {
    if (!available || selection!.selected.isEmpty) return;
    final keys = Set<String>.of(selection!.selected);
    final wasEnabled = selection!.enabled;
    await run(() async {
      // Settle a prior automatic write before replacing the server key set.
      // Unsubmitted selection changes must not enable automatic writes yet.
      await app.configureCloudSyncKeys(selection!.saved);
      final rows = [
        for (final key in keys)
          {
            'settingKey': key,
            'settingValue': encodeCloudValue(preference(app, key)),
          },
      ];
      if (await app.post('v1/users/settings/cloud/update.json', {
            'fullUpdate': true,
            'settings': rows,
          }) !=
          true) {
        throw StateError(
          t('Unable to update user synchronized application settings'),
        );
      }
      await app.configureCloudSyncKeys(keys);
      selection!.acceptRemote(rows, preserveDraft: false);
      if (mounted) {
        settingsNotice(
          context,
          t(
            wasEnabled
                ? 'Synchronized settings have been updated'
                : 'Settings sync has been enabled',
          ),
        );
      }
    });
  }

  Future<void> download() async {
    if (!available || !selection!.enabled || selection!.selected.isEmpty) {
      return;
    }
    final keys = Set<String>.of(selection!.selected);
    await run(() async {
      final data = await app.get('v1/users/settings/cloud/get.json');
      final remoteKeys = selection!.remoteKeys(data);
      await app.configureCloudSyncKeys(remoteKeys);
      // Explicit download overwrites only selected values, leaving local-only
      // preferences and the user's checkbox draft intact.
      await app.applyCloudSettings(data, selected: keys);
      selection!.acceptRemote(data);
      if (mounted) settingsNotice(context, t('Success'));
    });
  }

  Future<void> disable() async {
    if (!available || !selection!.enabled) return;
    await run(() async {
      await app.configureCloudSyncKeys(selection!.saved);
      if (await app.post('v1/users/settings/cloud/disable.json', {}) != true) {
        throw StateError(
          t('Unable to disable user synchronized application settings'),
        );
      }
      await app.configureCloudSyncKeys([]);
      selection!.acceptRemote(false, preserveDraft: false);
      if (mounted) {
        settingsNotice(context, t('Settings sync has been disabled'));
      }
    });
  }

  Future<void> more() async {
    if (!available) return;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) {
        Widget group(List<Widget> children) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
              sheet,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
        Widget button(
          String label,
          String value, {
          bool enabled = true,
          bool cancel = false,
        }) => CupertinoButton(
          minimumSize: const Size(double.infinity, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          onPressed: enabled ? () => Navigator.pop(sheet, value) : null,
          child: Text(
            t(label),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: cancel ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  group([
                    button('Select All', 'all'),
                    button('Select None', 'none'),
                    button('Invert Selection', 'invert'),
                  ]),
                  group([
                    button(
                      'Upload Selected Settings',
                      'upload',
                      enabled: selection!.selected.isNotEmpty,
                    ),
                    button(
                      'Download Selected Settings',
                      'download',
                      enabled:
                          selection!.enabled && selection!.selected.isNotEmpty,
                    ),
                  ]),
                  group([button('Cancel', 'cancel', cancel: true)]),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == 'upload') {
      await upload();
    } else if (action == 'download') {
      await download();
    } else {
      setState(() {
        if (action == 'all') selection!.selectAll(true);
        if (action == 'none') selection!.selectAll(false);
        if (action == 'invert') selection!.invert();
      });
    }
  }

  Widget checkbox(
    String title,
    bool? value,
    VoidCallback change, {
    bool nested = false,
    RecordData? item,
  }) => Semantics(
    label: title,
    checked: value == true,
    mixed: value == null,
    enabled: available,
    onTap: available ? change : null,
    child: ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: available ? change : null,
        child: Opacity(
          opacity: available ? 1 : .55,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: EdgeInsetsDirectional.fromSTEB(
              nested ? 32 : 16,
              10,
              16,
              10,
            ),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value != false ? brand : null,
                    border: Border.all(
                      color: value != false
                          ? brand
                          : CupertinoColors.separator.resolveFrom(context),
                    ),
                  ),
                  child: value == false
                      ? null
                      : Icon(
                          value == null
                              ? CupertinoIcons.minus
                              : CupertinoIcons.check_mark,
                          size: 16,
                          color: CupertinoColors.white,
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17),
                  ),
                ),
                if (item != null) ...[
                  const SizedBox(width: 8),
                  if (item['mobile'] == true)
                    Icon(
                      CupertinoIcons.device_phone_portrait,
                      size: 19,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  if (item['desktop'] == true) ...[
                    const SizedBox(width: 4),
                    Icon(
                      CupertinoIcons.desktopcomputer,
                      size: 19,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget separator({bool nested = false}) => Padding(
    padding: EdgeInsetsDirectional.only(start: nested ? 70 : 54),
    child: Container(
      height: .5,
      color: CupertinoColors.separator.resolveFrom(context),
    ),
  );
  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Settings Sync'),
    busy: busy,
    trailing: iconButton(
      CupertinoIcons.ellipsis,
      t('More'),
      available ? more : null,
    ),
    onRefresh: !app.authenticated
        ? null
        : () async {
            await run(load);
          },
    children: [
      Section(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        children: [
          ItemRow(
            t('Status'),
            value: t(
              !fetched
                  ? 'Unknown'
                  : selection!.enabled
                  ? 'Enabled'
                  : 'Disabled',
            ),
          ),
        ],
      ),
      if (!app.authenticated)
        Section(
          children: [
            ItemRow(
              t('Please log in with your ezBookkeeping account'),
              onTap: () => context.go('/login'),
            ),
          ],
        ),
      if (loadingError != null)
        Section(
          children: [
            ItemRow(t('Error'), subtitle: loadingError),
            actionButton(t('Retry'), () => run(load)),
          ],
        ),
      if (selection != null)
        Section(
          children: [
            SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      t('Synchronized Settings'),
                      style: TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ),
                  for (final group in selection!.groups) ...[
                    checkbox(
                      [
                        t(string(group['categoryName'])),
                        if (string(group['categorySubName']).isNotEmpty)
                          t(string(group['categorySubName'])),
                      ].join(' / '),
                      selection!.groupValue(group),
                      () => setState(
                        () => selection!.selectGroup(
                          group,
                          selection!.groupValue(group) != true,
                        ),
                      ),
                    ),
                    separator(),
                    for (final item in records(group['items'])) ...[
                      checkbox(
                        t(string(item['settingName'])),
                        selection!.selected.contains(
                          string(item['settingKey']),
                        ),
                        () => setState(
                          () => selection!.selectItem(
                            item,
                            !selection!.selected.contains(
                              string(item['settingKey']),
                            ),
                          ),
                        ),
                        nested: true,
                        item: item,
                      ),
                      separator(nested: true),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      if (fetched)
        Section(
          children: [
            SizedBox(
              width: double.infinity,
              child: CupertinoButton(
                onPressed: available && selection!.selected.isNotEmpty
                    ? upload
                    : null,
                child: Text(
                  t(
                    selection!.enabled
                        ? 'Update Synchronized Settings'
                        : 'Enable Settings Sync',
                  ),
                ),
              ),
            ),
            if (selection!.enabled)
              SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  onPressed: available ? disable : null,
                  child: Text(t('Disable')),
                ),
              ),
          ],
        ),
    ],
  );
}
