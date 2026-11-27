part of 'data_management_service.dart';

typedef _PresetImport = ({
  Map<String, dynamic> row,
  String? presetId,
  String name,
  String baseUrl,
  String? key,
});

typedef _OldMessageImport = ({ChatMessage message, String? id, DateTime? date});

final class _OldSessionImport {
  const _OldSessionImport({
    required this.session,
    required this.sortOrder,
    required this.messages,
    required this.originalMessageCount,
  });

  final ChatSession session;
  final double? sortOrder;
  final List<_OldMessageImport> messages;
  final int originalMessageCount;
}

/// JSON 的结构与可跳过的坏条目在写入前处理。对空域保留各版本的覆盖语义。
final class _BackupImportPlan {
  _BackupImportPlan({
    required this.version,
    required this.exportedAt,
  });

  factory _BackupImportPlan.decode(
    String content, {
    ImportMode? importMode,
    bool preImportSnapshot = false,
    bool strictCollections = false,
  }) {
    final source =
        content.startsWith('\uFEFF') ? content.substring(1) : content;
    if (exceedsMaxDepth(source)) {
      throw FormatException(DataManagementService.depthLimitMessage);
    }

    final Object? root;
    try {
      root = jsonDecode(source);
    } on FormatException {
      // jsonDecode 的 FormatException.source 持有包含正文和可能的 Key 的原文。
      throw const FormatException('Invalid backup JSON');
    }

    if (root is! Map<String, dynamic> || !root.containsKey('version')) {
      if (preImportSnapshot) throw const FormatException('Invalid snapshot');
      return _BackupImportPlan._legacy(
        root,
        strictCollections: strictCollections,
      );
    }

    final Object? version = root['version'];
    if (version is! int || version < 1) {
      throw const FormatException('Invalid backup version');
    }
    if (version > DataManagementService.backupVersion) {
      throw BackupVersionTooNewException(version);
    }

    final Object? date = root['exportedAt'];
    final plan = _BackupImportPlan(
      version: version,
      exportedAt: date is String ? DateTime.tryParse(date) : null,
    );
    if (strictCollections) {
      _validateCollections(root, version);
    } else if (!hasBackupFields(root)) {
      throw const FormatException('Missing backup data sections');
    }
    final presets = root['presets'];
    if (presets is List) {
      for (final preset in presets) {
        final parsed = _parsePreset(preset, version);
        if (parsed == null) {
          plan.skippedPresets++;
        } else {
          plan.presets.add(parsed);
        }
      }
    } else if (root.containsKey('presets')) {
      plan.skippedPresets++;
    }
    final sessions = root['sessions'];
    if (sessions is List) {
      final seenSessionIds = <String>{};
      var hasSessionReplacements = false;
      for (final session in sessions) {
        if (version == 1) {
          plan._addOldSession(session, strictCollections: strictCollections);
        } else if (session
            case {
              'session': {
                'session_id': final String id,
                'title': final String title,
              },
            } when id.isNotEmpty && title.isNotEmpty) {
          final row = session as Map<String, dynamic>;
          final repeated = seenSessionIds.contains(id);
          // 仅整文件覆盖允许用完整备份包替换同 ID 会话。缺少正文或
          // 经历清单的重复条目仍保留首条，避免意外清除已有资料。
          if ((repeated &&
                  (importMode != ImportMode.overwrite ||
                      row['messages'] is! List ||
                      row['experientialMemories'] is! List)) ||
              (importMode != null && !_hasExperienceOwners(row, id))) {
            plan.skippedSessions++;
            continue;
          }
          plan._addRowSession(
            row,
            id,
            deferExperienceIdChecks: importMode != null,
            strictCollections: strictCollections || preImportSnapshot,
          );
          seenSessionIds.add(id);
          hasSessionReplacements = hasSessionReplacements || repeated;
        } else {
          plan.skippedSessions++;
        }
      }
      if (importMode == ImportMode.overwrite && !hasSessionReplacements) {
        plan._validateUniqueExperienceOwners();
      }
    } else if (root.containsKey('sessions')) {
      plan.skippedSessions++;
    }
    final preferences = root['preferences'];
    if (preferences is Map<String, dynamic>) {
      for (final entry in preferences.entries) {
        if (_isSupportedPreference(entry)) {
          plan.preferences[entry.key] = entry.value;
        } else {
          plan.skippedPreferences++;
        }
      }
    } else if (root.containsKey('preferences')) {
      plan.skippedPreferences++;
    }
    if (version >= 2) plan._parseAssets(root);
    if (version == 1 && strictCollections) plan._deduplicateOldMessages();
    if (preImportSnapshot) plan._validateSnapshot(root);
    return plan;
  }

