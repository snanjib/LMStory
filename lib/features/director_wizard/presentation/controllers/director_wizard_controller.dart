import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/features/director_wizard/domain/services/world_prompt_composer.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';

/// 模型步分支（进入模型步时按「是否存在任一带 Key 供应商」判定一次）。
enum WizardModelBranch {
  /// 尚未判定（settings 未装载完）
  undetermined,

  /// 从未配置：模板创建供应商 + 贴 Key + 拉模型 + 选模型
  unconfigured,

  /// 已配置：从既有 preset × 已拉取模型直选（仅写会话覆盖）
  configured,
}

/// 嵌入步现状（进入嵌入步时按全局 advanced.embedding_* 快照判定一次）。
enum WizardEmbeddingStatus {
  /// 尚未判定（advancedConfig 未装载完）
  undetermined,

  /// 已有全局嵌入配置：显示现状 + 保留/更换/关闭
  configured,

  /// 未配置：讲好处 + 选/接新供应商/跳过
  unconfigured,
}

/// 项目规则步路径：路 A 模板选择 / 路 B 世界观问卷。
enum WizardRulesPath {
  /// 尚未选择路径
  undetermined,

  /// 路 A：现成模板
  template,

  /// 路 B：三题问卷 → 拼装或生成
  questionnaire,
}

/// 「初始化你的角色」方式（问卷路开关打开后二选一）。
enum WizardCharacterInitMode {
  /// 自由描述（第 1 轮尾部一次性注入）
  describe,

  /// 选现成角色卡（物化时走资料通道应用，无需一次性提示）
  card,
}

/// 项目规则步阶段。
enum WizardRulesStage {
  /// 路径分叉页
  choosing,

  /// 路 B 答题中
  answering,

  /// 生成方式确认页（「让模型替你写」点开后、点「开始写」前——
  /// 调用模型是有成本的事，须独立确认）
  confirming,

  /// 生成中（隔离态：不渲染任何选项，与向导选项状态解耦；
  /// 「停止生成」经确认弹窗后回 confirming）
  generating,

  /// 预览确认（四键 + 存模板开关）
  previewing,

  /// 自行编辑中
  editing,
}

/// 嵌入步选择（页面据此执行写键/零写入）。
///
/// 2026-10-18 UX 重构：砍掉「关闭」——创建流程不做配置管理，
/// 想关嵌入去设置页。
enum WizardEmbeddingChoice {
  /// 未做选择（未配置分支强制显式选择前停在此态）
  none,

  /// 保留现状——页面写回入口快照（F4：反悔更换时覆盖新值）
  keep,

  /// 选了模型（新的或既有）——页面写两键
  change,

  /// 先跳过（未配置分支）——零写入
  skip,
}

/// 导演向导状态机。
///
/// 三步：0=模型步 / 1=嵌入模型步 / 2=项目规则步。
/// 「退出即弃」由 autoDispose provider 承担：页面 pop 后 provider
/// 销毁，下次进入从全新状态开始；步内数据只存内存态，
/// 上一步/下一步不丢。
@immutable
class DirectorWizardState {
  const DirectorWizardState({
    required this.currentStep,
    this.modelBranch = WizardModelBranch.undetermined,
    this.selectedTemplateId = '',
    this.providerName = '',
    this.apiKeyInput = '',
    this.createdPresetId,
    this.fetchedModels = const [],
    this.providerSetupError,
    this.isSettingUpProvider = false,
    this.manualModelId = '',
    this.gmPresetId,
    this.gmModelId,
    this.isTestingConnection = false,
    this.testResult,
    this.shouldWriteGlobalDefaults = false,
    this.embeddingStatus = WizardEmbeddingStatus.undetermined,
    this.currentEmbeddingPresetId = '',
    this.currentEmbeddingModelId = '',
    this.embeddingChoice = WizardEmbeddingChoice.none,
    this.selectedEmbeddingPresetId,
    this.selectedEmbeddingModelId,
    this.showEmbProviderFlow = false,
    this.embSelectedTemplateId = '',
    this.embProviderName = '',
    this.embApiKeyInput = '',
    this.embCreatedPresetId,
    this.embFetchedModels = const [],
    this.embSetupError,
    this.embIsSettingUp = false,
    this.embManualModelId = '',
    this.rulesPath = WizardRulesPath.undetermined,
    this.rulesStage = WizardRulesStage.choosing,
    this.selectedRulesTemplateId,
    this.rulesGenreId,
    this.rulesGenreCustom = '',
    this.rulesStyleId,
    this.rulesStyleCustom = '',
    this.rulesPerson,
    this.rulesCharacterInitEnabled = false,
    this.rulesCharacterInitMode = WizardCharacterInitMode.describe,
    this.rulesCharacterDescription = '',
    this.rulesCharacterCardId,
    this.rulesCharacterCardName = '',
    this.rulesPreviewText,
    this.rulesPreviewGenerated = false,
    this.rulesGenFallback = false,
    this.rulesEditDraft = '',
    this.confirmedRules,
    this.saveRulesTemplate = true,
  });

