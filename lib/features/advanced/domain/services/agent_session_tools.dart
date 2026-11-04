import 'dart:convert';
import 'dart:typed_data';

import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/text/injection_guard.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_prose_contract.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/agent_style_lint.dart';
import 'package:lmstory/features/advanced/domain/services/agent_subagent.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/advanced/domain/services/search_story_text_tool.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/memory/domain/services/memory_query.dart';
import 'package:lmstory/features/memory/domain/services/memory_retrieval_exception.dart';

/// 工具集依赖包（控制器按会话组装，draft 每轮更换）
///
///  零工具轮升级闸门阈值：连续 ≥ 此轮数未调用 update_facts /
/// record_event_memory 时，finish_round 的事件记忆豁免升级为"须在
/// noEventReason 参数说明原因"（长会话退化治理设计 §3-S5，对 R5）。
const int kZeroToolEscalateAfter = 3;

class AgentToolDeps {
  const AgentToolDeps({
    required this.sessionId,
    required this.draft,
    required this.factualRepository,
    required this.experienceRepository,
    required this.storyReader,
    required this.latestMacros,
    required this.userInteraction,
    required this.commitRound,
    this.loadSkillBody,
    this.skillNames = const [],
    this.embedQuery,
    this.factualConfig = const FactualConfig(),
    this.enableAskUser = false,
    this.styleLint,
    this.currentAnchor,
    this.roundUserInput,
    this.spawnToolFactory,
    this.zeroMemoryRoundStreak = 0,
    this.foreshadowCheckInterval = 8,
    this.embedQueryTimeout,
    this.retrievalProfile,
  });

  final String sessionId;
  final AgentRoundDraft draft;
  final FactualRepository factualRepository;
  final ExperienceRepository experienceRepository;
  final AgentStoryReader storyReader;

  /// 最新宏摘要（常驻基线候选，read_compact_summary 用）
  final Future<List<ExperientialMemory>> Function() latestMacros;

  /// ask_user 的 UI 桥
  final AgentUserInteractionPort userInteraction;

  /// read_skill 的正文加载器（null = 无 skill 系统）
  final Future<String?> Function(String name)? loadSkillBody;

  /// 可用 skill 名单（工具描述用）
  final List<String> skillNames;

  /// finish_round 的轮提交（控制器内单一 drift 事务）
  final Future<String> Function(AgentRoundDraft draft) commitRound;

  /// 查询向量按需计算（检索工具内部现算；null = 未配置 embedding，仅 FTS）
  final Future<Float32List?> Function(String query)? embedQuery;

  final FactualConfig factualConfig;

  /// ask_user 是否注册（体验重构 ：UI 未接线前不注册，消除提示词/能力错配；
  ///  接横幅后开启）
  final bool enableAskUser;

  /// 完稿文风 lint（null = 禁用机检兜底层）；检查对象为 prose 参数
  final AgentStyleLint? styleLint;

  /// 会话当前剧情锚（update_story_anchor 部分更新的基底；null = 会话无锚）
  final StoryAnchor? Function()? currentAnchor;

  /// 本轮用户输入（终审闸门 A 的已知实体匹配素材之一；null = 拿不到）
  final String Function()? roundUserInput;

  /// spawn 子代理工厂（null = 不注册 spawn 工具）。入参为本工具集的
  /// 只读工具（子代理 research 档复用，共享 draft：检索命中登记进本轮
  /// 审计快照，只读无事务风险；update/finish 类不进子代理白名单）。
  final SpawnTool Function(List<AgentTool> readOnlyTools)? spawnToolFactory;

  /// 轮开始时统计的"连续零记忆轮"数（升级闸门输入；0 = 无升级）。
  /// 由 DirectorRoundRunner 从最近 artifacts 计算（zeroMemoryRoundStreak）。
  final int zeroMemoryRoundStreak;

  /// search_story 的 embedQuery 独立短超时帽（runner 从
  /// advanced.embedding.timeout_ms 同源注入；null = 工具默认 15s）。
  final Duration? embedQueryTimeout;

  /// 伏笔定期清点间隔轮数（清点轮 = 轮尾清点提醒 + finish_round 伏笔
  /// 对账闸门；与 runner 轮尾装配共用 isForeshadowSweepRound 节奏源，
  /// 来源 advanced.harness.foreshadow_check_interval；0 = 停用）。
  final int foreshadowCheckInterval;

  /// 会话「检索松紧度」快照（：runner 从 chat_sessions.
  /// retrieval_overrides 注入；null = 未物化，search_story 用内置默认）。
  final RetrievalProfile? retrievalProfile;
}

/// 事实 delta 的 LLM 输入形状（snake_case，FactsDelta.toJson 的子集）
///
/// update_facts 工具参数校验后转 [FactsDelta] 写入草稿；
/// 提交时 FactApplier 的全部守护（白名单/去重/频率/置信度/只读）原样生效。
class AgentFactsDeltaInput {
  const AgentFactsDeltaInput({
    required this.action,
    required this.confidence,
    this.entityId,
    this.entityType,
    this.primaryName,
    this.attrKey,
    this.value,
    this.reason,
    this.importance,
  });

  final String action;
  final int confidence;
  final String? entityId;
  final String? entityType;
  final String? primaryName;
  final String? attrKey;
  final String? value;
  final String? reason;
  final int? importance;

  FactsDelta? toFactsDelta() {
    // FactAction.fromString 对未知值抛 ArgumentError：先按已知动作白名单
    // 预检（不捕获 Error），未知动作返回 null
    const knownActions = {
      'create_entity',
      'update_attr',
      'append_list',
      'remove_from_list',
      'add_alias',
      'archive_entity',
    };
    if (!knownActions.contains(action)) return null;
    final parsedAction = FactAction.fromString(action);
    if (entityId == null && primaryName == null) return null;
    return FactsDelta(
      action: parsedAction,
      confidence: confidence,
      entityId: entityId,
      entityType: entityType,
      primaryName: primaryName,
      attrKey: attrKey,
      value: value,
      reason: reason,
      importance: importance,
    );
  }

  /// 弱模型容错解析：
  /// 字段别名归一（camelCase/`name`）、action 简写归一、confidence 数值
  /// 归一（"3"/0.8 概率/80 百分制 → 1-5）、整条序列化成字符串的兜底。
  /// 返回 (input, error) 二者互斥；error 逐条进失败信封反馈给模型。
  static ({AgentFactsDeltaInput? input, String? error}) fromRaw(Object? raw) {
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return fromRaw(decoded);
      } on FormatException {
        // 落到下面的通用拒绝
      }
    }
    if (raw is! Map<String, dynamic>) {
      return (input: null, error: '不是 JSON 对象');
    }
    final action = _normalizeActionName(raw['action']);
    if (action == null) {
      return (input: null, error: 'action「${raw['action']}」不是六种之一');
    }
    final confidence = _normalizeOneToFive(raw['confidence']);
    if (confidence == null) {
      return (
        input: null,
        error: 'confidence「${raw['confidence']}」非法（应为 1-5）',
      );
    }
    final entityId = _readString(raw, const ['entity_id', 'entityId']);
    final primaryName = _readString(
      raw,
      const ['primary_name', 'primaryName', 'name'],
    );
    if (entityId == null && primaryName == null) {
      return (input: null, error: 'entity_id 与 primary_name 至少需要一个');
    }
    return (
      input: AgentFactsDeltaInput(
        action: action,
        confidence: confidence,
        entityId: entityId,
        entityType: _readString(raw, const ['entity_type', 'entityType']),
        primaryName: primaryName,
        attrKey: _readString(raw, const ['attr_key', 'attrKey']),
        value: _readString(raw, const ['value']),
        reason: _readString(raw, const ['reason']),
        importance: _normalizeOptionalOneToFive(raw['importance']),
      ),
      error: null,
    );
  }
}

