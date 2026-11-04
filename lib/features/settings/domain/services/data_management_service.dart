import 'dart:async';
import 'dart:convert';
import 'package:lmstory/core/utils/json_depth_guard.dart';
import 'package:lmstory/core/utils/logger.dart';
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
  })  : _agentEventsUsagePort = agentEventsUsagePort,
        _messageVariantsCountPort = messageVariantsCountPort;

  static const Logger _importLogger = Logger('DataManagementService.import');

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
    if (root is! Map) return false;
    if (root['version'] is! int) return false;
    return root.containsKey('exportedAt') ||
        root.containsKey('sessions') ||
        root.containsKey('presets') ||
        root.containsKey('preferences');
  }

  final ChatRepository chatRepository;
  final ApiPresetRepository presetRepository;
  final SettingsRepository settingsRepository;
  final BackupRepository backupRepository;

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

  /// 从 JSON 字符串导入数据
  ///
  /// 自动识别 v3 / v2 完整备份格式和 v1 旧格式。
  /// - v3 / v2：使用 BackupRepository 进行全量导入（v3 含全局资产四类；
  ///   v2 备份缺新键走空清单，自然兼容）
  /// - v1：使用旧逻辑导入（仅会话+消息+供应商+偏好）
  ///
  /// [preImportSnapshot] 覆盖导入前置快照钩子——
  /// 在**任何删除动作之前**执行；抛异常则整个导入中止（fail-closed：
  /// 没有回滚网的覆盖不值得跑——导入文件损坏时这是唯一防线）。
  /// append 模式非破坏性，不触发。由 Presentation 层接线到
  /// AutoBackupManager.createPreImportSnapshot（文件 IO 不进本服务）。
  Future<ImportResult> importBackup(
    String jsonContent,
    ImportMode mode, {
    Future<void> Function()? preImportSnapshot,
    bool importApiKeys = false,
  }) async {
    // 与 looksLikeAppBackupJson 同口径剥 BOM：记事本等编辑器另存的备份
    // 带 U+FEFF 前缀，不剥则「确认可导入」后主链 jsonDecode 必败。
    final source = jsonContent.startsWith('\uFEFF')
        ? jsonContent.substring(1)
        : jsonContent;
    // 深度粗检先于 jsonDecode（与资源导入入口同口径），避免极深内容
    // 递归解析栈溢出成晦涩的 Stack Overflow 文案。
    if (exceedsMaxDepth(source)) {
      throw FormatException(depthLimitMessage);
    }
    final jsonData = jsonDecode(source);
    final version =
        jsonData is Map<String, dynamic> ? jsonData['version'] : null;

    // 快照先于版本路由与任何删除（快照失败不碰库）
    if (mode == ImportMode.overwrite && preImportSnapshot != null) {
      await preImportSnapshot();
    }

    // v2 与 v3 同走行级导入链（v3 是 v2 的超集；v2 备份缺全局资产键
    // 走空清单，自然兼容）。此前只比对单一常量，backupVersion 升 3 后
    // v2 备份会被误路由进 v1 导入链（丢故事模式数据）。
    final isV2OrV3 = version is int &&
        (version == 2 || version == backupVersion) &&
        jsonData is Map<String, dynamic>;
    if (isV2OrV3) {
      return _importV2OrV3(jsonData, mode, importApiKeys: importApiKeys);
    }
    //  收口：版本守卫下沉到服务层——页面守卫
    // 只是提前拦截，任何未来新调用方（自动化/命令入口）绕过页面时，
    // 更新版本的备份不得被误路由进 v1 导入生成空「Imported Chat」。
    if (version is int && version > backupVersion) {
      throw FormatException(
        'Backup version $version is newer than supported '
        '($backupVersion); please upgrade the app first.',
      );
    }
    // v1 格式或旧版仅会话格式
    if (jsonData is Map<String, dynamic> && jsonData.containsKey('version')) {
      return _importV1(jsonData, mode, importApiKeys: importApiKeys);
    }
    return _importLegacySessions(jsonData);
  }

  /// v2/v3 格式导入（全量数据，使用 BackupRepository）
  Future<ImportResult> _importV2OrV3(
    Map<String, dynamic> data,
    ImportMode mode, {
    bool importApiKeys = false,
  }) async {
    final hasPresets = _hasPresetData(data);
    // 会话域存在性 = 键存在**且为非空 List**（见 _hasSessionData）
    final hasSessions = _hasSessionData(data);
    // preferences 域同口径做形状
    // 预检——此前仅 containsKey，坏备份（值为字符串/列表）会让下方
    // `as Map` 在覆盖清空（clearAllUserOverrides 已执行）之后才抛
    // TypeError：偏好被清了、新的没进去。预检为 false 时该域跳过，
    // 覆盖清空也不触发。
    final hasPreferences =
        data['preferences'] is Map && (data['preferences'] as Map).isNotEmpty;
    // v3 全局资产键（v2 备份均缺省 → 空清单自然兼容）
    final hasGlobalAssets = data.containsKey('characterCards') ||
        data.containsKey('worldbooks') ||
        data.containsKey('userTemplates') ||
        data.containsKey('agentEvents');

    // 覆盖模式：先清空备份包含的数据类型
    if (mode == ImportMode.overwrite) {
      if (hasSessions) await backupRepository.deleteAllSessionData();
      if (hasPresets) await backupRepository.deleteAllCustomPresets();
      if (hasPreferences) await settingsRepository.clearAllUserOverrides();
    }

    final presetResult = hasPresets
        ? await _importPresetsV2(
            data['presets'] as List<dynamic>? ?? [],
            mode: mode,
            importApiKeys: importApiKeys,
          )
        : (imported: 0, skipped: 0, keysImported: 0);

    final sessionResult = hasSessions
        ? await _importSessionsV2(
            data['sessions'] as List<dynamic>? ?? [],
            mode: mode,
          )
        : (imported: 0, skipped: 0, importedMessages: 0);

    final prefResult = hasPreferences
        ? await _importPreferences(
            data['preferences'] as Map<String, dynamic>? ?? {},
            mode: mode,
          )
        : (imported: 0, skipped: 0);

    // v3：全局资产（条目级容错——坏数据跳过不中止其余导入，同  口径）
    var importedAssets = 0;
    if (hasGlobalAssets) {
      try {
        importedAssets = await backupRepository.importGlobalAssets(
          data,
          mode: mode,
        );
      } catch (e) {
        _importLogger.warn(
          'Skip malformed global assets during import',
          detail: '$e',
        );
      }
    }

    return ImportResult(
      importedPresets: presetResult.imported,
      skippedPresets: presetResult.skipped,
      importedSessions: sessionResult.imported,
      skippedSessions: sessionResult.skipped,
      importedMessages: sessionResult.importedMessages,
      importedPreferences: prefResult.imported,
      skippedPreferences: prefResult.skipped,
      importedAssets: importedAssets,
      importedApiKeys: presetResult.keysImported,
      mode: mode,
    );
  }

  /// v1 格式导入（旧格式兼容，仅会话+消息+供应商+偏好）
  Future<ImportResult> _importV1(
    Map<String, dynamic> data,
    ImportMode mode, {
    bool importApiKeys = false,
  }) async {
    final hasPresets = _hasPresetData(data);
    // 空会话数组跳过会话域（与 v2/v3 链同口径，UI 预检不区分版本）
    final hasSessions = _hasSessionData(data);
    // 与 v2/v3 链同口径的
    // 域形状预检——此前 containsKey 放行 List/字符串值，覆盖清空
    // （clearAllUserOverrides）之后 cast 才抛 TypeError：偏好已清、
    // 新值未进、其余域已导入（半空域终态）。
    final rawPreferences = data['preferences'];
    final hasPreferences = rawPreferences is Map && rawPreferences.isNotEmpty;

    if (mode == ImportMode.overwrite) {
      if (hasPresets) await presetRepository.deleteAllCustomPresets();
      //  修复：v1 覆盖此前用 chatRepository.deleteAllSessions
      // 只清 4 张表，记忆/事实/artifacts/FTS 全部残留成不可见孤儿；
      // 改用与 v2 相同的全量会话数据删除。
      if (hasSessions) await backupRepository.deleteAllSessionData();
      if (hasPreferences) await settingsRepository.clearAllUserOverrides();
    }

    final presetResult = hasPresets
        ? await _importPresetsV1(
            data['presets'] as List<dynamic>? ?? [],
            mode: mode,
            importApiKeys: importApiKeys,
          )
        : (imported: 0, skipped: 0, keysImported: 0);

    final sessionResult = hasSessions
        ? await _importSessionsV1(
            data['sessions'] as List<dynamic>? ?? [],
            mode: mode,
          )
        : (imported: 0, skipped: 0, importedMessages: 0);

    final prefResult = hasPreferences
        ? await _importPreferences(
            data['preferences'] as Map<String, dynamic>? ?? {},
            mode: mode,
          )
        : (imported: 0, skipped: 0);

    return ImportResult(
      importedPresets: presetResult.imported,
      skippedPresets: presetResult.skipped,
      importedSessions: sessionResult.imported,
      skippedSessions: sessionResult.skipped,
      importedMessages: sessionResult.importedMessages,
      importedPreferences: prefResult.imported,
      skippedPreferences: prefResult.skipped,
      importedApiKeys: presetResult.keysImported,
      mode: mode,
    );
  }

  Future<ImportResult> _importLegacySessions(dynamic data) async {
    // 条目级容错——此前 data.cast<Map<String, dynamic>>
    // 对任一畸形条目直接抛 TypeError 中止整个导入（已插入的会话保留、
    // 其余全部丢失）。改为逐条过滤 + skipped 计数（对齐  已修的
    // v2/v3 链行为）。
    final List<dynamic> rawList;
    if (data is List) {
      rawList = data;
    } else if (data is Map<String, dynamic>) {
      rawList = [data];
    } else {
      throw const FormatException('Invalid import format');
    }

    var importedSessions = 0;
    var skippedSessions = 0;
    var importedMessages = 0;

    for (final rawItem in rawList) {
      if (rawItem is! Map) {
        skippedSessions++;
        _importLogger.warn(
          'Skip malformed legacy session entry during import',
          detail: '$rawItem',
        );
        continue;
      }
      final item = Map<String, dynamic>.from(rawItem);
      final name = item['name'] as String? ?? 'Imported Chat';
      final messagesRaw = item['messages'] as List<dynamic>? ?? [];
      if (messagesRaw.isEmpty) continue;

      final session = await chatRepository.createSession(title: name);

      for (final msgRaw in messagesRaw) {
        // 坏消息条目跳过不中止该会话（v2/v3 链经 _asList 同样
        // 丢弃畸形行、保留会话）
        try {
          final msg = Map<String, dynamic>.from(msgRaw as Map);
          final role = msg['role'] as String? ?? 'user';
          final content = msg['content'] as String? ?? '';
          if (role != 'user' && role != 'assistant') continue;

          await chatRepository.addMessage(
            ChatMessage(
              messageId: _uuid.v4(),
              sessionId: session.sessionId,
              role: role,
              content: content,
              createdAt: DateTime.now(),
            ),
          );
          importedMessages++;
        } catch (e) {
          _importLogger.warn(
            'Skip malformed legacy message entry during import',
            detail: '$e',
          );
        }
      }

      await chatRepository.updateSessionMessageCount(
        session.sessionId,
        messagesRaw.length,
      );
      importedSessions++;
    }

    return ImportResult(
      importedPresets: 0,
      skippedPresets: 0,
      importedSessions: importedSessions,
      skippedSessions: skippedSessions,
      importedMessages: importedMessages,
      importedPreferences: 0,
      skippedPreferences: 0,
      mode: ImportMode.append,
    );
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

  // ==================== 私有方法：导入（v2） ====================

  /// v2 供应商导入（保留原始 presetId，含 protocol 等全部字段）
  Future<({int imported, int skipped, int keysImported})> _importPresetsV2(
    List<dynamic> presetsRaw, {
    required ImportMode mode,
    bool importApiKeys = false,
  }) async {
    var imported = 0;
    var skipped = 0;
    var keysImported = 0;

    for (final presetRaw in presetsRaw) {
      // 条目级容错——此前畸形条目（非 Map/类型不符）
      // 抛 TypeError 中止整个导入循环，覆盖模式下删除已先行提交，
      // 剩余会话/偏好全部不再导入（半空库终态）。坏条目计 skipped 落日志。
      try {
        final preset = presetRaw is Map<String, dynamic>
            ? presetRaw
            : Map<String, dynamic>.from(presetRaw as Map);

        final success = await backupRepository.importPreset(preset, mode: mode);

        if (success) {
          // 导入 API Key（：默认不导入——Key 是敏感凭据，含 Key 备份
          // 只有用户在导入面板显式勾选才覆盖本机密钥；快照/自动备份天然
          // 不含 Key 不受影响）
          final apiKey = preset['api_key'] as String?;
          final presetId = preset['preset_id'] as String?;
          if (importApiKeys &&
              apiKey != null &&
              apiKey.isNotEmpty &&
              presetId != null) {
            await settingsRepository.saveApiKey(presetId, apiKey);
            keysImported++;
          }
          imported++;
        } else {
          skipped++;
        }
      } catch (e) {
        skipped++;
        _importLogger.warn(
          'Skip malformed preset entry during import',
          detail: '$e',
        );
      }
    }

    return (imported: imported, skipped: skipped, keysImported: keysImported);
  }

  /// v2 会话导入（使用 BackupRepository，保留原始 ID，含故事模式全部数据）
  Future<({int imported, int skipped, int importedMessages})> _importSessionsV2(
    List<dynamic> sessionsRaw, {
    required ImportMode mode,
  }) async {
    var imported = 0;
    var skipped = 0;
    var importedMessages = 0;

    for (final sessionRaw in sessionsRaw) {
      // 条目级容错（同 _importPresetsV2）
      try {
        final sessionData = sessionRaw is Map<String, dynamic>
            ? sessionRaw
            : Map<String, dynamic>.from(sessionRaw as Map);

        //  修复：返回值为实际插入的消息条数；-1 = 会话已存在被跳过
        final insertedMessages = await backupRepository.importSessionData(
          sessionData,
          mode: mode,
        );

        if (insertedMessages >= 0) {
          imported++;
          importedMessages += insertedMessages;
        } else {
          skipped++;
        }
      } catch (e) {
        skipped++;
        _importLogger.warn(
          'Skip malformed session entry during import',
          detail: '$e',
        );
      }
    }

    return (
      imported: imported,
      skipped: skipped,
      importedMessages: importedMessages,
    );
  }

  // ==================== 私有方法：导入（v1 兼容） ====================

  /// v1 供应商导入（仅 name/baseUrl/apiKey，protocol 等字段缺失）
  Future<({int imported, int skipped, int keysImported})> _importPresetsV1(
    List<dynamic> presetsRaw, {
    required ImportMode mode,
    bool importApiKeys = false,
  }) async {
    var imported = 0;
    var skipped = 0;
    var keysImported = 0;

    final existingNames = mode == ImportMode.append
        ? (await presetRepository.getAllPresets()).map((p) => p.name).toSet()
        : <String>{};

    for (final presetRaw in presetsRaw) {
      // 条目级容错（同  的 v2 链）——v1 覆盖模式
      // 删除先行提交，畸形条目抛 TypeError 中止整链会让剩余条目全部
      // 不导入（半空库终态）。坏条目计 skipped 落日志。
      try {
        final preset = presetRaw is Map<String, dynamic>
            ? presetRaw
            : Map<String, dynamic>.from(presetRaw as Map);
        final name = preset['name'] as String? ?? '';
        final baseUrl = preset['baseUrl'] as String? ?? '';

        if (mode == ImportMode.append && existingNames.contains(name)) {
          skipped++;
          continue;
        }

        final newPreset = await presetRepository.createPreset(
          name: name,
          baseUrl: baseUrl,
        );

        final apiKey = preset['apiKey'] as String?;
        if (importApiKeys && apiKey != null && apiKey.isNotEmpty) {
          await settingsRepository.saveApiKey(newPreset.presetId, apiKey);
          keysImported++;
        }

        imported++;
      } catch (e) {
        skipped++;
        _importLogger.warn(
          'Skip malformed preset entry during v1 import',
          detail: '$e',
        );
      }
    }

    return (imported: imported, skipped: skipped, keysImported: keysImported);
  }

  /// v1 会话导入（旧格式，仅会话+消息，保留原始 messageId）
  Future<({int imported, int skipped, int importedMessages})> _importSessionsV1(
    List<dynamic> sessionsRaw, {
    required ImportMode mode,
  }) async {
    var imported = 0;
    var skipped = 0;
    var importedMessages = 0;

    final existingIds = mode == ImportMode.append
        ? (await chatRepository.getAllSessions())
            .map((s) => s.sessionId)
            .toSet()
        : <String>{};

    for (final sessionRaw in sessionsRaw) {
      // 条目级容错（同  的 v2 链）——v1 覆盖模式
      // 删除先行提交，畸形会话条目抛 TypeError 中止整链 = 半空库终态。
      try {
        final session = sessionRaw is Map<String, dynamic>
            ? sessionRaw
            : Map<String, dynamic>.from(sessionRaw as Map);
        final sessionId = session['sessionId'] as String? ?? '';

        if (mode == ImportMode.append && existingIds.contains(sessionId)) {
          skipped++;
          continue;
        }

        final name = session['name'] as String? ?? 'Imported Chat';
        final modeValue = session['mode'] as String? ?? ChatMode.chat;
        final settings = session['settings'] as Map<String, dynamic>? ?? {};
        final messagesRaw = session['messages'] as List<dynamic>? ?? [];

        final newSession = await chatRepository.createSession(
          title: name,
          mode: modeValue,
          modelId: settings['modelId'] as String?,
          presetId: settings['presetId'] as String?,
        );

        await chatRepository.updateSession(
          newSession.copyWith(
            isStarred: session['isStarred'] as bool? ?? false,
            sortOrder: (session['sortOrder'] as num?)?.toDouble(),
            systemPromptOverride: settings['systemPromptOverride'] as String?,
            temperature: (settings['temperature'] as num?)?.toDouble(),
            topP: (settings['topP'] as num?)?.toDouble(),
            maxTokens: settings['maxTokens'] as int?,
            autoCompaction: settings['autoCompaction'] as bool?,
            compactionThreshold:
                (settings['compactionThreshold'] as num?)?.toDouble(),
            streamEnabled: settings['streamEnabled'] as bool?,
            maxContextMessages: settings['maxContextMessages'] as int?,
          ),
        );

        for (final msgRaw in messagesRaw) {
          // 坏消息条目跳过不中止该会话（v2/v3 链经 _asList 同样
          // 丢弃畸形行、保留会话）
          try {
            final msg = msgRaw is Map<String, dynamic>
                ? msgRaw
                : Map<String, dynamic>.from(msgRaw as Map);
            final role = msg['role'] as String? ?? 'user';
            final content = msg['content'] as String? ?? '';

            if (role != 'user' && role != 'assistant' && role != 'system') {
              continue;
            }

            // 保留原始 messageId（修复 v1 导入 bug：之前生成新 UUID 导致分支断裂）
            await chatRepository.addMessage(
              ChatMessage(
                messageId: msg['messageId'] as String? ?? _uuid.v4(),
                sessionId: newSession.sessionId,
                role: role,
                content: content,
                createdAt: msg['createdAt'] != null
                    ? DateTime.parse(msg['createdAt'] as String)
                    : DateTime.now(),
                tokensUsed: msg['tokensUsed'] as int?,
                modelName: msg['modelName'] as String?,
                thinkingContent: msg['thinkingContent'] as String?,
                thinkingDuration: msg['thinkingDuration'] as int?,
                toolCalls: msg['toolCalls'] as String?,
                toolCallId: msg['toolCallId'] as String?,
                firstTokenLatency: msg['firstTokenLatency'] as int?,
                parentUserMsgId: msg['parentUserMsgId'] as String?,
                attachments: msg['attachments'] != null
                    ? MessageAttachment.listFromJson(
                        msg['attachments'] as String,
                      )
                    : null,
              ),
            );
            importedMessages++;
          } catch (e) {
            _importLogger.warn(
              'Skip malformed message entry during v1 import',
              detail: '$e',
            );
          }
        }

        await chatRepository.updateSessionMessageCount(
          newSession.sessionId,
          messagesRaw.length,
        );

        imported++;
      } catch (e) {
        skipped++;
        _importLogger.warn(
          'Skip malformed session entry during v1 import',
          detail: '$e',
        );
      }
    }

    return (
      imported: imported,
      skipped: skipped,
      importedMessages: importedMessages,
    );
  }

  // ==================== 私有方法：偏好导入（v1/v2 共用） ====================

  Future<({int imported, int skipped})> _importPreferences(
    Map<String, dynamic> preferences, {
    required ImportMode mode,
  }) async {
    var imported = 0;
    var skipped = 0;

    final currentOverrides = mode == ImportMode.append
        ? await settingsRepository.getUserOverrides()
        : <String, dynamic>{};

    for (final entry in preferences.entries) {
      if (mode == ImportMode.append &&
          currentOverrides.containsKey(entry.key)) {
        skipped++;
        continue;
      }
      // 拒收非标量值——覆盖表叶子全为标量（见 SettingsRepository
      // _configToMap），List/null 等脏值入库只会给读取侧埋雷（类型矫正
      // 见 _deepMerge，此处从源头拒收并计入 skipped）
      final value = entry.value;
      final isScalar = value is num || value is bool || value is String;
      final isScalarMap = value is Map<String, dynamic> &&
          value.values.every(
            (v) => v is num || v is bool || v is String,
          );
      if (!isScalar && !isScalarMap) {
        skipped++;
        _importLogger.warn(
          'Skip non-scalar preference entry during import',
          detail: '${entry.key}: ${value.runtimeType}',
        );
        continue;
      }
      // 条目级容错（单个坏值不中止其余偏好导入）
      try {
        await settingsRepository.setUserOverride(entry.key, value);
        imported++;
      } catch (e) {
        skipped++;
        _importLogger.warn(
          'Skip malformed preference entry during import',
          detail: '${entry.key}: $e',
        );
      }
    }

    return (imported: imported, skipped: skipped);
  }

  // ==================== 私有方法：工具 ====================

  /// 备份是否携带会话数据——`sessions` 键存在**且为
  /// 非空 List** 才算有；v1/v2/v3 导入链共用。
  ///
  /// 决策依据（让行为符合 UI 承诺，而非反向迁就实现）：
  /// - 空数组（空库设备「会话」默认勾选导出的真实形态）：覆盖导入跳过
  ///   会话域的删除+导入。此前按 containsKey 照样 deleteAllSessionData()
  ///   清空全部会话，而预检页/模式 Sheet/二次确认三处 UI 都承诺
  ///   「这份备份不含会话数据……覆盖不会影响你的任何会话」——按计数
  ///   （count=0）与按「缺键」混为一谈导致承诺落空。空数组清空无意义：
  ///   「无会话数据可导入」与「不含会话数据」对用户的含义一致。
  /// - 键缺失：不动会话域（既有语义保持不变）。
  /// - 值非 List（畸形备份）：同样跳过会话域——避免「先删除、后抛
  ///   TypeError」的半空库路径（与  条目级容错同方向）。
  static bool _hasSessionData(Map<String, dynamic> data) {
    final sessions = data['sessions'];
    return sessions is List && sessions.isNotEmpty;
  }

  /// presets 域与 [_hasSessionData] 同口径——
  /// 键存在且为非空 List 才算有。此前空 `presets: []` 备份（零供应商
  /// 设备导出的真实形态）覆盖导入会删光本机全部自定义供应商与 Key 而
  /// 不导入任何东西——「无数据可导入」不应等价于「清空该域」。
  /// v1/v2/v3 导入链共用。
  static bool _hasPresetData(Map<String, dynamic> data) {
    final presets = data['presets'];
    return presets is List && presets.isNotEmpty;
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
