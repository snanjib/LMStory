import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';

/// chat 压缩触发线公式——圆环满刻度的唯一口径。
///
/// 公式与 [CompactionService.shouldCompact] 同源：
/// availableWindow = max(contextWindow - 32000, floor(contextWindow × 0.5))
/// triggerTokens = floor(availableWindow × threshold)
void main() {
  group('CompactionService.compactionTriggerTokens', () {
    test('contextWindow 未知/非正 → null（圆环无满刻度可画）', () {
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: null,
          threshold: 0.6,
        ),
        isNull,
      );
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: 0,
          threshold: 0.6,
        ),
        isNull,
      );
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: -128000,
          threshold: 0.6,
        ),
        isNull,
      );
    });

    test('大窗口：availableWindow = window - 32000', () {
      // max(128000 - 32000, 64000) = 96000；96000 × 0.6 = 57600
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: 128000,
          threshold: 0.6,
        ),
        57600,
      );
    });

    test('窗口 = 32000：减法项归零，走 0.5 下限项', () {
      // max(0, floor(16000)) = 16000；16000 × 0.6 = 9600
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: 32000,
          threshold: 0.6,
        ),
        9600,
      );
    });

    test('小窗口：减法项为负，0.5 下限托底', () {
      // max(-2000, floor(15000)) = 15000；15000 × 0.6 = 9000
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: 30000,
          threshold: 0.6,
        ),
        9000,
      );
    });

    test('availableWindow 为 0 的极端小窗口 → null（与 shouldCompact 同判）', () {
      // max(1 - 32000, floor(0.5) = 0) = 0 → 无可用窗口
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: 1,
          threshold: 0.6,
        ),
        isNull,
      );
    });

    test('阈值随会话/全局设置变化（0.4-0.9 档位）', () {
      // 96000 × 0.9 = 86400；96000 × 0.4 = 38400
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: 128000,
          threshold: 0.9,
        ),
        86400,
      );
      expect(
        CompactionService.compactionTriggerTokens(
          contextWindow: 128000,
          threshold: 0.4,
        ),
        38400,
      );
    });
  });
}
