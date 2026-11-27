import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';

void main() {
  test('旧库自动记忆即使有正轮号，升级后仍不能证明来源', () async {
    final directory = await Directory.systemTemp.createTemp('lmstory_source_');
    final file = File('${directory.path}/synthetic.db');
    AppDatabase? db;

    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      final chatRepository = ChatRepositoryImpl(database: db);
      final session = await chatRepository.createSession(
        title: '合成旧会话',
        mode: 'intermediate',
      );
      final oldMemory = await ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      ).appendExperience(
        sessionId: session.sessionId,
        summary: '合成的旧往事',
        importance: 4,
        tags: const ['旧物'],
        turnNumber: 37,
        narrativeTime: '旅途第三天',
      );
      await db.close();
      db = null;

      // 模拟旧库：保留自动记忆及旧字段，去掉新列后将版本设为 55。
      final oldNative = NativeDatabase(
        file,
        setup: (raw) {
          raw
            ..execute(
              'ALTER TABLE experiential_memories '
              'DROP COLUMN has_verified_source_turn',
            )
            ..execute('PRAGMA user_version = 55');
          final columns =
              raw.select('PRAGMA table_info(experiential_memories)');
          expect(
            columns.map((row) => row['name']),
            isNot(contains('has_verified_source_turn')),
          );
          expect(raw.select('PRAGMA user_version').single['user_version'], 55);
          final rows = raw.select(
            'SELECT memory_id, source, turn_number FROM experiential_memories',
          );
          expect(rows, hasLength(1));
          expect(rows.single['memory_id'], oldMemory.memoryId);
          expect(rows.single['source'], 'auto');
          expect(rows.single['turn_number'], 37);
        },
      );

      db = AppDatabase.forTesting(oldNative);
      final upgradedMemory = (await ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      ).getRecentExperiences(session.sessionId, limit: 1))
          .single;

      expect(upgradedMemory.memoryId, oldMemory.memoryId);
      expect(upgradedMemory.source, 'auto');
      expect(upgradedMemory.turnNumber, 37);
      expect(upgradedMemory.summary, '合成的旧往事');
      expect(upgradedMemory.narrativeTime, '旅途第三天');
      expect(upgradedMemory.importance, 4);
      expect(upgradedMemory.hasVerifiedSourceTurn, isFalse);

      final columns = await db
          .customSelect('PRAGMA table_info(experiential_memories)')
          .get();
      final sourceColumn = columns.singleWhere(
        (row) => row.read<String>('name') == 'has_verified_source_turn',
      );
      expect(sourceColumn.read<int>('notnull'), 1);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(
        version.read<int>('user_version'),
        AppDatabase.currentSchemaVersion,
      );
      expect(AppDatabase.currentSchemaVersion, greaterThan(55));
    } finally {
      await db?.close();
      await directory.delete(recursive: true);
    }
  });
}