  /// 当前步（0 基）
  final int currentStep;

  /// 总步数（一期恒三步）
  static const int totalSteps = 3;

  // ── 模型步 ──────────────────────────────────────────────────────

  final WizardModelBranch modelBranch;

  /// 未配置分支选中的供应商模板（'' = 未选；默认 tpl-deepseek）
  final String selectedTemplateId;

  /// 供应商名称（选中模板时预填模板名，可改）
  final String providerName;

  /// API Key 输入（创建链随 saveApiKey 即时落库）
  final String apiKeyInput;

  /// 创建链产出的 presetId（供应商实体即时落库，属用户资产）
  final String? createdPresetId;

  /// 拉取到的模型列表（空 + providerSetupError 非空 = 拉取失败走手填）
  final List<ModelInfo> fetchedModels;

  /// 创建/拉取链失败信息（原始异常串，UI 负责人话映射）
  final String? providerSetupError;

  /// 创建+存 Key+拉取 进行中
  final bool isSettingUpProvider;

  /// 拉取失败时的手填模型 ID
  final String manualModelId;

  /// GM 就绪两要素（Key 由创建链保证 / 已配置分支由带 Key 判定保证）
  final String? gmPresetId;
  final String? gmModelId;

  /// 测试连接进行中
  final bool isTestingConnection;

  /// 测试连接结果原文（'success' | 'fail:<category>|<raw>' | null）
  final String? testResult;

  /// 完成时是否顺带写全局默认（未配置分支=写，已配置分支=只写会话覆盖）
  final bool shouldWriteGlobalDefaults;

  // ── 嵌入步 ──────────────────────────────────────────────────────

  final WizardEmbeddingStatus embeddingStatus;

  /// 进入嵌入步时的全局嵌入现状快照（'' = 未配置）
  final String currentEmbeddingPresetId;
  final String currentEmbeddingModelId;

  final WizardEmbeddingChoice embeddingChoice;

  /// 选定要写入的嵌入模型（页面在选择确认时写两键）
  final String? selectedEmbeddingPresetId;
  final String? selectedEmbeddingModelId;

  /// 「接一家新供应商」展开态（嵌入步专属第二供应商流）
  final bool showEmbProviderFlow;

  // 嵌入步第二供应商流（与模型步创建链同构、状态独立，避免跨步互踩）
  final String embSelectedTemplateId;
  final String embProviderName;
  final String embApiKeyInput;
  final String? embCreatedPresetId;
  final List<ModelInfo> embFetchedModels;
  final String? embSetupError;
  final bool embIsSettingUp;
  final String embManualModelId;

  // ── 项目规则步 ──────────────────────────────────────────────────

  final WizardRulesPath rulesPath;
  final WizardRulesStage rulesStage;

  /// 路 A 选中的模板 id（content 由页面从模板列表取）
  final String? selectedRulesTemplateId;

  /// 路 B 三题答案（题材/文风/人称 + 自定义）
  final String? rulesGenreId;
  final String rulesGenreCustom;
  final String? rulesStyleId;
  final String rulesStyleCustom;
  final WorldPerson? rulesPerson;

  /// 「初始化你的角色」开关（问卷路专属，默认关）
  final bool rulesCharacterInitEnabled;

  /// 开启后的方式（默认自由描述）
  final WizardCharacterInitMode rulesCharacterInitMode;

  /// 自由描述原文（空 = 未写）
  final String rulesCharacterDescription;

  /// card 模式所选角色卡 id / 展示名（null = 未选）
  final String? rulesCharacterCardId;
  final String rulesCharacterCardName;

  /// 预览文本（拼装或生成产物）
  final String? rulesPreviewText;

  /// 预览是否为模型生成（否则为本地拼装）
  final bool rulesPreviewGenerated;

  /// 生成失败已回退拼装（UI 展示兜底提示）
  final bool rulesGenFallback;

