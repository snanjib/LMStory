import 'package:lmstory/core/config/config_level.dart';

/// 配置可见性标注注册表。
///
/// 打标真源是`：本表每一处
/// 标注经 [ConfigVisibilityEntry.cIds] 对账回分类表；改可见性先改
/// 分类表（含判据一句话），再改这里。只登记实际被过滤层查询的键。
///
/// 键为「面.区.行」三级路径字符串（[ConfigVisibilityKeys]）：
/// 区级整区过滤用两级键，区内行级过滤在区键下再挂行键。
/// 过滤只动展示层——被隐藏项的存储键、默认值、消费点与已有用户值
/// 全部不动。
class ConfigVisibilityKeys {
  ConfigVisibilityKeys._();

  // ── 对话模式设置页（settings.chat.*）──
  static const chatDefaultModel = 'settings.chat.defaultModel';
  static const chatGenerationDefaults = 'settings.chat.generationDefaults';
  static const chatAutoCompaction = 'settings.chat.autoCompaction';
  static const chatDisplayPreferences = 'settings.chat.displayPreferences';

  // ── 通用设置 — 高级子页（settings.general.advanced.*）──
  static const generalAdvancedReasoningEffort =
      'settings.general.advanced.reasoningEffort';
  static const generalAdvancedTimeout = 'settings.general.advanced.timeout';
  static const generalAdvancedTitleModel =
      'settings.general.advanced.titleModel';

  // ── 故事模式设置枢纽页（settings.story.hub.*）──
  static const storyHubModels = 'settings.story.hub.models';
  static const storyHubSystemPrompt = 'settings.story.hub.systemPrompt';
  static const storyHubToolsMemory = 'settings.story.hub.toolsMemory';
  static const storyHubGeneration = 'settings.story.hub.generation';
  static const storyHubPrompts = 'settings.story.hub.prompts';
  static const storyHubSuggestReply = 'settings.story.hub.suggestReply';

  // ── 故事模式设置 — 模型子页（settings.story.models.*）──
  static const storyModelsPhaseModels = 'settings.story.models.phaseModels';
  static const storyModelsEmbedding = 'settings.story.models.embedding';

  // ── 故事模式设置 — 生成参数子页（settings.story.generation.*，
  // 全局页内行级混排：区壳恒显，思考预算行 simple、采样参数行 advanced）──
  static const storyGlobalGenerationTemperature =
      'settings.story.generation.temperature';
  static const storyGlobalGenerationTopP = 'settings.story.generation.topP';
  static const storyGlobalGenerationMaxTokens =
      'settings.story.generation.maxTokens';
  static const storyGlobalGenerationPresencePenalty =
      'settings.story.generation.presencePenalty';
  static const storyGlobalGenerationFrequencyPenalty =
      'settings.story.generation.frequencyPenalty';
  static const storyGlobalGenerationReasoningEffort =
      'settings.story.generation.reasoningEffort';

  // ── 导演模式设置页（settings.director.*）──
  static const directorRules = 'settings.director.rules';
  static const directorGmModel = 'settings.director.modelGeneration.gmModel';
  static const directorGenerationTemperature =
      'settings.director.modelGeneration.temperature';
  static const directorGenerationTopP =
      'settings.director.modelGeneration.topP';
  static const directorGenerationMaxTokens =
      'settings.director.modelGeneration.maxTokens';
  static const directorGenerationPresencePenalty =
      'settings.director.modelGeneration.presencePenalty';
  static const directorGenerationFrequencyPenalty =
      'settings.director.modelGeneration.frequencyPenalty';
  static const directorGenerationReasoningEffort =
      'settings.director.modelGeneration.reasoningEffort';
  static const directorPacing = 'settings.director.modelGeneration.pacing';
  static const directorSuggestReply =
      'settings.director.modelGeneration.suggestReply';
  static const directorToolPermissions = 'settings.director.tools';
  static const directorBudget = 'settings.director.budget';
  static const directorContext = 'settings.director.context';

  // 记忆区行级（D-C13：区壳恒显，区内行过滤，区级键随行级拆分移除）
  static const directorMemoryEmbedding = 'settings.director.memory.embedding';
  static const directorMemoryFactual = 'settings.director.memory.factual';
  static const directorMemoryConsolidation =
      'settings.director.memory.consolidation';
  static const directorMemoryAdvanced = 'settings.director.memory.advanced';

  // ── chat 会话设置面板（panel.chat.*，平铺结构无区壳，字段即行）──
  static const chatPanelModel = 'panel.chat.model';
  static const chatPanelSystemPrompt = 'panel.chat.systemPrompt';
  static const chatPanelTemperature = 'panel.chat.temperature';
  static const chatPanelTopP = 'panel.chat.topP';
  static const chatPanelMaxTokens = 'panel.chat.maxTokens';
  static const chatPanelMaxContextMessages = 'panel.chat.maxContextMessages';
  static const chatPanelStreamEnabled = 'panel.chat.streamEnabled';
  static const chatPanelReasoningEffort = 'panel.chat.reasoningEffort';

