part of 'data_management_service.dart';

extension on DataManagementService {
  Future<void> _verifyRecoverySessions(_BackupImportPlan plan) async {
    final actual = await backupRepository.exportAllSessionsData();
    if (plan.version == null || plan.version == 1) {
      _verifyOldSessions(plan.oldSessions, actual);
      return;
    }

    final byId = <Object?, Map<String, dynamic>>{
      for (final session in actual)
        if (session['session'] case final Map<String, dynamic> row)
          row['session_id']: session,
    };
    if (actual.length != plan.rowSessions.length ||
        byId.length != actual.length) {
      throw StateError('Trial recovery session count did not match the backup');
    }

    final hasGlobalEvents = plan.assets['agentEvents']?.isNotEmpty ?? false;
    for (final expected in plan.rowSessions) {
      final expectedSession = expected['session'] as Map<String, dynamic>;
      final session = byId[expectedSession['session_id']];
      if (session == null ||
          !_matchesStoredRow(
            expectedSession,
            session['session'] as Map<String, dynamic>,
          )) {
        throw StateError('Trial recovery session did not match the backup');
      }

      for (final section in _sessionRows.entries) {
        if (!_matchesStoredRows(
          _storedSessionRows(expected, section.key),
          _storedSessionRows(session, section.key),
          section.value,
          allowExtraRows: hasGlobalEvents && section.key == 'agentEvents',
        )) {
          throw StateError(
            'Trial recovery session rows did not match the backup',
          );
        }
      }
    }
  }
}

bool _matchesStoredRows(
  List<Map<String, dynamic>> expected,
  List<Map<String, dynamic>> actual,
  _SessionRowFormat format, {
  required bool allowExtraRows,
}) {
  if (!allowExtraRows && expected.length != actual.length) return false;
  if (expected.isEmpty) return true;

  // Bucketing by the row's key (or by its required fields for history-like
  // collections) avoids scanning all messages for each expected row.
  String key(Map<String, dynamic> row) => format.uniqueColumns.isNotEmpty
      ? format.identity(row)
      : jsonEncode([
          for (final column in [...format.requiredText, ...format.requiredInt])
            row[column],
        ]);
  final remaining = groupBy(actual, key);
  for (final row in expected) {
    final candidates = remaining[key(row)];
    if (candidates == null) return false;
    final index =
        candidates.indexWhere((candidate) => _matchesStoredRow(row, candidate));
    if (index < 0) return false;
    candidates.removeAt(index);
  }
  return true;
}

bool _matchesStoredRow(
  Map<String, dynamic> expected,
  Map<String, dynamic> actual,
) {
  for (final entry in expected.entries) {
    final key = entry.key;
    // SQLite allocates the row ID. Unknown columns have always been ignored
    // by the backup importer for compatibility with different schemas.
    if (key == 'id' || !actual.containsKey(key)) continue;
    final value = entry.value;
    final stored = actual[key];
    if (value == stored) continue;
    if (value is bool && stored == (value ? 1 : 0)) continue;
    // Old vector rows are backfilled from the actual BLOB after import.
    if (key == 'embedding_dimensions' && value == null && stored is int) {
      continue;
    }
    return false;
  }
  return true;
}

void _verifyOldSessions(
  List<_OldSessionImport> expected,
  List<Map<String, dynamic>> actual,
) {
  if (expected.length != actual.length) {
    throw StateError('Trial recovery session count did not match the backup');
  }

  // v1 and legacy imports allocate new session IDs and may allocate message
  // IDs. Match the sessions with explicit message IDs first, then compare
  // the remaining sessions by their preserved values.
  final remaining = actual.toList();
  final ordered = [
    ...expected
        .where((session) => session.messages.any((row) => row.id != null)),
    ...expected
        .where((session) => session.messages.every((row) => row.id == null)),
  ];
  for (final expectedSession in ordered) {
    final index = remaining.indexWhere((row) {
      final session = row['session'] as Map<String, dynamic>;
      return session['title'] == expectedSession.session.title &&
          session['mode'] == expectedSession.session.mode &&
          _matchesOldMessages(
            expectedSession.messages,
            _storedSessionRows(row, 'messages'),
          );
    });
    if (index < 0) {
      throw StateError(
        'Trial recovery legacy messages did not match the backup',
      );
    }
    remaining.removeAt(index);
  }
}

bool _matchesOldMessages(
  List<_OldMessageImport> expected,
  List<Map<String, dynamic>> actual,
) {
  if (expected.length != actual.length) return false;

  String key(Object? role, Object? content, Object? parent) =>
      jsonEncode([role, content, parent]);
  final remaining = groupBy(
    actual,
    (row) => key(row['role'], row['content'], row['parent_user_msg_id']),
  );
  // Explicit IDs are more specific than rows with tool-generated IDs.
  final ordered = [
    ...expected.where((message) => message.id != null),
    ...expected.where((message) => message.id == null),
  ];
  for (final entry in ordered) {
    final message = entry.message;
    final candidates =
        remaining[key(message.role, message.content, message.parentUserMsgId)];
    if (candidates == null || candidates.isEmpty) return false;
    final index = entry.id == null
        ? 0
        : candidates.indexWhere((row) => row['message_id'] == entry.id);
    if (index < 0) return false;
    candidates.removeAt(index);
  }
  return true;
}
