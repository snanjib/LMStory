import 'dart:convert';
// TODO(decouple): domain→advanced 临时边（导演 UI 实体），P2 拆 state 时消除
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:meta/meta.dart';

/// 中级模式轮次中间产物（持久化后的快照）
///
/// 对应 `intermediate_round_artifacts` 表（v0.2  新增）。
/// 用于持久化每轮四步生成的生成内容/关键词/检索结果，使历史轮次的小窗
/// 在切换会话或重新进入时仍可见（修复"生成内容和检索过程消失"问题）。
///
/// 与 ChatMessage 解耦：通过 [sessionId] + [turnNumber] 关联到对应
/// assistant 消息，不污染 ChatMessage 字段（DOC-09A-1 §1.5 硬约束）。
///
/// DOC-11 §6.1 扩展：新增 [retrievedFacts] 字段，持久化事实层检索结果，
/// 使历史轮次的事实类分区可见。
///
/// Schema 依据：DOC-09C §5、DOC-08 §5.5、DOC-02 §6.4
@immutable
class StoryRoundArtifacts {
  const StoryRoundArtifacts({
    required this.sessionId,
    required this.turnNumber,
    required this.createdAt,
    this.generatedText,
    this.extractedKeywords = const [],
    this.retrievedMemories = const [],
    this.retrievedFacts = const [],
    this.replyText,
    this.eventSummary,
    this.factsChanges = const [],
    this.agentSteps = const [],
    this.agentTimeline = const [],
    this.agentWorkSummary,
    this.storyAnchor,
    this.reviewExecuted = false,
    this.currentVariantIndex,
  });

