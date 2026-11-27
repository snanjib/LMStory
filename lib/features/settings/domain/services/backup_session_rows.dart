part of 'data_management_service.dart';

/// Persisted session collections in the row-based backup. Search indexes are
/// built from these rows by the repository.
const _sessionRows = <String, _SessionRowFormat>{
  'messages': _SessionRowFormat(
    requiredText: ['message_id', 'role'],
    uniqueColumns: ['message_id'],
    globallyUnique: true,
  ),
  'compactionPoints': _SessionRowFormat(
    requiredText: ['summary_message_id', 'boundary_message_id'],
  ),
  'forkBranches': _SessionRowFormat(
    requiredText: ['anchor_user_msg_id'],
    uniqueColumns: ['anchor_user_msg_id'],
  ),
  'experientialMemories': _SessionRowFormat(
    requiredText: ['memory_id', 'summary'],
    requiredInt: ['turn_number'],
    uniqueColumns: ['memory_id'],
    globallyUnique: true,
  ),
  'factualEntities': _SessionRowFormat(
    requiredText: ['entity_id', 'primary_name', 'type'],
    requiredInt: ['created_turn'],
    uniqueColumns: ['entity_id'],
    globallyUnique: true,
  ),
  'factualAttributes': _SessionRowFormat(
    requiredText: ['attribute_id', 'entity_id', 'attr_key', 'value'],
    uniqueColumns: ['attribute_id'],
    globallyUnique: true,
  ),
  'relationshipMigrationBackup': _SessionRowFormat(
    requiredText: [
      'attribute_id',
      'entity_id',
      'attr_key',
      'value_type',
      'value',
    ],
  ),
  'factualHistory': _SessionRowFormat(
    requiredText: ['entity_id', 'action'],
    requiredInt: ['turn_number'],
    hasSessionColumn: false,
  ),
  'intermediateArtifacts': _SessionRowFormat(
    requiredInt: ['turn_number', 'created_at'],
  ),
  'messageVariants': _SessionRowFormat(
    requiredInt: ['turn_number', 'variant_index', 'created_at'],
    uniqueColumns: ['turn_number', 'variant_index'],
  ),
  'agentEvents': _SessionRowFormat(
    requiredText: ['type', 'data'],
    requiredInt: ['seq'],
    uniqueColumns: ['seq'],
  ),
};

final class _SessionRowFormat {
  const _SessionRowFormat({
    this.requiredText = const [],
    this.requiredInt = const [],
    this.uniqueColumns = const [],
    this.hasSessionColumn = true,
    this.globallyUnique = false,
  });

  final List<String> requiredText;
  final List<String> requiredInt;
  final List<String> uniqueColumns;
  final bool hasSessionColumn;
  final bool globallyUnique;

  bool accepts(Map<String, dynamic> row, String sessionId) =>
      (!hasSessionColumn || row['session_id'] == sessionId) &&
      requiredText.every((key) => row[key] is String) &&
      requiredInt.every((key) => row[key] is int) &&
      uniqueColumns.every((key) => row[key] != '') &&
      (!requiredText.contains('entity_id') || row['entity_id'] != '');

  String identity(Map<String, dynamic> row) =>
      jsonEncode(uniqueColumns.map((key) => row[key]).toList());
}

