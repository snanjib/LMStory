# LMStory 接口设计（5）：Memory 接口

> **状态：历史接口快照。** 当前契约以 `ExperienceRepository`、`FactualRepository` 及其实现为准；下文未来超集 `MemoryRepository` 不是已实现接口。

| 属性 | 值 |
|------|-----|
| 文档编号 | LMStory-DOC-05-5 |
| 版本 | v1.8 |
| 日期 | 2026-07-25 |
| 状态 | 审定（拆分自 DOC-05 v2.2） |
| 前置文档 | LMStory-DOC-01 ~ 04 |
| 配套文档 | LMStory-DOC-05-1 ~ 05-8（其他子文档） |

---

## 0. 文档定位

本文档是接口设计的第 5 部分，覆盖 §4 + §4.5（MemoryRepository v0.3 + ExperienceRepository v0.2 中级模式）。

> **拆分说明**：本文档原属 DOC-05 v2.2，因 05 行数严重超限（2841 行 > 500 行限制）拆分为 DOC-05-1 ~ DOC-05-8 共 8 个子文档。本文档保留原节号以保持交叉引用稳定。原 DOC-05 文件替换为索引页（指向各子文档）。

---

## 4. MemoryRepository（记忆管理，v0.3 Advanced 模式）

**所属模块**: Memory
**版本**: v0.3（factual 类操作 + 3 路 hybridSearch）；v0.2 中级模式使用子集接口 `ExperienceRepository`（见 §4.5）
**职责**: 事实类/经历类记忆的存储与检索（v0.3 完整接口，含 factual + experiential + 3 路 hybridSearch）
**接口定义位置**: `features/memory/domain/repositories/memory_repository.dart`

> **v0.2 / v0.3 关系说明**：v0.2 中级模式仅使用经历类记忆 + 2 路检索（FTS5+Vector），接口见 §4.5 `ExperienceRepository`。本节 `MemoryRepository` 为 v0.3 Advanced 模式的完整接口（factual + experiential + 3 路 hybridSearch + temporal），v0.3 启动时实现。`MemoryRepository` 在接口层面是 `ExperienceRepository` 的超集（扩展 factual 类操作和 temporal 通道）。

### 4.1 接口定义

```dart
abstract class MemoryRepository {
  // ─── 事实类记忆 ───

  /// Upsert 事实类记忆（key 存在则更新，不存在则插入）
  /// [updates] 批量更新列表
  /// value 为 "__deleted__" 时删除该记录
  /// 异常: QueryException (E301)
  Future<void> upsertFacts(
    String sessionId,
    List<FactualUpdate> updates,
  );

  /// 获取会话全部事实类记忆
  Future<List<FactualMemory>> getAllFacts(String sessionId);

  /// 按 category 获取事实类记忆
  Future<List<FactualMemory>> getFactsByCategory(
    String sessionId,
    String category,
  );

  /// 删除单条事实
  /// 异常: QueryException (E301)
  Future<void> deleteFact(String sessionId, String key);

  /// 删除会话全部事实
  /// 异常: QueryException (E301)
  Future<void> deleteAllFacts(String sessionId);

  // ─── 经历类记忆 ───

  /// 追加经历类记忆（无条件持久化，业务过滤由调用方负责）
  /// 返回持久化后的 ExperientialMemory（含回填的 memoryId）
  /// 异常: QueryException (E301)
  /// **命名说明**：v0.2 起统一为 `appendExperience`（与 §4.5 ExperienceRepository 对齐），
  /// 08 §7.1 / DOC-09A-2 §6.5 的 `appendExperience` 签名以本方法为权威基准。
  ///
  /// **V2.5（5W1E）**：
  /// - `summary` 降级为可选（`String?`），仅宏摘要（is_summary=true）使用
  /// - 单事件优先使用 5W1E 6 字段（when/where/who/what/significance/extra）
  /// - 5W1E 字段与 memories_fts 7 内容字段对齐，支持精细化检索
  ///
  /// **v0.2 叙事时间机制（2026-07-25 新增）**：
  /// - `narrativeTime` 参数从原 v0.3 启用提前到 v0.2 启用——由 summarizing 阶段
  ///   LLM 输出的 `EventSummary.narrativeTime` 传入，持久化到
  ///   `experiential_memories.narrative_time` 列。persist 成功后由控制器 upsert
  ///   到 `chat_sessions.current_narrative_time` 作为会话级状态。
  /// - `narrativePeriod` 仍为 v0.3 启用（中级模式恒 null）
  /// - 详见 DOC-08 §5.7、DOC-09A-2 §8.1
  Future<ExperientialMemory> appendExperience({
    required String sessionId,
    String? summary,  // V2.5 降级为可选（宏摘要使用，单事件优先用 5W1E）
    required int importance,
    required List<String> tags,
    required int turnNumber,
    String? narrativeTime,    // v0.2 启用（2026-07-25 叙事时间机制）：绝对叙事时间锚点（如"来公寓第三天"）
    String? narrativePeriod,  // v0.3 启用（中级模式恒 null）
    // ─── 5W1E（V2.5）───
    String? when,         // 何时（相对时间，如"次日清晨"）
    String? where,        // 何地
    String? who,          // 谁
    String? what,         // 发生什么
    String? significance, // 意义
    String? extra,        // 额外信息
  });

  /// 获取经历类记忆（按 turn_number 排序）
  /// [includeArchived] 是否包含已归档，默认 false
  Future<List<ExperientialMemory>> getEvents(
    String sessionId, {
    bool includeArchived = false,
  });

  /// 按 turn_number 范围获取经历类记忆
  Future<List<ExperientialMemory>> getEventsByTurnRange(
    String sessionId,
    int startTurn,
    int endTurn,
  );

  /// 按 narrative_period 获取经历类记忆
  Future<List<ExperientialMemory>> getEventsByPeriod(
    String sessionId,
    String narrativePeriod,
  );

  /// 按 memoryId 获取单条经历类记忆
  /// 异常: ModelNotFoundException (E007)
  Future<ExperientialMemory> getByMemoryId(String memoryId);

  /// 获取未归档经历类记忆数量
  Future<int> getActiveEventCount(String sessionId);

  /// 更新记忆的 embedding 向量
  /// 异常: ModelNotFoundException (E007), QueryException (E301)
  Future<void> updateEmbedding(String memoryId, Float32List embedding);

  // ─── 混合检索 ───

  /// 混合检索经历类记忆
  /// [query] 检索关键词（向量检索需要调用 Embedding API，可能产生额外延迟和 API 调用）
  /// [topK] 返回数量
  /// [weights] 三通道权重（fts5, vector, temporal）
  /// [keyEventImportance] 关键事件重要性阈值
  /// [keyEventBoostFactor] 关键事件加权系数
  /// [currentTurnNumber] 当前轮次（用于计算 recencyScore）
  /// [queryNarrativePeriod] 查询的叙事周期（用于计算 periodMatchScore）
  /// [scoreThreshold] 最低分数阈值，低于此值的结果被过滤
  /// 自动过滤 is_archived=true 的非摘要事件（is_summary=true 的归档摘要事件保留）
  /// 返回按 final_score 降序排列的结果
  /// 异常: QueryException (E301), EmbeddingRateLimitedException (E104)
  Future<List<ScoredMemory>> hybridSearch({
    required String sessionId,
    required String query,
    required int topK,
    required ({double fts5, double vector, double temporal}) weights,
    required int keyEventImportance,
    required double keyEventBoostFactor,
    required int currentTurnNumber,
    required String? queryNarrativePeriod,
    required double scoreThreshold,
  });

  // ─── 归档 ───

  /// 标记事件为已归档
  /// 异常: QueryException (E301)
  Future<void> archiveEvents(List<String> memoryIds);

  // ─── 清理 ───

  /// 删除会话全部记忆
  /// 异常: QueryException (E301)
  Future<void> deleteAllMemories(String sessionId);
}
```

