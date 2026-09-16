/// Monetary aggregates can exceed a transaction or signed 64-bit amount.
BigInt aggregateAmount(Object? value) =>
    value is BigInt ? value : BigInt.parse('${value ?? 0}');

/// Convert only a bounded ratio for painting, never the monetary operands.
double chartFraction(BigInt value, BigInt total) {
  if (value <= BigInt.zero || total <= BigInt.zero) return 0;
  if (value >= total) return 1;
  const scale = 1000000000000000;
  return ((value * BigInt.from(scale)) ~/ total).toDouble() / scale;
}

/// Exact half-away rounding and the original small-positive-percent marker.
/// The caller applies its locale's digits/decimal separator to this text.
String aggregatePercent(BigInt value, BigInt total, {int precision = 2}) {
  if (total == BigInt.zero) return '0';
  final negative = value.isNegative != total.isNegative;
  final scale = BigInt.from(10).pow(precision);
  final numerator = value.abs() * BigInt.from(100) * scale;
  final denominator = total.abs();
  if (!negative && numerator > BigInt.zero && numerator < denominator) {
    return precision == 0 ? '<1' : '<0.${'0' * (precision - 1)}1';
  }
  final rounded =
      (numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two);
  final raw = rounded.toString().padLeft(precision + 1, '0');
  final integer = precision == 0
      ? raw
      : raw.substring(0, raw.length - precision);
  final fraction = precision == 0
      ? ''
      : raw.substring(raw.length - precision).replaceFirst(RegExp(r'0+$'), '');
  return '${negative && rounded != BigInt.zero ? '-' : ''}$integer${fraction.isEmpty ? '' : '.$fraction'}';
}
