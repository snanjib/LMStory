import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/services/data_store_operation_guard.dart';
import 'package:lmstory/core/utils/json_depth_guard.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/message_attachment.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/agent_events_usage_port.dart';
import 'package:lmstory/features/settings/domain/services/message_variants_count_port.dart';
import 'package:lmstory/features/settings/domain/services/session_export_formatter.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:uuid/uuid.dart';

export 'package:lmstory/features/settings/domain/entities/data_management_models.dart'
    show BackupDraftIndexConflictException, BackupExperienceIdConflictException;

part 'backup_import_execution.dart';
part 'backup_import_plan.dart';
part 'backup_import_settings.dart';
part 'backup_recovery_readback.dart';
part 'backup_session_rows.dart';

/// 同一数据存储上的写入或覆盖操作仍在进行，暂不能覆盖导入。
final class BackupOverwriteBusyException implements Exception {
  const BackupOverwriteBusyException();
}

/// 无法保护当前覆盖范围内的旧数据。
final class BackupSnapshotException implements Exception {
  const BackupSnapshotException();
}

/// 导入失败后无法确认原数据已恢复，用户可通过已有快照恢复。
final class BackupRollbackException implements Exception {
  const BackupRollbackException();
}

/// 备份版本需要更新的应用。
final class BackupVersionTooNewException extends FormatException {
  BackupVersionTooNewException(this.version)
      : super(
          'Backup version $version is newer than supported '
          '(${DataManagementService.backupVersion}); please upgrade the app first.',
        );

  final int version;
}

/// 文件可以解析，但没有能写入恢复库的内容。
final class BackupNoRestorableDataException extends FormatException {
  const BackupNoRestorableDataException()
      : super('Backup contains no restorable data');
}

/// 数据管理服务
///
/// 统一封装数据导入/导出/统计/恢复的业务逻辑。
/// 文件 IO（读写文件、系统分享）由调用方（Presentation 层）负责，
/// 本服务只负责数据组装、解析、合并、去重等纯业务逻辑。
///
/// v3 备份格式（backupVersion=3）：
/// - v2 全量数据（会话/供应商/偏好，行级读写保留原始 ID）之上新增
///   全局资产四类：characterCards / worldbooks / userTemplates（自建模板）/
///   agentEvents（导演事件日志行级 dump，自动跟随 schema）
/// - 向后兼容：v2 备份导入时新键缺省走空清单；v1 旧格式走旧导入链
/// - 命名注意：backupVersion 是 LMStory 项目自己的备份格式版本号，
///   与世界书/角色卡的 SillyTavern 卡规范版本（卡 JSON 内 spec_version
///   v1/v2/v3）完全无关，两者不得混用
class DataManagementService {
  DataManagementService({
    required this.chatRepository,
    required this.presetRepository,
    required this.settingsRepository,
    required this.backupRepository,
    AgentEventsUsagePort? agentEventsUsagePort,
    MessageVariantsCountPort? messageVariantsCountPort,
    DataStoreOperationGuard? operationGuard,
  })  : _agentEventsUsagePort = agentEventsUsagePort,
        _messageVariantsCountPort = messageVariantsCountPort,
        _operationGuard = operationGuard ?? DataStoreOperationGuard();

  /// JSON 嵌套深度超限的导入错误文案（主链抛出与页面预检提前拒绝共用，
  /// 随当前 UI 语言）。
  static String get depthLimitMessage => t.settings.data.backupTooDeep;

  /// 判定 JSON 内容是否为应用数据备份（全量或单会话导出，v1/v2/v3）。
  ///
  /// 外部"打开方式/分享"的 JSON 先经此分流再走资源库导入——备份的顶层
  /// 结构（如 data/entries 等载荷键）会命中角色卡/世界书的启发式判定，
  /// 不分流会被误导入资源库。识别特征：顶层 `version` 为 int（导出链路
  /// 专有键，SillyTavern 卡用的是字符串 `spec_version`）且带有
  /// exportedAt / sessions / presets / preferences 任一载荷键——后者
  /// 排除恰好带 version 字段的第三方资源格式（如个别世界书）。
  static bool looksLikeAppBackupJson(String content) {
    var source = content;
    if (source.startsWith('\uFEFF')) source = source.substring(1);
    // 深度粗检先于 jsonDecode（与资源导入入口同口径）：超深内容不判为
    // 备份，交还资源导入链以其明确的深度错误拒绝。
    if (exceedsMaxDepth(source)) return false;
    final dynamic root;
    try {
      root = jsonDecode(source);
    } on FormatException {
      return false;
    }
    if (root is! Map<String, dynamic>) return false;
    if (root['version'] is! int) return false;
    return _BackupImportPlan.hasBackupFields(root);
  }

