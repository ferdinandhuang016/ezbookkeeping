import 'dart:convert';

import 'package:flutter/services.dart';

import 'common.dart';

Future<RecordData?> chooseOriginalIcon(
  BuildContext context,
  String kind,
  String current, {
  int iconType = 0,
  String color = '000000',
}) => showCupertinoModalPopup<RecordData>(
  context: context,
  builder: (_) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .8,
    child: _IconSelection(
      kind: kind,
      current: current,
      iconType: iconType,
      color: color,
    ),
  ),
);

class _IconSelection extends ConsumerStatefulWidget {
  const _IconSelection({
    required this.kind,
    required this.current,
    required this.iconType,
    required this.color,
  });
  final String kind, current, color;
  final int iconType;
  @override
  ConsumerState<_IconSelection> createState() => _IconSelectionState();
}

class _IconSelectionState extends NativeState<_IconSelection> {
  List<RecordData> icons = [];
  List<RecordData> custom = [];
  late int tab = widget.iconType;
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        icons = records(
          jsonDecode(
            await rootBundle.loadString('assets/reference/icons.json'),
          )[widget.kind],
        );
        custom = records(app.settings['cachedCustomIcons']);
        if (app.config['enableUserCustomIcon'] == true) {
          try {
            custom = records(await app.get('v1/custom_icons/list.json'));
            await app.setPreference('cachedCustomIcons', custom);
          } catch (_) {
            /* Cached icons stay available offline. */
          }
        }
      }),
    );
  }

  @override
  Widget buildPage(BuildContext context) {
    final choices = tab == 0 ? icons : custom;
    return NativePage(
      title: t('Icon'),
      back: false,
      busy: busy,
      trailing: iconButton(
        CupertinoIcons.xmark,
        t('Close'),
        () => Navigator.pop(context),
      ),
      children: [
        if (app.config['enableUserCustomIcon'] == true)
          Padding(
            padding: const EdgeInsets.all(16),
            child: CupertinoSlidingSegmentedControl<int>(
              groupValue: tab,
              children: {
                0: Text(t('System Icons')),
                1: Text(t('Custom Icons')),
              },
              onValueChanged: (value) {
                if (value != null) setState(() => tab = value);
              },
            ),
          ),
        if (app.config['enableUserCustomIcon'] != true && tab == 1)
          actionButton(t('System Icons'), () => setState(() => tab = 0)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 58,
              mainAxisSpacing: 8,
              crossAxisSpacing: 4,
            ),
            itemCount: choices.length,
            itemBuilder: (context, index) {
              final item = choices[index];
              final id = string(item['id']);
              final selected = widget.iconType == tab && widget.current == id;
              return Semantics(
                label: t(
                  string(item['name']).isEmpty
                      ? 'Custom Icon'
                      : string(item['name']),
                ),
                selected: selected,
                button: true,
                child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () =>
                      Navigator.pop(context, {'icon': id, 'iconType': tab}),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected ? brand : CupertinoColors.transparent,
                        width: 2,
                      ),
                    ),
                    child: recordIcon({
                      'icon': id,
                      'iconType': tab,
                      'color': widget.color,
                      if (widget.kind == 'account') 'currency': '',
                    }),
                  ),
                ),
              );
            },
          ),
        ),
        if (!busy && choices.isEmpty)
          emptyState(t('No available custom icons')),
      ],
    );
  }
}

Future<String?> chooseOriginalColor(
  BuildContext context,
  String current,
  List<String> colors,
) => showCupertinoModalPopup<String>(
  context: context,
  builder: (_) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .65,
    child: _ColorSelection(current: current, colors: colors),
  ),
);

class _ColorSelection extends ConsumerStatefulWidget {
  const _ColorSelection({required this.current, required this.colors});
  final String current;
  final List<String> colors;
  @override
  ConsumerState<_ColorSelection> createState() => _ColorSelectionState();
}

class _ColorSelectionState extends NativeState<_ColorSelection> {
  late String custom = widget.current;
  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Color'),
    back: false,
    trailing: iconButton(
      CupertinoIcons.xmark,
      t('Close'),
      () => Navigator.pop(context),
    ),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 6,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [
            for (final color in widget.colors)
              Semantics(
                label: '#${color.toUpperCase()}',
                button: true,
                selected: color == widget.current,
                child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.pop(context, color),
                  child: Container(
                    decoration: BoxDecoration(
                      color: color == '000000'
                          ? CupertinoColors.label.resolveFrom(context)
                          : itemColor(color),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: color == widget.current
                          ? Icon(
                              CupertinoIcons.check_mark,
                              color: itemColor(color).computeLuminance() > .5
                                  ? CupertinoColors.black
                                  : CupertinoColors.white,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      Section(
        children: [
          InputRow(
            t('Custom Color'),
            value: custom,
            onChanged: (value) => custom = value.replaceFirst('#', ''),
          ),
          ItemRow(
            t('Apply'),
            onTap: () async {
              if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(custom)) {
                await inform(context, t('Invalid color'));
                return;
              }
              if (mounted) Navigator.pop(context, custom.toLowerCase());
            },
          ),
        ],
      ),
    ],
  );
}
