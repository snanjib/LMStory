import 'dart:typed_data';

import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_round_runner.dart'
    show DirectorRoundRunner;
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';

/// [DirectorRoundRunner] 对宿主控制器的全部依赖面（P1 解耦）。
///
/// 原导演逻辑以 extension 形式寄生在 IntermediateChatController 的 9 个
/// part 文件里，直接访问主类私有成员。拆出为独立 runner 后，宿主（P1 为
/// IntermediateChatController，P2 起为 AdvancedChatController）实现本接口，
/// runner 只经此接口交互，不再触碰宿主私有实现。
///
/// 成员清单 = extension 实际访问的私有成员全集（决策日志 .1）：
/// state 读写、_round 身份、_streamRunner 取消标志、_logger、_fail、
/// _resolveQueryVector、_runPersistPhase、factual/experience/llm/
/// 事件日志/压缩服务等仓库依赖、历史回读（原 _ControllerStoryReader
/// 经 _chatRepository / _persistenceService 的两处读取）。
///
// TODO(decouple): [AdvancedChatState] / [RoundContext] /
/// [StoryCompactionService] / [StoryRoundArtifacts] 仍是
/// intermediate 类型——P2 拆分 AdvancedChatState 与 story_runtime 共享层后
/// 替换为各自归位后的类型。
abstract interface class DirectorHost {
  /// 状态读写桥接（宿主的 StateNotifier.state）。
  ///
  /// runner 是导演轮期间 state 的主要写入方（流式正文/步骤/HITL 横幅），
  /// 每次写入都经宿主状态机，保持与故事模式同一通知路径。
  AdvancedChatState get storyState;
  set storyState(AdvancedChatState value);

  /// 当前轮上下文（身份校验：cancel/recover 清空 _round 后旧轮须停走）。
  RoundContext? get currentRound;

  /// 流取消标志（用户停止 / 后台中断后为 true，runner 各检查点读取）。
  bool get isStreamCancelled;

  /// 日志。
  Logger get logger;

  /// 失败出口：分类 + 自动重试决策 + failed 状态机（故事侧同款）。
  Future<void> failRound(
    IntermediatePhase phase,
    String errorCode, {
    Object? error,
    ErrorCategory? errorCategory,
    StoryRuntimeConfig? config,
  });

  /// 持久化阶段（故事模式事务管线；导演产出写回 round 后复用）。
  Future<void> runPersistPhase(RoundContext round);

  /// 查询向量化（embedding 未配置 / 本轮降级时返回 null）。
  Future<Float32List?> resolveQueryVector(String queryText);

  // ── 仓库依赖（宿主构造注入，经 host 透出给 runner）──────────────────

  /// LLM 服务（AgentRunner 的网关出口）。
  LlmService get llmService;

  /// Agent 步骤的能力画像显式覆盖（Demo 作用域等受控环境注入；null 走生产默认解析）。
  ProviderToolCapabilities? get capabilitiesOverride;

  /// 经历记忆仓库（检索 + 宏摘要）。
  ExperienceRepository get experienceRepository;

  /// 事实层仓库（query_facts/update_facts；未注入时导演轮 E010）。
  FactualRepository? get factualRepository;

  /// agent 事件日志仓库（durable 日志 + 崩溃恢复；null = 未启用）。
  AgentEventLogStore? get agentEventLogRepository;

  /// 工程压缩事务服务（开启态轮前/溢出压缩；null = 不可用）
  EngineeringCompactionService? get engineeringCompactionService;

  /// CompactionPoint 压缩服务（导演轮轮前压缩；null = 未启用）。
  StoryCompactionService? get compactionService;

  // ── 历史回读（story reader 用，避免 runner 摸具体仓库实现）──────────

  /// 全量会话消息（未按 CompactionPoint 过滤；导演回读原文用）。
  Future<List<ChatMessage>> loadSessionMessages(String sessionId);

  /// 会话全部回合产物（turnNumber → artifacts）。
  Future<Map<int, StoryRoundArtifacts>> loadSessionArtifacts(
    String sessionId,
  );
}
