import 'package:drift/drift.dart';

/// experiential_memories 表定义
///
/// 存储经历类记忆（事件摘要 + embedding 向量），中级模式核心数据表。
/// 向量仅存 [embedding] BLOB 字段（后：纯 Dart 方案，无独立 memory_vectors 表）。
///
/// 多粒度记忆（DOC-10 v1.1）：
/// - memory_level 区分 micro/macro 两层记忆
/// - parent_event_ids 仅 macro 有效，关联聚类的微摘要 ID 列表
/// - macro_trigger_reason 仅 macro 有效，记录触发原因
///
/// 5W1E 字段（v0.2 Phase C 方案二，2026-07-19 新增）：
/// - when_text / where_text / who_text / what_text / significance / extra
/// - SQL 列名用 `*_text` 后缀避免与 SQL 保留字（when/where）冲突
/// - Dart 实体类（ExperientialMemory）字段名仍为 when/where/who/what/significance/extra，
///   在 Repository 映射层转换
/// - 所有字段 nullable，兼容旧数据（迁移前已存的记忆这 6 列为 NULL）
///
/// Schema 依据：DOC-09C §5、DOC-08 §5.1、DOC-02 §6.2、DOC-10 §3.1。
class ExperientialMemoriesTable extends Table {
  @override
  String get tableName => 'experiential_memories';

  /// 自增主键（内部使用，Repository 不暴露，B-4 硬约束）
  IntColumn get id => integer().autoIncrement()();

  /// 业务主键 UUID（对外暴露）
  TextColumn get memoryId => text().customConstraint('NOT NULL UNIQUE')();

  /// 所属会话
  TextColumn get sessionId => text()();

  /// 事件摘要文本（向后兼容字段，v0.2 Phase C 方案二降级）
  ///
  /// 方案二之后：LLM 改为输出 5W1E 6 字段，本字段可选。
  /// 旧数据仍以 summary 为主要载体；新数据 summary 可为空字符串。
  TextColumn get summary => text()();

  /// 5W1E：何时（叙事时间，非现实时间）
  ///
  /// SQL 列名 `when_text` 避免 SQL 保留字 `when` 冲突。
  /// 例：「次日清晨」「三年后」「战斗结束时」
  TextColumn get whenText => text().nullable()();

  /// 5W1E：何地
  ///
  /// SQL 列名 `where_text` 避免 SQL 保留字 `where` 冲突。
  /// 例：「森林深处」「王城广场」「船舱内」
  TextColumn get whereText => text().nullable()();

  /// 5W1E：何人（角色/主体）
  ///
  /// 例：「勇者独自」「勇者与公主」「风与海浪」
  TextColumn get whoText => text().nullable()();

  /// 5W1E：何事（动作/对话/变化/状态）
  ///
  /// 例：「斩杀了巨龙」「发现一封信」「雨持续下着」
  TextColumn get whatText => text().nullable()();

  /// 5W1E：为何重要（意义/影响/后果，Labov 评估模型）
  ///
  /// 例：「获得了关键道具」「改变了勇者的信念」
  TextColumn get significance => text().nullable()();

  /// 5W1E：额外（兜底字段，无法归入上述字段的补充信息）
  ///
  /// 例：「天气骤变，雷声大作」「叙述视角切换为第二人称」
  TextColumn get extra => text().nullable()();

  /// 重要性 1-5（默认 3）
  IntColumn get importance => integer().withDefault(const Constant(3))();

  /// 标签 JSON 数组（默认空数组）
  TextColumn get tags => text().withDefault(const Constant('[]'))();

  /// 轮次号（对应当前对话轮次）
  IntColumn get turnNumber => integer()();

  /// 叙事时间（v0.2 恒为 NULL，v0.3 启用）
  TextColumn get narrativeTime => text().nullable()();

  /// 叙事时段（v0.2 恒为 NULL，v0.3 启用）
  TextColumn get narrativePeriod => text().nullable()();

  /// embedding 向量 BLOB（Float32List 小端字节序；纯 Dart 方案单一数据源）
  BlobColumn get embedding => blob().nullable()();

  /// 是否有 embedding（false=无，true=有；检索时过滤）
  BoolColumn get hasEmbedding => boolean().withDefault(const Constant(false))();

  /// embedding 维度（Float32 元素个数 = LENGTH(blob)/4；，2026-09-09）
  ///
  /// 换嵌入模型后新旧维度不同，检索侧对维度不符的行**静默跳过**——本列让
  /// 陈旧向量可观测：以会话最近一次写入的维度为基准，其余不一致行计入
  /// 「与新模型不匹配」并可一键重建。NULL = 无向量或历史行待回填
  /// （迁移/导入后由 backfillEmbeddingDimensions 幂等补齐）。
  IntColumn get embeddingDimensions => integer().nullable()();

  /// 是否归档（非摘要事件归档后置 true）
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  /// 是否为归档摘要事件
  BoolColumn get isSummary => boolean().withDefault(const Constant(false))();

  /// 归档事件 ID 列表 JSON（is_summary=true 时使用）
  TextColumn get archivedEventIds => text().nullable()();

  /// 记忆层级（DOC-10 §3.1）：'micro' 每轮一条微摘要 / 'macro' 事件聚合宏摘要
  ///
  /// 默认 'micro'，兼容旧数据。macro 记录通过 [parentEventIds] 关联聚类的微摘要。
  TextColumn get memoryLevel => text().withDefault(const Constant('micro'))();

  /// 父事件 ID 列表（仅 macro 有效，DOC-10 §3.1）
  ///
  /// JSON 数组字符串，存储聚类的微摘要 memoryId 列表。
  /// micro 记录此字段为 NULL。
  TextColumn get parentEventIds => text().nullable()();

  /// 宏摘要触发原因（仅 macro 有效，DOC-10 §3.1）
  ///
  /// 'event_end'（LLM 判断事件结束）/ 'round_limit'（固定轮次兜底）。
  /// micro 记忆此字段为 NULL。
  TextColumn get macroTriggerReason => text().nullable()();

  /// 来源（v51）：'auto'=轮管线产物 / 'manual'=记忆库手动新增。
  ///
  /// deleteExperienceByTurns（重生成/删除本轮的按 turn 窗清理）只删
  /// 'auto' 行——用户手动写的记忆不随轮回滚静默消失。DEFAULT('auto')
  /// 对存量行无感；存量手动行不可追溯，按 auto 处理。
  TextColumn get source => text().withDefault(const Constant('auto'))();

  /// 创建时间
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