  factory _BackupImportPlan._legacy(
    Object? root, {
    required bool strictCollections,
  }) {
    final List<dynamic> rows;
    if (root is Map<String, dynamic> && root['messages'] is List) {
      rows = [root];
    } else if (root is List<dynamic>) {
      rows = root;
    } else {
      throw const FormatException('Invalid backup format');
    }
    final plan = _BackupImportPlan(version: null, exportedAt: null);
    for (final row in rows) {
      plan._addOldSession(row, strictCollections: strictCollections);
    }
    return plan;
  }

  final int? version;
  final DateTime? exportedAt;
  final presets = <_PresetImport>[];
  final rowSessions = <Map<String, dynamic>>[];
  final _sessionRowOwners = <String, Map<String, String>>{};
  final oldSessions = <_OldSessionImport>[];
  final preferences = <String, dynamic>{};
  final assets = <String, List<Map<String, dynamic>>>{};
  int skippedSessions = 0;
  int skippedPresets = 0;
  int skippedPreferences = 0;
  int skippedAssets = 0;
  int skippedMessages = 0;
  int skippedSessionRows = 0;

  bool get hasRestorableData =>
      presets.isNotEmpty ||
      rowSessions.isNotEmpty ||
      oldSessions.isNotEmpty ||
      preferences.isNotEmpty ||
      assets.values.any((rows) => rows.isNotEmpty);

  int get skippedItems =>
      skippedPresets +
      skippedSessions +
      skippedPreferences +
      skippedAssets +
      skippedMessages +
      skippedSessionRows +
      oldSessions.fold<int>(
        0,
        (total, session) =>
            total + session.originalMessageCount - session.messages.length,
      );

  static const Map<String, BackupDataDomain> _assetDomains = {
    'characterCards': BackupDataDomain.characterCards,
    'worldbooks': BackupDataDomain.worldbooks,
    'userTemplates': BackupDataDomain.userTemplates,
    'agentEvents': BackupDataDomain.agentEvents,
  };

  Set<BackupDataDomain> get domains => {
        if (rowSessions.isNotEmpty || oldSessions.isNotEmpty)
          BackupDataDomain.sessions,
        if (presets.isNotEmpty) BackupDataDomain.presets,
        for (final key in assets.keys)
          if (_assetDomains[key] case final domain?) domain,
      };

  void _validateSnapshot(Map<String, dynamic> root) {
    if (version != DataManagementService.backupVersion ||
        exportedAt == null ||
        root['sessions'] is! List ||
        root['presets'] is! List ||
        root['preferences'] is! Map<String, dynamic> ||
        root.containsKey('contains_secrets') ||
        _assetDomains.keys.any((key) => root[key] is! List) ||
        skippedSessions != 0 ||
        skippedMessages != 0 ||
        skippedSessionRows != 0 ||
        skippedAssets != 0) {
      throw const FormatException('Invalid snapshot');
    }

    for (final row in root['presets'] as List) {
      if (row is! Map<String, dynamic> ||
          row.containsKey('apiKey') ||
          row.containsKey('api_key') ||
          (!_isBuiltIn(row) &&
              _parsePreset(row, DataManagementService.backupVersion) == null)) {
        throw const FormatException('Invalid preset in snapshot');
      }
    }
  }

  static bool hasBackupFields(Map<String, dynamic> root) =>
      root.containsKey('exportedAt') ||
      root.containsKey('sessions') ||
      root.containsKey('presets') ||
      root.containsKey('preferences') ||
      _assetDomains.keys.any(root.containsKey);

