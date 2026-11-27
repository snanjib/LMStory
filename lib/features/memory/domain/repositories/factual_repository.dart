import 'package:lmstory/core/exceptions/app_exceptions.dart'
    show ResourceApplyException;
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity_catalog.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_changes_snapshot.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart'
    show ExperienceRepository;
import 'package:lmstory/features/memory/domain/services/memory_query.dart'
    show MemoryQuery;

export 'package:lmstory/features/memory/domain/entities/factual_entity_catalog.dart';

/// 「记忆查看器」手动编辑属性的固定 updateReason（持久化审计值，非 UI 文案）。
const factualManualEditReason = '手动编辑';

/// 「记忆查看器」手动归并写审计历史的固定原因（持久化审计值，非 UI 文案）。
const factualManualMergeReason = '记忆查看器手动归并';

/// 持久化引用不属于当前会话。切稿调用方须撤销整个事务。
class FactTargetMismatch implements Exception {
  const FactTargetMismatch();
}

/// 事实层仓储接口（DOC-11 §11.1、DOC-05 §4.6）
///
/// 按 ISP 接口隔离原则，事实层使用独立 Repository，与 [ExperienceRepository]
/// 分离。v0.3 MemoryRepository 将 implements 这两个接口。
///
/// **职责边界**：
/// - 本接口仅含纯数据存取（CRUD + 批量应用 deltas）
/// - 业务逻辑（三重防护、5 层健康度防护、消歧）在 FactApplier 服务内
/// - Repository 不暴露数据库主键（dbId），统一使用业务 ID（entityId /
///   attributeId）
///
/// **事务原子性**（DOC-11 §7.3）：
/// `applyFactsDeltas` 必须在 drift 事务内执行，任一 delta 失败则整个
/// 事务回滚。本方法**不开自身事务**，供 StoryPersistenceService
/// 在外层 drift transaction 内调用以保证原子性（与经历层 persisting
/// 同事务，DOC-11 §8.2）。
///
/// 异常规范：
/// - EntityNotFoundException (E007)：UPDATE_ATTR/APPEND_LIST 等动作的
///   entityId 不存在时抛出
/// - QueryException (E301)：数据库查询失败
abstract class FactualRepository {
  // ─── 实体查询 ───────────────────────────────────────────────────────

  /// 获取会话内所有实体
  ///
  /// [includeArchived]：是否包含已归档实体（默认 false，仅返回活跃实体）。
  /// 按 importance 降序、createdAt 升序排列（关键实体优先，同重要性按
  /// 出现顺序）。
  Future<List<FactualEntity>> getEntities(
    String sessionId, {
    bool includeArchived = false,
  });

  /// 获取关键实体（importance >= [minImportance]）
  ///
  /// retrieving 阶段 FactContextBuilder 调用，强制注入 prompt 的实体集合
  /// （DOC-11 §6.1 步骤 1）。
  /// 不含已归档实体。
  ///
  /// [includeForceInject] = true 时，forceInject 非 none 的实体重要性
  /// 不达标也入选（：query_facts 的「常驻」标签与 worldbook-style
  /// 技能建议以此为前提；导演 coreBlocks 开启，其余调用方保持原口径）。
  ///
  /// [excludeInjectionDisabled] = true 时剔除注入停用词条（批 J-b
  ///  漏桶收口）。注入面调用方（FactContextBuilder.buildFactBlock）
  /// 必须传 true；浏览/检索/写入面（query_facts、FactApplier 消歧与更新
  /// 定位）保持 false——停用词条仍可被检索命中并接受更新。
  Future<List<FactualEntity>> getKeyEntities(
    String sessionId,
    int minImportance, {
    bool includeForceInject = false,
    bool excludeInjectionDisabled = false,
  });

  /// 按 primaryName 或 aliases 匹配实体（DOC-11 §10.1）
  ///
  /// [names] 待匹配的名字列表（本轮 keywords 中识别的实体名）。
  /// 匹配规则：primaryName 精确匹配 OR aliases 数组包含。
  /// 多匹配时返回全部，由调用方按 importance 优先级消歧（DOC-11 §10.2）。
  /// 不含已归档实体。
  ///
  /// [excludeInjectionDisabled] = true 时剔除注入停用词条（含以其别名
  /// 命中的结果）。语义同 [getKeyEntities]：仅注入面传 true。
  Future<List<FactualEntity>> findByName(
    String sessionId,
    List<String> names, {
    bool excludeInjectionDisabled = false,
  });

