import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';

/// 合并后的属性条目（记忆查看器手动归并用）
class MergedAttribute {
  const MergedAttribute({
    required this.attrKey,
    required this.value,
    this.valueType = AttributeValueType.single,
  });

  final String attrKey;
  final String value;
  final AttributeValueType valueType;
}

/// 实体归并方案（LLM 产出、UI 预览确认后落库）
///
/// [targetEntityId] 必须是参与归并的既有实体之一（保留者）；
/// 其余实体由调用方归档吸收。别名与属性均为"最终态"：
/// 落库时直接写入保留者，被吸收条目不做逐项搬迁。
class MergePlan {
  const MergePlan({
    required this.targetEntityId,
    required this.primaryName,
    required this.importance,
    required this.aliases,
    required this.attributes,
    this.notes,
  });

  /// 保留的规范实体 ID
  final String targetEntityId;

  /// 合并后的规范名
  final String primaryName;

  /// 合并后的重要度（1-5）
  final int importance;

  /// 合并后的别名并集（含被吸收实体的主名/别名）
  final List<String> aliases;

  /// 合并后的属性列表
  final List<MergedAttribute> attributes;

  /// LLM 备注（如冲突处理说明），可为空
  final String? notes;
}

/// 记忆查看器手动归并服务
///
/// 用户在事实记忆 Tab 多选重复实体后，由本服务发起一次非流式 LLM 调用，
/// 产出 [MergePlan] 供预览确认。仿照 MemoryConsolidator 的容错约定：
/// - 输出 JSON，容忍前后说明文字（截取首尾大括号）
/// - 失败/超时/解析失败 → 返回 null（调用方展示失败态可重试）
/// - 超时 30 秒；显式禁用思考（整理任务不需要）
///
/// 可观测性：所有失败路径都记日志（超时/调用异常=error，
/// 各类解析失败=warn 带原因），成功记 info——此前 catch(_) 全静默，
/// 供应商挂/超时/截断/解析失败在 UI 都是同一句"请稍后重试"，无从排查。
class FactsMergeService {
  FactsMergeService({required LlmService llmService, Logger? logger})
      : _llmService = llmService,
        _logger = logger ?? const Logger('FactsMerge');

  final LlmService _llmService;
  final Logger _logger;

  /// 合并值的长度上限（对齐 FactualConfig.maxAttrValueLength 默认值；
  /// FactApplier 同名守卫在归并暂存路径同样生效）
  static const int _maxMergedAttrValueLength = 500;

  static const String _systemPrompt = '''
你是互动故事的记忆库管理员。用户选中了若干条指向同一现实对象的事实实体（重复建档），需要你把它们整合为一条规范实体。

整合规则：
1. 从输入实体中选一条作为保留者（优先选信息最全、命名最正式的），target_entity_id 填它的 entity_id。约束：世界书来源的实体既不能作保留者也不能被吸收；角色卡来源的实体不能被吸收、可以作保留者——若输入含角色卡实体，target_entity_id 必须填它。
2. primary_name 为整合后的规范名：选最具代表性、最完整的名称。
3. aliases 为别名并集：必须包含所有其他实体（被吸收者）的主名和别名，加上保留者自己的别名；去掉重复。
4. attributes 为整合后的属性列表：同键冲突时合并描述——新值必须完整包含每条来源的有用信息，禁止丢弃任何一方的细节；无法合并的信息量大的列表用 value_type="list" 逐条列出。attr_key 只能使用输入中已出现的键。
5. importance 取各来源中的最高值（1-5）。
6. notes 简述你的取舍（可省略）。

只输出 JSON 对象，格式：
{"target_entity_id":"...","primary_name":"...","importance":3,"aliases":["..."],"attributes":[{"attr_key":"...","value":"...","value_type":"single|list|dict"}],"notes":"..."}''';