  static void _validateCollections(Map<String, dynamic> root, int version) {
    final lists = [
      'presets',
      'sessions',
      if (version >= 2) ..._assetDomains.keys,
    ];
    if (lists.any((key) => root.containsKey(key) && root[key] is! List) ||
        (root.containsKey('preferences') && root['preferences'] is! Map)) {
      throw const FormatException('Invalid backup data collection');
    }
  }

  void _parseAssets(Map<String, dynamic> root) {
    for (final key in _assetDomains.keys) {
      if (root[key] case final List<dynamic> entries) {
        final rows = entries.whereType<Map<String, dynamic>>().where((row) {
          return switch (key) {
            'characterCards' => _validResourceRow(row, 'card_id'),
            'worldbooks' => _validResourceRow(row, 'book_id'),
            'userTemplates' => _hasText(row, 'template_id') &&
                _hasText(row, 'name') &&
                row['kind'] is String &&
                row['content'] is String &&
                !_isBuiltIn(row),
            'agentEvents' => _hasText(row, 'session_id') &&
                row['seq'] is int &&
                _hasText(row, 'type') &&
                row['time'] != null &&
                row['data'] is String,
            _ => false,
          };
        }).toList();
        skippedAssets += entries.length - rows.length;
        // 明确空的资源列表可清空该表。事件日志独立覆盖需要实际有事件。
        if (rows.isNotEmpty || (entries.isEmpty && key != 'agentEvents')) {
          assets[key] = rows;
        }
      } else if (root.containsKey(key)) {
        skippedAssets++;
      }
    }
  }

  static bool _hasText(Object? value, String key) =>
      value is Map<String, dynamic> &&
      value[key] is String &&
      (value[key] as String).isNotEmpty;

  static bool _validResourceRow(Map<String, dynamic> row, String id) =>
      _hasText(row, id) && _hasText(row, 'name') && row['raw_json'] is String;

  static bool _isBuiltIn(Map<String, dynamic> row) =>
      row['is_built_in'] == true || row['is_built_in'] == 1;

  static _PresetImport? _parsePreset(dynamic value, int version) {
    if (value is! Map<String, dynamic>) return null;
    final Object? apiKey = value[version == 1 ? 'apiKey' : 'api_key'];
    final key = apiKey is String && apiKey.isNotEmpty ? apiKey : null;
    if (version >= 2) {
      if (!_hasText(value, 'preset_id') ||
          !_hasText(value, 'name') ||
          _isBuiltIn(value)) {
        return null;
      }
      return (
        row: value,
        presetId: value['preset_id'] as String,
        name: value['name'] as String,
        baseUrl: '',
        key: key,
      );
    }
    final Object? name = value['name'];
    final Object? baseUrl = value['baseUrl'];
    if (name is! String ||
        name.isEmpty ||
        (baseUrl != null && baseUrl is! String)) {
      return null;
    }
    return (
      row: value,
      presetId: null,
      name: name,
      baseUrl: baseUrl as String? ?? '',
      key: key,
    );
  }

  static bool _isSupportedPreference(MapEntry<String, dynamic> entry) {
    final value = entry.value;
    if (_isScalar(value)) return true;
    if (value is Map<String, dynamic>) return value.values.every(_isScalar);
    const collapsedSections = {
      'ui.storySession.collapsedSections',
      'ui.directorSession.collapsedSections',
      'ui.directorSettings.collapsedSections',
    };
    return collapsedSections.contains(entry.key) &&
        value is List &&
        value.every((id) => id is String);
  }

  static bool _isScalar(Object? value) =>
      value is String || value is bool || value is num && value.isFinite;

  void _addOldSession(dynamic value, {required bool strictCollections}) {
    if (value is! Map<String, dynamic>) {
      skippedSessions++;
      return;
    }
    if (strictCollections &&
        value.containsKey('messages') &&
        value['messages'] is! List) {
      throw const FormatException('Invalid backup message collection');
    }
    // 仅捕获同步的输入转换错误。访问仓储发生在转换完成之后。
    try {
      final session = _parseOldSession(value, legacy: version == null);
      if (session != null) {
        oldSessions.add(session);
      } else if (value['messages'] case final List<dynamic> rows
          when rows.isNotEmpty) {
        skippedSessions++;
      }
      // ignore: avoid_catching_errors — synchronous legacy JSON casts
    } on TypeError {
      skippedSessions++;
    } on FormatException {
      skippedSessions++;
    }
  }

