import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';

void main() {
  test('缺省 JSON 解析出全部默认值', () {
    final c = AdvancedConfig.fromJson(const {});
    expect(c.systemPrompt, '');
    expect(c.generatingPresetId, '');
    expect(c.generation.temperature, 0.8);
    expect(c.generation.maxTokens, 8192);
    expect(c.defaults.maxSteps, 8);
    expect(c.budget.maxDurationMinutes, 5);
    expect(c.budget.tokenBudgetRatio, 0.6);
    expect(c.budget.maxRequestRetries, 5); // P5 默认上调（2026-10-15 批 E）
    expect(c.doomLoop.threshold, 8);
    expect(c.hitl.askUserTimeoutMinutes, 3);
    expect(c.hitl.approvalTimeoutMinutes, 5);
    expect(c.subagent.maxSteps, 6);
    expect(c.subagent.maxDurationMinutes, 2);
    expect(c.tools, isEmpty);
    expect(c.contextBudget.compactionTriggerRatio, 0.5);
    // 上下文配置收敛：三段式遗产两键已从 advanced 段
    // default_config 移除；值类解析兜底仍回落类默认（下限动态/检索
    // 0.15），导演消费经 storyRuntime 组装定死（见
    // story_runtime_config_test 的 DirectorContextBudgetPin 组）
    expect(c.contextBudget.recentMinRatio, isNull);
    expect(c.contextBudget.retrievalRatio, 0.15);
    expect(c.contextBudget.recentMinTokenTarget, 32000);
  });

  test('tools 三态解析与非法值拒绝', () {
    final c = AdvancedConfig.fromJson(const {
      'tools': {'spawn': 'deny', 'update_facts': 'ask'},
    });
    expect(c.tools['spawn'], 'deny');
    expect(c.tools['update_facts'], 'ask');
    expect(
      () => AdvancedConfig.fromJson(const {
        'tools': {'spawn': 'sometimes'},
      }),
      throwsFormatException,
    );
  });

  test('narrative_pacing 缺省 balanced，三合法值解析，非法值拒绝', () {
    expect(AdvancedConfig.fromJson(const {}).narrativePacing, 'balanced');
    for (final v in const ['conservative', 'balanced', 'aggressive']) {
      expect(
        AdvancedConfig.fromJson({'narrative_pacing': v}).narrativePacing,
        v,
      );
    }
    expect(
      () => AdvancedConfig.fromJson(const {'narrative_pacing': 'fast'}),
      throwsFormatException,
    );
  });

  test('压缩参数段：JSON 单源解析 + fromConfig 传导 + 真实 maxTokens 优先', () {
    // default_config.json 的 advanced.engineering_compaction 段为生产
    // 默认唯一来源（本测试锁定解析与传导，不重复记默认值）
    final json = AdvancedConfig.fromJson(const {
      'engineering_compaction': {
        'output_reserve_tokens': 12000,
        'headroom_tokens': 4000,
        'retain_ratio': 0.25,
        'retain_min_tokens': 1000,
        'retain_max_tokens': 20000,
        'retain_max_window_ratio': 0.5,
        'chars_per_token': 5,
        'oversized_result_chars': 4000,
        'degrade_head_chars': 300,
      },
    });
    final tuning = EngineeringCompactionTuning.fromConfig(
      json.engineeringCompaction,
    );
    expect(tuning.outputReserveTokens, 12000);
    expect(tuning.headroomTokens, 4000);
    expect(tuning.retainRatio, 0.25);
    expect(tuning.charsPerToken, 5);
    expect(tuning.oversizedResultChars, 4000);
    expect(tuning.degradeHeadChars, 300);

    // 实际请求面优先：会话真实 maxTokens 覆盖默认输出预留
    final withReal = EngineeringCompactionTuning.fromConfig(
      json.engineeringCompaction,
      actualMaxTokens: 8192,
    );
    expect(withReal.outputReserveTokens, 8192);
    expect(withReal.headroomTokens, 4000, reason: '其余参数不变');

    // 无请求面（0）回落配置默认
    expect(
      EngineeringCompactionTuning.fromConfig(json.engineeringCompaction)
          .outputReserveTokens,
      12000,
    );

    // 缺段回落：JSON 缺 engineering_compaction 时不炸（安全回落）
    expect(
      AdvancedConfig.fromJson(const {})
          .engineeringCompaction
          .outputReserveTokens,
      isPositive,
    );
  });
}