/// 按候选键名取第一个非空字符串值（弱模型字段名别名归一）
String? _readString(Map<String, dynamic> raw, List<String> keys) {
  for (final key in keys) {
    final value = raw[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

/// action 归一：小写 + 常见简写映射（create→create_entity 等）
String? _normalizeActionName(Object? raw) {
  if (raw == null) return null;
  const aliases = {
    'create': 'create_entity',
    'create_entity': 'create_entity',
    'update': 'update_attr',
    'update_attr': 'update_attr',
    'set_attr': 'update_attr',
    'append': 'append_list',
    'append_list': 'append_list',
    'add_to_list': 'append_list',
    'remove': 'remove_from_list',
    'remove_from_list': 'remove_from_list',
    'add_alias': 'add_alias',
    'alias': 'add_alias',
    'archive': 'archive_entity',
    'archive_entity': 'archive_entity',
  };
  return aliases[raw.toString().trim().toLowerCase()];
}

/// 1-5 分制归一：接受数字/数字字符串；按量程识别原分制——
/// <1 概率制（×5）、6-10 十分制（÷2）、>10 百分制（÷20）
int? _normalizeOneToFive(Object? raw) {
  double? value;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    value = double.tryParse(raw.trim());
  }
  if (value == null || value <= 0) return null;
  if (value < 1) return (value * 5).round().clamp(1, 5);
  if (value <= 5) return value.round().clamp(1, 5);
  if (value <= 10) return (value / 2).round().clamp(1, 5);
  if (value <= 100) return (value / 20).round().clamp(1, 5);
  return 5;
}

/// 可选的 1-5 分制字段（importance）：缺失/非法返回 null 而不是拒绝整条
int? _normalizeOptionalOneToFive(Object? raw) {
  if (raw == null) return null;
  return _normalizeOneToFive(raw);
}

/// 组装 P0 工具集（设计报告 §7.4 表）+  read_skill
///
/// ask_user 按 [AgentToolDeps.enableAskUser] 注册（：UI 横幅接线前不注册）。
/// spawn 按 [AgentToolDeps.spawnToolFactory] 注册（工厂非空即接线）。
///
///  双维护纪律：各工具的 `description` 是事实性表述（参数语义/上限/
/// 拒绝条件）的唯一权威；系统提示词"工具索引"（agent_system_prompt.dart
/// 的 _buildToolIndex）是其浓缩版——修改任一侧时必须同步另一侧。
///
/// [deniedTools]（导演设置 ，设计文档 §5.1 deny 语义）：被拒工具不注册
/// ——模型不可见，系统提示词工具索引随实际注册集自动移除（buildFrozenPrefix
/// 以返回列表为准）；子代理 research 档拿到的只读集同步剔除（与主代理
/// allow 集求交集的等价实现）。
List<AgentTool> buildAgentTools(
  AgentToolDeps deps, {
  Set<String> deniedTools = const {},
}) {
  final readOnlyTools = [
    if (deps.loadSkillBody != null) ReadSkillTool(deps),
    SearchStoryTool(
      deps,
      embedQueryTimeout: deps.embedQueryTimeout,
      canSearchStoryText: !deniedTools.contains('search_story_text'),
    ),
    SearchStoryTextTool(reader: deps.storyReader, draft: deps.draft),
    ReadStoryTool(deps),
    QueryFactsTool(deps),
    ReadCompactSummaryTool(deps),
  ].where((t) => !deniedTools.contains(t.name)).toList();
  return [
    ...readOnlyTools,
    UpdateFactsTool(deps),
    MergeEntitiesTool(deps),
    UpdateStoryAnchorTool(deps),
    RecordEventMemoryTool(deps),
    if (deps.spawnToolFactory != null) deps.spawnToolFactory!(readOnlyTools),
    if (deps.enableAskUser) AskUserTool(deps),
    FinishRoundTool(deps),
  ].where((t) => !deniedTools.contains(t.name)).toList();
}

// ==================== 只读：search_story ====================

class SearchStoryTool implements AgentTool {
  SearchStoryTool(
    this._deps, {
    Duration? embedQueryTimeout,
    this.canSearchStoryText = true,
  }) : embedQueryTimeout = embedQueryTimeout ?? _defaultEmbedTimeout;

  final bool canSearchStoryText;

  String get _textSearchHint => canSearchStoryText
      ? '\n若这些摘要仍不足以核实所需细节，可用 search_story_text，以少量关键词搜索历史原文，必要时移除人物名等限制条件。'
      : '';

  /// embedQuery 网络调用的独立短超时默认值
  static const Duration _defaultEmbedTimeout = Duration(seconds: 15);

  /// embedQuery 独立短超时（：构造注入取代 static 可变字段）。
  /// runner 侧从 advanced.embedding.timeout_ms 同源注入（取
  /// max(配置, 15s)）——此前固定 15s 会把用户配置的更长超时截死。
  final Duration embedQueryTimeout;

  /// 成功回执的输出结构声明
  static const Map<String, String> kOutputSchema = {
    'query': 'string',
    'hitCount': 'int',
  };

  final AgentToolDeps _deps;

  @override
  String get name => 'search_story';

  @override
  String get description =>
      '检索故事记忆（经历摘要/事件记忆，带轮号位置）。先搜摘要定位轮号，再用 read_story 回读原文。检索失败会返回"没命中"，请换关键词重试而不是放弃。'
      '$_textSearchHint';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '检索词（人物名/地点/事件）'},
        'top_k': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 20,
          'description': '返回条数（上限 20；不传按会话检索配置取默认）',
        },
      },
      'required': ['query'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final query = arguments['query']?.toString() ?? '';
    if (query.isEmpty) {
      return AgentToolResult.failure(
        title: '缺少检索词',
        output: 'query 不能为空。请提供要检索的关键词。',
      );
    }
    // 安全解析（数字字符串/浮点容错；非法或越界给可行动信封）
    // 模型未传 top_k 时回落会话「检索松紧度」快照值（再回落内置 8）
    final topK = parseIntegerArg(
      arguments,
      'top_k',
      min: 1,
      max: 20,
      fallback: _deps.retrievalProfile?.topK ?? 8,
    );
    if (topK.error != null) {
      return AgentToolResult.failure(title: '参数不对', output: topK.error!);
    }
    _deps.draft.searchQueries.add(query);

    invocation.onProgress?.call('检索「$query」');

    Float32List? vector;
    final embedder = _deps.embedQuery;
    if (embedder != null) {
      // embedding 网络调用单独短超时——内嵌在检索工具里，挂死会
      // 连带整个工具调用挂死；超时一律退化为纯 FTS 检索，轮次继续。
      // 去掉 catchError 兜底——降级与否由 embedder 链路
      // 决定（fallback_on_failure=true 在 host._resolveQueryVector 内
      // 返 null；false 抛 EmbeddingCallFailedException），此处原样传播，
      // 经管线致命通道上抛触发 E104（此前被吞成静默 FTS，E104 不可达）。
      //（显式 Future<Float32List?> 上转：async 抛错 lambda 推得
      // Future<Never> 会把 onTimeout 的 Null 收窄成类型错误）
      final pending = embedder(query);
      vector = await pending.timeout(
        embedQueryTimeout,
        onTimeout: () => null,
      );
    }

    var hits = <ScoredMemory>[];
    try {
      hits = [
        ...await _deps.experienceRepository.searchExperiencesMultiChannel(
          sessionId: _deps.sessionId,
          fts5Queries: [query],
          vectorQueries: [
            (query: query, vector: vector),
          ],
          topK: topK.value!,
          fts5Weight: 0.6,
          vectorWeight: 0.4,
          keyEventThreshold: 4,
          keyEventBoost: 1.5,
          normalizationEpsilon: 1e-6,
          // 向量质量过滤阈值来自会话松紧度快照（null/缺省 0.0 = 不过滤）
          vectorScoreThreshold:
              _deps.retrievalProfile?.vectorScoreThreshold ?? 0.0,
          currentTurnNumber: _deps.draft.turnNumber,
        ),
      ];
    } on MemoryRetrievalUnavailableException catch (e) {
      // 2026-09-09 审查：全通道失败必须与"没有命中"区分——否则
      // 模型会断定"库里不存在"并重复建档。
      _deps.draft.calledTools.add(name);
      return AgentToolResult.failure(
        title: '检索通道不可用',
        output:
            '记忆检索通道当前不可用（${e.attemptedChannels} 条通道全部失败）。这不代表记忆库里没有该内容。请稍后重试，或改用 read_story(turn=轮号) 直接回读原文。$_textSearchHint',
      );
    }

    // 子串兜底（2026-09-09 审查）：多通道只覆盖有 FTS 行
    //（importance ≥ 存储门槛）或有向量的记忆；未建索引、低重要性、以及
    // 双字关键词（trigram 无法召回）的记忆由主表 LIKE 补齐到 topK。
    final fallbackTerms = MemoryQuery.tokenize(query);
    if (fallbackTerms.isNotEmpty && hits.length < topK.value!) {
      final fallback =
          await _deps.experienceRepository.searchExperiencesBySubstring(
        _deps.sessionId,
        fallbackTerms,
        limit: topK.value!,
      );
      final seen = {for (final h in hits) h.memory.memoryId};
      for (final memory in fallback) {
        if (hits.length >= topK.value!) break;
        if (!seen.add(memory.memoryId)) continue;
        hits.add(
          ScoredMemory(
            memory: memory,
            fts5Score: 0,
            vectorScore: 0,
            temporalScore: 0,
            finalScore: 0,
          ),
        );
      }
    }

    if (hits.isEmpty) {
      _deps.draft.calledTools.add(name);
      return AgentToolResult.success(
        title: '「$query」· 未命中',
        output:
            '没有找到与「$query」相关的记忆。请换一个关键词重试（如人物名、地名、事件动作），或用 read_story 浏览近几轮原文。$_textSearchHint',
        metadata: {'query': query, 'hitCount': 0},
        outputSchema: kOutputSchema,
      );
    }

    final lines = <String>['共 ${hits.length} 条命中（按相关度排序）：'];
    for (var i = 0; i < hits.length; i++) {
      final memory = hits[i].memory;
      final excerpt =
          (memory.summary ?? memory.what ?? '').replaceAll('\n', ' ');
      final preview =
          excerpt.length > 80 ? '${excerpt.substring(0, 80)}…' : excerpt;
      lines.add(
        '${i + 1}. [第${memory.turnNumber}轮] $preview${memory.isMacro ? '（宏摘要）' : ''}',
      );
      _deps.draft.retrievedMemories.add(memory);
    }
    lines.add('提示：用 read_story(turn=轮号) 回读对应轮次的完整原文。');

    _deps.draft.calledTools.add(name);
    return AgentToolResult.success(
      title: '「$query」· ${hits.length} 处命中',
      output: '${lines.join('\n')}$_textSearchHint',
      metadata: {'query': query, 'hitCount': hits.length},
      outputSchema: kOutputSchema,
    );
  }
}

// ==================== 只读：read_story ====================

class ReadStoryTool implements AgentTool {
  ReadStoryTool(this._deps);

  /// 成功回执的输出结构声明（三条早退分支同样补记分项）
  static const Map<String, String> kOutputSchema = {
    'fromTurn': 'int',
    'rounds': 'int',
    'total': 'int',
  };

  final AgentToolDeps _deps;

  @override
  String get name => 'read_story';

  @override
  String get description =>
      '按轮号回读故事原文（用户输入 + 生成正文 + 回复 + 事件摘要）。用于核对细节、引用原文、检查伏笔。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'turn': {
          'type': 'integer',
          'minimum': 1,
          'description': '起始轮号（1-based）',
        },
        'count': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 5,
          'description': '读取轮数（默认 1，上限 5）',
        },
      },
      'required': ['turn'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    // 安全解析（此前 `as int?` 会把 Dart 类型错误原文喂给模型）
    final turn = parseIntegerArg(arguments, 'turn', min: 1);
    if (turn.error != null) {
      return AgentToolResult.failure(title: '参数不对', output: turn.error!);
    }
    final count =
        parseIntegerArg(arguments, 'count', min: 1, max: 5, fallback: 1);
    if (count.error != null) {
      return AgentToolResult.failure(title: '参数不对', output: count.error!);
    }

    final total = await _deps.storyReader.totalRounds();
    if (total == 0) {
      _deps.draft.calledTools.add(name);
      return AgentToolResult.success(
        title: '还没有正文',
        output: '故事还没有任何已提交的轮次。当前是第一轮。',
        metadata: {'fromTurn': turn.value, 'rounds': 0, 'total': 0},
        outputSchema: kOutputSchema,
      );
    }

    final rounds = await _deps.storyReader.readRounds(
      fromTurn: turn.value!,
      count: count.value!,
    );
    if (rounds.isEmpty) {
      _deps.draft.calledTools.add(name);
      return AgentToolResult.success(
        title: '第 ${turn.value} 幕不存在',
        output: '第 ${turn.value} 轮不存在。当前共 $total 轮，turn 取值 1-$total。',
        metadata: {'fromTurn': turn.value, 'rounds': 0, 'total': total},
        outputSchema: kOutputSchema,
      );
    }

    final sections = <String>[];
    for (final round in rounds) {
      if (round.isEmpty) continue;
      final buffer = StringBuffer('【第${round.turnNumber}轮】');
      if (round.userText?.isNotEmpty ?? false) {
        buffer.write('\n用户：${round.userText}');
      }
      if (round.narrativeText?.isNotEmpty ?? false) {
        buffer.write('\n正文：${round.narrativeText}');
      }
      if ((round.replyText?.isNotEmpty ?? false) &&
          round.replyText != round.narrativeText) {
        buffer.write('\n回复：${round.replyText}');
      }
      if (round.eventSummaryText?.isNotEmpty ?? false) {
        buffer.write('\n事件摘要：${round.eventSummaryText}');
      }
      sections.add(buffer.toString());
    }

    if (sections.isEmpty) {
      _deps.draft.calledTools.add(name);
      return AgentToolResult.success(
        title: '该幕无正文',
        output: '第 ${turn.value} 轮没有已保存的正文内容（可能是纯对话轮）。',
        metadata: {'fromTurn': turn.value, 'rounds': 0, 'total': total},
        outputSchema: kOutputSchema,
      );
    }

    _deps.draft.calledTools.add(name);
    return AgentToolResult.success(
      title: '第 ${turn.value} 幕起 · ${sections.length} 幕',
      output: sections.join('\n\n'),
      metadata: {
        'fromTurn': turn.value,
        'rounds': sections.length,
        'total': total,
      },
      outputSchema: kOutputSchema,
    );
  }
}

