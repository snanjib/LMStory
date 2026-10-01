import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_ai/data/resource_ai_save_service.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';

class _FakeRepository implements ResourceLibraryRepository {
  final cards = <CharacterCard>[];
  final books = <Worldbook>[];
  final updates = <String>[];

  @override
  Future<CharacterCard> createCharacterCard({
    required String name,
    required String rawJson,
    String? sourceFormat,
  }) async {
    final card = CharacterCard(
      cardId: 'card-${cards.length}',
      name: name,
      rawJson: rawJson,
      sourceFormat: sourceFormat,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    cards.add(card);
    return card;
  }

  @override
  Future<Worldbook> createWorldbook({
    required String name,
    required String rawJson,
  }) async {
    final book = Worldbook(
      bookId: 'book-${books.length}',
      name: name,
      rawJson: rawJson,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    books.add(book);
    return book;
  }

  @override
  Future<void> updateCharacterCard({
    required String cardId,
    required String name,
    required String rawJson,
  }) async {
    updates.add('card:$cardId');
    final i = cards.indexWhere((c) => c.cardId == cardId);
    if (i >= 0) {
      cards[i] = CharacterCard(
        cardId: cardId,
        name: name,
        rawJson: rawJson,
        sourceFormat: cards[i].sourceFormat,
        createdAt: cards[i].createdAt,
        updatedAt: DateTime(2026, 1, 2),
      );
    }
  }

  @override
  Future<void> updateWorldbook({
    required String bookId,
    required String name,
    required String rawJson,
  }) async {
    updates.add('book:$bookId');
    final i = books.indexWhere((b) => b.bookId == bookId);
    if (i >= 0) {
      books[i] = Worldbook(
        bookId: bookId,
        name: name,
        rawJson: rawJson,
        createdAt: books[i].createdAt,
        updatedAt: DateTime(2026, 1, 2),
      );
    }
  }

  @override
  Future<void> deleteCharacterCard(String cardId) async {}

  @override
  Future<void> deleteWorldbook(String bookId) async {}

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => cards;

  @override
  Future<List<Worldbook>> getAllWorldbooks() async => books;

  @override
  Future<CharacterCard?> getCharacterCard(String cardId) async =>
      cards.where((c) => c.cardId == cardId).firstOrNull;

  @override
  Future<Worldbook?> getWorldbook(String bookId) async =>
      books.where((b) => b.bookId == bookId).firstOrNull;
}

void main() {
  late _FakeRepository repo;
  late ResourceAiSaveService service;

  setUp(() {
    repo = _FakeRepository();
    service = ResourceAiSaveService(repository: repo);
  });

  group('saveCharacterCard', () {
    final draft = CardDraft.initial()
        .withField(CardField.name, '阿尔')
        .withField(CardField.description, '剑客');

    test('新建：buildCardJson + create(sourceFormat v2)，返回新 id', () async {
      final id = await service.saveCharacterCard(draft: draft);
      expect(id, 'card-0');
      final saved = repo.cards.single;
      expect(saved.name, '阿尔');
      expect(saved.sourceFormat, 'v2');
      final j = jsonDecode(saved.rawJson) as Map<String, dynamic>;
      expect(j['spec'], 'chara_card_v2');
      expect(repo.updates, isEmpty, reason: '新建不走 update');
    });

    test('编辑+另存：与新建同路径（新 id，不动原卡）', () async {
      final original = await repo.createCharacterCard(
        name: '旧卡',
        rawJson: '{"spec":"chara_card_v2"}',
      );
      final id = await service.saveCharacterCard(draft: draft);
      expect(id, isNot(original.cardId));
      expect(repo.cards, hasLength(2));
    });

    test('编辑+覆盖：patch 留底 JSON 后 update，id 不变且未知键保留', () async {
      const originalRawJson =
          '{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"旧名",'
          '"extensions":{"depth_prompt":{"depth":4}},"character_book":{"entries":[]}}}';
      final original = await repo.createCharacterCard(
        name: '旧名',
        rawJson: originalRawJson,
      );

      final id = await service.saveCharacterCard(
        draft: draft,
        existingCardId: original.cardId,
        originalRawJson: originalRawJson,
      );

      expect(id, original.cardId);
      expect(repo.updates, ['card:${original.cardId}']);
      final saved = repo.cards.single;
      expect(saved.name, '阿尔');
      final j = jsonDecode(saved.rawJson) as Map<String, dynamic>;
      final data = j['data'] as Map<String, dynamic>;
      expect(
        data['extensions'],
        {
          'depth_prompt': {'depth': 4},
        },
        reason: '覆盖保存未知键必须保留',
      );
      expect(data['character_book'], {'entries': <dynamic>[]});
      expect(data['description'], '剑客');
    });

    test('空名落默认名', () async {
      await service.saveCharacterCard(
        draft: CardDraft.initial().withField(CardField.description, 'x'),
      );
      expect(repo.cards.single.name, isNotEmpty);
    });
  });

  group('saveWorldbook', () {
    final draft = WorldbookDraft.initial().withMeta(name: '剑的世界').upsertEntry(
          const WorldEntry(id: 'e1', keys: ['古剑'], content: '一柄古剑'),
        );

    test('新建：buildWorldbookJson + create，返回新 id', () async {
      final id = await service.saveWorldbook(draft: draft);
      expect(id, 'book-0');
      final saved = repo.books.single;
      expect(saved.name, '剑的世界');
      final j = jsonDecode(saved.rawJson) as Map<String, dynamic>;
      expect(j['entries'], isA<Map<String, dynamic>>());
      expect(repo.updates, isEmpty);
    });

    test('编辑+覆盖：patch 留底 JSON 后 update，未触达书级键保留', () async {
      const originalRawJson =
          '{"name":"旧书","unknown_key":true,"entries":{"e1":{"uid":1,'
          '"key":["旧键"],"content":"旧内容","extensions":{"sticky":2}}}}';
      final original = await repo.createWorldbook(
        name: '旧书',
        rawJson: originalRawJson,
      );

      final id = await service.saveWorldbook(
        draft: draft,
        existingBookId: original.bookId,
        originalRawJson: originalRawJson,
      );

      expect(id, original.bookId);
      expect(repo.updates, ['book:${original.bookId}']);
      final saved = repo.books.single;
      expect(saved.name, '剑的世界');
      final j = jsonDecode(saved.rawJson) as Map<String, dynamic>;
      expect(j['unknown_key'], isTrue);
      final e1 = (j['entries'] as Map)['e1'] as Map<String, dynamic>;
      expect(e1['content'], '一柄古剑');
      expect((e1['extensions'] as Map)['sticky'], 2);
    });
  });
}
