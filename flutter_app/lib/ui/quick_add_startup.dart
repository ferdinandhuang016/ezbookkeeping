import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_controller.dart';
import '../core/money.dart';
import 'common.dart' show ItemRow, NativePage, Section, embeddedAmountPad;

class QuickAddStartupPage extends ConsumerWidget {
  const QuickAddStartupPage({
    super.key,
    this.initialAmount = 0,
    this.onAmountChanged,
  });

  final int initialAmount;
  final ValueChanged<int>? onAmountChanged;

  void updateAmount(WidgetRef ref, int amount) {
    final callback = onAmountChanged;
    if (callback == null) {
      ref.read(appControllerProvider).updatePendingQuickAddAmount(amount);
    } else {
      callback(amount);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currencyCode = ref.read(appControllerProvider).formatter.defaultCurrency;
    final chinese = WidgetsBinding
        .instance
        .platformDispatcher
        .locale
        .languageCode
        .toLowerCase()
        .startsWith('zh');
    String label(String zh, String en) => chinese ? zh : en;
    return NativePage(
      title: label('添加交易', 'Add Transaction'),
      bottom: embeddedAmountPad(
        initialAmount,
        onChanged: (amount) => updateAmount(ref, amount),
        onDone: (amount) => updateAmount(ref, amount),
        currencyCode: currencyCode,
        onCurrencyTap: () {},
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: AbsorbPointer(
            child: CupertinoSlidingSegmentedControl<int>(
              groupValue: 3,
              children: {
                3: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(label('支出', 'Expense')),
                ),
                2: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(label('收入', 'Income')),
                ),
                4: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(label('转账', 'Transfer')),
                ),
              },
              onValueChanged: (_) {},
            ),
          ),
        ),
        Section(
          children: [
            ItemRow(
              label('金额', 'Amount'),
              value: Money.format(initialAmount),
              trailing: const CupertinoListTileChevron(),
            ),
            ItemRow(
              label('分类', 'Category'),
              trailing: const CupertinoListTileChevron(),
            ),
            ItemRow(
              label('账户', 'Account'),
              trailing: const CupertinoListTileChevron(),
            ),
            ItemRow(
              label('交易时间', 'Transaction Time'),
              trailing: const CupertinoListTileChevron(),
            ),
            ItemRow(
              label('标签', 'Tags'),
              trailing: const CupertinoListTileChevron(),
            ),
            ItemRow(label('备注描述', 'Description')),
          ],
        ),
      ],
    );
  }
}
