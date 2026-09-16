import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_controller.dart';
import '../core/money.dart';

class QuickAddStartupPage extends ConsumerStatefulWidget {
  const QuickAddStartupPage({
    super.key,
    this.initialAmount = 0,
    this.onAmountChanged,
  });

  final int initialAmount;
  final ValueChanged<int>? onAmountChanged;

  @override
  ConsumerState<QuickAddStartupPage> createState() =>
      _QuickAddStartupPageState();
}

class _QuickAddStartupPageState extends ConsumerState<QuickAddStartupPage> {
  late String input = Money.format(widget.initialAmount);
  int? accumulator;
  String? operator;
  bool replace = true;

  void press(String key) {
    setState(() {
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
            accumulator = Money.calculate(
              '${Money.format(accumulator!)}$operator${Money.format(right)}',
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
          if (accumulator != null && operator != null && !replace) {
            input = Money.format(
              Money.calculate('${Money.format(accumulator!)}$operator$input'),
            );
          }
          accumulator = null;
          operator = null;
          replace = true;
        } else if (replace) {
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
        final amount = Money.parse(input);
        final onAmountChanged = widget.onAmountChanged;
        if (onAmountChanged == null) {
          ref.read(appControllerProvider).updatePendingQuickAddAmount(amount);
        } else {
          onAmountChanged(amount);
        }
      } on FormatException {
        // Retain the last valid value while the encrypted ledger opens.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final formatter = ref.read(appControllerProvider).formatter;
    final chinese = WidgetsBinding
        .instance
        .platformDispatcher
        .locale
        .languageCode
        .toLowerCase()
        .startsWith('zh');
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemBackground.resolveFrom(context),
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 60,
              child: Center(
                child: Text(
                  chinese ? '添加交易' : 'Add transaction',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: CupertinoColors.tertiarySystemFill.resolveFrom(
                    context,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    for (final label
                        in chinese
                            ? const ['支出', '收入', '转账']
                            : const ['Expense', 'Income', 'Transfer'])
                      Expanded(
                        child: Center(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontWeight: label == (chinese ? '支出' : 'Expense')
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    formatter.digits(
                      input.replaceAll('.', formatter.decimalSeparator),
                    ),
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 34,
                      color: Color(0xffd43f3f),
                    ),
                  ),
                ),
              ),
            ),
            for (final row in const [
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
                                  semanticLabel: chinese ? '完成' : 'Done',
                                )
                              : Text(
                                  key == '.'
                                      ? formatter.decimalSeparator
                                      : formatter.digits(key),
                                  style: const TextStyle(fontSize: 26),
                                ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
