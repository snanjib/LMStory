import 'dart:async';

import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/context_overflow.dart';
import 'package:lmstory/core/llm/model_unavailability.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/entities/stream_failure.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式失败分类器。
///
/// 纯 Domain 层工具：将原始异常自动分流为 [ErrorCategory]，
/// 并提供 i18n 通俗提示文案和建议操作文案。
///
/// 设计要点：
/// - [classifyError] 接收已知公开异常类型（[AppHttpException] /
///   [TimeoutException] / 网关归一后的 [AgentLlmException]）；
///   私有类型 `_StreamErrorException` 按其 `toString()` 含 "StreamError"
///   字符串特征识别为 network（不改类可见性）。
/// - [resolveFailureMessage] 按 errorCode 提供阶段化通俗提示（E010 配置、
///   E012 检索…），保留"发生了什么"的上下文。
/// - [resolveSuggestion] 按 category 提供行动建议（"检查网络"…），传达"该怎么做"。
///
/// 使用方式：
/// ```dart
/// final (category, httpStatus, rawError) = classifyError(e);
/// final message = resolveFailureMessage(errorCode, category);
/// / suggestion 由 UI 层调 resolveSuggestion 获取
/// ```
class StoryFailureClassifier {
  const StoryFailureClassifier();

  /// 将原始异常分流为 (错误分类, HTTP 状态码, 原始异常文本)。
  ///
  /// 分流规则（DOC-09B §9）：
  /// - [AppHttpException]：
  ///   - 401/403 → auth
  ///   - 429 → rateLimit
  ///   - 5xx → server
  ///   - 其他 4xx → server
  ///   - code `connection_timeout`/`receive_timeout`/`send_timeout` → timeout
  ///   - code `connection_error` → network
  /// - [TimeoutException]（dart:async）→ timeout
  /// - [AgentLlmException]（导演 agent loop 网关归一产物）：按 semantic /
  ///   code / statusCode 分流；`BAD_REQUEST`/400 → request（确定性请求错误）
  /// - `_StreamErrorException`（toString 含 "StreamError"）→ network
  /// - 其他 → unknown
  ///
  /// `rawError` 为异常 `toString()` 截断前 2000 字符，供技术用户诊断。
  ///
  /// 截断长度演变： 初版 500 字符； 放宽到 2000 字符
  /// （堆栈信息通常 > 500 字符，500 截断后丢失关键调用链）。
  ({ErrorCategory category, int? httpStatus, String? rawError}) classifyError(
    Object error,
  ) {
    final ErrorCategory category;
    final int? httpStatus;

    if (error is AppHttpException) {
      httpStatus = error.statusCode;
      final status = error.statusCode;
      final code = error.code;
      // 超限识别在状态码分支之前——各家超限均为 400+文案，
      // 状态码判不出（口径=core/llm/context_overflow.dart 模式表）
      if (isContextOverflowText(
        '${error.message}${error.responseBody ?? ''}',
        code,
      )) {
        category = ErrorCategory.contextOverflow;
      } else if (status == 401 || status == 403) {
        category = ErrorCategory.auth;
      } else if (status == 429) {
        category = ErrorCategory.rateLimit;
      } else if (status != null && status >= 500) {
        category = ErrorCategory.server;
      } else if (status != null && status >= 400) {
        // 其他 4xx 归类为 server（客户端错误但非认证/限流，统一提示服务端异常）
        category = ErrorCategory.server;
      } else if (code == 'connection_timeout' ||
          code == 'receive_timeout' ||
          code == 'send_timeout') {
        category = ErrorCategory.timeout;
      } else if (code == 'connection_error') {
        category = ErrorCategory.network;
      } else {
        category = ErrorCategory.unknown;
      }
    } else if (error is TimeoutException) {
      httpStatus = null;
      category = ErrorCategory.timeout;
    } else if (error is StreamErrorException) {
      // 流式错误结构化识别——wire 层语义码优先（429→rateLimit、
      // 401/403→AUTH→auth、5xx→server），未识别语义码归 network；
      // 超限文案匹配优先于语义码归 network（同网关口径）
      httpStatus = null;
      if (isContextOverflowText(error.message, error.code)) {
        category = ErrorCategory.contextOverflow;
      } else if (isModelUnavailableText(error.message)) {
        // 上游网关在模型下线/无可用通道时返回 400+文案
        //（如 AG "Upstream request failed: Model is unavailable"），网络
        // 正常——归 network 会误导用户排查 Wi-Fi，按 server 提示等待/换模型
        category = ErrorCategory.server;
      } else {
        // 审查收官 ：部分供应商流内 error 块的 code 是数字字符串
        //（'429'/'401'，sse_parser 的 rawCode?.toString() 原样保留）——
        // 补数字形态映射，避免限流被归 network（建议文案误导）
        switch (error.code) {
          case 'RATE_LIMIT':
          case '429':
            category = ErrorCategory.rateLimit;
          case 'AUTH':
          case '401':
          case '403':
            category = ErrorCategory.auth;
          case 'SERVER':
          case '500':
          case '502':
          case '503':
          case '504':
            category = ErrorCategory.server;
          case 'BAD_REQUEST':
            // 400 请求体校验失败（如工具 schema 被供应商拒收）是确定性
            // 问题：归 network 会把用户引向排查 Wi-Fi；request 类别给出
            // 「调整模型/参数」的具体建议，而不是盲目重试。
            category = ErrorCategory.request;
          default:
            category = ErrorCategory.network;
        }
      }
    } else if (error is AgentLlmException) {
      // 导演 agent loop 的网关归一异常：wire 语义码/HTTP 状态码优先，
      // 文案兜底超限与模型不可用（两者均以 400 承载，状态码判不出）。
      httpStatus = error.statusCode;
      final code = error.code;
      final status = error.statusCode;
      if (error.semantic == AgentLlmErrorSemantic.contextOverflow ||
          isContextOverflowText(error.message, code)) {
        category = ErrorCategory.contextOverflow;
      } else if (isModelUnavailableText(error.message)) {
        category = ErrorCategory.server;
      } else if (code == 'RATE_LIMIT' || code == '429' || status == 429) {
        category = ErrorCategory.rateLimit;
      } else if (code == 'AUTH' ||
          code == '401' ||
          code == '403' ||
          status == 401 ||
          status == 403) {
        category = ErrorCategory.auth;
      } else if (code == 'SERVER' || (status != null && status >= 500)) {
        category = ErrorCategory.server;
      } else if (code == 'BAD_REQUEST' || status == 400) {
        category = ErrorCategory.request;
      } else if (code == 'timeout' ||
          code == 'connection_timeout' ||
          code == 'receive_timeout' ||
          code == 'send_timeout') {
        category = ErrorCategory.timeout;
      } else if (code == 'connection_error') {
        category = ErrorCategory.network;
      } else {
        category = ErrorCategory.unknown;
      }
    } else if (error.toString().contains('StreamError')) {
      // 兜底：非本类型实例但 toString 带 StreamError 特征（旧路径/其他
      // 包装形态）→ network；：toString 含底层 400 文本时
      // 同样检测模型不可用特征
      httpStatus = null;
      category = isModelUnavailableText(error.toString())
          ? ErrorCategory.server
          : ErrorCategory.network;
    } else {
      httpStatus = null;
      category = ErrorCategory.unknown;
    }

    final rawError = _truncate(error.toString(), 2000);
    return (category: category, httpStatus: httpStatus, rawError: rawError);
  }

