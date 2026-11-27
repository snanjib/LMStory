import 'dart:convert';
import 'dart:typed_data';

import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/agent_workbench_reminder.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/text/injection_guard.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_prose_contract.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/agent_style_lint.dart';
import 'package:lmstory/features/advanced/domain/services/agent_subagent.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/advanced/domain/services/calc_agent_tools.dart';
import 'package:lmstory/features/advanced/domain/services/retrieval_evidence.dart';
import 'package:lmstory/features/advanced/domain/services/search_story_text_tool.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/data/migrations/relationship_split_migration.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_changes_snapshot.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/memory/domain/services/facts_delta_projection.dart';
import 'package:lmstory/features/memory/domain/services/memory_query.dart';
import 'package:lmstory/features/memory/domain/services/memory_retrieval_exception.dart';

/// 记录本轮已调用工具，并在维护阶段标记已完成核对或同步。
void _recordToolCall(
  AgentRoundDraft draft,
  String toolName, {
  bool countsForMaintenance = false,
}) {
  draft.calledTools.add(toolName);
  if (countsForMaintenance && draft.phase == AgentRoundPhase.maintenance) {
    draft.maintenanceCheckedOrUpdated = true;
  }
}

/// 工具集依赖包（控制器按会话组装，draft 每轮更换）
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
    this.maintenanceExtraSteps = 6,
    this.embedQueryTimeout,
    this.retrievalProfile,
    // 工程上下文模式（开启态）证据/暴露量闸门：null = 关闭态（旧闸门保留）
    this.retrievalEvidenceGate,
    this.eventExposureGate,
  });

  final String sessionId;
  final AgentRoundDraft draft;
  final FactualRepository factualRepository;
  final ExperienceRepository experienceRepository;
  final AgentStoryReader storyReader;

  /// 开启态检索证据闸门：返回 null=通过；缺口→结构化拒绝。
  final Future<EntityCoverageCheck?> Function(String prose)?
      retrievalEvidenceGate;

  /// 开启态事件记忆暴露量闸门：入参=本轮正文（暴露量输入采集
  /// 用真实本轮正文）；返回 null=放行。
  final Future<EventExposureCheck?> Function(String prose)? eventExposureGate;

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

  /// 伏笔定期清点间隔轮数（保留以兼容旧构造函数；调度现由维护缺口与大周期接管）。
  final int foreshadowCheckInterval;

  /// 大周期轮进入维护阶段时追加的独立步数配额（0 = 不追加）。
  final int maintenanceExtraSteps;

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
    this.originalReason,
    this.importance,
  });

  static const int maxBatchSize = 8;

  final String action;
  final int confidence;
  final String? entityId;
  final String? entityType;
  final String? primaryName;
  final String? attrKey;
  final String? value;
  final String? reason;
  final String? originalReason;
  final int? importance;

  FactsDelta? toFactsDelta({bool skipFrequencyGuard = false}) {
    // FactAction.fromString 对未知值抛 ArgumentError：先按已知动作白名单
    // 预检（不捕获 Error），未知动作返回 null
    const knownActions = {
      'create_entity',
      'update_attr',
      'append_list',
      'remove_from_list',
      'add_alias',
      'archive_entity',
      'set_importance',
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
      skipFrequencyGuard: skipFrequencyGuard,
    );
  }

  static List<dynamic>? decodeList(Object? raw) {
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
      return (input: null, error: 'action「${raw['action']}」不是七种合法动作之一');
    }
    if (raw['confidence'] == null) {
      return (
        input: null,
        error: '缺少必填字段 confidence（须提供 1-5 整数表示把握度/证据强度）',
      );
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
        originalReason: raw['reason']?.toString(),
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
    'set_importance': 'set_importance',
    'importance': 'set_importance',
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
    ListFactsTool(deps),
    QueryFactsTool(deps),
    QueryMemoryChangesTool(deps),
    ReadCompactSummaryTool(deps),
    CalcEvalTool(deps),
    CalcDateTool(deps),
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
    FinishMaintenanceTool(deps),
  ].where((t) => !deniedTools.contains(t.name)).toList();
}

// ==================== 只读：search_story ====================

class SearchStoryTool implements AgentTool {
  SearchStoryTool(
    this._deps, {
    Duration? embedQueryTimeout,
    this.canSearchStoryText = true,
  }) : embedQueryTimeout = embedQueryTimeout ?? _defaultEmbedTimeout;

  // ── MEM-12a 检索参数（导演现行有效参数，值零漂移锁定）──────────────
  //
  // 与故事模式配置（IntermediateConfig.retrieval / default_config.json
  // 的 intermediate.retrieval）不同是**有意差异**：导演检索参数为工具内
  // 直连定值（导演现行有效参数），不随故事模式配置联动。两模式对照表
  // 与差异说明。
  // 本批（MEM-12a）仅做命名常量提取整理，值逐字不变——零行为变化；
  // 值由 agent_session_tools_test.dart 的 MEM-12a 值锁定测试防漂移。

  /// FTS5 通道权重（故事模式 0.5）
  static const double _kFts5Weight = 0.6;

  /// 向量通道权重（故事模式 0.5）
  static const double _kVectorWeight = 0.4;

  /// 关键事件重点索引的重要度阈值（故事模式 999 = 停用）
  static const int _kKeyEventThreshold = 4;

  /// 关键事件加权倍数（故事模式 1.0 = 不加权）
  static const double _kKeyEventBoost = 1.5;

  /// 归一化平滑项（故事模式 0.01；差异说明见对照表 epsilon 节）
  static const double _kNormalizationEpsilon = 1e-6;

  /// 模型未传 top_k 且无会话松紧度快照时的内置默认
  ///（快照三档 5/8/12，见 RetrievalProfile.tiers）
  static const int _kDefaultTopK = 8;

  /// 无快照时的向量质量过滤阈值（0.0 = 不过滤；
  /// 保守档另有 0.55，见 RetrievalProfile.conservative）
  static const double _kDefaultVectorScoreThreshold = 0;

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
      fallback: _deps.retrievalProfile?.topK ?? _kDefaultTopK,
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
          fts5Weight: _kFts5Weight,
          vectorWeight: _kVectorWeight,
          keyEventThreshold: _kKeyEventThreshold,
          keyEventBoost: _kKeyEventBoost,
          normalizationEpsilon: _kNormalizationEpsilon,
          // 向量质量过滤阈值来自会话松紧度快照（null/缺省 0.0 = 不过滤）
          vectorScoreThreshold: _deps.retrievalProfile?.vectorScoreThreshold ??
              _kDefaultVectorScoreThreshold,
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
        metadata: retrievalEvidencePayload(
          status: 'error',
          queryScope: {'query': query},
        ),
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
        metadata: {
          'query': query,
          'hitCount': 0,
          ...retrievalEvidencePayload(
            status: 'empty',
            queryScope: {'query': query},
          ),
        },
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
      metadata: {
        'query': query,
        'hitCount': hits.length,
        // 文本类检索无实体面（实体级充分性由 query_facts 类证据承担）
        ...retrievalEvidencePayload(
          status: 'success',
          queryScope: {'query': query},
        ),
      },
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

// ==================== 只读：list_facts ====================

class ListFactsTool implements AgentTool {
  ListFactsTool(this._deps);

  static const int defaultLimit = 25;
  static const int maxLimit = 50;

  static const Set<String> _allowedSources = {
    'dynamic',
    'auto',
    'worldbook',
    'card',
    'all',
  };

  static const Set<String> _allowedSorts = {
    'stale_first',
    'recently_updated',
    'importance_desc',
    'created_desc',
  };

  /// 成功回执的输出结构声明
  static const Map<String, String> kOutputSchema = {
    'count': 'int',
    'totalMatched': 'int',
    'hasMore': 'boolean',
  };

  final AgentToolDeps _deps;

  @override
  String get name => 'list_facts';

