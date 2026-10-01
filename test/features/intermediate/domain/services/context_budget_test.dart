import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';

void main() {
  group('ContextBudget computeRecentMinRatio', () {
    test('128K 模型：32000/96000 = 0.333', () {
      const budget = ContextBudget();
      final ratio = budget.computeRecentMinRatio(
        availableWindow: 96000,
      );
      expect(ratio, closeTo(0.333, 0.01));
    });

    test('1M 模型：32000/968000 = 0.033，触发下限保护 0.10', () {
      const budget = ContextBudget();
      final ratio = budget.computeRecentMinRatio(
        availableWindow: 968000,
      );
      expect(ratio, 0.10);
    });

    test('256K 模型：32000/224000 = 0.143', () {
      const budget = ContextBudget();
      final ratio = budget.computeRecentMinRatio(
        availableWindow: 224000,
      );
      expect(ratio, closeTo(0.143, 0.01));
    });

    test('用户自定义 recentMinRatio 时不动态计算', () {
      const budget = ContextBudget(recentMinRatio: 0.25);
      final ratio = budget.computeRecentMinRatio(
        availableWindow: 96000,
      );
      expect(ratio, 0.25);
    });
  });
}
