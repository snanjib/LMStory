import 'dart:convert';

/// 导演会话「检索松紧度」快照。
///
/// 快照语义（配置语义铁律）：三档各自持有**具体值**，选中即把该档的
/// 具体值写入会话列（chat_sessions.retrieval_overrides JSON），此后与
/// 任何全局/预设定义互不影响——改档位预设不追溯旧会话。
/// 「平衡」档即当前全局行为的具体快照（search_story 默认 topK=8、
/// 不设向量质量阈值）。
///
/// 消费点：search_story 工具（经 AgentToolDeps.retrievalProfile 注入）——
/// topK 作为模型未传 top_k 时的默认值；vectorScoreThreshold 传入混合检索
/// 的向量质量过滤（null/缺失 = 仓库默认 0.0，不过滤）。
///
/// 解码宽容：JSON 缺键 → 该项为 null → 消费方回落自己的默认值；
/// 未知键忽略。坏 JSON 由仓库映射层降级为 null（对齐 toolPermissions）。
class RetrievalProfile {
  const RetrievalProfile({this.topK, this.vectorScoreThreshold});

  factory RetrievalProfile.fromJson(Map<String, dynamic> json) =>
      RetrievalProfile(
        topK: json['top_k'] is int ? json['top_k'] as int : null,
        vectorScoreThreshold: json['vector_score_threshold'] is num
            ? (json['vector_score_threshold'] as num).toDouble()
            : null,
      );

  /// 保守：少而准——更少的返回条数 + 过滤低分向量命中
  static const RetrievalProfile conservative = RetrievalProfile(
    topK: 5,
    vectorScoreThreshold: 0.55,
  );

  /// 平衡：当前全局行为的具体快照（topK=8、不过滤）
  static const RetrievalProfile balanced = RetrievalProfile(
    topK: 8,
    vectorScoreThreshold: 0,
  );

  /// 宽松：多而广——更多返回条数、不过滤
  static const RetrievalProfile loose = RetrievalProfile(
    topK: 12,
    vectorScoreThreshold: 0,
  );

  /// 三档清单（UI 顺序：保守/平衡/宽松）
  static const List<RetrievalProfile> tiers = [
    conservative,
    balanced,
    loose,
  ];

  /// search_story 缺省返回条数（模型未显式传 top_k 时生效）
  final int? topK;

  /// 向量命中质量过滤阈值（0 = 不过滤）
  final double? vectorScoreThreshold;

  /// 同档判定（同一具体值组合视为同档，用于选中态回显）
  bool sameAs(RetrievalProfile other) =>
      topK == other.topK && vectorScoreThreshold == other.vectorScoreThreshold;

  Map<String, dynamic> toJson() => {
        if (topK != null) 'top_k': topK,
        if (vectorScoreThreshold != null)
          'vector_score_threshold': vectorScoreThreshold,
      };

  String encode() => jsonEncode(toJson());

  /// 从 JSON 字符串解码；坏 JSON / 非对象返回 null（仓库映射层降级口径）
  static RetrievalProfile? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return RetrievalProfile.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }
}
