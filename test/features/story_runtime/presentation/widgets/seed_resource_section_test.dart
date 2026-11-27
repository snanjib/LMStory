import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/seed_resource_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// 取消应用分组名规则测试
///
/// 口径：分组按 sourceRef 聚合后，显示名取**资源名**（卡名/书名，
/// 反查资源表）——此前一律用首个实体主名，世界书组显示的是第一个
/// 词条名（如「魔法体系（45 个实体）」），用户认不出是哪本书，
/// 与确认弹窗 unapplyConfirm(name:...) 联动误导。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  FactualEntity entity(
    String name, {
    FactualSource source = FactualSource.auto,
    String? sourceRef,
  }) {
    return FactualEntity(
      entityId: 'ent-$name',
      sessionId: 's1',
      type: FactualEntityType.lore,
      primaryName: name,
      aliases: const [],
      importance: 3,
      createdTurn: 0,
      createdAt: DateTime(2026),
      source: source,
      sourceRef: sourceRef,
    );
  }

  test('世界书组名用书名（资源名）而非首个词条主名', () {
    final groups = groupProjectedSeedEntities(
      [
        entity('魔法体系', source: FactualSource.worldbook, sourceRef: 'book-1'),
        entity('魔王', source: FactualSource.worldbook, sourceRef: 'book-1'),
      ],
      bookNamesById: const {'book-1': '型月世界书'},
    );

    expect(groups, hasLength(1));
    final group = groups['book-1']!;
    expect(group.name, '型月世界书');
    expect(group.count, 2);
    expect(group.sourceRef, 'book-1');
  });

  test('卡组名用卡名（资源名）', () {
    final groups = groupProjectedSeedEntities(
      [entity('莱昂', source: FactualSource.card, sourceRef: 'card-9')],
      cardNamesById: const {'card-9': 'ReZero 角色卡'},
    );

    expect(groups['card-9']!.name, 'ReZero 角色卡');
  });

  test('角色卡的内嵌条目同组显示为角色卡', () {
    final groups = groupProjectedSeedEntities(
      [
        entity('内嵌词条', source: FactualSource.worldbook, sourceRef: 'card-9'),
        entity('莱昂', source: FactualSource.card, sourceRef: 'card-9'),
      ],
      cardNamesById: const {'card-9': '向导角色卡'},
    );

    final group = groups.values.single;
    expect(group.name, '向导角色卡');
    expect(group.source, FactualSource.card);
    expect(group.count, 2);
  });

  test('资源反查不到（已删/数据漂移）→ 回退首个实体主名', () {
    final groups = groupProjectedSeedEntities(
      [
        entity('魔法体系', source: FactualSource.worldbook, sourceRef: 'book-1'),
        entity('魔王', source: FactualSource.worldbook, sourceRef: 'book-1'),
      ],
    );

    expect(groups['book-1']!.name, '魔法体系');
    expect(groups['book-1']!.count, 2);
  });

  test('auto 来源与空 sourceRef 实体不参与分组', () {
    final groups = groupProjectedSeedEntities(
      [
        entity('莱昂'),
        entity('莱昂', source: FactualSource.card),
        entity('空引用', source: FactualSource.worldbook, sourceRef: ''),
      ],
    );

    expect(groups, isEmpty);
  });

  test('同会话多本书各成一组，组名各自取书名', () {
    final groups = groupProjectedSeedEntities(
      [
        entity('词条A', source: FactualSource.worldbook, sourceRef: 'book-1'),
        entity('词条B', source: FactualSource.worldbook, sourceRef: 'book-2'),
        entity('词条C', source: FactualSource.worldbook, sourceRef: 'book-1'),
      ],
      bookNamesById: const {'book-1': '书一', 'book-2': '书二'},
    );

    expect(groups, hasLength(2));
    expect(groups['book-1']!.name, '书一');
    expect(groups['book-1']!.count, 2);
    expect(groups['book-2']!.name, '书二');
    expect(groups['book-2']!.count, 1);
  });

  // ── （只读语义 2.0）：应用预览弹窗三段式——「将导入为只读基线」
  // （锁形前缀样例行）、「注入方式」（常驻 N 条 + 其余 M 条按关键词
  // 触发）、尾部只读基线说明。搭法沿用 factual_memory_tab_injection_
  // wiring_test 的定时 pump 范式（勿用 pumpAndSettle）。

  Future<void> pumpSection(
    WidgetTester tester, {
    required FakeFactualRepository factualRepo,
    required ResourceLibraryRepository resourceRepo,
    required Future<String?> Function() ensureSessionIdForApply,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: ProviderScope(
          overrides: [
            factualRepositoryProvider.overrideWithValue(factualRepo),
            resourceLibraryRepositoryProvider.overrideWithValue(resourceRepo),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SeedResourceSection(
                  sessionId: 'draft',
                  enabled: true,
                  ensureSessionIdForApply: ensureSessionIdForApply,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('预览确认后将角色卡应用到保存后的会话并显示资源名', (tester) async {
    // 卡内词条：3 启用（1 常驻 + 2 关键词触发）+ 1 停用 →
    // constantCount=1、enabledEntryCount=3、按关键词触发=2
    final card = CharacterCard(
      cardId: 'card-1',
      name: '测试主角',
      rawJson: jsonEncode({
        'name': '测试主角',
        'description': '来自异世界的旅人',
        'personality': '沉着冷静',
        'character_book': {
          'entries': [
            {
              'key': ['常驻词条'],
              'comment': '常驻设定',
              'content': '常驻正文',
              'constant': true,
            },
            {
              'key': ['普通A'],
              'comment': '普通设定A',
              'content': '正文A',
            },
            {
              'key': ['普通B'],
              'comment': '普通设定B',
              'content': '正文B',
            },
            {
              'key': ['停用常驻'],
              'comment': '停用设定',
              'content': '停用正文',
              'constant': true,
              'enabled': false,
            },
          ],
        },
      }),
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final factualRepo = FakeFactualRepository();
    var ensureCalls = 0;
    await pumpSection(
      tester,
      factualRepo: factualRepo,
      resourceRepo: _SingleCardRepository(card),
      ensureSessionIdForApply: () async {
        ensureCalls++;
        return 'saved-session';
      },
    );

    // 选卡 → 预览弹窗
    await tester.tap(find.text('应用角色卡'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 底栏入场
    await tester.tap(find.text('测试主角'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 底栏退场 + 预览解析
    await tester.pump(const Duration(milliseconds: 100));

    // 段一：只读基线段标题在位，样例行带锁形前缀
    expect(find.text('将导入为只读基线'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(find.text('背景：来自异世界的旅人'), findsOneWidget);
    // 段二：注入方式段——常驻 1 条 + 其余 2 条按关键词触发
    expect(find.text('注入方式'), findsOneWidget);
    expect(find.text('包含 1 条常驻词条（每轮必进上下文）'), findsOneWidget);
    expect(find.text('其余 2 条按关键词触发'), findsOneWidget);
    // 尾部：只读基线 + 演变并存说明
    expect(find.textContaining('不会改写原文'), findsOneWidget);
    expect(ensureCalls, 0);
    expect(factualRepo.createdEntities, isEmpty);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(ensureCalls, 1);
    expect(factualRepo.createdEntities, isNotEmpty);
    expect(
      factualRepo.createdEntities.map((entity) => entity.sessionId),
      everyElement('saved-session'),
    );
    expect(
      find.text('角色卡 · 测试主角'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .join(' / '),
    );
  });
}

/// 仅含一张角色卡的资源库假仓储（预览链不触达事实层，Factual 用 helpers fake）
class _SingleCardRepository implements ResourceLibraryRepository {
  _SingleCardRepository(this.card);

  final CharacterCard card;

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => [card];

  @override
  Future<List<Worldbook>> getAllWorldbooks() async => const [];

  @override
  Future<CharacterCard?> getCharacterCard(String cardId) async =>
      card.cardId == cardId ? card : null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
