import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/draft_json_builder.dart';
import 'package:lmstory/features/resource_library/domain/services/character_card_parser.dart';
import 'package:lmstory/features/resource_library/domain/services/worldbook_parser.dart';

void main() {
  group('buildCardJson', () {
    test('V2 结构 + V1 镜像 + 空 extensions 也存在', () {
      final d = CardDraft.initial()
          .withField(CardField.name, '阿尔')
          .withField(CardField.description, '一位流浪剑客')
          .withField(CardField.personality, '沉稳')
          .withField(CardField.scenario, '雨夜酒馆')
          .withField(CardField.firstMes, '你推门而入……')
          .withField(CardField.mesExample, '<START>\n{{user}}: 你好')
          .withField(CardField.creatorNotes, '适合长篇')
          .withTags(['奇幻', '剑客']);

      final j = buildCardJson(d);
      expect(j['spec'], 'chara_card_v2');
      expect(j['spec_version'], '2.0');

      final data = j['data'] as Map<String, dynamic>;
      expect(data['name'], '阿尔');
      expect(data['description'], '一位流浪剑客');
      expect(data['personality'], '沉稳');
      expect(data['scenario'], '雨夜酒馆');
      expect(data['first_mes'], '你推门而入……');
      expect(data['mes_example'], '<START>\n{{user}}: 你好');
      expect(data['creator_notes'], '适合长篇');
      expect(data['tags'], ['奇幻', '剑客']);
      // 空对象也必须存在
      expect(data['extensions'], isA<Map<String, dynamic>>());
      expect(data['extensions'], isEmpty);

      // V1 兼容镜像（顶层三件套）
      expect(j['name'], '阿尔');
      expect(j['description'], '一位流浪剑客');
      expect(j['personality'], '沉稳');
    });

    test('round-trip：能被 CharacterCardParser 解回等价内容', () {
      final d = CardDraft.initial()
          .withField(CardField.name, 'Kai')
          .withField(CardField.description, 'A wandering swordsman.')
          .withField(CardField.personality, 'calm');
      final parsed = CharacterCardParser.parse(jsonEncode(buildCardJson(d)));
      expect(parsed.name, 'Kai');
      expect(parsed.description, 'A wandering swordsman.');
      expect(parsed.personality, 'calm');
      expect(parsed.specVersion, 'v2');
    });
  });

  group('buildWorldbookJson', () {
    test('entries 字典结构 + 条目字段 + 书级默认值', () {
      final d = WorldbookDraft.initial()
          .withMeta(name: '剑的世界', description: '关于剑的一切')
          .upsertEntry(
            const WorldEntry(
              id: 'e1',
              keys: ['古剑'],
              secondaryKeys: ['名剑'],
              comment: '主线道具',
              content: '一柄 {{char}} 使用的古剑',
              constant: true,
              insertionOrder: 200,
            ),
          )
          .upsertEntry(const WorldEntry(id: 'e2', keys: ['酒馆'], content: 'c2'));

      final j = buildWorldbookJson(d);
      expect(j['name'], '剑的世界');
      expect(j['description'], '关于剑的一切');
      expect(j['scan_depth'], isNull);
      expect(j['token_budget'], isNull);
      expect(j['recursive_scanning'], isFalse);

      final entries = j['entries'] as Map<String, dynamic>;
      expect(entries.keys, containsAll(['e1', 'e2']));
      final e1 = entries['e1'] as Map<String, dynamic>;
      expect(e1['key'], ['古剑']);
      expect(e1['keysecondary'], ['名剑']);
      expect(e1['comment'], '主线道具');
      expect(e1['content'], '一柄 {{char}} 使用的古剑');
      expect(e1['constant'], isTrue);
      expect(e1['selective'], isFalse);
      expect(e1['order'], 200);
      expect(e1['disable'], isFalse);
      // 独立导出格式 position 为 int 枚举
      // （0=before_char/1=after_char，DOC-15 §6.2）
      expect(e1['position'], 0);

      final ext = e1['extensions'] as Map<String, dynamic>;
      expect(ext, contains('depth'));
      expect(ext, contains('probability'));
      expect(ext, contains('useProbability'));
      expect(ext, contains('scan_depth'));
      expect(ext, contains('case_sensitive'));
      expect(ext, contains('match_whole_words'));
      expect(ext, contains('vectorized'));
    });

    test('position 映射 before/after + disable 取反 enabled', () {
      final d = WorldbookDraft.initial().upsertEntry(
        const WorldEntry(
          id: 'e1',
          keys: ['a'],
          content: 'c',
          enabled: false,
          positionBeforeChar: false,
        ),
      );
      final e1 = (buildWorldbookJson(d)['entries'] as Map)['e1']
          as Map<String, dynamic>;
      expect(e1['disable'], isTrue);
      expect(e1['position'], 1);
    });

    test('round-trip：能被 WorldbookParser 解回等价条目', () {
      final d = WorldbookDraft.initial()
          .withMeta(name: '书名')
          .upsertEntry(
            const WorldEntry(
              id: 'e1',
              keys: ['古剑'],
              content: '一柄古剑',
              constant: true,
            ),
          )
          .upsertEntry(const WorldEntry(id: 'e2', keys: ['x'], content: 'y'));
      final parsed =
          WorldbookParser.parseBook(jsonEncode(buildWorldbookJson(d)));
      expect(parsed.name, '书名');
      expect(parsed.entries, hasLength(2));
      final first = parsed.entries.first;
      expect(first.keys, ['古剑']);
      expect(first.content, '一柄古剑');
      expect(first.constant, isTrue);
      expect(first.enabled, isTrue);
    });
  });

  group('patchWorldbookJson', () {
    Map<String, dynamic> originalBook() => jsonDecode(
          jsonEncode(<String, dynamic>{
            'name': '原书',
            'description': '原描述',
            'unknown_book_level': {'keep': true},
            'entries': {
              'e1': {
                'uid': 1,
                'key': ['旧键'],
                'content': '旧内容',
                'extensions': {'position': 4, 'depth': 3, 'sticky': 2},
              },
              'e2': {
                'uid': 2,
                'key': ['e2键'],
                'content': 'e2内容',
              },
            },
          }),
        ) as Map<String, dynamic>;

    test('改 e1 + 删 e2 + 增 e3，未知字段全保留', () {
      final draft = WorldbookDraft.initial()
          .withMeta(name: '新名')
          .upsertEntry(
            const WorldEntry(id: 'e1', keys: ['新键'], content: '新内容'),
          )
          .upsertEntry(
            const WorldEntry(id: 'e3', keys: ['k3'], content: 'c3'),
          );

      final patched = patchWorldbookJson(originalBook(), draft);

      expect(patched['name'], '新名');
      // 书级未知键保留
      expect(patched['unknown_book_level'], {'keep': true});

      final entries = patched['entries'] as Map<String, dynamic>;
      expect(entries.containsKey('e2'), isFalse, reason: 'e2 应被删除');
      expect(entries.containsKey('e3'), isTrue, reason: 'e3 应存在');

      final e1 = entries['e1'] as Map<String, dynamic>;
      expect(e1['key'], ['新键']);
      expect(e1['content'], '新内容');
      // 未知 extensions 键原值仍在
      final ext = e1['extensions'] as Map<String, dynamic>;
      expect(ext['position'], 4);
      expect(ext['depth'], 3);
      expect(ext['sticky'], 2);
      // 原条目未知字段保留
      expect(e1['uid'], 1);
    });

    test('WorldEntry.extensions 携带的值覆盖原条目同名键', () {
      final draft = WorldbookDraft.initial().upsertEntry(
        const WorldEntry(
          id: 'e1',
          keys: ['k'],
          content: 'c',
          extensions: {'depth': 9, 'custom_extra': 'x'},
        ),
      );
      final patched = patchWorldbookJson(originalBook(), draft);
      final ext =
          ((patched['entries'] as Map)['e1'] as Map)['extensions'] as Map;
      expect(ext['depth'], 9, reason: '显式携带值覆盖原值');
      expect(ext['sticky'], 2, reason: '未携带的未知键保留');
      expect(ext['custom_extra'], 'x');
    });

    test('输入 original 不被就地修改', () {
      final orig = originalBook();
      final draft = WorldbookDraft.initial().upsertEntry(
        const WorldEntry(id: 'e9', keys: ['k'], content: 'c'),
      );
      patchWorldbookJson(orig, draft);
      expect((orig['entries'] as Map).keys, containsAll(['e1', 'e2']));
      expect((orig['entries'] as Map).containsKey('e9'), isFalse);
    });
  });

  group('patchCardJson', () {
    Map<String, dynamic> originalCard() => jsonDecode(
          jsonEncode(<String, dynamic>{
            'spec': 'chara_card_v2',
            'spec_version': '2.0',
            'name': '旧名',
            'data': {
              'name': '旧名',
              'description': '旧描述',
              'extensions': {
                'depth_prompt': {'prompt': 'x', 'depth': 4},
              },
              'character_book': {'entries': <dynamic>[]},
            },
          }),
        ) as Map<String, dynamic>;

    test('覆盖核心字段，未知键原样保留', () {
      final draft = CardDraft.initial()
          .withField(CardField.name, '新名')
          .withField(CardField.description, '新描述');
      final patched = patchCardJson(originalCard(), draft);

      final data = patched['data'] as Map<String, dynamic>;
      expect(data['name'], '新名');
      expect(data['description'], '新描述');
      expect(
        data['extensions'],
        {
          'depth_prompt': {'prompt': 'x', 'depth': 4},
        },
        reason: '卡级 extensions 未触达须整包保留',
      );
      expect(data['character_book'], {'entries': <dynamic>[]});
      expect(patched['spec'], 'chara_card_v2');
      expect(patched['name'], '新名', reason: 'V1 镜像同步');
    });

    test('输入 original 不被就地修改', () {
      final orig = originalCard();
      patchCardJson(orig, CardDraft.initial().withField(CardField.name, 'Z'));
      final data = orig['data'] as Map<String, dynamic>;
      expect(data['name'], '旧名');
    });
  });

  test('宏原样：{{char}}/{{user}} 不被处理', () {
    final d = WorldbookDraft.initial().upsertEntry(
      const WorldEntry(id: 'e1', keys: ['k'], content: '{{char}}对{{user}}说'),
    );
    final e1 =
        (buildWorldbookJson(d)['entries'] as Map)['e1'] as Map<String, dynamic>;
    expect(e1['content'], '{{char}}对{{user}}说');

    final card = CardDraft.initial()
        .withField(CardField.firstMes, '{{char}}: 你好，{{user}}');
    final built = buildCardJson(card);
    expect((built['data'] as Map)['first_mes'], '{{char}}: 你好，{{user}}');
  });

  group('草稿预填（编辑模式）', () {
    test('cardDraftFromJson：data 段优先，V1 扁平回退，tags 带回', () {
      final d = cardDraftFromJson({
        'name': '顶层名',
        'data': {
          'name': '阿尔',
          'description': '剑客',
          'first_mes': '你好',
          'tags': ['奇幻'],
        },
      });
      expect(d.value(CardField.name), '阿尔');
      expect(d.value(CardField.description), '剑客');
      expect(d.value(CardField.firstMes), '你好');
      expect(d.tags, ['奇幻']);

      final v1 = cardDraftFromJson({'name': '旧卡', 'description': 'x'});
      expect(v1.value(CardField.name), '旧卡');
    });

    test('worldbookDraftFromJson：uid 为条目 id，extensions 整包带回', () {
      final d = worldbookDraftFromJson({
        'name': '书',
        'entries': {
          'e1': {
            'uid': 1,
            'key': ['古剑'],
            'content': '一柄古剑',
            'disable': true,
            'extensions': {'depth': 3, 'sticky': 2},
          },
        },
      });
      expect(d.name, '书');
      final e = d.entries.single;
      expect(e.id, 'e1');
      expect(e.keys, ['古剑']);
      expect(e.enabled, isFalse, reason: 'disable=true 取反');
      expect(e.extensions['sticky'], 2);
    });

    test('round-trip：fromJson → patch 保未知键', () {
      const rawJson =
          '{"name":"书","unknown":1,"entries":{"e1":{"uid":1,"key":["k"],'
          '"content":"c","extensions":{"position":4,"depth":3}}}}';
      final d = worldbookDraftFromJson(
        Map<String, dynamic>.from(jsonDecode(rawJson) as Map),
      );
      final patched = patchWorldbookJson(
        Map<String, dynamic>.from(jsonDecode(rawJson) as Map),
        d,
      );
      expect(patched['unknown'], 1);
      final ext =
          ((patched['entries'] as Map)['e1'] as Map)['extensions'] as Map;
      expect(ext['position'], 4);
      expect(ext['depth'], 3);
    });

    // 数组格式世界书（内嵌
    // character_book 的 snake_case 形态，导入侧一直接受）——此前预填
    // 只认 dict，数组书预填出零条目空草稿，AI 覆盖保存把整书清空。
    test('WA12-1：数组格式（character_book）预填出全部条目（snake_case 兜底）', () {
      final d = worldbookDraftFromJson({
        'name': '内嵌书',
        'entries': [
          {
            'uid': 11,
            'keys': ['王城'],
            'secondary_keys': ['首都'],
            'content': '王城的设定',
            'enabled': true,
            'insertion_order': 7,
            'position': 0,
            'extensions': {'depth': 5},
          },
          {
            'uid': 12,
            'keys': ['森林'],
            'content': '森林的设定',
            'enabled': false,
          },
        ],
      });
      expect(d.name, '内嵌书');
      expect(d.entries, hasLength(2), reason: '数组条目必须全部预填（此前为 0）');
      final e11 = d.entries.firstWhere((e) => e.id == '11');
      expect(e11.keys, ['王城']);
      expect(e11.secondaryKeys, ['首都']);
      expect(e11.insertionOrder, 7);
      expect(e11.enabled, isTrue);
      expect(e11.positionBeforeChar, isTrue, reason: 'position 0=角色定义前');
      expect(e11.extensions['depth'], 5);
      final e12 = d.entries.firstWhere((e) => e.id == '12');
      expect(e12.enabled, isFalse, reason: 'enabled:false 生效');
    });

    test('WA12-1：数组格式覆盖保存——全条目保留、归一 dict、孪生键清理', () {
      const rawJson = '{"name":"内嵌书","entries":[{"uid":11,"keys":["王城"],'
          '"content":"旧文","enabled":true,"insertion_order":7,'
          '"position":0,"extensions":{"depth":5,"custom":1}}]}';
      final original = Map<String, dynamic>.from(jsonDecode(rawJson) as Map);
      final d = worldbookDraftFromJson(original);
      // AI 编辑：改内容（其余原样）
      final src = d.entries.single;
      final edited = d.upsertEntry(
        WorldEntry(
          id: src.id,
          keys: src.keys,
          content: '新文',
          secondaryKeys: src.secondaryKeys,
          insertionOrder: src.insertionOrder,
          enabled: src.enabled,
          positionBeforeChar: src.positionBeforeChar,
          extensions: src.extensions,
        ),
      );

      final patched = patchWorldbookJson(original, edited);

      final entries = patched['entries'] as Map;
      expect(entries, isA<Map<String, dynamic>>(), reason: '输出归一为独立导出 dict 形态');
      expect(entries, hasLength(1), reason: '条目不丢（此前整书被清空）');
      final row = entries['11'] as Map;
      expect(row['content'], '新文');
      expect(row['key'], ['王城'], reason: '写出 camelCase 键');
      expect(row['order'], 7);
      expect(row['disable'], isFalse);
      expect(
        row.containsKey('keys'),
        isFalse,
        reason: 'snake_case 孪生键清理，防两套字段并存',
      );
      expect(row.containsKey('enabled'), isFalse);
      expect(row.containsKey('insertion_order'), isFalse);
      final ext = row['extensions'] as Map;
      expect(ext['depth'], 5);
      expect(ext['custom'], 1, reason: 'extensions 未知键保留');
    });
  });

  group('key 标量容错（崩溃回归）', () {
    test('{"key":"单键"} 字符串标量不抛 TypeError，键被读出', () {
      // B 线亲证崩溃样本：裸 `as List?` 对字符串标量抛 TypeError，
      // _boot 无 try/catch → AI 编辑页永久转圈。
      final raw = jsonDecode(
        '{"entries": {"0": {"uid": 0, "key": "单键", "content": "正文"}}}',
      ) as Map<String, dynamic>;
      final draft = worldbookDraftFromJson(raw);
      expect(draft.entries.length, 1);
      expect(draft.entries.single.keys, ['单键']);
      expect(draft.entries.single.content, '正文');
    });

    test('逗号分隔字符串按列表展开；null/数字键返回空', () {
      final raw = jsonDecode(
        '{"entries": {"0": {"uid": 0, "key": "a,b", "keysecondary": "c"}, '
        '"1": {"uid": 1, "key": 5}, "2": {"uid": 2, "key": null}}}',
      ) as Map<String, dynamic>;
      final draft = worldbookDraftFromJson(raw);
      expect(draft.entries[0].keys, ['a', 'b']);
      expect(draft.entries[0].secondaryKeys, ['c']);
      expect(draft.entries[1].keys, isEmpty, reason: '数字标量不炸、返回空');
      expect(draft.entries[2].keys, isEmpty, reason: 'null 不炸、返回空');
    });
  });
}