  @override
  String get description => '浏览事实库实体目录（默认仅列活跃动态实体并附全库统计头；支持按类型、来源、久未校准排序与轮次分页）。'
      '每行仅展示索引概要（ID/主名/类型/重要度/来源/建改轮次/属性数/别名数），不含属性值详情；'
      '如需查细节请配合 query_facts(entity_ids=[...]) 批量读取。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
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
          'description': '按实体类型过滤（可选）',
        },
        'source': {
          'type': 'string',
          'enum': ['dynamic', 'auto', 'worldbook', 'card', 'all'],
          'description': '来源过滤：dynamic（默认，AI 自建或发生过演化的实体）/ '
              'auto / worldbook / card / all',
        },
        'sort': {
          'type': 'string',
          'enum': [
            'stale_first',
            'recently_updated',
            'importance_desc',
            'created_desc',
          ],
          'description': '排序：stale_first（默认，高重要度且久未校准优先）/ recently_updated / '
              'importance_desc / created_desc',
        },
        'updated_before_turn': {
          'type': 'integer',
          'minimum': 1,
          'description': '筛选最近活跃轮次严格小于该轮号的实体（可选）',
        },
        'updated_after_turn': {
          'type': 'integer',
          'minimum': 1,
          'description': '筛选最近活跃轮次严格大于该轮号的实体（可选）',
        },
        'include_archived': {
          'type': 'boolean',
          'description': '是否包含已归档实体（默认 false）',
        },
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': maxLimit,
          'description': '每页条数（默认 25，上限 50）',
        },
        'offset': {
          'type': 'integer',
          'minimum': 0,
          'description': '分页偏移量（默认 0）',
        },
      },
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    FactualEntityType? entityType;
    final rawType = arguments['entity_type']?.toString().trim();
    if (rawType != null && rawType.isNotEmpty) {
      entityType = FactualEntityType.tryFromString(rawType);
      if (entityType == null) {
        return AgentToolResult.failure(
          title: '参数不对',
          output: 'entity_type「$rawType」非法，可选：'
              'character / location / item / lore / organization / misc。',
        );
      }
    }

    final rawSource = arguments['source']?.toString().trim();
    final sourceFilter =
        (rawSource == null || rawSource.isEmpty) ? 'dynamic' : rawSource;
    if (!_allowedSources.contains(sourceFilter)) {
      return AgentToolResult.failure(
        title: '参数不对',
        output:
            'source「$sourceFilter」非法，可选：dynamic / auto / worldbook / card / all。',
      );
    }

    final rawSort = arguments['sort']?.toString().trim();
    final sort = (rawSort == null || rawSort.isEmpty) ? 'stale_first' : rawSort;
    if (!_allowedSorts.contains(sort)) {
      return AgentToolResult.failure(
        title: '参数不对',
        output:
            'sort「$sort」非法，可选：stale_first / recently_updated / importance_desc / created_desc。',
      );
    }

    int? updatedBeforeTurn;
    if (arguments['updated_before_turn'] != null) {
      final parsed = parseIntegerArg(arguments, 'updated_before_turn', min: 1);
      if (parsed.error != null) {
        return AgentToolResult.failure(title: '参数不对', output: parsed.error!);
      }
      updatedBeforeTurn = parsed.value;
    }

    int? updatedAfterTurn;
    if (arguments['updated_after_turn'] != null) {
      final parsed = parseIntegerArg(arguments, 'updated_after_turn', min: 1);
      if (parsed.error != null) {
        return AgentToolResult.failure(title: '参数不对', output: parsed.error!);
      }
      updatedAfterTurn = parsed.value;
    }

    final limitResult = parseIntegerArg(
      arguments,
      'limit',
      min: 1,
      max: maxLimit,
      fallback: defaultLimit,
    );
    if (limitResult.error != null) {
      return AgentToolResult.failure(title: '参数不对', output: limitResult.error!);
    }
    final offsetResult = parseIntegerArg(
      arguments,
      'offset',
      min: 0,
      fallback: 0,
    );
    if (offsetResult.error != null) {
      return AgentToolResult.failure(
        title: '参数不对',
        output: offsetResult.error!,
      );
    }

    final includeArchived = arguments['include_archived'] == true;
    final page = await _deps.factualRepository.listEntityCatalog(
      _deps.sessionId,
      entityType: entityType,
      sourceFilter: sourceFilter,
      sort: sort,
      updatedBeforeTurn: updatedBeforeTurn,
      updatedAfterTurn: updatedAfterTurn,
      includeArchived: includeArchived,
      limit: limitResult.value!,
      offset: offsetResult.value!,
    );

    _recordToolCall(_deps.draft, name, countsForMaintenance: true);

    final s = page.summary;
    final typeParts = [
      for (final type in FactualEntityType.values)
        if ((s.typeCounts[type] ?? 0) > 0) '${type.name} ${s.typeCounts[type]}',
    ];
    final lines = <String>[
      '【事实库概览】活跃 ${s.activeCount}（动态 ${s.dynamicCount}｜静态世界书 ${s.staticWorldbookCount}｜静态角色卡 ${s.staticCardCount}），已归档 ${s.archivedCount}${typeParts.isEmpty ? '' : '｜类型：${typeParts.join('、')}'}。',
    ];
    if (sourceFilter == 'dynamic') {
      lines.add(
        '当前视图：source=dynamic（活跃动态实体），sort=$sort；如需查看未演化静态设定可传 source="worldbook" / "card" / "all"。',
      );
    }
    if (page.items.isEmpty) {
      lines.add('本页无匹配实体（共 ${page.totalMatched} 条符合当前筛选）。');
    } else {
      final start = page.offset + 1;
      final end = page.offset + page.items.length;
      lines.add('本页展示 $start-$end / 共 ${page.totalMatched} 条：');
      for (final item in page.items) {
        final e = item.entity;
        final safeName = sanitizeUntrusted(e.primaryName);
        final turnInfo = e.updatedTurn != null
            ? '建T${e.createdTurn}·改T${e.updatedTurn}'
            : '建T${e.createdTurn}';
        final flags = [
          if (e.injectionDisabled) '[停用注入]',
          if (e.isArchived) '[已归档]',
        ].join();
        lines.add(
          '◆ [${e.entityId}] $safeName（${e.type.name}｜重要度${e.importance}｜来源${e.source.name}｜$turnInfo｜属性${item.attributeCount}条｜别名${item.aliasCount}个）${flags.isEmpty ? '' : ' $flags'}',
        );
      }
    }
    if (page.hasMore) {
      lines.add('还有下一页，可传 offset=${page.offset + page.items.length} 继续翻页。');
    }
    lines.add(
      '提示：本目录仅列索引不含属性详情，需要核对或修订具体内容时请用 query_facts(entity_ids=[...]) 批量读卡。',
    );

    return AgentToolResult.success(
      title: '事实目录 · ${page.items.length}/${page.totalMatched}',
      output: lines.join('\n'),
      metadata: {
        'count': page.items.length,
        'totalMatched': page.totalMatched,
        'hasMore': page.hasMore,
      },
      outputSchema: kOutputSchema,
    );
  }
}

// ==================== 只读：query_facts ====================

class QueryFactsTool implements AgentTool {
  QueryFactsTool(this._deps);

  /// 批量 ID 直查单次上限
  static const int maxBatchIds = 8;

  /// 成功回执的输出结构声明
  static const Map<String, String> kOutputSchema = {'count': 'int'};

  final AgentToolDeps _deps;

  @override
  String get name => 'query_facts';

  @override
  String get description =>
      '查询事实层（实体卡片）：支持按 entity_id / entity_ids（单次最多 8 个）批量直查，也支持按名称精查或关键词模糊查（关键词按空白/标点切分，覆盖主名、别名与属性值），返回实体 ID、类型、重要度、属性（状态/关系/设定）。更新既有实体时优先用卡片中的 [实体ID] 定位（也可用 primary_name 按名定位）。写改用 update_facts。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'entity_id': {'type': 'string', 'description': '按实体 ID 精确查询（可选）'},
        'entity_ids': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': maxBatchIds,
          'description': '按实体 ID 列表批量直查（最多 8 个，配合 list_facts 使用）',
        },
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
    final entityIdArg = arguments['entity_id']?.toString().trim() ?? '';
    final entityIdsArg = parseStringListArg(arguments, 'entity_ids');
    final requestedIds = <String>[
      if (entityIdArg.isNotEmpty) entityIdArg,
      for (final id in entityIdsArg)
        if (id.isNotEmpty && id != entityIdArg) id,
    ];
    if (requestedIds.length > maxBatchIds) {
      return AgentToolResult.failure(
        title: '批量 ID 超限',
        output:
            'entity_ids 单次最多查询 $maxBatchIds 个实体（当前 ${requestedIds.length} 个），请分批查询。',
      );
    }

    final name = arguments['name']?.toString().trim() ?? '';
    final query = arguments['query']?.toString().trim() ?? '';
    if (requestedIds.isEmpty && name.isEmpty && query.isEmpty) {
      return AgentToolResult.failure(
        title: '缺少查询条件',
        output: '请提供 entity_id、entity_ids、name 或 query 至少一个。',
      );
    }

    final queryScope = <String, dynamic>{
      if (requestedIds.isNotEmpty) 'entity_ids': requestedIds,
      if (name.isNotEmpty) 'name': name,
      if (query.isNotEmpty) 'query': query,
    };

    var entities = <FactualEntity>[];
    if (requestedIds.isNotEmpty) {
      entities = await _deps.factualRepository.getEntitiesByIds(
        _deps.sessionId,
        requestedIds,
      );
      if (entities.isEmpty) {
        _recordToolCall(_deps.draft, this.name, countsForMaintenance: true);
        return AgentToolResult.success(
          title: '未命中',
          output:
              '未找到指定实体 ID（${requestedIds.join('、')}）。请先用 list_facts 确认有效实体 ID。',
          metadata: {
            'count': 0,
            ...retrievalEvidencePayload(
              status: 'empty',
              queryScope: queryScope,
            ),
          },
          outputSchema: kOutputSchema,
        );
      }
    } else {
      // 词元：query 与 name 一起切分（多词/标点/短词统一处理）。
      // 精确名仍用原始串查主名/别名——归一化只作用于关键词通道。
      final terms = MemoryQuery.tokenizeAll([query, name]);

      // ① 精确名/别名（主表直查，最快且最准）
      entities = name.isEmpty
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
      if (entities.isEmpty && terms.isNotEmpty) {
        entities = await _deps.factualRepository.searchEntitiesByText(
          _deps.sessionId,
          terms,
        );
      }

      if (entities.isEmpty) {
        _recordToolCall(_deps.draft, this.name, countsForMaintenance: true);
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
            metadata: {
              'count': 0,
              'archivedCount': archived.length,
              ...retrievalEvidencePayload(
                status: 'empty',
                queryScope: queryScope,
              ),
            },
            outputSchema: kOutputSchema,
          );
        }
        return AgentToolResult.success(
          title: term.isEmpty ? '未命中' : '「$term」· 未命中',
          output: '没有找到匹配的实体（已检索：主名、别名、属性值；关键词已按词拆分）。\n'
              '注意：本轮 update_facts 新建的实体要等落幕提交后才可检索。\n'
              '若确属新出现的事物，可在 update_facts 中用 create_entity 创建；若可能是既有实体的别称，请先核对相似名并用 add_alias/merge_entities 归并，不要重复建档。\n'
              '注：世界书/事实检索按名称与描述字面匹配；低重要度经历细节不在本检索面，可用 search_story_text 扫描原文。',
          metadata: {
            'count': 0,
            ...retrievalEvidencePayload(
              status: 'empty',
              queryScope: queryScope,
            ),
          },
          outputSchema: kOutputSchema,
        );
      }
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
      lines.add(
        '◆ [${e.entityId}] ${e.primaryName}（${e.type.name}｜重要度${e.importance}${e.source.name != 'auto' ? '｜来源${e.source.name}' : ''}${e.forceInject.name != 'none' ? '｜常驻' : ''}${e.injectionDisabled ? '｜停用注入' : ''}${e.isArchived ? '｜已归档' : ''}）',
      );
      for (final attr in entityAttrs.take(8)) {
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

    _recordToolCall(_deps.draft, this.name, countsForMaintenance: true);
    return AgentToolResult.success(
      title: '${entities.length} 张设定卡',
      output: lines.join('\n'),
      metadata: {
        'count': entities.length,
        // 证据记录（成功查询才构成有效证据）：success + 命中实体读取时点修订快照
        ...retrievalEvidencePayload(
          status: 'success',
          queryScope: queryScope,
          entities: [
            for (final e in entities)
              EvidenceEntityRef(
                id: e.entityId,
                primaryName: e.primaryName,
                updatedAtMs: e.updatedAt?.millisecondsSinceEpoch,
                contentDigest: _entityDigest(
                  e,
                  attributes.where((a) => a.entityId == e.entityId).toList(),
                ),
              ),
          ],
        ),
      },
      outputSchema: kOutputSchema,
    );
  }
}

