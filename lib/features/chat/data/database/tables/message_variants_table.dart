import 'package:drift/drift.dart';

/// message_variants 表定义（schemaVersion 49， 非破坏性重生成）
///
/// 每轮 assistant 稿件的**版本快照**：重生成/编辑重发不再物理销毁旧版，
/// 旧版先快照为本表一行，新版生成后在 persist 事务内追加为下一变体索引。
/// 当前指针存 intermediate_round_artifacts.current_variant_index；
/// chat_messages.content 始终物化为「当前指针变体」的内容（上下文组装、
/// 导出、复制会话等既有读路径零改动）。
///
/// 键：(session_id, turn_number, variant_index) 唯一——变体按轮次而非
/// message_id 键（重生成会换 assistant 消息行 id，message_id 键会让快照
/// 随旧行级联丢失）。
///
/// 兼容：纯增量新表，存量会话零迁移（变体行按需懒创建——首次重生成时
/// 旧版即快照为 variant 0，语义等同「存量消息 = variant 0」）。
class MessageVariantsTable extends Table {
  @override
  String get tableName => 'message_variants';

  /// 自增主键（内部使用，Repository 不暴露）
  IntColumn get id => integer().autoIncrement()();

  /// 所属会话
  TextColumn get sessionId => text()();

  /// 轮次号（与 chat_messages 推导轮次 + artifacts.turn_number 对齐）
  IntColumn get turnNumber => integer()();

  /// 变体序号（0 起，0 = 该轮最初版本）
  IntColumn get variantIndex => integer()();

  /// 该变体的稿件正文（assistant content 快照）
  TextColumn get content => text().nullable()();

  /// 该变体的思考合并串快照（nullable）
  TextColumn get thinkingContent => text().nullable()();

  /// 该变体的 agent 步骤 JSON 数组（幕后回放随变体切换）
  TextColumn get agentSteps => text().withDefault(const Constant('[]'))();

  /// 该变体的轮时间线 JSON 数组（nullable，同 artifacts.agent_timeline）
  TextColumn get agentTimeline => text().nullable()();

  /// 该变体的轮工作摘要 JSON（nullable）
  TextColumn get agentSummary => text().nullable()();

  /// 该变体结束时的剧情锚 JSON（nullable）
  TextColumn get storyAnchor => text().nullable()();

  /// 生成该变体时的用户指令（editAndResend 场景各变体来源指令可能不同；
  /// regenerate 变体与原始指令一致）
  TextColumn get sourceInput => text().nullable()();

  /// 该变体的事实层原始 deltas JSON（自 artifacts.facts_deltas 复制）
  ///
  /// 切换变体时事实层回滚到轮前后按此确定性重放（不调 LLM）；
  /// null = 该变体无派生资料（旧数据/无事实变更）。
  TextColumn get factsDeltas => text().nullable()();

  /// 该变体的经历记忆行快照 JSON（轮内 auto 行全列序列化，含向量）
  ///
  /// 切换变体时删除当前轮派生行后按此恢复（含 FTS/向量状态标记）；
  /// null = 该变体无经历记忆派生。
  TextColumn get experientialSnapshot => text().nullable()();

  /// 该变体的事件摘要 JSON（自 artifacts.event_summary 复制，随变体走）
  TextColumn get eventSummary => text().nullable()();

  /// 该变体的事实层变更展示记录 JSON（自 artifacts.facts_changes 复制）
  TextColumn get factsChanges => text().nullable()();

  /// 创建时间（毫秒时间戳）
  IntColumn get createdAt => integer()();
}
