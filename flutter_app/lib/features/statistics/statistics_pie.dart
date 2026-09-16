import 'package:fl_chart/fl_chart.dart';

import '../../ui/common.dart';
import '../../core/aggregate_amount.dart';

/// The mobile chart selects a category before opening its transaction list.
class StatisticsPie extends StatefulWidget {
  const StatisticsPie({
    super.key,
    required this.entries,
    required this.label,
    required this.displayValue,
    required this.displayPercent,
    required this.totalTitle,
    required this.totalValue,
    required this.colors,
    required this.onOpen,
    required this.showPercent,
    required this.hasData,
  });
  final List<MapEntry<String, BigInt>> entries;
  final String Function(String) label;
  final String Function(BigInt) displayValue;
  final String Function(BigInt) displayPercent;
  final String totalTitle, totalValue;
  final List<Color> colors;
  final ValueChanged<int> onOpen;
  final bool showPercent;
  final bool hasData;

  @override
  State<StatisticsPie> createState() => _StatisticsPieState();
}

class _StatisticsPieState extends State<StatisticsPie> {
  int selected = 0;

  @override
  void didUpdateWidget(StatisticsPie oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entries.length != widget.entries.length ||
        List.generate(widget.entries.length, (i) => i).any(
          (i) =>
              oldWidget.entries[i].key != widget.entries[i].key ||
              oldWidget.entries[i].value != widget.entries[i].value,
        )) {
      selected = 0;
    }
  }

  void select(int offset) {
    setState(() => selected = (selected + offset) % widget.entries.length);
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final totalPositive = entries.fold<BigInt>(
      BigInt.zero,
      (sum, item) =>
          sum + (item.value > BigInt.zero ? item.value : BigInt.zero),
    );
    final fractions = [
      for (final item in entries) chartFraction(item.value, totalPositive),
    ];
    final painted = [
      for (var i = 0; i < entries.length; i++)
        if (entries[i].value > BigInt.zero && fractions[i] > .0001) i,
    ];
    final selectedItem = entries.isEmpty ? null : entries[selected];
    final color = widget.colors[selected % widget.colors.length];
    final foreground = CupertinoColors.label.resolveFrom(context);
    final startAngle =
        90.0 -
        fractions.take(selected).fold<double>(0, (a, b) => a + b) * 360 -
        (fractions.isEmpty ? 0 : fractions[selected] * 180);
    Widget selectorArrow(int offset) => Semantics(
      label: tr(context, offset > 0 ? 'Previous' : 'Next'),
      button: true,
      enabled: entries.length > 1,
      child: CupertinoButton(
        padding: const EdgeInsets.all(8),
        onPressed: entries.length <= 1 ? null : () => select(offset),
        child: Icon(
          offset > 0 ? CupertinoIcons.arrow_left : CupertinoIcons.arrow_right,
          size: 24,
          color: foreground.withValues(alpha: entries.length <= 1 ? .55 : 1),
        ),
      ),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final radius = constraints.maxWidth / 2;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            CupertinoTheme.brightnessOf(context) ==
                                Brightness.dark
                            ? const Color(0xff181818)
                            : const Color(0xfff0f0f0),
                      ),
                    ),
                    if (painted.isNotEmpty)
                      PieChart(
                        PieChartData(
                          startDegreeOffset: startAngle,
                          centerSpaceRadius: radius * .4,
                          sectionsSpace: 0,
                          pieTouchData: PieTouchData(
                            touchCallback: (event, response) {
                              final index =
                                  response
                                      ?.touchedSection
                                      ?.touchedSectionIndex ??
                                  -1;
                              if (event is FlTapUpEvent &&
                                  index >= 0 &&
                                  index < painted.length) {
                                setState(() => selected = painted[index]);
                              }
                            },
                          ),
                          sections: [
                            for (final index in painted)
                              PieChartSectionData(
                                value: fractions[index],
                                color:
                                    widget.colors[index % widget.colors.length],
                                radius: radius * .6,
                                showTitle: false,
                              ),
                          ],
                        ),
                        duration: Duration.zero,
                      ),
                    IgnorePointer(
                      child: Container(
                        width: radius * .8,
                        height: radius * .8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xff7f2020),
                          border: Border.all(color: const Color(0xffdddddd)),
                        ),
                        padding: const EdgeInsets.all(7),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (!widget.hasData)
                              Text(
                                tr(context, 'No data'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: CupertinoColors.white,
                                  fontSize: 17,
                                ),
                              )
                            else ...[
                              Text(
                                widget.totalTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: CupertinoColors.white,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                widget.totalValue,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: CupertinoColors.white,
                                  fontSize: 17,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Row(
            children: [
              selectorArrow(1),
              Expanded(
                child: Column(
                  children: [
                    if (widget.showPercent)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 2,
                        ),
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          border: Border.all(color: color),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(
                          selectedItem == null
                              ? '---'
                              : widget.displayPercent(selectedItem.value),
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                    if (selectedItem == null)
                      Text(
                        tr(context, 'No transaction data'),
                        textAlign: TextAlign.center,
                      )
                    else
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(44, 32),
                        onPressed: () => widget.onOpen(selected),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          children: [
                            Text(
                              widget.label(selectedItem.key),
                              style: TextStyle(color: foreground, fontSize: 16),
                            ),
                            Text(
                              widget.displayValue(selectedItem.value),
                              style: TextStyle(color: color, fontSize: 16),
                            ),
                            Icon(
                              CupertinoIcons.chevron_right,
                              size: 16,
                              color: CupertinoColors.tertiaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              selectorArrow(-1),
            ],
          ),
        ),
      ],
    );
  }
}