  final ChatRepository chatRepository;
  final ApiPresetRepository presetRepository;
  final SettingsRepository settingsRepository;
  final BackupRepository backupRepository;
  final DataStoreOperationGuard _operationGuard;

  /// 导演事件日志用量端口（批 I 存储统计；可选——测试桩可不提供）。
  /// 此前直接依赖 advanced/data 仓库实现，属
  /// features 内 domain→data 违例，改为域内声明的最小端口。
  final AgentEventsUsagePort? _agentEventsUsagePort;

  /// 稿件变体行数端口。
  final MessageVariantsCountPort? _messageVariantsCountPort;

  /// 备份格式版本（v3：v2 全量数据 + 全局资产四类）
  ///
  /// 注意：这是项目自己的备份格式版本号，与 SillyTavern 卡规范
  /// spec_version 无关——见类注释「命名注意」。
  static const int backupVersion = 3;

  static const _uuid = Uuid();

  // ==================== 导出 ====================

  /// 全量导出为 JSON 字符串
  ///
  /// 根据 [options] 决定导出哪些数据类型。返回的 JSON 符合 LMStory v3 备份格式
  ///（v3：全局资产四类——角色卡/世界书/自建模板/导演事件日志——随全量导出，
  /// 与 options 无关：它们是用户资产而非敏感配置，且行级 dump 体量可控）。
  Future<String> exportFullBackup(DataExportOptions options) async {
    final backupData = <String, dynamic>{
      'version': backupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
    };

    if (options.includePresets) {
      backupData['presets'] = await _exportPresets(options.includeApiKeys);
      // K5 修复：含 Key 导出时在文件头打显式标记——
      // 用户随手把备份传网盘/发给别人前，工具与人都该能一眼识别风险。
      if (options.includeApiKeys) {
        backupData['contains_secrets'] = true;
      }
    }
    if (options.includeSessions) {
      backupData['sessions'] = await backupRepository.exportAllSessionsData();
    }
    if (options.includePreferences) {
      backupData['preferences'] = await settingsRepository.getUserOverrides();
    }
    // v3：全局资产四类（角色卡/世界书/自建模板/导演事件日志）。
    // 行级 dump 经 BackupRepository 导出清单取数（自动跟随 schema；
    // 事件日志读写代码归并行会话，此处不触碰）。agentEvents 仅随
    // 会话导出——无会话数据的备份不需要事件日志。
    // 全局资产可勾选排除（默认包含）。
    if (options.includeGlobalAssets) {
      final globalAssets = await backupRepository.exportGlobalAssets();
      backupData['characterCards'] = globalAssets['characterCards'] ?? [];
      backupData['worldbooks'] = globalAssets['worldbooks'] ?? [];
      backupData['userTemplates'] = globalAssets['userTemplates'] ?? [];
      if (options.includeSessions) {
        backupData['agentEvents'] = globalAssets['agentEvents'] ?? [];
      }
    }

    return const JsonEncoder.withIndent('  ').convert(backupData);
  }

  /// 导出单个会话为 JSON 字符串（v3 格式，含全部关联数据——会话九表
  /// 与导演事件日志 agentEvents，见 ）
  Future<String> exportSessionAsJson(String sessionId) async {
    final sessionData = await backupRepository.exportSessionData(sessionId);

    final backupData = <String, dynamic>{
      'version': backupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'sessions': [sessionData],
    };

    return const JsonEncoder.withIndent('  ').convert(backupData);
  }

