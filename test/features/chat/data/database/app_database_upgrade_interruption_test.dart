import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/database/database_connection.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
// Open the file independently of Drift, using its SQLite dependency.
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart' show OpenMode, sqlite3;

import 'fixtures/public_schema_v54.dart';

const _legacyVersion = 54;
const _originalRelationships = '{"苏晴":"信任","师门众人":"交恶"}';
const _remainingRelationships = '{"师门众人":"交恶"}';
const _splitReason = '关系拆分迁移：个人关系按对象拆出';

const _conversation = {
  'sessions': [
    {
      'session_id': 'session-1',
      'title': '临时故事',
      'mode': 'advanced',
      'max_steps': 17,
      'narrative_pacing': 'aggressive',
      'watch_mode': 1,
    },
  ],
  'experiences': [
    {
      'memory_id': 'legacy-experience',
      'session_id': 'session-1',
      'summary': '林舟认识了苏晴。',
      'turn_number': 5,
      'source': 'auto',
      'has_verified_source_turn': 0,
    },
  ],
  'messages': [
    {
      'message_id': 'message-1',
      'session_id': 'session-1',
      'role': 'user',
      'content': '林舟去见苏晴。',
    },
  ],
};

const _readIndexes = [
  'idx_ira_session_turn',
  'idx_msg_session_latest',
  'idx_session_latest_story',
  'idx_session_recent',
];

const _legacyAttribute = {
  'entity_id': 'person-1',
  'session_id': 'session-1',
  'attr_key': 'relationships',
  'value': _originalRelationships,
  'value_type': 'dict',
  'source': 'auto',
  'updated_turn': 5,
};

const _legacyHistory = {
  'attr_key': 'relationships',
  'entity_id': 'person-1',
  'action': 'update_attr',
  'old_value': '{}',
  'new_value': _originalRelationships,
  'reason': '原有关系更新',
  'turn_number': 5,
};

final _upgraded = {
  ..._conversation,
  'user_version': AppDatabase.currentSchemaVersion,
  'attributes': [
    {
      ..._legacyAttribute,
      'attr_key': 'relationship:苏晴',
      'value': '信任',
      'value_type': 'single',
    },
    {..._legacyAttribute, 'value': _remainingRelationships},
  ],
  'history': [
    _legacyHistory,
    {
      ..._legacyHistory,
      'attr_key': 'relationship:苏晴',
      'old_value': null,
      'new_value': '信任',
      'reason': _splitReason,
    },
    {
      ..._legacyHistory,
      'old_value': _originalRelationships,
      'new_value': _remainingRelationships,
      'reason': _splitReason,
    },
  ],
  'backups': [
    {
      'attribute_id': 'legacy-relationships',
      'entity_id': 'person-1',
      'session_id': 'session-1',
      'attr_key': 'relationships',
      'value': _originalRelationships,
      'value_type': 'dict',
    },
  ],
};

void main() {
  late File file;

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('lmstory_upgrade_');
    addTearDown(() async => directory.delete(recursive: true));
    file = File('${directory.path}/test.sqlite');
    await _seedVersion54(file);
  });

  test('正常升级拆分关系并保留会话、消息、设置和历史', () async {
    await _openAndClose(file);

    expect(_readState(file), _upgraded);
  });

  test('结构修复后中断保留旧版本，重开补完迁移且再次打开不重复', () async {
    final interrupted = _InterruptAfterRepair(await openNativeDatabase(file));
    try {
      await expectLater(
        interrupted.customSelect('SELECT 1').get(),
        throwsA(
          isA<Object>().having(
            (error) => error.toString(),
            'description',
            contains(_interruptionMessage),
          ),
        ),
      );
    } finally {
      await interrupted.close();
    }
    final afterInterruption = _readState(file);

    await _openAndClose(file);
    final afterRetry = _readState(file);

    expect(
      {'中断后': afterInterruption, '重开后': afterRetry},
      {
        '中断后': {
          ..._conversation,
          'user_version': _legacyVersion,
          'attributes': [_legacyAttribute],
          'history': [_legacyHistory],
          'backups': isEmpty,
        },
        '重开后': _upgraded,
      },
    );

    await _openAndClose(file);
    expect(_readState(file), afterRetry);
  });

  test('已误标为 55 的旧库保留关系流水，升级时不猜测补跑', () async {
    final raw = sqlite3.open(file.path);
    try {
      raw.userVersion = 55;
    } finally {
      raw.close();
    }

    await _openAndClose(file);
    expect(
      _readState(file),
      {
        ..._conversation,
        'user_version': AppDatabase.currentSchemaVersion,
        'attributes': [_legacyAttribute],
        'history': [_legacyHistory],
        'backups': isEmpty,
      },
    );
  });
}

