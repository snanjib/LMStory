import 'package:drift/drift.dart';

/// intermediate_round_artifacts 表定义
///
/// 中级模式轮次中间产物持久化表（v0.2  修复）。
///
/// 用途：持久化每轮四步生成的生成内容/关键词/检索结果，使历史轮次的小窗
/// 在切换会话或重新进入时仍可见（修复"生成内容和检索过程消失"问题）。
///
/// 写入时机：与 experiential_memories 同事务写入（StoryPersistenceServiceImpl
/// 的 persistRound / persistRegeneratedRound 事务内追加 INSERT）。
/// 删除时机：deleteRoundAndDownstream 事务内追加 DELETE。
/// 读取时机：IntermediateChatController.loadHistory 批量加载，
/// 按 turn_number 关联到对应 assistant 消息。
///
/// 不污染 ChatMessage 字段（DOC-09A-1 §1.5 硬约束），独立表方案。
///
/// Schema 依据：DOC-09C §5、DOC-08 §5.5、DOC-02 §6.4
class IntermediateRoundArtifactsTable extends Table {
  @override
  String get tableName => 'intermediate_round_artifacts';

  /// 自增主键（内部使用，Repository 不暴露，B-4 硬约束）
  IntColumn get id => integer().autoIncrement()();

  /// 所属会话
  TextColumn get sessionId => text()();

  /// 轮次号（与 ChatMessage.turnNumber + experiential_memories.turnNumber 对齐）
  IntColumn get turnNumber => integer()();

  /// 生成全文（reviewing 阶段产出的最终生成内容，nullable：失败轮次可能无生成内容）
  TextColumn get generatedText => text().nullable()();

  /// 生成关键词 JSON 数组（generating 阶段产出的检索关键词，默认空数组）
  TextColumn get extractedKeywords =>
      text().withDefault(const Constant('[]'))();

  /// 检索到的记忆 JSON 数组（retrieved 阶段产出的 ExperientialMemory 列表序列化）
  TextColumn get retrievedMemories =>
      text().withDefault(const Constant('[]'))();

  /// 检索到的事实 JSON 数组（retrieved 阶段产出的 RetrievedFact 列表序列化，
  /// DOC-11 §6.1）
  TextColumn get retrievedFacts => text().withDefault(const Constant('[]'))();

  /// 最终回复正文（nullable：失败轮次可能无回复）
  ///
  /// 执行 reviewing 时保存审查结果；跳过 reviewing 时保存 generating 结果。
  /// 该字段独立于 [generatedText]，便于 UI 按 [reviewExecuted] 决定是否展示对比。
  TextColumn get replyText => text().nullable()();

  /// 事件摘要 JSON（summarizing 阶段产出，nullable：失败轮次可能无摘要）
  ///
  /// v0.2 四步重构新增：summarizing 独立步骤产出后序列化为 JSON 存储。
  TextColumn get eventSummary => text().nullable()();

  /// 事实层变更记录 JSON 数组（summarizing 产出、persisting 应用后的快照，
  /// schemaVersion 35 新增）
  ///
  /// 每条 FactsChangeRecord 携带实体名/类型/属性名 + 变更前/变更后，供
  /// 「事实层变更小窗」展示本轮事实层的新增/更新/追加/移除/别名/归档。
  /// 默认空数组（无变更或事实层禁用时）。
  TextColumn get factsChanges => text().withDefault(const Constant('[]'))();

  /// 导演模式 agent 工具步骤 JSON 数组（schemaVersion 40 新增）
  ///
  /// 按执行顺序持久化 AgentWorkStep 列表（toolName/callId/argsPreview/title/
  /// output/status/durationMs），使历史轮次的工具卡在重新进入时仍按
  /// opencode 时间线渲染。故事模式恒为空数组。
  ///
  /// 对话流计划（schemaVersion 45）起与 agent_timeline 兼容期双写；
  /// 评估移除不在本计划内。
  TextColumn get agentSteps => text().withDefault(const Constant('[]'))();

  /// 导演模式轮时间线 JSON 数组（对话流计划 §4.2，schemaVersion 45 新增）
  ///
  /// AgentTimelineBlock 列表序列化（kind/stepIndex/text/action 内嵌
  /// AgentWorkStep/startMs/endMs 相对轮起点毫秒）：思考/播报/动作三类块
  /// 按真实发生顺序交错。UI 优先按此渲染单一折叠组；旧数据缺列（null）
  /// 回退 agentSteps-only 渲染。故事模式恒为 null。
  TextColumn get agentTimeline => text().nullable()();

  /// 导演模式本轮工作摘要 JSON（schemaVersion 41 新增，体验重构）
  ///
  /// AgentWorkSummary 序列化（steps/totalTokens/durationMs），供历史轮次的
  /// L1 过程汇总行显示"幕后 N 步 · … · Ns"。含 LLM 等待时间的轮总时长
  /// 无法从 agent_steps 逐步耗时求和还原，故独立持久化。故事模式恒为 null。
  TextColumn get agentSummary => text().nullable()();

  /// 该轮结束时的剧情锚快照 JSON（schemaVersion 42 新增，体验重构卡片 C）
  ///
  /// 幕间 Recap 卡的数据源：每轮持久化"当前锚"（本轮更新值或继承值），
  /// 会话从未设锚时恒为 null（不显示 Recap 卡）。故事模式恒为 null。
  TextColumn get storyAnchor => text().nullable()();

  /// 本轮事实层原始 deltas JSON（FactsDelta 列表序列化）
  ///
  /// 供稿件变体快照复制：切换回旧变体时按该 deltas 在轮前状态上确定性
  /// 重放事实层（记忆是所选正文的派生物）。null = 本轮无事实变更或
  /// 旧数据（旧轮次切换时不重放，删除当前派生即止）。
  TextColumn get factsDeltas => text().nullable()();

  /// 本轮是否执行了 reviewing 阶段（v0.2.2 新增，schemaVersion 32）
  ///
  /// `true` = 执行了审查（generating → reviewing → summarizing）
  /// `false` = 跳过了审查（generating → summarizing，生成即最终）
  ///
  /// UI 据此判断 idle 时是否显示 GeneratePanel：
  /// - `true`：显示生成面板（生成与回复内容不同，用户可对比）
  /// - `false`：不显示生成面板（生成即最终，重复显示无意义）
  BoolColumn get reviewExecuted =>
      boolean().withDefault(const Constant(false))();

  /// 当前变体指针（schemaVersion 49 新增， 非破坏性重生成）
  ///
  /// nullable：null = 该轮单版本（从未重生成 / 旧数据）。
  /// 指向 message_variants.(session_id, turn_number, variant_index)；
  /// chat_messages.content 与本表过程列物化为指针所指变体（切换变体时
  /// 同事务改写，上下文组装读 content 即读当前变体）。
  IntColumn get currentVariantIndex => integer().nullable()();

  /// 创建时间（毫秒时间戳，与 failure_logs 风格一致）
  IntColumn get createdAt => integer()();
}
