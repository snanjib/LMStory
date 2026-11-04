import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_tools.dart';

void main() {
  AgentToolInvocation invocation() => AgentToolInvocation(
        callId: 'c1',
        toolName: 'update_draft',
        stepIndex: 0,
        cancellation: AgentCancellationToken(),
      );

  group('UpdateDraftTool 卡模式', () {
    test('set_card_field 写字段', () async {
      var state = DraftState.empty(DraftKind.characterCard);
      final tool = UpdateDraftTool(
        kind: DraftKind.characterCard,
        readState: () => state,
        onDraftChanged: (s) => state = s,
      );
      final r = await tool.invoke(invocation(), {
        'action': 'set_card_field',
        'field': 'description',
        'value': '一位剑客',
      });
      expect(r.isError, isFalse);
      expect(state.card!.value(CardField.description), '一位剑客');
    });

    test('set_card_tags 覆盖标签', () async {
      var state = DraftState.empty(DraftKind.characterCard);
      final tool = UpdateDraftTool(
        kind: DraftKind.characterCard,
        readState: () => state,
        onDraftChanged: (s) => state = s,
      );
      final r = await tool.invoke(invocation(), {
        'action': 'set_card_tags',
        'tags': ['奇幻', '剑'],
      });
      expect(r.isError, isFalse);
      expect(state.card!.tags, ['奇幻', '剑']);
    });

    test('非法字段名/缺参 → failure 信封不抛异常', () async {
      final state = DraftState.empty(DraftKind.characterCard);
      final tool = UpdateDraftTool(
        kind: DraftKind.characterCard,
        readState: () => state,
        onDraftChanged: (_) {},
      );

      final badField = await tool.invoke(invocation(), {
        'action': 'set_card_field',
        'field': 'not_a_field',
        'value': 'x',
      });
      expect(badField.isError, isTrue);
      expect(badField.output, contains('name'));

      final missingValue = await tool.invoke(invocation(), {
        'action': 'set_card_field',
        'field': 'name',
      });
      expect(missingValue.isError, isTrue);
      expect(missingValue.output, isNotEmpty);
    });

    test('卡模式调书 action → failure 说明模式约束', () async {
      final state = DraftState.empty(DraftKind.characterCard);
      final tool = UpdateDraftTool(
        kind: DraftKind.characterCard,
        readState: () => state,
        onDraftChanged: (_) {},
      );
      final r = await tool.invoke(invocation(), {
        'action': 'add_book_entry',
        'entry': {
          'keys': ['k'],
          'content': 'c',
        },
      });
      expect(r.isError, isTrue);
      expect(r.output, contains('角色卡'));
      expect(r.output, contains('set_card_field'));
    });

    test('未知 action → failure 列出合法 action', () async {
      final state = DraftState.empty(DraftKind.characterCard);
      final tool = UpdateDraftTool(
        kind: DraftKind.characterCard,
        readState: () => state,
        onDraftChanged: (_) {},
      );
      final r = await tool.invoke(invocation(), {'action': 'do_everything'});
      expect(r.isError, isTrue);
      expect(r.output, contains('set_card_field'));
      expect(r.output, contains('do_everything'));
    });
  });

  group('UpdateDraftTool 书模式', () {
    late UpdateDraftTool testTool;
    late DraftState state;

    setUp(() {
      state = DraftState.empty(DraftKind.worldbook);
      testTool = UpdateDraftTool(
        kind: DraftKind.worldbook,
        readState: () => state,
        onDraftChanged: (s) => state = s,
      );
    });

    test('set_book_meta 写书名与描述', () async {
      final r = await testTool.invoke(invocation(), {
        'action': 'set_book_meta',
        'name': '剑的世界',
        'description': '一切与剑相关',
      });
      expect(r.isError, isFalse);
      expect(state.book!.name, '剑的世界');
      expect(state.book!.description, '一切与剑相关');
    });

    test('add_book_entry 端内分配 id 并追加', () async {
      final r = await testTool.invoke(invocation(), {
        'action': 'add_book_entry',
        'entry': {
          'keys': ['古剑'],
          'content': '一柄古剑',
          'constant': true,
          'order': 200,
        },
      });
      expect(r.isError, isFalse);
      final entries = state.book!.entries;
      expect(entries, hasLength(1));
      expect(entries.single.keys, ['古剑']);
      expect(entries.single.content, '一柄古剑');
      expect(entries.single.constant, isTrue);
      expect(entries.single.insertionOrder, 200);
      expect(entries.single.id, isNotEmpty);

      // 再加一条，id 不同
      await testTool.invoke(invocation(), {
        'action': 'add_book_entry',
        'entry': {
          'keys': ['b'],
          'content': 'c2',
        },
      });
      final two = state.book!.entries;
      expect(two, hasLength(2));
      expect(two[0].id, isNot(two[1].id));
    });

    test('update_book_entry 按 id 部分更新', () async {
      await testTool.invoke(invocation(), {
        'action': 'add_book_entry',
        'entry': {
          'keys': ['k1'],
          'content': 'c1',
          'comment': '备注',
        },
      });
      final id = state.book!.entries.single.id;

      final r = await testTool.invoke(invocation(), {
        'action': 'update_book_entry',
        'id': id,
        'patch': {'content': '新内容', 'constant': true},
      });
      expect(r.isError, isFalse);
      final e = state.book!.entries.single;
      expect(e.content, '新内容');
      expect(e.constant, isTrue);
      expect(e.comment, '备注', reason: '未触达字段保持');
      expect(e.keys, ['k1']);
    });

    test('update/remove 不存在的 id → failure', () async {
      final r1 = await testTool.invoke(invocation(), {
        'action': 'update_book_entry',
        'id': 'e404',
        'patch': {'content': 'x'},
      });
      expect(r1.isError, isTrue);

      final r2 = await testTool.invoke(invocation(), {
        'action': 'remove_book_entry',
        'id': 'e404',
      });
      expect(r2.isError, isTrue);
    });

    test('remove_book_entry 删除条目', () async {
      await testTool.invoke(invocation(), {
        'action': 'add_book_entry',
        'entry': {
          'keys': ['k'],
          'content': 'c',
        },
      });
      final id = state.book!.entries.single.id;
      final r = await testTool.invoke(invocation(), {
        'action': 'remove_book_entry',
        'id': id,
      });
      expect(r.isError, isFalse);
      expect(state.book!.entries, isEmpty);
    });

    test('书模式调卡 action → failure', () async {
      final r = await testTool.invoke(invocation(), {
        'action': 'set_card_field',
        'field': 'name',
        'value': 'x',
      });
      expect(r.isError, isTrue);
      expect(r.output, contains('世界书'));
    });
  });

  group('FinalizeDraftTool', () {
    test('置 finalized 且非终止、可再次置位', () async {
      var state = DraftState.empty(DraftKind.characterCard);
      final tool = FinalizeDraftTool(
        readState: () => state,
        onDraftChanged: (s) => state = s,
      );
      final r = await tool.invoke(invocation(), {});
      expect(r.isError, isFalse);
      expect(r.terminal, isFalse, reason: 'finalize 不终止轮次');
      expect(state.finalized, isTrue);

      // 可再改：finalize 后草稿仍可更新
      state = state.withCard(
        state.card!.withField(CardField.name, '后改的名字'),
      );
      expect(state.card!.value(CardField.name), '后改的名字');
      expect(state.finalized, isTrue, reason: '草稿改动不清 finalized');
    });
  });

  group('ResourceAiReadSkillTool', () {
    test('skillNames 注入三个建卡 skill 并可读取正文', () async {
      const names = ['card-crafting', 'worldbook-crafting', 'card-editing'];
      final tool = ResourceAiReadSkillTool(
        skillNames: names,
        loadSkillBody: (name) async => name == 'card-crafting' ? '# 正文' : null,
      );
      expect(tool.name, 'read_skill');
      expect(tool.permission, AgentToolPermission.readOnly);
      expect(tool.description, contains('card-crafting'));

      final ok = await tool.invoke(invocation(), {'name': 'card-crafting'});
      expect(ok.isError, isFalse);
      expect(ok.output, contains('# 正文'));

      final missing = await tool.invoke(invocation(), {'name': 'nope'});
      expect(missing.isError, isTrue);
      expect(missing.output, contains('card-editing'));
    });
  });
}