> **v1.2 变更说明**：
> - `appendExperience`（v0.2 起由 `appendEvent` 重命名）移除 minImportance 过滤逻辑（业务规则由 UpdateWorldUseCase 负责），返回类型改为非空 `ExperientialMemory`
> - `getById(int dbId)` → `getByMemoryId(String memoryId)`，避免暴露数据库主键
> - `updateEmbedding(int dbId, ...)` → `updateEmbedding(String memoryId, ...)`
> - `archiveEvents(List<int> dbIds)` → `archiveEvents(List<String> memoryIds)`
> - `hybridSearch` 新增 `currentTurnNumber`、`queryNarrativePeriod`、`scoreThreshold` 参数
> - `hybridSearch` 注释补充向量检索 API 调用说明和 is_archived 过滤行为

### 4.2 检索结果类型

```dart
/// 带分数的检索结果
class ScoredMemory {
  final ExperientialMemory memory;
  final double fts5Score;
  final double vectorScore;
  final double temporalScore;
  final double finalScore;
  const ScoredMemory({
    required this.memory,
    required this.fts5Score,
    required this.vectorScore,
    required this.temporalScore,
    required this.finalScore,
  });
}
```

> **与 DOC-04 的差异**：DOC-04 Section 1.5 流程图返回 `List<ExperientialMemory>`，本接口返回 `List<ScoredMemory>`（包装了 ExperientialMemory + 各通道分数），信息更丰富。以本文档为准。

### 4.3 使用示例

```dart
// update_world 双写（UpdateWorldUseCase 内部）
final factualUpdates = StatePatchParser.parse(input.statePatch);

await appDatabase.transaction(() async {
  // 1. Upsert 事实类记忆
  await memoryRepo.upsertFacts(sessionId, factualUpdates);

  // 2. 追加经历类记忆（业务过滤已在调用方完成）
  if (input.importance >= minImportance) {
    final event = await memoryRepo.appendExperience(
      sessionId: sessionId,
      summary: input.eventSummary,
      importance: input.importance,
      tags: input.tags,
      turnNumber: currentTurn,
      narrativeTime: input.narrativeTime,
      narrativePeriod: extractNarrativePeriod(input.narrativeTime),
    );
    // 3. 事务外：异步入队 Embedding
    embeddingQueue.enqueue(event.memoryId);
  }
});

// 4. 事务外：发出领域事件
eventBus.emit(FactualMemoryChangeEvent(
  sessionId: sessionId,
  changedKeys: factualUpdates.map((u) => u.key).toList(),
));
```

---

## 4.5 ExperienceRepository（经历类记忆管理，v0.2 中级模式专用）