// ==================== 只读：query_memory_changes ====================

/// 查询当前会话仍留存的事实流水。
///
/// 事实历史没有会话列，因此先从当前会话实体联表，再读取每个实体的
/// factual_memory_history。这个边界也让回执能够明确说明经历编辑和普通手改
/// 可能没有完整流水，避免把“查空”解释成“没有发生过”。
class QueryMemoryChangesTool implements AgentTool {
  QueryMemoryChangesTool(this._deps)
      : _instanceNonce =
            '${DateTime.now().microsecondsSinceEpoch}-${_nextNonce++}';

  static int _nextNonce = 0;

  static const Map<String, String> kOutputSchema = {
    'status': 'string',
    'count': 'int',
    'hasNext': 'boolean',
  };

  final AgentToolDeps _deps;
  final String _instanceNonce;

  @override
  String get name => 'query_memory_changes';

  @override
  String get description =>
      '查询当前故事、当前选定稿件上仍留存的事实变更流水，按入账轮倒序返回。支持 entity_id/entity_name、attr_key、actions/kinds、关键词 q、from_turn/to_turn、limit 和 cursor。q 按实体名、属性键、理由和实际变更项匹配，不把旧列表的未变更成员当作命中。只覆盖已记录的事实变更，经历编辑和未留痕的普通手工变化可能没有历史。结果可用 read_story 回读正文。 Query retained factual changes for the current story and selected variant only.';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {
        'type': 'object',
        'properties': {
          'entity_id': {'type': 'string', 'description': '本故事实体 ID'},
          'entity_name': {'type': 'string', 'description': '本故事当前主名或别名'},
          'attr_key': {
            'type': 'string',
            'description': '属性键，支持 relationship:对象',
          },
          'actions': {
            'type': 'array',
            'items': {
              'type': 'string',
              'enum': [
                'create_entity',
                'update_attr',
                'append_list',
                'remove_from_list',
                'add_alias',
                'archive_entity',
                'set_importance',
              ],
            },
          },
          'kinds': {
            'type': 'array',
            'items': {
              'type': 'string',
              'enum': ['fact', 'experience'],
            },
          },
          'q': {'type': 'string', 'description': '匹配实体名、属性键、原因或实际变更项'},
          'from_turn': {'type': 'integer', 'minimum': 1},
          'to_turn': {'type': 'integer', 'minimum': 1},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 30},
          'cursor': {'type': 'string'},
        },
      };

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final entityId = _readTrimmed(arguments['entity_id']);
    final entityName = _readTrimmed(arguments['entity_name']);
    if (entityId != null && entityName != null) {
      return _invalid('entity_id 与 entity_name 不能同时使用。');
    }

    final rawFromTurn = arguments['from_turn'];
    final rawToTurn = arguments['to_turn'];
    final fromTurn = _readInt(rawFromTurn);
    final toTurn = _readInt(rawToTurn);
    if (rawFromTurn != null && fromTurn == null ||
        rawToTurn != null && toTurn == null) {
      return _invalid('from_turn 和 to_turn 必须是整数。');
    }
    if (fromTurn != null && fromTurn < 1 || toTurn != null && toTurn < 1) {
      return _invalid('from_turn 和 to_turn 必须是大于等于 1 的整数。');
    }
    if (fromTurn != null && toTurn != null && fromTurn > toTurn) {
      return _invalid('from_turn 不能大于 to_turn，轮号端点均包含。');
    }

    final limitResult = parseIntegerArg(
      arguments,
      'limit',
      min: 1,
      max: 30,
      fallback: 10,
    );
    if (limitResult.error != null) {
      return _invalid(limitResult.error!);
    }
    final actions = _readStringList(arguments['actions']);
    if (actions == null) {
      return _invalid('actions 必须是字符串数组。');
    }
    final normalizedActions = <String>{};
    for (final action in actions) {
      final normalized = _normalizeFactAction(action);
      if (normalized == null) {
        return _invalid('actions 含未知动作「$action」。');
      }
      normalizedActions.add(normalized);
    }

    final kinds = _readStringList(arguments['kinds']);
    if (kinds == null) {
      return _invalid('kinds 必须是字符串数组。');
    }
    final normalizedKinds = <String>{};
    for (final kind in kinds) {
      final normalized = kind.trim().toLowerCase();
      if (normalized != 'fact' && normalized != 'experience') {
        return _invalid('kinds 只支持 fact 或 experience。');
      }
      normalizedKinds.add(normalized);
    }
    if (normalizedKinds.length == 1 && normalizedKinds.contains('experience')) {
      _recordToolCall(_deps.draft, name, countsForMaintenance: true);
      return AgentToolResult.success(
        title: '事实变更历史不可用',
        output: '当前版本没有经历编辑的逐项变更流水，未从经历摘要推断事实变化。',
        metadata: {
          'status': 'history_unavailable',
          'count': 0,
          'hasNext': false,
          'coverage': {'fact': '可查', 'experience': '未记录逐项变更历史'},
        },
        outputSchema: kOutputSchema,
      );
    }

    final q = _readTrimmed(arguments['q']);
    final normalizedConditions = <String, dynamic>{
      'entity_id': entityId,
      'entity_name': entityName,
      'attr_key': _readTrimmed(arguments['attr_key']),
      'actions': normalizedActions.toList()..sort(),
      'kinds': normalizedKinds.toList()..sort(),
      'q': q,
      'from_turn': fromTurn,
      'to_turn': toTurn,
      'limit': limitResult.value,
    };

    try {
      final snapshot = await _deps.factualRepository.readMemoryChangesSnapshot(
        _deps.sessionId,
      );
      final entities = snapshot.entities;
      final selected = _selectEntities(entities, entityId, entityName);
      if (entityName != null && selected.length > 1) {
        _recordToolCall(_deps.draft, name, countsForMaintenance: true);
        final candidates =
            selected.map((e) => '[${e.entityId}] ${e.primaryName}').join('、');
        return AgentToolResult.success(
          title: '实体名有歧义',
          output: '「$entityName」匹配多个本故事实体，请改用 entity_id 选择一个：$candidates。',
          metadata: {
            'status': 'ambiguous_entity',
            'count': 0,
            'hasNext': false,
            'candidates': [
              for (final e in selected)
                {'entityId': e.entityId, 'primaryName': e.primaryName},
            ],
          },
          outputSchema: kOutputSchema,
        );
      }

      final attributes = snapshot.attributes;
      final attrById = <String, FactualAttribute>{
        for (final attribute in attributes) attribute.attributeId: attribute,
      };
      final entityById = <String, FactualEntity>{
        for (final entity in selected) entity.entityId: entity,
      };
      final rows = <_MemoryChangeRow>[];
      var missingAttributeCoverage = false;
      final selectedIds = {for (final entity in selected) entity.entityId};
      for (final item in snapshot.history) {
        if (!selectedIds.contains(item.entityId)) continue;
        if (item.historyId == null) continue;
        if (fromTurn != null && item.turnNumber < fromTurn) continue;
        if (toTurn != null && item.turnNumber > toTurn) continue;
        final action = item.action.toJsonString();
        if (normalizedActions.isNotEmpty &&
            !normalizedActions.contains(action)) {
          continue;
        }
        final attribute =
            item.attributeId == null ? null : attrById[item.attributeId!];
        final attrKey = attribute?.attrKey;
        final wantedAttr = normalizedConditions['attr_key'] as String?;
        if (wantedAttr != null && attrKey != wantedAttr) {
          if (item.attributeId != null && attribute == null) {
            missingAttributeCoverage = true;
          }
          continue;
        }
        final entity = entityById[item.entityId];
        if (entity == null || _isMaintenanceHistory(item)) continue;
        final row = _MemoryChangeRow(
          entity: entity,
          attribute: attribute,
          history: item,
          currentFactsChanges:
              snapshot.currentFactsChangesByTurn[item.turnNumber],
        );
        if (q != null && !row.matchesQuery(q)) continue;
        rows.add(row);
      }
      rows.sort(_compareMemoryChangeRows);

      final currentDigest = _stableDigest(
        jsonEncode({
          'conditions': normalizedConditions,
          'rows': [for (final row in rows) row.digestData],
          'story': snapshot.storyRevision,
          'variants': [
            for (final entry in snapshot.currentVariantByTurn.entries)
              [entry.key, entry.value],
          ],
        }),
      );
      final cursor = _decodeMemoryCursor(arguments['cursor']);
      if (arguments['cursor'] != null && cursor == null) {
        return _cursorStale();
      }
      if (cursor != null &&
          (cursor.sessionId != _deps.sessionId ||
              cursor.instanceNonce != _instanceNonce ||
              jsonEncode(cursor.conditions) !=
                  jsonEncode(normalizedConditions) ||
              cursor.digest != currentDigest)) {
        return _cursorStale();
      }

      var start = 0;
      if (cursor != null) {
        start = rows.indexWhere(
          (row) =>
              row.history.turnNumber == cursor.lastTurn &&
              row.history.historyId == cursor.lastHistoryId,
        );
        if (start < 0) return _cursorStale();
        start += 1;
      }
      final page = rows.skip(start).take(limitResult.value!).toList();
      final hasNext = start + page.length < rows.length;
      final nextCursor = hasNext
          ? _MemoryChangesCursor(
              sessionId: _deps.sessionId,
              conditions: normalizedConditions,
              digest: currentDigest,
              instanceNonce: _instanceNonce,
              lastTurn: page.last.history.turnNumber,
              lastHistoryId: page.last.history.historyId!,
            ).encode()
          : null;

      if (missingAttributeCoverage &&
          normalizedConditions['attr_key'] != null) {
        _recordToolCall(_deps.draft, name, countsForMaintenance: true);
        return AgentToolResult.success(
          title: '属性历史覆盖不足',
          output:
              '所查范围内存在已删除或失联的属性键，无法证明 attr_key 条件覆盖完整。请去掉 attr_key 或改查当前仍存在的属性。',
          metadata: {
            'status': 'coverage_insufficient',
            'count': 0,
            'hasNext': false,
            'coverage': _coverageMetadata(),
          },
          outputSchema: kOutputSchema,
        );
      }

      final status = rows.isEmpty ? 'no_match_in_recorded_history' : 'matched';
      _recordToolCall(_deps.draft, name, countsForMaintenance: true);
      final lines = <String>[];
      if (page.isEmpty) {
        lines.add('在所查范围内没有找到已记录的变更。');
      } else {
        for (final row in page) {
          lines.add(
            await row
                .render(snapshot.storyRoundsByTurn[row.history.turnNumber]),
          );
        }
      }
      lines
        ..add('仅覆盖当前故事已留存的事实变更。普通手工编辑、经历编辑和已删除流水可能没有完整历史。')
        ..add('查询范围限定为当前故事当前选定稿件；正文回读线索仅在本轮产物能唯一对应时提供。');
      if (nextCursor != null) lines.add('还有下一页，可使用返回的 cursor 继续查询。');
      return AgentToolResult.success(
        title: rows.isEmpty ? '未找到已记录变更' : '命中 ${page.length} 条事实变更',
        output: lines.join('\n'),
        metadata: {
          'status': status,
          'count': page.length,
          'hasNext': hasNext,
          'scope': 'current_story_current_variant',
          if (nextCursor != null) 'cursor': nextCursor,
          'coverage': _coverageMetadata(),
        },
        outputSchema: kOutputSchema,
      );
    } catch (error) {
      _deps.draft.calledTools.add(name);
      return AgentToolResult.failure(
        title: '记忆变更读取失败',
        output: '无法读取已记录的事实变更（$error）。这不代表故事中没有发生变化，请稍后重试或用 read_story 回读原文。',
        metadata: {'status': 'read_error'},
      );
    }
  }

  AgentToolResult _invalid(String output) => AgentToolResult.failure(
        title: '参数不对',
        output: output,
        metadata: {'status': 'invalid_arguments'},
      );

  AgentToolResult _cursorStale() => AgentToolResult.failure(
        title: '查询游标已失效',
        output: 'cursor 已失效，查询条件、当前稿件或已记录流水发生变化，请从第一页重新查询。',
        metadata: {'status': 'cursor_stale'},
      );

  List<FactualEntity> _selectEntities(
    List<FactualEntity> entities,
    String? entityId,
    String? entityName,
  ) {
    if (entityId != null) {
      return entities.where((entity) => entity.entityId == entityId).toList();
    }
    if (entityName != null) {
      return entities
          .where(
            (entity) =>
                entity.primaryName == entityName ||
                entity.aliases.contains(entityName),
          )
          .toList();
    }
    return entities;
  }

  Map<String, String> _coverageMetadata() => const {
        'fact': '当前会话实体联表后读取仍留存的 factual_memory_history',
        'experience': '没有逐项变更流水',
        'manual': '普通手工编辑可能缺少连续历史',
      };
}