  // ── 导演会话设置面板（panel.director.*）──
  static const directorPanelMemoryManagement =
      'panel.director.memoryManagement';
  static const directorPanelRules = 'panel.director.rules';
  static const directorPanelGmModel = 'panel.director.modelGeneration.gmModel';
  static const directorPanelGenerationTemperature =
      'panel.director.modelGeneration.temperature';
  static const directorPanelGenerationTopP =
      'panel.director.modelGeneration.topP';
  static const directorPanelGenerationPresencePenalty =
      'panel.director.modelGeneration.presencePenalty';
  static const directorPanelGenerationFrequencyPenalty =
      'panel.director.modelGeneration.frequencyPenalty';
  static const directorPanelGenerationMaxTokens =
      'panel.director.modelGeneration.maxTokens';
  static const directorPanelGenerationReasoningEffort =
      'panel.director.modelGeneration.reasoningEffort';
  static const directorPanelPacing = 'panel.director.pacing';
  static const directorPanelSupervision = 'panel.director.supervision';
  static const directorPanelBudget = 'panel.director.budget';
  static const directorPanelContext = 'panel.director.context';
  static const directorPanelResource = 'panel.director.resource';

  // ── 结构无变化面（定稿 §1.3/1.4/1.9/1.12）：区键声明 + 空过滤门
  //（门在双模式下恒过，守卫快照与表↔代码对账需要键存在）──
  static const appearanceThemeMode = 'settings.appearance.themeMode';
  static const appearanceFontSize = 'settings.appearance.fontSize';
  static const appearanceStructure = 'settings.appearance.structure';
  static const appearancePalette = 'settings.appearance.palette';
  static const languageUiLanguage = 'settings.language.uiLanguage';
  static const languageSendKey = 'settings.language.sendKey';
  static const storySystemPromptSection = 'settings.story.systemPrompt.section';
  static const dataAutoBackup = 'settings.data.autoBackup';

  // ── 故事会话设置面板（panel.story.*，区键两级）──
  static const storyMemoryManagement = 'panel.story.memoryManagement';
  static const storyResource = 'panel.story.resource';
  static const storyPhaseModels = 'panel.story.phaseModels';
  static const storySystemPrompt = 'panel.story.systemPrompt';
  static const storyContextWindow = 'panel.story.contextWindow';
  static const storyContextBudget = 'panel.story.contextBudget';
  static const storyToolCalling = 'panel.story.toolCalling';
  static const storySuggestReply = 'panel.story.suggestReply';

  // ── 故事会话设置面板 · 生成参数区行键（panel.story.generation.*）──
  // 区壳双模式恒显（思考预算属生成参数族），不设区级键，行级过滤。
  static const storyGenerationTemperature =
      'panel.story.generation.temperature';
  static const storyGenerationTopP = 'panel.story.generation.topP';
  static const storyGenerationMaxTokens = 'panel.story.generation.maxTokens';
  static const storyGenerationPresencePenalty =
      'panel.story.generation.presencePenalty';
  static const storyGenerationFrequencyPenalty =
      'panel.story.generation.frequencyPenalty';
  static const storyGenerationReasoningEffort =
      'panel.story.generation.reasoningEffort';
}

class ConfigVisibilityEntry {
  const ConfigVisibilityEntry(this.level, this.cIds);

  /// 该键在简单模式是否可见（advanced 键仅进阶模式渲染）。
  final ConfigLevel level;

  /// 关联分类表 C-编号（可多个），供表↔代码对账。
  final List<String> cIds;
}