**所属模块**: Memory
**版本**: v0.2（中级模式）；v0.3 Advanced 模式使用 §4 `MemoryRepository`（超集，含 factual + 3 路 hybridSearch）
**职责**: 经历类记忆的存储、检索、向量化（中级模式四步生成流程专用）
**接口定义位置**: `features/memory/domain/repositories/experience_repository.dart`

> **接口拆分说明**：按接口隔离原则（ISP），v0.2 中级模式使用独立的 `ExperienceRepository`，仅暴露中级模式所需方法。`MemoryRepository`（§4）为 v0.3 超集。08 §7.1 / DOC-09A-2 §6.5 的接口签名以本节为权威基准。
>
> **与 MemoryRepository 的关系**：`MemoryRepository` 在 v0.3 实现时将 `implements ExperienceRepository` 并扩展 factual 类操作和 temporal 通道。v0.2 仅实现 `ExperienceRepository`，无空方法。
>
> **ExperienceEvent 说明**：08 §7.1 声明 `appendExperience(String, ExperienceEvent)`，其中 `ExperienceEvent` 作为参数对象。本节不引入 `ExperienceEvent` 实体——其字段（summary/importance/tags/turnNumber）与 DOC-05-2 §2.3 `EventSummary` 完全重叠，故统一为 `EventSummary`（LLM 输出结构）+ `appendExperience` 命名参数（持久化时由 Controller 从 EventSummary 提取传入）。避免重复实体定义。

### 4.5.1 接口定义

