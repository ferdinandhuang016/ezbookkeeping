/// Amounts are stored as integer hundredths, exactly as on the server.
abstract final class Money {
  static const maxAmount = 999999999999999;

  static int parse(String text) {
    final value = text.trim();
    if (!RegExp(r'^-?\d+(\.\d{0,2})?$').hasMatch(value)) {
      throw const FormatException(
        'Enter an amount with at most two decimal places',
      );
    }
    final negative = value.startsWith('-');
    final pieces = value.replaceFirst('-', '').split('.');
    final amount =
        BigInt.parse(pieces[0]) * BigInt.from(100) +
        BigInt.parse(pieces.length > 1 ? pieces[1].padRight(2, '0') : '0');
    if (amount > BigInt.from(maxAmount)) {
      throw const FormatException('Amount value exceeds limitation');
    }
    return amount.toInt() * (negative ? -1 : 1);
  }

  static String format(int amount) =>
      '${amount < 0 ? '-' : ''}${amount.abs() ~/ 100}.${(amount.abs() % 100).toString().padLeft(2, '0')}';

  /// Decimal rate multiplication with half-up rounding, no binary floating point.
  static int convert(int amount, String rate) {
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(rate)) {
      throw const FormatException('Invalid exchange rate');
    }
    final parts = rate.split('.');
    final scale = BigInt.from(10).pow(parts.length == 2 ? parts[1].length : 0);
    final numerator = BigInt.parse(parts.join()) * BigInt.from(amount.abs());
    final result =
        ((numerator * BigInt.two + scale) ~/ (scale * BigInt.two)).toInt() *
        (amount < 0 ? -1 : 1);
    if (result.abs() > maxAmount) {
      throw const FormatException('Amount value exceeds limitation');
    }
    return result;
  }

  static int calculate(String expression) {
    final parser = _MoneyExpression(expression);
    final value = parser.parse();
    final scaled = value.numerator.abs() * BigInt.from(100);
    final rounded =
        (scaled * BigInt.two + value.denominator) ~/
        (value.denominator * BigInt.two);
    if (rounded > BigInt.from(maxAmount)) {
      throw const FormatException('Amount value exceeds limitation');
    }
    return rounded.toInt() * (value.numerator.isNegative ? -1 : 1);
  }
}

class _Fraction {
  _Fraction(this.numerator, this.denominator);
  final BigInt numerator;
  final BigInt denominator;
  _Fraction add(_Fraction b) => _Fraction(
    numerator * b.denominator + b.numerator * denominator,
    denominator * b.denominator,
  );
  _Fraction negate() => _Fraction(-numerator, denominator);
  _Fraction multiply(_Fraction b) =>
      _Fraction(numerator * b.numerator, denominator * b.denominator);
  _Fraction divide(_Fraction b) {
    if (b.numerator == BigInt.zero) {
      throw const FormatException('Cannot divide by zero');
    }
    return _Fraction(
      numerator *
          b.denominator *
          (b.numerator.isNegative ? -BigInt.one : BigInt.one),
      denominator * b.numerator.abs(),
    );
  }
}

class _MoneyExpression {
  _MoneyExpression(String text)
    : text = text
          .replaceAll(RegExp(r'\s'), '')
          .replaceAll('×', '*')
          .replaceAll('÷', '/')
          .replaceAll('−', '-');
  final String text;
  int index = 0;
  bool take(String symbol) {
    if (index < text.length && text[index] == symbol) {
      index++;
      return true;
    }
    return false;
  }

  _Fraction parse() {
    if (text.length > 255) {
      throw const FormatException('Expression is too long');
    }
    final value = additive();
    if (index != text.length) throw const FormatException('Invalid expression');
    return value;
  }

  _Fraction additive() {
    var value = multiplicative();
    while (index < text.length) {
      if (take('+')) {
        value = value.add(multiplicative());
      } else if (take('-')) {
        value = value.add(multiplicative().negate());
      } else {
        break;
      }
    }
    return value;
  }

  _Fraction multiplicative() {
    var value = primary();
    while (index < text.length) {
      if (take('*')) {
        value = value.multiply(primary());
      } else if (take('/')) {
        value = value.divide(primary());
      } else {
        break;
      }
    }
    return value;
  }

  _Fraction primary() {
    if (take('-')) return primary().negate();
    if (take('+')) return primary();
    if (take('(')) {
      final result = additive();
      if (!take(')')) {
        throw const FormatException('Missing closing parenthesis');
      }
      return result;
    }
    final match = RegExp(r'^(\d+(?:\.\d*)?|\.\d+)')
        .firstMatch(text.substring(index));
    if (match == null) throw const FormatException('Invalid expression');
    final number = match[0]!;
    index += number.length;
    final parts = number.split('.');
    return _Fraction(
      BigInt.parse(parts.join()),
      BigInt.from(10).pow(parts.length == 2 ? parts[1].length : 0),
    );
  }
}