  /// 从 JSON 反序列化
  factory StoryRoundArtifacts.fromJson(Map<String, dynamic> json) {
    return StoryRoundArtifacts(
      sessionId: json['sessionId'] as String,
      turnNumber: json['turnNumber'] as int,
      generatedText: json['generatedText'] as String?,
      extractedKeywords:
          (json['extractedKeywords'] as List<dynamic>).cast<String>(),
      retrievedMemories: (json['retrievedMemories'] as List<dynamic>)
          .map((e) => ExperientialMemory.fromJson(e as Map<String, dynamic>))
          .toList(),
      retrievedFacts: (json['retrievedFacts'] as List<dynamic>?)
              ?.map((e) => RetrievedFact.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      replyText: json['replyText'] as String?,
      eventSummary: json['eventSummary'] == null
          ? null
          : EventSummary.fromJson(json['eventSummary'] as Map<String, dynamic>),
      factsChanges: (json['factsChanges'] as List<dynamic>?)
              ?.map(
                (e) => FactsChangeRecord.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          const [],
      agentSteps: AgentWorkStep.normalizeTerminal(
        AgentWorkStep.listFromJsonString(
          json['agentSteps'] as String?,
        ),
      ),
      // 读侧终态归一——写侧归一（f8c9d7c9）只堵新数据，
      //  时间线（schema 45）以来存量成功轮的 artifacts 里仍带着 running
      // finish_round 块，历史轮展开幕后组渲染永久 spinner；fromJson 是全部
      // 历史轮的必经读点，此处兜底同时防未来任何写侧回归。
      agentTimeline: AgentTimelineBlock.normalizeTerminalActions(
        AgentTimelineBlock.listFromJsonString(
          json['agentTimeline'] as String?,
        ),
      ),
      agentWorkSummary: parseAgentWorkSummary(
        json['agentWorkSummary'] as String?,
      ),
      storyAnchor: StoryAnchor.parse(json['storyAnchor'] as String?),
      reviewExecuted: (json['reviewExecuted'] as bool?) ?? false,
      currentVariantIndex: json['currentVariantIndex'] as int?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        json['createdAt'] as int,
      ),
    );
  }

  /// 所属会话
  final String sessionId;

  /// 轮次号（与 ChatMessage.turnNumber + experiential_memories.turnNumber 对齐）
  final int turnNumber;

  /// 生成全文（reviewing 阶段产出的最终生成内容，nullable：失败轮次可能无生成内容）
  final String? generatedText;

  /// 生成关键词列表（generating 阶段产出的检索关键词，可能为空）
  final List<String> extractedKeywords;

  /// 检索到的经历类记忆列表（retrieved 阶段产出，可能为空）
  final List<ExperientialMemory> retrievedMemories;

  /// 检索到的事实类命中列表（retrieved 阶段产出，DOC-11 §6.1）
  ///
  /// 事实层启用时由 FactContextBuilder 产出，每个 [RetrievedFact] 包含
  /// 实体 + 属性快照。事实层未启用时为空列表。
  /// UI 检索面板据此展示【世界设定】分区。
  final List<RetrievedFact> retrievedFacts;

  /// 最终回复正文（reviewing 阶段产出，nullable：失败轮次可能无回复）
  ///
  /// 四步重构新增：与 [generatedText] 区分，reviewing 产出的最终回复独立持久化。
  final String? replyText;

  /// 事件摘要（summarizing 阶段产出，nullable：失败轮次可能无摘要）
  ///
  /// 四步重构新增：summarizing 独立步骤产出的结构化事件摘要。
  final EventSummary? eventSummary;

  /// 本轮事实层变更记录（summarizing 产出、persisting 应用后的快照）
  ///
  /// 每条 [FactsChangeRecord] 携带实体名/类型/属性名（来自 LLM 意图）与
  /// 变更前/变更后（来自审计记录），供「事实层变更小窗」展示。无变更或
  /// 事实层禁用时为空列表。
  final List<FactsChangeRecord> factsChanges;

  /// 导演模式本轮 agent 工具步骤（opencode 式时间线，v0.3 schemaVersion 40）
  ///
  /// 按执行顺序持久化，使历史轮次的工具卡在切换会话或重新进入时仍可见，
  /// 且生成中（running）与生成结束（done/error）共用同一条时间线结构。
  /// 故事模式（intermediate）恒为空列表。
  final List<AgentWorkStep> agentSteps;

  /// 导演模式本轮轮时间线（对话流计划 §4.2，schemaVersion 45）
  ///
  /// 思考/播报/动作三类块按真实发生顺序交错（与 agentSteps 兼容期双写）。
  /// UI 优先按此渲染单一折叠组；空列表（旧数据缺列）回退 agentSteps-only
  /// 渲染。故事模式恒为空列表。
  final List<AgentTimelineBlock> agentTimeline;

  /// 导演模式本轮工作摘要（体验重构 ，schemaVersion 41）
  ///
  /// 步数/总 token/总时长（含 LLM 等待时间），供历史轮次 L1 过程汇总行
  /// 与成本累计展示。故事模式恒为 null。
  final AgentWorkSummary? agentWorkSummary;

  /// 该轮结束时的剧情锚快照（体验重构卡片 C，schemaVersion 42）
  ///
  /// 本轮 update_story_anchor 更新值或继承值；幕间 Recap 卡数据源。
  /// 会话从未设锚时恒为 null。故事模式恒为 null。
  final StoryAnchor? storyAnchor;

  /// 本轮是否执行了 reviewing 阶段（v0.2.2 新增）
  ///
  /// `true` = 执行了审查（generating → reviewing → summarizing）
  /// `false` = 跳过了审查（generating → summarizing，生成即最终）
  ///
  /// UI 据此判断 idle 时是否显示 GeneratePanel：
  /// - `true`：显示生成面板（生成与回复内容不同，用户可对比）
  /// - `false`：不显示生成面板（生成即最终，重复显示无意义）
  final bool reviewExecuted;

  /// 当前变体指针（schemaVersion 49；null = 该轮单版本）
  ///
  /// 指向 message_variants.(session, turn, variant_index)；UI 变体切换器
  /// 的「n/m」中的 n-1。切换变体由持久层同事务改写本字段与
  /// chat_messages.content（当前变体物化）。
  final int? currentVariantIndex;

  /// 创建时间
  final DateTime createdAt;

  /// 序列化为 JSON（用于持久化到数据库 JSON 字段）
  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'turnNumber': turnNumber,
        'generatedText': generatedText,
        'extractedKeywords': extractedKeywords,
        'retrievedMemories': retrievedMemories.map((m) => m.toJson()).toList(),
        'retrievedFacts': retrievedFacts.map((f) => f.toJson()).toList(),
        'replyText': replyText,
        'eventSummary': eventSummary?.toJson(),
        'factsChanges': factsChanges.map((c) => c.toJson()).toList(),
        'agentSteps': AgentWorkStep.listToJsonString(agentSteps),
        'agentTimeline': agentTimeline.isEmpty
            ? null
            : AgentTimelineBlock.listToJsonString(agentTimeline),
        'agentWorkSummary': stringifyAgentWorkSummary(agentWorkSummary),
        'storyAnchor': StoryAnchor.stringify(storyAnchor),
        'reviewExecuted': reviewExecuted,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  /// 反序列化 agentWorkSummary 字段（数据库 TEXT 存储 JSON）
  static AgentWorkSummary? parseAgentWorkSummary(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return null;
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic>) return null;
      return AgentWorkSummary.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 序列化 agentWorkSummary 字段
  static String? stringifyAgentWorkSummary(AgentWorkSummary? summary) {
    return summary == null ? null : jsonEncode(summary.toJson());
  }

  /// 反序列化 extractedKeywords 字段（数据库 TEXT 存储 JSON 数组）
  static List<String> parseDraftKeywords(String jsonString) {
    if (jsonString.isEmpty) return const [];
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list.cast<String>();
  }

  /// 序列化 extractedKeywords 字段
  static String stringifyDraftKeywords(List<String> keywords) {
    return jsonEncode(keywords);
  }

  /// 反序列化 eventSummary 字段（数据库 TEXT 存储 JSON）
  static EventSummary? parseEventSummary(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return null;
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, dynamic>) return null;
    return EventSummary.fromJson(decoded);
  }

