import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';

/// 配置双模式守卫测试两条（C-P1 定稿 §4.3(d)）。
///
/// a) 表↔代码对账：分类表（119 项账本）中每个「有 UI」C-编号至少被
///    一个键的 cIds 引用（36 项 simple 逐项验收即由此承载）；代码侧
///    引用的每个 cIds 必须存在于账本编号域（C-01..C-122，C-18 已剔除）。
/// b) 15 面声明键集合快照：与 C-P1 定稿 §一逐页对照清单一致，防实施
///    漂移；结构无变化面声明为空键集。
///
/// 打标真源`（本测试的
/// 编号清单即其 §二/§四 快照；改表先改这里，再改载体）。
void main() {
  // ── 分类表快照（2026-09-20 D-C11/D-C12 补录后终态）──────────────
  /// 账本全集：C-01..C-122（C-18 经核为组件态默认，已从账本剔除；
  /// C-121/C-122 为 WS1 外观两键入账，账本 119→121）。
  final universe = <String>{
    for (var i = 1; i <= 122; i++)
      if (i != 18) 'C-${i.toString().padLeft(2, '0')}',
  };

  /// 无 UI 项（页面=（无 UI），28 项）：不可过滤，账本记档。
  /// C-84 勘误：C-P4 实测有 UI（DirectorStepperRow 两行），
  /// 随 C-83 组整组 advanced，移出本集合。
  final noUiIds = {
    'C-26', 'C-39', //
    'C-46', 'C-47', 'C-48', 'C-49', 'C-50', 'C-51', 'C-52', 'C-53', 'C-54',
    'C-55', 'C-56', 'C-57', 'C-58', 'C-59', 'C-60', 'C-61',
    'C-68', 'C-76', 'C-79', 'C-85', 'C-86',
    'C-87', 'C-88', 'C-89', 'C-90', 'C-91',
  };

  /// 「有 UI」项 = 全集 − 无 UI（91 项）。
  final uiIds = universe.difference(noUiIds);

  /// 36 项 simple（分类表 §四分布：D-C11 补录后 + C-121/C-122 外观键
  /// + D-C13 C-43 嵌入模型）。
  final simpleIds = {
    'C-01', 'C-02', 'C-03', 'C-04', 'C-05', 'C-09', //
    'C-10', 'C-11', 'C-12', 'C-13', 'C-14', 'C-15', 'C-16', 'C-17',
    'C-19',
    'C-27', 'C-28', 'C-34', 'C-43',
    'C-62', 'C-63', 'C-65',
    'C-92', 'C-93', 'C-99',
    'C-100', 'C-101', 'C-108', 'C-109',
    'C-110', 'C-112', 'C-113', 'C-119', 'C-120',
    'C-121', 'C-122',
  };

  // ── 15 面声明键集合快照（定稿 §一）────────────────────────────
  final surfaceSnapshot = <String, List<String>>{
    'settings.home': [],
    'settings.general': [],
    'settings.appearance': [
      ConfigVisibilityKeys.appearanceThemeMode,
      ConfigVisibilityKeys.appearanceFontSize,
      ConfigVisibilityKeys.appearanceStructure,
      ConfigVisibilityKeys.appearancePalette,
    ],
    'settings.languageInput': [
      ConfigVisibilityKeys.languageUiLanguage,
      ConfigVisibilityKeys.languageSendKey,
    ],
    'settings.general.advanced': [
      ConfigVisibilityKeys.generalAdvancedReasoningEffort,
      ConfigVisibilityKeys.generalAdvancedTimeout,
      ConfigVisibilityKeys.generalAdvancedTitleModel,
    ],
    'settings.chat': [
      ConfigVisibilityKeys.chatDefaultModel,
      ConfigVisibilityKeys.chatGenerationDefaults,
      ConfigVisibilityKeys.chatAutoCompaction,
      ConfigVisibilityKeys.chatDisplayPreferences,
    ],
    'settings.story.hub': [
      ConfigVisibilityKeys.storyHubModels,
      ConfigVisibilityKeys.storyHubSystemPrompt,
      ConfigVisibilityKeys.storyHubToolsMemory,
      ConfigVisibilityKeys.storyHubGeneration,
      ConfigVisibilityKeys.storyHubPrompts,
      ConfigVisibilityKeys.storyHubSuggestReply,
    ],
    'settings.story.models': [
      ConfigVisibilityKeys.storyModelsPhaseModels,
      ConfigVisibilityKeys.storyModelsEmbedding,
    ],
    'settings.story.systemPrompt': [
      ConfigVisibilityKeys.storySystemPromptSection,
    ],
    'settings.story.generation': [
      ConfigVisibilityKeys.storyGlobalGenerationTemperature,
      ConfigVisibilityKeys.storyGlobalGenerationTopP,
      ConfigVisibilityKeys.storyGlobalGenerationMaxTokens,
      ConfigVisibilityKeys.storyGlobalGenerationPresencePenalty,
      ConfigVisibilityKeys.storyGlobalGenerationFrequencyPenalty,
      ConfigVisibilityKeys.storyGlobalGenerationReasoningEffort,
    ],
    'settings.director': [
      ConfigVisibilityKeys.directorRules,
      ConfigVisibilityKeys.directorGmModel,
      ConfigVisibilityKeys.directorGenerationTemperature,
      ConfigVisibilityKeys.directorGenerationTopP,
      ConfigVisibilityKeys.directorGenerationMaxTokens,
      ConfigVisibilityKeys.directorGenerationPresencePenalty,
      ConfigVisibilityKeys.directorGenerationFrequencyPenalty,
      ConfigVisibilityKeys.directorGenerationReasoningEffort,
      ConfigVisibilityKeys.directorPacing,
      ConfigVisibilityKeys.directorSuggestReply,
      ConfigVisibilityKeys.directorToolPermissions,
      ConfigVisibilityKeys.directorBudget,
      ConfigVisibilityKeys.directorContext,
      ConfigVisibilityKeys.directorMemoryEmbedding,
      ConfigVisibilityKeys.directorMemoryFactual,
      ConfigVisibilityKeys.directorMemoryConsolidation,
      ConfigVisibilityKeys.directorMemoryAdvanced,
    ],
    'settings.data': [
      ConfigVisibilityKeys.dataAutoBackup,
    ],
    'panel.chat': [
      ConfigVisibilityKeys.chatPanelModel,
      ConfigVisibilityKeys.chatPanelSystemPrompt,
      ConfigVisibilityKeys.chatPanelTemperature,
      ConfigVisibilityKeys.chatPanelTopP,
      ConfigVisibilityKeys.chatPanelMaxTokens,
      ConfigVisibilityKeys.chatPanelMaxContextMessages,
      ConfigVisibilityKeys.chatPanelStreamEnabled,
      ConfigVisibilityKeys.chatPanelReasoningEffort,
    ],
    'panel.story': [
      ConfigVisibilityKeys.storyMemoryManagement,
      ConfigVisibilityKeys.storyResource,
      ConfigVisibilityKeys.storyPhaseModels,
      ConfigVisibilityKeys.storySystemPrompt,
      ConfigVisibilityKeys.storyGenerationTemperature,
      ConfigVisibilityKeys.storyGenerationTopP,
      ConfigVisibilityKeys.storyGenerationMaxTokens,
      ConfigVisibilityKeys.storyGenerationPresencePenalty,
      ConfigVisibilityKeys.storyGenerationFrequencyPenalty,
      ConfigVisibilityKeys.storyGenerationReasoningEffort,
      ConfigVisibilityKeys.storyContextWindow,
      ConfigVisibilityKeys.storyContextBudget,
      ConfigVisibilityKeys.storyToolCalling,
      ConfigVisibilityKeys.storySuggestReply,
    ],
    'panel.director': [
      ConfigVisibilityKeys.directorPanelMemoryManagement,
      ConfigVisibilityKeys.directorPanelRules,
      ConfigVisibilityKeys.directorPanelGmModel,
      ConfigVisibilityKeys.directorPanelGenerationTemperature,
      ConfigVisibilityKeys.directorPanelGenerationTopP,
      ConfigVisibilityKeys.directorPanelGenerationPresencePenalty,
      ConfigVisibilityKeys.directorPanelGenerationFrequencyPenalty,
      ConfigVisibilityKeys.directorPanelGenerationMaxTokens,
      ConfigVisibilityKeys.directorPanelGenerationReasoningEffort,
      ConfigVisibilityKeys.directorPanelPacing,
      ConfigVisibilityKeys.directorPanelSupervision,
      ConfigVisibilityKeys.directorPanelBudget,
      ConfigVisibilityKeys.directorPanelContext,
      ConfigVisibilityKeys.directorPanelResource,
    ],
  };

  group('守卫 a：分类表 ↔ 载体 cIds 对账', () {
    test('代码引用的每个 cIds 都在账本编号域（C-01..C-122，无 C-18）', () {
      final referenced = <String>{
        for (final key in ConfigVisibility.registeredKeys)
          ...ConfigVisibility.entryOf(key)!.cIds,
      };
      expect(
        referenced.difference(universe),
        isEmpty,
        reason: '代码引用了账本外的编号，先改分类表再改代码（红线 4）',
      );
    });

    test('每个「有 UI」C-编号至少被一个键的 cIds 引用（90 项防漏接）', () {
      final referenced = <String>{
        for (final key in ConfigVisibility.registeredKeys)
          ...ConfigVisibility.entryOf(key)!.cIds,
      };
      expect(
        uiIds.difference(referenced),
        isEmpty,
        reason: '有 UI 的配置项未被任何可见性键覆盖（漏接即简化模式放空）',
      );
    });

    test('未登记键 fail-open 契约：entryOf 为空即 release 分支唯一可见路径', () {
      // debug 断言抛错由 config_level_test 锁定；release 语义=未登记
      // 视为可见（误隐藏核心配置的代价高于多显示一个技术参数）。
      // of() 对未登记键的 release 返回值即 true，此处锁定其前置语义：
      // unregistered => entryOf == null（fail-open 判据单源）。
      expect(ConfigVisibility.entryOf('panel.story.notRegistered'), isNull);
      expect(ConfigVisibility.entryOf('settings.chat.defaultModel'), isNotNull);
    });

    test('36 项 simple 全部落在 simple 级键上（逐项验收）', () {
      final simpleCovered = <String>{
        for (final key in ConfigVisibility.registeredKeys)
          if (ConfigVisibility.entryOf(key)!.level == ConfigLevel.simple)
            ...ConfigVisibility.entryOf(key)!.cIds,
      };
      expect(
        simpleIds.difference(simpleCovered),
        isEmpty,
        reason: '分类表判 simple 的项必须由 simple 级键承载',
      );
      // simple 键的 cIds 不得混入 advanced 项（行级拆分项除外：
      // D-C7/D-C12 行打标仍 advanced、控件键 simple 的先例由 C-64/
      // C-102/C-111 键对账承载，cIds 允许 advanced 编号出现在 simple 键）
      expect(
        simpleCovered.difference(universe.difference(noUiIds)),
        isEmpty,
        reason: 'simple 键引用了无 UI 编号',
      );
    });
  });

  group('守卫 b：15 面声明键集合快照', () {
    test('载体声明与定稿 §一快照一致（防实施漂移）', () {
      expect(ConfigVisibilitySurfaces.declarations, surfaceSnapshot);
    });

    test('每个登记键恰好归属一个面（无孤儿键、无跨面重复）', () {
      final ownership = <String, List<String>>{};
      ConfigVisibilitySurfaces.declarations.forEach((surface, keys) {
        for (final key in keys) {
          ownership.putIfAbsent(key, () => []).add(surface);
        }
      });
      expect(
        ownership.keys.toSet(),
        ConfigVisibility.registeredKeys.toSet(),
        reason: '声明面与登记键集合不一致',
      );
      final duplicated =
          ownership.entries.where((e) => e.value.length > 1).map((e) => e.key);
      expect(duplicated, isEmpty, reason: '同一键出现在多个面');
    });

    test('声明键集合恰好 15 面', () {
      expect(ConfigVisibilitySurfaces.declarations.length, 15);
    });
  });
}
