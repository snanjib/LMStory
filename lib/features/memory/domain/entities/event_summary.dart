import 'package:meta/meta.dart';

/// 事件摘要（v0.2 中级模式，LLM 输出结构，DOC-09B §8.1）
///
/// 由四步生成的 summarizing 步骤产出（工具调用或 JSON 模式解析）。
/// turnNumber 由程序填充（非 LLM 输出），基于会话当前轮次计数（S-10）。
///
/// 2026-07-17 修订（DOC-10 §4.1）：新增 `eventEnded` 字段，用于多粒度记忆触发判断。
///
/// 2026-07-19 修订（v0.2 Phase C 方案二）：扩展为 5W1E 6 字段结构
/// （when/where/who/what/significance/extra），原 `summary` 字段降级为
/// 向后兼容字段。新结构基于 Chatman 叙事学 + Bal 事件理论 + Labov 评估模型，
/// 适用于所有类型叙事（角色驱动/无角色/伏笔/无伏笔/抒情/议论等）。
/// 详见 DOC-09B §8.1 / DOC-10。
@immutable
class EventSummary {
  const EventSummary({
    required this.importance,
    required this.tags,
    required this.turnNumber,
    this.eventEnded = false,
    this.summary,
    this.when,
    this.where,
    this.who,
    this.what,
    this.significance,
    this.extra,
    this.narrativeTime,
  });

  /// 从 JSON 反序列化
  factory EventSummary.fromJson(Map<String, dynamic> json) => EventSummary(
        importance: json['importance'] as int,
        tags: (json['tags'] as List<dynamic>).cast<String>(),
        turnNumber: json['turnNumber'] as int,
        eventEnded: json['eventEnded'] as bool? ?? false,
        summary: json['summary'] as String?,
        when: json['when'] as String?,
        where: json['where'] as String?,
        who: json['who'] as String?,
        what: json['what'] as String?,
        significance: json['significance'] as String?,
        extra: json['extra'] as String?,
        narrativeTime: json['narrativeTime'] as String?,
      );

  /// 重要性 1-5（LLM 输出）
  final int importance;

  /// 标签数组（LLM 输出）
  final List<String> tags;

  /// 对话轮次序号（程序填充，非 LLM 输出）
  final int turnNumber;

  /// 本轮是否标志着当前事件结束（DOC-10 §4.1，LLM 输出）
  ///
  /// 用于多粒度记忆触发判断：
  /// - true：触发宏摘要生成（聚合本轮及之前未聚合的微摘要）
  /// - false：继续累积微摘要，等待后续触发
  final bool eventEnded;

  /// 事件摘要文本（向后兼容字段，v0.2 Phase C 方案二降级）
  ///
  /// 方案二之前：本字段是 LLM 唯一输出的事件描述（必填）。
  /// 方案二之后：LLM 改为输出 5W1E 6 字段，本字段可选，用于：
  /// - 向后兼容旧数据库行（迁移前已存的 experiential_memories）
  /// - LLM 顺手生成的一句话摘要（由提示词决定是否输出）
  /// - 历史小窗（SummarizePanel）的简短展示
  ///
  /// 新代码应优先使用 6 字段（[when]/[where]/[who]/[what]/[significance]/[extra]），
  /// 本字段仅作兜底。展示文本统一使用 [displayText] getter。
  final String? summary;

  // ==================== 5W1E 字段（v0.2 Phase C 方案二，2026-07-19 新增）====================

  /// 何时：事件发生的时间点（叙事时间，非现实时间）
  ///
  /// 通用性说明：所有叙事都有时序（即使是无角色、无情节的抒情文本也有
  /// "此刻"），因此本字段对所有叙事类型适用。
  /// 例：「次日清晨」「三年后」「战斗结束时」「此刻」
  /// 无明确时间信息时为 null 或空字符串。
  final String? when;

  /// 何地：事件发生的地点
  ///
  /// 通用性说明：地点是叙事的物理/心理容器，无物理场景时可填心理空间
  /// （如"回忆中""梦境里"）。
  /// 例：「森林深处」「王城广场」「船舱内」「回忆中」
  /// 无地点信息时为 null 或空字符串。
  final String? where;

