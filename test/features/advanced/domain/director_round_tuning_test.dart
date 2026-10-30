import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/features/advanced/domain/entities/director_round_tuning.dart';
import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';

void main() {
  test('fromConfig 逐字段打包（含 ask_user 3 分钟新默认）', () {
    final t = DirectorRoundTuning.fromConfig(const AdvancedConfig());
    expect(t.defaultMaxSteps, 8);
    expect(t.maxDurationMinutes, 5);
    expect(t.tokenBudgetRatio, 0.6);
    expect(t.maxRequestRetries, 5); // P5 上调后默认
    expect(t.doomLoopThreshold, 8); // 默认阈值 3→8（递进提醒前置）
    expect(t.askUserTimeout, const Duration(minutes: 3));
    expect(t.approvalTimeout, const Duration(minutes: 5));
    expect(t.subagentMaxSteps, 6);
    expect(t.subagentMaxDuration, const Duration(minutes: 2));
    expect(t.globalTools, isEmpty);
  });

  test('fromConfig 读取自定义值', () {
    final t = DirectorRoundTuning.fromConfig(
      const AdvancedConfig(
        defaults: AdvancedDefaultsConfig(maxSteps: 12),
        budget: AdvancedBudgetConfig(
          maxDurationMinutes: 9,
          tokenBudgetRatio: 0.7,
          maxRequestRetries: 2,
        ),
        doomLoop: AdvancedDoomLoopConfig(threshold: 5),
        hitl: AdvancedHitlConfig(
          askUserTimeoutMinutes: 8,
          approvalTimeoutMinutes: 4,
        ),
        subagent: AdvancedSubagentConfig(maxSteps: 3, maxDurationMinutes: 6),
        tools: {'spawn': 'deny'},
      ),
    );
    expect(t.defaultMaxSteps, 12);
    expect(t.maxDurationMinutes, 9);
    expect(t.tokenBudgetRatio, 0.7);
    expect(t.maxRequestRetries, 2);
    expect(t.doomLoopThreshold, 5);
    expect(t.askUserTimeout, const Duration(minutes: 8));
    expect(t.approvalTimeout, const Duration(minutes: 4));
    expect(t.subagentMaxSteps, 3);
    expect(t.subagentMaxDuration, const Duration(minutes: 6));
    expect(t.globalTools, {'spawn': 'deny'});
  });

  test('fromConfig 携带全局节奏档（缺省 balanced，会话列覆盖的前置）', () {
    expect(
      DirectorRoundTuning.fromConfig(const AdvancedConfig()).globalPacing,
      NarrativePacing.balanced,
    );
    expect(
      DirectorRoundTuning.fromConfig(
        AdvancedConfig.fromJson(const {'narrative_pacing': 'conservative'}),
      ).globalPacing,
      NarrativePacing.conservative,
    );
  });

  test('B8「一直等待」档：ask_user_timeout_minutes=0 → askUserTimeout 为 null', () {
    final t = DirectorRoundTuning.fromConfig(
      const AdvancedConfig(
        hitl: AdvancedHitlConfig(askUserTimeoutMinutes: 0),
      ),
    );
    expect(t.askUserTimeout, isNull, reason: '0 = 永不超时（null）');
    // 审批超时保持 fail-closed：0 不开放，任何值仍物化为 Duration
    expect(
      DirectorRoundTuning.fromConfig(
        const AdvancedConfig(),
      ).approvalTimeout,
      const Duration(minutes: 5),
    );
  });
}