// ==================== 只读：query_facts ====================

class QueryFactsTool implements AgentTool {
  QueryFactsTool(this._deps);

  /// 成功回执的输出结构声明
  static const Map<String, String> kOutputSchema = {'count': 'int'};

  final AgentToolDeps _deps;

  @override
  String get name => 'query_facts';

  @override
  String get description =>
      '查询事实层（实体卡片）：按名称精查或按关键词模糊查（关键词按空白/标点切分，覆盖主名、别名与属性值），返回实体 ID、类型、重要度、属性（状态/关系/设定）。更新既有实体时优先用卡片中的 [实体ID] 定位（也可用 primary_name 按名定位）。写改用 update_facts。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': '实体名或别名（精确优先）'},
        'query': {'type': 'string', 'description': '关键词（全文检索）'},
      },
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final name = arguments['name']?.toString().trim() ?? '';
    final query = arguments['query']?.toString().trim() ?? '';
    if (name.isEmpty && query.isEmpty) {
      return AgentToolResult.failure(
        title: '缺少查询条件',
        output: '请提供 name（按名查）或 query（按关键词查）至少一个。',
      );
    }

    // 词元：query 与 name 一起切分（多词/标点/短词统一处理）。
    // 精确名仍用原始串查主名/别名——归一化只作用于关键词通道。
    final terms = MemoryQuery.tokenizeAll([query, name]);

    // ① 精确名/别名（主表直查，最快且最准）
    var entities = name.isEmpty
        ? <FactualEntity>[]
        : await _deps.factualRepository.findByName(_deps.sessionId, [name]);

    // ② 世界书词条 FTS（ranked；短词走 LIKE）
    if (entities.isEmpty && terms.isNotEmpty) {
      entities = await _deps.factualRepository.searchWorldFacts(
        _deps.sessionId,
        terms,
        limit: 10,
      );
    }

    // ③ 主表子串兜底——覆盖 auto/card/手动实体与属性值。
    // 2026-09-09 审查：此前关键词通道只查 factual_fts（世界书专用索引），
    // 库里看得见的 AI 建档实体永远搜不到，模型因此每轮重复建档。
    if (entities.isEmpty && terms.isNotEmpty) {
      entities = await _deps.factualRepository.searchEntitiesByText(
        _deps.sessionId,
        terms,
      );
    }

    if (entities.isEmpty) {
      // 局部变量 name（查询参数）遮蔽工具名 getter，用 this.name 消歧
      _deps.draft.calledTools.add(this.name);
      final term = name.isNotEmpty ? name : query;
      // ④ 归档探测：命中归档实体时明说，避免"看得见却搜不到"的静默
      final archivedProbe = terms.isEmpty
          ? const <FactualEntity>[]
          : await _deps.factualRepository.searchEntitiesByText(
              _deps.sessionId,
              terms,
              limit: 5,
              includeArchived: true,
            );
      final archived = archivedProbe.where((e) => e.isArchived).toList();
      if (archived.isNotEmpty) {
        final lines = <String>['匹配的实体均已归档（可能被归并过）：'];
        for (final e in archived) {
          lines.add(
            '◆ [${e.entityId}] ${e.primaryName}（已归档｜重要度${e.importance}）',
          );
        }
        lines.add('如需继续使用，请在记忆库把它恢复为活跃，或按新名/别名重查。');
        return AgentToolResult.success(
          title: '「$term」· 已归档',
          output: lines.join('\n'),
          metadata: {'count': 0, 'archivedCount': archived.length},
          outputSchema: kOutputSchema,
        );
      }
      return AgentToolResult.success(
        title: term.isEmpty ? '未命中' : '「$term」· 未命中',
        output: '没有找到匹配的实体（已检索：主名、别名、属性值；关键词已按词拆分）。\n'
            '注意：本轮 update_facts 新建的实体要等落幕提交后才可检索。\n'
            '若确属新出现的事物，可在 update_facts 中用 create_entity 创建；若可能是既有实体的别称，请先核对相似名并用 add_alias/merge_entities 归并，不要重复建档。',
        metadata: {'count': 0},
        outputSchema: kOutputSchema,
      );
    }

    final entityIds = entities.map((e) => e.entityId).toList();
    final attributes = await _deps.factualRepository.getAttributes(
      _deps.sessionId,
      entityIds,
    );

    final lines = <String>['共 ${entities.length} 个实体：'];
    for (final e in entities) {
      final entityAttrs = attributes
          .where((a) => a.entityId == e.entityId)
          .toList()
        ..sort((a, b) => b.importance.compareTo(a.importance));
      // [实体ID] 与故事模式 {{known_entities}} 的 [ent_xxx] 格式一致，
      // 供模型在 update_facts 中用 entity_id 精确定位
      lines.add(
        '◆ [${e.entityId}] ${e.primaryName}（${e.type.name}｜重要度${e.importance}${e.source.name != 'auto' ? '｜来源${e.source.name}' : ''}${e.forceInject.name != 'none' ? '｜常驻' : ''}）',
      );
      for (final attr in entityAttrs.take(8)) {
        // 值经消毒后由导入资料包裹承载（：运行时注入点同导入侧
        // 走 sanitizeUntrusted，防模型把哨兵标签写回事实层再注入）
        lines.add(
          '  · ${attr.attrKey}: '
          '${wrapImportedData(sanitizeUntrusted(attr.value))}',
        );
      }
      if (e.aliases.isNotEmpty) {
        lines.add('  · 别名: ${e.aliases.join("、")}');
      }

      _deps.draft.retrievedFacts.add(
        RetrievedFact(
          entity: e,
          attributes: entityAttrs,
          isKeyEntity: e.isKeyEntity,
          isKeywordMatched: true,
        ),
      );
    }

    _deps.draft.calledTools.add(this.name);
    return AgentToolResult.success(
      title: '${entities.length} 张设定卡',
      output: lines.join('\n'),
      metadata: {'count': entities.length},
      outputSchema: kOutputSchema,
    );
  }
}

// ==================== 只读：read_compact_summary ====================

class ReadCompactSummaryTool implements AgentTool {
  ReadCompactSummaryTool(this._deps);

  /// 成功回执的输出结构声明
  static const Map<String, String> kOutputSchema = {'macroCount': 'int'};

  final AgentToolDeps _deps;

  @override
  String get name => 'read_compact_summary';

  @override
  String get description =>
      '读取故事最新概览：剧情主线宏摘要 + 当前叙事时间。适合开场 grounding 或不确定主线时使用。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final macros = await _deps.latestMacros();

    if (macros.isEmpty) {
      _deps.draft.calledTools.add(name);
      return AgentToolResult.success(
        title: '故事刚起步',
        output: '故事刚起步，还没有剧情主线摘要。',
        metadata: {'macroCount': 0},
        outputSchema: kOutputSchema,
      );
    }

    final lines = <String>['【剧情主线（宏摘要，最新在前）】'];
    for (final macro in macros.take(3)) {
      lines.add('· [第${macro.turnNumber}轮] ${macro.summary}');
    }

    _deps.draft.calledTools.add(name);
    return AgentToolResult.success(
      title: '主线与近况',
      output: lines.join('\n'),
      metadata: {'macroCount': macros.length},
      outputSchema: kOutputSchema,
    );
  }
}

// ==================== 写入：update_facts ====================

class UpdateFactsTool implements AgentTool {
  UpdateFactsTool(this._deps);

  final AgentToolDeps _deps;

  /// 成功回执的输出结构声明（管线 post-execute 校验）
  static const Map<String, String> kOutputSchema = {
    'accepted': 'int',
    'rejected': 'int',
    'duplicates': 'int',
  };

  /// 同参提交计数（幂等回执；key = delta 序列化，值 = 已见次数）。
  /// 实例级（一轮一实例），首次调用时从 draft 既有暂存初始化。
  final Map<String, int> _submissionCounts = {};
  bool _submissionCountsInitialized = false;

  @override
  String get name => 'update_facts';

  @override
  String get description =>
      '写入/更新事实层（人物状态、关系、设定等）。动作：create_entity / update_attr / append_list / remove_from_list / add_alias / archive_entity。新实体首次出现时，create_entity 应同时带 attr_key+value 初始化属性（一个属性，多属性可再补 update_attr）；已知实体缺关键属性（性格/背景/描述）时主动补齐。更新既有实体优先用 query_facts 卡片的 [实体ID] 定位，缺省时 primary_name 按名定位亦可。变更先暂存，finish_round 时统一提交；导入实体（世界书/角色卡，卡片中标注来源）的基线内容只读：对其 update_attr 会作为演变并存、可新增属性与别名、主名不可改（将转别名）、可 archive；基线原文永不被覆盖。属性更新是合并不是覆盖：新值必须同时包含旧值已有要点与本次新增，不得丢失旧信息。暂存有误时的补救通道：clear_pending=true 清空本轮全部暂存变更（此参数可不带 deltas）；replace_pending=true 清空后以本次 deltas 重新暂存（如归并保留者选错时重设）。';

