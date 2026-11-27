import 'dart:typed_data';

import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';

/// 经历类记忆仓储接口（v0.2 中级模式专用，DOC-05 §4.5）
///
/// 按 ISP 接口隔离原则，中级模式使用独立 Repository。
/// MemoryRepository（v0.3）将 implements 本接口并扩展 factual 类操作。
///
/// 混合检索算法整体在 ExperienceRepositoryImpl（Data 层）实现（S-11），
/// Controller/UseCase 只决定"何时检索"和"如何使用结果"。
abstract class ExperienceRepository {
  /// 两路混合检索经历类记忆（FTS5 + Vector）
  ///
  /// 算法（DOC-09A-1 §3.5-3.7， 扩展）：
  /// 1. FTS5 通道：MATCH 查询 → BM25 → min-max 归一化
  /// 2. Vector 通道：VectorEngine.batchSearch → (similarity+1)/2 归一化
  /// 3. 质量过滤：vec < vectorScoreThreshold 且 fts5 == 0 → 跳过
  /// 4. 合并：finalScore = fts5Score×fts5Weight + vectorScore×vectorWeight
  /// 5. 关键事件加权：importance >= keyEventThreshold → finalScore × keyEventBoost
  /// 6. 时间衰减：recencyBoost = 0.5^((currentTurn-turn)/halfLife)，
  ///    finalScore += recencyBoost × recencyWeight
  /// 7. importance 加权：finalScore += (importance/5) × importanceWeight
  /// 8. 降序取 topK
  ///
  /// [queryVector] 查询向量（由 Controller 调 EmbeddingService 生成）。
  /// 为 null 时跳过 Vector 通道（如向量化失败降级、或无可用 embedding 模型）。
  /// 关键词向量化职责在 Controller（网络调用不属 Repository 纯数据存取）。
  ///
  ///  新增的可选参数（默认值 0/null = 不启用）：
  /// - [recencyWeight]：时间衰减权重，0 禁用
  /// - [importanceWeight]：importance 加权权重，0 禁用
  /// - [recencyHalfLife]：半衰期轮次（与 recencyWeight 配合）
  /// - [vectorScoreThreshold]：质量过滤阈值，0 禁用
  /// - [currentTurnNumber]：当前轮次号（recencyBoost 计算用，null 禁用 recency）
  ///
  /// 异常: QueryException (E301)
  Future<List<ScoredMemory>> searchExperiences({
    required String sessionId,
    required String query,
    required Float32List? queryVector,
    required int topK,
    required double fts5Weight,
    required double vectorWeight,
    required int keyEventThreshold,
    required double keyEventBoost,
    required double normalizationEpsilon,
    double recencyWeight = 0.0,
    double importanceWeight = 0.0,
    int recencyHalfLife = 20,
    double vectorScoreThreshold = 0.0,
    int? currentTurnNumber,
  });

  /// 5 路并行检索（v0.2.2 架构调整）
  ///
  /// 与记忆库 5 类关键词对齐（DOC-09A-1 §3.5 修订）：
  /// - [fts5Queries]：3 路 FTS5 查询（characters/items/locations 各一个 query 字符串）
  /// - [vectorQueries]：2 路 Vector 查询（actions/plots 各一个，含 query 文本和向量）
  ///
  /// 5 路用 Future.wait 并行执行，归并打分后返回 topK。
  /// - 某路 query 为空（或 vector 为 null）时自动跳过该路。
  /// - 任一通道失败自动降级（该路返回空结果，不阻塞其他路）。
  /// - 同一 memoryId 多路命中时取各路最高分归并。
  /// - 归并打分公式与 [searchExperiences] 完全一致（fts5×weight + vec×weight
  ///   + 关键事件加权 + recency + importance）。
  ///
  /// 质量阈值（absoluteThreshold / relativeThreshold）由 Controller 层过滤，
  /// 本方法只做 [vectorScoreThreshold] 单路质量过滤（与 [searchExperiences] 一致）。
  ///
  /// 异常: QueryException (E301)
  Future<List<ScoredMemory>> searchExperiencesMultiChannel({
    required String sessionId,
    required List<String> fts5Queries,
    required List<({String query, Float32List? vector})> vectorQueries,
    required int topK,
    required double fts5Weight,
    required double vectorWeight,
    required int keyEventThreshold,
    required double keyEventBoost,
    required double normalizationEpsilon,
    double recencyWeight = 0.0,
    double importanceWeight = 0.0,
    int recencyHalfLife = 20,
    double vectorScoreThreshold = 0.0,
    int? currentTurnNumber,
  });

