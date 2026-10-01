import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';

/// 导演模式对 [ChatSession] 导演侧字段（maxSteps/toolPermissions/
/// maxDurationMinutes/retrievalOverrides）的语义化读写（.3 收口）。
///
/// 字段与 `chat_sessions` 表列**保留不动**（DB 映射在 chat 仓库与
/// story_runtime 持久化层）；本扩展仅收口导演侧的默认值回退语义。
/// 旧 watch_mode 列已由 tool_permissions（v44）取代，运行时无读取点。
extension DirectorSessionX on ChatSession {
  /// 每轮最大步数（会话列 NULL = 跟随全局 [globalMaxSteps] 当前值，由
  /// 调用方注入；0 = 无上限，语义同 AgentBudget.maxSteps）。
  /// 三口径统一——设置面板回显与 runner
  /// 预算读数都走本 getter，杜绝「?? 8」与全局默认值分裂。
  int effectiveMaxSteps(int globalMaxSteps) => maxSteps ?? globalMaxSteps;

  /// 会话工具权限（NULL/空/损坏 = 跟随全局 advanced.tools）
  Map<String, String>? get sessionToolPermissions =>
      ToolPermissions.fromJson(toolPermissions);

  /// 单轮时间预算分钟数（NULL = 跟随全局，由 tuning 兜底）
  int? get sessionMaxDurationMinutes => maxDurationMinutes;

  /// 会话剧情节奏档（NULL/非法值 = 跟随全局 advanced.narrative_pacing；
  /// 非法值容错仿 [sessionToolPermissions] 列语义）
  NarrativePacing? get sessionNarrativePacing =>
      NarrativePacing.tryFromConfigValue(narrativePacing);

  /// 会话「检索松紧度」快照（NULL/坏 JSON = 未物化，消费方回落
  /// search_story 内置默认值）
  RetrievalProfile? get sessionRetrievalProfile =>
      RetrievalProfile.tryDecode(retrievalOverrides);
}