  /// 生成调用进行中（阶段派生，非独立真源——禁止双真源分叉）
  bool get isGeneratingRules => rulesStage == WizardRulesStage.generating;

  /// 编辑框草稿
  final String rulesEditDraft;

  /// 确认使用的规则产物（null = 跳过规则步，跟随全局兜底）
  final String? confirmedRules;

  /// 「保存到我的模板」开关（默认开；不存需用户主动关闭）
  final bool saveRulesTemplate;

  /// 拉取结果中嵌入类型的可选模型（类型标记是群材料实证头号坑，只列对的）
  List<ModelInfo> get embSelectableModels =>
      embFetchedModels.where((m) => m.type == ModelType.embedding).toList();

  /// 拉取列表中可作 GM 的对话模型（与已配置分支同口径过滤嵌入类型，
  /// 防新手把嵌入模型选成导演主模型）
  List<ModelInfo> get gmSelectableModels =>
      fetchedModels.where((m) => m.type == ModelType.chat).toList();

  /// 模型步门控：GM preset+model 齐（E010 的前置条件）
  bool get isModelReady =>
      gmPresetId != null &&
      gmPresetId!.isNotEmpty &&
      gmModelId != null &&
      gmModelId!.isNotEmpty;

  /// 嵌入步门控：未配置分支强制显式选择——
  /// 未选「配上」或「暂时跳过」前不放行下一步
  bool get isEmbeddingChoicePending =>
      embeddingStatus == WizardEmbeddingStatus.unconfigured &&
      embeddingChoice == WizardEmbeddingChoice.none;

  /// 出口产物：初始化角色自由描述（开关开 + describe + 非空才非 null）
  String? get characterInitPrompt => rulesCharacterInitEnabled &&
          rulesCharacterInitMode == WizardCharacterInitMode.describe &&
          rulesCharacterDescription.trim().isNotEmpty
      ? rulesCharacterDescription.trim()
      : null;

  /// 出口产物：所选角色卡 id（开关开 + card + 已选才非 null）
  String? get characterCardId => rulesCharacterInitEnabled &&
          rulesCharacterInitMode == WizardCharacterInitMode.card &&
          rulesCharacterCardId != null &&
          rulesCharacterCardId!.isNotEmpty
      ? rulesCharacterCardId
      : null;

