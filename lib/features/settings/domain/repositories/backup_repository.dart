import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';

/// 数据备份仓储接口
///
/// 专用于数据导入/导出的批量数据访问，提供跨表的原始数据读写能力。
/// 与业务 Repository（ChatRepository / ExperienceRepository 等）分离，
/// 避免在业务接口中堆积导入/导出专用的批量方法。
///
/// 所有方法操作原始行数据（Map<String, dynamic>），保留原始业务 ID，
/// 确保导出再导入后数据完全无损（ID 引用关系、分支结构、记忆关联等不变）。
///
/// 数据格式约定：
/// - DateTime 字段：ISO-8601 字符串
/// - Boolean 字段：0/1 整数（SQLite 原生存储格式）
/// - BLOB 字段（embedding）：base64 编码字符串
/// - JSON 字符串字段（tags/aliases 等）：保持原始 JSON 字符串
abstract class BackupRepository {
  /// 导出单个会话的所有关联数据（跨全部表）
  ///
  /// 返回的 Map 包含以下 key：
  /// - session: chat_sessions 行（原始字段）
  /// - messages: chat_messages 行列表（含摘要消息，不过滤）
  /// - compactionPoints: compaction_points 行列表
  /// - forkBranches: chat_session_branches 行列表
  /// - experientialMemories: experiential_memories 行列表（embedding 已 base64）
  /// - factualEntities: factual_entities 行列表
  /// - factualAttributes: factual_attributes 行列表
  /// - factualHistory: factual_memory_history 行列表
  /// - intermediateArtifacts: intermediate_round_artifacts 行列表
  /// - failureLogs: failure_logs 行列表（仅该会话）
  Future<Map<String, dynamic>> exportSessionData(String sessionId);

  /// 导出所有会话的所有关联数据
  ///
  /// 返回的列表中每个元素等同于 [exportSessionData] 的返回值。
  Future<List<Map<String, dynamic>>> exportAllSessionsData();

  /// 导入单个会话的备份数据（保留原始 ID）
  ///
  /// 步骤：
  /// 1. （覆盖模式）删除目标 sessionId 的所有现有数据
  /// 2. 插入 session 行（保留原始 sessionId）
  /// 3. 插入 messages（保留原始 messageId）
  /// 4. 插入 compactionPoints / forkBranches
  /// 5. 插入 experientialMemories（保留原始 memoryId，恢复 embedding BLOB）
  /// 6. 插入 factualEntities / factualAttributes / factualHistory
  /// 7. 插入 intermediateArtifacts
  /// 8. 重建 FTS5 索引
  ///
  /// [data] 为 [exportSessionData] 返回格式的 Map。
  /// [mode] 为追加或覆盖模式。追加模式下 sessionId 已存在则跳过，返回 0。
  ///
  /// 返回**实际插入的消息条数**（修复 2026-08-23：OR IGNORE 撞 ID 时
  /// 行被静默跳过，按备份长度计数会虚报——现以 sqlite changes() 为准；
  /// -1 = 追加模式下 sessionId 已存在被跳过；0 = 导入成功但消息为空/全冲突）。
  Future<int> importSessionData(
    Map<String, dynamic> data, {
    required ImportMode mode,
  });

  /// 删除单个会话的所有关联数据（跨全部表，含 FTS5 索引）
  Future<void> deleteSessionData(String sessionId);

  /// 删除所有会话的所有关联数据（跨全部表，含 FTS5 索引）
  ///
  /// 保留 api_presets / templates / user_overrides（非会话级数据）。
  Future<void> deleteAllSessionData();

  // rebuildFtsIndex/rebuildAllFtsIndex 两死方法已删
  //（零调用方，且 memory_type 列口径与活代码 memory_fts_rebuilder 冲突——
  // 死代码写 memory_level 值、活代码写 'experiential'；FTS 重建唯一正路
  // 是 lib/features/memory/data/repositories/memory_fts_rebuilder.dart）。

  // ==================== 供应商数据 ====================

  /// 导出所有供应商（含内置和自定义，原始行数据）
  ///
  /// 返回 api_presets 表的全部行，保留 presetId / protocol / templateId /
  /// providerOptions / cachedModels 等全部字段。
  /// API Key 不在此处导出（由 DataManagementService 通过 SettingsRepository 处理）。
  Future<List<Map<String, dynamic>>> exportAllPresets();

  /// 导入供应商（保留原始 presetId）
  ///
  /// [mode] 为追加或覆盖模式。
  /// 追加模式：presetId 已存在则跳过，返回 false。
  /// 覆盖模式：先删除自定义供应商再插入。
  /// 内置供应商始终跳过（应用启动时自动创建）。
  Future<bool> importPreset(
    Map<String, dynamic> data, {
    required ImportMode mode,
  });

  /// 删除所有自定义供应商（保留内置）
  Future<void> deleteAllCustomPresets();

  // ==================== 全局资产（v3 备份格式） ====================

  /// 导出全局资产：角色卡 / 世界书 / 自建提示词模板 / 导演事件日志
  ///
  /// 全量备份（backupVersion 3）新增的四类非会话级资产，原始行级 dump：
  /// - characterCards：character_cards 全表
  /// - worldbooks：worldbooks 全表
  /// - userTemplates：templates 表自建行（is_built_in = 0，内置模板不入备份）
  /// - agentEvents：agent_events 全表（[includeAgentEvents] 为 false 时省略键）
  ///
  /// 行级 dump 自动跟随 schema（SELECT * + 导入列白名单），表结构变更
  /// 无需同步改本方法。
  Future<Map<String, List<Map<String, dynamic>>>> exportGlobalAssets({
    bool includeAgentEvents = true,
  });

  /// 导入全局资产（v3 键，v2 备份缺键走空清单自然兼容）
  ///
  /// [data] 含 characterCards / worldbooks / userTemplates / agentEvents
  /// 中至少一个键即可；逐表走列白名单恢复（INSERT OR IGNORE，撞 ID
  /// 静默跳过）。覆盖模式下先删除对应表现有数据（templates 仅删自建行，
  /// 内置保留）。
  ///
  /// 返回实际插入的总行数。
  Future<int> importGlobalAssets(
    Map<String, dynamic> data, {
    required ImportMode mode,
  });
}