  /// 主表子串检索（关键词通道的可达性兜底）
  ///
  /// 与 [searchWorldFacts] 的分工：后者只查 `factual_fts`（世界书词条
  /// 专用索引，auto/card/手动实体永无行），因此关键词查询对非世界书实体
  /// 恒空。本方法直接扫主表——`primary_name` / `aliases` / 属性值三路
  /// LIKE（词元由 [MemoryQuery] 切分与转义），**不依赖任何索引**，保证
  /// 「库里可见的实体一定能被关键词召回」。
  ///
  /// [terms] 已切分的词元（多词为 OR 关系）；空列表返回空。
  /// 结果按 importance 降序、updated_at 降序（NULL 最后）、created_at 升序。
  /// [includeArchived] = true 时含已归档实体（供"是否已归档"探测）。
  /// [excludeInjectionDisabled] 语义同 [getKeyEntities]：仅注入面传 true。
  Future<List<FactualEntity>> searchEntitiesByText(
    String sessionId,
    List<String> terms, {
    int limit = 10,
    bool includeArchived = false,
    bool excludeInjectionDisabled = false,
  });

  /// 按 entityId 获取单个实体
  ///
  /// 不存在时返回 null。
  Future<FactualEntity?> getEntityById(String entityId);

  /// 按 entityId 列表批量获取实体（严格按 [sessionId] 隔离，包含已归档实体）。
  ///
  /// 保留输入去重顺序，不存在或跨会话的 ID 自动忽略。
  Future<List<FactualEntity>> getEntitiesByIds(
    String sessionId,
    List<String> entityIds,
  );

  /// 分页浏览会话内实体目录，并返回全会话紧凑分布统计头。
  ///
  /// - [sourceFilter]：`'dynamic'`（默认，`source == auto || updatedTurn != null`）、
  ///   `'auto'`、`'worldbook'`、`'card'`、`'all'`
  /// - [sort]：`'stale_first'`（默认，`importance DESC, COALESCE(updated_turn, created_turn) ASC, created_at ASC`）、
  ///   `'recently_updated'`、`'importance_desc'`、`'created_desc'`
  /// - [updatedBeforeTurn]：匹配 `COALESCE(updated_turn, created_turn) < updatedBeforeTurn`
  /// - [updatedAfterTurn]：匹配 `COALESCE(updated_turn, created_turn) > updatedAfterTurn`
  /// - [includeArchived]：是否包含已归档实体（默认 false）；非归档的停用注入词条始终保留
  /// - [limit]：默认 25，上限 50
  Future<FactualEntityCatalogPage> listEntityCatalog(
    String sessionId, {
    FactualEntityType? entityType,
    String sourceFilter = 'dynamic',
    String sort = 'stale_first',
    int? updatedBeforeTurn,
    int? updatedAfterTurn,
    bool includeArchived = false,
    int limit = 25,
    int offset = 0,
  });

  /// Looks up a known stored type for an entity in the requested session.
  Future<FactualEntityType?> getEntityTypeInSession(
    String sessionId,
    String entityId,
  );

  // ─── 实体写入 ───────────────────────────────────────────────────────

  /// 创建新实体
  ///
  /// 返回持久化后的 [FactualEntity]（含回填的 entityId）。
  /// **不开自身事务**，供 FactApplier 在外层 drift transaction 内调用。
  ///
  /// 调用方需保证 primaryName 在会话内唯一（FactApplier 已做去重检查）。
  Future<FactualEntity> createEntity(FactualEntity entity);

  /// 更新实体的 aliases 列表（ADD_ALIAS 动作）
  ///
  /// **不开自身事务**，供 FactApplier 在外层 drift transaction 内调用。
  Future<void> updateEntityAliases(
    String entityId,
    List<String> aliases,
    int updatedTurn,
  );

  /// 动态调整实体重要度（1-5，同步更新 `updatedTurn` / `updatedAt`）。
  ///
  /// 仅修改注入权重元数据，不改主名/类型/属性；同时放行 `auto` 与
  /// `worldbook`/`card` 导入实体。
  /// **不开自身事务**，供 FactApplier 在外层 drift transaction 内调用。
  Future<void> updateEntityImportance(
    String entityId,
    int importance,
    int updatedTurn,
  );

  /// 归档实体（ARCHIVE_ENTITY 动作）
  ///
  /// [reason] 归档原因（如"剧情中角色死亡"）。
  /// [turnNumber] 触发轮次。
  /// **不开自身事务**，供 FactApplier 在外层 drift transaction 内调用。
  Future<void> archiveEntity(
    String entityId,
    String reason,
    int turnNumber,
  );

