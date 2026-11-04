import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_script_board_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 场记板视图 widget 测试
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  FactualEntity entity(
    String id,
    String name, {
    bool disabled = false,
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: name,
        aliases: const [],
        importance: 6,
        createdTurn: 1,
        createdAt: DateTime(2026),
        injectionDisabled: disabled,
      );

  final data = DirectorCoreBlocksData(
    keyEntities: [entity('e1', '灯塔')],
    attributesByEntity: {
      'e1': [
        FactualAttribute(
          attributeId: 'a1',
          entityId: 'e1',
          sessionId: 's1',
          attrKey: '状态',
          value: '熄灭',
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
        turnNumber: 1,
        createdAt: DateTime(2026),
        summary: '主线推进到第二夜',
        memoryLevel: MemoryLevel.macro,
      ),
    ],
    narrativeTime: '第二夜',
    anchor: const StoryAnchor(
      updatedTurn: 2,
      arc: '抵达灯塔',
      foreshadows: [AnchorForeshadow(text: '灯塔里有人')],
    ),
  );

  Future<void> pumpSheet(
    WidgetTester tester,
    Future<DirectorCoreBlocksData?> Function() loader,
  ) {
    return tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () =>
                      DirectorScriptBoardSheet.show(context, loader: loader),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('展示四段：关键实体（含属性）/主线/叙事时间/剧情锚', (tester) async {
    await pumpSheet(tester, () async => data);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('场记板'), findsOneWidget);
    expect(find.text('· 灯塔：状态=熄灭'), findsOneWidget);
    expect(find.text('· 主线推进到第二夜'), findsOneWidget);
    expect(find.text('第二夜'), findsOneWidget);
    expect(find.text('· 当前弧线：抵达灯塔'), findsOneWidget);
    expect(find.text('· 灯塔里有人'), findsOneWidget);
  });

  testWidgets('loader 返回 null 显示不可用说明', (tester) async {
    await pumpSheet(tester, () async => null);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.text('场记板暂不可用（事实层未启用或装配失败）'),
      findsOneWidget,
    );
  });
}
