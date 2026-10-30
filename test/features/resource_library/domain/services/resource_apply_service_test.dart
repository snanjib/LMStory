import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_projection_service.dart';

/// ResourceApplyService 预览链测试
///
/// 覆盖：
/// - ：预览口径与真实投影一致——enabled=false 词条不进样例行、
///   不进「共 N 条」总数、不进常驻计数（投影侧 `if (!entry.enabled) continue`）
/// - ：域服务只产出结构化语义键（SeedPreviewLineKind），不再拼接
///   「background/personality/内置词条/［常驻］」等用户可见文案
void main() {
  late _FakeResourceLibraryRepository repo;
  late ResourceApplyService service;

  setUp(() {
    repo = _FakeResourceLibraryRepository();
    service = ResourceApplyService(
      resourceRepository: repo,
      projectionService: ResourceProjectionService(
        repository: _NoopFactualRepository(),
      ),
    );
  });

  group('previewWorldbook：预览=投影口径', () {
    test('停用词条不进样例行，正常词条照常列出并标记常驻', () async {
      repo.worldbook = _worldbookJson([
        _entry(keys: ['启用词条'], comment: '启用的设定', constant: true),
        _entry(
          keys: ['停用词条'],
          comment: '停用的设定',
          constant: true,
          enabled: false,
        ),
        _entry(keys: ['普通词条'], comment: '普通设定'),
      ]);

      final preview = await service.previewWorldbook(
        bookId: 'book-1',
        defaultSettingName: '未命名设定',
      );

      expect(preview.title, '测试书');
      expect(preview.lines, hasLength(2), reason: '3 词条中 1 条停用，只列 2 条启用');
      expect(
        preview.lines.map((l) => l.text),
        containsAll(['启用的设定', '普通设定']),
      );
      expect(
        preview.lines.map((l) => l.text),
        isNot(contains('停用的设定')),
        reason: '停用词条投影时会被跳过，预览也不应列出',
      );
      final constantLine = preview.lines.firstWhere(
        (l) => l.text == '启用的设定',
      );
      expect(constantLine.kind, SeedPreviewLineKind.worldbookEntry);
      expect(constantLine.isConstant, isTrue);
      // 域层不再拼「［常驻］」前缀文案
      expect(constantLine.text, isNot(contains('［常驻］')));
      // 书路径 enabledEntryCount = 启用词条数（2 启用 + 1 停用）
      expect(preview.enabledEntryCount, 2);
    });

    test('常驻计数只统计启用词条，总条数同口径', () async {
      final entries = [
        for (var i = 0; i < 6; i++)
          _entry(keys: ['词条$i'], comment: '常驻$i', constant: true),
        _entry(keys: ['停用常驻'], comment: '停用常驻', constant: true, enabled: false),
        _entry(keys: ['启用普通'], comment: '启用普通'),
      ];
      repo.worldbook = _worldbookJson(entries);

      final preview = await service.previewWorldbook(
        bookId: 'book-1',
        defaultSettingName: '未命名设定',
      );

      // 7 条启用（6 常驻 + 1 普通）：停用常驻不计入
      expect(preview.constantCount, 6, reason: '常驻计数不应包含停用词条（WA7-3 虚高）');
      final moreLine = preview.lines
          .singleWhere((l) => l.kind == SeedPreviewLineKind.moreCount);
      expect(moreLine.count, 7, reason: '「共 N 条」按启用词条数计');
      // （只读语义 2.0）：启用词条总数与常驻计数同源口径——
      // 「按关键词触发」条数 = enabledEntryCount - constantCount = 1
      expect(preview.enabledEntryCount, 7);
      expect(preview.enabledEntryCount! - preview.constantCount, 1);
    });

    test('启用词条不超过 6 时不产生截断尾行', () async {
      repo.worldbook = _worldbookJson([
        _entry(keys: ['唯一词条'], comment: '唯一设定'),
      ]);

      final preview = await service.previewWorldbook(
        bookId: 'book-1',
        defaultSettingName: '未命名设定',
      );

      expect(preview.lines, hasLength(1));
      expect(preview.lines.single.kind, SeedPreviewLineKind.worldbookEntry);
      expect(preview.lines.single.isConstant, isFalse);
    });
  });

  group('previewCharacterCard：结构化语义键 + 停用词条口径', () {
    test('背景/性格/内置词条行按语义键产出，不再硬编码英文字段名', () async {
      repo.card = _cardJson(
        name: '测试主角',
        description: '来自异世界的旅人',
        personality: '沉着冷静',
        entries: [
          _entry(keys: ['卡内词条'], comment: '卡内设定'),
        ],
      );

      final preview = await service.previewCharacterCard(
        cardId: 'card-1',
        defaultCharacterName: '未命名角色',
      );

      expect(preview.title, '测试主角');
      expect(preview.lines, hasLength(3));

      final background = preview.lines[0];
      expect(background.kind, SeedPreviewLineKind.cardBackground);
      expect(background.text, '来自异世界的旅人');

      final personality = preview.lines[1];
      expect(personality.kind, SeedPreviewLineKind.cardPersonality);
      expect(personality.text, '沉着冷静');

      final embedded = preview.lines[2];
      expect(embedded.kind, SeedPreviewLineKind.cardEmbeddedEntry);
      expect(embedded.text, '卡内设定');
    });

    test('停用内置词条不进样例行，常驻计数只含启用的常驻词条', () async {
      repo.card = _cardJson(
        name: '测试主角',
        description: '来自异世界的旅人',
        personality: '',
        entries: [
          _entry(keys: ['启用常驻'], comment: '启用常驻词条', constant: true),
          _entry(
            keys: ['停用常驻'],
            comment: '停用常驻词条',
            constant: true,
            enabled: false,
          ),
        ],
      );

      final preview = await service.previewCharacterCard(
        cardId: 'card-1',
        defaultCharacterName: '未命名角色',
      );

      expect(
        preview.lines.map((l) => l.text),
        isNot(contains('停用常驻词条')),
      );
      expect(preview.constantCount, 1, reason: '停用常驻词条不投影，也不计入常驻量级提示');
      // 卡路径 enabledEntryCount = 内置词条启用数（停用行不计）
      expect(preview.enabledEntryCount, 1);
    });
  });

  group('预览截断按 Unicode 码点（WA8-6）', () {
    test('emoji 代理对不被截成半个字符，尾缀省略号保留', () async {
      // 'a' + 61 个 emoji：UTF-16 码元 123 > 60，码点 62 > 60 → 截断；
      // 旧 substring(0,60) 会在第 60 码元处切开一个代理对（孤立高位代理）
      const emoji = '\u{1F600}'; // 😀
      repo.card = _cardJson(
        name: '表情主角',
        description: 'a${emoji * 61}',
        personality: '',
      );

      final preview = await service.previewCharacterCard(
        cardId: 'card-1',
        defaultCharacterName: '未命名角色',
      );
      final text = preview.lines
          .singleWhere((l) => l.kind == SeedPreviewLineKind.cardBackground)
          .text;

      final expected = 'a${emoji * 59}…';
      expect(text, expected, reason: '按码点截前 60 个再补省略号');
      // 输出不得含孤立代理项（半个字符，Dart 对未配对代理按原值出 rune）
      expect(
        text.runes.every((r) => r < 0xD800 || r > 0xDFFF),
        isTrue,
      );
    });

    test('码元数超限但码点数未超 → 不截断不加省略号', () async {
      // 'a' + 30 个 emoji：码元 61 > 60，码点 31 ≤ 60 → 原样保留
      const emoji = '\u{1F600}';
      repo.card = _cardJson(
        name: '表情主角',
        description: 'a${emoji * 30}',
        personality: '',
      );

      final preview = await service.previewCharacterCard(
        cardId: 'card-1',
        defaultCharacterName: '未命名角色',
      );
      final text = preview.lines
          .singleWhere((l) => l.kind == SeedPreviewLineKind.cardBackground)
          .text;
      expect(text, 'a${emoji * 30}');
      expect(text.endsWith('…'), isFalse);
    });
  });
}

