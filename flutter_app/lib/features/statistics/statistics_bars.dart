import '../../ui/common.dart';
import '../../core/aggregate_amount.dart';

/// Mobile TrendsBarChart.vue scales each period by its signed total. Only
/// positive series draw bars; stacked and separate bars use different divisors.
List<double> statisticsBarFractions(
  Iterable<Object> sourceValues,
  Object sourceMaximumTotal, {
  required bool stacked,
}) {
  final values = sourceValues.map(aggregateAmount).toList();
  final maximumTotal = aggregateAmount(sourceMaximumTotal);
  final total = values.fold(BigInt.zero, (a, b) => a + b);
  final positive = values
      .where((value) => value > BigInt.zero)
      .fold(BigInt.zero, (a, b) => a + b);
  final maximum = values.fold(BigInt.zero, (a, b) => b > a ? b : a);
  final divisor = stacked ? positive : maximum;
  if (maximumTotal <= BigInt.zero ||
      total <= BigInt.zero ||
      divisor <= BigInt.zero) {
    return List.filled(values.length, 0);
  }
  return values
      .map((value) => chartFraction(value * total, divisor * maximumTotal))
      .toList();
}

class StatisticsBars extends StatelessWidget {
  const StatisticsBars({
    super.key,
    required this.fractions,
    required this.colors,
    required this.stacked,
  });
  final List<double> fractions;
  final List<Color> colors;
  final bool stacked;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(56, 0, 16, 12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        Widget track(List<int> indices) => Container(
          height: 4,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: CupertinoColors.systemGrey5.resolveFrom(context),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Row(
            children: [
              for (final i in indices)
                Container(
                  width: constraints.maxWidth * fractions[i],
                  color: colors[i % colors.length],
                ),
            ],
          ),
        );
        if (stacked) return track(List.generate(fractions.length, (i) => i));
        return Column(
          children: [
            for (var i = 0; i < fractions.length; i++)
              if (fractions[i] > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: track([i]),
                ),
          ],
        );
      },
    ),
  );
}