  @override
  AgentToolPermission get permission => AgentToolPermission.write;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'deltas': {
          'type': 'array',
          'description': '变更列表',
          'items': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': [
                  'create_entity',
                  'update_attr',
                  'append_list',
                  'remove_from_list',
                  'add_alias',
                  'archive_entity',
                ],
              },
              'confidence': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 5,
                'description': '置信度 1-5',
              },
              'entity_id': {
                'type': 'string',
                'description':
                    '目标实体 ID（query_facts 卡片的 [ent_xxx]）。create_entity 不用；缺省时可用 primary_name 按名定位',
              },
              'entity_type': {
                'type': 'string',
                'enum': [
                  'character',
                  'location',
                  'item',
                  'lore',
                  'organization',
                  'misc',
                ],
              },
              'primary_name': {'type': 'string'},
              'attr_key': {
                'type': 'string',
                'description': '属性键。update/append/remove 时必填；create_entity 时建议携带 '
                    '（创建实体的同时初始化属性，如 description=描述）。各类型预定义键：\n'
                    'character: name/personality/background/relationships/skills '
                    '（另支持 gender/age/species 等自定义键）\n'
                    'location: name/description/features\n'
                    'item: name/description/owner\n'
                    'lore: name/description/category\n'
                    'organization: name/description/leader/members/background\n'
                    'misc: name/description/category\n'
                    '注：character 用 description 描述背景时系统自动映射到 background。',
              },
              'value': {
                'type': 'string',
                'description':
                    '属性值/别名/归档原因。覆盖描述性（single）属性时，新值必须包含旧值的有用信息（合并而非替换），禁止丢弃原有经历/细节。',
              },
              'reason': {'type': 'string', 'description': '变更理由'},
              'importance': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 5,
                'description': '重要度 1-5，评"今后出场可能性"，默认 2，宁低勿高（身份地位高不等于重要性高）',
              },
            },
            'required': ['action', 'confidence'],
          },
        },
        // 暂存补救通道参数
        'clear_pending': {
          'type': 'boolean',
          'description':
              '补救通道：清空本轮全部暂存变更（含此前 update_facts/merge_entities 暂存的）。仅清空时可省略 deltas。',
        },
        'replace_pending': {
          'type': 'boolean',
          'description':
              '补救通道：清空暂存后以本次 deltas 重新暂存（归并保留者选错等场景的重设）。必须搭配 deltas。',
        },
      },
      // deltas 不再硬性 required——clear_pending 可单独调用
      'required': <String>[],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    // 暂存补救通道——
    // clear_pending 清空本轮全部暂存 deltas（update_facts/merge_entities
    // 暂存的）；replace_pending 清空后以本次 deltas 重新暂存（重设
    // 归并保留者等错目标场景）。此前坏 delta 无撤销通道，失败信封的
    // 「请在提交前说明」对模型是死路指引。
    final clearPending = arguments['clear_pending'] == true;
    final replacePending = arguments['replace_pending'] == true;
    final rawDeltas = _decodeDeltas(arguments['deltas']);
    // 清空条数提到方法级作用域：全拒失败信封的「已清空」提示需要
    final removedCount = _deps.draft.factsDeltas.length;
    if (clearPending || replacePending) {
      _deps.draft.factsDeltas.clear();
      // 幂等计数必须随暂存一起清空。
      // 计数的前提是「该 delta 当前在暂存里」；clear 之后该前提消失，
      // 若保留计数，模型按 replace 语义重发整批修正内容时，与旧暂存
      // 等值的条目会被判「已暂存过」跳过——draft 实际已空，静默丢数据
      // 且报成功。清空后重发即正常入暂存（「第 N 次」防重只对仍在
      // 暂存中的 delta 有意义）。
      _submissionCounts.clear();
      // merge_entities 的同 source
      // 计数同为此害——清空后重归并同一 source（merge 回执与失败信封正
      // 是这么指引的）会被残留计数误报「已暂存过」，归并意图静默丢失。
      // 计数挂在 draft 上才能在这里一并清（工具实例间不互见）。
      _deps.draft.mergeRequestCounts.clear();
      _deps.draft.calledTools.add(name);
      if (!replacePending || rawDeltas == null || rawDeltas.isEmpty) {
        return AgentToolResult.success(
          title: '暂存已清空',
          output: '已清空本轮暂存的 $removedCount 条变更'
              '${replacePending ? '（replace_pending 需搭配 deltas，本次仅执行清空）' : ''}。'
              '此前的暂存不会在 finish_round 提交，可重新用 update_facts 暂存正确内容。',
          metadata: {'cleared': removedCount},
          outputSchema: kOutputSchema,
        );
      }
    }
    if (rawDeltas == null || rawDeltas.isEmpty) {
      return AgentToolResult.failure(
        title: '缺少变更',
        output: 'deltas 不能为空，且必须是变更对象的数组。',
      );
    }
    if (rawDeltas.length > 8) {
      return AgentToolResult.failure(
        title: '一次最多 8 条',
        output: '单次最多 8 条变更（当前 ${rawDeltas.length} 条）。请分批提交。',
      );
    }

    final accepted = <String>[];
    final rejected = <String>[];
    //  幂等回执：对 draft 现有暂存 deltas 做序列化等值比较，同参重复
    // 不再 add（不消耗 8 条配额与提交期去重成本），回执注明第 N 次。
    // 提交计数按工具实例（=本轮）持续累计——draft 只保留一份暂存，计数
    // 不能只看 draft，否则「第 N 次」永远停在 2。
    if (!_submissionCountsInitialized) {
      _submissionCountsInitialized = true;
      for (final existing in _deps.draft.factsDeltas) {
        final key = jsonEncode(existing.toJson());
        _submissionCounts[key] = (_submissionCounts[key] ?? 0) + 1;
      }
    }
    final duplicates = <String>[];
    // 2026-09-09 审查（FF10/防重复建档）：记录本轮新暂存的 create_entity
    // 名字，暂存后做一次相似名核对并在回执中列出候选。
    final newCreateNames = <String>[];
    // 导入实体主名转换提示行——update_attr name 命中
    // 预检时 delta 照常暂存，仅在接受回执追加提示（非 rejected）。
    final importedNameHints = <String>[];
    for (var i = 0; i < rawDeltas.length; i++) {
      final parsed = AgentFactsDeltaInput.fromRaw(rawDeltas[i]);
      final input = parsed.input;
      if (input == null) {
        rejected.add('第 ${i + 1} 条：${parsed.error}');
        continue;
      }
      final delta = input.toFactsDelta();
      if (delta == null) {
        // fromRaw 已覆盖全部校验分支，这里只是防御兜底
        rejected.add('第 ${i + 1} 条：格式无效');
        continue;
      }
      final key = jsonEncode(delta.toJson());
      final seen = _submissionCounts[key] ?? 0;
      if (seen > 0) {
        _submissionCounts[key] = seen + 1;
        duplicates.add(
          '${i + 1}. ${delta.action.name} → '
          '${delta.primaryName ?? delta.entityId ?? '?'}'
          '${delta.attrKey != null ? '.${delta.attrKey}' : ''}'
          '：该操作已暂存过（第 ${seen + 1} 次），本轮提交时自动去重，未重复占用配额',
        );
        continue;
      }
      // 导入实体（source != auto）暂存期预检——与
      // FactApplier 提交期守卫同口径，提前给模型回执。
      // 拒绝走既有 rejected 逐条通道（不进暂存、不计幂等）；主名转换只加
      // 提示行，delta 照常暂存。
      final precheckReject = await _precheckImportedEntityDelta(
        delta,
        i + 1,
        importedNameHints,
      );
      if (precheckReject != null) {
        rejected.add(precheckReject);
        continue;
      }
      _submissionCounts[key] = 1;
      _deps.draft.factsDeltas.add(delta);
      if (delta.action == FactAction.createEntity &&
          delta.primaryName != null) {
        newCreateNames.add(delta.primaryName!);
      }
      accepted.add(
        '${i + 1}. ${delta.action.name} → ${delta.primaryName ?? delta.entityId ?? '?'}${delta.attrKey != null ? '.${delta.attrKey}' : ''}${delta.value != null ? ' = ${delta.value}' : ''}',
      );
    }

    // 全部被拒且无重复 → 真·全部无效（失败信封）；仅重复 → 成功回执
    //（重复不是错误，是幂等命中）
    if (accepted.isEmpty && duplicates.isEmpty) {
      // replace_pending 先清后验，全拒时
      // 旧暂存已被清空——不告知则模型以为正确内容仍在暂存，finish_round
      // 会静默空提交。
      final clearedNotice = (clearPending || replacePending) && removedCount > 0
          ? '\n注意：本次调用已先清空此前的 $removedCount 条暂存，且新内容全部被拒——当前暂存为空，本轮 finish_round 将不提交任何事实变更。'
          : '';
      return AgentToolResult.failure(
        title: '变更全部无效',
        output: '全部变更被拒绝，逐条原因：\n${rejected.join('\n')}\n'
            '要求：action 为六种之一、confidence 为 1-5、entity_id 或 '
            'primary_name 至少一个；字段名用小写蛇形（entity_id/primary_name/attr_key）。'
            '$clearedNotice',
      );
    }

    final buffer = StringBuffer(
      accepted.isEmpty
          ? '本次 ${duplicates.length} 条全部为重复暂存，未新增变更：\n'
          : '已暂存 ${accepted.length} 条变更'
              '${rejected.isNotEmpty ? '（${rejected.length} 条无效被忽略：${rejected.join('；')}）' : ''}'
              '${duplicates.isNotEmpty ? '（${duplicates.length} 条重复被跳过）' : ''}：\n',
    )..writeAll(accepted, '\n');
    if (duplicates.isNotEmpty) {
      if (accepted.isNotEmpty) buffer.write('\n');
      buffer.writeAll(duplicates, '\n');
    }
    // 主名转换提示行（与 accepted 行同用 1-based 序号，按「第 N 条」
    // 对应）；命中即有 accepted 行，前置换行总有效
    if (importedNameHints.isNotEmpty) {
      buffer.write('\n${importedNameHints.join('\n')}');
    }

    // 相似名核对（包含关系，只提示不自动归并）：把"查询未命中→每轮新建"
    // 造成的近重复实体在提交前暴露给模型。
    var similarHints = 0;
    if (newCreateNames.isNotEmpty) {
      final candidates = await FactContextBuilder(
        repository: _deps.factualRepository,
      ).findSimilarNameCandidates(_deps.sessionId, newCreateNames);
      if (candidates.isNotEmpty) {
        similarHints = candidates.length;
        buffer.write('\n\n注意：新建的名字与既有实体名称相近，请核对是否同一对象：');
        for (final candidate in candidates) {
          buffer.write(
            '\n· 「${candidate.newName}」≈ 既有 '
            '${candidate.displayNames.join('、')}——若为同一对象，请改用 '
            'add_alias（并入既有实体）或 merge_entities，不要重复建档。',
          );
        }
      }
    }

    buffer.write('\n变更将在 finish_round 提交时统一生效。');

    // 成功路径登记 calledTools—— 升级闸门据此判「本轮用过记忆工具」
    _deps.draft.calledTools.add(name);
    return AgentToolResult.success(
      title: accepted.isEmpty
          ? '${duplicates.length} 条重复暂存'
          : '${accepted.length} 处修订',
      output: buffer.toString(),
      metadata: {
        'accepted': accepted.length,
        'rejected': rejected.length,
        'duplicates': duplicates.length,
        'similarHints': similarHints,
      },
      outputSchema: kOutputSchema,
    );
  }

  /// 导入实体（source != auto）暂存期预检：与 FactApplier 提交期守卫同口径
  ///提前给模型回执。
  ///
  /// - update_attr 且规范化 attrKey == 'name'：提交期转 add_alias
  ///   ——不拒，delta 照常
  ///   暂存，向 [nameHints] 追加提示行。
  /// - remove_from_list 且该 attrKey 在实体上的属性行非空且全部只读
  ///   （无 auto 行）：提交期必然被跳过（FactApplier.
  ///   _applyRemoveFromList）——直接拒，返回拒因。
  /// - 其余动作放行不加提示（提交期语义已正确且无需模型干预）。
  ///
  /// 目标实体查不到（entity_id 无效 / primary_name 未命中）→ 返回 null
  /// 不做预检，走既有路径（提交期仍有完整守卫）。
  Future<String?> _precheckImportedEntityDelta(
    FactsDelta delta,
    int index,
    List<String> nameHints,
  ) async {
    final attrKey = delta.attrKey;
    if (attrKey == null) return null;
    final isNameUpdate = delta.action == FactAction.updateAttr;
    final isListRemove = delta.action == FactAction.removeFromList;
    if (!isNameUpdate && !isListRemove) return null;

    // 定位目标实体：entity_id 精查优先，缺省按 primary_name 取首条
    FactualEntity? entity;
    final entityId = delta.entityId;
    if (entityId != null && entityId.isNotEmpty) {
      entity = await _deps.factualRepository.getEntityById(entityId);
    } else {
      final name = delta.primaryName;
      if (name != null && name.isNotEmpty) {
        final matches = await _deps.factualRepository.findByName(
          _deps.sessionId,
          [name],
        );
        if (matches.isNotEmpty) entity = matches.first;
      }
    }
    if (entity == null || entity.source == FactualSource.auto) return null;

    // attrKey 规范化复用提交期同一函数（兼容 description→background 等）
    final normalized = AttributeSchema.normalizeAttrKey(entity.type, attrKey);
    if (isNameUpdate) {
      // 导入实体主名不可改——提交期转别名，暂存期不拒、加提示行
      if (normalized == 'name') {
        nameHints.add('第 $index 条：导入实体主名不可改，提交时将以别名记录');
      }
      return null;
    }
    final rows = await _deps.factualRepository.getAttributesByKey(
      entity.entityId,
      normalized,
    );
    if (rows.isNotEmpty && rows.every((r) => r.source != FactualSource.auto)) {
      // 拒因用模型原始 attrKey（与输入对应；规范化键仅用于行查询）
      return '第 $index 条：「${entity.primaryName}」的 $attrKey '
          '为导入基线，不可移除；如需剧情变化请用 update_attr 补演变';
    }
    return null;
  }
}