```dart
abstract class ExperienceRepository {
  // ─── 检索（2 路，中级模式专用）───

  /// 两路混合检索经历类记忆（FTS5 + Vector，无 temporal 通道）
  ///
  /// 算法（DOC-09A-1 §3.5-3.7）：
  /// 1. FTS5 通道：`memories_fts` 表 MATCH 查询，按 BM25 计算 fts5Score
  /// 2. Vector 通道：VectorEngine.batchSearch 纯 Dart 余弦相似度（从 experiential_memories.embedding BLOB 加载），similarity → vectorScore
  /// 3. 质量过滤：`vec < vectorScoreThreshold && fts5 == 0` → 跳过
  /// 4. 两路结果按 memory_id 合并，分数叠加：`finalScore = fts5Score × fts5Weight + vectorScore × vectorWeight`
  /// 5. 关键事件加权：`importance >= keyEventThreshold` 的事件 `finalScore × keyEventBoost`
  /// 6. 时间衰减：`recencyBoost = 0.5^((currentTurn-turn)/halfLife)`，`finalScore += recencyBoost × recencyWeight`
  /// 7. importance 加权：`finalScore += (importance/5) × importanceWeight`
  /// 8. 按 finalScore 降序取 topK
  ///
  /// 自动过滤 `is_archived=true` 的非摘要事件（`is_summary=true` 的归档摘要事件保留）。
  /// session 隔离：FTS5 直接 `WHERE session_id`，Vector 在加载 embedding BLOB 时按 `WHERE session_id` 过滤候选集（纯 Dart 内存计算，无需 JOIN）。
  ///
  /// [queryVector] 查询向量（由 Controller 调 EmbeddingService 生成）。
  /// 为 null 时跳过 Vector 通道（如向量化失败降级、或无可用 embedding 模型）。
  /// 关键词向量化职责在 Controller（网络调用不属 Repository 纯数据存取）。
  ///
  /// 可选参数（默认值 0/null = 不启用，向后兼容）：
  /// - [recencyWeight]：时间衰减权重，0 禁用
  /// - [importanceWeight]：importance 加权权重，0 禁用
  /// - [recencyHalfLife]：半衰期轮次（与 recencyWeight 配合）
  /// - [vectorScoreThreshold]：质量过滤阈值，0 禁用
  /// - [currentTurnNumber]：当前轮次号（recencyBoost 计算用，null 禁用 recency）
  ///
  /// 返回按 finalScore 降序排列的结果（含各通道分数，用于调试和展示）。
  /// 异常: QueryException (E301), EmbeddingRateLimitedException (E104, 向量查询 API 调用）
  ///
  /// **V2.5**：`RetrievalConfig.topK` 默认值由 5 调整为 3，
  /// 减少 LLM 上下文占用（5W1E 多字段检索精度提升，少量高质量结果优于多量结果）。
  /// 调用方仍可通过 RetrievalConfig 显式覆盖。
  Future<List<ScoredMemory>> searchExperiences({
    required String sessionId,
    required String query,
    required Float32List? queryVector,
    required int topK,  // 默认 3（RetrievalConfig.topK，V2.5由 5→3）
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

  // ─── 追加 ───

  /// 追加经历类记忆（无条件持久化，业务过滤由调用方负责）
  /// 在 drift transaction 内调用，与 insertFtsIndex + updateEmbedding 同事务保证原子性。
  /// 返回持久化后的 ExperientialMemory（含回填的 memoryId UUID）。
  /// 异常: QueryException (E301)
  ///
  /// **签名权威性**：08 §7.1 的 `appendExperience(String, ExperienceEvent)` 和
  /// DOC-09A-2 §6.5 的 `appendExperience(sessionId, summary, importance, tags, turnNumber)` 均以本方法为准对齐。
  ///
  /// **V2.5（5W1E）**：
  /// - `summary` 降级为可选（`String?`）：宏摘要（is_summary=true）继续使用 summary，
  ///   单事件优先使用 5W1E 6 字段
  /// - 新增 6 个 5W1E 命名参数（when/where/who/what/significance/extra），
  ///   与 `memories_fts` 表 7 内容字段对齐，支持 FTS5 多字段检索
  /// - 调用方由 Controller 从 EventSummary 提取 5W1E 字段传入
  Future<ExperientialMemory> appendExperience({
    required String sessionId,
    String? summary,  // V2.5 降级为可选（宏摘要使用，单事件优先用 5W1E）
    required int importance,
    required List<String> tags,
    required int turnNumber,
    String? narrativeTime,
    String? narrativePeriod,
    // ─── 5W1E（V2.5，与 memories_fts 7 内容字段对齐）───
    String? when,         // 何时
    String? where,        // 何地
    String? who,          // 谁
    String? what,         // 发生什么
    String? significance, // 意义
    String? extra,        // 额外信息
  });

  // ─── 读取 ───

  /// 获取最近的经历类记忆（按 turn_number 降序，取 limit 条）
  /// 用于上下文组装（DOC-09A-2 §4）和检索小窗详情展示。
  /// 自动过滤 is_archived=true（除非 includeArchived=true）。
  Future<List<ExperientialMemory>> getRecentExperiences(
    String sessionId, {
    required int limit,
    bool includeArchived = false,
  });

  // ─── 向量与索引同步（显式插入，同事务）───

  /// 更新记忆的 embedding 向量（命名统一：DOC-09A-2 §6.5 的 `saveEmbedding` 以本方法为准）
  /// 在 drift transaction 内调用，写入 `experiential_memories.embedding`（BLOB），保证一致性。
  /// v0.2 主方案：向量仅存 BLOB，检索时由 VectorEngine.batchSearch 加载计算，不再建独立向量表。
  /// 异常: ModelNotFoundException (E007), QueryException (E301)
  Future<void> updateEmbedding(String memoryId, Float32List embedding);

  /// 显式插入 FTS5 索引行（DOC-09A-2 §6.5 引用，本节正式定义）
  /// 在 drift transaction 内调用，与 appendExperience 同事务，替代触发器同步（DOC-02 §6.3）。
  /// 异常: QueryException (E301)
  ///
  /// **V2.5（5W1E）**：
  /// - `summary` 降级为可选（`String?`）：与 `appendExperience` 签名保持一致
  /// - 新增 6 个 5W1E 命名参数（when/where/who/what/significance/extra），
  ///   与 `memories_fts` 表 7 内容字段（summary + 5W1E + extra）一一对应
  /// - FTS5 索引内容字段对所有 7 列建立索引，支持多字段 MATCH 查询
  Future<void> insertFtsIndex({
    required String memoryId,
    String? summary,
    required String sessionId,
    // ─── 5W1E（V2.5，与 memories_fts 7 内容字段对齐）───
    String? when,
    String? where,
    String? who,
    String? what,
    String? significance,
    String? extra,
  });

  // ─── 清理 ───

  /// 删除会话全部经历类记忆（含 FTS5 索引和向量索引）
  /// 异常: QueryException (E301)
  Future<void> deleteAllExperiences(String sessionId);

  /// 删除指定轮次及下游的经历记忆 + FTS5 索引（简化 Fork）
  ///
  /// 用于重新生成/编辑重发/删除整轮场景（DOC-09A-1 §2.4-§2.6），
  /// 清理 turn_number >= [fromTurnNumber] 的经历记忆，避免记忆串戏。
  /// 仅删 `is_archived=0` 的事件（归档摘要记忆独立于轮次，不删）。
  ///
  /// **不开自身事务**，供 IntermediatePersistenceService 在外层 drift
  /// transaction 内调用以保证原子性（与 [appendExperience]/[insertFtsIndex]
  /// 同模式）。本方法不调用 [deleteAllExperiences]（后者开自身事务）。
  /// 异常: QueryException (E301)
  Future<void> deleteExperienceByTurns({
    required String sessionId,
    required int fromTurnNumber,
  });

  // ─── 重建向量索引（2026-07-21 新增）───

  /// 获取会话内未生成 embedding 向量的经历类记忆
  ///
  /// 用于「重建向量索引」功能（会话级，手动触发补全向量）。
  /// 触发场景：
  /// - 之前未配置 embedding 模型时持久化的记忆（has_embedding=false）
  /// - E104 错误后用户选择"临时降级继续"的本轮记忆（has_embedding=false）
  /// - embedding API 失败 + fallbackOnFailure=true 的旧记忆（has_embedding=false）
  ///
  /// 返回 `has_embedding=false` 且未归档的记忆，按 turn_number 升序
  /// （时间顺序，便于按事件流逐条补全向量）。
  ///
  /// [minImportance] 2026-07-22 新增：最低重要性阈值，仅返回 importance >= 此值
  /// 的记忆。用于对齐持久化时的两级向量化策略——持久化时 importance <
  /// microVectorizeThreshold(默认4) 的记忆有意不建 embedding，重建时也不应
  /// 补齐这些记忆。null 表示不筛选（仅用于向后兼容）。
  ///
  /// [limit] 限制单次查询数量，避免会话积累大量未向量化记忆时一次性加载
  /// 占用过多内存（重建时 UI 显示进度条，逐批加载更友好）。默认 500。
  ///
  /// 异常: QueryException (E301)
  Future<List<ExperientialMemory>> getMemoriesWithoutEmbedding(
    String sessionId, {
    int limit = 500,
  });

  // ─── 记忆查看器 CRUD（2026-07-22 新增，DOC-06B §6.18 / DOC-09B §7.8）───

  /// 获取会话内全部经历类记忆（按 turnNumber 升序）
  ///
  /// 用于「记忆查看器」UI 浏览会话内全部记忆。
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
  /// 用于「记忆查看器」编辑/查看单条记忆。不存在时返回 null。
  ///
  /// 异常: QueryException (E301)
  Future<ExperientialMemory?> getExperienceById(String memoryId);

  /// 更新单条经历类记忆的可编辑字段
  ///
  /// 用于「记忆查看器」手动编辑单条记忆。
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

  /// 按 memoryId 删除单条经历类记忆（含 FTS5 索引 + embedding）
  ///
  /// 用于「记忆查看器」手动删除单条记忆。
  /// 与 [deleteExperiencesByIds] 的差异：面向用户直接操作，**开自身事务**
  /// 保证一致性，且不需要 sessionId 参数（按 memoryId 单条删除）。
  ///
  /// 异常: QueryException (E301)
  Future<void> deleteExperienceById(String memoryId);
}
```

