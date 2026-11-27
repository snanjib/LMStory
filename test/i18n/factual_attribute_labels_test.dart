import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/facts_change_detail_dialog.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_detail_dialog.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_attribute_dialog.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_round_panels_builder.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  const relationshipKey = 'relationship:守碑人';
  final createdAt = DateTime(2026);

  FactualAttribute attribute(String key, String value) => FactualAttribute(
        attributeId: key,
        entityId: 'entity',
        sessionId: 'story',
        attrKey: key,
        value: value,
        importance: 3,
        createdAt: createdAt,
      );

  Widget launcher(VoidCallback Function(BuildContext) open) =>
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: open(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.enUs);
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.enUs);
    addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.zhCn));
  });

  testWidgets('fact details translate built-ins and keep story text', (
    tester,
  ) async {
    final fact = RetrievedFact(
      entity: FactualEntity(
        entityId: 'entity',
        sessionId: 'story',
        type: FactualEntityType.character,
        primaryName: '林晚',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: createdAt,
      ),
      attributes: [
        attribute('personality', '冷静'),
        attribute(relationshipKey, '旧友'),
        attribute('随身物件', '银钥匙'),
      ],
      isKeyEntity: false,
      isKeywordMatched: false,
    );
    await tester.pumpWidget(
      launcher(
        (context) => () => FactualDetailDialog.show(context, fact: fact),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Personality'), findsOneWidget);
    expect(find.text('Relationship with 守碑人'), findsOneWidget);
    for (final text in ['林晚', '冷静', '旧友', '随身物件', '银钥匙']) {
      expect(find.text(text), findsOneWidget);
    }

    LocaleSettings.setLocaleSync(AppLocale.zhCn);
    await tester.pumpAndSettle();
    expect(find.text('性格'), findsOneWidget);
    expect(find.text('与 守碑人 的关系'), findsOneWidget);
  });

  testWidgets('fact change details preserve relationship history', (
    tester,
  ) async {
    await tester.pumpWidget(
      launcher(
        (context) => () => FactsChangeDetailDialog.show(
              context,
              record: const FactsChangeRecord(
                action: FactAction.updateAttr,
                confidence: 5,
                entityType: 'character',
                primaryName: '林晚',
                attrKey: relationshipKey,
                oldValue: '旧友',
                newValue: '盟友',
              ),
            ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Relationship with 守碑人'), findsOneWidget);
    expect(find.text('旧友'), findsOneWidget);
    expect(find.text('盟友'), findsOneWidget);
  });

  testWidgets('history and newly applied changes share verified fact labels', (
    tester,
  ) async {
    final fixture = await tester.runAsync(() async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final chat = ChatRepositoryImpl(database: db);
      final session = await chat.createSession(title: 'Synthetic story');
      final foreign = await chat.createSession(title: 'Other synthetic story');
      final repo = FactualRepositoryImpl(database: db);

      Future<void> create(
        String id,
        FactualEntityType type,
        String name, {
        String? sessionId,
      }) =>
          repo.createEntity(
            FactualEntity(
              entityId: id,
              sessionId: sessionId ?? session.sessionId,
              type: type,
              primaryName: name,
              aliases: const [],
              importance: 3,
              createdTurn: 1,
              createdAt: createdAt,
            ),
          );

      await create('key', FactualEntityType.item, '青铜钥匙');
      await create('gate', FactualEntityType.location, '海边城门');
      await create('actor', FactualEntityType.character, '林晚');
      await create(
        'foreign',
        FactualEntityType.character,
        '异线角色',
        sessionId: foreign.sessionId,
      );

      final applier = FactApplier(repository: repo);
      Future<List<FactsChangeRecord>> apply(
        int turn,
        List<FactsDelta> deltas,
      ) =>
          applier.applyDeltas(
            session.sessionId,
            deltas,
            turn,
            const FactualConfig(),
          );
      const owner = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'key',
        attrKey: 'owner',
        value: '守碑人',
        confidence: 5,
      );
      await apply(1, [owner]);
      final changes = await apply(2, const [
        FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'key',
          attrKey: 'owner',
          value: '林晚',
          confidence: 5,
        ),
        FactsDelta(
          action: FactAction.appendList,
          entityId: 'gate',
          attrKey: 'features',
          value: '风化的城墙',
          confidence: 5,
        ),
        FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'actor',
          attrKey: '随身物件',
          value: '银钥匙',
          confidence: 5,
        ),
      ]);
      expect(
        changes.map((change) => change.entityType),
        ['item', 'location', 'character'],
      );
      expect(
        (await repo.getAttributesByKey('key', 'owner')).single.value,
        '林晚',
      );
      final placeJson = changes[1].toJson()..remove('entityType');
      final history = StoryRoundArtifacts(
        sessionId: session.sessionId,
        turnNumber: 2,
        createdAt: createdAt,
        factsChanges: [
          FactsChangeRecord.fromJson(changes.first.toJson()),
          FactsChangeRecord.fromJson(placeJson),
          changes[2],
          const FactsChangeRecord(
            action: FactAction.updateAttr,
            entityId: 'foreign',
            entityType: 'unknown_legacy_type',
            attrKey: 'personality',
            newValue: '保留这句原文',
            confidence: 4,
          ),
        ],
      );
      return (history: history, repository: repo);
    });
    if (fixture == null) fail('Fact creation did not return a history fixture');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          factualRepositoryProvider.overrideWithValue(fixture.repository),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(body: buildHistoryFactsChangePanel(fixture.history)),
          ),
        ),
      ),
    );

    await tester.tap(
      find.text(t.intermediate.chat.historyFactsChangeReady(turn: 2, count: 4)),
    );
    await tester.pumpAndSettle();
    expect(find.text('key · Owner'), findsOneWidget);
    expect(find.text('gate · Features'), findsOneWidget);
    expect(find.text('actor · 随身物件'), findsOneWidget);
    expect(find.text('foreign · personality'), findsOneWidget);

    Future<void> open(String row) async {
      await tester.tap(find.text(row));
      await tester.pumpAndSettle();
    }

    Future<void> close() async {
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
    }

    await open('key · Owner');
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('守碑人'), findsOneWidget);
    expect(find.text('林晚'), findsOneWidget);
    LocaleSettings.setLocaleSync(AppLocale.zhCn);
    await tester.pumpAndSettle();
    expect(find.text('所有者'), findsOneWidget);
    await close();
    expect(find.text('key · 所有者'), findsOneWidget);

    await open('gate · 特征');
    expect(find.text('特征'), findsOneWidget);
    expect(find.text('风化的城墙'), findsOneWidget);
    LocaleSettings.setLocaleSync(AppLocale.enUs);
    await tester.pumpAndSettle();
    expect(find.text('Features'), findsOneWidget);
    await close();

    await open('foreign · personality');
    expect(find.text('personality'), findsOneWidget);
    expect(find.text('保留这句原文'), findsOneWidget);
  });

  testWidgets('editing a relationship returns the original storage key', (
    tester,
  ) async {
    FactualAttributeEditResult? result;
    await tester.pumpWidget(
      launcher(
        (context) => () async {
          result = await showDialog<FactualAttributeEditResult>(
            context: context,
            builder: (_) => FactualAttributeEditDialog(
              attribute: attribute(relationshipKey, '旧友'),
              entityType: FactualEntityType.character,
              title: 'Edit attribute',
            ),
          );
        },
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Relationship with 守碑人'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '盟友');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.attrKey, relationshipKey);
    expect(result?.value, '盟友');
  });
}