// ── 测试数据 ─────────────────────────────────────────────────────────

Map<String, dynamic> _entry({
  required List<String> keys,
  required String comment,
  bool constant = false,
  bool enabled = true,
}) =>
    {
      'key': keys,
      'comment': comment,
      'content': '$comment 的正文',
      'constant': constant,
      'enabled': enabled,
    };

String _worldbookJson(List<Map<String, dynamic>> entries) => jsonEncode({
      'entries': {
        for (var i = 0; i < entries.length; i++) i.toString(): entries[i],
      },
    });

String _cardJson({
  required String name,
  required String description,
  required String personality,
  List<Map<String, dynamic>> entries = const [],
}) =>
    jsonEncode({
      'name': name,
      'description': description,
      'personality': personality,
      'character_book': {'entries': entries},
    });

class _FakeResourceLibraryRepository implements ResourceLibraryRepository {
  String? card;
  String? worldbook;

  @override
  Future<CharacterCard?> getCharacterCard(String cardId) async => card == null
      ? null
      : CharacterCard(
          cardId: cardId,
          name: '测试主角',
          rawJson: card!,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );

  @override
  Future<Worldbook?> getWorldbook(String bookId) async => worldbook == null
      ? null
      : Worldbook(
          bookId: bookId,
          name: '测试书',
          rawJson: worldbook!,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 预览链不触达事实层，占位仓储即可
class _NoopFactualRepository implements FactualRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