  DirectorWizardState copyWith({
    int? currentStep,
    WizardModelBranch? modelBranch,
    String? selectedTemplateId,
    String? providerName,
    String? apiKeyInput,
    Object? createdPresetId = _sentinel,
    List<ModelInfo>? fetchedModels,
    Object? providerSetupError = _sentinel,
    bool? isSettingUpProvider,
    String? manualModelId,
    Object? gmPresetId = _sentinel,
    Object? gmModelId = _sentinel,
    bool? isTestingConnection,
    Object? testResult = _sentinel,
    bool? shouldWriteGlobalDefaults,
    WizardEmbeddingStatus? embeddingStatus,
    String? currentEmbeddingPresetId,
    String? currentEmbeddingModelId,
    WizardEmbeddingChoice? embeddingChoice,
    Object? selectedEmbeddingPresetId = _sentinel,
    Object? selectedEmbeddingModelId = _sentinel,
    bool? showEmbProviderFlow,
    String? embSelectedTemplateId,
    String? embProviderName,
    String? embApiKeyInput,
    Object? embCreatedPresetId = _sentinel,
    List<ModelInfo>? embFetchedModels,
    Object? embSetupError = _sentinel,
    bool? embIsSettingUp,
    String? embManualModelId,
    WizardRulesPath? rulesPath,
    WizardRulesStage? rulesStage,
    Object? selectedRulesTemplateId = _sentinel,
    Object? rulesGenreId = _sentinel,
    String? rulesGenreCustom,
    Object? rulesStyleId = _sentinel,
    String? rulesStyleCustom,
    Object? rulesPerson = _sentinel,
    bool? rulesCharacterInitEnabled,
    WizardCharacterInitMode? rulesCharacterInitMode,
    String? rulesCharacterDescription,
    Object? rulesCharacterCardId = _sentinel,
    String? rulesCharacterCardName,
    Object? rulesPreviewText = _sentinel,
    bool? rulesPreviewGenerated,
    bool? rulesGenFallback,
    String? rulesEditDraft,
    Object? confirmedRules = _sentinel,
    bool? saveRulesTemplate,
  }) {
    return DirectorWizardState(
      currentStep: currentStep ?? this.currentStep,
      modelBranch: modelBranch ?? this.modelBranch,
      selectedTemplateId: selectedTemplateId ?? this.selectedTemplateId,
      providerName: providerName ?? this.providerName,
      apiKeyInput: apiKeyInput ?? this.apiKeyInput,
      createdPresetId: createdPresetId == _sentinel
          ? this.createdPresetId
          : createdPresetId as String?,
      fetchedModels: fetchedModels ?? this.fetchedModels,
      providerSetupError: providerSetupError == _sentinel
          ? this.providerSetupError
          : providerSetupError as String?,
      isSettingUpProvider: isSettingUpProvider ?? this.isSettingUpProvider,
      manualModelId: manualModelId ?? this.manualModelId,
      gmPresetId:
          gmPresetId == _sentinel ? this.gmPresetId : gmPresetId as String?,
      gmModelId: gmModelId == _sentinel ? this.gmModelId : gmModelId as String?,
      isTestingConnection: isTestingConnection ?? this.isTestingConnection,
      testResult:
          testResult == _sentinel ? this.testResult : testResult as String?,
      shouldWriteGlobalDefaults:
          shouldWriteGlobalDefaults ?? this.shouldWriteGlobalDefaults,
      embeddingStatus: embeddingStatus ?? this.embeddingStatus,
      currentEmbeddingPresetId:
          currentEmbeddingPresetId ?? this.currentEmbeddingPresetId,
      currentEmbeddingModelId:
          currentEmbeddingModelId ?? this.currentEmbeddingModelId,
      embeddingChoice: embeddingChoice ?? this.embeddingChoice,
      selectedEmbeddingPresetId: selectedEmbeddingPresetId == _sentinel
          ? this.selectedEmbeddingPresetId
          : selectedEmbeddingPresetId as String?,
      selectedEmbeddingModelId: selectedEmbeddingModelId == _sentinel
          ? this.selectedEmbeddingModelId
          : selectedEmbeddingModelId as String?,
      showEmbProviderFlow: showEmbProviderFlow ?? this.showEmbProviderFlow,
      embSelectedTemplateId:
          embSelectedTemplateId ?? this.embSelectedTemplateId,
      embProviderName: embProviderName ?? this.embProviderName,
      embApiKeyInput: embApiKeyInput ?? this.embApiKeyInput,
      embCreatedPresetId: embCreatedPresetId == _sentinel
          ? this.embCreatedPresetId
          : embCreatedPresetId as String?,
      embFetchedModels: embFetchedModels ?? this.embFetchedModels,
      embSetupError: embSetupError == _sentinel
          ? this.embSetupError
          : embSetupError as String?,
      embIsSettingUp: embIsSettingUp ?? this.embIsSettingUp,
      embManualModelId: embManualModelId ?? this.embManualModelId,
      rulesPath: rulesPath ?? this.rulesPath,
      rulesStage: rulesStage ?? this.rulesStage,
      selectedRulesTemplateId: selectedRulesTemplateId == _sentinel
          ? this.selectedRulesTemplateId
          : selectedRulesTemplateId as String?,
      rulesGenreId: rulesGenreId == _sentinel
          ? this.rulesGenreId
          : rulesGenreId as String?,
      rulesGenreCustom: rulesGenreCustom ?? this.rulesGenreCustom,
      rulesStyleId: rulesStyleId == _sentinel
          ? this.rulesStyleId
          : rulesStyleId as String?,
      rulesStyleCustom: rulesStyleCustom ?? this.rulesStyleCustom,
      rulesPerson: rulesPerson == _sentinel
          ? this.rulesPerson
          : rulesPerson as WorldPerson?,
      rulesCharacterInitEnabled:
          rulesCharacterInitEnabled ?? this.rulesCharacterInitEnabled,
      rulesCharacterInitMode:
          rulesCharacterInitMode ?? this.rulesCharacterInitMode,
      rulesCharacterDescription:
          rulesCharacterDescription ?? this.rulesCharacterDescription,
      rulesCharacterCardId: rulesCharacterCardId == _sentinel
          ? this.rulesCharacterCardId
          : rulesCharacterCardId as String?,
      rulesCharacterCardName:
          rulesCharacterCardName ?? this.rulesCharacterCardName,
      rulesPreviewText: rulesPreviewText == _sentinel
          ? this.rulesPreviewText
          : rulesPreviewText as String?,
      rulesPreviewGenerated:
          rulesPreviewGenerated ?? this.rulesPreviewGenerated,
      rulesGenFallback: rulesGenFallback ?? this.rulesGenFallback,
      rulesEditDraft: rulesEditDraft ?? this.rulesEditDraft,
      confirmedRules: confirmedRules == _sentinel
          ? this.confirmedRules
          : confirmedRules as String?,
      saveRulesTemplate: saveRulesTemplate ?? this.saveRulesTemplate,
    );
  }

