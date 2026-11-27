import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';

const savedFixtureFactName = 'Brass Beacon';
const _savedFactValue = 'lantern calibration marker';
const _rejectedFactName = 'Harbor Signal Booth';
const _rejectedFactValue = 'temporary fog marker';

const factWriteFixtureDeltas = [
  FactsDelta(
    action: FactAction.createEntity,
    entityType: 'location',
    primaryName: _rejectedFactName,
    attrKey: 'description',
    value: _rejectedFactValue,
    confidence: 5,
  ),
  FactsDelta(
    action: FactAction.createEntity,
    entityType: 'location',
    primaryName: savedFixtureFactName,
    attrKey: 'description',
    value: _savedFactValue,
    confidence: 5,
  ),
];

const guardedFactFixtureDeltas = [
  FactsDelta(
    action: FactAction.updateAttr,
    primaryName: savedFixtureFactName,
    attrKey: 'unsupported_field',
    value: 'unsupported value',
    reason: 'Synthetic unsupported field',
    confidence: 5,
  ),
  FactsDelta(
    action: FactAction.updateAttr,
    primaryName: savedFixtureFactName,
    attrKey: 'description',
    value: _savedFactValue,
    reason: 'The observation is unchanged',
    confidence: 5,
  ),
];

/// Reject the history insert after the fact's attribute is visible in SQLite.
Future<void> rejectFixtureFactHistory(AppDatabase database) =>
    database.customStatement('''
      CREATE TRIGGER reject_fixture_fact
      BEFORE INSERT ON factual_memory_history
      WHEN NEW.new_value = '$_rejectedFactName'
        AND EXISTS (
          SELECT 1 FROM factual_attributes
          WHERE entity_id = NEW.entity_id AND value = '$_rejectedFactValue'
        )
      BEGIN
        SELECT RAISE(ABORT, 'synthetic fact history failure');
      END
    ''');

Future<void> expectCommittedFactFixtureRound(
  AppDatabase database, {
  required String sessionId,
  required String userInput,
  required String reply,
  required String summary,
  required String what,
}) async {
  final chat = ChatRepositoryImpl(database: database);
  final messages = await chat.getMessages(sessionId);
  expect(messages.map((message) => message.content), [userInput, reply]);

  final experiences = ExperienceRepositoryImpl(
    database: database,
    vectorEngine: const VectorEngine(),
  );
  final experience = (await experiences.getAllExperiences(sessionId)).single;
  expect(experience.summary, summary);
  expect(experience.what, what);
  expect(experience.turnNumber, 1);

  final facts = FactualRepositoryImpl(database: database);
  final entity = (await facts.getEntities(sessionId)).single;
  expect(entity.primaryName, savedFixtureFactName);
  final attributes = await facts.getAttributes(sessionId, [entity.entityId]);
  expect(attributes.single.value, _savedFactValue);
  final history = (await facts.getHistory(entity.entityId)).single;
  expect(history.action, FactAction.createEntity);
  expect(history.newValue, savedFixtureFactName);
  expect(history.turnNumber, 1);
  expect(
    await facts.searchEntitiesByText(sessionId, [_rejectedFactValue]),
    isEmpty,
  );
}
