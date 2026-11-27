import 'package:lmstory/features/chat/domain/entities/chat_message.dart';

/// 数据导出选项
///
/// 控制全量导出时包含哪些数据类型。三类数据可任意组合，
/// [includeApiKeys] 仅在 [includePresets] 为 true 时才有意义。
class DataExportOptions {
  const DataExportOptions({
    required this.includeSessions,
    required this.includePresets,
    required this.includePreferences,
    this.includeApiKeys = false,
    this.includeGlobalAssets = true,
  });

  /// 是否导出会话（含消息）
  final bool includeSessions;

  /// 是否导出 API 供应商
  final bool includePresets;

  /// 是否导出个人偏好
  final bool includePreferences;

  /// 是否包含 API Key（敏感信息）
  ///
  /// 仅当 [includePresets] 为 true 时才生效。
  final bool includeApiKeys;

  /// 是否包含全局世界资产（角色卡/世界书/自建模板）
  ///
  /// 默认 true（快照/自动备份 const 构造零改动）；「仅偏好」类导出取消
  /// 勾选后文件不再携带全部世界书正文。导出侧缺键导入完全兼容（v3 导入
  /// 对缺省键本就跳过）。
  final bool includeGlobalAssets;

  /// 是否至少选择了一项可导出内容
  ///
  /// 注意：includeGlobalAssets 不参与判定（它不是独立可导出的用户数据面）
  bool get isEmpty =>
      !includeSessions && !includePresets && !includePreferences;
}

/// 单会话导出格式
enum SessionExportFormat {
  /// JSON 格式（机器可读，可再导入）
  json,

  /// Markdown 格式（人类可读，便于分享）
  markdown,

  /// 纯文本格式（最简单兼容性）
  text,
}

/// 导入模式
enum ImportMode {
  /// 追加：按业务 ID 去重，已存在的跳过，只导入新的
  append,

  /// 覆盖：清空备份包含的数据类型，再用备份重建
  overwrite,
}

/// 活动经历的所属会话与备份包装或已写入的数据冲突。
class BackupExperienceIdConflictException extends FormatException {
  const BackupExperienceIdConflictException()
      : super(
          'Cannot overwrite because different sessions share an experience ID',
        );

  const BackupExperienceIdConflictException.ownerMismatch()
      : super('Backup experience row does not belong to its session');

  const BackupExperienceIdConflictException.existingOwner()
      : super('Backup experience ID belongs to another session');
}

/// 同一会话的一轮中存在无法分别寻址的稿件。
final class BackupDraftIndexConflictException extends FormatException {
  const BackupDraftIndexConflictException()
      : super('Multiple drafts in one round share the same index');
}

/// 导入结果汇总
class ImportResult {
  const ImportResult({
    required this.importedPresets,
    required this.skippedPresets,
    required this.importedSessions,
    required this.skippedSessions,
    required this.importedMessages,
    required this.importedPreferences,
    required this.skippedPreferences,
    required this.mode,
    this.importedAssets = 0,
    this.importedApiKeys = 0,
    this.skippedMessages = 0,
    this.skippedAssets = 0,
    this.skippedSessionRows = 0,
  });

  final int importedPresets;
  final int skippedPresets;
  final int importedSessions;
  final int skippedSessions;
  final int importedMessages;
  final int skippedMessages;
  final int skippedSessionRows;
  final int importedPreferences;
  final int skippedPreferences;
  final ImportMode mode;

  /// v3 全局资产实际插入行数（角色卡+世界书+自建模板+导演事件日志）
  final int importedAssets;
  final int skippedAssets;

  /// 实际写入的 API Key 条数——追加模式下供应商全部已存在被跳过时为 0，
  /// 摘要不得宣称「已导入并覆盖」（此前只看勾选与备份内容，误导排查）
  final int importedApiKeys;

  /// 是否没有任何变更
  bool get isNoOp =>
      importedPresets == 0 &&
      skippedPresets == 0 &&
      importedSessions == 0 &&
      skippedSessions == 0 &&
      importedMessages == 0 &&
      skippedMessages == 0 &&
      skippedSessionRows == 0 &&
      importedPreferences == 0 &&
      skippedPreferences == 0 &&
      importedAssets == 0 &&
      skippedAssets == 0;
}