  /// 按 errorCode 返回通俗提示文案（"发生了什么"）。
  ///
  /// errorCode 对应阶段化语义（E010 配置、E012 检索…），保留上下文。
  /// 未知 errorCode 回退到 [ErrorCategory.unknown] 对应的通用文案。
  String resolveFailureMessage(String errorCode, ErrorCategory category) {
    final messages = t.intermediate.chat.failure.messages;
    // 超限专属文案优先于阶段码文案（自动压缩重试仍超限后的横幅）
    if (category == ErrorCategory.contextOverflow) {
      return messages.contextOverflow;
    }
    // E016 但分类为 request（400 参数/工具 schema 被拒）时
    // 不显示「网络中断」——请求是确定性问题，重发同载荷不会成功
    if (errorCode == 'E016' && category == ErrorCategory.request) {
      return messages.e016Request;
    }
    // E016 但分类为 server（上游 400「模型不可用」）时
    // 不显示「网络中断」——网络正常，误导排查方向
    if (errorCode == 'E016' && category == ErrorCategory.server) {
      return messages.e016Server;
    }
    switch (errorCode) {
      case 'E010':
        return messages.e010;
      // E011/E015 为幽灵码（V2 四步重构后
      // generating/reviewing 纯文本输出，不再产生），映射与文案已删除，
      // 落到 default 回退通用文案。格式错误由 E013/E017 覆盖。
      case 'E012':
        return messages.e012;
      case 'E013':
        return messages.e013;
      case 'E014':
        return messages.e014;
      case 'E016':
        return messages.e016;
      case 'E017':
        return messages.e017;
      case 'E018':
        return messages.e018;
      // 2026-07-21 新增：E104 = embedding 调用失败（限流是子场景，由
      // ErrorCategory.rateLimit 区分）。覆盖原 EmbeddingRateLimitedException
      // 的语义扩展，触发 FailureBar 弹出，用户可选重试/临时降级/中止。
      case 'E104':
        return messages.e104;
      default:
        return messages.unknown;
    }
  }

  /// 按 category 返回建议操作文案（"该怎么做"）。
  ///
  /// 由 UI 层在展示时调用，不存入 FailureContext。
  String resolveSuggestion(ErrorCategory category) {
    final actions = t.intermediate.chat.failure.suggestedActions;
    switch (category) {
      case ErrorCategory.config:
        return actions.config;
      case ErrorCategory.network:
        return actions.network;
      case ErrorCategory.auth:
        return actions.auth;
      case ErrorCategory.rateLimit:
        return actions.rateLimit;
      case ErrorCategory.server:
        return actions.server;
      case ErrorCategory.request:
        return actions.request;
      case ErrorCategory.timeout:
        return actions.timeout;
      case ErrorCategory.format:
        return actions.format;
      case ErrorCategory.persist:
        return actions.persist;
      case ErrorCategory.contextOverflow:
        return actions.contextOverflow;
      case ErrorCategory.unknown:
        return actions.unknown;
    }
  }

  /// 截断字符串到最大长度。
  String _truncate(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);

  // 「模型不可用」特征识别已提取为共享口径
  // core/llm/model_unavailability.dart 的 isModelUnavailableText
  // 。
}
