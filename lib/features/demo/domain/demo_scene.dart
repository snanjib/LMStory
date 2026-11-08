/// 首次启动演示场景与流程步骤定义。
///
/// 场景 id 与步骤 id 是数据包、Spotlight 目标与流程状态机的共享词汇；
/// 新场景不复用本枚举（另立场景文件），本文件只服务
/// `first_launch_director`。
library;

/// 演示场景标识（数据包 manifest.sceneId 必须匹配）
const String demoSceneId = 'first_launch_director';

/// 演示流程步骤（推进条件见契约 §10.3）
enum DemoStepId {
  /// 主页：引导点击导演向导入口
  homeWizardEntry,

  /// 向导模型步：选择虚拟对话模型
  wizardModel,

  /// 向导嵌入步：选择虚拟嵌入模型
  wizardEmbedding,

  /// 向导规则步：选择内置异世界模板并确认
  wizardRules,

  /// 会话页：固定提示词已填入、锁定，等待用户亲自发送
  sessionInput,

  /// 回合进行中：等待业务提交完成
  roundRunning,

  /// 设置面板介绍
  settingsIntro,

  /// 记忆库查看本轮实体（引导点开设置面板内的记忆库按钮）
  memoryView,

  /// 记忆库内查看（真实进入记忆库后；返回即收尾）
  memoryInspect,

  /// 返回会话，收尾说明并触发交接
  backToSession,
}

/// Spotlight 语义目标 id（真实 widget 注册位见契约 §3.4）
abstract final class DemoTargetIds {
  static const String homeWizardCard = 'demo.home.wizardCard';
  static const String wizardGmRow = 'demo.wizard.gmRow';
  static const String wizardEmbeddingChoice = 'demo.wizard.embeddingChoice';
  static const String wizardTemplateList = 'demo.wizard.templateList';
  static const String wizardRulesConfirm = 'demo.wizard.rulesConfirm';
  static const String wizardNext = 'demo.wizard.next';
  static const String wizardEmbeddingModelItem =
      'demo.wizard.embeddingModelItem';
  static const String wizardTemplateItem = 'demo.wizard.templateItem';
  static const String sessionChatBody = 'demo.session.chatBody';
  static const String sessionInputArea = 'demo.session.inputArea';
  static const String sessionSettingsButton = 'demo.session.settingsButton';
  static const String sessionMemoryButton = 'demo.session.memoryButton';
  static const String memoryEpisodicTab = 'demo.memory.episodicTab';
  static const String memoryEpisodicItem = 'demo.memory.episodicItem';
  static const String memoryFactualTab = 'demo.memory.factualTab';
  static const String memoryFactualItem = 'demo.memory.factualItem';
  static const String memoryBackButton = 'demo.memory.backButton';
}

/// 虚拟供应商种子常量（DemoSeeder 与交接清理共用）
abstract final class DemoSeedIds {
  static const String presetId = 'demo-preset-v1';
  static const String chatModelId = 'demo-narrator-glm';
  static const String embeddingModelId = 'demo-embedding';
  static const String placeholderApiKey = 'demo-local-replay';
  static const String invalidBaseUrl = 'https://demo.invalid/v1';
}
