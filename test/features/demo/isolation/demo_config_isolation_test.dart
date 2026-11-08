import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/demo_seeder.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_overrides.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../shared/demo_pack_factory.dart';

/// 业务配置确定性隔离（契约 §5）：真实 `user_overrides` JSON 中的模型、
/// 嵌入、工具权限、预算等配置不得改变演示的固定回放流程；真实配置
/// 本身零修改。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 真实用户带强烈个性化配置（工具审批收紧、私有嵌入、自定义预算）
  Map<String, Object> realUserOverrides() => <String, Object>{
        'user_overrides': jsonEncode(<String, dynamic>{
          'advanced.tools.update_facts': 'deny',
          'advanced.tools.record_event_memory': 'ask',
          'advanced.embedding_preset_id': 'real-private-preset',
          'advanced.embedding_model_id': 'real-private-embed',
          'advanced.defaults.max_steps': 3,
          'advanced.context.effective_context_limit': 12345,
          'advanced.phase_models.generating_preset_id': 'real-private-preset',
          'advanced.phase_models.generating_model_id': 'real-private-model',
          'broadcast_chat.preset_id': 'real-private-preset',
        }),
      };

  late AppDatabase demoDb;
  late Preferences realPrefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(realUserOverrides());
    realPrefs = Preferences();
    demoDb = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await demoDb.close();
  });

  test('种子后解析配置为确定性默认（真实业务覆盖不穿透）', () async {
    final prefs = DemoPreferences(fallback: realPrefs);
    final secure = DemoSecureStorage();
    await seedDemoEnvironment(demoDb, secure, prefs, localeTag: 'zh-CN');

    final bridge = DemoBridge();
    final container = ProviderContainer(
      overrides: buildDemoOverrides(
        bridge: bridge,
        demoDb: demoDb,
        prefs: prefs,
        secure: secure,
        pack: buildMinimalPack(),
      ),
    );
    addTearDown(container.dispose);
    addTearDown(bridge.dispose);

    // ── 实际解析链（非独立键断言）──
    final settingsRepo = container.read(settingsRepositoryProvider);
    final config = await settingsRepo.getResolvedConfig();

    expect(
      config.advanced.embeddingPresetId,
      '',
      reason: '真实私有嵌入 preset 不得泄漏——演示嵌入由用户在向导步显式选择',
    );
    expect(config.advanced.embeddingModelId, '');
    expect(
      config.advanced.generatingPresetId,
      '',
      reason: '真实全局 GM 不得预填（重看用户场景）',
    );
    expect(
      config.advanced.defaults.maxSteps,
      isNot(3),
      reason: '真实步数预算不得改变演示回合',
    );
    expect(
      config.advanced.context.effectiveContextLimit,
      isNot(12345),
      reason: '真实窗口上限不得泄漏',
    );

    // ── 配置快照（Controller 消费口径）──
    final snapshot = await container
        .read(configurationResolverProvider)
        .snapshotAdvancedDefaults();
    expect(
      snapshot.toolPermissions?[ToolPermissions.allTools.first],
      isNull,
      reason: '真实 deny/ask 审批不得收紧演示工具权限（默认全放行）',
    );
    expect(snapshot.maxSteps, isNot(3));
  });

  test('演示环境内自写入的覆盖可读写自洽（向导嵌入步路径）', () async {
    final prefs = DemoPreferences(fallback: realPrefs);
    final secure = DemoSecureStorage();
    await seedDemoEnvironment(demoDb, secure, prefs, localeTag: 'zh-CN');

    final bridge = DemoBridge();
    final container = ProviderContainer(
      overrides: buildDemoOverrides(
        bridge: bridge,
        demoDb: demoDb,
        prefs: prefs,
        secure: secure,
        pack: buildMinimalPack(),
      ),
    );
    addTearDown(container.dispose);
    addTearDown(bridge.dispose);

    final settingsRepo = container.read(settingsRepositoryProvider);
    // 模拟向导嵌入步写入
    await settingsRepo.setUserOverride(
      'advanced.embedding_preset_id',
      'demo-seed-preset',
    );
    final config = await settingsRepo.getResolvedConfig();
    expect(
      config.advanced.embeddingPresetId,
      'demo-seed-preset',
      reason: '演示内写入必须真实生效（非只读遮蔽）',
    );
  });

  test('真实偏好文件零修改', () async {
    final prefs = DemoPreferences(fallback: realPrefs);
    final secure = DemoSecureStorage();
    await seedDemoEnvironment(demoDb, secure, prefs, localeTag: 'zh-CN');

    // 真实侧 user_overrides 原样
    expect(
      await realPrefs.getString('user_overrides'),
      realUserOverrides()['user_overrides'],
      reason: '演示不得修改真实业务配置',
    );
  });
}
