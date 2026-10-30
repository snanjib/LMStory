import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/director_wizard/domain/entities/director_wizard_outcome.dart';
import 'package:lmstory/features/director_wizard/presentation/controllers/director_wizard_controller.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';
import '../../../../test_helpers/wizard_page_actions.dart';

/// 2026-10-19 反馈批：问卷「选中即原文」预览盒、自定义输入用户补充行、
/// 「初始化你的角色」开关（自由描述/选角色卡）与完成产物携带。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ApiPreset keyedPreset() => ApiPreset(
        presetId: 'preset-1',
        name: '测试供应商',
        baseUrl: 'https://example.com',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        cachedModels: const [ModelInfo(modelId: 'model-1')],
      );

  CharacterCard card({String id = 'card-1', String name = '林九的卡'}) =>
      CharacterCard(
        cardId: id,
        name: name,
        rawJson: '{}',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  /// 进入问卷答题页（模型步选模型 → 嵌入步跳过 → 规则步选问卷路）。
  Future<void> pumpToQuiz(
    WidgetTester tester, {
    required FakeWizardSettingsNotifier fake,
    List<CharacterCard> cards = const [],
    _ResultBox? box,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) => fake),
          settingsRepositoryProvider.overrideWithValue(_NoopSettingsRepo()),
          advancedConfigProvider
              .overrideWith((ref) async => const AdvancedConfig()),
          configurationResolverProvider
              .overrideWithValue(const _StubResolver()),
          llmServiceProvider.overrideWithValue(_NoopLlmService()),
          resourceLibraryRepositoryProvider
              .overrideWithValue(_CardOnlyResourceRepo(cards)),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
            home: box == null
                ? const DirectorWizardPage()
                : Builder(
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
                            box.value = outcome;
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
    if (box != null) {
      await tester.tap(find.text('open-wizard'));
      await tester.pumpAndSettle();
    } else {
      await tester.pumpAndSettle();
    }
    await pickWizardGmViaSheet(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await skipWizardEmbedding(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    // 规则步 → 问卷路
    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
  }

  testWidgets('选中题材即显拼入原文（弹层内）；摘要卡回显答案与原文', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToQuiz(tester, fake: fake);

    // 短页：三张摘要卡全未选，无原文盒
    expect(find.text('未选'), findsNWidgets(3));
    expect(find.text('将写入提示词'), findsNothing);

    // 开题材弹层选奇幻修仙（留在弹层断言选中即原文）
    await answerWizardQuiz(
      tester,
      question: '想在一个什么样的世界里玩？',
      option: '奇幻修仙',
      dismissSheet: false,
    );
    expect(find.text('将写入提示词'), findsOneWidget);
    expect(
      find.textContaining('这是一个东方修仙世界'),
      findsAtLeastNWidgets(1),
      reason: '弹层内题材块原文可见（摘要卡同文实时回显故不止一处）',
    );

    // 关弹层回短页：摘要卡回显答案 + 原文一行预览
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('奇幻修仙'), findsOneWidget);
    expect(find.textContaining('这是一个东方修仙世界'), findsOneWidget);
    expect(find.text('未选'), findsNWidgets(2), reason: '余两题仍未选');
  });

  testWidgets('人称选中即显块；「留空」无块不显', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToQuiz(tester, fake: fake);

    await answerWizardQuiz(
      tester,
      question: '故事用什么视角讲？',
      option: '第一人称',
      dismissSheet: false,
    );
    expect(
      find.textContaining('故事以第一人称讲述'),
      findsAtLeastNWidgets(1),
      reason: '弹层内人称块可见（摘要卡同文实时回显）',
    );

    await tester.ensureVisible(find.text('留空'));
    await tester.tap(find.text('留空'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('故事以第一人称讲述'),
      findsNothing,
      reason: '留空无块，原文盒随之消失',
    );
  });

  testWidgets('自定义输入实时显示「用户补充」拼入行（弹层内）', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToQuiz(tester, fake: fake);

    await answerWizardQuiz(
      tester,
      question: '想在一个什么样的世界里玩？',
      dismissSheet: false,
    );
    // 题材九选项占满首屏，自定义输入框在折叠线之下——滚动到构建再输入
    await tester.scrollUntilVisible(
      find.byType(TextField),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.enterText(
      find.byType(TextField).first,
      '赛博霓虹下的地下城',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('用户补充：赛博霓虹下的地下城'),
      findsAtLeastNWidgets(1),
      reason: '自定义原文按拼装前缀实时预览（弹层内+摘要卡回显）',
    );
  });

  testWidgets('下一题链式推进：三题连答完成回短页，摘要卡全回显', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToQuiz(tester, fake: fake);

    // 题材 → 下一题（链开文风弹层）
    await answerWizardQuiz(
      tester,
      question: '想在一个什么样的世界里玩？',
      option: '奇幻修仙',
      advance: true,
      dismissSheet: false,
    );
    expect(
      find.text('白话流畅'),
      findsOneWidget,
      reason: '文风选项已随链式弹层在场',
    );
    await tester.tap(find.text('白话流畅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一题'));
    await tester.pumpAndSettle();

    // 人称（末题主按钮=完成答题）
    expect(find.text('第三人称'), findsOneWidget);
    await tester.tap(find.text('第三人称'));
    await tester.pumpAndSettle();
    expect(find.text('完成答题'), findsOneWidget);
    await tester.tap(find.text('完成答题'));
    await tester.pumpAndSettle();

    // 回短页：三卡全回显，未选清零
    expect(find.text('奇幻修仙'), findsOneWidget);
    expect(find.text('白话流畅'), findsOneWidget);
    expect(find.text('第三人称'), findsOneWidget);
    expect(find.text('未选'), findsNothing);
  });

  testWidgets('初始化角色：默认关；开启后双路径；描述可输入', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToQuiz(tester, fake: fake);

    expect(find.text('初始化你的角色'), findsOneWidget);
    expect(find.text('我自己描述'), findsNothing, reason: '默认关不渲染子选项');

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('我自己描述'), findsOneWidget);
    expect(find.text('选一张现成角色卡'), findsOneWidget);
    expect(
      find.textContaining('可以描述你想要在第一轮就出现的角色'),
      findsOneWidget,
      reason: '描述框带引导提示',
    );

    await tester.enterText(
      find.byType(TextField).last,
      '林九，男，落魄刀客，欠了一屁股债',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('初始化角色-卡路径：空库 SnackBar 提示；有卡可选并回显', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpToQuiz(tester, fake: fake);

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选一张现成角色卡'));
    await tester.tap(find.text('选一张现成角色卡'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('挑一张角色卡'));
    await tester.tap(find.text('挑一张角色卡'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('还没有角色卡'),
      findsOneWidget,
      reason: '空库提示（不阻断，可切回自己描述）',
    );
  });

  testWidgets('完成产物：描述路径携带 characterInitPrompt（规则未确认也不丢）', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    final box = _ResultBox();
    await pumpToQuiz(tester, fake: fake, box: box);

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      '林九，男，落魄刀客',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('完成'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(box.value, isNotNull);
    expect(box.value!.characterInitPrompt, '林九，男，落魄刀客');
    expect(box.value!.characterCardId, isNull);
    expect(
      box.value!.systemPromptOverride,
      isNull,
      reason: '规则未确认仍为跳过语义',
    );
  });

  testWidgets('完成产物：卡路径携带 characterCardId', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    final box = _ResultBox();
    await pumpToQuiz(
      tester,
      fake: fake,
      cards: [card()],
      box: box,
    );

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选一张现成角色卡'));
    await tester.tap(find.text('选一张现成角色卡'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('挑一张角色卡'));
    await tester.tap(find.text('挑一张角色卡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('林九的卡'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选角色卡：林九的卡'), findsOneWidget);

    await tester.ensureVisible(find.text('完成'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(box.value, isNotNull);
    expect(box.value!.characterCardId, 'card-1');
    expect(box.value!.characterInitPrompt, isNull);
  });

  group('DirectorWizardState 出口派生 getter（开关/模式/空值组合）', () {
    test('默认全 null（未启用）', () {
      const state = DirectorWizardState(currentStep: 0);
      expect(state.characterInitPrompt, isNull);
      expect(state.characterCardId, isNull);
    });

    test('describe + 非空描述 → prompt 非 null；空白描述仍 null', () {
      const base = DirectorWizardState(
        currentStep: 0,
        rulesCharacterInitEnabled: true,
        rulesCharacterDescription: '  林九  ',
      );
      expect(base.characterInitPrompt, '林九');
      expect(base.characterCardId, isNull);

      const blank = DirectorWizardState(
        currentStep: 0,
        rulesCharacterInitEnabled: true,
        rulesCharacterDescription: '   ',
      );
      expect(blank.characterInitPrompt, isNull);
    });

    test('card + 已选 → cardId 非 null；开关关闭时选择不出口', () {
      const picked = DirectorWizardState(
        currentStep: 0,
        rulesCharacterInitEnabled: true,
        rulesCharacterInitMode: WizardCharacterInitMode.card,
        rulesCharacterCardId: 'card-9',
      );
      expect(picked.characterCardId, 'card-9');
      expect(picked.characterInitPrompt, isNull);

      const off = DirectorWizardState(
        currentStep: 0,
        rulesCharacterInitMode: WizardCharacterInitMode.card,
        rulesCharacterCardId: 'card-9',
      );
      expect(off.characterCardId, isNull);
    });
  });
}

class _ResultBox {
  DirectorWizardOutcome? value;
}

class _NoopSettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 只实现卡读取两接口（其余 noSuchMethod 兜底）。
class _CardOnlyResourceRepo implements ResourceLibraryRepository {
  _CardOnlyResourceRepo(this.cards);

  final List<CharacterCard> cards;

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => cards;

  @override
  Future<CharacterCard?> getCharacterCard(String cardId) async {
    for (final c in cards) {
      if (c.cardId == cardId) return c;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