Future<void> _openAndClose(File file) async {
  final db = AppDatabase.forTesting(await openNativeDatabase(file));
  try {
    await db.customSelect('SELECT 1').get();
  } finally {
    await db.close();
  }
}

Future<void> _seedVersion54(File file) async {
  await file.writeAsBytes(
    gzip.decode(base64Decode(publicSchemaV54SqliteGzip)),
    flush: true,
  );
  final raw = sqlite3.open(file.path, mode: OpenMode.readWrite);
  try {
    expect(raw.userVersion, _legacyVersion);
    expect(
      raw
          .select("PRAGMA table_info('experiential_memories')")
          .map((column) => column['name']),
      isNot(contains('has_verified_source_turn')),
    );
    raw
      ..execute(
        'INSERT INTO chat_sessions '
        '(session_id, title, mode, max_steps, narrative_pacing, watch_mode) '
        "VALUES ('session-1', '临时故事', 'advanced', 17, 'aggressive', 1)",
      )
      ..execute(
        'INSERT INTO chat_messages (message_id, session_id, role, content) '
        "VALUES ('message-1', 'session-1', 'user', '林舟去见苏晴。')",
      )
      ..execute(
        'INSERT INTO factual_entities '
        '(entity_id, session_id, type, primary_name, created_turn) VALUES '
        "('person-1', 'session-1', 'character', '林舟', 1), "
        "('person-2', 'session-1', 'character', '苏晴', 1)",
      )
      ..execute(
        'INSERT INTO factual_attributes '
        '(attribute_id, entity_id, session_id, attr_key, value, value_type, updated_turn) '
        "VALUES ('legacy-relationships', 'person-1', 'session-1', 'relationships', ?, 'dict', 5)",
        [_originalRelationships],
      )
      ..execute(
        'INSERT INTO factual_memory_history '
        '(entity_id, attribute_id, action, old_value, new_value, reason, turn_number) '
        "VALUES ('person-1', 'legacy-relationships', 'update_attr', '{}', ?, '原有关系更新', 5)",
        [_originalRelationships],
      )
      ..execute(
        'INSERT INTO experiential_memories '
        '(memory_id, session_id, summary, turn_number) '
        "VALUES ('legacy-experience', 'session-1', '林舟认识了苏晴。', 5)",
      );
  } finally {
    raw.close();
  }
}

Map<String, Object> _readState(File file) {
  final raw = sqlite3.open(file.path, mode: OpenMode.readOnly);
  try {
    expect(raw.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(
      raw
          .select("SELECT name FROM sqlite_schema WHERE type = 'index'")
          .map((row) => row['name']),
      containsAll(_readIndexes),
    );
    return {
      'user_version': raw.userVersion,
      'sessions': raw.select(
        'SELECT session_id, title, mode, max_steps, narrative_pacing, watch_mode '
        'FROM chat_sessions ORDER BY id',
      ),
      'messages': raw.select(
        'SELECT message_id, session_id, role, content '
        'FROM chat_messages ORDER BY id',
      ),
      'experiences': raw.select(
        'SELECT memory_id, session_id, summary, turn_number, source, '
        'has_verified_source_turn FROM experiential_memories ORDER BY id',
      ),
      'attributes': raw.select(
        'SELECT entity_id, session_id, attr_key, value, value_type, source, updated_turn '
        'FROM factual_attributes ORDER BY attr_key',
      ),
      'history': raw.select(
        'SELECT a.attr_key, h.entity_id, h.action, h.old_value, h.new_value, h.reason, h.turn_number '
        'FROM factual_memory_history h LEFT JOIN factual_attributes a '
        'ON h.attribute_id = a.attribute_id ORDER BY h.id',
      ),
      'backups': raw.select(
        'SELECT attribute_id, entity_id, session_id, attr_key, value, value_type '
        'FROM factual_relationship_migration_backup ORDER BY id',
      ),
    };
  } finally {
    raw.close();
  }
}

class _InterruptAfterRepair extends AppDatabase {
  _InterruptAfterRepair(super.e) : super.forTesting();

  @override
  Future<SchemaRepairResult> repairSchema() async {
    await super.repairSchema();
    throw StateError(_interruptionMessage);
  }
}

const _interruptionMessage = 'Synthetic interruption after schema repair';