  static const _sentinel = Object();
}

/// 向导控制器：步进导航 + 模型步两分支状态机。
class DirectorWizardController extends StateNotifier<DirectorWizardState> {
  DirectorWizardController({SettingsNotifier? settings})
      : _settings = settings,
        super(const DirectorWizardState(currentStep: 0));

  final SettingsNotifier? _settings;

  SettingsNotifier get _requireSettings {
    final settings = _settings;
    if (settings == null) {
      throw StateError('DirectorWizardController requires SettingsNotifier');
    }
    return settings;
  }

  // ── 步进 ────────────────────────────────────────────────────────

  bool get _canNext => state.currentStep < DirectorWizardState.totalSteps - 1;

  void nextStep() {
    if (_canNext) {
      state = state.copyWith(currentStep: state.currentStep + 1);
    }
  }

  void prevStep() {
    if (state.currentStep > 0) {
      state = state.copyWith(currentStep: state.currentStep - 1);
    }
  }

  /// 直达指定步（越界忽略）；PageView 滑动同步步号用。
  void goToStep(int index) {
    if (index < 0 || index >= DirectorWizardState.totalSteps) return;
    if (index == state.currentStep) return;
    // 滑动越步守卫：模型步未就绪不允许滑入后续步
    if (index > 0 && !state.isModelReady) return;
    state = state.copyWith(currentStep: index);
  }

  /// 重置回全新状态。
  void reset() {
    state = const DirectorWizardState(currentStep: 0);
  }

  // ── 模型步 ──────────────────────────────────────────────────────

  static const _defaultTemplateId = 'tpl-deepseek';
  static const _defaultTemplateName = 'DeepSeek';

  /// 进入模型步：按是否存在任一带 Key 供应商定分支（判定一次，中途不
  /// 翻转——未配置分支创建供应商后 apiKeyStatus 会变真，但分支语义固定）。
  void enterModelStep({required bool anyKeyedPreset}) {
    if (state.modelBranch != WizardModelBranch.undetermined) return;
    if (anyKeyedPreset) {
      state = state.copyWith(modelBranch: WizardModelBranch.configured);
    } else {
      state = state.copyWith(
        modelBranch: WizardModelBranch.unconfigured,
        selectedTemplateId: _defaultTemplateId,
        providerName: _defaultTemplateName,
        shouldWriteGlobalDefaults: true,
      );
    }
  }

  /// 已配置分支空态的出口：切到供应商接入流（视同未配置路径，完成时写全局）。
  void switchToProviderSetup() {
    state = state.copyWith(
      modelBranch: WizardModelBranch.unconfigured,
      selectedTemplateId: _defaultTemplateId,
      providerName: _defaultTemplateName,
      shouldWriteGlobalDefaults: true,
    );
  }

  /// 选中供应商模板（名字预填模板显示名）。
  void selectTemplate({
    required String templateId,
    required String displayName,
  }) {
    state = state.copyWith(
      selectedTemplateId: templateId,
      providerName: displayName,
    );
  }

  /// 选中模板的显示名兜底（switchToProviderSetup 时模板可能未选）。
  static String providerNameOf(String templateId) =>
      templateId == _defaultTemplateId ? _defaultTemplateName : '';

  void setProviderName(String name) {
    state = state.copyWith(providerName: name);
  }

  void setApiKeyInput(String key) {
    state = state.copyWith(apiKeyInput: key);
  }

  void setManualModelId(String modelId) {
    state = state.copyWith(manualModelId: modelId);
  }