/// deltas 容错解码：部分弱模型会把整个数组序列化成 JSON 字符串
List<dynamic>? _decodeDeltas(Object? raw) {
  if (raw is List) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } on FormatException {
      // 落到 null：走「缺少变更」信封
    }
  }
  return null;
}

// ==================== 写入：merge_entities ====================

/// 实体归并工具：把重复建档的 source 实体并入 target 后归档。
///
/// 设计原则：不新增 FactsDelta 原子动作——归并被拆解为既有标准动作的组合
/// （add_alias / update_attr / append_list / archive_entity）暂存进
/// draft.factsDeltas，完整复用 FactApplier 的只读基线守卫（属性级：基线
/// 不覆盖、更新转演变，世界书/角色卡同规）、schema 白名单与
/// deleteFactsByTurns 的审计逆放回滚，取消/失败不留残 state。
/// 机械部分由本工具代劳（别名去重并入、缺失属性整体搬迁、list 补差集）；
/// 同键单值冲突不自动搬迁，在结果中列出交模型决策。
class MergeEntitiesTool implements AgentTool {
  MergeEntitiesTool(this._deps);

  final AgentToolDeps _deps;

  /// 暂存 delta 总量上限（别名多/列表长的极端实体防御性截断）
  static const _maxStagedDeltas = 50;

  /// 成功回执的输出结构声明（管线 post-execute 校验）
  static const Map<String, String> kOutputSchema = {
    'staged': 'int',
    'aliases': 'int',
    'movedAttrs': 'int',
    'conflicts': 'int',
  };

  /// 同 source 归并请求计数（幂等回执）——真身在
  /// [AgentRoundDraft.mergeRequestCounts]（draft 级=本轮），update_facts
  /// 清空暂存时随之重置；此处仅转发读写。
  Map<String, int> get _mergeRequests => _deps.draft.mergeRequestCounts;

  @override
  String get name => 'merge_entities';

  @override
  String get description =>
      '把重复实体归并为一个：将 source 的主名/别名并入 target 别名、source 有而 target 无的属性搬迁过去，最后归档 source。 '
      '用于同一实体以不同名称重复建档（如"庄园"与"边境庄园"）。先用 query_facts 核对两侧确为同一实体，再用卡片 [实体ID] 定位。 '
      '同键属性值冲突时不会自动搬迁，会在结果中列出，由你决定是否用 update_facts 手工合并。 '
      '世界书/角色卡实体不可作为 source 被吸收（只读基线）；世界书不可作为 target，角色卡可作为保留者继续演化。变更先暂存，finish_round 时统一提交，可随轮回滚。';

