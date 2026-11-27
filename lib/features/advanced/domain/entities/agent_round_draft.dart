import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';

/// 导演轮内所处阶段（普通轮始终为 [writing]；大周期轮完成任务一后切 [maintenance]）
enum AgentRoundPhase { writing, maintenance }

/// Agent 轮草稿区（事务边界内的暂存，设计报告 §7.8）
///
/// 一切写工具（update_facts / record_event_memory）在轮进行中只写草稿；
/// `finish_round` 时由控制器在单一 drift 事务内提交（persistRound）。
/// 取消/失败不留 partial final state——草稿随轮丢弃。
class AgentRoundDraft {
  AgentRoundDraft({required this.turnNumber});

  /// 本轮序号（1-based；提交时写 EventSummary.turnNumber 与事实 history）
  int turnNumber;

  /// 事实变更草稿（提交时经 FactApplier.applyDeltas 落库，全部守护生效）
  final List<FactsDelta> factsDeltas = [];

  /// 暂存时点的属性基底快照（审批基底变化检测）
  ///
  /// key = `entityId|attrKey`（经 normalizeAttrKey 归一），value = 首次暂存
  /// 该属性的 DB 当前 auto 行值（null = 当时无行）。提交时比对当前值：
  /// 暂存（审批预览）之后被其他路径改动过的基底不静默覆盖——命中漂移的
  /// update_attr delta 被剔除并留痕。clear_pending/replace_pending 与
  /// [factsDeltas] 同步清空。
  final Map<String, String?> factBaseSnapshots = {};

  /// 事件记忆草稿（5W1E；未调用 record_event_memory 时由控制器兜底合成）
  EventSummary? eventSummary;

  /// 检索命中快照（供轮次产物 artifacts 展示/审计）
  final List<RetrievedFact> retrievedFacts = [];
  final List<ExperientialMemory> retrievedMemories = [];

  /// finish_round 的 prose 参数写入的正文（正文交付契约 §2.1：唯一写入方
  /// 是 FinishRoundTool 的 prose 参数，围栏剥离后、闸门检查前落笔；
  /// null = 本轮尚未经工具交付正文）
  String? explicitReply;

  /// 完稿 lint 定向重写已用掉一次（体验重构 ：只重写一次，二次放行并记录审计）
  bool styleRewriteUsed = false;

  /// 本轮完稿 lint 最终违规数（风格漂移监测留痕；finish_round 每次
  /// lint 后覆盖——定向重写后为终值；自然收尾兜底 lint 同写。null = 本轮
  /// 未过 lint）。轮末随 AgentWorkSummary 落库。
  int? styleLintHits;

  /// 本轮实际调用过的工具名（终审闸门的检索覆盖判定；运行期暂存，不持久化）
  final Set<String> calledTools = {};

  /// merge_entities 同 source 归并请求计数（幂等回执；运行期暂存，
  /// 不持久化）。挂在 draft 而非工具实例字段：update_facts 的
  /// clear_pending/replace_pending 清空暂存时必须连它一起清（
  /// 2026-09-15）——否则清空后对同一 source 的合法重归并
  /// 被残留计数误报「已暂存过」，归并意图静默丢失（的姊妹面）。
  final Map<String, int> mergeRequestCounts = {};

  /// 检索覆盖闸门已用掉一次性豁免（防拒绝死循环）
  bool retrievalGateUsed = false;

  /// 事件记忆提醒已用掉一次性豁免
  bool eventMemoryGateUsed = false;

  /// 伏笔对账提醒已用掉一次性豁免（清点轮 finish_round 首次拦截后置位，
  /// 二次提交放行；与 eventMemoryGateUsed 同构）
  bool foreshadowGateUsed = false;

  /// 当前轮内所处阶段（普通轮始终为 writing；大周期轮完成任务一后切 maintenance）
  AgentRoundPhase phase = AgentRoundPhase.writing;

  /// 本轮是否启用大周期双任务接力（任务一正文 → 任务二周期审查与维护）
  bool isMajorReviewRound = false;

  /// 切入 maintenance 阶段后是否已调用过查/改/锚/事件工具
  bool maintenanceCheckedOrUpdated = false;

  /// 维护收尾门控一次性豁免（首次未巡检即调用 finish_maintenance 时置位）
  bool maintenanceGateUsed = false;

  /// 周期审查与维护是否已通过 finish_maintenance 正式完成
  bool maintenanceCompleted = false;

  /// 剧情锚草稿（体验重构卡片 C：update_story_anchor 写入，提交时落库；
  /// null = 本轮未更新，持久化时继承会话当前锚）
  StoryAnchor? storyAnchor;

  /// 本轮已实际发出的 ask_user 次数（：每轮最多 2 次的强制计数）
  int askUserUsed = 0;

  /// 本轮收集的检索关键词（artifacts.extractedKeywords）
  final List<String> searchQueries = [];

  bool get hasPendingWrites => factsDeltas.isNotEmpty || eventSummary != null;
}
