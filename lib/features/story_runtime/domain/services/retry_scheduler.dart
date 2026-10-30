// RetryConfig 仍由 intermediate_config 提供（getMaxRetries 的配额来源）。
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/network/retry_policy.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';

/// 重试调度器（Phase 5 Step 5.3 提取）
///
/// 从 `IntermediateChatController` 提取的**纯决策逻辑**：
/// - 按错误码查询最大重试次数（[getMaxRetries]）
/// - 正常阶段 → 重试阶段映射（[toRetryPhase]）
/// - 计算重试延迟（[retryDelay]）
///
/// **职责边界**：
/// - 本类无状态、无副作用（`const` 构造），只提供决策与纯数据变换
/// - 重试的**编排**（设置 state、延迟等待、降级标志、重跑阶段）留在控制器
///   （需访问 state / `_round` / 降级标志 / 阶段方法）
/// - 故事专属的阶段流式产物清理（resetPhaseState，依赖 IntermediateChatState）
///   留在 intermediate 的 retry part，不进共享层
///
/// 详见 DOC-09A-2 §6.2（自动重试）、DOC-09B §9（错误码重试配置）。
///
/// E011/E015 为幽灵码（V2 四步重构后
/// generating/reviewing 纯文本输出，不再产生；格式错误由 E013/E017 覆盖），
/// 其重试配额/延迟映射与 V1 遗留的 strictFormatReminder 已删除。
class RetryScheduler {
  const RetryScheduler();

  /// 按错误码查询最大重试次数（DOC-09B §9 + DOC-09A-2 §6.2）
  ///
  /// 返回值 = 额外重试次数（不含首次尝试）。
  /// E018 持久化失败不可重试（事务回滚）。
  int getMaxRetries(String errorCode, RetryConfig? retry) {
    final r = retry ?? const RetryConfig();
    switch (errorCode) {
      case 'E010':
        return r.generatingMaxRetries;
      case 'E012':
        return r.retrievalMaxRetries;
      case 'E013':
        return r.extractingMaxRetries;
      case 'E014':
        return r.reviewingMaxRetries;
      case 'E016':
        return r.streamInterruptRetry;
      case 'E017':
        return r.summarizingMaxRetries;
      case 'E018':
        return 0; // 持久化失败不可重试（事务回滚）
      // 2026-07-21 新增：E104 = embedding 调用失败，本质属检索阶段失败，
      // 复用 retrievalMaxRetries（与 E012 一致）。限流场景由 ErrorCategory
      // 区分，但自动重试次数同 E104 错误码统一管理。
      case 'E104':
        return r.retrievalMaxRetries;
      default:
        return 0;
    }
  }

  /// 正常阶段 → 重试阶段映射
  IntermediatePhase toRetryPhase(IntermediatePhase phase) {
    switch (phase) {
      case IntermediatePhase.generating:
        return IntermediatePhase.generatingRetry;
      case IntermediatePhase.extracting:
        return IntermediatePhase.extractingRetry;
      case IntermediatePhase.retrieving:
        return IntermediatePhase.retrievingRetry;
      case IntermediatePhase.reviewing:
        return IntermediatePhase.reviewingRetry;
      case IntermediatePhase.summarizing:
        return IntermediatePhase.summarizingRetry;
      // compacting 失败映射 E018（0 次重试），不会走到 *Retry 阶段。
      // 此处与不可重试阶段一起返回 failed（逻辑上不可达，仅为 switch 完备性）。
      case IntermediatePhase.compacting:
      case IntermediatePhase.idle:
      case IntermediatePhase.generatingRetry:
      case IntermediatePhase.extractingRetry:
      case IntermediatePhase.retrievingRetry:
      case IntermediatePhase.reviewingRetry:
      case IntermediatePhase.summarizingRetry:
      case IntermediatePhase.persisting:
      case IntermediatePhase.failed:
        return IntermediatePhase.failed;
    }
  }

  /// 计算重试延迟（2026-10-15 批 E 改读共享 [RetryPolicy]）
  ///
  /// 故事错误码 → 共享语义码映射后走统一退避：格式类（E013/E017/
  /// EMPTY/FORMAT）立即重试零退避；流中断（E016）与服务端/未知类指数
  /// 退避（500ms 起封顶 15s + ±25% jitter）；限流带服务端冷却指示
  /// （[retryAfter]）精确遵守（封顶 60s 不加 jitter，重发不早于指示值）。
  ///
  /// [roll] ∈ [0,1) 可注入（测试确定性），缺省随机。
  Duration retryDelay(
    String errorCode, {
    Duration? retryAfter,
    double Function()? roll,
    RetryPolicy policy = const RetryPolicy(),
  }) {
    return policy.delayFor(
      semantic: semanticCodeOf(errorCode),
      attempt: 1,
      retryAfter: retryAfter,
      roll: roll?.call(),
    );
  }

  /// 故事 E0xx 错误码 → 共享语义码（退避口径映射；判定仍由
  /// [getMaxRetries] 的阶段键控制次数，两轴分离）
  static String semanticCodeOf(String errorCode) {
    switch (errorCode) {
      case 'E013': // 关键词提取格式错误
      case 'E017': // 事件摘要格式错误
        return 'FORMAT_ERROR';
      case 'E016': // 流中断
        return 'STREAM_ERROR';
      case 'E010': // 生成失败（服务端/网络混合，按通用指数退避）
      case 'E012': // 检索失败
      case 'E014': // 审查失败
        return 'SERVER';
      case 'E104': // embedding 失败（限流子场景由 retryAfter 承载）
        return 'SERVER';
      default:
        return 'unknown';
    }
  }
}