/// 查询唯一入口。
abstract final class ConfigVisibility {
  static const Map<String, ConfigVisibilityEntry> _entries = {
    // 对话模式设置页
    ConfigVisibilityKeys.chatDefaultModel:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-19']),
    ConfigVisibilityKeys.chatGenerationDefaults: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-20', 'C-21', 'C-22', 'C-23'],
    ),
    ConfigVisibilityKeys.chatAutoCompaction: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-24', 'C-25'],
    ),
    ConfigVisibilityKeys.chatDisplayPreferences: ConfigVisibilityEntry(
      ConfigLevel.simple,
      ['C-10', 'C-11', 'C-12', 'C-13', 'C-14', 'C-15', 'C-16'],
    ),
    // 通用设置 — 高级子页（3 区 → 1 区：思考预算保留，超时/标题模型进阶）
    ConfigVisibilityKeys.generalAdvancedReasoningEffort:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-09']),
    ConfigVisibilityKeys.generalAdvancedTimeout: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-06', 'C-07'],
    ),
    ConfigVisibilityKeys.generalAdvancedTitleModel:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-08']),
    // 故事模式设置枢纽页（7 卡 → 4 卡：生成参数卡保留——思考预算在区内）
    ConfigVisibilityKeys.storyHubModels:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-28']),
    ConfigVisibilityKeys.storyHubSystemPrompt:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-27']),
    ConfigVisibilityKeys.storyHubToolsMemory: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-35', 'C-36', 'C-37', 'C-38', 'C-40', 'C-41', 'C-42'],
    ),
    ConfigVisibilityKeys.storyHubGeneration: ConfigVisibilityEntry(
      ConfigLevel.simple,
      ['C-29', 'C-30', 'C-31', 'C-32', 'C-33', 'C-34'],
    ),
    ConfigVisibilityKeys.storyHubPrompts:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-45']),
    ConfigVisibilityKeys.storyHubSuggestReply:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-44']),
    // 故事模式设置 — 模型子页（D-C13：嵌入模型为两模式基本需要，划
    // simple；reasoning 提示卡为展示层裁量非配置项，不走键，见该页注释）
    ConfigVisibilityKeys.storyModelsPhaseModels:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-28']),
    ConfigVisibilityKeys.storyModelsEmbedding:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-43']),
    // 故事模式设置 — 生成参数子页（6 行 → 1 行：思考预算行保留）
    ConfigVisibilityKeys.storyGlobalGenerationTemperature:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-29']),
    ConfigVisibilityKeys.storyGlobalGenerationTopP:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-30']),
    ConfigVisibilityKeys.storyGlobalGenerationMaxTokens:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-31']),
    ConfigVisibilityKeys.storyGlobalGenerationPresencePenalty:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-32']),
    ConfigVisibilityKeys.storyGlobalGenerationFrequencyPenalty:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-33']),
    ConfigVisibilityKeys.storyGlobalGenerationReasoningEffort:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-34']),
    // 故事会话设置面板
    ConfigVisibilityKeys.storyMemoryManagement:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-108']),
    ConfigVisibilityKeys.storyResource:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-109']),
    ConfigVisibilityKeys.storyPhaseModels:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-100']),
    ConfigVisibilityKeys.storySystemPrompt:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-101']),
    ConfigVisibilityKeys.storyContextWindow:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-103']),
    ConfigVisibilityKeys.storyContextBudget:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-104']),
    ConfigVisibilityKeys.storyToolCalling:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-105', 'C-106']),
    ConfigVisibilityKeys.storySuggestReply:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-107']),
    // 生成参数区行级（思考预算行 simple，采样参数行 advanced）
    ConfigVisibilityKeys.storyGenerationTemperature:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-102']),
    ConfigVisibilityKeys.storyGenerationTopP:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-102']),
    ConfigVisibilityKeys.storyGenerationMaxTokens:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-102']),
    ConfigVisibilityKeys.storyGenerationPresencePenalty:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-102']),
    ConfigVisibilityKeys.storyGenerationFrequencyPenalty:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-102']),
    ConfigVisibilityKeys.storyGenerationReasoningEffort:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-102']),
    // 导演模式设置页（5 折叠区 → 2 区：规则 + 记忆区壳恒显；模型与生成
    // 区 9 行 → 2 行 + 思考档行级保留（D-C12）；记忆区内行级过滤——
    // 向量化模型行 simple（D-C13）；推荐回复组尾整组隐藏）
    ConfigVisibilityKeys.directorRules:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-62']),
    ConfigVisibilityKeys.directorGmModel:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-63']),
    ConfigVisibilityKeys.directorGenerationTemperature:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-64']),
    ConfigVisibilityKeys.directorGenerationTopP:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-64']),
    ConfigVisibilityKeys.directorGenerationMaxTokens:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-64']),
    ConfigVisibilityKeys.directorGenerationPresencePenalty:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-64']),
    ConfigVisibilityKeys.directorGenerationFrequencyPenalty:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-64']),
    ConfigVisibilityKeys.directorGenerationReasoningEffort:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-64']),
    ConfigVisibilityKeys.directorPacing:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-65']),
    ConfigVisibilityKeys.directorSuggestReply: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-83', 'C-84'],
    ),
    ConfigVisibilityKeys.directorToolPermissions:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-77']),
    ConfigVisibilityKeys.directorBudget: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-66', 'C-67', 'C-69', 'C-70', 'C-71', 'C-72', 'C-73'],
    ),
    ConfigVisibilityKeys.directorContext: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-74', 'C-75'],
    ),
    // 记忆区行级（D-C13：向量化模型行 simple，记忆管线技术行 advanced）
    ConfigVisibilityKeys.directorMemoryEmbedding:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-81']),
    ConfigVisibilityKeys.directorMemoryFactual:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-78']),
    ConfigVisibilityKeys.directorMemoryConsolidation:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-80']),
    ConfigVisibilityKeys.directorMemoryAdvanced:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-81', 'C-82']),
    // chat 会话设置面板（8 字段 → 3 字段：模型/系统提示词/思考预算保留）
    ConfigVisibilityKeys.chatPanelModel:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-92']),
    ConfigVisibilityKeys.chatPanelSystemPrompt:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-93']),
    ConfigVisibilityKeys.chatPanelTemperature:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-94']),
    ConfigVisibilityKeys.chatPanelTopP:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-95']),
    ConfigVisibilityKeys.chatPanelMaxTokens:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-96']),
    ConfigVisibilityKeys.chatPanelMaxContextMessages:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-97']),
    ConfigVisibilityKeys.chatPanelStreamEnabled:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-98']),
    ConfigVisibilityKeys.chatPanelReasoningEffort:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-99']),
    // 导演会话设置面板（8 区 → 5 区；模型与生成区行级过滤 + D-C12
    // 思考档行级保留；记忆管理/角色卡世界书两区为 D-C11 补标 C-119/C-120）
    ConfigVisibilityKeys.directorPanelMemoryManagement:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-119']),
    ConfigVisibilityKeys.directorPanelRules:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-113']),
    ConfigVisibilityKeys.directorPanelGmModel:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-110']),
    ConfigVisibilityKeys.directorPanelGenerationTemperature:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-111']),
    ConfigVisibilityKeys.directorPanelGenerationTopP:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-111']),
    ConfigVisibilityKeys.directorPanelGenerationPresencePenalty:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-111']),
    ConfigVisibilityKeys.directorPanelGenerationFrequencyPenalty:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-111']),
    ConfigVisibilityKeys.directorPanelGenerationMaxTokens:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-111']),
    ConfigVisibilityKeys.directorPanelGenerationReasoningEffort:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-111']),
    ConfigVisibilityKeys.directorPanelPacing:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-112']),
    ConfigVisibilityKeys.directorPanelSupervision: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-114', 'C-115'],
    ),
    ConfigVisibilityKeys.directorPanelBudget: ConfigVisibilityEntry(
      ConfigLevel.advanced,
      ['C-116', 'C-117'],
    ),
    ConfigVisibilityKeys.directorPanelContext:
        ConfigVisibilityEntry(ConfigLevel.advanced, ['C-118']),
    ConfigVisibilityKeys.directorPanelResource:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-120']),
    // 结构无变化面（区键声明，双模式恒过；实现见各页）
    ConfigVisibilityKeys.appearanceThemeMode:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-01']),
    ConfigVisibilityKeys.appearanceFontSize:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-03']),
    ConfigVisibilityKeys.appearanceStructure:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-121']),
    ConfigVisibilityKeys.appearancePalette:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-122']),
    ConfigVisibilityKeys.languageUiLanguage:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-02']),
    ConfigVisibilityKeys.languageSendKey:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-04', 'C-05']),
    ConfigVisibilityKeys.storySystemPromptSection:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-27']),
    ConfigVisibilityKeys.dataAutoBackup:
        ConfigVisibilityEntry(ConfigLevel.simple, ['C-17']),
  };

  /// 已登记的全部可见性键（守卫测试遍历用）。
  static Iterable<String> get registeredKeys => _entries.keys;

  /// [key] 的标注 entry；未登记返回 null（守卫测试与对账用）。
  static ConfigVisibilityEntry? entryOf(String key) => _entries[key];

  /// [key] 是否在 [current] 级别下渲染。
  ///
  /// 未登记键：debug 断言即抛错（接线期强制登记，误隐藏核心配置的
  /// 代价远高于多显示一个技术参数）；release fail-open 视为可见。
  static bool of(String key, ConfigLevel current) {
    final entry = _entries[key];
    if (entry == null) {
      assert(
        false,
        'ConfigVisibility: 可见性键 "$key" 未登记，'
        ' 请先在配置可见性分类表打标后补入 config_visibility.dart',
      );
      return true;
    }
    return current == ConfigLevel.advanced || entry.level == ConfigLevel.simple;
  }
}

/// 15 个过滤面的声明键集合（C-P1 定稿 §一逐页对照的代码投影）。
///
/// 键集合快照由守卫测试对账（防实施漂移）；结构无变化面（设置主页/
/// 通用设置页）声明为空键集——入口层不裁剪，页面内容见各页声明门。
abstract final class ConfigVisibilitySurfaces {
  static const Map<String, List<String>> declarations = {
    // 设置侧 12 页
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
    // 会话内 3 面板
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
}
