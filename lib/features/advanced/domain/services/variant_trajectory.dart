import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/trajectory_binding.dart';

/// 变体切换的轨迹处置规划（先生成身份、后正文内容）。
///
/// 判定次序：① 身份核对（目标变体的绑定 attemptId == 账本内该轮轨迹的
/// attemptId）→ ② 内容核对（目标正文散列 == 绑定留痕散列）。**双成立才
/// 保留轨迹**（=「切回生成该轨迹的原版」这一种情形）；其余（含同文不同
/// attempt——正文散列相等不证明工作来源）、身份缺失/绑定不全 → 一律
/// 遮蔽为单行；保守侧。绑定留痕不可变（生成事实），切换/编辑/重生成
/// 不重算旧绑定。

/// 轨迹遮蔽单行（模型可见；账本事件全保留仅投影替换）
const String kVariantMaskLine = '〔本轮经过版本切换，工作过程不再回放；正文以所示版本为准〕';

/// 切换处置结果
class VariantSwitchPlan {
  const VariantSwitchPlan({
    required this.turn,
    required this.retainTrajectory,
    required this.replaceStart,
    required this.replaceEnd,
    required this.replacement,
    this.ledgerAttemptId,
  });

  final int turn;

  /// ①∧② 双成立（保留原轨迹；replacement 为恢复原貌时非空）
  final bool retainTrajectory;

  /// 当前投影坐标 [replaceStart, replaceEnd)——surface 变更事件的目标
  /// 区间（无 surface 变更时区间退化、可忽略）
  final int replaceStart;
  final int replaceEnd;

  /// 替换消息数组（空 = 无需 surface 变更：保留且未遮蔽过的原版切换）
  final List<AgentMessage> replacement;

  /// 账本内该轮轨迹的尝试身份（诊断/审计）
  final String? ledgerAttemptId;

  /// 是否需要 surface 变更事件
  bool get needsSurfaceChange => replacement.isNotEmpty;
}