  /// 未配置链路：模板建供应商 + 存 Key + 拉模型列表（供应商实体即时落库）。
  ///
  /// 返回 true = 供应商已创建（后续无论拉取成败都可继续）；false = 前置
  /// 校验失败或创建失败（未发起任何落库）。
  Future<bool> createAndFetchModels() async {
    if (state.selectedTemplateId.isEmpty ||
        state.providerName.trim().isEmpty ||
        state.apiKeyInput.trim().isEmpty) {
      return false;
    }
    final settings = _requireSettings;
    state = state.copyWith(isSettingUpProvider: true);
    try {
      final preset = await settings.createFromTemplate(
        templateId: state.selectedTemplateId,
        name: state.providerName.trim(),
      );
      if (preset == null) {
        state = state.copyWith(
          isSettingUpProvider: false,
          providerSetupError: 'create-failed',
        );
        return false;
      }
      await settings.saveApiKey(preset.presetId, state.apiKeyInput.trim());
      final models = await settings.fetchModels(preset.presetId);
      final fetchError = settings.state.fetchModelsError;
      state = state.copyWith(
        isSettingUpProvider: false,
        createdPresetId: preset.presetId,
        fetchedModels: models,
        providerSetupError: models.isEmpty ? (fetchError ?? 'empty') : null,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        isSettingUpProvider: false,
        providerSetupError: e.toString(),
      );
      return state.createdPresetId != null;
    }
  }

  /// 未配置链路：从拉取列表选中模型。
  void selectFetchedModel(String modelId) {
    final presetId = state.createdPresetId;
    if (presetId == null || presetId.isEmpty) return;
    state = state.copyWith(
      gmPresetId: presetId,
      gmModelId: modelId,
      testResult: null,
    );
  }

  /// 未配置链路：拉取失败的手填兜底——手填 ID 回写该供应商模型列表后选为 GM。
  Future<void> useManualModel() async {
    final presetId = state.createdPresetId;
    final modelId = state.manualModelId.trim();
    if (presetId == null || presetId.isEmpty || modelId.isEmpty) return;
    final manualModels = [
      ModelInfo(modelId: modelId, displayName: modelId),
    ];
    await _requireSettings.updatePresetModels(presetId, manualModels);
    state = state.copyWith(
      fetchedModels: manualModels,
      gmPresetId: presetId,
      gmModelId: modelId,
      testResult: null,
    );
  }

  /// 已配置链路：直选既有模型（只暂存，不写库）。
  void selectExistingModel({
    required String presetId,
    required String modelId,
  }) {
    state = state.copyWith(
      gmPresetId: presetId,
      gmModelId: modelId,
      testResult: null,
    );
  }

  /// 测试当前 GM 连接（结果原文入态，UI 映射人话）。
  Future<void> testSelectedConnection() async {
    final presetId = state.gmPresetId;
    if (presetId == null || presetId.isEmpty) return;
    final settings = _requireSettings;
    state = state.copyWith(isTestingConnection: true);
    await settings.testConnection(presetId);
    state = state.copyWith(
      isTestingConnection: false,
      testResult: settings.state.testResult,
    );
  }
  // ── 嵌入步 ──────────────────────────────────────────────────────

  /// 进入嵌入步：按全局 advanced.embedding_* 快照定现状（判定一次）。
  ///
  /// 已配置分支预选「就按现状继续」（默认高亮、下一步恒可用）；
  /// 未配置分支不预置默认（：强制显式选择，
  /// 消除「什么都不选也能下一步」的不透明）。
  void enterEmbeddingStep({
    required String currentPresetId,
    required String currentModelId,
  }) {
    if (state.embeddingStatus != WizardEmbeddingStatus.undetermined) return;
    final configured = currentPresetId.isNotEmpty && currentModelId.isNotEmpty;
    state = state.copyWith(
      embeddingStatus: configured
          ? WizardEmbeddingStatus.configured
          : WizardEmbeddingStatus.unconfigured,
      currentEmbeddingPresetId: currentPresetId,
      currentEmbeddingModelId: currentModelId,
      embeddingChoice:
          configured ? WizardEmbeddingChoice.keep : WizardEmbeddingChoice.none,
    );
  }

  /// 保留现状（已配置分支；页面写回入口快照两键）。
  void keepCurrentEmbedding() {
    state = state.copyWith(embeddingChoice: WizardEmbeddingChoice.keep);
  }

  /// 先跳过（未配置分支，零写入——FTS5 兜底不阻断）。
  void skipEmbedding() {
    state = state.copyWith(embeddingChoice: WizardEmbeddingChoice.skip);
  }

  /// 选定嵌入模型（页面随后写两键）。
  void chooseEmbeddingModel({
    required String presetId,
    required String modelId,
  }) {
    state = state.copyWith(
      embeddingChoice: WizardEmbeddingChoice.change,
      selectedEmbeddingPresetId: presetId,
      selectedEmbeddingModelId: modelId,
    );
  }

