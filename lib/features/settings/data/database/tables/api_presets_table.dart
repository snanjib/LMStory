import 'package:drift/drift.dart';

/// api_presets 表定义
/// 存储 API 预设（含内置供应商和自定义预设）
class ApiPresetsTable extends Table {
  @override
  String get tableName => 'api_presets';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get presetId => text().withLength(min: 1).unique()();
  TextColumn get name => text().withLength(min: 1)();
  // 允许空字符串：用户可先创建仅含名称的占位供应商，
  // 后续在详情页补全 URL（与 ApiPresetRepository.createPreset 设计一致）。
  // 旧版 `withLength(min: 1)` 在 Windows 端因 SQLite CHECK 约束导致保存失败且无 UI 反馈。
  TextColumn get baseUrl => text().withDefault(const Constant(''))();
  BoolColumn get isBuiltIn => boolean().withDefault(const Constant(false))();
  TextColumn get cachedModels =>
      text().withDefault(const Constant('[]'))(); // JSON array of ModelInfo

  /// LLM 协议类型（LlmProtocol.name，默认 'openaiCompatible'）
  ///
  /// 决定 LlmAdapterFactory 分发目标。详见 DOC-12 §3.3。
  /// 旧数据无此列时，drift withDefault 自动回退到 'openaiCompatible'。
  TextColumn get protocol =>
      text().withDefault(const Constant('openaiCompatible'))();

  /// 模板 ID（null = 完全自定义或内置本身；非 null = 基于模板创建的自定义实例）
  ///
  /// 用于"基于模板新建"功能支持多账号。详见 DOC-12 §3.3。
  TextColumn get templateId => text().nullable()();

  /// 协议特有参数（JSON 字符串，nullable）
  ///
  /// 存储 LlmRequest.providerOptions 的原始 JSON，由适配器层读取。
  /// 高级用户配置协议特有参数（如 OpenRouter extra_headers、
  /// Anthropic anthropic_beta、Gemini thinkingConfig）。
  /// null 或空串表示无配置，适配器走默认逻辑。
  /// 详见 DOC-12 §5.5 providerOptions 透传机制。
  TextColumn get providerOptions => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
