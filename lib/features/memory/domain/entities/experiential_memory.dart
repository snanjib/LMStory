import 'dart:convert';

import 'package:meta/meta.dart';

/// 记忆层级（DOC-10 §2.1）
///
/// - [micro]：每轮一条的微摘要，append-only
/// - [macro]：对若干相邻微摘要的聚合宏摘要，独立记录
enum MemoryLevel {
  micro,
  macro;

  /// 从数据库字符串解析
  static MemoryLevel fromString(String value) {
    switch (value) {
      case 'macro':
        return MemoryLevel.macro;
      case 'micro':
      default:
        return MemoryLevel.micro;
    }
  }

  /// 序列化为数据库字符串
  String toDbString() => name;
}

/// 宏摘要触发原因（DOC-10 §2.2）
enum MacroTriggerReason {
  /// LLM 判断事件结束
  eventEnd,

  /// 固定轮次兜底
  roundLimit,

  /// CompactionPoint 触发（总占用超 compactionTriggerRatio 时压缩）
  ///
  /// 压缩摘要兼任宏摘要功能：将旧对话压缩为一段剧情摘要，
  /// 既作为 generating 的稳定前缀（提升 LLM 缓存命中率），
  /// 又作为宏摘要留档（memory_level=macro，importance=3，
  /// 参与语义检索，标注为"段落摘要"）。
  compaction;

  /// 从数据库字符串解析
  static MacroTriggerReason? fromString(String? value) {
    if (value == null) return null;
    switch (value) {
      case 'event_end':
        return MacroTriggerReason.eventEnd;
      case 'round_limit':
        return MacroTriggerReason.roundLimit;
      case 'compaction':
        return MacroTriggerReason.compaction;
      default:
        return null;
    }
  }

  /// 序列化为数据库字符串
  String toDbString() {
    switch (this) {
      case MacroTriggerReason.eventEnd:
        return 'event_end';
      case MacroTriggerReason.roundLimit:
        return 'round_limit';
      case MacroTriggerReason.compaction:
        return 'compaction';
    }
  }
}

/// 经历类记忆（v0.2 中级模式核心实体）
///
/// 对应 `experiential_memories` 表（DOC-02 §6.2、DOC-10 §3.1）。
/// 中级模式字段恒值约束（DOC-09A-1 §1.5）：
/// - narrativeTime 由 summarizing 阶段 LLM 输出（v0.2 叙事时间机制启用，2026-07-25）
/// - narrativePeriod 恒为 NULL（v0.3 启用）
/// - isArchived / isSummary 恒为 FALSE（v0.3 归档机制启用）
/// - hasEmbedding 由 embedding 生成结果决定
///
/// 多粒度记忆（DOC-10 v1.1）：
/// - [memoryLevel] 区分 micro/macro 两层记忆
/// - [parentEventIds] 仅 macro 有效，关联聚类的微摘要 ID 列表
/// - [macroTriggerReason] 仅 macro 有效，记录触发原因
///
/// 5W1E 字段（v0.2 Phase C 方案二，2026-07-19 新增）：
/// - when / where / who / what / significance / extra
/// - 所有字段 nullable，兼容旧数据
/// - 数据库列名为 when_text/where_text/who_text/what_text（避免 SQL 保留字），
///   实体字段名为 when/where/who/what，在 Repository 映射层转换
///
///  新增 `toJson` / `fromJson`：用于 intermediate_round_artifacts 表
/// 持久化检索结果列表（修复生成内容/检索过程消失问题，见 DOC-09A-1 §1.5 修订）。
@immutable
class ExperientialMemory {
  const ExperientialMemory({
    required this.memoryId,
    required this.sessionId,
    required this.importance,
    required this.tags,
    required this.turnNumber,
    required this.createdAt,
    this.summary,
    this.when,
    this.where,
    this.who,
    this.what,
    this.significance,
    this.extra,
    this.narrativeTime,
    this.narrativePeriod,
    this.isArchived = false,
    this.isSummary = false,
    this.hasEmbedding = false,
    this.memoryLevel = MemoryLevel.micro,
    this.parentEventIds,
    this.macroTriggerReason,
    this.source = 'auto',
    this.hasVerifiedSourceTurn = false,
  });