  /// 设置实体强制注入开关（v0.2.3）
  ///
  /// 只改 `forceInject` 列，**豁免内容只读守卫**（世界书/角色卡实体也可改开关）。
  /// 纯检索偏好，不写入审计历史、不触发 updatedTurn 变更。
  Future<void> updateEntityForceInject(
    String entityId,
    ForceInjectTarget target,
  );

  /// 批量设置实体强制注入开关（记忆库批量勾选用）
  ///
  /// 在事务内执行，任一失败整体回滚。
  Future<void> batchUpdateForceInject(
    List<String> entityIds,
    ForceInjectTarget target,
  );

  /// 批 J-b：词条级注入停用/恢复（纯列写，无审计）
  Future<void> batchUpdateInjectionDisabled(
    List<String> entityIds, {
    required bool disabled,
  });

  // ─── 属性查询 ───────────────────────────────────────────────────────

  /// 批量获取多个实体的所有属性
  ///
  /// retrieving 阶段 FactContextBuilder 调用，加载命中实体的全部属性
  /// 用于注入【世界设定】区块（DOC-11 §6.1 步骤 4）。
  Future<List<FactualAttribute>> getAttributes(
    String sessionId,
    List<String> entityIds,
  );

  /// 获取单个实体的某 attrKey 下的所有属性行（多行，按 source 区分）
  ///
  /// v36 起同 (entityId, attrKey) 可存在「基线（source=card）+ 演变（source=auto）」
  /// 多行。FactApplier 调用，用于只读守卫（取 auto 行、识别只读基线）。
  /// 无匹配时返回空列表。
  Future<List<FactualAttribute>> getAttributesByKey(
    String entityId,
    String attrKey,
  );

  // ─── 属性写入 ───────────────────────────────────────────────────────

  /// 创建属性记录（CREATE_ENTITY 时初始化属性 OR APPEND_LIST 时属性不存在）
  ///
  /// **不开自身事务**，供 FactApplier 在外层 drift transaction 内调用。
  Future<FactualAttribute> createAttribute(FactualAttribute attribute);

  /// 更新属性值（UPDATE_ATTR 动作）
  ///
  /// 同步更新 updatedAt / updatedTurn / updateReason 字段。
  /// **不开自身事务**，供 FactApplier 在外层 drift transaction 内调用。
  Future<void> updateAttributeValue(
    String attributeId,
    String newValue,
    int updatedTurn,
    String? updateReason,
  );

  // ─── 审计日志 ───────────────────────────────────────────────────────

  /// 追加一条审计日志（FactApplier 在应用每个 delta 后调用）
  ///
  /// **不开自身事务**，供 FactApplier 在外层 drift transaction 内调用。
  Future<void> insertHistory(FactualMemoryHistory history);

  /// 获取实体的修改历史（用于审计 UI 或回滚）
  ///
  /// 按 createdAt 降序排列（最新在前）。
  Future<List<FactualMemoryHistory>> getHistory(String entityId);

  /// 在同一只读事务取得当前会话事实流水、对象属性和当前稿证据。
  Future<FactualMemoryChangesSnapshot> readMemoryChangesSnapshot(
    String sessionId,
  );

  /// 统计实体在指定轮次范围内的更新次数（更新频率限制 DOC-11 §7.4.5）
  ///
  /// [fromTurn] 起始轮次（含）。
  /// 返回 [fromTurn] 及之后的 UPDATE_ATTR / APPEND_LIST / REMOVE_FROM_LIST
  /// 操作总数（CREATE_ENTITY / ADD_ALIAS / ARCHIVE_ENTITY 不计入"更新频率"，
  /// 因为它们不是"修改现有属性"）。
  Future<int> countRecentUpdates(
    String entityId, {
    required int fromTurn,
  });

  // ─── 清理 ─────────────────────────────────────────────────────────

  /// 删除单个实体（含其全部属性 + 相关历史记录）
  ///
  /// 2026-07-22 新增：用于「记忆查看器」手动删除单个实体。
  /// 与 [deleteAllFacts] 的差异：仅删除指定 entityId 的数据，不影响其他实体。
  /// **开自身事务**。
  ///
  /// 异常: QueryException (E301)
  Future<void> deleteEntityById(String entityId);

  /// 按投影来源成组删除实体（取消应用，F1 修复 2026-08-23）
  ///
  /// 删除会话内全部 `sourceRef` 匹配的实体及其属性、历史记录与 FTS 行，
  /// 返回删除的实体数。**有意绕过 [deleteEntityById] 的只读守卫**——
  /// 守卫面向记忆库手动单条删除（防误删种子）；"取消应用"是投影生命周期
  /// 的另一半（种子成组移除），且实体携带的 auto 演变行随实体一并删除
  /// 属预期语义。**开自身事务**。
  ///
  /// 异常: QueryException (E301)
  Future<int> deleteEntitiesBySourceRef(
    String sessionId,
    String sourceRef,
  );

