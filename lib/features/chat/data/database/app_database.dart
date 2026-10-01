import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/data/database/tables/agent_events_table.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/chat/data/database/database_connection.dart'
    if (dart.library.html) 'database_connection_web.dart';
import 'package:lmstory/features/chat/data/database/tables/chat_messages_table.dart';
import 'package:lmstory/features/chat/data/database/tables/chat_session_branches_table.dart';
import 'package:lmstory/features/chat/data/database/tables/chat_sessions_table.dart';
import 'package:lmstory/features/chat/data/database/tables/compaction_points_table.dart';
import 'package:lmstory/features/chat/data/database/tables/message_variants_table.dart';
import 'package:lmstory/features/diagnostics/data/database/tables/failure_logs_table.dart';
import 'package:lmstory/features/memory/data/database/embedding_dimensions_backfill.dart';
import 'package:lmstory/features/memory/data/database/tables/experiential_memories_table.dart';
import 'package:lmstory/features/memory/data/database/tables/factual_attributes_table.dart';
import 'package:lmstory/features/memory/data/database/tables/factual_entities_table.dart';
import 'package:lmstory/features/memory/data/database/tables/factual_memory_history_table.dart';
import 'package:lmstory/features/resource_library/data/database/tables/character_cards_table.dart';
import 'package:lmstory/features/resource_library/data/database/tables/worldbooks_table.dart';
import 'package:lmstory/features/settings/data/database/tables/api_presets_table.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/story_runtime/data/database/tables/intermediate_round_artifacts_table.dart';
import 'package:lmstory/features/templates/data/database/tables/templates_table.dart';
import 'package:meta/meta.dart';

part 'app_database.g.dart';

