import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart';

void main() {
  test('IntermediateConfig.storyRuntime 聚合字段一致', () {
    const config = IntermediateConfig();
    final rt = config.storyRuntime;
    expect(rt.contextBudget, same(config.contextBudget));
    expect(rt.context, same(config.context));
    expect(rt.memory, same(config.memory));
    expect(rt.consolidation, same(config.consolidation));
    expect(rt.retrieval, same(config.retrieval));
    expect(rt.prompts, same(config.prompts));
    expect(rt.systemPrompt, config.systemPrompt);
    expect(rt.stream, same(config.stream));
    expect(rt.reviewEnabled, config.reviewEnabled);
    expect(rt.retry, same(config.retry));
    expect(rt.consolidationPrompt, config.prompts.consolidationPrompt);
  });

  test('AdvancedConfig.storyRuntime 聚合字段一致（同构组装）', () {
    const config = AdvancedConfig();
    final rt = config.storyRuntime;
    // 2026-09-13 上下文配置收敛：导演组装不再透传 contextBudget，
    // 而是定死三段式遗产参数（见 directorPinned 测试）
    expect(
      rt.contextBudget.compactionTriggerRatio,
      config.contextBudget.compactionTriggerRatio,
    );
    expect(rt.contextBudget.recentMinRatio, isNull);
    expect(rt.contextBudget.retrievalRatio, 0);
    expect(rt.context, same(config.context));
    expect(rt.memory, same(config.memory));
    expect(rt.consolidation, same(config.consolidation));
    expect(rt.retrieval, same(config.retrieval));
    expect(rt.prompts, same(config.prompts));
    expect(rt.systemPrompt, config.systemPrompt);
    //  审查移除 advanced.stream：导演组装侧固定默认值（不消费）
    expect(rt.stream, same(const StreamConfig()));
    expect(rt.reviewEnabled, config.reviewEnabled);
    // retry 为故事 RetryScheduler 专用：导演组装侧固定默认值（设计文档 §4）
    expect(rt.retry, same(const RetryConfig()));
    expect(rt.consolidationPrompt, config.prompts.consolidationPrompt);
  });

  group('DirectorContextBudgetPin（上下文配置收敛 §2.1-4）', () {
    test('定死检索预留 0、原文区下限动态，阈值与目标 token 透传', () {
      const budget = ContextBudget(
        compactionTriggerRatio: 0.6,
        recentMinRatio: 0.3,
        recentMinTokenTarget: 24000,
      );
      final pinned = budget.directorPinned;
      expect(pinned.compactionTriggerRatio, 0.6);
      expect(pinned.recentMinRatio, isNull);
      expect(pinned.retrievalRatio, 0);
      expect(pinned.recentMinTokenTarget, 24000);
    });

    test('故事侧 ContextBudget 不受影响（同一实例透传）', () {
      const config = IntermediateConfig();
      expect(
        config.storyRuntime.contextBudget,
        same(config.contextBudget),
      );
    });
  });
}
