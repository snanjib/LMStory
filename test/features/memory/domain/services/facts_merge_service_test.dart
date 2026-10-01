import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/services/facts_merge_service.dart';

/// FactsMergeService 单元测试：LLM 归并方案的产出与容错解析
void main() {
  final t = DateTime(2026, 8, 24);

  FactualEntity entity(
    String id,
    String name, {
    List<String> aliases = const [],
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: FactualEntityType.location,
        primaryName: name,
        aliases: aliases,
        importance: 3,
        createdTurn: 1,
        createdAt: t,
      );

  FactualAttribute attr(String entityId, String key, String value) =>
      FactualAttribute(
        attributeId: 'a-$entityId-$key',
        entityId: entityId,
        sessionId: 's1',
        attrKey: key,
        value: value,
        importance: 2,
        createdAt: t,
      );

  const namingConfig = NamingConfig(
    baseUrl: 'https://api.example.com',
    apiKey: 'sk-test',
    modelId: 'test-model',
  );

  Map<String, List<FactualAttribute>> attrsByEntity(
    List<FactualAttribute> all,
  ) {
    return {
      for (final id in all.map((a) => a.entityId).toSet())
        id: all.where((a) => a.entityId == id).toList(),
    };
  }

  group('FactsMergeService.planMerge', () {
    test('正常 JSON → 完整 MergePlan，别名去重且不含规范名', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(
          responseContent: jsonEncode({
            'target_entity_id': 'e-2',
            'primary_name': '边境庄园',
            'importance': '4',
            'aliases': ['庄园', '老宅', '边境庄园'],
            'attributes': [
              {'attr_key': 'description', 'value': '边境的老庄园，有护城河'},
              {
                'attr_key': 'features',
                'value': '["护城河"]',
                'value_type': 'list',
              },
            ],
            'notes': '合并两段描述',
          }),
        ),
      );
      final entities = [
        entity('e-1', '庄园', aliases: ['老宅']),
        entity('e-2', '边境庄园'),
      ];
      final plan = await service.planMerge(
        entities: entities,
        // features 行必须有输入依据（校验：方案键只能来自输入键集）
        attributesByEntity: attrsByEntity(<FactualAttribute>[
          attr('e-1', 'description', '城外的老庄园'),
          attr('e-2', 'description', '位于边境'),
          FactualAttribute(
            attributeId: 'a-e-1-features',
            entityId: 'e-1',
            sessionId: 's1',
            attrKey: 'features',
            value: '["护城河"]',
            importance: 2,
            valueType: AttributeValueType.list,
            createdAt: t,
          ),
        ]),
        namingConfig: namingConfig,
      );

      expect(plan, isNotNull);
      expect(plan!.targetEntityId, 'e-2');
      expect(plan.primaryName, '边境庄园');
      expect(plan.importance, 4);
      // 别名并集保留，规范名自身不重复出现
      expect(plan.aliases, ['庄园', '老宅']);
      expect(plan.attributes, hasLength(2));
      expect(plan.attributes[1].valueType, AttributeValueType.list);
      expect(plan.notes, '合并两段描述');
    });

    test('容忍 JSON 前后的说明文字', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(
          responseContent: '好的，整合如下：'
              '{"target_entity_id":"e-1","primary_name":"庄园",'
              '"importance":3,"aliases":[],"attributes":[]} 请确认。',
        ),
      );
      final plan = await service.planMerge(
        entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );
      expect(plan, isNotNull);
      expect(plan!.primaryName, '庄园');
    });

    test('WA-X5 校验：幻觉键 / 超长值 / 类型漂移的属性被过滤', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(
          responseContent: jsonEncode({
            'target_entity_id': 'e-2',
            'primary_name': '边境庄园',
            'importance': 3,
            'aliases': <String>[],
            'attributes': <Map<String, dynamic>>[
              // 输入中没有 secret_key → 幻觉键，过滤
              {'attr_key': 'secret_key', 'value': '凭空出现的键'},
              // 超过 500 字 → 过滤
              {
                'attr_key': 'description',
                'value': '长' * 501,
              },
              // 输入 description 均为 single，方案声明 dict → 类型漂移，过滤
              {
                'attr_key': 'description',
                'value': '{"a":1}',
                'value_type': 'dict',
              },
              // 合法：输入键 + 类型一致
              {'attr_key': 'description', 'value': '合并后的描述'},
            ],
          }),
        ),
      );
      final plan = await service.planMerge(
        entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
        attributesByEntity: attrsByEntity(<FactualAttribute>[
          attr('e-1', 'description', '城外的老庄园'),
          attr('e-2', 'description', '位于边境'),
        ]),
        namingConfig: namingConfig,
      );

      expect(plan, isNotNull);
      expect(plan!.attributes, hasLength(1));
      expect(plan.attributes.single.attrKey, 'description');
      expect(plan.attributes.single.value, '合并后的描述');
    });

    test('target 不在输入实体中 / 主名为空 / 非 JSON → 返回 null', () async {
      Future<MergePlan?> run(String content) {
        return FactsMergeService(
          llmService: _StubLlmService(responseContent: content),
        ).planMerge(
          entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
          attributesByEntity: const {},
          namingConfig: namingConfig,
        );
      }

      expect(
        await run(
          '{"target_entity_id":"e-9","primary_name":"X",'
          '"importance":3,"aliases":[],"attributes":[]}',
        ),
        isNull,
      );
      expect(
        await run(
          '{"target_entity_id":"e-1","primary_name":"",'
          '"importance":3,"aliases":[],"attributes":[]}',
        ),
        isNull,
      );
      expect(await run('完全不是 JSON'), isNull);
    });

    test('LLM 异常 / 少于 2 条实体 → null（不抛出）', () async {
      final failing = FactsMergeService(
        llmService: _StubLlmService(throwException: true),
      );
      expect(
        await failing.planMerge(
          entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
          attributesByEntity: const {},
          namingConfig: namingConfig,
        ),
        isNull,
      );

      final ok = FactsMergeService(llmService: _StubLlmService());
      expect(
        await ok.planMerge(
          entities: [entity('e-1', '庄园')],
          attributesByEntity: const {},
          namingConfig: namingConfig,
        ),
        isNull,
      );
    });
  });

  group('B10 口径对齐（source 拒只读、target 拒 worldbook）', () {
    FactualEntity sourced(
      String id,
      String name,
      FactualSource source,
    ) =>
        FactualEntity(
          entityId: id,
          sessionId: 's1',
          type: FactualEntityType.character,
          primaryName: name,
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: t,
          source: source,
        );

    test('card-as-target：单张角色卡可作保留者，方案 target 落卡片 → 通过', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(
          responseContent: jsonEncode({
            'target_entity_id': 'card-1',
            'primary_name': '守碑人',
            'importance': 4,
            'aliases': ['碑翁'],
            'attributes': <Map<String, String>>[],
          }),
        ),
      );
      final plan = await service.planMerge(
        entities: [
          sourced('card-1', '守碑人', FactualSource.card),
          sourced('e-9', '碑翁', FactualSource.auto),
        ],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      expect(plan, isNotNull, reason: '角色卡作为保留者是合法组合');
      expect(plan!.targetEntityId, 'card-1');
    });

    test('含角色卡时方案 target 落普通实体（卡片将被吸收）→ 拒绝', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(
          responseContent: jsonEncode({
            'target_entity_id': 'e-9',
            'primary_name': '碑翁',
            'importance': 3,
            'aliases': <String>[],
            'attributes': <Map<String, String>>[],
          }),
        ),
      );
      final plan = await service.planMerge(
        entities: [
          sourced('card-1', '守碑人', FactualSource.card),
          sourced('e-9', '碑翁', FactualSource.auto),
        ],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      expect(plan, isNull, reason: '角色卡不可被吸收，target 必须落卡片');
    });

    test('世界书实体参与（两角色皆不可）→ 直接拒绝不走 LLM', () async {
      final llm = _CountingLlmService();
      final service = FactsMergeService(llmService: llm);
      final plan = await service.planMerge(
        entities: [
          sourced('wb-1', '世界设定', FactualSource.worldbook),
          sourced('e-9', '设定残留', FactualSource.auto),
        ],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      expect(plan, isNull);
      expect(llm.callCount, 0, reason: '无可行组合应在 LLM 调用前拒绝');
    });

    test('多条只读实体（必有一条被吸收）→ 直接拒绝不走 LLM', () async {
      final llm = _CountingLlmService();
      final service = FactsMergeService(llmService: llm);
      final plan = await service.planMerge(
        entities: [
          sourced('card-1', '守碑人甲', FactualSource.card),
          sourced('card-2', '守碑人乙', FactualSource.card),
          sourced('e-9', '碑翁', FactualSource.auto),
        ],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      expect(plan, isNull);
      expect(llm.callCount, 0);
    });
  });

  group('FactsMergeService 失败可观测性（2026-08-26：失败必须留痕可排查）', () {
    late _CapturingSink sink;

    setUp(() {
      sink = _CapturingSink();
      Logger.clearSinks();
      Logger.addSink(sink);
    });

    tearDown(Logger.clearSinks);

    test('LLM 调用异常 → error 日志，带模型名与异常对象', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(throwException: true),
      );
      await service.planMerge(
        entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      final record = sink.singleOfLevel(LogLevel.error);
      expect(record.message, contains('归并 LLM 调用失败'));
      expect(record.detail, contains('model=test-model'));
      expect(record.error, isNotNull);
    });

    test('超时 → 单独的超时 error 日志', () async {
      final service = FactsMergeService(
        llmService: _ThrowingLlmService(TimeoutException('30s 超时')),
      );
      await service.planMerge(
        entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      final record = sink.singleOfLevel(LogLevel.error);
      expect(record.message, contains('超时'));
    });

    test('响应非 JSON → warn 日志带原因与响应预览', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(responseContent: '抱歉，我无法完成这个任务。'),
      );
      await service.planMerge(
        entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      final record = sink.singleOfLevel(LogLevel.warn);
      expect(record.message, contains('归并方案解析失败'));
      expect(record.message, contains('无 JSON 对象'));
      expect(record.detail, contains('preview=抱歉，我无法完成这个任务。'));
    });

    test('target 不在候选实体 → warn 日志指明期望与实际值', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(
          responseContent: jsonEncode({
            'target_entity_id': 'e-9',
            'primary_name': 'X',
            'importance': 3,
            'aliases': <String>[],
            'attributes': <Map<String, String>>[],
          }),
        ),
      );
      await service.planMerge(
        entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      final record = sink.singleOfLevel(LogLevel.warn);
      expect(record.message, contains('target_entity_id'));
      expect(record.message, contains('e-9'));
      expect(record.message, contains('e-1'));
    });

    test('成功 → info 日志带模型与保留实体', () async {
      final service = FactsMergeService(
        llmService: _StubLlmService(
          responseContent: jsonEncode({
            'target_entity_id': 'e-2',
            'primary_name': '边境庄园',
            'importance': 3,
            'aliases': <String>[],
            'attributes': <Map<String, String>>[],
          }),
        ),
      );
      await service.planMerge(
        entities: [entity('e-1', '庄园'), entity('e-2', '边境庄园')],
        attributesByEntity: const {},
        namingConfig: namingConfig,
      );

      final record = sink.singleOfLevel(LogLevel.info);
      expect(record.message, '归并方案生成成功');
      expect(record.detail, contains('model=test-model'));
      expect(record.detail, contains('target=e-2'));
    });
  });
}

class _StubLlmService implements LlmService {
  _StubLlmService({this.responseContent = '', this.throwException = false});

  final String responseContent;
  final bool throwException;

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    if (throwException) {
      throw Exception('LLM 调用失败');
    }
    return LlmResponse(content: responseContent);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 计数桩（：验证无可行组合时在 LLM 调用前拒绝）
class _CountingLlmService implements LlmService {
  int callCount = 0;

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    callCount++;
    return const LlmResponse(content: '{}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 固定异常类型的桩（超时分支测试用）
class _ThrowingLlmService implements LlmService {
  _ThrowingLlmService(this.exception);

  final Exception exception;

  @override
  Future<LlmResponse> chat(LlmRequest request) async => throw exception;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 收集 LogRecord 的测试 sink（extends 继承 currentFilePath 默认 null）
class _CapturingSink extends LogSink {
  final records = <LogRecord>[];

  LogRecord singleOfLevel(LogLevel level) {
    final matched = records.where((r) => r.level == level).toList();
    expect(matched, hasLength(1), reason: '期望恰好一条 $level 日志，实际 $records');
    return matched.single;
  }

  @override
  void write(LogRecord record) => records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}
