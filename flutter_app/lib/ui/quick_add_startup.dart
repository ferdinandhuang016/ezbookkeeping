import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_controller.dart';
import 'common.dart' show embeddedAmountPad;

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
                alignment: Alignment.bottomCenter,
                child: embeddedAmountPad(
                  initialAmount,
                  onChanged: (amount) => updateAmount(ref, amount),
                  onDone: (amount) => updateAmount(ref, amount),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
