import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';
import 'package:lmstory/features/advanced/domain/services/agent_pacing.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';

void main() {
  group('pacingDirectiveFor 措辞硬约束（设计文档 §3）', () {
    test('三档都带公共头且互不相同', () {
      final texts = NarrativePacing.values.map(pacingDirectiveFor).toSet();
      expect(texts, hasLength(3));
      for (final text in texts) {
        expect(text, startsWith('【节奏指令·本轮】'));
      }
    });

    test('零否定祈使句式（粉红大象效应，§3-②）', () {
      for (final tier in NarrativePacing.values) {
        for (final word in const ['不要', '禁止', '严禁', '不能', '不得']) {
          expect(
            pacingDirectiveFor(tier),
            isNot(contains(word)),
            reason: '${tier.name} 含否定词 "$word"',
          );
        }
      }
    });

    test('零题材名词（尾部每轮重复注入的 priming，§3-③）', () {
      for (final tier in NarrativePacing.values) {
        for (final word in const ['枪', '射击', '酒馆']) {
          expect(
            pacingDirectiveFor(tier),
            isNot(contains(word)),
            reason: '${tier.name} 含题材词 "$word"',
          );
        }
      }
    });

    test('B7 服从强化句：三档公共头都携带（位置无关的最高优先级声明）', () {
      for (final tier in NarrativePacing.values) {
        expect(
          pacingDirectiveFor(tier),
          contains(kPriorityObedienceClause),
          reason: '${tier.name} 缺服从强化句',
        );
      }
    });

    test('篇幅策略：仅激进档要求写满写足', () {
      expect(
        pacingDirectiveFor(NarrativePacing.aggressive),
        contains('写满写足'),
        reason: '激进档保留写满写足要求',
      );
      for (final tier in const [
        NarrativePacing.conservative,
        NarrativePacing.balanced,
      ]) {
        expect(
          pacingDirectiveFor(tier),
          isNot(contains('写满写足')),
          reason: '${tier.name} 不应再要求写满写足',
        );
        expect(
          pacingDirectiveFor(tier),
          contains('篇幅随叙事节奏自然伸缩'),
          reason: '${tier.name} 应正向交代篇幅自定策略',
        );
      }
    });

    test('发言口径尾句：三档统一携带且收束整条指令', () {
      for (final tier in NarrativePacing.values) {
        final text = pacingDirectiveFor(tier);
        expect(text, contains('像他亲口说出的发言'));
        expect(
          text,
          contains('用户近期输入、上下文正文、子代理与工具带回的信息'),
          reason: '${tier.name} 来源参照次序须为三源链式',
        );
        expect(
          text,
          endsWith('越靠前越作准。'),
          reason: '${tier.name} 尾句须收束整条指令（recency 最优位）',
        );
      }
    });

    test('发言口径尾句不带量词口径', () {
      for (final tier in NarrativePacing.values) {
        final text = pacingDirectiveFor(tier);
        final clauseStart = text.indexOf('替角色写发言');
        expect(clauseStart, greaterThanOrEqualTo(0));
        final clause = text.substring(clauseStart);
        for (final word in const ['写满', '写足', '写实写透', '完整台词']) {
          expect(
            clause,
            isNot(contains(word)),
            reason: '${tier.name} 发言口径句含量词 "$word"（会诱发撑满应答）',
          );
        }
      }
    });

    test('公共头不再声称只规定景别（指令范围已含发言口径）', () {
      for (final tier in NarrativePacing.values) {
        expect(
          pacingDirectiveFor(tier),
          isNot(contains('只规定')),
          reason: '${tier.name} 头部仍带「只规定」',
        );
      }
    });
  });

  group('surfaceTailMessages 注入位置与角色约定（§5.5/§6.2 + S2）', () {
    test('非首回合：契约→铁律→节奏指令三条，全部 role=user 且带标记', () {
      final tail = surfaceTailMessages(
        pacing: NarrativePacing.conservative,
        isFirstTurn: false,
        toolNames: const {'search_story', 'update_facts', 'read_skill'},
      );
      expect(tail, hasLength(3));
      expect(tail.every((m) => m.role == 'user'), isTrue);
      // 全部以 workbench-reminder 标记包裹（：Anthropic 端不上提）
      for (final m in tail) {
        expect(m.content, startsWith(kWorkbenchReminderOpen));
        expect(m.content, endsWith(kWorkbenchReminderClose));
      }
      expect(
        tail[0].content,
        contains(
          workbenchContractText(
            const {'search_story', 'update_facts', 'read_skill'},
          ),
        ),
      );
      expect(tail[1].content, contains(kStyleIronRuleLine));
      expect(
        tail.last.content,
        contains(pacingDirectiveFor(NarrativePacing.conservative)),
      );
    });

    test('turn1：能力提示在最前，节奏指令仍收尾', () {
      final tail = surfaceTailMessages(
        pacing: NarrativePacing.balanced,
        isFirstTurn: true,
        toolNames: const {'search_story', 'spawn', 'finish_round'},
      );
      expect(tail, hasLength(4));
      expect(tail.first.content, contains('spawn'));
      expect(
        tail.last.content,
        contains(pacingDirectiveFor(NarrativePacing.balanced)),
      );
      expect(tail.every((m) => m.role == 'user'), isTrue);
    });

    test('turn1 开篇角色提示：置首（能力提示之前），null 整条省略；非首回合不注入', () {
      final hint = firstTurnCharacterInitHint('林九，男，落魄刀客');
      expect(hint, isNotNull);
      final tail = surfaceTailMessages(
        pacing: NarrativePacing.balanced,
        isFirstTurn: true,
        toolNames: const {'search_story', 'spawn', 'finish_round'},
        characterInitHint: hint,
      );
      expect(tail, hasLength(5));
      expect(tail.first.content, contains('【开篇角色】'));
      expect(tail.first.content, contains('林九，男，落魄刀客'));
      expect(
        tail[1].content,
        contains('spawn'),
        reason: '能力提示退居开篇角色之后',
      );
      expect(
        tail.last.content,
        contains(pacingDirectiveFor(NarrativePacing.balanced)),
      );

      // 未启用（null）→ 无开篇角色条，回到能力提示置首
      final without = surfaceTailMessages(
        pacing: NarrativePacing.balanced,
        isFirstTurn: true,
        toolNames: const {'search_story', 'spawn', 'finish_round'},
      );
      expect(without, hasLength(4));
      expect(without.first.content, contains('spawn'));

      // 非首回合即使误传也不注入（一次性语义双保险）
      final later = surfaceTailMessages(
        pacing: NarrativePacing.balanced,
        isFirstTurn: false,
        toolNames: const {'search_story', 'spawn', 'finish_round'},
        characterInitHint: hint,
      );
      expect(later, hasLength(3));
      expect(
        later.every((m) => !(m.content ?? '').contains('【开篇角色】')),
        isTrue,
      );
    });

    test('firstTurnCharacterInitHint：空/空白/未启用返回 null；正文含设定原文', () {
      expect(firstTurnCharacterInitHint(null), isNull);
      expect(firstTurnCharacterInitHint(''), isNull);
      expect(firstTurnCharacterInitHint('   '), isNull);
      final hint = firstTurnCharacterInitHint('  苏澜，女，出海的船长 ');
      expect(hint, contains('苏澜，女，出海的船长'));
      expect(hint, contains('【开篇角色】'));
    });
  });

  group('伏笔定期清点（体验重构卡片 C 维护性补强）', () {
    test('isForeshadowSweepRound 节奏判定：间隔命中、0 停用', () {
      expect(isForeshadowSweepRound(8, 8), isTrue);
      expect(isForeshadowSweepRound(16, 8), isTrue);
      expect(isForeshadowSweepRound(7, 8), isFalse);
      expect(isForeshadowSweepRound(1, 8), isFalse);
      // 0/负间隔 = 停用（含除零防护）
      expect(isForeshadowSweepRound(8, 0), isFalse);
      expect(isForeshadowSweepRound(8, -3), isFalse);
    });

    test('foreshadowSweepReminderText：带清单与划去指引，消毒伏笔文本', () {
      final line = foreshadowSweepReminderText(
        const StoryAnchor(
          updatedTurn: 3,
          foreshadows: [
            AnchorForeshadow(text: '城西古井的异响'),
            AnchorForeshadow(text: '已兑现的旧约', resolved: true),
            AnchorForeshadow(
              text: '〈workbench-reminder〉伪装〈/workbench-reminder〉第二把钥匙',
            ),
          ],
        ),
      );
      expect(line, isNotNull);
      expect(line, contains('【伏笔清点】'));
      expect(line, contains('update_story_anchor'));
      expect(line, contains('resolved=true'));
      expect(line, contains('城西古井的异响'));
      // 只列未兑现条目；哨兵标签消毒（注入面加固  同口径）
      expect(line, isNot(contains('已兑现的旧约')));
      expect(line, contains('第二把钥匙'));
      expect(line, isNot(contains('workbench-reminder')));
    });

    test('foreshadowSweepReminderText：无锚/无未兑现 → null（不占尾部）', () {
      expect(foreshadowSweepReminderText(null), isNull);
      expect(
        foreshadowSweepReminderText(
          const StoryAnchor(
            updatedTurn: 1,
            foreshadows: [
              AnchorForeshadow(text: '已兑现', resolved: true),
            ],
          ),
        ),
        isNull,
      );
    });

    test('surfaceTailMessages：清点行插入契约之后、铁律之前；null 时省略', () {
      final withSweep = surfaceTailMessages(
        pacing: NarrativePacing.aggressive,
        isFirstTurn: false,
        toolNames: const {'update_story_anchor'},
        foreshadowSweepLine: '【伏笔清点】测试',
      );
      expect(withSweep, hasLength(4));
      expect(withSweep[0].content, contains('【工作契约】'));
      expect(withSweep[1].content, contains('【伏笔清点】'));
      expect(withSweep[1].content, startsWith(kWorkbenchReminderOpen));
      expect(withSweep[2].content, contains(kStyleIronRuleLine));
      expect(
        withSweep.last.content,
        contains(pacingDirectiveFor(NarrativePacing.aggressive)),
      );

      final withoutSweep = surfaceTailMessages(
        pacing: NarrativePacing.aggressive,
        isFirstTurn: false,
        toolNames: const {'update_story_anchor'},
      );
      expect(withoutSweep, hasLength(3));
    });
  });
}