  void _deduplicateOldMessages() {
    final ids = <String>{};
    for (final session in oldSessions) {
      session.messages.removeWhere((message) {
        final id = message.id;
        return id != null && !ids.add(id);
      });
    }
  }

  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  static _OldSessionImport? _parseOldSession(
    Map<String, dynamic> row, {
    required bool legacy,
  }) {
    final title = row['name'] as String? ?? 'Imported Chat';
    if (title.isEmpty) {
      throw const FormatException('Empty backup session title');
    }
    final rows = row['messages'] as List<dynamic>? ?? const [];
    if (legacy && rows.isEmpty) return null;
    final messages = rows
        .map((row) => _parseOldMessage(row, legacy: legacy))
        .whereType<_OldMessageImport>()
        .toList();
    if (legacy && messages.isEmpty) return null;
    final settings = legacy
        ? <String, dynamic>{}
        : row['settings'] as Map<String, dynamic>? ?? const {};
    final session = ChatSession(
      sessionId: legacy ? '' : row['sessionId'] as String? ?? '',
      title: title,
      mode: legacy ? ChatMode.chat : row['mode'] as String? ?? ChatMode.chat,
      createdAt: _epoch,
      lastActiveAt: _epoch,
      messageCount: 0,
      modelId: settings['modelId'] as String?,
      presetId: settings['presetId'] as String?,
      isStarred: !legacy && (row['isStarred'] as bool? ?? false),
      systemPromptOverride: settings['systemPromptOverride'] as String?,
      temperature: (settings['temperature'] as num?)?.toDouble(),
      topP: (settings['topP'] as num?)?.toDouble(),
      maxTokens: settings['maxTokens'] as int?,
      autoCompaction: settings['autoCompaction'] as bool?,
      compactionThreshold:
          (settings['compactionThreshold'] as num?)?.toDouble(),
      streamEnabled: settings['streamEnabled'] as bool?,
      maxContextMessages: settings['maxContextMessages'] as int?,
    );
    return _OldSessionImport(
      session: session,
      sortOrder: legacy ? null : (row['sortOrder'] as num?)?.toDouble(),
      messages: messages,
      originalMessageCount: rows.length,
    );
  }

  static _OldMessageImport? _parseOldMessage(
    dynamic row, {
    required bool legacy,
  }) {
    if (row is! Map<String, dynamic>) return null;
    try {
      final role = row['role'] as String? ?? 'user';
      if (role != 'user' &&
          role != 'assistant' &&
          (legacy || role != 'system')) {
        return null;
      }
      final id = legacy ? null : row['messageId'] as String?;
      if (id?.isEmpty ?? false) return null;
      final date = legacy || row['createdAt'] == null
          ? null
          : DateTime.parse(row['createdAt'] as String);
      return (
        id: id,
        date: date,
        message: ChatMessage(
          messageId: '',
          sessionId: '',
          role: role,
          content: row['content'] as String? ?? '',
          createdAt: _epoch,
          tokensUsed: legacy ? null : row['tokensUsed'] as int?,
          modelName: legacy ? null : row['modelName'] as String?,
          thinkingContent: legacy ? null : row['thinkingContent'] as String?,
          thinkingDuration: legacy ? null : row['thinkingDuration'] as int?,
          toolCalls: legacy ? null : row['toolCalls'] as String?,
          toolCallId: legacy ? null : row['toolCallId'] as String?,
          firstTokenLatency: legacy ? null : row['firstTokenLatency'] as int?,
          parentUserMsgId: legacy ? null : row['parentUserMsgId'] as String?,
          attachments: legacy || row['attachments'] == null
              ? null
              : MessageAttachment.listFromJson(row['attachments'] as String),
        ),
      );
      // ignore: avoid_catching_errors — synchronous legacy JSON casts
    } on TypeError {
      return null;
    } on FormatException {
      return null;
    }
  }
}
