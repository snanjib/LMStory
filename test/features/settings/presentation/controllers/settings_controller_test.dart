import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';

/// SettingsNotifier 单元测试。
///
/// 重点验证 clearError 不会丢失已配置的字段（回归测试）。
void main() {
  // SettingsNotifier._init 里 ModelRegistry.refresh 是 fire-and-forget：
  // 真实网络请求完成后的 writeModelCache 会调 path_provider channel，
  // 尾巴跨过测试边界时「test failed after it had already completed」
  // （时序 flaky，网络快慢决定是否踩界）。mock 掉 channel 指向系统
  // 临时目录，尾巴不再触碰真实 platform channel（2026-09-13 P2 批二定界）。
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => Directory.systemTemp.path,
  );

  late _StubPresetRepository presetRepo;
  late _StubTemplateRepository templateRepo;
  late _StubSettingsRepository settingsRepo;
  late SettingsNotifier notifier;

  setUp(() {
    presetRepo = _StubPresetRepository();
    templateRepo = _StubTemplateRepository();
    settingsRepo = _StubSettingsRepository();
    notifier = SettingsNotifier(
      presetRepo: presetRepo,
      templateRepo: templateRepo,
      settingsRepo: settingsRepo,
    );
  });

  tearDown(() => notifier.dispose());

  group('clearError 回归测试（C3 修复）', () {
    test('clearError 后所有 global* 字段保留', () async {
      // 等待 _init 完成
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 设置全局生成参数
      await notifier.setGlobalTemperature(1.5);
      await notifier.setGlobalTopP(0.8);
      await notifier.setGlobalMaxTokens(2048);
      await notifier.setGlobalStreamEnabled(false);

      // 验证设置成功
      expect(notifier.state.globalTemperature, 1.5);
      expect(notifier.state.globalTopP, 0.8);
      expect(notifier.state.globalMaxTokens, 2048);
      expect(notifier.state.globalStreamEnabled, false);

      // 模拟错误发生（通过 createPreset 传入空 name 触发）
      // 直接设置 error 字段
      notifier.state = notifier.state.copyWith(error: 'Test error');
      expect(notifier.state.error, 'Test error');

      // 清除 error
      notifier.clearError();

      // 验证 error 已清除
      expect(notifier.state.error, isNull);

      // 验证所有 global* 字段保留（bug 修复前会丢失）
      expect(
        notifier.state.globalTemperature,
        1.5,
        reason: 'globalTemperature 应保留',
      );
      expect(notifier.state.globalTopP, 0.8, reason: 'globalTopP 应保留');
      expect(
        notifier.state.globalMaxTokens,
        2048,
        reason: 'globalMaxTokens 应保留',
      );
      expect(
        notifier.state.globalStreamEnabled,
        false,
        reason: 'globalStreamEnabled 应保留',
      );
    });

    test('clearError 后 titleModel 字段保留', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 设置 titleModel（通过 setUserOverride 模拟）
      await settingsRepo.setUserOverride(
        'common.title_model.preset_id',
        'preset-123',
      );
      await settingsRepo.setUserOverride(
        'common.title_model.model_id',
        'model-456',
      );
      await notifier.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(notifier.state.titleModelPresetId, 'preset-123');
      expect(notifier.state.titleModelModelId, 'model-456');

      // 设置 error 后清除
      notifier
        ..state = notifier.state.copyWith(error: 'Test error')
        ..clearError();

      expect(notifier.state.error, isNull);
      expect(
        notifier.state.titleModelPresetId,
        'preset-123',
        reason: 'titleModelPresetId 应保留',
      );
      expect(
        notifier.state.titleModelModelId,
        'model-456',
        reason: 'titleModelModelId 应保留',
      );
    });

    test('clearError 后 defaultReasoningEffort 保留', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setDefaultReasoningEffort(ReasoningEffort.high);
      expect(notifier.state.defaultReasoningEffort, ReasoningEffort.high);

      notifier
        ..state = notifier.state.copyWith(error: 'Test error')
        ..clearError();

      expect(notifier.state.error, isNull);
      expect(
        notifier.state.defaultReasoningEffort,
        ReasoningEffort.high,
        reason: 'defaultReasoningEffort 应保留',
      );
    });

    test('clearError 后基础字段保留（presets/templates/fontSize 等）', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 验证基础字段已加载
      expect(notifier.state.presets, isNotEmpty);
      expect(notifier.state.fontSize, 15);

      notifier
        ..state = notifier.state.copyWith(error: 'Test error')
        ..clearError();

      expect(notifier.state.error, isNull);
      expect(notifier.state.presets, isNotEmpty, reason: 'presets 应保留');
      expect(notifier.state.fontSize, 15, reason: 'fontSize 应保留');
    });
  });

  group('模板可见性', () {
    test('toolUpdateWorld 全下架：仓库层过滤后 state 只含存活类型', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      //  #28：枚举值已删，存量 'toolUpdateWorld' 行在仓库映射层
      // 被 tryFromDbValue → null 跳过（template_test 验证解析口径），
      // controller 不再自滤——stub 直接模拟仓库过滤后的产出。
      expect(
        notifier.state.templates
            .any((template) => template.kind == TemplateKind.systemPrompt),
        isTrue,
      );
      expect(notifier.state.templates.length, templateRepo.templates.length);
    });
  });

  group('全局生成参数 setters', () {
    test('setGlobalTemperature 持久化并更新 state', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setGlobalTemperature(1.2);
      expect(notifier.state.globalTemperature, 1.2);
      expect(settingsRepo.overrides['broadcast_chat.temperature'], 1.2);
    });

    test('setGlobalTemperature 超范围时 clamp', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setGlobalTemperature(5);
      expect(notifier.state.globalTemperature, 2.0, reason: '应 clamp 到 2.0');

      await notifier.setGlobalTemperature(-1);
      expect(notifier.state.globalTemperature, 0.0, reason: '应 clamp 到 0.0');
    });

    test('setGlobalTopP 持久化并更新 state', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setGlobalTopP(0.5);
      expect(notifier.state.globalTopP, 0.5);
      expect(settingsRepo.overrides['broadcast_chat.top_p'], 0.5);
    });

    test('setGlobalMaxTokens 传 null 时移除 override', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setGlobalMaxTokens(4096);
      expect(notifier.state.globalMaxTokens, 4096);
      expect(settingsRepo.overrides['broadcast_chat.max_tokens'], 4096);

      await notifier.setGlobalMaxTokens(null);
      expect(notifier.state.globalMaxTokens, isNull);
      expect(
        settingsRepo.overrides.containsKey('broadcast_chat.max_tokens'),
        isFalse,
        reason: '传 null 应移除 override',
      );
    });

    test('setGlobalStreamEnabled 持久化并更新 state', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await notifier.setGlobalStreamEnabled(false);
      expect(notifier.state.globalStreamEnabled, false);
      expect(settingsRepo.overrides['broadcast_chat.stream_enabled'], false);
    });
  });

  group('deletePreset 级联清理（D8 审查修复）', () {
    test('删除供应商时清理三模式全部模型引用键，不误清无关键', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      settingsRepo.overrides
        ..['advanced.phase_models.generating_preset_id'] = 'test-preset'
        ..['advanced.phase_models.generating_model_id'] = 'gm'
        ..['advanced.embedding_preset_id'] = 'test-preset'
        ..['advanced.embedding_model_id'] = 'emb'
        ..['advanced.suggest_reply.preset_id'] = 'test-preset'
        ..['advanced.suggest_reply.model_id'] = 'sg-adv'
        ..['intermediate.suggest_reply.preset_id'] = 'test-preset'
        ..['intermediate.suggest_reply.model_id'] = 'sg-story'
        ..['intermediate.phase_models.generating_preset_id'] = 'test-preset'
        ..['intermediate.phase_models.generating_model_id'] = 'g-story'
        // 无关键应保留
        ..['advanced.system_prompt'] = '导演规则'
        ..['other-preset.key'] = 'test-preset';

      await notifier.deletePreset('test-preset');

      for (final key in const [
        'advanced.phase_models.generating_preset_id',
        'advanced.phase_models.generating_model_id',
        'advanced.embedding_preset_id',
        'advanced.embedding_model_id',
        'advanced.suggest_reply.preset_id',
        'advanced.suggest_reply.model_id',
        'intermediate.suggest_reply.preset_id',
        'intermediate.suggest_reply.model_id',
        'intermediate.phase_models.generating_preset_id',
        'intermediate.phase_models.generating_model_id',
      ]) {
        expect(
          settingsRepo.overrides.containsKey(key),
          isFalse,
          reason: '删除供应商后应清理 $key',
        );
      }
      expect(settingsRepo.overrides['advanced.system_prompt'], '导演规则');
      expect(settingsRepo.overrides['other-preset.key'], 'test-preset');
    });
  });

  group('内容宽度模式（通用设置-外观）', () {
    test('默认流式；set 持久化到 general.content_width_mode', () async {
      final notifier = SettingsNotifier(
        presetRepo: presetRepo,
        templateRepo: templateRepo,
        settingsRepo: settingsRepo,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.state.contentWidthMode, LmContentWidthMode.fluid);

      await notifier.setContentWidthMode(LmContentWidthMode.capped);
      expect(notifier.state.contentWidthMode, LmContentWidthMode.capped);
      expect(
        settingsRepo.overrides['general.content_width_mode'],
        'capped',
      );

      // 重启（重建 notifier）：从 override 读回 capped
      final fresh = SettingsNotifier(
        presetRepo: presetRepo,
        templateRepo: templateRepo,
        settingsRepo: settingsRepo,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fresh.state.contentWidthMode, LmContentWidthMode.capped);
      fresh.dispose();
      notifier.dispose();
    });

    test('坏值回落流式（容忍化与 fontSize 同口径）', () async {
      settingsRepo.overrides['general.content_width_mode'] = 'bogus';
      final fresh = SettingsNotifier(
        presetRepo: presetRepo,
        templateRepo: templateRepo,
        settingsRepo: settingsRepo,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fresh.state.contentWidthMode, LmContentWidthMode.fluid);
      fresh.dispose();
    });
  });

  group('配置初始化容忍化与 stale 清理', () {
    test('CF9-3：类型坏键不炸设置初始化——按未配置回退默认值', () async {
      // 手改 SP/异版本备份导入的坏形态：数值存成 String
      settingsRepo.overrides['broadcast_chat.temperature'] = '0.7';
      settingsRepo.overrides['broadcast_chat.stream_enabled'] = 'true';
      settingsRepo.overrides['general.font_size'] = '18';

      final fresh = SettingsNotifier(
        presetRepo: presetRepo,
        templateRepo: templateRepo,
        settingsRepo: settingsRepo,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(fresh.state.error, isNull, reason: '坏键不应令 _init 进 error 态');
      expect(fresh.state.isLoading, isFalse);
      // 坏键按未配置处理 → 默认值（而非抛 TypeError 后的全灭）
      expect(fresh.state.globalTemperature, 0.7);
      expect(fresh.state.globalStreamEnabled, true);
      expect(fresh.state.fontSize, 15);
      fresh.dispose();
    });

    test('CF9-5：stale 预设清理双键同删（不再留 model_id 孤儿）', () async {
      settingsRepo.overrides['broadcast_chat.preset_id'] = 'deleted-preset';
      settingsRepo.overrides['broadcast_chat.model_id'] = 'orphan-model';

      final fresh = SettingsNotifier(
        presetRepo: presetRepo,
        templateRepo: templateRepo,
        settingsRepo: settingsRepo,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        settingsRepo.removedKeys,
        containsAll([
          'broadcast_chat.preset_id',
          'broadcast_chat.model_id',
        ]),
        reason: 'CF9-5：stale 分支须与 deletePreset 级联同口径双键同删',
      );
      fresh.dispose();
    });
  });
}