  Future<MergePlan?> planMerge({
    required List<FactualEntity> entities,
    required Map<String, List<FactualAttribute>> attributesByEntity,
    required NamingConfig namingConfig,
  }) async {
    if (entities.length < 2) {
      _logger.warn('归并方案生成跳过：实体数<2', detail: 'count=${entities.length}');
      return null;
    }

    // 口径对齐（与导演 merge_entities 同一真源——见
    // agent_session_tools.dart MergeEntitiesTool：source 拒只读、target 拒
    // worldbook）：worldbook 两角色皆不可；只读实体至多一条且只能是 card
    // （作为强制保留者）。无可行配置直接拒绝，不走 LLM。
    final readonly =
        entities.where((e) => e.source.isReadOnly).toList(growable: false);
    final hasWorldbook =
        readonly.any((e) => e.source == FactualSource.worldbook);
    if (hasWorldbook || readonly.length > 1) {
      _logger.warn(
        '归并方案生成拒绝：只读实体无法参与该组合',
        detail: 'readonly=${readonly.length}, '
            'worldbook=$hasWorldbook, entities=${entities.length}',
      );
      return null;
    }
    // 单条角色卡在选时它必须是保留者（不能被吸收）
    final forcedTargetId =
        readonly.length == 1 ? readonly.single.entityId : null;

    final request = LlmRequest(
      baseUrl: namingConfig.baseUrl,
      apiKey: namingConfig.apiKey,
      modelId: namingConfig.modelId,
      messages: [
        {'role': 'system', 'content': _systemPrompt},
        {
          'role': 'user',
          'content': _buildUserContent(
            entities,
            attributesByEntity,
          ),
        },
      ],
      temperature: 0.2,
      maxTokens: 2000,
      modelMaxOutputTokens: namingConfig.maxOutputTokens,
      stream: false,
      responseFormat: const LlmResponseFormatJsonObject(),
      protocol: namingConfig.protocol,
      providerOptions: namingConfig.providerOptions,
      reasoningEffort: ReasoningEffort.disabled,
    );

    final stopwatch = Stopwatch()..start();
    // 诊断上下文：每条失败日志都带上模型与耗时，供诊断页/日志文件排查
    String diag() =>
        'model=${namingConfig.modelId}, entities=${entities.length}, '
        '${stopwatch.elapsedMilliseconds}ms';

    try {
      final response =
          await _llmService.chat(request).timeout(const Duration(seconds: 30));
      final (plan, failReason) = _parsePlan(
        response.content,
        entities,
        attributesByEntity,
        forcedTargetId: forcedTargetId,
      );
      if (plan == null) {
        _logger.warn(
          '归并方案解析失败：${failReason ?? '未知原因'}',
          detail: '${diag()}, finish_reason=${response.finishReason ?? 'n/a'}, '
              'content_len=${response.content.length}, '
              'preview=${_preview(response.content)}',
        );
        return null;
      }
      _logger.info(
        '归并方案生成成功',
        detail: '${diag()}, target=${plan.targetEntityId}, '
            'attrs=${plan.attributes.length}, aliases=${plan.aliases.length}',
      );
      return plan;
    } on TimeoutException {
      _logger.error(
        '归并 LLM 调用超时（>30s）',
        detail: diag(),
      );
      return null;
    } catch (e, stackTrace) {
      // AppHttpException 携带 statusCode/responseBody，$e 即含供应商报错体
      _logger.error(
        '归并 LLM 调用失败',
        detail: diag(),
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  String _buildUserContent(
    List<FactualEntity> entities,
    Map<String, List<FactualAttribute>> attributesByEntity,
  ) {
    final buffer = StringBuffer()
      ..writeln('以下是 ${entities.length} 条疑似同一对象的实体档案：');
    for (var i = 0; i < entities.length; i++) {
      final e = entities[i];
      buffer.writeln(
        '${i + 1}. entity_id=${e.entityId} 主名=${e.primaryName} '
        '类型=${e.type.name} 重要度=${e.importance} 来源=${e.source.name}'
        '${e.aliases.isNotEmpty ? ' 别名=${e.aliases.join(',')}' : ''}',
      );
      final attrs =
          attributesByEntity[e.entityId] ?? const <FactualAttribute>[];
      for (final attr in attrs) {
        buffer.writeln(
          '   - ${attr.attrKey} (${attr.valueType.toDbString()}) = ${attr.value}',
        );
      }
    }
    buffer.writeln('请按整合规则输出 JSON。');
    return buffer.toString();
  }

  /// 解析产物与失败原因：plan 为 null 时 failReason 说明哪个环节拒绝
  /// （供调用方日志区分失败模式），两者互斥非空。
  /// [forcedTargetId] 非 null 时（选区含单条角色卡），方案 target 必须
  /// 落在该卡片实体上（口径对齐：角色卡只能作保留者）。
  (MergePlan?, String?) _parsePlan(
    String raw,
    List<FactualEntity> entities,
    Map<String, List<FactualAttribute>> attributesByEntity, {
    String? forcedTargetId,
  }) {
    final json = _extractJsonObject(raw);
    if (json == null) {
      return (null, '响应中无 JSON 对象（截断或空内容，查 finish_reason/content_len）');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      return (null, 'JSON 解析失败（多半被 max_tokens 截断）：$e');
    }
    if (decoded is! Map<String, dynamic>) {
      return (null, 'JSON 顶层不是对象（${decoded.runtimeType}）');
    }

    final targetId = (decoded['target_entity_id'] ?? '').toString().trim();
    final ids = entities.map((e) => e.entityId).toSet();
    if (!ids.contains(targetId)) {
      return (
        null,
        'target_entity_id 不在候选实体中（得到 "$targetId"，期望 ${ids.join('/')}）',
      );
    }
    if (forcedTargetId != null && targetId != forcedTargetId) {
      return (
        null,
        'target_entity_id 必须是只读保留者 "$forcedTargetId"（角色卡不能被吸收，得到 "$targetId"）',
      );
    }

    final primaryName = (decoded['primary_name'] ?? '').toString().trim();
    if (primaryName.isEmpty) return (null, 'primary_name 为空');

    final importance = _parseIntSafe(decoded['importance']).clamp(1, 5);

    final aliases = <String>[];
    if (decoded['aliases'] is List) {
      for (final alias in decoded['aliases'] as List) {
        final text = alias?.toString().trim() ?? '';
        if (text.isNotEmpty && text != primaryName && !aliases.contains(text)) {
          aliases.add(text);
        }
      }
    }

    final attributes = <MergedAttribute>[];
    // 输入侧校验依据：提示词的"attr_key
    // 只能使用输入中已出现的键"与值长约定此前只约束模型、不校验产物——
    // 模型幻觉键会新建白名单外属性、超长值绕过 500 字上限入库。
    final inputKeys = <String>{};
    final inputKeyTypes = <String, Set<AttributeValueType>>{};
    for (final attrs in attributesByEntity.values) {
      for (final attr in attrs) {
        inputKeys.add(attr.attrKey);
        inputKeyTypes.putIfAbsent(attr.attrKey, () => {}).add(attr.valueType);
      }
    }
    if (decoded['attributes'] is List) {
      for (final item in decoded['attributes'] as List) {
        if (item is! Map<String, dynamic>) continue;
        final key = (item['attr_key'] ?? '').toString().trim();
        final value = (item['value'] ?? '').toString().trim();
        if (key.isEmpty || value.isEmpty) continue;
        if (!inputKeys.contains(key)) continue;
        if (value.length > _maxMergedAttrValueLength) continue;
        final valueType = AttributeValueType.fromString(
          (item['value_type'] ?? 'single').toString(),
        );
        // 值类型与输入既有行一致：类型漂移会让 list 值写进 single 行
        // （或反之），displayText/listValue 解析退化。
        final allowedTypes = inputKeyTypes[key];
        if (allowedTypes != null &&
            allowedTypes.isNotEmpty &&
            !allowedTypes.contains(valueType)) {
          continue;
        }
        attributes.add(
          MergedAttribute(
            attrKey: key,
            value: value,
            valueType: valueType,
          ),
        );
      }
    }

    final notes = (decoded['notes'] ?? '').toString().trim();

    return (
      MergePlan(
        targetEntityId: targetId,
        primaryName: primaryName,
        importance: importance,
        aliases: aliases,
        attributes: attributes,
        notes: notes.isEmpty ? null : notes,
      ),
      null,
    );
  }

  /// 日志用响应预览：截 200 字符并压成单行（日志按行落盘）
  String _preview(String content) {
    final singleLine = content.replaceAll('\n', ' ').replaceAll('\r', ' ');
    return singleLine.length > 200
        ? '${singleLine.substring(0, 200)}…'
        : singleLine;
  }

  String? _extractJsonObject(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) return null;
    final end = raw.lastIndexOf('}');
    if (end <= start) return null;
    return raw.substring(start, end + 1);
  }

  int _parseIntSafe(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}
