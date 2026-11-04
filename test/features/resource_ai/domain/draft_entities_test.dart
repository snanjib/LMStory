import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';

void main() {
  group('CardField', () {
    test('jsonName 映射蛇形命名', () {
      expect(CardField.name.jsonName, 'name');
      expect(CardField.description.jsonName, 'description');
      expect(CardField.personality.jsonName, 'personality');
      expect(CardField.scenario.jsonName, 'scenario');
      expect(CardField.firstMes.jsonName, 'first_mes');
      expect(CardField.mesExample.jsonName, 'mes_example');
      expect(CardField.creatorNotes.jsonName, 'creator_notes');
    });
  });

  group('CardDraft', () {
    test('字段写入与完成度', () {
      var d = CardDraft.initial();
      expect(d.isDirty, isFalse);
      d = d.withField(CardField.description, '一位流浪剑客');
      expect(d.isDirty, isTrue);
      expect(d.value(CardField.description), '一位流浪剑客');
      expect(d.value(CardField.name), '');
    });

    test('initial 全字段为空串', () {
      final d = CardDraft.initial();
      for (final f in CardField.values) {
        expect(d.value(f), '');
      }
      expect(d.tags, isEmpty);
    });

    test('withField 不可变：原草稿不变', () {
      final d0 = CardDraft.initial().withField(CardField.name, '阿尔');
      final d1 = d0.withField(CardField.name, '贝塔');
      expect(d0.value(CardField.name), '阿尔');
      expect(d1.value(CardField.name), '贝塔');
    });

    test('tags 写入与替换', () {
      var d = CardDraft.initial();
      expect(d.isDirty, isFalse);
      d = d.withTags(['奇幻', '剑客']);
      expect(d.isDirty, isTrue);
      expect(d.tags, ['奇幻', '剑客']);
      d = d.withTags(['科幻']);
      expect(d.tags, ['科幻']);
    });

    test('isDirty 在字段清回空后回落', () {
      var d = CardDraft.initial().withField(CardField.name, 'X');
      d = d.withField(CardField.name, '');
      expect(d.isDirty, isFalse);
    });
  });

  group('WorldbookDraft', () {
    test('词条增改删与 id 分配', () {
      var d = WorldbookDraft.initial();
      expect(d.entries, isEmpty);
      expect(d.isDirty, isFalse);
      final id = d.nextEntryId();
      d = d.upsertEntry(
        WorldEntry(id: id, keys: const ['剑'], content: '一柄古剑'),
      );
      expect(d.entries.single.id, id);
      expect(d.isDirty, isTrue);

      // upsert 同 id = 覆盖
      d = d.upsertEntry(
        WorldEntry(id: id, keys: const ['剑'], content: '改写后的内容'),
      );
      expect(d.entries, hasLength(1));
      expect(d.entries.single.content, '改写后的内容');

      d = d.removeEntry(id);
      expect(d.entries, isEmpty);
      expect(d.isDirty, isFalse);
    });

    test('nextEntryId 单调递增且不与已有冲突', () {
      var d = WorldbookDraft.initial();
      final first = d.nextEntryId();
      d = d.upsertEntry(
        WorldEntry(id: first, keys: const ['a'], content: 'a'),
      );
      final second = d.nextEntryId();
      expect(second, isNot(first));
      d = d.upsertEntry(
        WorldEntry(id: second, keys: const ['b'], content: 'b'),
      );
      expect(d.nextEntryId(), isNot(second));
    });

    test('removeEntry 不存在的 id 无副作用', () {
      final d = WorldbookDraft.initial().upsertEntry(
        const WorldEntry(id: 'e1', keys: ['a'], content: 'a'),
      );
      final after = d.removeEntry('e404');
      expect(after.entries, hasLength(1));
    });

    test('书元信息（name/description）参与 isDirty', () {
      var d = WorldbookDraft.initial();
      d = d.withMeta(name: '剑的世界');
      expect(d.isDirty, isTrue);
      expect(d.name, '剑的世界');
      expect(d.description, '');
    });

    test('upsertEntry 不可变：原草稿不变', () {
      final d0 = WorldbookDraft.initial();
      final d1 = d0.upsertEntry(
        const WorldEntry(id: 'e1', keys: ['a'], content: 'a'),
      );
      expect(d0.entries, isEmpty);
      expect(d1.entries, hasLength(1));
    });
  });

  group('WorldEntry', () {
    test('默认值符合 ST 惯例', () {
      const e = WorldEntry(id: 'e1', keys: ['k'], content: 'c');
      expect(e.secondaryKeys, isEmpty);
      expect(e.comment, '');
      expect(e.constant, isFalse);
      expect(e.selective, isFalse);
      expect(e.insertionOrder, 100);
      expect(e.enabled, isTrue);
      expect(e.positionBeforeChar, isTrue);
      expect(e.extensions, isEmpty);
    });
  });

  group('DraftState', () {
    test('卡模式持有卡草稿，书模式持有书草稿', () {
      final s = DraftState.empty(DraftKind.characterCard);
      expect(s.kind, DraftKind.characterCard);
      expect(s.card, isNotNull);
      expect(s.book, isNull);
      final b = DraftState.empty(DraftKind.worldbook);
      expect(b.book, isNotNull);
      expect(b.card, isNull);
    });

    test('hasConversation 初始 false，随对话置位', () {
      final s0 = DraftState.empty(DraftKind.characterCard);
      expect(s0.hasConversation, isFalse);
      final s1 = s0.withConversation();
      expect(s1.hasConversation, isTrue);
      expect(s0.hasConversation, isFalse); // 不可变
    });

    test('withCard/withBook/withFinalized 变换', () {
      final s0 = DraftState.empty(DraftKind.characterCard);
      final s1 = s0.withCard(s0.card!.withField(CardField.name, 'N'));
      expect(s1.card!.value(CardField.name), 'N');
      expect(s0.card!.value(CardField.name), ''); // 原状态不变

      final s2 = DraftState.empty(DraftKind.worldbook);
      final s3 = s2.withBook(
        s2.book!.upsertEntry(
          const WorldEntry(id: 'e1', keys: ['k'], content: 'c'),
        ),
      );
      expect(s3.book!.entries, hasLength(1));

      expect(s3.finalized, isFalse);
      final s4 = s3.withFinalized(value: true);
      expect(s4.finalized, isTrue);
      expect(s4.book!.entries, hasLength(1)); // 其他载荷保留
    });
  });
}