class _MemoryChangeRow {
  _MemoryChangeRow({
    required this.entity,
    required this.attribute,
    required this.history,
    required this.currentFactsChanges,
  });

  final FactualEntity entity;
  final FactualAttribute? attribute;
  final FactualMemoryHistory history;
  final String? currentFactsChanges;

  List<Object?> get digestData => [
        history.historyId,
        history.entityId,
        history.attributeId,
        history.action.toJsonString(),
        history.oldValue,
        history.newValue,
        history.reason,
        history.turnNumber,
        history.createdAt.toIso8601String(),
        entity.primaryName,
        entity.aliases,
        attribute?.attrKey,
        currentFactsChanges,
      ];

  bool matchesQuery(String query) {
    final needle = query.toLowerCase();
    final text = <String?>[
      entity.primaryName,
      ...entity.aliases,
      attribute?.attrKey,
      history.reason,
      ..._changedValueTokens(),
    ].whereType<String>().join('\n').toLowerCase();
    return text.contains(needle);
  }

  List<String> _changedValueTokens() {
    final action = history.action.toJsonString();
    final changed = history.newValue;
    if (changed == null || changed.isEmpty) {
      return action == 'archive_entity' && history.reason != null
          ? [history.reason!]
          : const [];
    }
    if (action == 'append_list' || action == 'remove_from_list') {
      return [changed];
    }
    if (action != 'update_attr' || history.oldValue == null) {
      return [changed];
    }
    try {
      final before = jsonDecode(history.oldValue!);
      final after = jsonDecode(changed);
      if (before is Map && after is Map) {
        final keys = {...before.keys, ...after.keys};
        final tokens = <String>[];
        for (final key in keys) {
          final oldItem = before[key];
          final newItem = after[key];
          if (jsonEncode(oldItem) == jsonEncode(newItem)) continue;
          tokens.add(key.toString());
          if (oldItem != null) tokens.add(oldItem.toString());
          if (newItem != null) tokens.add(newItem.toString());
        }
        return tokens.isEmpty ? [changed] : tokens;
      }
      if (before is List && after is List) {
        final beforeByKey = <String, Object?>{
          for (final item in before) jsonEncode(item): item,
        };
        final afterByKey = <String, Object?>{
          for (final item in after) jsonEncode(item): item,
        };
        final tokens = <String>[];
        for (final key in {...beforeByKey.keys, ...afterByKey.keys}) {
          if (beforeByKey.containsKey(key) && afterByKey.containsKey(key)) {
            continue;
          }
          final item = afterByKey[key] ?? beforeByKey[key];
          tokens.addAll(_valueTokens(item));
        }
        return tokens.isEmpty ? [changed] : tokens;
      }
      if (jsonEncode(before) != jsonEncode(after)) {
        return [
          ..._valueTokens(after),
          ..._valueTokens(before),
        ];
      }
    } on FormatException {
      // 单值属性或旧格式文本，按变更后值匹配。
    }
    return [changed];
  }

  static List<String> _valueTokens(Object? value) {
    if (value is Map) {
      return [
        for (final entry in value.entries) ...[
          entry.key.toString(),
          ..._valueTokens(entry.value),
        ],
      ];
    }
    if (value is List) {
      return [for (final item in value) ..._valueTokens(item)];
    }
    return value == null ? const [] : [value.toString()];
  }

