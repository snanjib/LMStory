import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_world_status_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  late Translations zh;

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    zh = await AppLocale.zhCn.build();
  });

  FactualEntity makeEntity(
    String id,
    String name, {
    FactualEntityType type = FactualEntityType.character,
    FactualSource source = FactualSource.auto,
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: type,
        primaryName: name,
        aliases: const [],
        importance: 5,
        source: source,
        createdTurn: 1,
        createdAt: DateTime(2026),
      );

  DirectorCoreBlocksData sampleData({int foreshadowCount = 2}) =>
      DirectorCoreBlocksData(
        keyEntities: [
          makeEntity('ent_1', '沈墨', source: FactualSource.card),
          makeEntity(
            'ent_2',
            '青崖驿',
            type: FactualEntityType.location,
            source: FactualSource.worldbook,
          ),
        ],
        recentActiveEntities: [
          makeEntity('ent_3', '驿丞'),
        ],
        attributesByEntity: {
          'ent_1': [
            FactualAttribute(
              attributeId: 'a1',
              entityId: 'ent_1',
              sessionId: 's1',
              attrKey: '伤势',
              value: '右臂渗血 [ent_3]',
              importance: 5,
              createdAt: DateTime(2026),
            ),
            FactualAttribute(
              attributeId: 'a2',
              entityId: 'ent_1',
              sessionId: 's1',
              attrKey: 'relationship:ent_3',
              value: '互生猜忌',
              importance: 4,
              createdAt: DateTime(2026),
            ),
          ],
          'ent_2': [
            FactualAttribute(
              attributeId: 'a3',
              entityId: 'ent_2',
              sessionId: 's1',
              attrKey: 'description',
              value: '["雨夜孤驿","暗门封锁"]',
              valueType: AttributeValueType.list,
              importance: 4,
              createdAt: DateTime(2026),
            ),
          ],
        },
        latestMacros: [
          ExperientialMemory(
            memoryId: 'm1',
            sessionId: 's1',
            importance: 5,
            tags: const [],
            turnNumber: 4,
            createdAt: DateTime(2026),
            summary: '众人因暴雨困于驿站 [ent_2]',
            memoryLevel: MemoryLevel.macro,
          ),
        ],
        narrativeTime: '第四夜子时',
        anchor: StoryAnchor(
          updatedTurn: 4,
          narrativeTime: '第四夜子时',
          arc: '青崖驿迷局',
          oneLiner: '灯灭门锁',
          foreshadows: [
            for (var i = 1; i <= foreshadowCount; i++)
              AnchorForeshadow(
                text: '线索 $i',
                resolved: i == foreshadowCount && foreshadowCount > 1,
              ),
          ],
        ),
      );

  Widget wrap(
    Widget child, {
    ThemeData? theme,
    double textScale = 1.0,
    double width = 390,
  }) {
    return TranslationProvider(
      child: MaterialApp(
        theme: theme ??
            ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(body: child),
        ),
      ),
    );
  }

  group('DirectorWorldStatusSheet', () {
    testWidgets(
        'renders quick actions, world now, foreshadows, and key/recent entities without ent_xxx leaks',
        (tester) async {
      var memoryOpened = false;
      var pureToggled = false;
      var exported = false;
      var titleUpdated = false;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => DirectorWorldStatusSheet.show(
                  context,
                  loader: () async => sampleData(),
                  pureReading: false,
                  isGenerating: false,
                  onOpenMemory: () => memoryOpened = true,
                  onTogglePureReading: () => pureToggled = true,
                  onExport: () => exported = true,
                  onUpdateTitle: () => titleUpdated = true,
                  onEditAnchor: (_) async => true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(zh.advanced.worldSheet.title), findsOneWidget);
      expect(find.text('第四夜子时'), findsOneWidget);
      expect(find.text('青崖驿迷局'), findsOneWidget);
      expect(find.text('灯灭门锁'), findsOneWidget);
      expect(find.text('沈墨'), findsOneWidget);
      expect(find.text('青崖驿'), findsOneWidget);
      expect(find.text('驿丞'), findsOneWidget);
      expect(find.textContaining('与 驿丞 的关系'), findsOneWidget);
      expect(find.textContaining('雨夜孤驿'), findsOneWidget);

      // Zero ent_xxx leaks anywhere
      final allTexts = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .join('\n');
      expect(allTexts, isNot(contains('ent_')));

      // Quick actions work
      await tester.tap(find.byKey(const ValueKey('world-status-pure-reading')));
      await tester.pump();
      expect(pureToggled, isTrue);

      await tester.tap(find.byKey(const ValueKey('world-status-open-memory')));
      await tester.pumpAndSettle();
      expect(memoryOpened, isTrue);

      // Re-open to test export and update title
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('world-status-export')));
      await tester.pumpAndSettle();
      expect(exported, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('world-status-update-title')));
      await tester.pumpAndSettle();
      expect(titleUpdated, isTrue);
    });

    testWidgets('supports anchor editing and null loader fallback', (
      tester,
    ) async {
      StoryAnchor? saved;
      await tester.pumpWidget(
        wrap(
          DirectorWorldStatusPanel(
            loader: () async => null,
            fallbackAnchor: const StoryAnchor(
              updatedTurn: 2,
              arc: '旧弧线',
              narrativeTime: '次日清晨',
            ),
            pureReading: false,
            isGenerating: false,
            onOpenMemory: () {},
            onTogglePureReading: () {},
            onExport: () {},
            onUpdateTitle: () {},
            onEditAnchor: (anchor) async {
              saved = anchor;
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('次日清晨'), findsOneWidget);
      expect(find.text('旧弧线'), findsOneWidget);
      expect(
        find.text(zh.advanced.worldSheet.entitiesUnavailable),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('world-status-edit-anchor')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('anchor-edit-save')));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
    });

    testWidgets('folds long open foreshadow lists and expands on demand', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          DirectorWorldStatusPanel(
            loader: () async => sampleData(foreshadowCount: 9),
            pureReading: false,
            isGenerating: false,
            onOpenMemory: () {},
            onTogglePureReading: () {},
            onExport: () {},
            onUpdateTitle: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('线索 6'), findsOneWidget);
      expect(find.text('线索 7'), findsNothing);
      await tester
          .tap(find.text(zh.advanced.recap.foreshadowsExpandAll(count: 2)));
      await tester.pump();
      expect(find.text('线索 7'), findsOneWidget);
      expect(find.text('线索 8'), findsOneWidget);
    });
  });

  group('4 structures x 2 palettes x light/dark at 320dp & 1.3x fontScale', () {
    for (final structure in ThemeCatalog.structures) {
      for (final palette in ThemeCatalog.palettes) {
        for (final brightness in Brightness.values) {
          testWidgets(
              'panel zero overflow: ${structure.id}/${palette.id}/${brightness.name}',
              (tester) async {
            final theme = ThemeCatalog.assemble(
              LmAppearance(structureId: structure.id, paletteId: palette.id),
              brightness,
            );
            await tester.pumpWidget(
              wrap(
                DirectorWorldStatusPanel(
                  loader: () async => sampleData(),
                  pureReading: false,
                  isGenerating: false,
                  onOpenMemory: () {},
                  onTogglePureReading: () {},
                  onExport: () {},
                  onUpdateTitle: () {},
                  onEditAnchor: (_) async => true,
                  onClose: () {},
                ),
                theme: theme,
                textScale: 1.3,
                width: 320,
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });
}