> **与 DOC-09A-2 §6.5 事务边界的对齐**：
> - `appendExperience` 返回 `ExperientialMemory`（含 `memoryId` UUID），**不使用 `last_insert_rowid()`**——Repository 内部生成 UUID 写入 `memory_id` 列后返回，遵循"Repository 不暴露 dbId"硬约束。
> - DOC-09A-2 §6.5 的 `saveEmbedding` → 对齐为 `updateEmbedding`（本节命名）。
> - DOC-09A-2 §6.5 的 `insertFtsIndex(memoryId, eventSummary, sessionId)` → 对齐为 `insertFtsIndex({named params})`。
> - DOC-09A-1 §3.8 SQL 中 `JOIN experiential_memories em ON mv.memory_id = em.id` 需改为 `ON mv.memory_id = em.memory_id`（关联业务 ID，非自增主键）。

### 4.5.2 检索结果类型

检索结果复用 §4.2 `ScoredMemory`。中级模式两路检索中 `temporalScore` 固定为 0（无 temporal 通道），`finalScore = fts5Score × fts5Weight + vectorScore × vectorWeight`（经关键事件加权和归一化后）。

---

## 4.6 FactualRepository（事实层中间方案，v0.2 中级模式，DOC-11）

**所属模块**: Memory
**版本**: v0.2（中级模式事实层中间方案，DOC-11）；v0.3 Advanced 模式由 `MemoryRepository` 接管并迁移
**职责**: 事实层数据的存储与检索（实体 + 属性 + 审计日志三表）
**接口定义位置**: `features/memory/domain/repositories/factual_repository.dart`
**实现位置**: `features/memory/data/repositories/factual_repository_impl.dart`

> **设计依据**：DOC-11 §11.1。按 ISP 接口隔离原则，事实层使用独立 Repository，与 `ExperienceRepository`（§4.5）分离。v0.3 `MemoryRepository` 将 `implements ExperienceRepository + FactualRepository`。
>
> **职责边界**：本接口仅含纯数据存取（CRUD + 批量应用 deltas）。业务逻辑（三重防护、5 层健康度防护、消歧）在 `FactApplier` 服务内（§4.6.2）。Repository 不暴露数据库主键（dbId），统一使用业务 ID（entityId / attributeId）。
>
> **事务原子性**（DOC-11 §7.3）：`applyFactsDeltas` 及所有写方法不开自身事务，供 `IntermediatePersistenceService` 在外层 drift transaction 内调用以保证原子性（与经历层 persisting 同事务，DOC-11 §8.2）。

### 4.6.1 接口定义