/// 最小化 stub，返回空列表和空配置
class _StubPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [
        ApiPreset(
          presetId: 'test-preset',
          name: 'Test',
          baseUrl: 'https://test.com',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];

  @override
  Future<ApiPreset> getPreset(String presetId) async =>
      throw UnimplementedError();

  @override
  Future<ApiPreset> createPreset({
    required String name,
    String baseUrl = '',
    LlmProtocol protocol = LlmProtocol.openaiCompatible,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ApiPreset> createFromTemplate({
    required String templateId,
    required String name,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ApiPreset> updatePreset(
    String presetId,
    ApiPreset Function(ApiPreset current) updater,
  ) async =>
      throw UnimplementedError();

  @override
  Future<ApiPreset> resetPreset(String presetId) async =>
      throw UnimplementedError();

  @override
  Future<void> deletePreset(String presetId) async {}

  @override
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubTemplateRepository implements TemplateRepository {
  final List<Template> templates = [
    Template(
      templateId: 'visible-system-prompt',
      name: '系统提示词',
      kind: TemplateKind.systemPrompt,
      content: 'system',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  ];

  @override
  Future<List<Template>> getAllTemplates() async => templates;

  @override
  Future<void> ensureBuiltInTemplates() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  final Map<String, dynamic> overrides = {};

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => overrides;

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  final removedKeys = <String>[];

  @override
  Future<void> removeUserOverride(String key) async {
    removedKeys.add(key);
    overrides.remove(key);
  }

  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
      );

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  Future<void> saveApiKey(String presetId, String apiKey) async {}

  @override
  Future<void> deleteApiKey(String presetId) async {}

  @override
  Future<void> clearAllUserOverrides() async {
    overrides.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