/// 存储统计信息
class StorageStats {
  const StorageStats({
    required this.dbSizeBytes,
    required this.sessionCount,
    required this.messageCount,
    required this.presetCount,
    required this.templateCount,
    required this.preferenceCount,
    this.agentEventCount = 0,
    this.agentEventBytes = 0,
    this.variantCount = 0,
  });

  /// 数据库文件大小（字节）
  final int dbSizeBytes;

  /// 会话数量
  final int sessionCount;

  /// 消息数量
  final int messageCount;

  /// API 供应商数量
  final int presetCount;

  /// 模板数量
  final int templateCount;

  /// 用户偏好覆盖项数量
  final int preferenceCount;

  /// 导演事件日志行数
  final int agentEventCount;

  /// 导演事件日志 data 负载近似字节数
  final int agentEventBytes;

  /// 稿件变体行数（：变体含正文/思考/锚快照，
  /// 存储膨胀须可见——与  的删除链修复互相配合）
  final int variantCount;

  /// 人类可读的事件日志大小
  String get agentEventSizeFormatted => formatBytes(agentEventBytes);

  /// 字节 → 人类可读（与 [dbSizeFormatted] 同口径；0 = 平台不可测常态）
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return unitIndex <= 1
        ? '${size.toInt()} ${units[unitIndex]}'
        : '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  /// 人类可读的数据库大小（如 "1.2 MB"）
  ///
  /// 0 字节（Web 平台 IndexedDB 无法测量的常态 / 原生库缺失）显示
  /// 占位符而非误导性的 "0 B"。
  String get dbSizeFormatted {
    if (dbSizeBytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = dbSizeBytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return unitIndex <= 1
        ? '${size.toInt()} ${units[unitIndex]}'
        : '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }
}

/// 孤立消息组
///
/// 表示一组 sessionId 在 chat_sessions 表中已不存在的消息。
/// 用于数据恢复功能：将这些消息重新组织成新会话。
class OrphanMessageGroup {
  const OrphanMessageGroup({
    required this.orphanSessionId,
    required this.messages,
  });

  /// 孤立消息所属的 sessionId（在 chat_sessions 表中已不存在）
  final String orphanSessionId;

  /// 该 sessionId 下的所有孤立消息（按时间升序）
  final List<ChatMessage> messages;

  /// 最早消息时间
  DateTime? get earliestTime => messages.isEmpty
      ? null
      : messages.map((m) => m.createdAt).reduce(
            (a, b) => a.isBefore(b) ? a : b,
          );

  /// 最晚消息时间
  DateTime? get latestTime => messages.isEmpty
      ? null
      : messages.map((m) => m.createdAt).reduce(
            (a, b) => a.isAfter(b) ? a : b,
          );

  /// 消息数量
  int get messageCount => messages.length;
}

/// 数据库表结构修复结果
///
/// 记录增量修复操作的详细变更，用于 UI 展示修复报告。
///
/// 纯增量修复（不删除已有数据）：
/// - [createdTables]：原本不存在的表，用 CREATE TABLE IF NOT EXISTS 创建
/// - [addedColumns]：已存在表缺失的列，用 ALTER TABLE ADD COLUMN 补齐
///   格式为 "表名.列名"
/// - [updatedSchemaVersion]：修复后的 schemaVersion 值
///
/// 不会修改已有列的类型/约束，不会删除任何数据。
class SchemaRepairResult {
  const SchemaRepairResult({
    this.createdTables = const [],
    this.addedColumns = const [],
    this.failedColumns = const [],
    this.updatedSchemaVersion = 0,
  });

  /// 新建的表名列表
  final List<String> createdTables;

  /// 新增的列列表（格式："表名.列名"）
  final List<String> addedColumns;

  /// 添加失败的列列表（修复 2026-08-23：不再静默吞掉 ALTER 失败）
  ///
  /// 格式同 [addedColumns]。非空即代表数据库处于半迁移状态，
  /// 下次启动会自动重试（repairSchema 幂等），但相关功能可能异常。
  final List<String> failedColumns;

  /// 修复后的 schemaVersion
  final int updatedSchemaVersion;

  /// 是否没有任何变更
  bool get isNoOp =>
      createdTables.isEmpty && addedColumns.isEmpty && failedColumns.isEmpty;

  /// 是否存在添加失败的列
  bool get hasFailures => failedColumns.isNotEmpty;

  /// 变更总数
  int get totalChanges =>
      createdTables.length + addedColumns.length + failedColumns.length;
}