```dart
abstract class FactualRepository {
  // ─── 实体查询 ───────────────────────────────────────────────
  Future<List<FactualEntity>> getEntities(String sessionId, {bool includeArchived = false});
  Future<List<FactualEntity>> getKeyEntities(String sessionId, int minImportance);
  Future<List<FactualEntity>> findByName(String sessionId, List<String> names);
  Future<FactualEntity?> getEntityById(String entityId);

  // ─── 实体写入 ───────────────────────────────────────────────
  Future<FactualEntity> createEntity(FactualEntity entity);
  Future<void> updateEntityAliases(String entityId, List<String> aliases, int updatedTurn);
  Future<void> archiveEntity(String entityId, String reason, int turnNumber);

  // ─── 属性查询 ───────────────────────────────────────────────
  Future<List<FactualAttribute>> getAttributes(String sessionId, List<String> entityIds);
  Future<FactualAttribute?> getAttribute(String entityId, String attrKey);

  // ─── 属性写入 ───────────────────────────────────────────────
  Future<FactualAttribute> createAttribute(FactualAttribute attribute);
  Future<void> updateAttributeValue(String attributeId, String newValue, int updatedTurn, String? updateReason);

  // ─── 审计日志 ───────────────────────────────────────────────
  Future<void> insertHistory(FactualMemoryHistory history);
  Future<List<FactualMemoryHistory>> getHistory(String entityId);
  Future<int> countRecentUpdates(String entityId, {required int fromTurn});

  // ─── 记忆查看器 CRUD（2026-07-22 新增，DOC-06B §6.18 / DOC-09B §7.8）───

  /// 删除单个实体（含其全部属性 + 相关历史记录）
  ///
  /// 用于「记忆查看器」手动删除单个实体。
  /// 与 [deleteAllFacts] 的差异：仅删除指定 entityId 的数据，不影响其他实体。
  /// **开自身事务**。
  ///
  /// 异常: QueryException (E301)
  Future<void> deleteEntityById(String entityId);

  /// 删除单个属性
  ///
  /// 用于「记忆查看器」手动删除单个属性。
  /// **开自身事务**。
  ///
  /// 异常: QueryException (E301)
  Future<void> deleteAttributeById(String attributeId);

  /// 直接更新实体基本信息（不含 aliases）
  ///
  /// 用于「记忆查看器」手动编辑实体的 primaryName / type /
  /// importance / category / isArchived 字段。
  /// 与 [updateEntityAliases] 的差异：本方法面向用户直接编辑实体核心信息，
  /// 支持 primaryName / type / importance 等字段修改。
  /// **开自身事务**。
  ///
  /// 异常: QueryException (E301)
  Future<void> updateEntityBasic({
    required String entityId,
    String? primaryName,
    FactualEntityType? type,
    int? importance,
    String? category,
    bool? isArchived,
    int? updatedTurn,
  });

  // ─── 清理 ─────────────────────────────────────────────────
  Future<void> deleteAllFacts(String sessionId);
  Future<void> deleteFactsByTurns({required String sessionId, required int fromTurn});
}
```

> **异常规范**：
> - `EntityNotFoundException (E007)`：UPDATE_ATTR/APPEND_LIST 等动作的 entityId 不存在时抛出（注：实际实现中 FactApplier 在调用 repository 前已做存在性检查，repository 层不抛此异常；保留接口层语义供未来扩展）
> - `QueryException (E301)`：数据库查询失败

### 4.6.2 FactApplier 服务（业务逻辑）

**所属模块**: Memory（Domain 层服务）
**接口定义位置**: `features/memory/domain/services/fact_applier.dart`

> **设计依据**：DOC-11 §7、§11.2。`FactApplier` 是 Domain 层服务，负责将 summarizing 阶段 LLM 产出的 `FactsDelta` 列表应用到事实层数据库。包含三重防护 + 5 层健康度防护的业务逻辑。

```dart
class FactApplier {
  FactApplier({required FactualRepository repository});

  /// 批量应用事实变更
  ///
  /// [sessionId] 当前会话 ID
  /// [deltas] LLM 产出的 FactsDelta 列表
  /// [turnNumber] 当前轮次号（用于审计记录和更新频率限制）
  /// [config] 事实层配置（控制防护阈值）
  ///
  /// 返回成功应用的 delta 数量（被防护机制跳过的不计入失败）。
  ///
  /// 事务原子性：本方法不开自身事务，由调用方在 drift transaction 内
  /// 调用。任一 delta 抛出异常则整个事务回滚（DOC-11 §7.3）。
  Future<int> applyDeltas(String sessionId, List<FactsDelta> deltas, int turnNumber, FactualConfig config);
}
```

**防护机制**（DOC-11 §7.1、§7.4）：

| 层级 | 防护 | 实现位置 |
|------|------|---------|
| 三重防护 1 | 提示词约束（在 `kExtractFactsToolPrompt` 中） | `intermediate_prompts_v2.dart` |
| 三重防护 2 | 冲突检测（key 已存在 + 值真的不同） | `FactApplier._applyUpdateAttr` |
| 三重防护 3 | 重要性阈值（importance>=4 的关键属性需 confidence>=4） | `FactApplier._applyUpdateAttr` |
| 健康度 1 | 属性 schema 白名单（`AttributeSchema.isAttrKeyAllowed`） | `FactApplier._applyUpdateAttr` / `_applyAppendList` |
| 健康度 2 | 提示词约束（临时状态≠事实） | `kExtractFactsToolPrompt` |
| 健康度 3 | 系统级去重（精确 + 语义相似度 Levenshtein + 包含关系检测） | `FactApplier._applyAppendList` |
| 健康度 4 | 更新频率限制（3 轮 2 次） | `FactApplier._applyUpdateAttr` |
| 健康度 5 | 属性值长度上限（200 字） | `FactApplier._applyUpdateAttr` / `_applyAppendList` |

### 4.6.3 FactContextBuilder 服务（检索与注入）

**所属模块**: Memory（Domain 层服务）
**接口定义位置**: `features/memory/domain/services/fact_context_builder.dart`

> **设计依据**：DOC-11 §6、§11.2。retrieving 阶段调用，加载关键实体 + 关键词命中实体，构建【世界设定】注入文本供 revising 阶段使用。