  @override
  AgentToolPermission get permission => AgentToolPermission.write;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'source_entity_id': {
          'type': 'string',
          'description': '要被并入并归档的实体 ID（query_facts 卡片的 [ent_xxx]）',
        },
        'source_name': {
          'type': 'string',
          'description': '源实体名（entity_id 缺省时按名定位）',
        },
        'target_entity_id': {
          'type': 'string',
          'description': '保留的规范实体 ID',
        },
        'target_name': {
          'type': 'string',
          'description': '保留的规范实体名（entity_id 缺省时按名定位）',
        },
        'confidence': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 5,
          'description': '置信度 1-5（默认 4）',
        },
        'reason': {'type': 'string', 'description': '归并理由'},
      },
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final source = await _resolveEntity(
      _readString(arguments, 'source_entity_id'),
      _readString(arguments, 'source_name'),
    );
    final target = await _resolveEntity(
      _readString(arguments, 'target_entity_id'),
      _readString(arguments, 'target_name'),
    );
    if (source == null || target == null) {
      return AgentToolResult.failure(
        title: '找不到实体',
        output: 'source 或 target 未定位到实体'
            '${source == null ? '（source ${_readString(arguments, 'source_entity_id') ?? _readString(arguments, 'source_name') ?? '未提供'}）' : ''}'
            '${target == null ? '（target ${_readString(arguments, 'target_entity_id') ?? _readString(arguments, 'target_name') ?? '未提供'}）' : ''}。'
            '请先用 query_facts 获取 [实体ID]。',
      );
    }
    if (source.entityId == target.entityId) {
      return AgentToolResult.failure(
        title: '同一实体',
        output: 'source 与 target 是同一个实体（${target.primaryName}），无需归并。',
      );
    }
    // 只读守卫：
    // - source 拒 isReadOnly（worldbook+card）——只读基线不可被吸收归档
    //   （查看器入口按 isReadOnly 拦截，两端口径一致）
    // - target 拒 worldbook，允许 card——：
    //   只读语义 2.0 后世界书实体并非「完全冻结」（属性级只读：别名/
    //   演变行可加，查看器归并也放行只读保留者）；此处保留保守拒绝
    //   仅把拒因措辞对齐
    //   属性级只读语义，防模型据「完全冻结」错误推断 update_attr/
    //   add_alias 也不可用。
    if (source.source.isReadOnly) {
      return AgentToolResult.failure(
        title: '只读来源实体',
        output: '来源实体「${source.primaryName}」是世界书/角色卡投影，'
            '其内容为只读基线，不可被吸收归档。若它是重复建档问题，'
            '可把它作为保留者（target），反向吸收 AI 自建的重复实体。',
      );
    }
    if (target.source == FactualSource.worldbook) {
      return AgentToolResult.failure(
        title: '世界书实体只读',
        output:
            '世界书来源的实体不作为归并目标（target=${target.primaryName}）：其基线内容只读，保留者身份由导入资源承载。仍可对它用 update_attr 追加演变属性或 add_alias 补充称呼；如需整合，可把 AI 自建的重复实体作为 source 归入其他非世界书目标。',
      );
    }
    // 已归档实体拦截：归档实体不在检索与
    // 名字解析面内，搬进归档 target 的知识等于凭空蒸发；已归档 source 则
    // 无需再归并。
    if (target.isArchived) {
      return AgentToolResult.failure(
        title: '目标已归档',
        output: '目标实体「${target.primaryName}」已被归档，不再参与记忆。'
            '请先用 query_facts 另选一个活跃实体作为保留者。',
      );
    }
    if (source.isArchived) {
      return AgentToolResult.failure(
        title: '源实体已归档',
        output: '源实体「${source.primaryName}」已在早前归档，其内容已不参与'
            '记忆，无需归并。若需找回请引导用户在记忆查看器恢复。',
      );
    }

    //  幂等回执：同一 source 的归并此前已暂存（每次归并必以
    // archiveEntity(source) 收尾）——重复请求直接回执，不再生成第二批
    // deltas（同键别名/属性搬移在提交期会整体去重，预生成只耗配额）。
    // 已见次数按工具实例累计（draft 只保留一份，计数不能只看 draft）。
    final priorMerges = _deps.draft.factsDeltas
        .where(
          (d) =>
              d.action == FactAction.archiveEntity &&
              d.entityId == source.entityId,
        )
        .length;
    final seenRequests = _mergeRequests[source.entityId] ?? priorMerges;
    if (seenRequests > 0) {
      _mergeRequests[source.entityId] = seenRequests + 1;
      _deps.draft.calledTools.add(name);
      return AgentToolResult.success(
        title: '归并已暂存过',
        // 单条字面量：中文文案在拼接点无空格会触发 lint
        output: '「${source.primaryName}」的归并此前已在本轮暂存'
            '（第 ${seenRequests + 1} 次请求），finish_round 提交时自动去重，未重复暂存。若此前归并的保留者选错了，用 update_facts 的 replace_pending 重设本轮暂存（清空后重新提交正确内容），不要继续对同一实体重复归并。',
        metadata: {
          'staged': 0,
          'aliases': 0,
          'movedAttrs': 0,
          'conflicts': 0,
          'duplicateStaging': seenRequests,
        },
        outputSchema: kOutputSchema,
      );
    }
    invocation.onProgress
        ?.call('归并「${source.primaryName}」→「${target.primaryName}」');

    final reason = _readString(arguments, 'reason');
    final confidence = _normalizeOneToFive(arguments['confidence']) ?? 4;
    final attrs = await _deps.factualRepository.getAttributes(
      _deps.sessionId,
      [source.entityId, target.entityId],
    );
    final sourceRows = _effectiveRows(
      attrs.where((a) => a.entityId == source.entityId),
    );
    final targetRows = _effectiveRows(
      attrs.where((a) => a.entityId == target.entityId),
    );

    final deltas = <FactsDelta>[];
    final summaryLines = <String>[];

    // 1) 名字并入：源主名 + 别名 → target 别名（跳过与 target 主名相同者）
    // 别名余量披露——预计超出 kMaxAliasesPerEntity
    // 名字不再暂存，计数进回执（措辞用「预计」：此处检查与提交期 applier
    // 守卫之间存在同轮竞争窗口，最终以 applier 为准）。
    final existingTargetNames = {target.primaryName, ...target.aliases};
    var aliasCount = 0;
    var skippedAliases = 0;
    var projectedAliasCount = target.aliases.length;
    for (final name in [source.primaryName, ...source.aliases]) {
      if (name == target.primaryName || existingTargetNames.contains(name)) {
        continue;
      }
      if (projectedAliasCount >= FactApplier.kMaxAliasesPerEntity) {
        skippedAliases++;
        continue;
      }
      projectedAliasCount++;
      existingTargetNames.add(name);
      deltas.add(
        FactsDelta(
          action: FactAction.addAlias,
          entityId: target.entityId,
          value: name,
          confidence: confidence,
          reason: reason,
          isCuration: true,
        ),
      );
      aliasCount++;
    }
    if (aliasCount > 0) {
      summaryLines.add('别名并入 $aliasCount 条');
    }
    if (skippedAliases > 0) {
      summaryLines.add(
        '预计 $skippedAliases 个名字超出别名上限（${FactApplier.kMaxAliasesPerEntity} 条）不会并入',
      );
    }

    // 2) 属性搬迁：源有目标无 → 整体搬；同键 list → 补差集；同键单值 → 冲突
    final conflicts = <String>[];
    var movedAttrs = 0;
    for (final entry in sourceRows.entries) {
      final attr = entry.value;
      final items = attr.valueType == AttributeValueType.list
          ? _parseListItems(attr.value)
          : <String>[];
      if (!targetRows.containsKey(entry.key)) {
        if (attr.valueType == AttributeValueType.list) {
          for (final item in items) {
            deltas.add(
              FactsDelta(
                action: FactAction.appendList,
                entityId: target.entityId,
                attrKey: entry.key,
                value: item,
                confidence: confidence,
                reason: reason,
                isCuration: true,
              ),
            );
          }
        } else {
          deltas.add(
            FactsDelta(
              action: FactAction.updateAttr,
              entityId: target.entityId,
              attrKey: entry.key,
              value: attr.value,
              confidence: confidence,
              reason: reason,
              isCuration: true,
            ),
          );
        }
        movedAttrs++;
        continue;
      }
      final targetAttr = targetRows[entry.key]!;
      if (attr.valueType == AttributeValueType.list &&
          targetAttr.valueType == AttributeValueType.list) {
        final targetItems = _parseListItems(targetAttr.value);
        var appended = 0;
        for (final item in items) {
          if (targetItems.contains(item)) continue;
          deltas.add(
            FactsDelta(
              action: FactAction.appendList,
              entityId: target.entityId,
              attrKey: entry.key,
              value: item,
              confidence: confidence,
              reason: reason,
              isCuration: true,
            ),
          );
          appended++;
        }
        if (appended > 0) {
          summaryLines.add('${entry.key} 补充 $appended 条列表项');
        }
        continue;
      }
      conflicts.add(
        '${entry.key}：保留「${targetAttr.value}」，未搬迁源值「${attr.value}」',
      );
    }
    if (movedAttrs > 0) {
      summaryLines.add('属性搬迁 $movedAttrs 项');
    }

    // 3) 归档 source（可逆；deleteFactsByTurns 回滚时会 unarchive）
    deltas.add(
      FactsDelta(
        action: FactAction.archiveEntity,
        entityId: source.entityId,
        value: reason,
        confidence: confidence,
        reason: reason,
        isCuration: true,
      ),
    );

    if (deltas.length > _maxStagedDeltas) {
      return AgentToolResult.failure(
        title: '归并项过多',
        output: '本次归并将产生 ${deltas.length} 条变更，超过单次上限 $_maxStagedDeltas。 '
            '请改用 update_facts 分批手工合并关键属性后再归档。',
      );
    }

    _deps.draft.factsDeltas.addAll(deltas);
    _deps.draft.calledTools.add(name);
    // 审查收官 ：请求计数在暂存成功后才写入——此前放在守卫后、
    // _maxStagedDeltas 检查前，超限失败/属性查询异常路径会污染计数，
    // 模型按失败信封指引补完作业后的合法归并被误报「已暂存过」，
    // source 永不归档（意图静默丢失）
    _mergeRequests[source.entityId] = 1;

    final buffer = StringBuffer(
      '已暂存「${source.primaryName}」→「${target.primaryName}」的归并（${deltas.length} 条变更， '
      'finish_round 提交时生效）：',
    );
    if (summaryLines.isNotEmpty) {
      buffer.write('\n${summaryLines.join('；')}');
    }
    if (conflicts.isNotEmpty) {
      buffer
        ..write('\n以下同名属性值存在冲突，未自动搬迁，请自行决策：')
        ..writeAll(conflicts.map((c) => '\n- $c'));
    } else if (summaryLines.isEmpty) {
      buffer.write('\n源实体无可搬迁内容，仅并入名字并归档。');
    }

    return AgentToolResult.success(
      title: '归并「${source.primaryName}」→「${target.primaryName}」',
      output: buffer.toString(),
      metadata: {
        'staged': deltas.length,
        'aliases': aliasCount,
        'skippedAliases': skippedAliases,
        'movedAttrs': movedAttrs,
        'conflicts': conflicts.length,
      },
      outputSchema: kOutputSchema,
    );
  }

  Future<FactualEntity?> _resolveEntity(String? id, String? name) async {
    if (id != null && id.isNotEmpty) {
      final byId = await _deps.factualRepository.getEntityById(id);
      if (byId != null) return byId;
    }
    if (name != null && name.isNotEmpty) {
      final matches = await _deps.factualRepository.findByName(
        _deps.sessionId,
        [name],
      );
      if (matches.isNotEmpty) return matches.first;
    }
    return null;
  }

  String? _readString(Map<String, dynamic> raw, String key) {
    final value = raw[key];
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 每个属性键取"生效行"：auto 行优先（可演化事实），否则取首行（基线）
  Map<String, FactualAttribute> _effectiveRows(
    Iterable<FactualAttribute> rows,
  ) {
    final result = <String, FactualAttribute>{};
    for (final row in rows) {
      final existing = result[row.attrKey];
      if (existing == null ||
          (row.source == FactualSource.auto &&
              existing.source != FactualSource.auto)) {
        result[row.attrKey] = row;
      }
    }
    return result;
  }

  /// list 属性值的 JSON 数组解析；解析失败按单项处理
  List<String> _parseListItems(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } on FormatException {
      // 落到下方单项兜底
    }
    return value.isEmpty ? const [] : [value];
  }
}

// ==================== 写入：record_event_memory ====================

class RecordEventMemoryTool implements AgentTool {
  RecordEventMemoryTool(this._deps);

  /// 成功回执的输出结构声明
  static const Map<String, String> kOutputSchema = {'importance': 'int'};

  final AgentToolDeps _deps;

  @override
  String get name => 'record_event_memory';

  @override
  String get description =>
      '记录本轮事件记忆（5W1E：何时/何地/谁/发生了什么/意义）。每轮只记一条最重要的关键事件，细节留给事实层；没有值得记录的事件可以不调用。';