extension on _BackupImportPlan {
  void _addRowSession(
    Map<String, dynamic> session,
    String id, {
    required bool deferExperienceIdChecks,
    required bool strictCollections,
  }) {
    final validated = Map<String, dynamic>.of(session);
    for (final section in _sessionRows.entries) {
      final name = section.key;
      if (!session.containsKey(name)) continue;

      final raw = session[name];
      if (raw is! List<dynamic>) {
        if (strictCollections) {
          throw const FormatException('Invalid backup session collection');
        }
        _countSkippedRows(name, 1);
        validated.remove(name);
        continue;
      }

      final rows = <Map<String, dynamic>>[];
      final seenKeys = <String>{};
      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;
        _checkSessionOwner(
          item,
          id,
          isExperience: name == 'experientialMemories',
        );

        final format = section.value;
        final row = _normalizeSessionRow(name, item);
        if (!format.accepts(row, id)) continue;
        if (name == 'agentEvents' &&
            row['time'] is! num &&
            row['time'] is! String) {
          continue;
        }
        if (format.uniqueColumns.isNotEmpty) {
          final key = format.identity(row);
          if (!seenKeys.add(key)) {
            if (name == 'messageVariants') {
              // 同号稿件无法各自关联正文和派生记录，保留整个原库。
              throw const BackupDraftIndexConflictException();
            }
            continue;
          }
          if (format.globallyUnique &&
              !(deferExperienceIdChecks && name == 'experientialMemories')) {
            final owners = _sessionRowOwners.putIfAbsent(name, () => {});
            if ((owners[key] ??= id) != id) {
              throw const FormatException(
                'Backup row has conflicting session owners',
              );
            }
          }
        }
        rows.add(row);
      }
      _countSkippedRows(name, raw.length - rows.length);
      validated[name] = rows;
    }

    final entities = _storedSessionRows(validated, 'factualEntities')
        .map((row) => row['entity_id'])
        .toSet();
    for (final name in ['factualAttributes', 'factualHistory']) {
      if (_storedSessionRows(validated, name)
          .any((row) => !entities.contains(row['entity_id']))) {
        // History may reference a removed attribute. Its entity must survive,
        // because it provides the history row's session ownership.
        throw const FormatException('Backup fact row has no restorable entity');
      }
    }
    rowSessions.add(validated);
  }

  void _validateUniqueExperienceOwners() {
    final owners = <String, String>{};
    for (final session in rowSessions) {
      for (final memory
          in _storedSessionRows(session, 'experientialMemories')) {
        final id = memory['memory_id'] as String;
        final sessionId = memory['session_id'] as String;
        if ((owners[id] ??= sessionId) != sessionId) {
          throw const BackupExperienceIdConflictException();
        }
      }
    }
  }

  void _countSkippedRows(String section, int count) {
    if (section == 'messages') {
      skippedMessages += count;
    } else {
      skippedSessionRows += count;
    }
  }
}

bool _hasExperienceOwners(Map<String, dynamic> session, String sessionId) {
  var hasMissingOwner = false;
  if (session['experientialMemories'] case final List<dynamic> rows) {
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      if (row.isEmpty) continue;
      final owner = row['session_id'];
      if (owner is! String || owner.isEmpty) {
        hasMissingOwner = true;
      } else {
        _checkSessionOwner(row, sessionId, isExperience: true);
      }
    }
  }
  return !hasMissingOwner;
}

void _checkSessionOwner(
  Map<String, dynamic> row,
  String sessionId, {
  required bool isExperience,
}) {
  final owner = row['session_id'];
  if (owner is String && owner.isNotEmpty && owner != sessionId) {
    if (isExperience) {
      throw const BackupExperienceIdConflictException.ownerMismatch();
    }
    throw const FormatException('Backup row belongs to a different session');
  }
}

Map<String, dynamic> _normalizeSessionRow(
  String name,
  Map<String, dynamic> row,
) {
  if (name != 'experientialMemories') return row;
  final id = row['memory_id'];
  final embedding = row['embedding'];
  if (id is! num && embedding is! String) return row;

  final normalized = Map<String, dynamic>.of(row);
  if (id is num && id.isFinite) {
    // Older hand-edited backups can store numeric IDs in TEXT columns.
    normalized['memory_id'] = id.toString();
  }
  if (embedding is String) {
    try {
      normalized['embedding'] = base64Encode(base64Decode(embedding));
    } on FormatException {
      // Keep the valid experience when only the optional vector is corrupt.
      normalized.remove('embedding');
    }
  }
  return normalized;
}

List<Map<String, dynamic>> _storedSessionRows(
  Map<String, dynamic> session,
  String name,
) =>
    (session[name] as List<dynamic>?)
        ?.whereType<Map<String, dynamic>>()
        .toList() ??
    const [];
