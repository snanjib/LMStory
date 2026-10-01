import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/draft_change_summary.dart';

void main() {
  group('summarizeDraftChanges 角色卡', () {
    test('字段设置与变更：按枚举序产出 fieldUpdated', () {
      final before = DraftState.empty(DraftKind.characterCard);
      final after = before
          .withCard(
            (before.card ?? CardDraft.initial())
                .withField(CardField.description, '一位剑客')
                .withField(CardField.name, '阿尔'),
          )
          .withConversation();

      final changes = summarizeDraftChanges(before, after);

      expect(changes, hasLength(2));
      expect(
        changes[0],
        isA<DraftChangeRecord>()
            .having((c) => c.kind, 'kind', DraftChangeKind.fieldUpdated)
            .having((c) => c.field, 'field', CardField.name),
      );
      expect(
        changes[1],
        isA<DraftChangeRecord>()
            .having((c) => c.kind, 'kind', DraftChangeKind.fieldUpdated)
            .having((c) => c.field, 'field', CardField.description),
      );
    });

    test('字段值不变不算变更（含空串→空串）', () {
      final before = DraftState.empty(DraftKind.characterCard);
      final after = before.withCard(
        (before.card ?? CardDraft.initial()).withField(CardField.name, ''),
      );
      expect(summarizeDraftChanges(before, after), isEmpty);
    });

    test('标签变更 → tagsUpdated（排在字段之后）', () {
      final before = DraftState.empty(DraftKind.characterCard).withCard(
        CardDraft.initial().withTags(const ['奇幻']),
      );
      final after = before.withCard(
        (before.card ?? CardDraft.initial()).withTags(const ['科幻', '剑客']),
      );

      final changes = summarizeDraftChanges(before, after);

      expect(changes, hasLength(1));
      expect(changes.single.kind, DraftChangeKind.tagsUpdated);
      expect(changes.single.field, isNull);
    });

    test('标签同集合不同顺序视为变更（非集合语义）', () {
      final before = DraftState.empty(DraftKind.characterCard).withCard(
        CardDraft.initial().withTags(const ['a', 'b']),
      );
      final after = before.withCard(
        (before.card ?? CardDraft.initial()).withTags(const ['b', 'a']),
      );
      expect(
        summarizeDraftChanges(before, after).single.kind,
        DraftChangeKind.tagsUpdated,
      );
    });

    test('无变更 → 空列表（hasConversation 等非草稿载荷不参与）', () {
      final before = DraftState.empty(DraftKind.characterCard);
      final after = before.withConversation();
      expect(summarizeDraftChanges(before, after), isEmpty);
    });
  });

  group('summarizeDraftChanges 世界书', () {
    DraftState book(DraftBookBuilder build) {
      var b = WorldbookDraft.initial();
      b = build(b);
      return DraftState.empty(DraftKind.worldbook).withBook(b);
    }

    test('书级元信息（name/description）→ 单条 bookMetaUpdated', () {
      final before = book((b) => b);
      final after = before.withBook(
        (before.book ?? WorldbookDraft.initial())
            .withMeta(name: '剑的世界', description: '一切与剑有关'),
      );

      final changes = summarizeDraftChanges(before, after);

      expect(changes, hasLength(1));
      expect(changes.single.kind, DraftChangeKind.bookMetaUpdated);
    });

    test('新增词条 → entryAdded，标题 comment 优先', () {
      final before = book((b) => b);
      final after = before.withBook(
        (before.book ?? WorldbookDraft.initial()).upsertEntry(
          const WorldEntry(
            id: 'e1',
            keys: ['剑'],
            comment: '古剑设定',
            content: '一柄古剑',
          ),
        ),
      );

      final changes = summarizeDraftChanges(before, after);

      expect(changes, hasLength(1));
      expect(changes.single.kind, DraftChangeKind.entryAdded);
      expect(changes.single.entryTitle, '古剑设定');
    });

    test('entryTitle 回退链：comment → keys 拼接 → id', () {
      final before = book(
        (b) => b
            .upsertEntry(
              const WorldEntry(id: 'e1', keys: ['剑'], content: 'c'),
            )
            .upsertEntry(const WorldEntry(id: 'e2', keys: [], content: 'c')),
      );
      // e1 换 keys（无 comment）→ keys 拼接；e2 无 keys 无 comment → id
      final after = before.withBook(
        (before.book ?? WorldbookDraft.initial())
            .upsertEntry(
              const WorldEntry(id: 'e1', keys: ['剑', '刃'], content: 'c'),
            )
            .upsertEntry(
              const WorldEntry(id: 'e2', keys: [], content: '改'),
            ),
      );

      final changes = summarizeDraftChanges(before, after);

      expect(changes, hasLength(2));
      expect(changes[0].kind, DraftChangeKind.entryUpdated);
      expect(changes[0].entryTitle, '剑、刃');
      expect(changes[1].kind, DraftChangeKind.entryUpdated);
      expect(changes[1].entryTitle, 'e2');
    });

    test('词条删除 → entryRemoved（before 序）', () {
      final before = book(
        (b) => b
            .upsertEntry(const WorldEntry(id: 'e1', keys: ['a'], content: 'a'))
            .upsertEntry(const WorldEntry(id: 'e2', keys: ['b'], content: 'b')),
      );
      final after = before.withBook(
        (before.book ?? WorldbookDraft.initial()).removeEntry('e1'),
      );

      final changes = summarizeDraftChanges(before, after);

      expect(changes, hasLength(1));
      expect(changes.single.kind, DraftChangeKind.entryRemoved);
      expect(changes.single.entryTitle, 'a');
    });

    test('仅 extensions 内部变更也能检出 entryUpdated', () {
      final before = book(
        (b) => b.upsertEntry(
          const WorldEntry(
            id: 'e1',
            keys: ['剑'],
            content: 'c',
            extensions: {
              'depth': 4,
              'sub': {
                'probability': 0.5,
                'list': [1, 2],
              },
            },
          ),
        ),
      );
      final after = before.withBook(
        (before.book ?? WorldbookDraft.initial()).upsertEntry(
          const WorldEntry(
            id: 'e1',
            keys: ['剑'],
            content: 'c',
            extensions: {
              'depth': 4,
              'sub': {
                'probability': 0.5,
                'list': [1, 2, 3],
              },
            },
          ),
        ),
      );

      final changes = summarizeDraftChanges(before, after);

      expect(changes, hasLength(1));
      expect(changes.single.kind, DraftChangeKind.entryUpdated);
    });

    test('extensions 深相等（键序不同）不算变更', () {
      final before = book(
        (b) => b.upsertEntry(
          const WorldEntry(
            id: 'e1',
            keys: ['剑'],
            content: 'c',
            extensions: {'a': 1, 'b': 2},
          ),
        ),
      );
      final after = before.withBook(
        (before.book ?? WorldbookDraft.initial()).upsertEntry(
          const WorldEntry(
            id: 'e1',
            keys: ['剑'],
            content: 'c',
            extensions: {'b': 2, 'a': 1},
          ),
        ),
      );

      expect(summarizeDraftChanges(before, after), isEmpty);
    });

    test('新增/更新按 after 序交错，删除排其后', () {
      final before = book(
        (b) => b
            .upsertEntry(const WorldEntry(id: 'e1', keys: ['a'], content: 'a'))
            .upsertEntry(const WorldEntry(id: 'e2', keys: ['b'], content: 'b'))
            .upsertEntry(const WorldEntry(id: 'e3', keys: ['c'], content: 'c')),
      );
      // after 序：e2（不变）、e3（更新）、e4（新增）；e1 删除
      final after = before.withBook(
        (before.book ?? WorldbookDraft.initial())
            .removeEntry('e1')
            .upsertEntry(
              const WorldEntry(id: 'e3', keys: ['c'], content: 'c 改'),
            )
            .upsertEntry(
              const WorldEntry(id: 'e4', keys: ['d'], content: 'd'),
            ),
      );

      final changes = summarizeDraftChanges(before, after);

      expect(
        changes.map((c) => c.kind).toList(),
        [
          DraftChangeKind.entryUpdated, // e3（after 序）
          DraftChangeKind.entryAdded, // e4（after 序）
          DraftChangeKind.entryRemoved, // e1（before 序，排最后）
        ],
        reason: 'after 序中不变的 e2 不产出记录；删除排在新增/更新之后',
      );
      expect(
        changes.map((c) => c.entryTitle).toList(),
        ['c', 'd', 'a'],
      );
    });
  });

  group('summarizeDraftChanges 定稿与防御', () {
    test('false → true → draftFinalized 排在最后', () {
      final before = DraftState.empty(DraftKind.characterCard).withCard(
        CardDraft.initial().withField(CardField.name, '阿尔'),
      );
      final after = before
          .withCard(
            (before.card ?? CardDraft.initial())
                .withField(CardField.name, '贝塔'),
          )
          .withFinalized(value: true);

      final changes = summarizeDraftChanges(before, after);

      expect(changes, hasLength(2));
      expect(changes[0].kind, DraftChangeKind.fieldUpdated);
      expect(changes[1].kind, DraftChangeKind.draftFinalized);
    });

    test('true → false（撤销定稿）忽略', () {
      final before =
          DraftState.empty(DraftKind.characterCard).withFinalized(value: true);
      final after = before.withFinalized(value: false);
      expect(summarizeDraftChanges(before, after), isEmpty);
    });

    test('kind 不一致 → 空列表（防御）', () {
      final before = DraftState.empty(DraftKind.characterCard);
      final after = DraftState.empty(DraftKind.worldbook);
      expect(summarizeDraftChanges(before, after), isEmpty);
    });
  });
}

/// 测试内便捷的草稿构建签名。
typedef DraftBookBuilder = WorldbookDraft Function(WorldbookDraft initial);