  /// 导出单个会话为 Markdown
  Future<String> exportSessionAsMarkdown(String sessionId) async {
    final session = await chatRepository.getSession(sessionId);
    final messages = await chatRepository.getMessages(sessionId);
    return SessionExportFormatter.toMarkdown(session, messages);
  }

  /// 导出单个会话为纯文本
  Future<String> exportSessionAsText(String sessionId) async {
    final session = await chatRepository.getSession(sessionId);
    final messages = await chatRepository.getMessages(sessionId);
    return SessionExportFormatter.toText(session, messages);
  }

  // ==================== 导入 ====================

  /// 解析备份结构并检查版本，不访问数据库或设置存储。
  static ({int? version, DateTime? exportedAt}) validateBackup(
    String jsonContent,
  ) {
    final plan = _BackupImportPlan.decode(jsonContent, strictCollections: true);
    return (version: plan.version, exportedAt: plan.exportedAt);
  }

  /// 读取可恢复内容的元数据及预检识别的跳过项，供开库失败时使用。
  static ({int? version, DateTime? exportedAt, int skippedItems})
      inspectRecoveryBackup(String content) {
    final plan = _recoveryPlan(content);
    return (
      version: plan.version,
      exportedAt: plan.exportedAt,
      skippedItems: plan.skippedItems,
    );
  }

  static _BackupImportPlan _recoveryPlan(String content) {
    final plan = _BackupImportPlan.decode(content, strictCollections: true);
    if (!plan.hasRestorableData) throw const BackupNoRestorableDataException();
    return plan;
  }

  /// 从本服务连接的隔离试库重新导出会话，核对每个预期会话及其恢复行。
  Future<void> verifyRecoveryReadback(String content) =>
      _verifyRecoverySessions(_recoveryPlan(content));

  /// 预导入快照必须是当前版本的完整导出，且供应商行不携带凭据。
  static void validatePreImportSnapshot(String jsonContent) {
    _BackupImportPlan.decode(jsonContent, preImportSnapshot: true);
  }

  /// 导入 v1 / v2 / v3 备份及未标版本的旧会话。
  ///
  /// 覆盖会触及已有数据时，[preImportSnapshot] 必须先完成可读回的备份。
  /// 写入、异常补偿和读回都在同一数据存储的覆盖许可内完成。
  Future<ImportResult> importBackup(
    String jsonContent,
    ImportMode mode, {
    Future<void> Function()? preImportSnapshot,
    bool importApiKeys = false,
  }) async {
    return _importPlan(
      _BackupImportPlan.decode(jsonContent, importMode: mode),
      mode,
      preImportSnapshot: preImportSnapshot,
      importApiKeys: importApiKeys,
    );
  }

  /// 写入隔离恢复试库，与恢复预检和读回使用同样的严格解析规则。
  Future<ImportResult> importRecoveryTrial(String content) async {
    return _importPlan(_recoveryPlan(content), ImportMode.overwrite);
  }

  Future<ImportResult> _importPlan(
    _BackupImportPlan plan,
    ImportMode mode, {
    Future<void> Function()? preImportSnapshot,
    bool importApiKeys = false,
  }) async {
    final release = mode == ImportMode.overwrite
        ? _operationGuard.tryBeginOverwrite()
        : _operationGuard.tryBeginWrite();
    if (release == null) throw const BackupOverwriteBusyException();

    try {
      if (mode == ImportMode.overwrite && plan.version != null) {
        return await _overwrite(
          plan,
          preImportSnapshot: preImportSnapshot,
          importApiKeys: importApiKeys,
        );
      }
      return await _applyImport(
        plan,
        ImportMode.append,
        importApiKeys: importApiKeys,
      );
    } finally {
      release();
    }
  }

  // ==================== 统计 ====================