  /// 主表子串检索（关键词通道的可达性兜底）
  ///
  /// 与 [searchExperiencesMultiChannel] 的分工：后者只覆盖有 FTS 行
  ///（importance ≥ importanceStorageThreshold）或有向量的记忆；低重要性、
  /// 未向量化、未建索引的记忆对它完全不存在。本方法直接扫主表 7 个内容列
  /// 与 tags，**不依赖任何索引**，保证「记忆库里看得见的记忆一定能被
  /// 关键词召回」。
  ///
  /// [terms] 已切分的词元（多词 OR）；空列表返回空。按轮次倒序取前 [limit]。
  /// [includeArchived] = true 时含已归档记忆。
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  });

  /// 追加经历类记忆（在 drift transaction 内调用，保证原子性）
  ///
  /// 返回持久化后的 ExperientialMemory（含回填的 memoryId UUID）。
  ///
  /// 5W1E 字段（v0.2 Phase C 方案二，2026-07-19 新增）：
  /// - [summary]：向后兼容字段，可为 null（新方案以 5W1E 为主载体）
  /// - [when]/[where]/[who]/[what]/[significance]/[extra]：5W1E 6 字段，全 nullable
  /// - 旧调用点（不传新字段）兼容；新调用点（持久化 EventSummary）应传递全部 6 字段
  ///
  /// [indexForRetrieval] = false 时不建 FTS 行（importance 低于存储门槛的
  /// 低价值记忆，由合并流程后续处理）。2026-09-09 审查：索引维护下沉到
  /// 本方法（单一写入口）——此前由调用方成对调用 [insertFtsIndex]，记忆
  /// 查看器手动新增就漏了这一步，导致手工记忆永远搜不到。
  ///
  /// [source]（v51）：'auto'=轮管线产物（默认）/
  /// 'manual'=记忆库手动新增——manual 行不参与 deleteExperienceByTurns
  /// 的按 turn 窗清理（重生成/删除本轮不得吞删用户手写记忆）。
  ///
  /// 异常: QueryException (E301)
  Future<ExperientialMemory> appendExperience({
    required String sessionId,
    required String? summary,
    required int importance,
    required List<String> tags,
    required int turnNumber,
    String? narrativeTime,
    String? narrativePeriod,
    String? when,
    String? where,
    String? who,
    String? what,
    String? significance,
    String? extra,
    bool indexForRetrieval = true,
    String source = 'auto',
    bool hasVerifiedSourceTurn = false,
  });

  /// 获取最近的经历类记忆（按 turn_number 降序，取 limit 条）
  Future<List<ExperientialMemory>> getRecentExperiences(
    String sessionId, {
    required int limit,
    bool includeArchived = false,
  });

  /// 获取未建 FTS5 索引的经历类记忆（新增）
  ///
  /// 返回存在于 `experiential_memories` 但不在 `memories_fts` 中的记忆，
  /// 即 importance < `RetrievalConfig.importanceStorageThreshold` 的低重要性记忆
  /// （持久化时跳过了 FTS5 索引建立）。
  ///
  /// 供 `MemoryConsolidator` 批量提炼使用：将这些未索引记忆合并为高重要性记忆后
  /// 建索引，使后续轮次可检索到合并后的关键剧情。
  ///
  /// 按 turn_number 升序返回（时间顺序，便于 LLM 理解剧情流）。
  /// 仅返回未归档（is_archived=false）的记忆。
  ///
  /// 异常: QueryException (E301)
  Future<List<ExperientialMemory>> getUnindexedExperiences(
    String sessionId, {
    required int limit,
  });

  /// 按 memoryId 列表批量删除经历类记忆（新增）
  ///
  /// 供 `MemoryConsolidator` 合并完成后删除原始未索引记忆使用，避免下次触发时
  /// 重复处理已合并的记忆。
  ///
  /// 同事务删除 `experiential_memories` 行 + `memories_fts` 索引行
  /// （FTS5 删除对未索引记忆为空操作，但保留以兼容"原记忆曾被索引"的边界场景）。
  ///
  /// **不开自身事务**，供持久化服务在外层 drift transaction 内调用以保证原子性。
  ///
  /// 异常: QueryException (E301)
  Future<void> deleteExperiencesByIds({
    required String sessionId,
    required List<String> memoryIds,
  });

  /// 更新记忆的 embedding 向量（在 drift transaction 内调用）
  ///
  /// 写入 experiential_memories.embedding BLOB（Float32List 小端字节序），
  /// 并同步维护 embedding_dimensions（2026-09-09：维度随向量落库，
  /// 换嵌入模型后的陈旧行才可被统计与重建）。
  /// 异常: ModelNotFoundException (E007), QueryException (E301)
  Future<void> updateEmbedding(String memoryId, Float32List embedding);

  /// 显式插入 FTS5 索引行（在 drift transaction 内调用，替代触发器）
  ///
  /// 5W1E 字段（v0.2 Phase C 方案二，2026-07-19 新增）：
  /// - FTS5 索引扩展到所有内容字段（summary + when + where + who + what + significance + extra）
  /// - 所有字段 nullable：null 或空字符串时插入空字符串到 FTS5（避免 NULL 影响 BM25）
  /// - 旧调用点（只传 summary）兼容：其他字段默认 null → 插入空字符串
  ///
  /// 异常: QueryException (E301)
  Future<void> insertFtsIndex({
    required String memoryId,
    required String? summary,
    required String sessionId,
    String? when,
    String? where,
    String? who,
    String? what,
    String? significance,
    String? extra,
  });

  /// 删除会话全部经历类记忆（含 FTS5 索引）
  ///
  /// 异常: QueryException (E301)
  Future<void> deleteAllExperiences(String sessionId);

  /// 删除会话内 turn_number >= [fromTurnNumber] 的经历记忆（含 FTS5 索引）
  ///
  ///  简化 Fork（覆盖式重写）专用：重生/编辑重发/删除整轮时，
  /// 清理目标轮次及下游所有事件摘要，避免记忆串戏。
  ///
  /// **不开自身事务**，供中级模式持久化服务（StoryPersistenceService）
  /// 在外层 drift transaction 内调用以保证原子性（与 [appendExperience]/
  /// [insertFtsIndex] 同模式）。本方法不调用 [deleteAllExperiences]（后者
  /// 开自身事务）。
  ///
  /// 异常: QueryException (E301)
  Future<void> deleteExperienceByTurns({
    required String sessionId,
    required int fromTurnNumber,
  });

  /// 删除会话内最新一条压缩触发的宏摘要记忆（含 FTS5 索引）
  ///
  /// 撤销压缩专用：undoCompaction 事务内调用，回剥最新
  /// 压缩点时同步清除其落库的宏摘要。定位口径：(sessionId,
  /// memoryLevel=macro, macroTriggerReason=compaction) 中 turn_number
  /// 最大的一条。禁止用 [deleteExperienceByTurns] 按轮范围删——会误伤
  /// 压缩点之后轮次的记忆。
  ///
  /// **不开自身事务**，供外层 drift transaction 调用（与
  /// [deleteExperienceByTurns] 同模式）。无匹配记忆时返回 false（幂等）。
  ///
  /// 异常: QueryException (E301)
  Future<bool> deleteLatestCompactionMacroMemory({required String sessionId});

  // ─── 多粒度记忆（DOC-10 v1.1）──────────────────────────────────────────

  /// 追加宏摘要记忆（在 drift transaction 内调用，保证原子性）
  ///
  /// 与 [appendExperience] 的差异：
  /// - memoryLevel = macro
  /// - parentEventIds 关联聚类的微摘要 memoryId 列表
  /// - macroTriggerReason 记录触发原因（event_end / round_limit）
  ///
  /// 宏摘要始终建 FTS5 索引 + 向量化（高信息密度，不受 micro 的
  /// importanceStorageThreshold 门槛限制）。索引写入与 [appendExperience]
  /// 同口径收口在本方法内（2026-09-09 审查：单一写入口）。
  ///
  /// 异常: QueryException (E301)
  Future<ExperientialMemory> appendMacroExperience({
    required String sessionId,
    required String summary,
    required int importance,
    required List<String> tags,
    required int turnNumber,
    required List<String> parentEventIds,
    required MacroTriggerReason triggerReason,
    bool indexForRetrieval = true,
  });

  /// 获取会话内最近一条宏摘要的轮次号
  ///
  /// 用于宏摘要触发判断：当前轮次 - 上次宏摘要轮次 >= triggerRoundLimit 时
  /// 触发固定轮次兜底。返回 null 表示会话内从未生成过宏摘要（首次触发从第 1 轮扫描）。
  ///
  /// 异常: QueryException (E301)
  Future<int?> getLastMacroTurnNumber(String sessionId);

  /// 获取会话内全部经历类记忆（按 turnNumber 升序）
  ///
  /// 2026-07-22 新增：用于「记忆查看器」UI 浏览会话内全部记忆。
  /// 与 [getRecentExperiences] 的差异：不限制返回数量，含已归档记忆，
  /// 按 turnNumber 升序排列（时间正序，便于浏览）。
  ///
  /// 异常: QueryException (E301)
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  });

  /// 按 memoryId 获取单条经历类记忆
  ///
  /// 2026-07-22 新增：用于「记忆查看器」编辑/查看单条记忆。
  /// 不存在时返回 null。
  ///
  /// 异常: QueryException (E301)
  Future<ExperientialMemory?> getExperienceById(String memoryId);

  /// 更新单条经历类记忆的可编辑字段
  ///
  /// 2026-07-22 新增：用于「记忆查看器」手动编辑单条记忆。
  /// 仅支持修改内容字段（summary + 5W1E + importance + tags），
  /// 不修改 memoryId / sessionId / turnNumber / createdAt 等元数据。
  /// 同步更新 FTS5 索引（删除旧索引 + 插入新索引）。
  ///
  /// **开自身事务**（与 [deleteExperiencesByIds] 不同，本方法面向用户直接操作，
  /// 需要保证索引与主表一致性）。
  ///
  /// 异常: QueryException (E301)
  Future<void> updateExperience({
    required String memoryId,
    required String sessionId,
    String? summary,
    String? when,
    String? where,
    String? who,
    String? what,
    String? significance,
    String? extra,
    int? importance,
    List<String>? tags,
  });

  /// 归档/恢复经历记忆
  ///
  /// 归档后不进检索与注入（读侧过滤已在位），数据保留可随时恢复——
  /// v0.3 预留的「归档」死状态由此补上通路。开自身事务；带 session 谓词
  /// （与 deleteExperienceById 同口径，防跨会话越权）。
  ///
  /// 异常: ModelNotFoundException (E007), QueryException (E301)
  Future<void> setExperienceArchived(
    String memoryId, {
    required String sessionId,
    required bool archived,
  });

  /// 按 memoryId 删除单条经历类记忆（含 FTS5 索引 + embedding）
  ///
  /// 2026-07-22 新增：用于「记忆查看器」手动删除单条记忆。
  /// 与 [deleteExperiencesByIds] 的差异：面向用户直接操作，**开自身事务**
  /// 保证一致性，且不需要 sessionId 参数（按 memoryId 单条删除）。
  ///
  /// 异常: QueryException (E301)
  /// 删除单条经历记忆（记忆库浏览器手动删除）。
  ///
  /// [sessionId]：可选会话谓词——记忆库以会话为
  /// 边界展示，删除操作带上所属会话与兄弟方法 deleteExperiencesByIds
  /// 对齐，防止跨会话误删（memoryId 泄漏到其他会话视角时的纵深防御）。
  Future<void> deleteExperienceById(String memoryId, {String? sessionId});

  /// 获取会话内未生成 embedding 向量的经历类记忆
  ///
  /// 2026-07-21 新增：用于「重建向量索引」功能（会话级，手动触发补全向量）。
  /// 触发场景：
  /// - 用户之前未配置 embedding 模型时持久化的记忆（has_embedding=false）
  /// - 用户在 E104 错误后选择"临时降级继续"的本轮记忆（has_embedding=false）
  /// - embedding API 调用失败 + fallbackOnFailure=true 的记忆（has_embedding=false）
  ///
  /// 返回 has_embedding=false 且未归档的记忆，按 turn_number 升序
  /// （时间顺序，便于按事件流逐条补全向量）。
  ///
  /// [limit] 限制单次查询数量，避免会话积累大量未向量化记忆时一次性加载
  /// 占用过多内存（重建时 UI 显示进度条，逐批加载更友好）。默认 500。
  ///
  /// [minImportance] 2026-07-22 新增：最低重要性阈值，仅返回 importance >= 此值
  /// 的记忆。用于对齐持久化时的两级向量化策略——持久化时 importance <
  /// microVectorizeThreshold(默认4) 的记忆有意不建 embedding，重建时也不应
  /// 补齐这些记忆。null 表示不筛选（旧行为，仅用于向后兼容）。
  ///
  /// [expectedDimensions] 新增：非空时把「有向量但维度
  /// 与 [expectedDimensions] 不一致（含维度列为 NULL）」的行也计入——即换
  /// 嵌入模型后的陈旧向量。返回「需要（重）向量化」的并集，按 turn_number
  /// 升序；null 时仅返回 has_embedding=false 的行（旧行为）。
  /// [expectedDimensions] 取值见 [getLatestEmbeddingDimensions]。
  ///
  /// 异常: QueryException (E301)
  Future<List<ExperientialMemory>> getMemoriesWithoutEmbedding(
    String sessionId, {
    int limit = 500,
    int? minImportance,
    int? expectedDimensions,
  });

  /// 会话最近一次写入的 embedding 维度
  ///
  /// 按 created_at 降序取第一条 embedding_dimensions 非空的行；无任何带
  /// 维度的行（全新会话/从未向量化）返回 null。
  ///
  /// 语义：换嵌入模型后，**首个新维度写入**（新记忆向量化或重建）之前，
  /// 基准仍是旧维度（此时无从判定陈旧）；首个新维度落库后，其余旧维度
  /// 行即为陈旧。控制器/健康统计以本值为 expectedDimensions。
  ///
  /// 异常: QueryException (E301)
  Future<int?> getLatestEmbeddingDimensions(String sessionId);

  /// 获取指定轮次范围内的微摘要列表（用于宏摘要生成的输入）
  ///
  /// 返回 turnNumber ∈ [fromTurn, toTurn] 且 memoryLevel = 'micro' 的记忆，
  /// 按 turnNumber 升序排列（时间顺序，便于 LLM 理解剧情流）。
  /// 不含已归档记忆。
  ///
  /// 异常: QueryException (E301)
  Future<List<ExperientialMemory>> getMicroSummariesInRange({
    required String sessionId,
    required int fromTurn,
    required int toTurn,
  });
}
