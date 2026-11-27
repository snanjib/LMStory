import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/story_runtime/domain/entities/context_usage_estimate.dart';

void main() {
  group('ContextUsageEstimate', () {
    test('unknown：无数据且不得用 0 冒充', () {
      const estimate = ContextUsageEstimate.unknown();
      expect(estimate.tokens, isNull);
      expect(estimate.hasData, isFalse);
      expect(estimate.isEstimated, isTrue);
      expect(estimate.updatedAt, isNull);
    });

    test('reported：实报锚点保留可信度与时间', () {
      final at = DateTime(2026, 11, 9, 12);
      final estimate = ContextUsageEstimate.reported(tokens: 12000, at: at);
      expect(estimate.tokens, 12000);
      expect(estimate.hasData, isTrue);
      expect(estimate.isEstimated, isFalse);
      expect(estimate.updatedAt, at);
    });

    test('estimated：无锚点时允许显式本地估算值', () {
      final estimate = ContextUsageEstimate.estimated(tokens: 8000);
      expect(estimate.tokens, 8000);
      expect(estimate.isEstimated, isTrue);
    });

    test('shift：材料增删按增量调整并降级为 estimated', () {
      final at = DateTime(2026, 11, 9, 12);
      final anchor = ContextUsageEstimate.reported(tokens: 10000);

      final next = anchor.shift(removedTokens: 6000, addedTokens: 500, at: at);
      expect(next.tokens, 4500);
      expect(next.isEstimated, isTrue);
      expect(next.updatedAt, at);
    });

    test('shift：调整后不得低于 0', () {
      final anchor = ContextUsageEstimate.reported(tokens: 1000);
      final next = anchor.shift(removedTokens: 5000, addedTokens: 0);
      expect(next.tokens, 0);
    });

    test('shift：无锚点时原样返回（仍为无数据）', () {
      const unknown = ContextUsageEstimate.unknown();
      final next = unknown.shift(removedTokens: 100, addedTokens: 10);
      expect(next.tokens, isNull);
      expect(next.hasData, isFalse);
    });

    test('afterCompaction：锚点 - 压缩前材料 + 压缩后材料', () {
      final at = DateTime(2026, 11, 9, 13);
      final anchor = ContextUsageEstimate.reported(tokens: 20000);

      final next = ContextUsageEstimate.afterCompaction(
        current: anchor,
        tokensBefore: 15000,
        tokensAfter: 2000,
        at: at,
      );
      expect(next.tokens, 7000);
      expect(next.isEstimated, isTrue);
      expect(next.updatedAt, at);
    });

    test('afterCompaction：旧摘要被替换时一并扣除', () {
      // 压缩前：规则 20 + 旧摘要 30 + 对话 100 = 150
      // 压缩服务返回：tokensBefore=100（仅对话区）、tokensAfter=20（新摘要）
      // 正确新材料 = 150 - 100 - 30 + 20 = 40；旧公式会残留 70。
      final anchor = ContextUsageEstimate.reported(tokens: 150);
      final next = ContextUsageEstimate.afterCompaction(
        current: anchor,
        tokensBefore: 100,
        tokensAfter: 20,
        replacedSummaryTokens: 30,
      );
      expect(next.tokens, 40);
      expect(next.isEstimated, isTrue);
    });

    test('afterCompaction：首次压缩无旧摘要时 replacedSummaryTokens 为 0', () {
      final anchor = ContextUsageEstimate.reported(tokens: 20000);
      final next = ContextUsageEstimate.afterCompaction(
        current: anchor,
        tokensBefore: 15000,
        tokensAfter: 2000,
      );
      expect(next.tokens, 7000);
    });

    test('nextRoundFromTurn：多步工具轮扣除临时工作面', () {
      // 首请求 1000（历史+用户指令），末请求 3000（含工具结果等工作面）。
      // 下一轮不会原样携带工作面，预计回到 1000，回复由持久化阶段追加。
      final next = ContextUsageEstimate.nextRoundFromTurn(
        lastInputTokens: 3000,
        firstInputTokens: 1000,
      );
      expect(next.tokens, 1000);
      expect(next.isEstimated, isTrue);
    });

    test('nextRoundFromTurn：单步轮不扣减，保留完整输入', () {
      final next = ContextUsageEstimate.nextRoundFromTurn(
        lastInputTokens: 1200,
        firstInputTokens: 1200,
      );
      expect(next.tokens, 1200);
      expect(next.isEstimated, isTrue);
    });

    test('nextRoundFromTurn：无完整输入 → unknown', () {
      expect(
        ContextUsageEstimate.nextRoundFromTurn(
          lastInputTokens: null,
          firstInputTokens: 1000,
        ).hasData,
        isFalse,
      );
      expect(
        ContextUsageEstimate.nextRoundFromTurn(
          lastInputTokens: 0,
          firstInputTokens: 0,
        ).hasData,
        isFalse,
      );
    });

    test('afterCompaction：无锚点 → unknown', () {
      final noAnchor = ContextUsageEstimate.afterCompaction(
        current: null,
        tokensBefore: 1000,
        tokensAfter: 200,
      );
      expect(noAnchor.hasData, isFalse);

      final emptyAnchor = ContextUsageEstimate.afterCompaction(
        current: const ContextUsageEstimate.unknown(),
        tokensBefore: 1000,
        tokensAfter: 200,
      );
      expect(emptyAnchor.hasData, isFalse);
    });
  });
}