  Future<String> render(FactualMemoryStoryRound? round) async {
    final action = history.action.toJsonString();
    final attr = attribute?.attrKey ?? '属性键未知';
    final before = history.oldValue ?? '未知';
    final changed = history.newValue ?? '未知';
    final after = _computedAfter(action, history.oldValue, history.newValue);
    final lines = <String>[
      '第 ${history.turnNumber} 轮入账·流水 ${history.historyId}·${entity.primaryName}（${entity.entityId}）·$attr·$action',
      '操作前：$before；变更项/写入值：$changed${after == null ? '' : '；按流水计算随后为：$after'}',
      if (history.reason == null || history.reason!.isEmpty)
        '理由：未记录'
      else
        '理由：${history.reason}',
    ];
    if (round != null && _matchesEvidence(round)) {
      lines.add('可用 read_story({"turn":${history.turnNumber}}) 核对正文。剧情时间：未知。');
    } else {
      lines.add('剧情时间：未知。当前正文未能唯一对应这条流水，需先用 read_story 核对。');
    }
    return lines.join('\n');
  }

  bool _matchesEvidence(FactualMemoryStoryRound round) {
    if (currentFactsChanges == null || currentFactsChanges!.isEmpty) {
      return false;
    }
    final evidence = _parseEvidence(currentFactsChanges!);
    final matches = evidence
        .where(
          (item) =>
              item['entityId'] == history.entityId &&
              item['action'] == history.action.toJsonString() &&
              item['oldValue'] == history.oldValue &&
              item['newValue'] == history.newValue,
        )
        .toList();
    if (matches.length != 1) return false;
    final text = [
      round.userText,
      round.narrativeText,
      round.replyText,
      round.eventSummaryText,
    ].whereType<String>().join('\n').toLowerCase();
    final nameMatches = text.contains(entity.primaryName.toLowerCase()) ||
        entity.aliases.any((alias) => text.contains(alias.toLowerCase()));
    final changedTokens = _changedValueTokens();
    final valueMatches = changedTokens.isNotEmpty &&
        changedTokens.any((value) => text.contains(value.toLowerCase()));
    return nameMatches && valueMatches;
  }

  static List<Map<String, dynamic>> _parseEvidence(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return const [];
      return decoded.whereType<Map<String, dynamic>>().toList();
    } on FormatException {
      return const [];
    }
  }

  static String? _computedAfter(
    String action,
    String? oldValue,
    String? changedValue,
  ) {
    if (changedValue == null ||
        (action != 'append_list' && action != 'remove_from_list')) {
      return action == 'update_attr' ? changedValue : null;
    }
    if (oldValue == null) return null;
    try {
      final decoded = jsonDecode(oldValue);
      if (decoded is! List) return null;
      final result = decoded.map((item) => item.toString()).toList();
      if (action == 'append_list') {
        if (!result.contains(changedValue)) result.add(changedValue);
      } else {
        result.remove(changedValue);
      }
      return jsonEncode(result);
    } on FormatException {
      return null;
    }
  }
}

class _MemoryChangesCursor {
  _MemoryChangesCursor({
    required this.sessionId,
    required this.conditions,
    required this.digest,
    required this.instanceNonce,
    required this.lastTurn,
    required this.lastHistoryId,
  });

  factory _MemoryChangesCursor.fromJson(Map<String, dynamic> json) =>
      _MemoryChangesCursor(
        sessionId: json['session_id'] as String,
        conditions: (json['conditions'] as Map).cast<String, dynamic>(),
        digest: json['digest'] as String,
        instanceNonce: json['instance_nonce'] as String,
        lastTurn: (json['last_turn'] as num).toInt(),
        lastHistoryId: (json['last_history_id'] as num).toInt(),
      );

  final String sessionId;
  final Map<String, dynamic> conditions;
  final String digest;
  final String instanceNonce;
  final int lastTurn;
  final int lastHistoryId;

  String encode() => base64UrlEncode(
        utf8.encode(
          jsonEncode({
            'session_id': sessionId,
            'conditions': conditions,
            'digest': digest,
            'instance_nonce': instanceNonce,
            'last_turn': lastTurn,
            'last_history_id': lastHistoryId,
          }),
        ),
      );
}

_MemoryChangesCursor? _decodeMemoryCursor(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(utf8.decode(base64Url.decode(raw))) as Map;
    return _MemoryChangesCursor.fromJson(decoded.cast<String, dynamic>());
  } on FormatException {
    return null;
  } catch (_) {
    return null;
  }
}

String? _readTrimmed(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  return text.isEmpty ? null : text;
}

int? _readInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num && raw == raw.roundToDouble()) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

List<String>? _readStringList(Object? raw) {
  if (raw == null) return const [];
  if (raw is String) return [raw];
  if (raw is! List) return null;
  if (raw.any((item) => item is! String)) return null;
  return raw.cast<String>();
}

String? _normalizeFactAction(String raw) {
  final value = raw.trim().toLowerCase();
  const aliases = {
    'create': 'create_entity',
    'create_entity': 'create_entity',
    'update': 'update_attr',
    'update_attr': 'update_attr',
    'append': 'append_list',
    'append_list': 'append_list',
    'remove': 'remove_from_list',
    'remove_from_list': 'remove_from_list',
    'add_alias': 'add_alias',
    'alias': 'add_alias',
    'archive': 'archive_entity',
    'archive_entity': 'archive_entity',
    'set_importance': 'set_importance',
    'importance': 'set_importance',
  };
  return aliases[value];
}

bool _isMaintenanceHistory(FactualMemoryHistory history) {
  final reason = history.reason ?? '';
  return reason == RelationshipSplitMigration.splitReason ||
      reason == RelationshipSplitMigration.restoreReason ||
      reason == RelationshipSplitMigration.pendingReason;
}

int _compareMemoryChangeRows(_MemoryChangeRow a, _MemoryChangeRow b) {
  final byTurn = b.history.turnNumber.compareTo(a.history.turnNumber);
  if (byTurn != 0) return byTurn;
  final byId = b.history.historyId!.compareTo(a.history.historyId!);
  if (byId != 0) return byId;
  final byEntity = a.entity.entityId.compareTo(b.entity.entityId);
  if (byEntity != 0) return byEntity;
  return (a.attribute?.attrKey ?? '').compareTo(b.attribute?.attrKey ?? '');
}

