import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/resource_library/data/repositories/resource_library_repository_impl.dart';

/// ResourceLibraryRepository 单元测试（DOC-15 §9.1）
///
/// 用真实 drift 内存库（NativeDatabase.memory）验证角色卡/世界书资源 CRUD。
void main() {
  late AppDatabase db;
  late ResourceLibraryRepositoryImpl repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ResourceLibraryRepositoryImpl(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('角色卡', () {
    test('创建 + 查询 + 删除', () async {
      final card = await repo.createCharacterCard(
        name: 'ReZero',
        rawJson: '{"spec":"chara_card_v3","data":{"name":"ReZero"}}',
        sourceFormat: 'v3',
      );

      expect(card.name, 'ReZero');
      expect(card.sourceFormat, 'v3');

      final fetched = await repo.getCharacterCard(card.cardId);
      expect(fetched, isNotNull);
      expect(fetched!.rawJson, contains('chara_card_v3'));

      final all = await repo.getAllCharacterCards();
      expect(all, hasLength(1));

      await repo.deleteCharacterCard(card.cardId);
      expect(await repo.getAllCharacterCards(), isEmpty);
    });

    test('update 覆盖保存：name/rawJson 更新且 id 不变', () async {
      final card = await repo.createCharacterCard(
        name: '旧名',
        rawJson: '{"spec":"chara_card_v2","data":{"name":"旧名"}}',
      );

      await repo.updateCharacterCard(
        cardId: card.cardId,
        name: '新名',
        rawJson:
            '{"spec":"chara_card_v2","data":{"name":"新名","description":"x"}}',
      );

      final fetched = await repo.getCharacterCard(card.cardId);
      expect(fetched, isNotNull);
      expect(fetched!.cardId, card.cardId, reason: '覆盖保存保持 id 不变');
      expect(fetched.name, '新名');
      expect(fetched.rawJson, contains('description'));
      expect(
        fetched.updatedAt.isAfter(card.updatedAt) ||
            fetched.updatedAt.isAtSameMomentAs(card.updatedAt),
        isTrue,
        reason: 'updatedAt 刷新',
      );
      expect(await repo.getAllCharacterCards(), hasLength(1));
    });
  });

  group('世界书', () {
    test('创建 + 查询 + 删除', () async {
      final book = await repo.createWorldbook(
        name: '型月世界书',
        rawJson: '{"entries":{"0":{"uid":0,"content":"..."}}}',
      );

      expect(book.name, '型月世界书');

      final fetched = await repo.getWorldbook(book.bookId);
      expect(fetched, isNotNull);
      expect(fetched!.rawJson, contains('entries'));

      final all = await repo.getAllWorldbooks();
      expect(all, hasLength(1));

      await repo.deleteWorldbook(book.bookId);
      expect(await repo.getAllWorldbooks(), isEmpty);
    });

    test('update 覆盖保存：name/rawJson 更新且 id 不变', () async {
      final book = await repo.createWorldbook(
        name: '旧书',
        rawJson: '{"entries":{"0":{"uid":0,"content":"..."}}}',
      );

      await repo.updateWorldbook(
        bookId: book.bookId,
        name: '新书',
        rawJson: '{"entries":{"0":{"uid":0,"content":"改"},"1":{"uid":1}}}',
      );

      final fetched = await repo.getWorldbook(book.bookId);
      expect(fetched, isNotNull);
      expect(fetched!.bookId, book.bookId, reason: '覆盖保存保持 id 不变');
      expect(fetched.name, '新书');
      expect(fetched.rawJson, contains('"uid":1'));
      expect(
        fetched.updatedAt.isAfter(book.updatedAt) ||
            fetched.updatedAt.isAtSameMomentAs(book.updatedAt),
        isTrue,
        reason: 'updatedAt 刷新',
      );
      expect(await repo.getAllWorldbooks(), hasLength(1));
    });
  });
}
