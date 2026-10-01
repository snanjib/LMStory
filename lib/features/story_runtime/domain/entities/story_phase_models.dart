// 故事运行时共享状态机原语（P2 解耦：从 intermediate_chat_state.dart 上移）。
//
// IntermediatePhase / FailureContext / ErrorCategory 为故事模式与导演模式
// 共用的阶段、失败上下文与错误分类。intermediate_chat_state.dart 经
// export 垫片保持原有引用路径兼容。

import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart'
    show RoundContext;

/// 故事模式生成阶段（DOC-09B §7.1）
///
/// v0.2.2 六步流程：compacting? → extracting → retrieving → generating → reviewing? → summarizing → persisting
/// 其中 compacting 与 reviewing 为可选阶段（compacting 条件触发，reviewing 由
/// `reviewEnabled` 配置控制）。每个正常阶段对应一个重试状态（启用自动重试）。
///
/// `compacting`：总占用 token 超过压缩触发线（compactionTriggerRatio）
/// 时触发，将旧对话压缩为摘要作为稳定前缀注入 generating。位于 extracting 之前
/// （是六步流程的最前置可选阶段）。失败走三选项失败处理（E018）。
enum IntermediatePhase {
  idle,

  /// CompactionPoint 压缩阶段（extracting 之前）
  ///
  /// 当原文区 token 超过上限时触发，将旧对话压缩为摘要。
  /// 产出 [RoundContext.compactionSummary]，作为稳定前缀注入 generating。
  /// 失败映射 E018（持久化/压缩失败），走三选项失败处理。
  compacting,
  generating,
  generatingRetry,
  extracting,
  extractingRetry,
  retrieving,
  retrievingRetry,
  reviewing,
  reviewingRetry,
  summarizing,
  summarizingRetry,
  persisting,
  failed,
}

/// 失败上下文（DOC-09B §9）
///
/// 携带错误码、失败阶段、用户可见提示、是否可重试。
class FailureContext {
  const FailureContext({
    required this.errorCode,
    required this.failedPhase,
    required this.errorMessage,
    required this.retryable,
    this.errorCategory = ErrorCategory.unknown,
    this.httpStatus,
    this.rawError,
    this.suggestionOverride,
  });

  /// 错误码 E010-E018（DOC-09B §9）
  final String errorCode;

  /// 失败阶段
  final IntermediatePhase failedPhase;

  /// 用户可见的错误提示
  final String errorMessage;

  /// 是否可重试（手动重试；自动重试用尽后仍为 true，用户可手动整轮重试）
  final bool retryable;

  /// 错误分类：用于 UI 分层展示和统计。
  /// 默认 unknown，由失败分类器在 _fail 时填充。
  final ErrorCategory errorCategory;

  /// HTTP 状态码：网络/服务器错误时携带，便于 UI 展示具体状态。
  /// 非 HTTP 错误（如格式异常、配置缺失）为 null。
  final int? httpStatus;

  /// 原始异常信息：异常 toString 截断前 2000 字符。
  /// 供技术用户诊断；UI 在"查看详情"中展示。
  ///
  /// 截断长度演变： 初版 500 字符； 放宽到 2000 字符
  /// （堆栈信息通常 > 500 字符，500 截断后丢失关键调用链）。
  final String? rawError;

  /// 建议操作覆盖文案。
  ///
  /// 空值时 UI 按 errorCategory 取通用建议；非空时优先展示。用于
  /// errorCategory 粒度不够的场景——如导演主模型未配置（E010+config），
  /// 通用「前往设置配置 API 供应商和模型」无法指向真正的修复入口，
  /// 需要按报点给出模式专属路径。仅影响展示，不写入失败日志。
  final String? suggestionOverride;
}

/// 错误分类
///
/// 用于 UI 分层展示：不同类别对应不同用户建议和操作指引。
/// 由失败分类器根据异常类型和 HTTP 状态码推断。
enum ErrorCategory {
  /// 配置错误：未配置 API 供应商/模型/API Key、配置加载失败
  config,

  /// 网络错误：连接失败、DNS 解析失败、连接中断
  network,

  /// 认证错误：401 Unauthorized、403 Forbidden、API Key 无效
  auth,

  /// 限流错误：429 Too Many Requests
  rateLimit,

  /// 服务器错误：500/502/503/504 等服务端异常
  server,

  /// 超时错误：请求超时（区别于网络中断）
  timeout,

  /// 格式错误：JSON 解析失败、响应结构不符合预期
  format,

  /// 上下文超限（：prompt 超过模型上下文窗口——400+文案识别，
  /// 口径见 core/llm/context_overflow.dart；自动压缩重试仍超限后归此）
  contextOverflow,

  /// 持久化错误：数据库写入失败、消息保存失败
  persist,

  /// 未知错误：未归类
  unknown,
}