  /// 展开嵌入步的第二供应商接入流（默认推荐 DeepSeek）。
  void startEmbProviderFlow() {
    state = state.copyWith(
      showEmbProviderFlow: true,
      embSelectedTemplateId: _defaultTemplateId,
      embProviderName: _defaultTemplateName,
    );
  }

  void selectEmbTemplate({
    required String templateId,
    required String displayName,
  }) {
    state = state.copyWith(
      embSelectedTemplateId: templateId,
      embProviderName: displayName,
    );
  }

  void setEmbProviderName(String name) {
    state = state.copyWith(embProviderName: name);
  }

  void setEmbApiKeyInput(String key) {
    state = state.copyWith(embApiKeyInput: key);
  }

  void setEmbManualModelId(String modelId) {
    state = state.copyWith(embManualModelId: modelId);
  }

  /// 嵌入流创建链：模板建供应商 + 存 Key + 拉模型（与模型步同构、独立状态）。
  Future<bool> createEmbProviderAndFetch() async {
    if (state.embSelectedTemplateId.isEmpty ||
        state.embProviderName.trim().isEmpty ||
        state.embApiKeyInput.trim().isEmpty) {
      return false;
    }
    final settings = _requireSettings;
    state = state.copyWith(embIsSettingUp: true);
    try {
      final preset = await settings.createFromTemplate(
        templateId: state.embSelectedTemplateId,
        name: state.embProviderName.trim(),
      );
      if (preset == null) {
        state = state.copyWith(
          embIsSettingUp: false,
          embSetupError: 'create-failed',
        );
        return false;
      }
      await settings.saveApiKey(preset.presetId, state.embApiKeyInput.trim());
      final models = await settings.fetchModels(preset.presetId);
      state = state.copyWith(
        embIsSettingUp: false,
        embCreatedPresetId: preset.presetId,
        embFetchedModels: models,
        embSetupError: models.isEmpty ? 'empty' : null,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        embIsSettingUp: false,
        embSetupError: e.toString(),
      );
      return state.embCreatedPresetId != null;
    }
  }

  /// 从拉取列表选嵌入模型。
  void selectEmbModel(String modelId) {
    final presetId = state.embCreatedPresetId;
    if (presetId == null || presetId.isEmpty) return;
    chooseEmbeddingModel(presetId: presetId, modelId: modelId);
  }

  /// 嵌入流手填兜底——自动标记 embedding 类型回写（头号坑的向导代填）。
  Future<void> useEmbManualModel() async {
    final presetId = state.embCreatedPresetId;
    final modelId = state.embManualModelId.trim();
    if (presetId == null || presetId.isEmpty || modelId.isEmpty) return;
    final manualModels = [
      ModelInfo(modelId: modelId, type: ModelType.embedding),
    ];
    await _requireSettings.updatePresetModels(presetId, manualModels);
    state = state.copyWith(embFetchedModels: manualModels);
    chooseEmbeddingModel(presetId: presetId, modelId: modelId);
  }
  // ── 项目规则步 ──────────────────────────────────────────────────

  /// 选择路径（路 A 模板 / 路 B 问卷）。
  void chooseRulesPath(WizardRulesPath path) {
    state = state.copyWith(
      rulesPath: path,
      rulesStage: WizardRulesStage.answering,
    );
  }

  /// 路 A 入口：进入模板列表（答题阶段只渲染模板区）。
  void enterRulesTemplates() {
    state = state.copyWith(
      rulesPath: WizardRulesPath.template,
      rulesStage: WizardRulesStage.answering,
    );
  }

  /// 路 A：选中模板并进入预览（content 由页面装配传入）。
  void selectRulesTemplate({
    required String templateId,
    required String content,
  }) {
    state = state.copyWith(
      selectedRulesTemplateId: templateId,
      rulesPath: WizardRulesPath.template,
      rulesStage: WizardRulesStage.previewing,
      rulesPreviewText: content,
      rulesPreviewGenerated: false,
      rulesGenFallback: false,
    );
  }

  void setRulesGenre(String? id) {
    state = state.copyWith(rulesGenreId: id);
  }

  void setRulesGenreCustom(String v) {
    state = state.copyWith(rulesGenreCustom: v);
  }

  void setRulesStyle(String? id) {
    state = state.copyWith(rulesStyleId: id);
  }

  void setRulesStyleCustom(String v) {
    state = state.copyWith(rulesStyleCustom: v);
  }