```dart
class FactContextBuilder {
  FactContextBuilder({required FactualRepository repository});

  /// 构建事实注入块
  ///
  /// [sessionId] 当前会话 ID
  /// [keywords] 本轮关键词（用 entities 部分匹配实体名）
  /// [config] 事实层配置（控制启停、阈值、上限）
  /// [injectionTitle] 注入标题文本（默认【世界设定】，可用户自定义）
  ///
  /// 返回 [FactRetrievalResult]，包含注入文本（factBlock）和命中事实列表（facts）。
  /// 失败时返回空结果（factBlock=''，facts=[]），不抛异常——
  /// 事实层失败不应阻塞经历层检索和 revising 流程。
  Future<FactRetrievalResult> buildFactBlock({
    required String sessionId,
    required ClassifiedKeywords keywords,
    required FactualConfig config,
    required String injectionTitle,
  });

  /// 构建 `{{known_entities}}` 占位符替换文本（DOC-11 §5.2，v1.3 新增）
  ///
  /// [sessionId] 当前会话 ID
  /// [config] 事实层配置
  ///
  /// 返回可直接替换 `{{known_entities}}` 占位符的文本。空串表示事实层禁用
  /// 或无已知实体，调用方应将占位符替换为 `（暂无已知实体）`。
  ///
  /// 与 [buildFactBlock] 的差异：
  /// - [buildFactBlock]：retrieving 阶段用，按 keywords 匹配 + 关键实体筛选，注入 revising
  /// - [buildKnownEntitiesBlock]：summarizing 阶段用，注入未归档实体（importance >=
  ///   keyEntityImportanceThreshold-1，实体数 > injectionMaxEntities 时只保留
  ///   importance >= keyEntityImportanceThreshold 的关键实体），让 LLM 知道已有
  ///   实体的 entityId，从而直接通过 update_attr 等动作操作已有实体，避免用
  ///   create_entity 给已存在实体加属性触发 §10.3 的实体已存在分支。
  ///   2026-07-22 修复：原硬编码 importance>=3/>=4/>20 改为读取 config 对应字段。
  ///
  /// 失败时返回空字符串（不抛异常），不阻塞 summarizing 阶段。
  Future<String> buildKnownEntitiesBlock({
    required String sessionId,
    required FactualConfig config,
  });
}

@immutable
class FactRetrievalResult {
  const FactRetrievalResult({required this.factBlock, required this.facts});
  final String factBlock;        // 注入文本（含【世界设定】标题），空串表示事实层禁用
  final List<RetrievedFact> facts; // 检中的事实列表（供 UI 检索面板展示）
  bool get hasFacts => factBlock.isNotEmpty && facts.isNotEmpty;
}

@immutable
class RetrievedFact {
  const RetrievedFact({
    required this.entity,
    required this.attributes,
    required this.isKeyEntity,
    required this.isKeywordMatched,
  });

  final FactualEntity entity;             // 命中的实体
  final List<FactualAttribute> attributes; // 该实体的所有属性
  final bool isKeyEntity;                  // 是否为关键实体（importance >= 阈值，强制注入）
  final bool isKeywordMatched;             // 是否为关键词命中

  // 序列化支持（用于 intermediate_round_artifacts 持久化）
  factory RetrievedFact.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}
```

**检索流程**（DOC-11 §6.1）：
1. 加载关键实体（`importance >= keyEntityImportanceThreshold`，强制注入）
2. 按 `keywords.entities` 匹配相关实体（`primaryName` 精确匹配 OR `aliases` 数组包含）
3. 合并去重，最多 `injectionMaxEntities` 个（关键实体优先，关键词命中次之）
4. 批量加载这些实体的所有属性
5. 按实体类型分组（角色/宠物/NPC/地点/物品）格式化文本

**与经历层检索的差异**：
- 经历层用 FTS5 + Vector 混合检索（基于 score 排序）
- 事实层用名字匹配 + 重要性筛选（无 score，二元判定：注入或不注入）
- 理由：事实层是"当前世界状态"快照，不需要按相关性排序，全部注入即可

### 4.6.4 与 v0.3 MemoryRepository 的关系

| 维度 | v0.2 中间方案（本文档） | v0.3 Advanced 模式 |
|------|----------------------|-------------------|
| 接口 | `FactualRepository`（独立）+ `FactApplier` + `FactContextBuilder` 服务 | `MemoryRepository` implements `ExperienceRepository + FactualRepository` |
| 触发方式 | summarizing 阶段并行调用 `extract_facts` 工具 | `update_world` 工具 + Agent Loop |
| 防护机制 | 三重防护 + 5 层健康度防护 | 同（沿用本方案） |
| HUD | 无 | 有（`factual_entities` 只读视图） |
| 迁移路径 | — | v0.3 启动时将 `FactualRepositoryImpl` 实现合并到 `MemoryRepositoryImpl`，接口层无需改动 |

详见 DOC-11 §14。

---



---