  @override
  AgentToolPermission get permission => AgentToolPermission.write;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'what': {'type': 'string', 'description': '发生了什么（一句话）'},
        'who': {'type': 'string', 'description': '涉及人物'},
        'when': {
          'type': 'string',
          'description': '事件发生时的故事内时间（如"三天后的深夜"）。'
              '当前叙事时间锚点由 update_story_anchor 统一维护，此处不必填写',
        },
        'where': {'type': 'string', 'description': '地点'},
        'significance': {'type': 'string', 'description': '此事的意义/影响'},
        'importance': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 5,
          'description': '重要度 1-5（≥4 会被重点索引）',
        },
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '标签（字符串数组，如 ["伏笔","决裂"]）；即使只有一个标签也用数组，不要传逗号分隔的字符串',
        },
      },
      'required': ['what', 'importance'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final what = _readText(arguments['what']);
    if (what.isEmpty) {
      return AgentToolResult.failure(
        title: '参数不对',
        output: 'what 不能为空。',
      );
    }
    // 安全解析（此前 `as num?` 遇字符串直接抛类型错误）
    final importance = parseIntegerArg(arguments, 'importance', min: 1, max: 5);
    if (importance.error != null) {
      return AgentToolResult.failure(
        title: '参数不对',
        output: '${importance.error}',
      );
    }

    // 长轮里二次调用直接覆盖首次记录，此前无任何提示——先记事件 A
    // 再补记 B 时 A 无声丢失。覆盖时明示被替换内容，交模型自行取舍。
    final previous = _deps.draft.eventSummary;
    final replacedNote =
        previous == null ? '' : '（已替换此前记录的「${previous.what}」，如两条都重要请合并为一条记录）';

    _deps.draft.eventSummary = EventSummary(
      importance: importance.value!,
      // 弱模型容错：tags 可能被写成逗号分隔字符串或 JSON 数组字符串，
      // 此前 `as List<dynamic>?` 会直接抛类型错误、整次调用失败。
      tags: parseStringListArg(arguments, 'tags'),
      turnNumber: _deps.draft.turnNumber,
      when: _readOptionalText(arguments['when']),
      where: _readOptionalText(arguments['where']),
      who: _readOptionalText(arguments['who']),
      what: what,
      significance: _readOptionalText(arguments['significance']),
    );

    // 成功路径登记 calledTools（升级闸门判据）
    _deps.draft.calledTools.add(name);
    return AgentToolResult.success(
      title: '已记 1 件事',
      output:
          '已记录本轮关键事件：「$what」（重要度 ${importance.value}）$replacedNote。finish_round 提交时生效。',
      metadata: {'importance': importance.value},
      outputSchema: kOutputSchema,
    );
  }

  /// 文本参数容错：数组按顿号合并，统一去空白
  static String _readText(Object? value) {
    if (value == null) return '';
    if (value is List) {
      return value
          .map((item) => item?.toString().trim() ?? '')
          .where((text) => text.isNotEmpty)
          .join('、');
    }
    return value.toString().trim();
  }

  static String? _readOptionalText(Object? value) {
    final text = _readText(value);
    return text.isEmpty ? null : text;
  }
}

// ==================== 写入：update_story_anchor（体验重构卡片 C）====================

/// 剧情锚维护工具：当前弧线/伏笔清单/叙事时间/一句主线进展。
///
/// 长线伏笔与当前弧线的"将来时"载体（core blocks 只覆盖现在时）。
/// 部分更新语义：未提供的字段保留旧值；伏笔传全量清单（新埋设的加入、
/// 已兑现的置 resolved=true）。有实质变化才调用，不是每轮例行更新。
class UpdateStoryAnchorTool implements AgentTool {
  UpdateStoryAnchorTool(this._deps);

  /// 成功回执的输出结构声明
  static const Map<String, String> kOutputSchema = {
    'foreshadows': 'int',
    'openForeshadows': 'int',
  };

  final AgentToolDeps _deps;

  @override
  String get name => 'update_story_anchor';

  @override
  String get description => '更新剧情锚（当前弧线/伏笔清单/叙事时间/一句主线进展）。伏笔埋设、兑现、'
      '新弧线开启或时间跳跃时调用；传 foreshadows 时给全量清单（已兑现的置 '
      'resolved=true）。没有实质变化不要调用。';

  @override
  AgentToolPermission get permission => AgentToolPermission.write;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'arc': {'type': 'string', 'description': '当前弧线（一段主线张力）'},
        'one_liner': {'type': 'string', 'description': '一句主线进展'},
        'narrative_time': {'type': 'string', 'description': '叙事时间锚点'},
        'foreshadows': {
          'type': 'array',
          'description': '伏笔全量清单（传则整体替换）',
          'items': {
            'type': 'object',
            'properties': {
              'text': {'type': 'string', 'description': '伏笔内容'},
              'resolved': {'type': 'boolean', 'description': '是否已兑现'},
            },
            'required': ['text'],
          },
        },
      },
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final arc = arguments['arc']?.toString();
    final oneLiner = arguments['one_liner']?.toString();
    final narrativeTime = arguments['narrative_time']?.toString();
    final rawForeshadows = arguments['foreshadows'] as List<dynamic>?;

    final foreshadows = rawForeshadows
        ?.whereType<Map<dynamic, dynamic>>()
        .map(
          (f) => AnchorForeshadow(
            text: f['text']?.toString() ?? '',
            resolved: f['resolved'] == true,
          ),
        )
        .where((f) => f.text.isNotEmpty)
        .toList();

    final current = _deps.draft.storyAnchor ?? _deps.currentAnchor?.call();
    if ((arc == null || arc.isEmpty) &&
        (oneLiner == null || oneLiner.isEmpty) &&
        (narrativeTime == null || narrativeTime.isEmpty) &&
        foreshadows == null) {
      return AgentToolResult.failure(
        title: '无实质变更',
        output: '所有字段都为空。只在伏笔埋设/兑现、新弧线、时间跳跃等实质变化时更新锚。',
      );
    }

    final updated = (current ?? const StoryAnchor(updatedTurn: 0)).copyWith(
      arc: (arc == null || arc.isEmpty) ? null : arc,
      oneLiner: (oneLiner == null || oneLiner.isEmpty) ? null : oneLiner,
      narrativeTime: (narrativeTime == null || narrativeTime.isEmpty)
          ? null
          : narrativeTime,
      foreshadows: foreshadows,
      updatedTurn: _deps.draft.turnNumber,
    );
    _deps.draft.storyAnchor = updated;

    final openCount = updated.openForeshadows.length;
    // 成功路径登记 calledTools（升级闸门判据）
    _deps.draft.calledTools.add(name);
    return AgentToolResult.success(
      title: '场记已更新 · $openCount 笔伏笔待兑现',
      output:
          '剧情锚已暂存：弧线=${updated.arc ?? '（未变）'}；伏笔 ${updated.foreshadows.length} 条（未兑现 $openCount 条）；finish_round 提交时生效。',
      metadata: {
        'foreshadows': updated.foreshadows.length,
        'openForeshadows': openCount,
      },
      outputSchema: kOutputSchema,
    );
  }
}

// ==================== 控制：ask_user ====================

class AskUserTool implements AgentTool {
  AskUserTool(this._deps);

  /// 成功回执的输出结构声明（answered 区分两分支）
  static const Map<String, String> kOutputSchema = {'answered': 'boolean'};

  final AgentToolDeps _deps;

  @override
  String get name => 'ask_user';

  @override
  String get description =>
      '向用户（导演）提问。用于关键抉择、设定确认或方向不清时。问题要具体，必要时给 options 选项。每轮最多 2 次。';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'question': {
          'type': 'string',
          'description': '要问导演的问题，写清楚抉择点与各选项的后果',
        },
        'options': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': 4,
          'description': '可选项（最多 4 个，可选）',
        },
      },
      'required': ['question'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    // 描述承诺"每轮最多 2 次"落到执行——超出直接给可行动信封
    if (_deps.draft.askUserUsed >= 2) {
      return AgentToolResult.failure(
        title: '提问次数已用完',
        output: '本轮提问次数已用完（最多 2 次）。请基于现有信息做稳妥的选择继续，不要继续提问。',
      );
    }
    final question = arguments['question']?.toString() ?? '';
    final options = (arguments['options'] as List<dynamic>? ?? const [])
        .map((o) => o.toString())
        .take(4)
        .toList();
    if (question.isEmpty) {
      return AgentToolResult.failure(
        title: '缺少问题',
        output: 'question 不能为空。',
      );
    }

    _deps.draft.askUserUsed++;
    invocation.onProgress?.call('等待导演回答…');
    final answer = await _deps.userInteraction.askUser(
      question: question,
      options: options.isEmpty ? null : options,
    );

    if (answer == null || answer.isEmpty) {
      return AgentToolResult.success(
        title: '导演未回答',
        output: '导演暂时没有回答。请基于现有信息做出稳妥的选择继续，不要等待或重复提问。',
        metadata: {'answered': false},
        outputSchema: kOutputSchema,
      );
    }

    return AgentToolResult.success(
      title: '导演答：「$answer」',
      output: '导演回答：「$answer」',
      metadata: {'answered': true},
      outputSchema: kOutputSchema,
    );
  }
}

// ==================== 控制：finish_round ====================

/// 提交本轮：正文经 prose 参数交付（正文交付契约设计 §2）
///
/// 调用与否 = 写没写正文：prose 合格即本轮已执笔，落库章节只来自 prose
/// （文本回退通道 C 除外，且带 text_fallback 留痕）。工具体守卫（§2.4）
/// 在闸门之前拦截空 prose / 截断疑似，保证空正文在提交动作上结构性不可能。
class FinishRoundTool implements AgentTool {
  FinishRoundTool(this._deps);

  /// 终局回执的输出结构声明
  static const Map<String, String> kOutputSchema = {'committed': 'boolean'};

  final AgentToolDeps _deps;

  @override
  String get name => 'finish_round';