  /// 何人：参与事件的角色/主体
  ///
  /// 通用性说明：无角色叙事（抒情、自然描写）中，主体可以是自然物或
  /// 抽象概念（"风""时间""孤独"）。
  /// 例：「勇者独自」「勇者与公主」「国王和卫兵」「风与海浪」
  /// 无主体信息时为 null 或空字符串。
  final String? who;

  /// 何事：事件的具体内容（动作、对话、变化、状态）
  ///
  /// 通用性说明：这是最核心的字段，所有叙事都有"被叙述的事"，无论是
  /// 动作（"斩杀巨龙"）、对话（"争吵"）、状态（"等待"）或描写（"雨落"）。
  /// 例：「斩杀了巨龙」「发现一封信」「争吵后决裂」「雨持续下着」
  /// 应尽量非空。
  final String? what;

  /// 为何重要：事件的意义、影响、后果
  ///
  /// 通用性说明：对应 Labov 评估模型（evaluation），无明确意义时可省略。
  /// 这不是必填字段，因为不是所有事件都有显著意义（有些只是过渡）。
  /// 例：「获得了关键道具」「改变了勇者的信念」「埋下伏笔」「气氛凝固」
  /// 无明确意义时为 null 或空字符串。
  final String? significance;

  /// 额外：无法归入上述字段的补充信息（兜底字段）
  ///
  /// 通用性说明：5W1E 不能覆盖所有可能的叙事要素（如氛围、感官细节、
  /// 风格特征），本字段作为兜底保留 LLM 认为重要但不属于 5W1 的细节。
  /// 例：「天气骤变，雷声大作」「伴有奇怪的香味」「叙述视角切换为第二人称」
  /// 无补充信息时为 null 或空字符串。
  final String? extra;

  /// 绝对叙事时间（v0.2 叙事时间机制，2026-07-25 新增）
  ///
  /// 由 LLM 在 summarizing 阶段输出的绝对故事内时间（如"来公寓第三天"）。
  ///
  /// 与 [when] 字段的区别：
  /// - [when] 是事件的相对时间描述（如"次日清晨""三年后"），用于单条事件定位
  /// - [narrativeTime] 是绝对时间锚点，每轮更新后会写入会话状态
  ///   （`ChatSession.currentNarrativeTime`），作为下一轮生成的上下文
  ///
  /// 非空时，控制器会将其 upsert 到 `chat_sessions.current_narrative_time`，
  /// 作为会话级当前叙事时间状态。null 表示本轮未输出叙事时间，保留原状态。
  final String? narrativeTime;

  /// 用于展示的文本（优先 summary，否则拼接 6 字段）
  ///
  /// 历史小窗、日志等需要一句话展示时使用。
  /// - 若 [summary] 非空：直接返回 summary
  /// - 否则：拼接 [what]/[who]/[when]/[where] 中非空字段（用 · 分隔）
  /// - 全部为空：返回 '(空事件)'
  String get displayText {
    if (summary != null && summary!.isNotEmpty) return summary!;
    final parts = <String>[
      if (what != null && what!.isNotEmpty) what!,
      if (who != null && who!.isNotEmpty) who!,
      if (when != null && when!.isNotEmpty) when!,
      if (where != null && where!.isNotEmpty) where!,
    ];
    if (parts.isEmpty) return '(空事件)';
    return parts.join(' · ');
  }

  /// 序列化为 JSON（用于 intermediate_round_artifacts 持久化）
  ///
  /// 仅序列化非空字段，避免污染持久化数据。
  /// importance/tags/turnNumber/eventEnded 总是序列化（必填/有默认值）。
  Map<String, dynamic> toJson() => {
        'importance': importance,
        'tags': tags,
        'turnNumber': turnNumber,
        'eventEnded': eventEnded,
        if (summary != null) 'summary': summary,
        if (when != null) 'when': when,
        if (where != null) 'where': where,
        if (who != null) 'who': who,
        if (what != null) 'what': what,
        if (significance != null) 'significance': significance,
        if (extra != null) 'extra': extra,
        if (narrativeTime != null) 'narrativeTime': narrativeTime,
      };
}
