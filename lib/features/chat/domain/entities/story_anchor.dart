import 'dart:convert';

/// 剧情锚（体验重构卡片 C：长线伏笔/当前弧线的载体，AI 内部维护）
///
/// 无大纲原则的边界产物：锚是世界状态的"将来时"快照（当前弧线/未兑现
/// 伏笔/叙事时间/一句主线进展），只由 AI 经 update_story_anchor 工具维护，
/// 用户无编辑入口。数据可见于幕间 Recap 卡（一行书脊形态，点击展开）
/// 与记忆浏览器。
class StoryAnchor {
  const StoryAnchor({
    required this.updatedTurn,
    this.arc,
    this.foreshadows = const [],
    this.narrativeTime,
    this.oneLiner,
  });

  factory StoryAnchor.fromJson(Map<String, dynamic> json) {
    return StoryAnchor(
      updatedTurn: (json['updatedTurn'] as num?)?.toInt() ?? 0,
      arc: json['arc'] as String?,
      foreshadows: (json['foreshadows'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(AnchorForeshadow.fromJson)
              .toList() ??
          const [],
      narrativeTime: json['narrativeTime'] as String?,
      oneLiner: json['oneLiner'] as String?,
    );
  }

  /// 当前弧线（本段剧情的主线张力）
  final String? arc;

  /// 伏笔清单（含兑现状态）
  final List<AnchorForeshadow> foreshadows;

  /// 叙事时间锚点（故事内时间）
  final String? narrativeTime;

  /// 一句主线进展（幕间 Recap 卡的书脊文案）
  final String? oneLiner;

  /// 最近一次更新的轮次号
  final int updatedTurn;

  /// 未兑现伏笔
  List<AnchorForeshadow> get openForeshadows =>
      foreshadows.where((f) => !f.resolved).toList();

  bool get isEmpty =>
      (arc?.isEmpty ?? true) &&
      foreshadows.isEmpty &&
      (oneLiner?.isEmpty ?? true);

  Map<String, dynamic> toJson() => {
        'updatedTurn': updatedTurn,
        if (arc != null && arc!.isNotEmpty) 'arc': arc,
        if (foreshadows.isNotEmpty)
          'foreshadows': foreshadows.map((f) => f.toJson()).toList(),
        if (narrativeTime != null && narrativeTime!.isNotEmpty)
          'narrativeTime': narrativeTime,
        if (oneLiner != null && oneLiner!.isNotEmpty) 'oneLiner': oneLiner,
      };

  /// 从 story_anchor 列 JSON 解析（null/空/损坏返回 null）
  static StoryAnchor? parse(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return null;
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic>) return null;
      final anchor = StoryAnchor.fromJson(decoded);
      return anchor.isEmpty ? null : anchor;
    } catch (_) {
      return null;
    }
  }

  /// 序列化到 story_anchor 列（null 安全）
  static String? stringify(StoryAnchor? anchor) {
    if (anchor == null || anchor.isEmpty) return null;
    return jsonEncode(anchor.toJson());
  }

  StoryAnchor copyWith({
    String? arc,
    List<AnchorForeshadow>? foreshadows,
    String? narrativeTime,
    String? oneLiner,
    int? updatedTurn,
  }) {
    return StoryAnchor(
      arc: arc ?? this.arc,
      foreshadows: foreshadows ?? this.foreshadows,
      narrativeTime: narrativeTime ?? this.narrativeTime,
      oneLiner: oneLiner ?? this.oneLiner,
      updatedTurn: updatedTurn ?? this.updatedTurn,
    );
  }
}

/// 单条伏笔
class AnchorForeshadow {
  const AnchorForeshadow({required this.text, this.resolved = false});

  factory AnchorForeshadow.fromJson(Map<String, dynamic> json) {
    return AnchorForeshadow(
      text: json['text'] as String? ?? '',
      resolved: json['resolved'] as bool? ?? false,
    );
  }

  final String text;

  /// 已兑现
  final bool resolved;

  Map<String, dynamic> toJson() => {'text': text, 'resolved': resolved};
}