/// 规划变体切换的事件面处置。
///
/// [windowEvents] 为当前纪元窗事件（含既有 branch/rebuild 遮蔽与
/// replay/binding 留痕）；[targetBinding] 为目标变体的最新绑定
/// （null = 身份缺失，保守遮蔽）；[targetProse] 为目标变体正文。
///
/// 返回 null = 该轮在窗内无事件（如捕获区史前轮）——事件面无从处置，
/// 调用方仅记审计标记（chat 侧已按既有边界守卫）。
VariantSwitchPlan? planVariantSwitch({
  required List<AgentDurableEvent> windowEvents,
  required int turn,
  required TrajectoryBindingRecord? targetBinding,
  required String targetProse,
}) {
  // 基准事件集：剔除指向本轮的既有 branch/rebuild 遮蔽（restore 场景
  // 需要未被遮蔽的原貌投影）；审计标记（log-only 无 surfaceOp）天然无 span。
  final baseEvents = windowEvents
      .where(
        (e) => !(e.type == AgentEventTypes.branchRebuild &&
            e.data['turn'] == turn),
      )
      .toList();
  final baseFold = deriveAgentSurfaceSpans(baseEvents);

  // 定位基准投影中该轮的轨迹区间：从首个 assistant 事件的消息起，到该轮
  // 最后一条产生消息的事件止（u_j 与尾部注入属装配面，保留不遮蔽）。
  var maskStart = -1;
  var maskEnd = -1;
  String? ledgerAttemptId;
  var hasWorkMessages = false;
  for (final span in baseFold.spans) {
    if (span.from < 0) continue;
    final eventTurn = span.event.data['turn'];
    if (eventTurn is! int || eventTurn != turn) continue;
    final attempt = span.event.data['attemptId'];
    if (attempt is String && ledgerAttemptId == null) {
      ledgerAttemptId = attempt;
    }
    if (span.event.type == AgentEventTypes.assistantMessage ||
        span.event.type == AgentEventTypes.toolResult) {
      hasWorkMessages = true;
      if (maskStart < 0) maskStart = span.from;
      if (span.to > maskEnd) maskEnd = span.to;
    }
  }
  if (maskStart < 0 || maskEnd <= maskStart) {
    // 该轮在窗内无 assistant 轨迹（捕获区/史前轮/未落账）——无从处置。
    return null;
  }

  // ① 身份核对 + ② 内容核对（目标绑定缺任一字段即保守遮蔽）。
  final retain = targetBinding != null &&
      targetBinding.attemptId != null &&
      ledgerAttemptId != null &&
      targetBinding.attemptId == ledgerAttemptId &&
      trajectoryBindingHash(targetProse) == targetBinding.proseHash;

  final baseMessages = baseFold.projection.messages;

  // 当前（可能已被先前切换遮蔽的）投影区间。坐标空间以「当前」为准：
  // 遮蔽过 → 该轮现占区间 = 指向本轮的 branch/rebuild 替换 span 并集
  //（逐次遮蔽各自覆盖当时的轮区间，并集即当前占位）；未遮蔽 → 基准
  // 坐标即当前坐标（无替换改写）。
  final maskedBefore = windowEvents.any(
    (e) =>
        e.type == AgentEventTypes.branchRebuild &&
        e.surfaceOp == AgentSurfaceOpKind.replace &&
        e.data['turn'] == turn,
  );
  var currentStart = maskStart;
  var currentEnd = maskEnd;
  if (maskedBefore) {
    currentStart = -1;
    currentEnd = -1;
    final currentFold = deriveAgentSurfaceSpans(windowEvents);
    for (final span in currentFold.spans) {
      if (span.from < 0) continue;
      if (span.event.type != AgentEventTypes.branchRebuild) continue;
      if (span.event.data['turn'] != turn) continue;
      if (currentStart < 0 || span.from < currentStart) {
        currentStart = span.from;
      }
      if (span.to > currentEnd) {
        currentEnd = span.to;
      }
    }
    // 防御：遮蔽标记存在但无有效 span（坐标损坏）→ 退回基准坐标，
    // 替换区间非法时投影忽略、守卫兜底。
    if (currentStart < 0 || currentEnd <= currentStart) {
      currentStart = maskStart;
      currentEnd = maskEnd;
    }
  }

  if (retain) {
    // 保留轨迹：未遮蔽过 → 投影已含原轨迹与新正文（② 保证内容一致），
    // 无 surface 变更；遮蔽过 → 以原轨迹恢复（restore）。
    if (!maskedBefore) {
      return VariantSwitchPlan(
        turn: turn,
        retainTrajectory: true,
        replaceStart: maskStart,
        replaceEnd: maskEnd,
        replacement: const [],
        ledgerAttemptId: ledgerAttemptId,
      );
    }
    return VariantSwitchPlan(
      turn: turn,
      retainTrajectory: true,
      replaceStart: currentStart,
      replaceEnd: currentEnd,
      replacement: List.unmodifiable(baseMessages.sublist(maskStart, maskEnd)),
      ledgerAttemptId: ledgerAttemptId,
    );
  }

  // 遮蔽：〔遮蔽行? + 新正文〕替换轨迹区间（无工作消息的退化轮只换正文）。
  final replacement = <AgentMessage>[
    if (hasWorkMessages) AgentMessage.user(kVariantMaskLine),
    AgentMessage.assistant(text: targetProse),
  ];
  return VariantSwitchPlan(
    turn: turn,
    retainTrajectory: false,
    replaceStart: currentStart,
    replaceEnd: currentEnd,
    replacement: List.unmodifiable(replacement),
    ledgerAttemptId: ledgerAttemptId,
  );
}

/// 构造变体切换的 surface 替换事件（branch/rebuild，data.messages 携带
/// [plan] 的替换数组；审计信息随事件 data 落账）
AgentDurableEvent variantSwitchRebuildEvent(VariantSwitchPlan plan) {
  return AgentDurableEvent(
    type: AgentEventTypes.branchRebuild,
    surfaceOp: AgentSurfaceOpKind.replace,
    replaceStart: plan.replaceStart,
    replaceEnd: plan.replaceEnd,
    data: {
      'reason': 'variant-switch',
      'turn': plan.turn,
      'retain': plan.retainTrajectory,
      if (plan.ledgerAttemptId != null) 'ledgerAttemptId': plan.ledgerAttemptId,
      'messages': [
        for (final m in plan.replacement) agentMessageToSurfaceData(m),
      ],
    },
  );
}

/// 构造分支重建的审计标记（log-only；编辑/重生成/删轮的物理删除路径与
/// 变体切换的无 surface 变更路径共用）
AgentDurableEvent branchRebuildMarkerEvent({
  required String reason,
  required int turn,
  String? attemptId,
  int? variantIndex,
}) {
  return AgentDurableEvent(
    type: AgentEventTypes.branchRebuild,
    data: {
      'reason': reason,
      'turn': turn,
      if (attemptId != null) 'attemptId': attemptId,
      if (variantIndex != null) 'variantIndex': variantIndex,
    },
  );
}
