import 'dart:math' as math;

/// 上下文占用数值的可信度
enum ContextUsageProvenance {
  /// 端点/事件日志实报（最近一次主请求的完整输入）
  reported,

  /// 本地估算（含压缩/删除后的材料调整，或端点未上报）
  estimated,
}

/// 「当前预计上下文」快照（三模式共享契约）
///
/// 口径（2026-11-09 上下文数据可靠性第一批）：
/// - 主数字 = 下一次主请求的预计完整输入，不是"最近请求用量"；
/// - 锚点必须是实报的完整输入（reported），压缩/删除等本地材料变更
///   以材料 token 增量调整后降级为 estimated（UI 显示 ≈）；
/// - 无可用锚点时 tokens 为 null（UI 显示「—」），不得用 0 冒充。
class ContextUsageEstimate {
  const ContextUsageEstimate._({
    required this.tokens,
    required this.provenance,
    required this.updatedAt,
  });

  /// 无数据（删除/重建后尚未拿到可计量的材料）
  const ContextUsageEstimate.unknown()
      : this._(
          tokens: null,
          provenance: ContextUsageProvenance.estimated,
          updatedAt: null,
        );

  /// 最近一次主请求实报的完整输入
  factory ContextUsageEstimate.reported({
    required int? tokens,
    DateTime? at,
  }) {
    return ContextUsageEstimate._(
      tokens: tokens,
      provenance: ContextUsageProvenance.reported,
      updatedAt: at,
    );
  }

  /// 本地估算值
  factory ContextUsageEstimate.estimated({
    required int? tokens,
    DateTime? at,
  }) {
    return ContextUsageEstimate._(
      tokens: tokens,
      provenance: ContextUsageProvenance.estimated,
      updatedAt: at,
    );
  }

  /// 下一个主请求的预计输入（工具轮工作面校准）
  ///
  /// 最后一次请求的完整输入包含本轮临时工作面（工具结果、工具调用
  /// 消息），这些材料不会原样进入下一轮；首末请求输入之差即工作面
  /// 增量，扣除后回到本轮起始材料规模。落库回复由持久化阶段追加。
  factory ContextUsageEstimate.nextRoundFromTurn({
    required int? lastInputTokens,
    required int? firstInputTokens,
    DateTime? at,
  }) {
    if (lastInputTokens == null || lastInputTokens <= 0) {
      return const ContextUsageEstimate.unknown();
    }
    final first = firstInputTokens;
    final tokens = first != null && first > 0 && first < lastInputTokens
        ? first
        : lastInputTokens;
    return ContextUsageEstimate.estimated(tokens: tokens, at: at);
  }

  /// 压缩成功后的当前预计
  ///
  /// 口径：锚点 - 被移除材料 + 新增材料。
  /// - [tokensBefore] / [tokensAfter] 是压缩服务返回的**对话区**口径，
  ///   不含旧摘要（见 `CompactionResult.tokensBefore` 注释）；
  /// - 累积式压缩会替换旧摘要，[replacedSummaryTokens] 必须单列扣除，
  ///   否则旧摘要会残留在估算里；
  /// - 首次压缩无旧摘要时传 0。
  ///
  /// current 通常为最近请求实报；没有锚点时返回 unknown。
  factory ContextUsageEstimate.afterCompaction({
    required ContextUsageEstimate? current,
    required int tokensBefore,
    required int tokensAfter,
    int replacedSummaryTokens = 0,
    DateTime? at,
  }) {
    final base = current;
    if (base == null || base.tokens == null) {
      return const ContextUsageEstimate.unknown();
    }
    final next =
        base.tokens! - tokensBefore + tokensAfter - replacedSummaryTokens;
    return ContextUsageEstimate.estimated(
      tokens: math.max(0, next),
      at: at,
    );
  }

  final int? tokens;
  final ContextUsageProvenance provenance;
  final DateTime? updatedAt;

  bool get hasData => tokens != null;

  bool get isEstimated => provenance == ContextUsageProvenance.estimated;

  /// 本地材料变更（压缩/删除/插入）后的增量调整
  ///
  /// removedTokens 为移出请求面的材料 token，addedTokens 为新增材料
  /// （如压缩摘要）。调整后可信度降级为 estimated。
  ContextUsageEstimate shift({
    required int removedTokens,
    required int addedTokens,
    DateTime? at,
  }) {
    final base = tokens;
    if (base == null) return this;
    final next = base - removedTokens + addedTokens;
    return ContextUsageEstimate.estimated(
      tokens: math.max(0, next),
      at: at,
    );
  }

  @override
  String toString() =>
      'ContextUsageEstimate(tokens: $tokens, provenance: ${provenance.name})';
}