  @override
  String get description =>
      '提交本轮：正文经 prose 参数交付——完整正文原文直接写入该参数，读者在正文卡阅读它。通过终审检查（事实出处、文风）后统一提交暂存变更并结束。回复文本另有职责：只写一两句过场播报，正文的唯一载体是 prose 参数。';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'prose': {
          'type': 'string',
          'description':
              '本轮完整正文原文。读者只阅读这里的文字：直接写入正文本身，保留原始换行与标点；代码围栏、摘要转述都会破坏阅读。',
        },
        'noEventReason': {
          'type': 'string',
          'description': '仅当终审提醒要求说明时填写：一句话说明本轮为何不记事件记忆。平时省略。',
        },
      },
      'required': ['prose'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    // ── 工具体守卫（契约 §2.4，先于闸门）：空正文结构性不可能提交 ──
    // 畸形 JSON 由 ToolCall.fromRawArgs 静默降级为空 Map，同样落进这里。
    final prose = stripCodeFences(arguments['prose']?.toString() ?? '');
    if (prose.isEmpty) {
      return AgentToolResult.failure(
        title: '正文参数缺失',
        output:
            '正文参数缺失或为空。可能原因：输出被「输出上限」截断（finish_reason=length 时推理占满预算），或参数未按协议携带完整正文。请调大输出上限后重发完整正文；若工具参数通道反复失败，直接输出完整正文文本结束本轮（系统会自动收录）。',
      );
    }
    if (invocation.finishReason == 'length' && prose.length < kProseThreshold) {
      return AgentToolResult.failure(
        title: '正文疑似被截断',
        output:
            '正文疑似被「输出上限」截断：本次仅收到 ${prose.length} 字（低于常规正文篇幅），且本轮模型输出已达长度上限。请调大「输出上限」后携带完整正文重新调用 finish_round；若参数通道反复受限，直接输出完整正文文本结束本轮（系统会自动收录）。',
      );
    }

    // prose 是 explicitReply 的唯一写入方（契约 §2.1：语义收窄）
    _deps.draft.explicitReply = prose;

    // ── 终审闸门（检查对象 = prose 参数；数据闸门代替提示词预习）──
    // 首次不满足 → 可行动 failure；draft 标记置位后二次提交放行（豁免进
    // 进度事件，供 L2 审计）。执行顺序：A 检索覆盖 → B 事件记忆 → 文风 lint。
    // 文风拒后的「定向重写一次」= 带修订再次调用本工具，参数变化天然不触发
    // doom-loop 连击。
    final retrievalHitNames = await _checkRetrievalCoverage(prose);
    if (retrievalHitNames != null) {
      if (!_deps.draft.retrievalGateUsed) {
        _deps.draft.retrievalGateUsed = true;
        return AgentToolResult.failure(
          title: '终审未过：未检索核对',
          output: '终审未过：本轮正文涉及已知角色/设定「$retrievalHitNames」，但全程未做任何检索核对。\n'
              '请先用 search_story/query_facts 核对后再提交；若这些是本轮新引入的名字，直接再次 finish_round 即可放行。',
        );
      }
      // 一次性豁免已用：放行，进度记录违规（L2 审计）
      invocation.onProgress?.call('检索覆盖豁免放行：「$retrievalHitNames」未经检索核对…');
    }

    if (_deps.draft.eventSummary == null) {
      //  零工具轮升级闸门：连续 kZeroToolEscalateAfter 轮未用记忆类
      // 工具且本轮也没用时，免费豁免升级为"说明原因（noEventReason）才能
      // 豁免"——否则忽略工具的代价≈0（R5）。本轮用过记忆工具则按非升级态
      //（现状：一次豁免放行），行为不回退。
      final escalated = _deps.zeroMemoryRoundStreak >= kZeroToolEscalateAfter &&
          !_deps.draft.calledTools.contains('update_facts') &&
          !_deps.draft.calledTools.contains('record_event_memory');
      final reason = arguments['noEventReason']?.toString().trim() ?? '';
      if (escalated) {
        if (reason.isEmpty) {
          return AgentToolResult.failure(
            title: '终审提醒：尚无事件记忆',
            output:
                '终审提醒：本轮尚无事件记忆，且近几轮也未曾记录。请用 record_event_memory 记一件最重要的事再提交；若本轮确无值得记录的事件，请在 finish_round 的 noEventReason 参数中用一句话说明原因后再次提交。',
          );
        }
        // reason 仅入 L2 审计（进度事件），不参与后续判定
        invocation.onProgress?.call('事件记忆豁免（原因：$reason）…');
      } else {
        if (!_deps.draft.eventMemoryGateUsed) {
          _deps.draft.eventMemoryGateUsed = true;
          return AgentToolResult.failure(
            title: '终审提醒：尚无事件记忆',
            output:
                '终审提醒：本轮尚无事件记忆。请用 record_event_memory 记一件最重要的事再提交；若本轮确无值得记录的事件，直接再次 finish_round 放行。',
          );
        }
        invocation.onProgress?.call('事件记忆豁免放行（本轮未记录事件）…');
      }
    }

    // ── 伏笔对账闸门（体验重构卡片 C 维护性补强）：清点轮且存在未兑现
    // 伏笔、本轮未动过锚时首次拦截，要求对账或确认——已兑现的划去
    //（update_story_anchor 置 resolved=true），均未兑现再次提交放行。
    // 与事件记忆闸门同构：一次性豁免防死循环；豁免进进度事件（L2 审计）。
    if (isForeshadowSweepRound(
      _deps.draft.turnNumber,
      _deps.foreshadowCheckInterval,
    )) {
      final anchor = _deps.draft.storyAnchor ?? _deps.currentAnchor?.call();
      final open = anchor?.openForeshadows ?? const [];
      if (open.isNotEmpty &&
          !_deps.draft.calledTools.contains('update_story_anchor')) {
        if (!_deps.draft.foreshadowGateUsed) {
          _deps.draft.foreshadowGateUsed = true;
          final listing = [
            for (final f in open.take(6)) '· ${sanitizeUntrusted(f.text)}',
          ].join('\n');
          return AgentToolResult.failure(
            title: '终审提醒：伏笔待清点',
            output: '终审提醒：剧情锚尚有 ${open.length} 笔未兑现伏笔，本轮未做对账：\n'
                '$listing\n'
                '若本轮正文已兑现其中之一（或发现某条早已兑现、已过时），请用 '
                'update_story_anchor 传全量清单并把已兑现条目置 resolved=true '
                '后再提交；若均未兑现，直接再次 finish_round 放行。',
          );
        }
        invocation.onProgress?.call('伏笔对账豁免放行（本轮未更新剧情锚）…');
      }
    }

    // 完稿文风 lint（体验重构  机检兜底层）：
    // 首次违规 → failure 反馈给模型定向重写一次（只改标记处）；
    // 已重写过 → 放行提交，违规记录进审计层（信封 title/output 即 L2 展示）。
    //  风格漂移监测：违规数留痕进 draft（每次 lint 覆盖，终值随
    // AgentWorkSummary 落库，供下轮漂移判定）。
    final lint = _deps.styleLint;
    if (lint != null) {
      final report = lint.lint(prose);
      _deps.draft.styleLintHits = report.violations.length;
      if (!report.isClean && !_deps.draft.styleRewriteUsed) {
        _deps.draft.styleRewriteUsed = true;
        return AgentToolResult.failure(
          title: '文风检查未过',
          output: report.buildFeedback(),
        );
      }
      if (!report.isClean) {
        // 二次仍超阈值：放行，标题记录违规数（进 L2 审计）
        invocation.onProgress?.call(
          '文风 ${report.violations.length} 处标记（放行）…',
        );
      }
    }

    invocation.onProgress?.call('提交本轮变更…');
    try {
      final persistedReply = await _deps.commitRound(_deps.draft);
      return AgentToolResult.terminal(
        title: '本轮完成',
        output:
            '本轮已完成提交。回复正文：${persistedReply.length > 60 ? '${persistedReply.substring(0, 60)}…' : persistedReply}',
        metadata: {'committed': true},
        outputSchema: kOutputSchema,
      );
    } catch (e) {
      // 提交失败（事务已回滚）：引导重试一次或直接文本收尾，不中断轮次
      return AgentToolResult.failure(
        title: '提交失败',
        output: '本轮提交失败：$e。数据已回滚。请简化变更后重试一次；若再失败，直接输出回复文本结束本轮（不再调用工具）。',
      );
    }
  }

  /// 剥离首尾 markdown 代码围栏（契约 §2.4：低风险清理，兼顾弱模型习惯；
  /// 只清首尾，正文中间的围栏原样保留）。导演侧权威替换直播块时同源使用
  static String stripCodeFences(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      // ``` 或 ```lang 开头（含换行）
      text = text.replaceFirst(RegExp(r'^```[a-zA-Z0-9_-]*[ \t]*\n?'), '');
    }
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
    return text.trim();
  }

  /// 终审闸门 A：检索覆盖判定。
  ///
  /// 返回命中的已知实体名（顿号连接，进拒绝信封）；null = 闸门不触发：
  /// 首轮（无旧设定可查）、本轮已有任一检索工具成功登记、正文与用户
  /// 输入均未命中关键实体名、或事实层查询失败（fail-open 不拦轮）。
  /// 子代理复用同一批检索工具实例，其检索同样登记进本轮（语义正确）。
  Future<String?> _checkRetrievalCoverage(String pendingText) async {
    if (_deps.draft.turnNumber <= 1) return null;
    const retrievalTools = {
      'search_story',
      'search_story_text',
      'read_story',
      'query_facts',
      'read_compact_summary',
    };
    if (_deps.draft.calledTools.any(retrievalTools.contains)) return null;

    final userInput = _deps.roundUserInput?.call() ?? '';
    List<FactualEntity> keyEntities;
    try {
      // 命中名进拒绝信封（模型可见的工具结果）——
      // 属注入面，停用词条按批 J-b 口径「不进任何注入桶」剔除（含主名/
      // 别名命中，查询级过滤）。query_facts / _resolveEntity 等检索写入
      // 面不改（停用词条仍可被检索/写入命中）。
      keyEntities = await _deps.factualRepository.getKeyEntities(
        _deps.sessionId,
        _deps.factualConfig.keyEntityImportanceThreshold,
        excludeInjectionDisabled: true,
      );
    } catch (_) {
      return null;
    }

    final hits = <String>[];
    for (final entity in keyEntities) {
      for (final candidate in [entity.primaryName, ...entity.aliases]) {
        final trimmed = candidate.trim();
        // 单字名包含匹配误报率过高（如"剑"），跳过
        if (trimmed.length < 2) continue;
        if (pendingText.contains(trimmed) || userInput.contains(trimmed)) {
          hits.add(trimmed);
          break;
        }
      }
    }
    if (hits.isEmpty) return null;
    final shown = hits.take(3).join('、');
    return hits.length > 3 ? '$shown 等' : shown;
  }
}

// ==================== 只读：read_skill（渐进披露）====================

class ReadSkillTool implements AgentTool {
  ReadSkillTool(this._deps);

  /// 成功回执的输出结构声明
  static const Map<String, String> kOutputSchema = {
    'name': 'string',
    'bodyLength': 'int',
  };

  final AgentToolDeps _deps;

  @override
  String get name => 'read_skill';

  @override
  String get description =>
      '读取一个写作技能的完整规范（渐进披露：目录里只有名字与简介）。在动笔前读与当前场景相关的技能。可用：${_deps.skillNames.isEmpty ? '（无）' : _deps.skillNames.join('、')}';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': '技能名（见技能目录）'},
      },
      'required': ['name'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final name = arguments['name']?.toString() ?? '';
    if (name.isEmpty) {
      return AgentToolResult.failure(
        title: '缺少技能名',
        output: 'name 不能为空。可用技能：${_deps.skillNames.join('、')}。',
      );
    }
    final loader = _deps.loadSkillBody;
    if (loader == null) {
      return AgentToolResult.failure(
        title: '手记未启用',
        output: '当前会话未启用技能系统。',
      );
    }
    final body = await loader(name);
    if (body == null || body.isEmpty) {
      return AgentToolResult.failure(
        title: '没有这份手记',
        output: '技能「$name」不存在。可用技能：${_deps.skillNames.join('、')}。',
      );
    }
    return AgentToolResult.success(
      title: '「$name」',
      output: body,
      metadata: {'name': name, 'bodyLength': body.length},
      outputSchema: kOutputSchema,
    );
  }
}