String _stableDigest(String value) {
  var hash = 2166136261;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 实体修订摘要（读取时点）：统一走 [entityRevisionDigest]——与闸门
/// 时点的当前修订共用同一规范化函数/排序/时间身份。
String _entityDigest(FactualEntity e, List<FactualAttribute> attrs) {
  return entityRevisionDigest(
    updatedAtMs: e.updatedAt?.millisecondsSinceEpoch,
    attributes: [for (final a in attrs) (a.attrKey, a.value)],
  );
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
      _recordToolCall(_deps.draft, name, countsForMaintenance: true);
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

    _recordToolCall(_deps.draft, name, countsForMaintenance: true);
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

  /// 审批基底快照键（entityId + 归一 attrKey）
  static String factBaseKey(String entityId, String attrKey) =>
      '$entityId|$attrKey';

  /// 暂存时捕获该属性的 DB 当前基底值（仅 update_attr；同属性只记首次）
  Future<void> _captureFactBaseIfNeeded(FactsDelta delta) async {
    if (delta.action != FactAction.updateAttr) return;
    final entityId = delta.entityId;
    final attrKey = delta.attrKey;
    if (entityId == null || attrKey == null) return;
    final repo = _deps.factualRepository;
    try {
      final entity = await repo.getEntityById(entityId);
      if (entity == null) return;
      final normalized = AttributeSchema.normalizeAttrKey(entity.type, attrKey);
      final snapshots = _deps.draft.factBaseSnapshots;
      final key = factBaseKey(entityId, normalized);
      if (snapshots.containsKey(key)) return;
      final rows = await repo.getAttributesByKey(entityId, normalized);
      String? current;
      for (final row in rows) {
        if (row.source == FactualSource.auto) {
          current = row.value;
          break;
        }
      }
      snapshots[key] = current;
    } catch (_) {
      // 基底读取失败不阻断暂存；该键提交期无基底可比（跳过漂移检查）
    }
  }

  /// 提交期基底漂移检测：返回「暂存后当前值 ≠ 暂存时基底」的键集合。
  /// 同轮多次暂存同属性不误报（DB 在提交前不被轮内暂存改动）。
  static Future<Set<String>> detectFactBaseDrift({
    required AgentRoundDraft draft,
    required FactualRepository repository,
  }) async {
    final drifted = <String>{};
    for (final entry in draft.factBaseSnapshots.entries) {
      final separator = entry.key.indexOf('|');
      if (separator <= 0) continue;
      final entityId = entry.key.substring(0, separator);
      final attrKey = entry.key.substring(separator + 1);
      try {
        final rows = await repository.getAttributesByKey(entityId, attrKey);
        String? current;
        for (final row in rows) {
          if (row.source == FactualSource.auto) {
            current = row.value;
            break;
          }
        }
        if (current != entry.value) drifted.add(entry.key);
      } catch (_) {
        continue;
      }
    }
    return drifted;
  }

  /// 同参提交计数（幂等回执；key = delta 序列化，值 = 已见次数）。
  /// 实例级（一轮一实例），首次调用时从 draft 既有暂存初始化。
  final Map<String, int> _submissionCounts = {};
  bool _submissionCountsInitialized = false;

  @override
  String get name => 'update_facts';

  @override
  String get description => '''
写入/更新事实层（人物状态、关系、设定、重要度等）。各动作必填字段矩阵（全部 7 种动作均须提供 action 与 confidence[1-5 整数：1=猜测，3=剧情合理推断，5=正文或设定明确写明]）：
- create_entity：action + confidence + entity_type + primary_name（建议附 importance 及 attr_key+value 初始化属性）
- update_attr：action + confidence + 目标（entity_id 或 primary_name）+ attr_key + value
- append_list：action + confidence + 目标（entity_id 或 primary_name）+ attr_key + value
- remove_from_list：action + confidence + 目标（entity_id 或 primary_name）+ attr_key + value
- add_alias：action + confidence + 目标（entity_id 或 primary_name）+ value（别名）
- archive_entity：action + confidence + 目标（entity_id 或 primary_name）（可选 value/reason）
- set_importance：action + confidence + 目标（entity_id 或 primary_name）+ importance[1-5]（可选 reason）
新实体首次出现时，create_entity 应同时带 attr_key+value 初始化属性；已知实体缺关键属性时主动补齐。更新既有实体优先用 list_facts/query_facts 的 [实体ID] 定位，缺省时 primary_name 按名定位亦可。重要度（1-5）代表当前及后续剧情对注入视野的需求权重，可随时用 set_importance 随角色或设定戏份升降动态调整。变更先暂存，交付或维护收尾时统一提交；导入实体（世界书/角色卡）的基线内容只读：对其 update_attr 会作为演变并存、可新增属性与别名、主名不可改（将转别名）、可 archive、可用 set_importance 调整注入重要度；基线原文永不被覆盖。单值属性更新只保留精炼的当前有效设定/状态，状态变更直接精简刷新（过程经历交由 record_event_memory）；信息维度增多时，针对 character/lore 善用自定义细分 attr_key，控制单字段长度不无限叠加。若本工具返回部分或全部失败，已暂存条目会保留，请仅针对失败条目修正参数后重新调用 update_facts。暂存有误时的补救通道：clear_pending=true 清空本轮全部暂存变更（可不带 deltas）；replace_pending=true 清空后以本次 deltas 重新暂存。关系约定：与具体角色的关系用 attr_key=relationship:对方名（single）；relationships（dict）仅存群体/笼统关系且只能整体 update。''';

  @override
  AgentToolPermission get permission => AgentToolPermission.write;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'deltas': {
          'type': 'array',
          'description':
              '变更列表（单次最多 8 条）。每条均必填 action 与 confidence（1-5，含 set_importance）：\n'
                  'create_entity 另必填 entity_type + primary_name（建议附 attr_key + value）；\n'
                  'update_attr / append_list / remove_from_list 另必填 entity_id/primary_name + attr_key + value；\n'
                  'add_alias 另必填 entity_id/primary_name + value；\n'
                  'archive_entity 另必填 entity_id/primary_name；\n'
                  'set_importance 另必填 entity_id/primary_name + importance（1-5）。',
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
                  'set_importance',
                ],
              },
              'confidence': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 5,
                'description':
                    '把握度 / 证据强度（1-5 整数；包括 set_importance 在内的全部 7 种动作均必填，不可省略）：1=低把握猜测，2=弱线索推断，3=剧情合理判断，4=明确依据，5=正文直述或已核实设定；关键属性变更通常要求 ≥3。',
              },
              'entity_id': {
                'type': 'string',
                'description':
                    '目标实体 ID（list_facts / query_facts 卡片的 [ent_xxx]）。create_entity 不用；缺省时可用 primary_name 按名定位',
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
                'description': '实体类型（create_entity 时必填）',
              },
              'primary_name': {
                'type': 'string',
                'description':
                    '实体主名（create_entity 时必填；其余动作在缺少 entity_id 时用于按名定位）',
              },
              'attr_key': {
                'type': 'string',
                'description':
                    '属性键。update_attr/append_list/remove_from_list 时必填；create_entity 时建议携带 '
                        '（创建实体的同时初始化属性，如 description=描述）。各类型预定义键：\n'
                        'character: name/personality/background/relationships/skills '
                        '（另支持 status/location/goal/appearance 等自定义细分键）\n'
                        'location: name/description/features\n'
                        'item: name/description/owner\n'
                        'lore: name/description/category（另支持自定义细分键）\n'
                        'organization: name/description/leader/members/background\n'
                        'misc: name/description/category\n'
                        '注：character 用 description 描述背景时系统自动映射到 background。',
              },
              'value': {
                'type': 'string',
                'description':
                    '属性值/别名/归档原因（update_attr/append_list/remove_from_list/add_alias 时必填）。更新单值（single）属性时请用精炼的当前有效设定/状态替换旧文，状态变化直接刷新并把过程留给事件记忆；维度较多时拆分为细分 attr_key，不要无限累加。',
              },
              'reason': {'type': 'string', 'description': '变更理由'},
              'importance': {
                'type': 'integer',
                'minimum': 1,
                'maximum': 5,
                'description':
                    '重要度 1-5，代表当前及后续剧情对注入视野的需求权重（≥5 进入核心常驻，退场可降至 2-3 腾出槽位）；set_importance 时必填（仍须同时填 confidence），create_entity 时建议携带',
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
    final rawDeltas = AgentFactsDeltaInput.decodeList(arguments['deltas']);
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
      // 基底快照随暂存一起清空——replace 语义是「全新暂存」，
      // 保留旧快照会让新暂存误比旧基底。
      _deps.draft.factBaseSnapshots.clear();
      _recordToolCall(_deps.draft, name, countsForMaintenance: true);
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
    if (rawDeltas.length > AgentFactsDeltaInput.maxBatchSize) {
      return AgentToolResult.failure(
        title: '一次最多 8 条',
        output: '单次最多 8 条变更（当前 ${rawDeltas.length} 条）。请分批提交。',
      );
    }

    final accepted = <String>[];
    final actionableRejected = <String>[];
    final noopSkipped = <String>[];
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
    final inMaintenance = _deps.draft.phase == AgentRoundPhase.maintenance;
    for (var i = 0; i < rawDeltas.length; i++) {
      final parsed = AgentFactsDeltaInput.fromRaw(rawDeltas[i]);
      final input = parsed.input;
      if (input == null) {
        actionableRejected.add('第 ${i + 1} 条：${parsed.error}');
        continue;
      }
      final delta = input.toFactsDelta(skipFrequencyGuard: inMaintenance);
      if (delta == null) {
        // fromRaw 已覆盖全部校验分支，这里只是防御兜底
        actionableRejected.add('第 ${i + 1} 条：格式无效');
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
        actionableRejected.add(precheckReject);
        continue;
      }
      final preflight = await _preflightDelta(delta, i + 1);
      if (preflight != null) {
        if (preflight.isNoop) {
          noopSkipped.add(preflight.message);
        } else {
          actionableRejected.add(preflight.message);
        }
        continue;
      }
      _submissionCounts[key] = 1;
      _deps.draft.factsDeltas.add(delta);
      await _captureFactBaseIfNeeded(delta);
      if (delta.action == FactAction.createEntity &&
          delta.primaryName != null) {
        newCreateNames.add(delta.primaryName!);
      }
      final acceptedDetail = delta.action == FactAction.setImportance
          ? ' importance=${delta.importance}'
          : '${delta.attrKey != null ? '.${delta.attrKey}' : ''}${delta.value != null ? ' = ${delta.value}' : ''}';
      accepted.add(
        '${i + 1}. ${delta.action.name} → ${delta.primaryName ?? delta.entityId ?? '?'}$acceptedDetail',
      );
    }

    // 相似名核对（包含关系，只提示不自动归并）：把"查询未命中→每轮新建"
    // 造成的近重复实体在提交前暴露给模型。
    var similarHints = 0;
    final similarHintLines = <String>[];
    if (newCreateNames.isNotEmpty) {
      final candidates = await FactContextBuilder(
        repository: _deps.factualRepository,
      ).findSimilarNameCandidates(_deps.sessionId, newCreateNames);
      if (candidates.isNotEmpty) {
        similarHints = candidates.length;
        similarHintLines.add('注意：新建的名字与既有实体名称相近，请核对是否同一对象：');
        for (final candidate in candidates) {
          similarHintLines.add(
            '· 「${candidate.newName}」≈ 既有 '
            '${candidate.displayNames.join('、')}——若为同一对象，请改用 '
            'add_alias（并入既有实体）或 merge_entities，不要重复建档。',
          );
        }
      }
    }

    // 存在第 II 类可修正失败（无论是否有部分 accepted）→ 返回 isError: true，
    // 保留已成功暂存的 accepted，指引模型仅修正失败条目重调 update_facts。
    if (actionableRejected.isNotEmpty) {
      if (accepted.isNotEmpty ||
          duplicates.isNotEmpty ||
          noopSkipped.isNotEmpty) {
        _recordToolCall(_deps.draft, name, countsForMaintenance: true);
      }
      final clearedNotice = (clearPending || replacePending) && removedCount > 0
          ? '\n注意：本次调用已先清空此前的 $removedCount 条暂存'
              '${accepted.isEmpty ? '，且新内容全部被拒——当前暂存为空，本轮 finish_round 将不提交任何事实变更。' : '，并重新暂存本次合法条目。'}'
          : '';
      if (accepted.isEmpty && duplicates.isEmpty && noopSkipped.isEmpty) {
        return AgentToolResult.failure(
          title: '变更全部无效',
          output: '全部变更被拒绝，逐条原因：\n${actionableRejected.join('\n')}\n'
              '要求：action 为七种合法动作之一、confidence 为 1-5 整数（含 set_importance 在内的全部动作均必填）、entity_id 或 '
              'primary_name 至少一个；字段名用小写蛇形（entity_id/primary_name/attr_key）。请修正参数后重新调用 update_facts。'
              '$clearedNotice',
          metadata: {
            'accepted': 0,
            'rejected': actionableRejected.length,
            'duplicates': 0,
            'noopSkipped': 0,
            'similarHints': 0,
          },
        );
      }
      final errBuffer = StringBuffer();
      if (accepted.isNotEmpty) {
        errBuffer
          ..writeln('已成功暂存 ${accepted.length} 条（已保留在暂存区，无需重复提交）：')
          ..writeAll(accepted, '\n');
        if (importedNameHints.isNotEmpty) {
          errBuffer.write('\n${importedNameHints.join('\n')}');
        }
        if (similarHintLines.isNotEmpty) {
          errBuffer.write('\n\n${similarHintLines.join('\n')}');
        }
      }
      if (duplicates.isNotEmpty) {
        if (errBuffer.isNotEmpty) errBuffer.write('\n\n');
        errBuffer
          ..writeln('以下 ${duplicates.length} 条为重复暂存（已自动去重跳过）：')
          ..writeAll(duplicates, '\n');
      }
      if (noopSkipped.isNotEmpty) {
        if (errBuffer.isNotEmpty) errBuffer.write('\n\n');
        errBuffer
          ..writeln('以下 ${noopSkipped.length} 条无需重复写入（设定已是最新）：')
          ..writeAll(noopSkipped, '\n');
      }
      if (errBuffer.isNotEmpty) errBuffer.write('\n\n');
      errBuffer
        ..writeln(
          '以下 ${actionableRejected.length} 条失败未写入（请仅针对这些失败条目修正参数后重新调用 update_facts）：',
        )
        ..writeAll(actionableRejected, '\n');
      if (clearedNotice.isNotEmpty) {
        errBuffer.write(clearedNotice);
      }
      if (accepted.isNotEmpty) {
        errBuffer.write('\n已暂存条目将在 finish_round / finish_maintenance 提交时生效。');
      }
      return AgentToolResult(
        title: accepted.isEmpty
            ? '变更全部无效'
            : '${accepted.length} 条已暂存，${actionableRejected.length} 条失败待修正',
        output: errBuffer.toString(),
        isError: true,
        metadata: {
          'accepted': accepted.length,
          'rejected': actionableRejected.length,
          'duplicates': duplicates.length,
          'noopSkipped': noopSkipped.length,
          'similarHints': similarHints,
        },
      );
    }

    // 全部为第 I 类无需写入的幂等/状态已满足跳过（无 accepted/duplicates/actionable）
    if (accepted.isEmpty && duplicates.isEmpty && noopSkipped.isNotEmpty) {
      _recordToolCall(_deps.draft, name, countsForMaintenance: true);
      return AgentToolResult.success(
        title: '设定已是最新，无需重复写入',
        output: '以下 ${noopSkipped.length} 条变更无需重复写入（目标状态已是最新）：\n'
            '${noopSkipped.join('\n')}',
        metadata: {
          'accepted': 0,
          'rejected': 0,
          'duplicates': 0,
          'noopSkipped': noopSkipped.length,
          'similarHints': 0,
        },
        outputSchema: kOutputSchema,
      );
    }

    final buffer = StringBuffer(
      accepted.isEmpty
          ? '本次 ${duplicates.length} 条全部为重复暂存，未新增变更：\n'
          : '已暂存 ${accepted.length} 条变更'
              '${duplicates.isNotEmpty ? '（${duplicates.length} 条重复被跳过）' : ''}'
              '${noopSkipped.isNotEmpty ? '（${noopSkipped.length} 条已是最新跳过）' : ''}：\n',
    )..writeAll(accepted, '\n');
    if (duplicates.isNotEmpty) {
      if (accepted.isNotEmpty) buffer.write('\n');
      buffer.writeAll(duplicates, '\n');
    }
    if (noopSkipped.isNotEmpty) {
      buffer
        ..write('\n')
        ..writeAll(noopSkipped, '\n');
    }
    // 主名转换提示行（与 accepted 行同用 1-based 序号，按「第 N 条」
    // 对应）；命中即有 accepted 行，前置换行总有效
    if (importedNameHints.isNotEmpty) {
      buffer.write('\n${importedNameHints.join('\n')}');
    }
    if (similarHintLines.isNotEmpty) {
      buffer.write('\n\n${similarHintLines.join('\n')}');
    }

    buffer.write('\n变更将在 finish_round 提交时统一生效。');

    // 成功路径登记 calledTools—— 升级闸门据此判「本轮用过记忆工具」
    _recordToolCall(_deps.draft, name, countsForMaintenance: true);
    return AgentToolResult.success(
      title: accepted.isEmpty
          ? '${duplicates.length} 条重复暂存'
          : '${accepted.length} 处修订',
      output: buffer.toString(),
      metadata: {
        'accepted': accepted.length,
        'rejected': 0,
        'duplicates': duplicates.length,
        'noopSkipped': noopSkipped.length,
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

  /// 与 FactApplier / FactsDeltaProjectionEvaluator 同源的暂存期预检。
  ///
  /// 返回 `isNoop: true` 表示第 I 类幂等/状态已满足跳过；`isNoop: false` 表示第 II 类可修正错误。
  Future<({String message, bool isNoop})?> _preflightDelta(
    FactsDelta delta,
    int index,
  ) async {
    if (delta.action == FactAction.createEntity &&
        delta.value != null &&
        delta.value!.length > _deps.factualConfig.maxAttrValueLength) {
      return (
        message: '第 $index 条：属性值过长（${delta.value!.length} 字，上限 '
            '${_deps.factualConfig.maxAttrValueLength} 字）。请精简为当前有效状态，或先创建实体后拆分为多个细分 attr_key。',
        isNoop: false,
      );
    }
    final verdict = await FactsDeltaProjectionEvaluator.preflightDelta(
      repository: _deps.factualRepository,
      sessionId: _deps.sessionId,
      delta: delta,
      config: _deps.factualConfig,
      turnNumber: _deps.draft.turnNumber,
    );
    if (verdict.outcome != FactsProjectionOutcome.skipped) return null;
    final note = verdict.note;
    if (note == null) return null;
    switch (note) {
      case FactsProjectionNote.entityMissing:
      case FactsProjectionNote.noMutableList:
      case FactsProjectionNote.valueNotInList:
        return null;
      case FactsProjectionNote.valueTooLong:
      case FactsProjectionNote.aliasTooLong:
        return (
          message:
              '第 $index 条：内容过长（上限 ${_deps.factualConfig.maxAttrValueLength} 字）。请只保留精炼的当前有效状态，或对 character/lore 拆分为细分 attr_key。',
          isNoop: false,
        );
      case FactsProjectionNote.tooFrequent:
        return (
          message:
              '第 $index 条：该实体近 3 轮更新已达上限（${_deps.factualConfig.maxUpdatesPer3Turns} 次）。请合并精简后再更新，或留待周期维护阶段统一校准。',
          isNoop: false,
        );
      case FactsProjectionNote.confidenceGate:
        return (
          message:
              '第 $index 条：关键属性变更要求 confidence ≥ ${_deps.factualConfig.modifyConfidenceThreshold}（当前 ${delta.confidence}）。请核对证据后提高 confidence 再提交。',
          isNoop: false,
        );
      case FactsProjectionNote.valueUnchanged:
      case FactsProjectionNote.valueUnchangedBaseline:
        return (
          message: '第 $index 条：目标值与当前已有设定或重要度完全相同，无需重复写入。',
          isNoop: true,
        );
      case FactsProjectionNote.attrKeyNotWhitelisted:
        return (
          message:
              '第 $index 条：属性键「${delta.attrKey}」不在该实体类型的允许字段内；请改用预定义键（character 与 lore 支持自定义细分键）。',
          isNoop: false,
        );
      case FactsProjectionNote.importanceOutOfRange:
        return (
          message: '第 $index 条：set_importance 的 importance 必须为 1-5 的整数。',
          isNoop: false,
        );
      case FactsProjectionNote.missingFields:
        return (
          message:
              '第 $index 条：缺少必填字段（update_attr/append_list/remove_from_list 需 attr_key+value，create_entity 需 entity_type+primary_name，set_importance 需 importance 1-5，add_alias 需 value）。',
          isNoop: false,
        );
      case FactsProjectionNote.unknownEntityType:
        return (
          message: '第 $index 条：entity_type「${delta.entityType}」非法。',
          isNoop: false,
        );
      case FactsProjectionNote.listRejectsUpdate:
        return (
          message:
              '第 $index 条：「${delta.attrKey}」为列表属性，请改用 append_list 或 remove_from_list。',
          isNoop: false,
        );
      case FactsProjectionNote.dictRejectsAppend:
      case FactsProjectionNote.dictKeyCreatesList:
        return (
          message:
              '第 $index 条：「${delta.attrKey}」为字典属性，不能用 append_list；请用 update_attr 整体更新，或对具体对象使用 relationship:对方名。',
          isNoop: false,
        );
      case FactsProjectionNote.aliasEmpty:
        return (message: '第 $index 条：别名不能为空。', isNoop: false);
      case FactsProjectionNote.aliasSameAsPrimary:
        return (message: '第 $index 条：别名与实体主名相同，无需添加。', isNoop: true);
      case FactsProjectionNote.aliasExists:
        return (message: '第 $index 条：该别名已存在，无需重复添加。', isNoop: true);
      case FactsProjectionNote.aliasLimit:
        return (
          message: '第 $index 条：该实体别名数量已达上限（$kFactsMaxAliasesPerEntity 条）。',
          isNoop: false,
        );
      case FactsProjectionNote.alreadyArchived:
        return (message: '第 $index 条：实体已归档，无需重复归档。', isNoop: true);
      case FactsProjectionNote.nameIsIdentity:
      case FactsProjectionNote.baselineSingleRedirect:
      case FactsProjectionNote.appendOnSingleConvertsUpdate:
      case FactsProjectionNote.duplicateExact:
      case FactsProjectionNote.sameNameConvertsUpdate:
      case FactsProjectionNote.sameNameConvertsAlias:
      case FactsProjectionNote.createsAttrRow:
        return null;
    }
  }
}

/// deltas 容错解码：部分弱模型会把整个数组序列化成 JSON 字符串

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
      _recordToolCall(_deps.draft, name, countsForMaintenance: true);
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
    _recordToolCall(_deps.draft, name, countsForMaintenance: true);
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
    _recordToolCall(_deps.draft, name, countsForMaintenance: true);
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
    _recordToolCall(_deps.draft, name, countsForMaintenance: true);
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
      '提交本轮：正文经 prose 参数交付——完整正文原文直接写入该参数，读者在正文卡阅读它。通过终审检查（事实出处、文风）后统一提交暂存变更并结束（大周期轮交付正文后将进入维护阶段，完成后由 finish_maintenance 收尾）。回复文本另有职责：只写一两句过场播报，正文的唯一载体是 prose 参数。';

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
      },
      'required': ['prose'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    if (_deps.draft.phase == AgentRoundPhase.maintenance) {
      return AgentToolResult.failure(
        title: '正文已锁定',
        output: '第 ${_deps.draft.turnNumber} 轮正文已在任务一交付并锁定，无需再次调用 '
            'finish_round 或重写正文。请使用 list_facts / query_facts / '
            'update_facts 等工具完成记忆审查与同步后，调用 finish_maintenance 结束本轮。',
      );
    }

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
    // 工程上下文模式（开启态）：证据闸门（status 真实、无 calledTools
    // 旁路、四类资格+修订未变；关闭态 gate 为 null 走下方旧分支）
    final evidenceGate = _deps.retrievalEvidenceGate;
    if (evidenceGate != null) {
      EntityCoverageCheck? coverage;
      try {
        coverage = await evidenceGate(prose);
      } catch (_) {
        coverage = null; // 闸门数据面异常不阻断提交（fail-open；留痕由接线方）
      }
      if (coverage != null) {
        final missing = [
          ...coverage.missingEntities,
          ...coverage.missingDueToRevision,
        ];
        if (missing.isNotEmpty) {
          if (!_deps.draft.retrievalGateUsed) {
            _deps.draft.retrievalGateUsed = true;
            final staleNote = coverage.missingDueToRevision.isNotEmpty
                ? '（其中 ${coverage.missingDueToRevision.join('、')} 的事实最近核对后有修订，需按新值重新核对）'
                : '';
            return AgentToolResult.failure(
              title: '终审未过：实体缺少当前有效核对证据',
              output: '终审未过：以下实体缺少当前有效核对证据（未检索或设定有新变更）：'
                  '「${missing.join('、')}」$staleNote。\n'
                  '已具备有效证据的实体无需重复查询。请针对缺少证据的实体调用 query_facts 核对后再提交。',
            );
          }
          invocation.onProgress?.call(
            '证据闸门豁免放行：「${missing.take(3).join('、')}」缺少有效证据…',
          );
        }
      }
    }

    // 开启态只能选新资格策略——旧本轮 calledTools 闸门仅关闭态
    //（gate null）执行；新 gate 通过后不再被「全程未检索核对」首拒。
    final retrievalHitNames =
        evidenceGate == null ? await _checkRetrievalCoverage(prose) : null;
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
      // 工程上下文模式（开启态）：事件暴露量闸门（表面超比 ∧
      // exposure≥3 ∧ 未记录三条件同时；过渡轮直接放行）取代旧首次拦截；
      // 关闭态（gate null）旧闸门分支完整保留。
      final exposureGate = _deps.eventExposureGate;
      if (exposureGate != null) {
        EventExposureCheck? exposure;
        try {
          exposure = await exposureGate(prose);
        } catch (_) {
          exposure = null;
        }
        if (exposure != null && exposure.shouldGate) {
          if (!_deps.draft.eventMemoryGateUsed) {
            _deps.draft.eventMemoryGateUsed = true;
            return AgentToolResult.failure(
              title: '终审提醒：新实体未被记录',
              output: exposure.newEntities.isEmpty
                  ? '终审提醒：本轮多次修改设定且尚未记录事件。请用 record_event_memory 记一件最重要的事再提交；确无值得记录的事件，直接再次 finish_round 放行。'
                  : '终审提醒：本轮引入了新的关键实体（${exposure.newEntities.join('、')}）且上下文已较长，尚未记录事件。请用 record_event_memory 记一件最重要的事再提交；确无值得记录的事件，直接再次 finish_round 放行。',
            );
          }
          invocation.onProgress?.call('事件记忆豁免放行（暴露量闸门）…');
        }
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

    if (_deps.draft.isMajorReviewRound &&
        _deps.draft.phase == AgentRoundPhase.writing) {
      _deps.draft.phase = AgentRoundPhase.maintenance;
      final extraSteps = _deps.maintenanceExtraSteps;
      const maintenanceNotice = '$kPriorityObedienceClause维护步数预算已达上限，所有工具已停用。'
          '本轮正文已在任务一提前锁定，请勿再输出或重写正文；'
          '请调用 finish_maintenance 或用一句话简短确认维护收尾并结束本轮。';
      return AgentToolResult.success(
        title: '任务一完成 · 进入周期审查',
        output: '【任务一已完成】第 ${_deps.draft.turnNumber} 轮正文已交付并锁定，后续无需再修改正文。\n'
            '现在切换至【任务二：周期审查与维护】：请脱离写作视角，结合已锁定的本轮正文与近数十轮剧情变化，使用 list_facts / query_facts / read_compact_summary 等工具全盘核对事实库（含实体重要度与归档）、事件记忆及剧情锚；确认同步完毕后调用 finish_maintenance 结束本轮。',
        metadata: {
          'committed': false,
          'phase': 'maintenance',
          'extraMaxStepsDelta': extraSteps,
        },
        outputSchema: kOutputSchema,
        extraMaxStepsDelta: extraSteps,
        phaseSoftLandingNotice: maintenanceNotice,
      );
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

// ==================== 控制：finish_maintenance ====================

/// 结束大周期审查与维护阶段（任务二）并统一提交本轮正文与全部记忆变更。
class FinishMaintenanceTool implements AgentTool {
  FinishMaintenanceTool(this._deps);

  /// 终局回执的输出结构声明
  static const Map<String, String> kOutputSchema = {'committed': 'boolean'};

  final AgentToolDeps _deps;

  @override
  String get name => 'finish_maintenance';

  @override
  String get description =>
      '结束周期审查与维护阶段并统一提交本轮。仅在大周期轮完成任务一 finish_round 锁定正文、并使用 list_facts / query_facts / read_compact_summary / update_facts 等完成核对与同步后调用。';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() => const {
        'type': 'object',
        'properties': <String, dynamic>{},
      };

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    if (_deps.draft.phase != AgentRoundPhase.maintenance) {
      return AgentToolResult.failure(
        title: '尚未进入维护阶段',
        output:
            '当前仍处于正文写作阶段（任务一），尚未调用 finish_round 交付正文。请先完成写作并调用 finish_round；常规轮次无需调用 finish_maintenance。',
      );
    }

    if (!_deps.draft.maintenanceCheckedOrUpdated &&
        !_deps.draft.maintenanceGateUsed) {
      _deps.draft.maintenanceGateUsed = true;
      return AgentToolResult.failure(
        title: '尚未巡检记忆状态',
        output:
            '尚未进行工具巡检，请先用 list_facts、query_facts、read_compact_summary 或 update_facts / update_story_anchor / record_event_memory 核对与同步后再确认收尾；如确认无需核对或修改，请再次调用 finish_maintenance。',
      );
    }

    invocation.onProgress?.call('提交本轮正文与维护变更…');
    try {
      final persistedReply = await _deps.commitRound(_deps.draft);
      _deps.draft.maintenanceCompleted = true;
      return AgentToolResult.terminal(
        title: '周期维护完成',
        output:
            '周期审查与维护已完成，本轮正文与全部变更已统一提交。回复正文：${persistedReply.length > 60 ? '${persistedReply.substring(0, 60)}…' : persistedReply}',
        metadata: {'committed': true},
        outputSchema: kOutputSchema,
      );
    } catch (e) {
      return AgentToolResult.failure(
        title: '提交失败',
        output: '本轮提交失败：$e。数据已回滚，请重试 finish_maintenance。',
      );
    }
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