/// LMStory 应用数据库
/// schemaVersion 见下方 getter（：标题不再写具体数字——
/// v48/v49/v50 三版均漏改标题，结构性追改改为不写数）；各版增量见下方
/// 版本注释块：
/// v16: failure_logs / intermediate_round_artifacts / memories_fts 虚拟表
/// v17: chat_sessions.json_mode_override（中级模式 JSON 模式会话级覆盖）
/// v18: intermediate_round_artifacts.reply_text/event_summary（四步重构）
/// v19: experiential_memories.memory_level/parent_event_ids/macro_trigger_reason
///      （DOC-10 多粒度记忆：micro/macro 双层结构）
/// v20: chat_sessions.presence_penalty/frequency_penalty（生成参数会话级覆盖）
/// v21: experiential_memories 5W1E 6 列 + memories_fts 重建 7 内容字段
///      （v0.2 Phase C 方案二，2026-07-19）
/// v22: 事实层 3 表（factual_entities / factual_attributes /
///      factual_memory_history，DOC-11 事实层中间方案，2026-07-20）
/// v23: chat_sessions 8 列会话级分步骤模型（原 drafting/extracting/revising/
///      summarizing 各 preset_id + model_id，2026-07-21 配置架构重构；
///      v33 改名为 generating/extracting/reviewing/summarizing）
/// v24: api_presets.protocol + api_presets.templateId 2 列
///      （DOC-12 供应商模板与多协议适配，2026-07-24）
/// v25: chat_messages.reasoning_content 列
///      （DeepSeek V4 reasoning_content 跨轮回传，DOC-12 §5.4.2，2026-07-24）
/// v26: chat_sessions.current_narrative_time 列
///      （v0.2 叙事时间机制：会话级当前叙事时间状态，2026-07-25）
/// v27: api_presets.provider_options 列
///      （DOC-12 §5.5 providerOptions 透传：协议特有参数配置，2026-07-28）
/// v28: intermediate_round_artifacts.retrieved_facts 列
///      （DOC-11 §6.1 事实层检索结果持久化到轮次中间产物表，2026-07-29）
/// v29: chat_sessions.effective_context_limit 列
///      （故事模式单次请求 token 上限配置，应对 TPM 限制，2026-07-29）
/// v30: chat_sessions.suggest_reply_preset_id / suggest_reply_model_id /
///      suggest_reply_prompt_override 3 列
///      （推荐回复功能会话级配置：模型 + 提示词覆盖，2026-07-29）
/// v31: chat_sessions.review_enabled_override / recent_min_ratio_override /
///      retrieval_ratio_override 3 列
///      （v0.2.2 故事模式架构调整：审查开关 + 上下文预算会话级覆盖，2026-07-30）
/// v32: chat_sessions.review_enabled_override 列名从 revise_enabled_override 改名；
///      intermediate_round_artifacts 新增 review_executed
///      （术语同步：终稿 → 审查，2026-08-01）
/// v33: chat_sessions 8 列会话级分步骤模型列名从 drafting_*/revising_* 改为
///      generating_*/reviewing_*（术语同步：草稿 → 生成，终稿 → 审查，2026-08-01）
/// v34: chat_sessions.compaction_trigger_ratio_override（DOC-14 §3.3：
///      压缩触发线会话级覆盖，2026-08-12）
/// v35: intermediate_round_artifacts.facts_changes（事实层变更小窗：
///      持久化本轮事实层变更记录，含变更前/变更后，2026-08-13）
/// v36: factual_entities.source/source_ref + factual_attributes.source
///      （世界书/角色卡只读模型，DOC-15 §8.1 方案 A，2026-08-13）
///      + character_cards / worldbooks 资源表（DOC-15 §9.1）
/// v37: factual_entities.force_inject（实体强制注入开关，v0.2.3，2026-08-14）
/// v38: agent_events（v0.3 Agent 会话事件日志：append-only 唯一真相源 +
///      surface 投影，设计报告 §7.3，2026-08-15）
/// v39: chat_sessions.max_steps（导演模式每轮最大步数预算，2026-08-15）
/// v40: intermediate_round_artifacts.agent_steps（导演模式每轮 agent 工具步骤
///      持久化，opencode 时间线重建用，2026-08-15）
/// v41: intermediate_round_artifacts.agent_summary（导演模式每轮工作摘要：
///      步数/总 token/总时长，L1 过程汇总行 + 成本累计用，体验重构 ，
///      2026-08-16）
/// v42: chat_sessions.story_anchor + intermediate_round_artifacts.story_anchor
///      （导演模式剧情锚：当前弧线/伏笔清单/叙事时间/一句主线，AI 经
///      update_story_anchor 维护，幕间 Recap 卡数据源，体验重构卡片 C，
///      2026-08-16）
/// v43: chat_sessions.watch_mode（导演模式监督开关，当轮快照在 runRound 读取）
/// v44: chat_sessions.tool_permissions / max_duration_minutes（导演设置体系：
///      watchMode 泛化为三态工具权限 map + 单轮时间预算会话覆盖；
///      存量 watch_mode=1 经 _migrateDirectorToolPermissions 物化监督预设）
/// v45: intermediate_round_artifacts.agent_timeline（导演模式对话流：
///      轮时间线持久化——思考/播报/动作三类块按真实发生顺序交错；
///      旧数据缺列回退 agent_steps 渲染，agent_steps 兼容期双写，2026-08-28）
/// v46: chat_sessions.narrative_pacing（导演模式剧情节奏档会话覆盖：
///      conservative|balanced|aggressive，NULL=跟随全局
///      advanced.narrative_pacing；剧情节奏档位设计 §5.3，2026-08-31）
/// v47: chat_sessions.next_turn（turn 单一事实源：会话级下一轮轮次号
///      计数器。NULL=存量会话未物化，运行时按公式惰性回退；首个 schema 47
///      迁移窗，后续 v47 内显式迁移步（如  归档让名 partial 索引）
///      挂本版本块，不另开版本）
/// v48: factual_entities.injection_disabled（批 J-b 记忆注入停用：会话内
///      停用指定实体后其记忆不再进入注入面，带 DEFAULT(false) 对存量行
///      无感；7cf837af 落版，2026-09-07）
/// v49: message_variants 新表 + intermediate_round_artifacts.current_variant_index
///      （非破坏性重生成：变体快照按 (session,turn,index) 键，
///      指针列在 artifacts 行；纯增量，存量会话零迁移，2026-09-08）
/// v50: experiential_memories.embedding_dimensions（记忆补齐，2026-09-09：
///      换嵌入模型后的陈旧向量可观测+可重建；纯增量补列，存量行由
///      backfillEmbeddingDimensions 在 beforeOpen 幂等回填）
/// v51: experiential_memories.source（2026-09-15 ：
///      'auto'=轮管线产物 / 'manual'=记忆库手动新增。deleteExperienceByTurns
///      只删 auto 行——手动记忆不再被「重生成/删除本轮」按 turn 窗静默吞删；
///      DEFAULT('auto') 对存量行无感（存量手动行不可追溯，仍按 auto 处理））
///
/// 迁移策略（user_rules #3 + 用户明确要求：升级不丢数据，只扩展表结构）：
/// - onCreate：m.createAll() + _createIndexes() + _createV16Tables() +
///   _createFactualIndexes()
/// - onUpgrade：任何 from < schemaVersion → 调用 [repairSchema] 做纯增量迁移，
///   CREATE TABLE IF NOT EXISTS + ALTER TABLE ADD COLUMN，不删除任何数据，
///   不修改已有列的类型/约束。
/// - 历史上曾使用 DROP + 重建策略，导致用户升级后数据全部丢失，已废弃。
/// - 正式发版前可重写为统一 MigrationStep（保留用户数据 + 增量迁移）。
@DriftDatabase(
  tables: [
    ChatSessionsTable,
    ChatMessagesTable,
    ChatSessionBranchesTable,
    CompactionPointsTable,
    ExperientialMemoriesTable,
    FactualEntitiesTable,
    FactualAttributesTable,
    FactualMemoryHistoryTable,
    ApiPresetsTable,
    TemplatesTable,
    FailureLogsTable,
    IntermediateRoundArtifactsTable,
    MessageVariantsTable,
    CharacterCardsTable,
    WorldbooksTable,
    AgentEventsTable,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  /// schema 修复日志（修复：ALTER 失败不再静默）
  static const Logger _repairLogger = Logger('AppDatabase.repairSchema');

  @override
  int get schemaVersion => 51;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
          await _createV16Tables();
          await _createFactualIndexes();
        },
        onUpgrade: (m, from, to) async {
          // 降级打开（新版本库被旧应用打开）显式拒绝
          // 写版本号——repairSchema 的版本写入已按 from<to 守卫，此处先
          // 记日志明示，避免静默把迁移轨迹抹回旧版本。
          if (from > to) {
            _repairLogger.warn(
              'Database downgraded open: from=$from > to=$to '
              '(repair-only, user_version preserved)',
            );
          }
          // 增量迁移策略（用户明确要求：升级不丢数据，只扩展表结构）：
          // 任何旧 schemaVersion 升级到当前版本时，调用 [repairSchema] 做纯增量迁移：
          // 1. CREATE TABLE IF NOT EXISTS：创建缺失的表
          // 2. ALTER TABLE ADD COLUMN：补齐已存在表缺失的列
          //    （SQLite 限制：不能加 NOT NULL 无 DEFAULT、UNIQUE、PRIMARY KEY 约束，
          //     [repairSchema] 内部会自动移除这些约束降级为 nullable）
          // 3. CREATE INDEX IF NOT EXISTS：重建索引
          // 4. 重建 FTS5 虚拟表（如果不存在）
          // 5. PRAGMA user_version：更新 schemaVersion 到最新
          //
          // 历史上曾使用 DROP + 重建策略（2026-07-25 之前），导致用户升级后
          // 已有的会话、消息、API 配置等数据全部丢失，已被废弃。
          //
          // 与 [recreateConversationTables]（清除会话和消息功能）的区别：
          // - onUpgrade：增量迁移，不丢数据
          // - recreateConversationTables：DROP + CREATE，会丢数据（用户主动清空）
          //
          // dev 阶段多次加表加列时无需写逐版本迁移块，[repairSchema] 自动处理。
          // 正式发版前可重写为统一 MigrationStep（保留用户数据 + 增量迁移）。
          await repairSchema();
          // v36：事实层 source/sourceRef 列的显式迁移（回填 + DROP 旧唯一索引 + 重建）。
          // repairSchema 只做「加表/加列/IF NOT EXISTS 建索引」，不处理数据回填和
          // DROP 旧索引，故单独抽此方法（幂等）。
          await _migrateFactualSourceSchema();
          // v37：实体强制注入开关列回填（worldbook constant → forceInject=world）。
          await _migrateForceInjectSchema();
          // v44：watchMode 布尔 → tool_permissions 监督预设完整 map
          //（一次性物化，旧列保留不读；回填条件幂等）
          await _migrateDirectorToolPermissions();
          // v47 窗口：主名唯一索引全量 → partial（归档让名）。
          //  的 next_turn 列走 repairSchema 纯增量，47 号迁移块仅此步。
          await _migrateFactualArchivedNameIndex();
          // v32/v33 列改名回填：drafting_*/revise_* →
          // generating_*/reviewing_*（含 revise_enabled_override）当年只改了
          // Table 类未迁数据——跳跃/逐版升级后旧列值孤儿化，会话级步骤模型
          // 与审查开关静默回落全局。须后于 repairSchema（新列先补齐才有落位）。
          await _migrateSessionColumnRenames();
        },
        beforeOpen: (details) async {
          // 升级路径的 repairSchema 失败
          // 会被内部捕获（组件级 catch），而 user_version 由 drift 在
          // onUpgrade 结束后统一写回——此后 from==to，onUpgrade 不再执行，
          // 失败列永远不会被自动重试（修复表结构 UI 的文案却承诺
          // 「下次启动将自动重试」）。beforeOpen 每次打开数据库都会执行：
          // 幂等重跑 repairSchema 即兑现该承诺——缺列即刻补齐，仍失败则
          // 记日志并在下次启动继续重试。新库（onCreate）schema 完整，跳过。
          if (details.wasCreated) return;
          try {
            final result = await repairSchema();
            if (result.failedColumns.isNotEmpty) {
              _repairLogger.warn(
                'Schema repair at open has failed columns (will retry next launch)',
                detail: result.failedColumns.join(', '),
              );
            }
            // v50：embedding_dimensions 幂等回填——升级路径的行在
            // 此补齐；旧备份导入的行由导入侧同函数补齐。
            await backfillEmbeddingDimensions(this);
            // v47 窗口补跑：开发期已停在 47 的库不会再触发 onUpgrade，
            // 此处幂等补跑保证旧全量索引被替换为 partial 版（已是 partial
            // 则一次 sqlite_master 查询后跳过）。
            await _migrateFactualArchivedNameIndex();
            // beforeOpen 双入口——08 月期间正常逐版升级的设备已越过
            // v33（onUpgrade 版本守卫会跳过它们），按旧列存在性检测对全部
            // 形态收敛（新装无旧列跳过；已回填 UPDATE 匹配 0 行）。
            await _migrateSessionColumnRenames();
          } catch (e, s) {
            _repairLogger.error(
              'Schema repair at open failed',
              error: e,
              stackTrace: s,
            );
          }
        },
      );

  /// 创建所有索引（对齐 DOC-02 Section 6.4）
  Future<void> _createIndexes() async {
    // chat_messages 索引
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_msg_session_created '
      'ON chat_messages (session_id, created_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_msg_session_branch '
      'ON chat_messages (session_id, parent_user_msg_id, branch_index)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_msg_session_summary '
      'ON chat_messages (session_id, is_summary)',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_msg_message_id '
      'ON chat_messages (message_id)',
    );

    // compaction_points 索引
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cp_session_created '
      'ON compaction_points (session_id, created_at)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cp_summary_msg '
      'ON compaction_points (summary_message_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cp_boundary_msg '
      'ON compaction_points (boundary_message_id)',
    );

    // chat_session_branches 索引
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_csb_session_anchor '
      'ON chat_session_branches (session_id, anchor_user_msg_id)',
    );

    // v7: api_presets + templates 索引
    await _createV7Indexes();
  }

  /// 创建 v7 新增表的索引
  Future<void> _createV7Indexes() async {
    // api_presets 索引
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_ap_presets_id '
      'ON api_presets (preset_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ap_built_in '
      'ON api_presets (is_built_in)',
    );

    // templates 索引
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_tmpl_template_id '
      'ON templates (template_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_tmpl_kind '
      'ON templates (kind)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_tmpl_built_in '
      'ON templates (is_built_in)',
    );
  }

  /// 创建 memories_fts 虚拟表（FTS5 全文索引，v21 7 内容字段版本）
  ///
  /// v0.2 Phase C 方案二：FTS5 索引从单一 summary 字段扩展到
  /// 7 个内容字段（summary + when/where/who/what/significance/extra），
  /// 让所有 5W1E 字段都可被关键词检索召回。
  ///
  /// - 与 experiential_memories 同事务显式插入（非触发器）
  /// - tokenize='trigram'：支持中文检索（≥3 字符可命中；<3 字符此表尚无
  ///   LIKE 兜底——factual_fts 侧已实现短词 LIKE，见
  ///   FactualRepositoryImpl.searchWorldFacts，经历层待同类接线）
  /// - memory_id/memory_type/session_id 为 UNINDEXED（仅作为返回字段，不参与索引）
  ///
  /// 调用点：`onCreate`（via [_createV16Tables]）、`onUpgrade` v21、
  /// [recreateConversationTables]（via [_createV16Tables]）
  Future<void> _createMemoriesFtsTable() async {
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
        summary,
        when_text,
        where_text,
        who_text,
        what_text,
        significance,
        extra,
        memory_id UNINDEXED,
        memory_type UNINDEXED,
        session_id UNINDEXED,
        tokenize='trigram'
      )
    ''');
  }

  /// memories_fts 期望列全集（v21 七内容字段版本 + 3 个 UNINDEXED 键列）。
  static const List<String> _memoriesFtsColumns = [
    'summary',
    'when_text',
    'where_text',
    'who_text',
    'what_text',
    'significance',
    'extra',
    'memory_id',
    'memory_type',
    'session_id',
  ];

  /// FTS 形状漂移自愈。
  ///
  /// v16-20 时代的 memories_fts 是 4 列旧形状；统一增量迁移策略
  /// （IF NOT EXISTS 建表）修不了「已存在的旧形状表」——insertFtsIndex
  /// 的 10 列 INSERT 在轮事务内必败，故事轮持久化全链失效，
  /// 「修复表结构」UI 同走 repairSchema（同样无效），唯一出路此前是
  /// 清库。形状不符 → DROP 重建 + 从 experiential_memories 回填：
  /// FTS 是派生数据，重建不丢用户数据；importance>=3 对齐默认存储
  /// 门槛（importance_storage_threshold=3），低价值行维持不索引语义，
  /// 与用户自设门槛的差异由索引健康条一键补齐按现行配置收敛。
  Future<void> _ensureMemoriesFtsShape() async {
    final cols = await _getTableColumns('memories_fts');
    if (cols.length == _memoriesFtsColumns.length &&
        cols.containsAll(_memoriesFtsColumns)) {
      return;
    }
    _repairLogger.warn(
      'memories_fts shape drift detected, rebuilding from source rows',
      detail: 'columns=${cols.join(',')}',
    );
    await customStatement('DROP TABLE IF EXISTS memories_fts');
    await _createMemoriesFtsTable();
    await customStatement('''
      INSERT INTO memories_fts
        (summary, when_text, where_text, who_text, what_text, significance,
         extra, memory_id, memory_type, session_id)
      SELECT
        COALESCE(summary, ''), COALESCE(when_text, ''), COALESCE(where_text, ''),
        COALESCE(who_text, ''), COALESCE(what_text, ''),
        COALESCE(significance, ''), COALESCE(extra, ''),
        memory_id, 'experiential', session_id
      FROM experiential_memories
      WHERE importance >= 3
    ''');
  }

  /// 创建 v0.2 中级模式新增对象（FTS5 虚拟表 + experiential_memories 索引）
  ///
  /// drift Table 类不支持 FTS5，用 customStatement 手动建。
  /// Schema 依据：DOC-09C §5、DOC-08 §5.5、DOC-02 §6.4。
  Future<void> _createV16Tables() async {
    // memories_fts 虚拟表（FTS5 全文索引）
    // v21 重建：扩展到 7 内容字段（summary + 5W1E 6 字段）
    await _createMemoriesFtsTable();

    // experiential_memories 索引（对齐 DOC-02 §6.4 / DOC-08 §5.5）
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_exp_session_archived_imp '
      'ON experiential_memories (session_id, is_archived, importance)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_exp_session_turn '
      'ON experiential_memories (session_id, turn_number)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_exp_session_embedding '
      'ON experiential_memories (session_id, has_embedding)',
    );
    // idx_exp_session_period 推迟到 v0.3（I-18：narrative_period v0.2 恒 NULL）

    // 多粒度记忆索引（DOC-10 §3.2）：按会话 + 层级查询宏摘要
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_exp_session_level '
      'ON experiential_memories (session_id, memory_level)',
    );

    // failure_logs 索引（诊断包）：按会话过滤 + 按时间排序
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_fl_session_created '
      'ON failure_logs (session_id, created_at)',
    );

    // intermediate_round_artifacts 索引（持久化修复）：
    // 按会话 + 轮次号查询（loadHistory 批量加载用）
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_ira_session_turn '
      'ON intermediate_round_artifacts (session_id, turn_number)',
    );
  }

  /// 创建事实层 3 表的索引（DOC-11 §3.1 / §3.2）
  ///
  /// 调用点：`onCreate`、`onUpgrade` v22、[recreateConversationTables]
  Future<void> _createFactualIndexes() async {
    // factual_entities 索引
    // 主名唯一性约束（同会话内不能有同名【活跃】实体，防重复创建）。
    // （根治）：partial 索引 WHERE is_archived = 0——归档让名，
    // 归档实体释放主名（长会话归档堆不再占住世界书短通用词）。
    // 旧库的全量唯一索引由 [_migrateFactualArchivedNameIndex] 显式替换
    ///（IF NOT EXISTS 不会覆盖已存在的全量索引）。
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_factual_entities_session_name '
      'ON factual_entities (session_id, primary_name) WHERE is_archived = 0',
    );
    // 按会话 + 类型查询（UI 分组展示用）
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_factual_entities_session_type '
      'ON factual_entities (session_id, type)',
    );
    // 按会话 + 重要性查询（retrieving 阶段加载关键实体用）
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_factual_entities_session_importance '
      'ON factual_entities (session_id, importance)',
    );

    // factual_attributes 索引
    // 实体 + 属性键 + 来源唯一性约束（v36 起同实体同 key 可有多行，按 source 区分；
    // DOC-15 §8.1 方案 A：基线行 + auto 演变行并存）
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_factual_attrs_entity_key_source '
      'ON factual_attributes (entity_id, attr_key, source)',
    );
    // partial unique index：保证 auto 行仍唯一（同一实体同 key 至多一行 auto）
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_factual_attrs_entity_key_auto '
      "ON factual_attributes (entity_id, attr_key) WHERE source='auto'",
    );
    // 按会话 + 实体批量查询（retrieving 阶段批量加载属性用）
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_factual_attrs_session_entity '
      'ON factual_attributes (session_id, entity_id)',
    );

    // factual_memory_history 索引
    // 按实体查询审计历史（v0.3 HUD 用）
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_factual_history_entity '
      'ON factual_memory_history (entity_id, created_at)',
    );
    // 按实体 + 轮次查询最近更新次数（DOC-11 §7.4.5 更新频率限制用）
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_factual_history_entity_turn '
      'ON factual_memory_history (entity_id, turn_number)',
    );

    // factual_fts 虚拟表（世界书词条全文索引，DOC-15 §7.3）
    await _createFactualFtsTable();
  }

  /// 创建 factual_fts 虚拟表（FTS5，DOC-15 §7.3）
  ///
  /// 索引世界书 lore 实体的 primaryName + aliases + description（content），
  /// 供 retrieving 阶段关键词召回。tokenize='trigram' 支持中文检索。
  /// entity_id / session_id 为 UNINDEXED（仅作返回字段）。
  Future<void> _createFactualFtsTable() async {
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS factual_fts USING fts5(
        primary_name,
        aliases,
        description,
        entity_id UNINDEXED,
        session_id UNINDEXED,
        tokenize='trigram'
      )
    ''');
  }

  /// 重建会话和消息相关的所有表（DROP + CREATE）
  ///
  /// 用于「清除会话和消息」功能：DROP 所有会话/消息/故事模式相关表后重新创建，
  /// 同时确保 v16 新增表（failure_logs / intermediate_round_artifacts /
  /// memories_fts 虚拟表）在 v15 → v16 升级缺失时被修复。
  ///
  /// 与 deleteAllSessions 的区别：
  /// - deleteAllSessions 仅 DELETE 数据，不 DROP 表 → 无法修复表缺失
  /// - recreateConversationTables DROP + CREATE → 表结构同步至最新 schema
  ///
  /// 保留：apiPresetsTable（供应商配置）、templatesTable（系统提示词模板）
  Future<void> recreateConversationTables() async {
    await transaction(() async {
      // 1. DROP 顺序：先删虚拟表与附属表，再删主表（避免外键约束冲突，
      //    虽然本项目无数据库级外键，但保持顺序可读）
      await customStatement('DROP TABLE IF EXISTS memories_fts');
      await customStatement('DROP TABLE IF EXISTS factual_fts');
      await customStatement(
        'DROP TABLE IF EXISTS intermediate_round_artifacts',
      );
      // 变体表一并 DROP+重建——「清除所有数据」
      // 此前不 DROP 不重建，正文/思考/锚快照原样残留（名实矛盾）。
      await customStatement('DROP TABLE IF EXISTS message_variants');
      await customStatement('DROP TABLE IF EXISTS factual_memory_history');
      await customStatement('DROP TABLE IF EXISTS factual_attributes');
      await customStatement('DROP TABLE IF EXISTS factual_entities');
      await customStatement('DROP TABLE IF EXISTS experiential_memories');
      await customStatement('DROP TABLE IF EXISTS compaction_points');
      await customStatement('DROP TABLE IF EXISTS chat_session_branches');
      await customStatement('DROP TABLE IF EXISTS chat_messages');
      await customStatement('DROP TABLE IF EXISTS chat_sessions');
      await customStatement('DROP TABLE IF EXISTS failure_logs');
      //  修复：agent_events 一并清除——
      // 此前"清除会话和消息"后导演模式事件日志永久残留。
      await customStatement('DROP TABLE IF EXISTS agent_events');

      // 2. 重建表（用 drift Migrator API，确保 schema 与 Table 类定义一致）
      final m = createMigrator();
      await m.createTable(chatSessionsTable);
      await m.createTable(chatMessagesTable);
      await m.createTable(chatSessionBranchesTable);
      await m.createTable(compactionPointsTable);
      await m.createTable(experientialMemoriesTable);
      await m.createTable(factualEntitiesTable);
      await m.createTable(factualAttributesTable);
      await m.createTable(factualMemoryHistoryTable);
      await m.createTable(intermediateRoundArtifactsTable);
      // 变体表随重建
      await m.createTable(messageVariantsTable);
      await m.createTable(failureLogsTable);
      await m.createTable(agentEventsTable);

      // 3. 重建 FTS5 虚拟表 + 所有相关索引
      //    _createV16Tables() 创建 memories_fts + experiential_memories 索引
      //    + failure_logs 索引 + intermediate_round_artifacts 索引
      //    _createFactualIndexes() 创建事实层 3 表索引
      //    _createIndexes() 创建 chat_messages / compaction_points /
      //    chat_session_branches 索引（IF NOT EXISTS，已存在会跳过）
      await _createV16Tables();
      await _createFactualIndexes();
      await _createIndexes();
    });
  }

  /// 修复数据库表结构（纯增量，不删除数据）
  ///
  /// 适用场景：dev 阶段 schemaVersion 升级后，旧版调试设备的数据库
  /// 表结构与新 schema 不一致，但用户不想丢失已有数据（会话、API Key 等）。
  ///
  /// 执行步骤：
  /// 1. CREATE TABLE：创建缺失的表（用 Migrator.createTable）
  /// 2. ALTER TABLE ADD COLUMN：补齐已存在表缺失的列
  /// 3. CREATE INDEX IF NOT EXISTS：重建索引（已存在会跳过）
  /// 4. 重建 FTS5 虚拟表（如果不存在）
  /// 5. PRAGMA user_version：更新 schemaVersion 到最新
  ///
  /// **不修改**已有列的类型/约束（纯增量）。
  /// **不删除**任何数据。
  ///
  /// SQLite ALTER TABLE ADD COLUMN 限制：
  /// - 不能加 NOT NULL 约束（除非有 DEFAULT）
  /// - 不能加 UNIQUE 约束
  /// - 不能加 PRIMARY KEY 约束
  /// 本方法会自动移除这些约束（无 DEFAULT 的 NOT NULL 降级为 nullable）。
  Future<SchemaRepairResult> repairSchema() async {
    final createdTables = <String>[];
    final addedColumns = <String>[];
    final failedColumns = <String>[];
    final m = createMigrator();

    await transaction(() async {
      // 1. 创建缺失的表
      for (final table in allTables) {
        final tableName = table.actualTableName;
        final exists = await _tableExists(tableName);
        if (!exists) {
          await m.createTable(table);
          createdTables.add(tableName);
        }
      }

      // 2. 补齐已存在表缺失的列
      for (final table in allTables) {
        final tableName = table.actualTableName;
        final existingColumns = await _getTableColumns(tableName);

        for (final column in table.$columns) {
          if (!existingColumns.contains(column.name)) {
            // 用 drift 的 GenerationContext 生成列定义 SQL
            final context = GenerationContext.fromDb(this);
            column.writeColumnDefinition(context);
            var columnDef = context.sql;

            // 处理 SQLite ALTER TABLE ADD COLUMN 限制
            columnDef = _safeColumnDefForAlterTable(columnDef);

            try {
              await customStatement(
                'ALTER TABLE "$tableName" ADD COLUMN $columnDef',
              );
              addedColumns.add('$tableName.${column.name}');
            } catch (e) {
              // 某些列可能因约束冲突无法添加（如已有数据违反 NOT NULL）。
              //  修复：不再静默吞掉——记录错误并计入结果，
              // 由调用方（升级路径/修复表结构 UI）向用户暴露半迁移状态。
              // 注意：升级路径的 user_version 由 drift 在 onUpgrade 完成后
              // 统一写回，组件内跳过 PRAGMA 无法阻止；可见化 + 幂等重试
              // （repairSchema 方向无关，下次启动自动重试失败列）是可达的修复。
              failedColumns.add('$tableName.${column.name}');
              _repairLogger.error(
                'ALTER TABLE failed during schema repair',
                detail: '$tableName.${column.name}: $e',
                error: e,
              );
            }
          }
        }
      }

      // 3. 重建索引（CREATE INDEX IF NOT EXISTS，已存在会跳过）
      await _createIndexes();
      await _createV16Tables();
      await _createFactualIndexes();
      // 3.5 FTS 形状校验：v16-20 旧形状 memories_fts 在
      // IF NOT EXISTS 建表策略下永不自愈——形状不符即 DROP 重建+回填
      await _ensureMemoriesFtsShape();

      // 4. 更新 schemaVersion（：只在当前版本落后时写——旧实现无条件
      // 强写，未来 v47 库被当前 v46 应用打开时版本号被抹回 46，污染迁移
      // 轨迹；降级打开时保持原版本号原样，仅做自愈修复）
      final currentVersionRow = await customSelect('PRAGMA user_version').get();
      final currentVersion =
          currentVersionRow.first.data['user_version'] as int? ?? 0;
      if (currentVersion < schemaVersion) {
        await customStatement('PRAGMA user_version = $schemaVersion');
      }
    });

    return SchemaRepairResult(
      createdTables: createdTables,
      addedColumns: addedColumns,
      failedColumns: failedColumns,
      updatedSchemaVersion: schemaVersion,
    );
  }

  /// v36 显式迁移：事实层 source/sourceRef 列的数据回填 + 索引重建（幂等）
  ///
  /// [repairSchema] 只能「加表 / 加列 / IF NOT EXISTS 建索引」，无法：
  /// 1. 回填存量行的 `source` 列（若 ALTER 时未带 DEFAULT，旧行为 NULL）；
  /// 2. DROP 旧的唯一索引 `idx_factual_attrs_entity_key(entity_id, attr_key)`，
  ///    它硬约束「同实体同 key 单行」，与 v36 基线 + 演变双行模型冲突。
  ///
  /// 故单独抽此方法，在 onUpgrade 的 repairSchema 之后调用（幂等，重复调用无害）。
  Future<void> _migrateFactualSourceSchema() async {
    // 1. DROP 旧唯一索引（若存在）；新复合/partial 索引由 _createFactualIndexes 建
    await customStatement(
      'DROP INDEX IF EXISTS idx_factual_attrs_entity_key',
    );
    // 2. 回填 source 列（新列若 ALTER 时无 DEFAULT，存量行为 NULL/空）
    await customStatement(
      "UPDATE factual_entities SET source='auto' WHERE source IS NULL OR source=''",
    );
    await customStatement(
      "UPDATE factual_attributes SET source='auto' WHERE source IS NULL OR source=''",
    );
  }

  /// v37 显式迁移：实体强制注入开关列回填（幂等）
  ///
  /// [repairSchema] 只加列，不做数据回填。此处把 v36 前世界书 constant
  /// 词条（以 importance=5 区分）迁成「开关 world + 评分 2」。
  Future<void> _migrateForceInjectSchema() async {
    // 1. 兜底：新列若存在 NULL/空，归位 none
    await customStatement(
      "UPDATE factual_entities SET force_inject='none' "
      "WHERE force_inject IS NULL OR force_inject=''",
    );
    // 2. constant 词条：worldbook + importance=5 → forceInject=world, importance=2
    await customStatement(
      "UPDATE factual_entities SET force_inject='world', importance=2 "
      "WHERE source='worldbook' AND importance=5",
    );
  }

  /// 仅测试可见的迁移入口（供集成测试直接触发回填）
  @visibleForTesting
  Future<void> migrateForceInjectForTest() => _migrateForceInjectSchema();

  /// v44 显式迁移：watchMode 布尔 → tool_permissions 监督预设完整 map（幂等）
  ///
  /// watch_mode=1 的存量导演会话物化「监督模式」12 工具完整 map；
  /// false/null 保持 NULL（跟随全局）。旧 watch_mode 列保留不删不读
  /// （AGENTS.md 保数据要求）。回填条件带 tool_permissions IS NULL，重跑安全。
  Future<void> _migrateDirectorToolPermissions() async {
    await customStatement(
      'UPDATE chat_sessions SET tool_permissions = ? '
      "WHERE watch_mode = 1 AND (tool_permissions IS NULL OR tool_permissions = '')",
      [jsonEncode(ToolPermissions.supervised)],
    );
  }

  /// 仅测试可见的迁移入口（供集成测试直接触发回填）
  @visibleForTesting
  Future<void> migrateDirectorToolPermissionsForTest() =>
      _migrateDirectorToolPermissions();

  /// v32/v33 列改名回填映射。
  ///
  /// 2026-08-01（23c0fc9c，v0.2.2 术语同步）把五列改名时只改了 drift
  /// Table 类的 getter 名，无任何数据迁移：repairSchema 按新名补出全
  /// NULL 新列，旧列未删未回填——停在 v23-31 的库跳跃升级（或 08 月
  /// 期间逐版升级）后，用户为会话配的分步骤模型与审查开关留在旧列，
  /// 静默回落全局默认。
  ///
  /// 检测条件用「旧列存在性」而非 from<33 版本守卫：正常逐版升级的设备
  /// user_version 已越过 v33，版本守卫会漏掉它们。幂等：新列非 NULL 不
  /// 覆盖（改名后用户又改过的值优先），旧列保留不删（保数据铁律，
  /// watch_mode 同口径）；备份 _restoreTable 按现行表结构白名单过滤旧列，
  /// 回填后新列已带值，round-trip 无损。
  static const Map<String, String> _sessionColumnRenames = {
    'drafting_preset_id': 'generating_preset_id',
    'drafting_model_id': 'generating_model_id',
    'revising_preset_id': 'reviewing_preset_id',
    'revising_model_id': 'reviewing_model_id',
    'revise_enabled_override': 'review_enabled_override',
  };

  Future<void> _migrateSessionColumnRenames() async {
    final cols = await _getTableColumns('chat_sessions');
    for (final entry in _sessionColumnRenames.entries) {
      if (!cols.contains(entry.key) || !cols.contains(entry.value)) continue;
      await customStatement(
        'UPDATE chat_sessions SET "${entry.value}" = "${entry.key}" '
        'WHERE "${entry.value}" IS NULL AND "${entry.key}" IS NOT NULL',
      );
    }
  }

  /// 仅测试可见的迁移入口（供迁移测试直接触发）
  @visibleForTesting
  Future<void> migrateSessionColumnRenamesForTest() =>
      _migrateSessionColumnRenames();

  /// v47 窗口（根治）：主名唯一索引全量 → partial（归档让名）。
  ///
  /// [_createFactualIndexes] 的 CREATE ... IF NOT EXISTS 不会覆盖旧库
  /// 已存在的全量索引，必须显式 DROP 后按 partial 版重建。幂等：索引
  /// 已是 partial（sqlite_master 的 sql 含 is_archived 条件）则跳过，
  /// 故 onUpgrade 与 beforeOpen 双入口重跑无害。既有数据不会违反
  /// partial 约束（活跃同名行在旧全量索引下本就不可能存在）。
  Future<void> _migrateFactualArchivedNameIndex() async {
    final existing = await customSelect(
      'SELECT sql FROM sqlite_master '
      "WHERE type='index' AND name='idx_factual_entities_session_name'",
    ).get();
    if (existing.isNotEmpty) {
      final sql = existing.first.data['sql'] as String? ?? '';
      if (sql.contains('is_archived')) return; // 已是 partial 版
    }
    await customStatement(
      'DROP INDEX IF EXISTS idx_factual_entities_session_name',
    );
    await customStatement(
      'CREATE UNIQUE INDEX idx_factual_entities_session_name '
      'ON factual_entities (session_id, primary_name) WHERE is_archived = 0',
    );
  }

  /// 仅测试可见的迁移入口（供迁移测试直接触发）
  @visibleForTesting
  Future<void> migrateFactualArchivedNameIndexForTest() =>
      _migrateFactualArchivedNameIndex();

  /// 检查表是否存在
  Future<bool> _tableExists(String tableName) async {
    final result = await customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      variables: [Variable.withString(tableName)],
    ).get();
    return result.isNotEmpty;
  }

  /// 获取表的现有列名集合
  Future<Set<String>> _getTableColumns(String tableName) async {
    final result = await customSelect(
      'PRAGMA table_info("$tableName")',
    ).get();
    return result.map((row) => row.read<String>('name')).toSet();
  }

  /// 使列定义安全适用于 ALTER TABLE ADD COLUMN
  ///
  /// SQLite 限制：
  /// - 不能加 NOT NULL 约束（除非有 DEFAULT）
  /// - 不能加 UNIQUE 约束
  /// - 不能加 PRIMARY KEY 约束
  ///
  /// 处理策略：
  /// - NOT NULL 无 DEFAULT → 移除 NOT NULL（降级为 nullable）
  /// - NOT NULL 有 DEFAULT → 保留（SQLite 允许）
  /// - UNIQUE → 移除
  /// - PRIMARY KEY → 移除
  String _safeColumnDefForAlterTable(String columnDef) {
    var def = columnDef;
    final hasDefault = def.toUpperCase().contains('DEFAULT');

    // NOT NULL 无 DEFAULT → 移除 NOT NULL
    if (!hasDefault && def.toUpperCase().contains('NOT NULL')) {
      def = def.replaceAll(RegExp(r'NOT\s+NULL', caseSensitive: false), '');
    }

    // 移除 UNIQUE
    def = def.replaceAll(RegExp(r'\bUNIQUE\b', caseSensitive: false), '');

    // 移除 PRIMARY KEY
    def =
        def.replaceAll(RegExp(r'\bPRIMARY\s+KEY\b', caseSensitive: false), '');

    // 清理多余空格
    def = def.replaceAll(RegExp(r'\s+'), ' ').trim();

    return def;
  }
}

/// 打开数据库连接
///
/// 通过条件导入（`database_connection.dart` / `database_connection_web.dart`）
/// 在编译期选择平台实现：
/// - 原生平台：`NativeDatabase` + 文件系统
/// - Web 平台：`WasmDatabase` + IndexedDB
LazyDatabase _openConnection() {
  return LazyDatabase(createDatabaseExecutor);
}