  void setRulesPerson(WorldPerson? person) {
    state = state.copyWith(rulesPerson: person);
  }

  // ── 初始化你的角色（问卷路开关；答案与三题同寿命，回退不清） ──────

  void setRulesCharacterInitEnabled({required bool enabled}) {
    state = state.copyWith(rulesCharacterInitEnabled: enabled);
  }

  void setRulesCharacterInitMode(WizardCharacterInitMode mode) {
    state = state.copyWith(rulesCharacterInitMode: mode);
  }

  void setRulesCharacterDescription(String v) {
    state = state.copyWith(rulesCharacterDescription: v);
  }

  void selectRulesCharacterCard({required String id, required String name}) {
    state =
        state.copyWith(rulesCharacterCardId: id, rulesCharacterCardName: name);
  }

  void setSaveRulesTemplate({required bool value}) {
    state = state.copyWith(saveRulesTemplate: value);
  }

  /// 本地拼装结果入预览（零调用路径）。
  void showRulesAssembled(String text) {
    state = state.copyWith(
      rulesStage: WizardRulesStage.previewing,
      rulesPreviewText: text,
      rulesPreviewGenerated: false,
      rulesGenFallback: false,
    );
  }

  /// 生成结果入预览（[fallback]=true 表示模型失败已回退拼装文本）。
  void showRulesGenerated(String text, {bool fallback = false}) {
    state = state.copyWith(
      rulesStage: WizardRulesStage.previewing,
      rulesPreviewText: text,
      rulesPreviewGenerated: !fallback,
      rulesGenFallback: fallback,
    );
  }

  /// 「让模型替你写」→ 确认页（未发起任何调用；答案保留）。
  void enterRulesConfirming() {
    state = state.copyWith(rulesStage: WizardRulesStage.confirming);
  }

  /// 确认页点「开始写」→ 生成中隔离态（此后页面才真正调起模型）。
  void startRulesGeneration() {
    if (state.rulesStage != WizardRulesStage.confirming) return;
    state = state.copyWith(
      rulesStage: WizardRulesStage.generating,
      rulesGenFallback: false,
    );
  }

  /// 生成中「停止生成」（经页面成本确认弹窗）→ 回确认页。
  /// 在途请求的结果由页面按阶段丢弃（取消后到达不回写预览）。
  void cancelRulesGeneration() {
    if (state.rulesStage != WizardRulesStage.generating) return;
    state = state.copyWith(rulesStage: WizardRulesStage.confirming);
  }

  /// 答题页/模板列表返回分叉页（答案保留、预览与已确认产物清除）。
  void backToRulesChoosing() {
    state = state.copyWith(
      rulesStage: WizardRulesStage.choosing,
      rulesPreviewText: null,
      rulesPreviewGenerated: false,
      rulesGenFallback: false,
      confirmedRules: null,
    );
  }

  /// 拒绝回退：回答题页（答案保留，预览清除——用户明确不要才清除产物，
  /// 回退即「不要这个」）。
  void backToRulesAnswering() {
    state = state.copyWith(
      rulesStage: WizardRulesStage.answering,
      rulesPreviewText: null,
      rulesPreviewGenerated: false,
      rulesGenFallback: false,
      confirmedRules: null,
    );
  }

  /// 进入自行编辑（草稿预填当前预览文本）。
  void beginRulesEditing() {
    state = state.copyWith(
      rulesStage: WizardRulesStage.editing,
      rulesEditDraft: state.rulesPreviewText ?? '',
    );
  }

  void updateRulesEditDraft(String v) {
    state = state.copyWith(rulesEditDraft: v);
  }

  /// 确认编辑：草稿成为预览文本。
  void confirmRulesEdit() {
    state = state.copyWith(
      rulesStage: WizardRulesStage.previewing,
      rulesPreviewText: state.rulesEditDraft,
      rulesPreviewGenerated: false,
    );
  }

  /// 就用这个：预览文本成为确认产物。
  void confirmRulesUse() {
    final text = state.rulesPreviewText;
    if (text == null || text.isEmpty) return;
    state = state.copyWith(confirmedRules: text);
  }
}

/// 向导页内 provider：autoDispose——页面销毁即弃，重进即新。
final directorWizardProvider = StateNotifierProvider.autoDispose<
    DirectorWizardController, DirectorWizardState>(
  (ref) => DirectorWizardController(
    settings: ref.watch(settingsNotifierProvider.notifier),
  ),
);