  Future<StorageStats> getStorageStats({
    required int dbSizeBytes,
    int templateCount = 0,
  }) async {
    final sessions = await chatRepository.getAllSessions();
    final presets = await presetRepository.getAllPresets();
    final messageCount = await chatRepository.getTotalMessageCount();
    final preferenceCount = await settingsRepository.getUserOverrideCount();
    final events = await _agentEventsUsagePort?.eventsUsage();
    final variantCount = await _messageVariantsCountPort?.messageVariantCount();

    return StorageStats(
      agentEventCount: events?.count ?? 0,
      agentEventBytes: events?.bytes ?? 0,
      variantCount: variantCount ?? 0,
      dbSizeBytes: dbSizeBytes,
      sessionCount: sessions.length,
      messageCount: messageCount,
      // 只计自建供应商——内置模板不是用户数据，
      // 计入会让"我的配置资产"虚高（templateCount 同口径由调用方保证）
      presetCount:
          presets.where((p) => !p.presetId.startsWith('builtin-')).length,
      templateCount: templateCount,
      preferenceCount: preferenceCount,
    );
  }

  // ==================== 数据恢复 ====================

  Future<List<OrphanMessageGroup>> scanOrphanMessages() async {
    final groups = await chatRepository.scanOrphanMessages();
    return groups
        .where((g) => g.isNotEmpty)
        .map(
          (messages) => OrphanMessageGroup(
            orphanSessionId: messages.first.sessionId,
            messages: messages,
          ),
        )
        .toList();
  }

  Future<List<ChatSession>> recoverOrphanMessages(
    List<OrphanMessageGroup> groups,
  ) async {
    final recovered = <ChatSession>[];

    for (final group in groups) {
      if (group.messages.isEmpty) continue;

      final session = await chatRepository.createSession(
        title: _generateRecoveryTitle(group),
      );

      //  修复：旧 ID → 新 ID 映射表。消息换新 messageId 时
      // parentUserMsgId 仍指向将被删除的旧消息——不重映射会导致恢复出的
      // 会话父子关系/分支结构断裂（父 ID 悬空）。
      final idRemap = <String, String>{
        for (final msg in group.messages) msg.messageId: _uuid.v4(),
      };

      for (final msg in group.messages) {
        final parentOld = msg.parentUserMsgId;
        await chatRepository.addMessage(
          msg.copyWith(
            messageId: idRemap[msg.messageId],
            sessionId: session.sessionId,
            // 父消息在本组内 → 用新 ID；不在（跨组/已删）→ 置空保完整
            parentUserMsgId: parentOld != null && idRemap.containsKey(parentOld)
                ? idRemap[parentOld]
                : null,
          ),
        );
      }

      await chatRepository.updateSessionMessageCount(
        session.sessionId,
        group.messageCount,
      );

      for (final msg in group.messages) {
        await chatRepository.deleteMessage(msg.messageId);
      }

      recovered.add(session);
    }

    return recovered;
  }

  // ==================== 清空 ====================

  Future<void> clearAllConversations() async {
    await chatRepository.recreateConversationTables();
  }

  // ==================== 表结构修复 ====================

  Future<SchemaRepairResult> repairDatabaseSchema() async {
    return chatRepository.repairSchema();
  }

  // ==================== 私有方法：导出 ====================

  /// 导出供应商（v2 格式：原始数据库行 + API Key）
  Future<List<Map<String, dynamic>>> _exportPresets(
    bool includeApiKeys,
  ) async {
    final presets = await backupRepository.exportAllPresets();
    final result = <Map<String, dynamic>>[];

    for (final preset in presets) {
      final presetId = preset['preset_id'] as String?;
      if (presetId == null) continue;

      final apiKey =
          includeApiKeys ? await settingsRepository.getApiKey(presetId) : null;

      final entry = Map<String, dynamic>.from(preset);
      if (apiKey != null && apiKey.isNotEmpty) {
        entry['api_key'] = apiKey;
      }
      result.add(entry);
    }

    return result;
  }

  /// 恢复会话标题入 slang（会入库并展示在侧边栏的持久文案）
  String _generateRecoveryTitle(OrphanMessageGroup group) {
    final base = t.settings.data.recoveredSessionTitle;
    final earliest = group.earliestTime;
    if (earliest == null) return base;
    return '$base ${earliest.year}-${earliest.month.toString().padLeft(2, '0')}-'
        '${earliest.day.toString().padLeft(2, '0')}';
  }
}