## 变更记录

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-06-30 | 从原 DOC-05 v2.2 拆分（05 因 2841 行严重超限拆为 05-1 ~ 05-8），本文档包含原 §4 + §4.5。原节号保持不变 |
| v1.1 | 2026-07-03 | 接口同步：§4.5.1 ExperienceRepository 新增 `deleteExperienceByTurns(sessionId, fromTurnNumber)` 方法（简化 Fork 删除阶段专用，不开自身事务，由 IntermediatePersistenceService 在外层事务内调用） |
| v1.2 | 2026-07-19 | 5W1E 改造：<br/>1. §4 `MemoryRepository.appendExperience` 签名：`summary` 改为 `String?`，新增 6 个 5W1E 命名参数（when/where/who/what/significance/extra）<br/>2. §4.5 `ExperienceRepository.appendExperience` 签名：同上<br/>3. §4.5 `ExperienceRepository.insertFtsIndex` 签名：`summary` 改为 `String?`，新增 6 个 5W1E 命名参数（与 `memories_fts` 7 内容字段对齐）<br/>4. §4.5 `ExperienceRepository.searchExperiences` 补注：`RetrievalConfig.topK` 默认值由 5 调整为 3（5W1E 多字段检索精度提升，减少上下文占用）<br/>5. 宏摘要（is_summary=true）保持 `summary` 单字段，不采用 5W1E；consolidation 已禁用（trigger_threshold=2.0） |
| v1.3 | 2026-07-20 | DOC-11 事实层中间方案同步：新增 §4.6 FactualRepository（v0.2 中级模式事实层），含三表 CRUD 接口、`FactApplier` 服务（三重防护 + 5 层健康度防护业务逻辑）、`FactContextBuilder` 服务（retrieving 阶段构建【世界设定】注入文本）、`RetrievedFact` 序列化类型、与 v0.3 `MemoryRepository` 的迁移路径 |
| v1.4 | 2026-07-21 | §4.5.1 ExperienceRepository 新增 `getMemoriesWithoutEmbedding(sessionId, {limit=500})` 方法（用于会话级「重建向量索引」功能，返回 `has_embedding=false` 且未归档的记忆按 turn_number 升序） |
| v1.5 | 2026-07-22 | §4.6.3 FactContextBuilder 新增 `buildKnownEntitiesBlock(sessionId, config)` 方法（DOC-11 §5.2 v1.3 同步），用于 summarizing 阶段注入 `{{known_entities}}` 占位符替换文本，让 LLM 知道已有实体的 entityId 从而直接通过 update_attr 等动作操作已有实体。修复事实层属性不更新 Bug |
| v1.6 | 2026-07-22 | 记忆查看器 CRUD 接口扩展：（1）**§4.5.1 ExperienceRepository 新增 4 个 CRUD 方法**——`getAllExperiences(sessionId, {includeArchived=true})` 全量查询（按 turnNumber 升序，不限制数量，含已归档）/ `getExperienceById(memoryId)` 单条查询 / `updateExperience({memoryId, sessionId, summary?, when?, where?, who?, what?, significance?, extra?, importance?, tags?})` 单条更新（同步 FTS5 索引，开自身事务）/ `deleteExperienceById(memoryId)` 单条删除（含 FTS5 + embedding，开自身事务）。4 个方法均面向「记忆查看器」UI 直接操作，与既有批量方法（`deleteExperiencesByIds` 不开自身事务）形成对比——用户直接操作需保证索引一致性故开自身事务。（2）**§4.6.1 FactualRepository 新增 3 个 CRUD 方法**——`deleteEntityById(entityId)` 级联删除实体+属性+历史（开自身事务）/ `deleteAttributeById(attributeId)` 单属性删除（开自身事务）/ `updateEntityBasic({entityId, primaryName?, type?, importance?, category?, isArchived?, updatedTurn?})` 实体核心信息更新（与 `updateEntityAliases` 互补，本方法支持 primaryName/type/importance 等字段，开自身事务）。3 个方法均面向「记忆查看器」UI 直接操作。代码同步：`ExperienceRepositoryImpl` / `FactualRepositoryImpl` 实现完成；测试 stub `FakeFactualRepository` + `_FailingExperienceRepository` 同步补全。配合 DOC-06B v3.8（§6.18 MemoryBrowserPage 视觉规范）、DOC-09B v2.20（§7.8 MemoryBrowserPage 交互流程 + §10.2 区段 6 记忆管理）、DOC-11 v1.4（§11.1 接口同步） |
| v1.7 | 2026-07-22 | 两处 importance 阈值对齐修复：（1）**§4.5.1 `getMemoriesWithoutEmbedding` 新增 `minImportance` 参数**——重建向量索引时按 `microVectorizeThreshold`(默认4) 筛选，对齐持久化时的两级向量化策略，避免补齐持久化时有意跳过的低重要性记忆 embedding。（2）**§4.6.3 `buildKnownEntitiesBlock` 阈值改为读 config**——原硬编码 importance>=3/>=4/>20 改为 `keyEntityImportanceThreshold-1` / `keyEntityImportanceThreshold` / `injectionMaxEntities`，与 `buildFactBlock` 注入逻辑对齐。新增 `ConfigurationResolver.resolveMicroVectorizeThreshold()` 方法 |
| v1.8 | 2026-07-25 | 叙事时间机制——appendExperience 接口 narrativeTime 参数启用状态修订：<br/>(1) §4 `MemoryRepository.appendExperience` 与 §4.5 `ExperienceRepository.appendExperience` 的 `narrativeTime` 参数从原 v0.3 启用提前到 v0.2 启用——由 summarizing 阶段 LLM 输出的 `EventSummary.narrativeTime` 传入，持久化到 `experiential_memories.narrative_time` 列；persist 成功后由控制器 upsert 到 `chat_sessions.current_narrative_time` 作为会话级状态<br/>(2) `narrativePeriod` 参数仍为 v0.3 启用（中级模式恒 null）<br/>(3) `when` 参数注释修订为"何时（相对时间，如'次日清晨'）"——明确与 `narrativeTime`（绝对时间锚点）的区别<br/>(4) 接口签名未变化（参数已存在），仅文档注释与启用状态标注更新<br/>(5) 详见 DOC-08 §5.7、DOC-09A-2 §8.1 |
