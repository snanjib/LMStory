import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/agent_tool_pipeline.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_approval_composer.dart';
import 'package:lmstory/features/advanced/presentation/utils/agent_approval_labels.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// 审批变更明细组装器单测（2026-10-15 批 B）
///
/// 验证面：四写工具的明细合成 + 转写映射（投影链与  投影器一致）、
/// 参数解析容错、merge 一期口径（意图白话 + 目标快照）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  final t = DateTime(2026, 10, 15, 12);
  ApprovalRowText display(AgentApprovalChange change) =>
      formatApprovalChange(change, LocaleSettings.instance.currentTranslations);

  late FakeFactualRepository repo;

  setUp(() {
    repo = FakeFactualRepository();
  });

  FactualEntity character({
    String id = 'ent_001',
    String name = '林晚',
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: name,
        aliases: const [],
        importance: 5,
        createdTurn: 1,
        createdAt: t,
      );

  void seedPersonality({String value = '冷静自持'}) {
    repo.seedAttribute(
      FactualAttribute(
        attributeId: 'attr_1',
        entityId: 'ent_001',
        sessionId: 's1',
        attrKey: 'personality',
        value: value,
        importance: 4,
        createdAt: t,
      ),
    );
  }

  AgentApprovalComposer composer({StoryAnchor? anchor}) =>
      AgentApprovalComposer(
        repository: repo,
        sessionId: 's1',
        draftTurnNumber: 3,
        currentAnchor: anchor,
        draftAnchor: null,
        draftEventSummary: null,
      );

  ToolExecutionRequest req(String name, Map<String, dynamic> args) =>
      ToolExecutionRequest(
        callId: 'c1',
        toolName: name,
        arguments: args,
        permission: AgentToolPermission.write,
      );

  group('update_facts 明细', () {
    test('update_attr 正常修改合成 before→after', () async {
      repo.entitiesById['ent_001'] = character();
      seedPersonality();

      final changes = await composer().compose(
        req('update_facts', {
          'deltas': [
            {
              'action': 'update_attr',
              'entityId': 'ent_001',
              'attrKey': 'personality',
              'value': '热情冲动',
              'reason': '本轮她为掩护同伴故意夸张表演',
              'confidence': 4,
            },
          ],
        }),
      );

      expect(changes, hasLength(1));
      final c = changes.single;
      expect(c.kind, ApprovalChangeKind.updateAttr);
      expect(c.entityName, '林晚');
      expect(c.attrKey, 'personality');
      expect(c.before, '冷静自持');
      expect(c.after, '热情冲动');
      expect(c.reason, '本轮她为掩护同伴故意夸张表演');
      expect(c.confidence, 4);
      expect(display(c).note, isNull);
    });

    test('值相同 → skipped 带 note 人话', () async {
      repo.entitiesById['ent_001'] = character();
      seedPersonality();

      final changes = await composer().compose(
        req('update_facts', {
          'deltas': [
            {
              'action': 'update_attr',
              'entityId': 'ent_001',
              'attrKey': 'personality',
              'value': '冷静自持',
              'confidence': 5,
            },
          ],
        }),
      );

      final c = changes.single;
      expect(display(c).note, contains('值相同'));
    });

    test('转写链投影到终态：create 撞名+value → update_attr 明细', () async {
      final existing = character();
      repo.entitiesByName = [existing];
      // 转写后的 update_attr 走 entityId 通道定位实体
      repo.entitiesById['ent_001'] = existing;
      seedPersonality();

      final changes = await composer().compose(
        req('update_facts', {
          'deltas': [
            {
              'action': 'create_entity',
              'entityType': 'character',
              'primaryName': '林晚',
              'attrKey': 'personality',
              'value': '热情冲动',
              'confidence': 4,
            },
          ],
        }),
      );

      final c = changes.single;
      // 终态是 update_attr（转写链走到底），实体定位到既有实体，
      // 且转写说明保留（用户应知道请求的是 create、实际会转 update）
      expect(c.kind, ApprovalChangeKind.updateAttr);
      expect(display(c).note, contains('同名'));
    });

    test('deltas 为 JSON 字符串也可解析；坏条目跳过不猜', () async {
      final changes = await composer().compose(
        req('update_facts', {
          'deltas':
              '[{"action":"update_attr","entityId":"ent_404","attrKey":"personality","value":"x","confidence":5}]',
        }),
      );
      // 实体不存在 → skipped(entityMissing) 仍生成一条（灰显）
      expect(changes, hasLength(1));
      expect(display(changes.single).note, contains('不存在'));

      final broken = await composer().compose(
        req('update_facts', {
          'deltas': [42, 'not-a-map'],
        }),
      );
      expect(broken, isEmpty);
    });
  });

  group('update_story_anchor 明细', () {
    test('逐字段 before→after + 伏笔差集', () async {
      const before = StoryAnchor(
        arc: '第一幕',
        foreshadows: [AnchorForeshadow(text: '断水剑下落')],
        narrativeTime: '第三日',
        oneLiner: '旧主线',
        updatedTurn: 2,
      );

      final changes = await composer(anchor: before).compose(
        req('update_story_anchor', {
          'arc': '第二幕',
          'foreshadows': [
            {'text': '断水剑下落'},
            {'text': '陈叔的身份'},
          ],
        }),
      );

      // arc 一条 + foreshadows 一条（one_liner/narrative_time 未提供不出现）
      expect(changes, hasLength(2));
      final arc = changes.firstWhere((c) => display(c).attributeLabel == '弧线');
      expect(arc.before, '第一幕');
      expect(arc.after, '第二幕');
      final fs = changes.firstWhere((c) => display(c).attributeLabel == '伏笔');
      expect(display(fs).note, contains('新增 1 项'));
      expect(display(fs).note, contains('移除 0 项'));
    });
  });

  group('record_event_memory 明细', () {
    test('5W1E 一条 + 同轮替换提示', () async {
      final changes = await composer().compose(
        req('record_event_memory', {
          'what': '林晚救下陈叔',
          'who': '林晚、陈叔',
          'significance': '结下同盟',
        }),
      );

      expect(changes, hasLength(1));
      final c = changes.single;
      expect(c.kind, ApprovalChangeKind.eventMemory);
      expect(c.after, '林晚救下陈叔');
      expect(display(c).note, contains('人物'));
      // 无草稿事件时无替换提示
      expect(display(c).note, isNot(contains('替换')));
    });
  });

  group('merge_entities 一期口径（P3）', () {
    test('意图白话行 + 目标实体快照参考', () async {
      final source = character(id: 'ent_a', name: '庄园');
      final target = character(id: 'ent_b', name: '边境庄园');
      repo.entitiesById['ent_a'] = source;
      repo.entitiesById['ent_b'] = target;
      repo.seedAttribute(
        FactualAttribute(
          attributeId: 'attr_9',
          entityId: 'ent_b',
          sessionId: 's1',
          attrKey: 'description',
          value: '边境的大型庄园',
          importance: 3,
          createdAt: t,
        ),
      );

      final changes = await composer().compose(
        req('merge_entities', {
          'source_entity_id': 'ent_a',
          'target_entity_id': 'ent_b',
          'reason': '同一地点两个名字',
          'confidence': 4,
        }),
      );

      // 意图行 + 快照行
      expect(changes.first.kind, ApprovalChangeKind.mergeNote);
      expect(display(changes.first).entityName, contains('庄园'));
      expect(display(changes.first).entityName, contains('→'));
      expect(display(changes.first).after, contains('合并'));
      expect(display(changes.first).after, contains('归档'));
      expect(changes.first.reason, '同一地点两个名字');
      expect(changes.first.confidence, 4);

      final snapshot = changes.where(
        (c) => c.kind == ApprovalChangeKind.entitySnapshot,
      );
      expect(snapshot, isNotEmpty);
      expect(snapshot.first.entityName, '边境庄园');
      expect(snapshot.first.attrKey, 'description');
    });
  });

  group('未知工具与降级', () {
    test('未知写工具返回空明细（横幅退化为摘要）', () async {
      final changes = await composer().compose(
        req('definitely_not_a_tool', const {}),
      );
      expect(changes, isEmpty);
    });
  });
}
