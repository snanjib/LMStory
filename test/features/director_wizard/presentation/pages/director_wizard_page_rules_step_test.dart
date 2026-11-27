import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/director_wizard/domain/entities/director_wizard_outcome.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';
import '../../../../test_helpers/wizard_page_actions.dart';

/// 项目规则步 UI：路径分叉、问卷拼装预览确认、生成成功/失败回退、
/// 自行编辑、存模板命名弹框（预填可改）、开关关闭不建模板。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  const identity = '你是一位互动故事的叙述者，负责构建并驱动一个开放的世界。你绝不代用户说话、行动或做决定。';

  ApiPreset keyedPreset() => ApiPreset(
        presetId: 'preset-1',
        name: '测试供应商',
        baseUrl: 'https://example.com',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        cachedModels: const [ModelInfo(modelId: 'model-1')],
      );

  Template tpl({String id = 'tpl-world', String content = '异世界模板内容XYZ'}) =>
      Template(
        templateId: id,
        name: '异世界穿越叙述者',
        kind: TemplateKind.systemPrompt,
        content: content,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  Future<_GenLlmService> pumpToRulesStep(
    WidgetTester tester, {
    required FakeWizardSettingsNotifier fake,
    bool llmFails = false,
    Completer<void>? llmGate,
  }) async {
    final llm = _GenLlmService(llmFails: llmFails, gate: llmGate);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) => fake),
          settingsRepositoryProvider.overrideWithValue(_NoopSettingsRepo()),
          advancedConfigProvider
              .overrideWith((ref) async => const AdvancedConfig()),
          configurationResolverProvider
              .overrideWithValue(const _StubResolver()),
          llmServiceProvider.overrideWithValue(llm),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
            home: const DirectorWizardPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 模型步选模型 → 嵌入步直过 → 规则步
    await pickWizardGmViaSheet(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await skipWizardEmbedding(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    return llm;
  }

  testWidgets('路径分叉渲染：模板卡 + 问卷卡', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToRulesStep(tester, fake: fake);

    expect(find.text('用现成模板'), findsOneWidget);
    expect(find.text('捏一个自己的世界'), findsOneWidget);
  });

  testWidgets('路 A：选模板即预览，就用这个 → 产物为模板内容', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
      templates: [tpl()],
    );
    await pumpToRulesStep(tester, fake: fake);

    await tester.tap(find.text('用现成模板'));
    await tester.pumpAndSettle();
    expect(find.text('异世界穿越叙述者'), findsOneWidget);

    await tester.tap(find.text('异世界穿越叙述者'));
    await tester.pumpAndSettle();
    expect(find.textContaining('异世界模板内容XYZ'), findsOneWidget, reason: '预览模板内容');

    await tester.ensureVisible(find.text('就用这个'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('就用这个'));
    await tester.pumpAndSettle();

    expect(
      fake.calls.where((c) => c.startsWith('createTemplate')),
      isEmpty,
      reason: '路 A 不重复存模板',
    );
  });

  testWidgets('English template selection displays the localized rules',
      (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
      templates: [
        tpl().copyWith(
          nameEn: 'Isekai narrator system prompt',
          contentEn: 'Write this scene in English.',
        ),
      ],
    );
    await pumpToRulesStep(tester, fake: fake);
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.enUs));
    addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.zhCn));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use a ready template'));
    await tester.pumpAndSettle();
    final english = find.text('Isekai narrator system prompt');
    expect(english, findsOneWidget);
    await tester.tap(english);
    await tester.pumpAndSettle();
    expect(find.textContaining('Write this scene in English.'), findsOneWidget);
  });

  testWidgets('路 B 拼装：答题→预览含身份句与所选块→存模板弹框预填题材', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToRulesStep(tester, fake: fake);

    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    expect(find.text('想在一个什么样的世界里玩？'), findsOneWidget);

    await answerWizardQuiz(
      tester,
      question: '想在一个什么样的世界里玩？',
      option: '奇幻修仙',
    );
    await tester.ensureVisible(find.text('立即拼好'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即拼好'));
    await tester.pumpAndSettle();

    expect(find.textContaining(identity), findsOneWidget);
    expect(find.textContaining('这是一个东方修仙世界'), findsOneWidget);
    expect(find.text('改成按选择生成'), findsNothing, reason: '拼装预览不显示生成专属键');

    // 就用这个 → 命名弹框（预填 自定义世界·奇幻修仙，可改）
    await tester.ensureVisible(find.text('就用这个'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('就用这个'));
    await tester.pumpAndSettle();
    expect(find.text('存为模板'), findsOneWidget);
    final nameField = find.byType(TextField);
    expect(
      tester.widget<TextField>(nameField).controller?.text,
      '自定义世界·奇幻修仙',
    );
    await tester.enterText(nameField, '我的修仙世界');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('createTemplate:我的修仙世界'));
  });

  testWidgets('路 B 生成成功：确认页先行，开始写才调用，可重新生成', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    final llm = await pumpToRulesStep(tester, fake: fake);

    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    await answerWizardQuiz(
      tester,
      question: '想在一个什么样的世界里玩？',
      option: '奇幻修仙',
    );

    await tester.ensureVisible(find.text('让模型替你写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('让模型替你写'));
    await tester.pumpAndSettle();

    // 确认页：成本预告可见；点「开始写」前零 LLM 调用
    expect(find.text('开始写'), findsOneWidget);
    expect(find.textContaining('花一点额度'), findsOneWidget);
    expect(llm.callCount, 0, reason: '确认页前不发起调用');
    await tester.tap(find.text('开始写'));
    await tester.pumpAndSettle();

    expect(find.textContaining('模型生成的世界设定ABC'), findsOneWidget);
    expect(find.text('重新生成'), findsOneWidget);
    expect(find.text('改成按选择生成'), findsOneWidget);

    // 重新生成也走确认页（任何模型调用前都有成本确认）
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();
    expect(find.text('开始写'), findsOneWidget);
    expect(llm.callCount, 1, reason: '重试在确认页停住，未发起第二次调用');
  });

  testWidgets('路 B 生成失败：回退拼装版本并带兜底提示', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToRulesStep(tester, fake: fake, llmFails: true);

    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    await answerWizardQuiz(
      tester,
      question: '想在一个什么样的世界里玩？',
      option: '奇幻修仙',
    );

    await tester.ensureVisible(find.text('让模型替你写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('让模型替你写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始写'));
    await tester.pumpAndSettle();

    expect(find.textContaining('模型这次没写出来'), findsOneWidget);
    expect(find.textContaining(identity), findsOneWidget, reason: '兜底为同选项拼装结果');
  });

  for (final person in ['留空', '第一人称', '第二人称', '第三人称']) {
    testWidgets('模型请求共用抽象选项块并准确传入人称：$person', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fake = FakeWizardSettingsNotifier(
        initialPresets: [keyedPreset()],
        keyedPresetIds: const {'preset-1'},
      );
      final llm = await pumpToRulesStep(tester, fake: fake);
      await tester.tap(find.text('捏一个自己的世界'));
      await tester.pumpAndSettle();
      await answerWizardQuiz(
        tester,
        question: '想在一个什么样的世界里玩？',
        option: '历史架空',
        dismissSheet: false,
      );
      await tester.enterText(find.byType(TextField), '只围绕普通人的日常生活');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await answerWizardQuiz(
        tester,
        question: '喜欢什么样的讲述文风？',
        option: '轻松幽默',
      );
      await answerWizardQuiz(
        tester,
        question: '故事用什么视角讲？',
        option: person,
      );
      await tester.ensureVisible(find.text('让模型替你写'));
      await tester.tap(find.text('让模型替你写'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始写'));
      await tester.pumpAndSettle();

      final request = llm.requests.single;
      final input = request.messages.last['content']! as String;
      final rules = t.directorWizard.rules;
      expect(input, contains(rules.blocks.genre.altHistory));
      expect(input, contains(rules.blocks.style.humorous));
      expect(input, contains('只围绕普通人的日常生活'));
      expect(input, isNot(contains('庙堂')));
      expect(input, isNot(contains('江湖')));
      expect(
        input,
        contains(person == '留空' ? rules.genPersonNone : '人称要求：$person'),
      );
      if (person == '留空') {
        expect(input, isNot(matches('第[一二三]人称')));
        expect(input, isNot(contains('自由发挥')));
      }
    });
  }

  testWidgets('开关关闭：就用这个 不弹命名框不建模板', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToRulesStep(tester, fake: fake);

    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('立即拼好'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即拼好'));
    await tester.pumpAndSettle();

    // 默认开 → 主动关闭
    await tester.ensureVisible(find.text('保存到我的模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到我的模板'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('就用这个'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('就用这个'));
    await tester.pumpAndSettle();

    expect(find.text('存为模板'), findsNothing, reason: '关闭后不弹命名框');
    expect(fake.calls.where((c) => c.startsWith('createTemplate')), isEmpty);
  });

  testWidgets('自行编辑：改稿后确认成为产物', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToRulesStep(tester, fake: fake);

    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('立即拼好'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即拼好'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('我自己再改改'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我自己再改改'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '我改过的世界设定');
    await tester.ensureVisible(find.text('确认修改'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认修改'));
    await tester.pumpAndSettle();

    expect(find.textContaining('我改过的世界设定'), findsOneWidget);
  });

  testWidgets('步进往返：预览产物不丢，完成携带规则', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    final box = _ResultBox();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) => fake),
          settingsRepositoryProvider.overrideWithValue(_NoopSettingsRepo()),
          advancedConfigProvider.overrideWith(
            (ref) async => const AdvancedConfig(),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      final outcome = await Navigator.of(context)
                          .push<DirectorWizardOutcome>(
                        MaterialPageRoute<DirectorWizardOutcome>(
                          builder: (_) => const DirectorWizardPage(),
                        ),
                      );
                      box
                        ..value = outcome
                        ..popped = true;
                    },
                    child: const Text('open-wizard'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-wizard'));
    await tester.pumpAndSettle();
    await pickWizardGmViaSheet(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await skipWizardEmbedding(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('立即拼好'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即拼好'));
    await tester.pumpAndSettle();

    // 往返：规则步 → 嵌入步 → 规则步（预览区的「上一步」是拒绝回退键，
    // 步进用底栏的最后一个）
    await tester.tap(find.text('上一步').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.textContaining(identity), findsOneWidget, reason: '预览不丢');

    // 关闭存模板开关后确认（避免弹框干扰完成断言）
    await tester.ensureVisible(find.text('保存到我的模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到我的模板'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('就用这个'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('就用这个'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(box.popped, isTrue);
    expect(box.value!.systemPromptOverride, contains(identity));
    expect(box.value!.phaseModels.generatingModelId, 'model-1');
  });

  testWidgets('直接完成（不碰规则步）：产物规则为 null 跟随全局', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    final box = _ResultBox();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) => fake),
          settingsRepositoryProvider.overrideWithValue(_NoopSettingsRepo()),
          advancedConfigProvider.overrideWith(
            (ref) async => const AdvancedConfig(),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      final outcome = await Navigator.of(context)
                          .push<DirectorWizardOutcome>(
                        MaterialPageRoute<DirectorWizardOutcome>(
                          builder: (_) => const DirectorWizardPage(),
                        ),
                      );
                      box
                        ..value = outcome
                        ..popped = true;
                    },
                    child: const Text('open-wizard'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-wizard'));
    await tester.pumpAndSettle();
    await pickWizardGmViaSheet(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await skipWizardEmbedding(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(
      box.value!.systemPromptOverride,
      isNull,
      reason: '跳过规则步 = null 跟随全局兜底（传空串会阻断全局回退）',
    );
  });

  testWidgets('返回导航：答题页可回分叉页，答案保留', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToRulesStep(tester, fake: fake);

    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    await answerWizardQuiz(
      tester,
      question: '想在一个什么样的世界里玩？',
      option: '奇幻修仙',
    );

    await tester.ensureVisible(find.text('返回上一级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回上一级'));
    await tester.pumpAndSettle();

    expect(find.text('用现成模板'), findsOneWidget, reason: '回到分叉页');
    expect(find.text('捏一个自己的世界'), findsOneWidget);

    // 重进问卷：答案保留（摘要卡回显答案与拼入原文）
    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    expect(
      find.text('奇幻修仙'),
      findsOneWidget,
      reason: '答案保留（摘要卡答案行）',
    );
    expect(
      find.textContaining('这是一个东方修仙世界'),
      findsOneWidget,
      reason: '拼入原文随摘要卡可见',
    );
  });

  testWidgets('生成中停止：成本确认弹窗 → 回确认页，在途结果作废', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    final gate = Completer<void>();
    final llm = await pumpToRulesStep(tester, fake: fake, llmGate: gate);

    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    await answerWizardQuiz(
      tester,
      question: '想在一个什么样的世界里玩？',
      option: '奇幻修仙',
    );
    await tester.ensureVisible(find.text('让模型替你写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('让模型替你写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始写'));
    await tester.pump();

    // 生成中隔离态：等待文案可见，选项不渲染
    expect(find.textContaining('正在替你写'), findsOneWidget);
    expect(find.text('让模型替你写'), findsNothing, reason: '生成中不渲染选项');
    expect(llm.callCount, 1);
    // 停止须经确认弹窗（生成中 spinner 无限动画，pumpAndSettle 会把
    // 假时钟一路推到外层 90s 超时——这里全部用有界 pump）
    await tester.tap(find.text('停止生成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('停掉这次生成？'), findsOneWidget);
    await tester.tap(find.text('停掉'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('开始写'), findsOneWidget, reason: '取消回确认页');

    // 在途请求此时才返回：结果作废，不回写预览
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('开始写'), findsOneWidget, reason: '作废结果不跳预览');
    expect(find.textContaining('模型生成的世界设定ABC'), findsNothing);
  });
}

class _ResultBox {
  DirectorWizardOutcome? value;
  bool popped = false;
}

class _StubResolver implements ConfigurationResolver {
  const _StubResolver();

  @override
  Future<NamingConfig?> resolvePresetModelNamingConfig(
    String presetId,
    String modelId,
  ) async {
    return const NamingConfig(
      baseUrl: 'https://example.com',
      apiKey: 'sk-test',
      modelId: 'model-1',
    );
  }

  @override
  Future<({Duration connectTimeout, Duration readTimeout})> resolveTimeouts() {
    return Future.value(
      (
        connectTimeout: const Duration(seconds: 15),
        readTimeout: const Duration(seconds: 30),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _GenLlmService implements LlmService {
  _GenLlmService({required this.llmFails, this.gate});

  final bool llmFails;

  /// 非空时 chat 等待其完成（生成中取消用例的在途请求控制）
  final Completer<void>? gate;

  int callCount = 0;
  final requests = <LlmRequest>[];

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    callCount++;
    requests.add(request);
    if (gate != null) await gate!.future;
    if (llmFails) throw Exception('llm down');
    return const LlmResponse(content: '模型生成的世界设定ABC');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopSettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
