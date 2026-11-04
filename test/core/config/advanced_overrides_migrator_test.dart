import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_overrides_migrator.dart';
import 'package:lmstory/core/storage/preferences.dart';

class _FakePrefs implements Preferences {
  _FakePrefs(this.map);
  final Map<String, String> map;

  @override
  Future<String?> getString(String key) async => map[key];

  @override
  Future<bool> setString(String key, String value) async {
    map[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

void main() {
  test('复制导演消费的 intermediate overrides 到 advanced，原键保留', () async {
    final prefs = _FakePrefs({
      'user_overrides':
          '{"intermediate.system_prompt":"我的规则","intermediate.generation.temperature":0.9,'
              '"intermediate.phase_models.generating_preset_id":"p1","intermediate.stream.tool_calling_enabled":false,'
              '"intermediate.embedding_preset_id":"pe","broadcast_chat.temperature":0.5}',
      'advanced_overrides_migrated': '',
    });
    final copied = await AdvancedOverridesMigrator(prefs).runIfNeeded();
    expect(copied, isTrue);
    final overrides = prefs.map['user_overrides']!;
    expect(overrides.contains('"advanced.system_prompt":"我的规则"'), isTrue);
    expect(overrides.contains('"advanced.generation.temperature":0.9'), isTrue);
    expect(
      overrides.contains('"advanced.phase_models.generating_preset_id":"p1"'),
      isTrue,
    );
    expect(
      overrides.contains('"advanced.stream.tool_calling_enabled":false'),
      isTrue,
    );
    expect(overrides.contains('"advanced.embedding_preset_id":"pe"'), isTrue);
    expect(
      overrides.contains('"broadcast_chat.temperature":0.5'),
      isTrue,
    ); // 无关键不动
    // 原键保留（故事侧继续用）
    expect(overrides.contains('"intermediate.system_prompt":"我的规则"'), isTrue);
    expect(prefs.map['advanced_overrides_migrated'], '1');
  });

  test('前缀级映射保留子段名（memory/consolidation/retrieval/prompts）', () async {
    final prefs = _FakePrefs({
      'user_overrides':
          '{"intermediate.memory.factual.enabled":false,"intermediate.consolidation.trigger_threshold":0.9,'
              '"intermediate.retrieval.top_k":8,"intermediate.prompts.consolidation_prompt":"自定义"}',
    });
    expect(await AdvancedOverridesMigrator(prefs).runIfNeeded(), isTrue);
    final overrides = prefs.map['user_overrides']!;
    expect(
      overrides.contains('"advanced.memory.factual.enabled":false'),
      isTrue,
      reason: '子段名 memory 必须保留，不得映射为 advanced.factual.enabled',
    );
    expect(
      overrides.contains('"advanced.consolidation.trigger_threshold":0.9'),
      isTrue,
    );
    expect(overrides.contains('"advanced.retrieval.top_k":8'), isTrue);
    expect(
      overrides.contains('"advanced.prompts.consolidation_prompt":"自定义"'),
      isTrue,
    );
  });

  test('已存在的 advanced 键不被覆盖（用户已自行配置优先）', () async {
    final prefs = _FakePrefs({
      'user_overrides':
          '{"intermediate.system_prompt":"旧规则","advanced.system_prompt":"新规则"}',
    });
    await AdvancedOverridesMigrator(prefs).runIfNeeded();
    final overrides = prefs.map['user_overrides']!;
    expect(overrides.contains('"advanced.system_prompt":"新规则"'), isTrue);
    expect(overrides.contains('"advanced.system_prompt":"旧规则"'), isFalse);
  });

  test('已迁移过则跳过；无相关 override 也能幂等通过', () async {
    final prefs = _FakePrefs({'advanced_overrides_migrated': '1'});
    expect(await AdvancedOverridesMigrator(prefs).runIfNeeded(), isFalse);
    final empty = _FakePrefs({'user_overrides': '{}'});
    expect(await AdvancedOverridesMigrator(empty).runIfNeeded(), isTrue);
  });

  test('user_overrides 损坏时跳过复制仍落迁移标记', () async {
    final prefs = _FakePrefs({'user_overrides': 'not json{{{'});
    expect(await AdvancedOverridesMigrator(prefs).runIfNeeded(), isTrue);
    expect(prefs.map['user_overrides'], 'not json{{{');
    expect(prefs.map['advanced_overrides_migrated'], '1');
  });

  test('上下文配置收敛：三段式遗产键不再复制为 advanced.*', () async {
    final prefs = _FakePrefs({
      'user_overrides': '{"intermediate.contextBudget.recentMinRatio":0.2,'
          '"intermediate.contextBudget.retrievalRatio":0.25,'
          '"intermediate.contextBudget.compactionTriggerRatio":0.6}',
    });
    await AdvancedOverridesMigrator(prefs).runIfNeeded();
    final overrides = prefs.map['user_overrides']!;
    // 触发线仍复制（导演唯一上下文旋钮）；遗产两键不再生成 advanced.* 死键
    expect(
      overrides.contains('"advanced.contextBudget.compactionTriggerRatio":0.6'),
      isTrue,
    );
    expect(
      overrides.contains('advanced.contextBudget.recentMinRatio'),
      isFalse,
    );
    expect(
      overrides.contains('advanced.contextBudget.retrievalRatio'),
      isFalse,
    );
    // intermediate 原键保留（故事侧继续消费）
    expect(
      overrides.contains('"intermediate.contextBudget.recentMinRatio":0.2'),
      isTrue,
    );
  });

  test('cleanupStaleContextBudgetKeys：清除存量死键并落独立标记（幂等）', () async {
    final prefs = _FakePrefs({
      'user_overrides': '{"advanced.contextBudget.recentMinRatio":0.2,'
          '"advanced.contextBudget.retrievalRatio":0.25,'
          '"advanced.contextBudget.compactionTriggerRatio":0.6,'
          '"advanced.system_prompt":"保留"}',
    });
    await AdvancedOverridesMigrator(prefs).cleanupStaleContextBudgetKeys();

    final decoded =
        jsonDecode(prefs.map['user_overrides']!) as Map<String, dynamic>;
    expect(
      decoded.containsKey('advanced.contextBudget.recentMinRatio'),
      isFalse,
    );
    expect(
      decoded.containsKey('advanced.contextBudget.retrievalRatio'),
      isFalse,
    );
    expect(decoded['advanced.contextBudget.compactionTriggerRatio'], 0.6);
    expect(decoded['advanced.system_prompt'], '保留');
    expect(prefs.map['advanced_context_budget_stale_keys_cleaned'], '1');

    // 二次调用幂等：无残留也不重复写
    final before = prefs.map['user_overrides'];
    await AdvancedOverridesMigrator(prefs).cleanupStaleContextBudgetKeys();
    expect(prefs.map['user_overrides'], before);
  });
}