  /// 删除单个属性
  ///
  /// 2026-07-22 新增：用于「记忆查看器」手动删除单个属性。
  /// **开自身事务**。
  ///
  /// 异常: QueryException (E301)
  Future<void> deleteAttributeById(String attributeId);

  /// 直接更新实体基本信息（不含 aliases）
  ///
  /// 2026-07-22 新增：用于「记忆查看器」手动编辑实体的 primaryName / type /
  /// importance / category / isArchived 字段。
  /// 与 [updateEntityAliases] 的差异：本方法面向用户直接编辑实体核心信息，
  /// 支持 primaryName / type / importance 等字段修改。
  /// **开自身事务**。
  ///
  /// 只读语义 2.0：对 source != auto 的实体，内容字段
  /// （primaryName/type/importance/category）任一非 null 即抛
  /// [ResourceApplyException]；仅 isArchived/updatedTurn 的调用放行——
  /// 归档是可逆生命周期标记（AI 可归档导入实体，手动恢复必须可达）。
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

  /// 删除会话全部事实层数据（实体 + 属性 + 历史）
  ///
  /// 用于会话删除或重建。**开自身事务**。
  Future<void> deleteAllFacts(String sessionId);

  /// 删除会话内 createdTurn >= [fromTurn] 的事实层数据（覆盖式重写场景）
  ///
  /// 重生/编辑重发/删除整轮时，清理目标轮次及下游所有事实变更，避免设定串戏。
  ///
  /// 5 步（实现见 FactualRepositoryImpl）：
  /// 1. 收集 createdTurn >= [fromTurn] 的实体（待删）
  /// 2. 删除其属性 + 历史
  /// 3. 回滚 createdTurn < [fromTurn] 的「幸存」实体在 fromTurn 及之后的
  ///    属性/别名/归档变更（基于 factual_memory_history 恢复旧值或删除新建属性）
  /// 4. 删除当前会话内 turnNumber >= [fromTurn] 的历史记录
  /// 5. 删除待删实体本身
  ///
  /// **不开自身事务**，供 StoryPersistenceService 在外层 drift
  /// transaction 内调用以保证原子性。
  Future<void> deleteFactsByTurns({
    required String sessionId,
    required int fromTurn,
  });

  /// 在事务内执行 [action]（供资源投影等需要多步原子写入的调用方使用）
  ///
  /// DOC-15 §9.3 投影原子性：整卡/整书「全投影或全不」，任一步失败整体回滚。
  Future<T> runInTransaction<T>(Future<T> Function() action);

  // ─── FTS5 索引（世界书词条检索，DOC-15 §7.3）────────────────────────

  /// 插入世界书词条全文索引（投影时调用）
  Future<void> insertFactualFts({
    required String entityId,
    required String sessionId,
    required String primaryName,
    required List<String> aliases,
    required String description,
  });

  /// 删除单条全文索引（删除实体时调用）
  Future<void> deleteFactualFts(String entityId);

  /// 删除会话全部全文索引（deleteAllFacts 时调用）
  Future<void> deleteAllFactualFts(String sessionId);

  /// 按实体重建 factual_fts 行
  ///
  /// 先删后插；仅 worldbook 实体落索引（与 rebuildSessionFts 口径一致），
  /// description 取该实体 rowid 首条 description 行（基线行优先——投影
  /// 先写基线行，演变行居后）。用于演变 description 行的原地更新与
  /// 回滚删除后的索引同步——此前只覆盖「新建」单路径，留下旧文本
  /// 脏索引（幽灵召回/旧值召回）。
  /// **不开自身事务**；调用方在事务内调用时随外层事务提交。
  Future<void> rebuildEntityFts(String entityId);

  /// 关键词检索世界书词条（返回命中的实体，按相关度降序）
  ///
  /// [excludeInjectionDisabled] = true 时剔除注入停用词条（含短词 LIKE
  /// 扫 aliases/description 命中的结果）。语义同 [getKeyEntities]：
  /// 仅注入面传 true；query_facts 等检索面保持不过滤。
  Future<List<FactualEntity>> searchWorldFacts(
    String sessionId,
    List<String> terms, {
    int limit = 20,
    bool excludeInjectionDisabled = false,
  });
}