  /// 序列化 eventSummary 字段
  static String? stringifyEventSummary(EventSummary? summary) {
    return summary == null ? null : jsonEncode(summary.toJson());
  }

  /// 反序列化 factsChanges 字段（数据库 TEXT 存储 JSON 数组）
  static List<FactsChangeRecord> parseFactsChanges(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return const [];
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! List) return const [];
      return FactsChangeRecord.listFromJson(decoded);
    } catch (_) {
      return const [];
    }
  }

  /// 序列化 factsChanges 字段
  static String stringifyFactsChanges(List<FactsChangeRecord> changes) {
    return jsonEncode(FactsChangeRecord.listToJson(changes));
  }

  /// 返回一份将 [factsChanges] 替换为指定值的副本。
  ///
  /// 持久化时由 StoryPersistenceServiceImpl 调用：controller 构造本对象
  /// 时事实层尚未应用（[factsChanges] 为空），事务内应用事实层后用实际变更
  /// 记录补全，再写入 intermediate_round_artifacts 表，使历史轮次的变更小窗
  /// 切换会话后仍可展示变更前/变更后。
  ///
  /// [currentVariantIndex]：可选回写变体指针——
  /// 内存 artifacts 构造时该字段默认 null（DB 指针由 service 内 UPDATE
  /// 完成且不回传），重生成收稿后不回写会令切换器（要求指针非 null）
  /// 在重开会话前不可达。
  StoryRoundArtifacts copyWithFactsChanges(
    List<FactsChangeRecord> factsChanges, {
    int? currentVariantIndex,
  }) {
    return StoryRoundArtifacts(
      sessionId: sessionId,
      turnNumber: turnNumber,
      generatedText: generatedText,
      extractedKeywords: extractedKeywords,
      retrievedMemories: retrievedMemories,
      retrievedFacts: retrievedFacts,
      replyText: replyText,
      eventSummary: eventSummary,
      factsChanges: factsChanges,
      agentSteps: agentSteps,
      agentTimeline: agentTimeline,
      agentWorkSummary: agentWorkSummary,
      storyAnchor: storyAnchor,
      reviewExecuted: reviewExecuted,
      currentVariantIndex: currentVariantIndex,
      createdAt: createdAt,
    );
  }
}