  /// 从 JSON 反序列化
  factory ExperientialMemory.fromJson(Map<String, dynamic> json) {
    return ExperientialMemory(
      memoryId: json['memoryId'] as String,
      sessionId: json['sessionId'] as String,
      importance: json['importance'] as int,
      tags: (json['tags'] as List<dynamic>).cast<String>(),
      turnNumber: json['turnNumber'] as int,
      summary: json['summary'] as String?,
      when: json['when'] as String?,
      where: json['where'] as String?,
      who: json['who'] as String?,
      what: json['what'] as String?,
      significance: json['significance'] as String?,
      extra: json['extra'] as String?,
      narrativeTime: json['narrativeTime'] as String?,
      narrativePeriod: json['narrativePeriod'] as String?,
      isArchived: json['isArchived'] as bool? ?? false,
      isSummary: json['isSummary'] as bool? ?? false,
      hasEmbedding: json['hasEmbedding'] as bool? ?? false,
      memoryLevel:
          MemoryLevel.fromString(json['memoryLevel'] as String? ?? 'micro'),
      parentEventIds:
          (json['parentEventIds'] as List<dynamic>?)?.cast<String>(),
      macroTriggerReason: MacroTriggerReason.fromString(
        json['macroTriggerReason'] as String?,
      ),
      source: json['source'] as String? ?? 'auto',
      hasVerifiedSourceTurn: json['hasVerifiedSourceTurn'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// 业务主键 UUID（非数据库自增 id，Repository 不暴露 dbId）
  final String memoryId;

  final String sessionId;

  /// 事件摘要文本（向后兼容字段，v0.2 Phase C 方案二降级为可选）
  ///
  /// 方案二之前：本字段是 LLM 唯一输出的事件描述（必填）。
  /// 方案二之后：LLM 改为输出 5W1E 6 字段，本字段可选。
  /// 旧数据仍以 summary 为主要载体；新数据 summary 可为 null。
  /// 展示文本统一使用 [displayText] getter。
  final String? summary;

  /// 5W1E：何时（叙事时间，非现实时间）
  final String? when;

  /// 5W1E：何地
  final String? where;

  /// 5W1E：何人（角色/主体）
  final String? who;

  /// 5W1E：何事（动作/对话/变化/状态）
  final String? what;

  /// 5W1E：为何重要（意义/影响/后果，Labov 评估模型）
  final String? significance;

  /// 5W1E：额外（兜底字段，无法归入上述字段的补充信息）
  final String? extra;

  /// 重要性 1-5
  final int importance;

  /// 标签列表
  final List<String> tags;

  /// 对话轮次序号
  final int turnNumber;

  /// 叙事时间（v0.2 叙事时间机制启用，2026-07-25，由 summarizing 阶段 LLM 输出）
  final String? narrativeTime;

  /// 叙事周期（v0.3 启用，中级模式恒 NULL）
  final String? narrativePeriod;

  /// 是否已归档（v0.3 启用，中级模式恒 FALSE）
  final bool isArchived;

  /// 是否为折叠摘要事件（v0.3 启用，中级模式恒 FALSE）
  final bool isSummary;

  /// 是否已生成向量
  final bool hasEmbedding;

  /// 记忆层级（DOC-10 §3.1）：默认 micro
  final MemoryLevel memoryLevel;

  /// 父事件 ID 列表（仅 macro 有效，DOC-10 §3.1）
  ///
  /// macro 记录关联的微摘要 memoryId 列表；micro 记录此字段为 null。
  final List<String>? parentEventIds;

  /// 宏摘要触发原因（仅 macro 有效，DOC-10 §3.1）
  final MacroTriggerReason? macroTriggerReason;

  /// 来源（v51）：'auto'=轮管线产物 / 'manual'=记忆库手动新增。
  /// 手动记忆不参与按 turn 窗的轮回滚清理（deleteExperienceByTurns）。
  final String source;

  /// 当前记忆可追溯到 [turnNumber] 对应的单轮输入和正文。
  final bool hasVerifiedSourceTurn;

  final DateTime createdAt;

  /// 是否为宏摘要记忆（便捷判断）
  bool get isMacro => memoryLevel == MemoryLevel.macro;

  /// 用于展示的文本（优先 summary，否则拼接 5W1E 字段）
  ///
  /// 与 EventSummary.displayText 逻辑一致。
  /// - 若 [summary] 非空：直接返回 summary
  /// - 否则：拼接 [what]/[who]/[when]/[where] 中非空字段（用 · 分隔）
  /// - 全部为空：返回 '(空事件)'
  /// 格式化展示文本。
  /// - 若 [summary] 非空：直接返回 summary
  /// - 否则：拼接 [what]/[who]/[when]/[where] 中非空字段（用 · 分隔）
  /// - 全部为空：返回 [emptyPlaceholder]
  String formatDisplayText({String emptyPlaceholder = '(空事件)'}) {
    if (summary != null && summary!.isNotEmpty) return summary!;
    final parts = <String>[
      if (what != null && what!.isNotEmpty) what!,
      if (who != null && who!.isNotEmpty) who!,
      if (when != null && when!.isNotEmpty) when!,
      if (where != null && where!.isNotEmpty) where!,
    ];
    if (parts.isEmpty) return emptyPlaceholder;
    return parts.join(' · ');
  }

  String get displayText => formatDisplayText();

  /// 序列化为 JSON（用于 intermediate_round_artifacts 表持久化）
  Map<String, dynamic> toJson() => {
        'memoryId': memoryId,
        'sessionId': sessionId,
        'importance': importance,
        'tags': tags,
        'turnNumber': turnNumber,
        if (summary != null) 'summary': summary,
        if (when != null) 'when': when,
        if (where != null) 'where': where,
        if (who != null) 'who': who,
        if (what != null) 'what': what,
        if (significance != null) 'significance': significance,
        if (extra != null) 'extra': extra,
        'narrativeTime': narrativeTime,
        'narrativePeriod': narrativePeriod,
        'isArchived': isArchived,
        'isSummary': isSummary,
        'hasEmbedding': hasEmbedding,
        'memoryLevel': memoryLevel.toDbString(),
        'parentEventIds': parentEventIds,
        'macroTriggerReason': macroTriggerReason?.toDbString(),
        'source': source,
        'hasVerifiedSourceTurn': hasVerifiedSourceTurn,
        'createdAt': createdAt.toIso8601String(),
      };

  /// 从 JSON 字符串列表反序列化（便捷方法）
  static List<ExperientialMemory> listFromJsonString(String jsonString) {
    final list = jsonDecode(jsonString) as List<dynamic>;
    return list
        .map((e) => ExperientialMemory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 序列化列表为 JSON 字符串（便捷方法）
  static String listToJsonString(List<ExperientialMemory> memories) {
    return jsonEncode(memories.map((m) => m.toJson()).toList());
  }
}
