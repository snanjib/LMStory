import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/model_unavailability.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 结构化错误载荷。
///
/// 新写入的错误卡走 `lmerr:` JSON 前缀进现有 ChatMessage.error 字段——
/// 渲染层（_ErrorMessage）先试 [tryDecode]，失败回退旧「建议/详细信息」
/// 分隔符解析（存量消息兼容），消除「英文 locale 必断」的硬编码中文
/// 分隔符隐性协议。
class SimpleErrorPayload {
  const SimpleErrorPayload({
    required this.message,
    this.code,
    this.suggestion,
    this.detail,
  });

  /// 用户可见的友好提示（写入时 locale 的文案）
  final String message;

  /// 错误码（S001-S009）
  final String? code;

  /// 可操作建议
  final String? suggestion;

  /// 原始错误详情（截断后）
  final String? detail;

  static const String prefix = 'lmerr:';

  /// 旧版（lmerr: 之前）错误文本分隔符，仅为存量持久化消息的回退解析
  /// 保留（渲染层识别 `\n建议：$suggestion` / `\n详细信息：$detail` 行）。
  /// 属持久化格式协议而非 UI 文案，新写入禁用。
  static const String legacySuggestionSeparator = '\n建议：';
  static const String legacyDetailSeparator = '\n详细信息：';

  /// 编码为持久化形态：`lmerr:{json}`（null 字段省略）。
  String encode() {
    return prefix +
        jsonEncode({
          'message': message,
          if (code != null) 'code': code,
          if (suggestion != null) 'suggestion': suggestion,
          if (detail != null) 'detail': detail,
        });
  }

  /// 解码持久化形态；非本格式（缺前缀/坏 JSON/缺 message）返回 null，
  /// 调用方回退旧分隔符解析。
  static SimpleErrorPayload? tryDecode(String stored) {
    if (!stored.startsWith(prefix)) return null;
    final jsonPart = stored.substring(prefix.length);
    try {
      final decoded = jsonDecode(jsonPart);
      if (decoded is! Map<String, dynamic>) return null;
      final message = decoded['message'];
      if (message is! String || message.isEmpty) return null;
      return SimpleErrorPayload(
        message: message,
        code: decoded['code'] as String?,
        suggestion: decoded['suggestion'] as String?,
        detail: decoded['detail'] as String?,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Simple 模式失败分类器（参考 StoryFailureClassifier）。
///
/// 纯 Domain 层工具：将原始异常分流为分类字符串 + HTTP 状态 + 原始异常文本，
/// 并提供错误码（S001-S009）映射和用户可见的友好提示文案。
///
/// 设计要点：
/// - [classifyError] 接收已知公开异常类型（[AppHttpException] /
///   [TimeoutException]）；私有流错误异常按 toString() 含 "stream_error"
///   或 "streamerror" 字符串特征识别（兼容 Simple 模式 STREAM_ERROR 和
///   Intermediate 模式 StreamError 两种格式），不改类可见性。
/// - [errorCodeFromCategory] 按分类映射 S001-S009（与中级 E010-E018 区分）。
/// - [resolveMessage] 按分类提供通俗提示文案（i18n chat.failure.messages）。
/// - [resolveSuggestion] 按分类提供可操作建议（i18n chat.failure.suggestedActions）。
///   与 messages 区分，messages 描述"发生了什么+一般提示"，
///   suggestedActions 给出"具体可操作步骤"。
/// - [formatDisplay] 组合「友好提示（错误码）」用于助手消息持久化展示。
/// - [formatDisplayWithSuggestion] 组合「友好提示（错误码）+ 建议：xxx」
///   用于持久化到 ChatMessage.error 字段，_ErrorMessage 组件识别 "\n建议：" 分隔符单独渲染。
///
/// 分类字符串值与 ErrorCategory.name 一致（'config'/'network'/...），
/// 诊断页可统一展示 Simple/Intermediate 两种模式的失败记录。
class SimpleFailureClassifier {
  const SimpleFailureClassifier();

  // ── 分类常量（与 ErrorCategory.name 值一致）─────────────────────────
  static const config = 'config';
  static const network = 'network';
  static const auth = 'auth';
  static const rateLimit = 'rateLimit';
  static const server = 'server';
  static const timeout = 'timeout';
  static const format = 'format';
  static const persist = 'persist';
  static const unknown = 'unknown';

  /// 将原始异常分流为 (错误分类, HTTP 状态码, 原始异常文本)。
  ///
  /// 分流规则（同 StoryFailureClassifier.classifyError）：
  /// - [AppHttpException]：
  ///   - 401/403 → auth
  ///   - 429 → rateLimit
  ///   - 5xx → server
  ///   - 其他 4xx → server
  ///   - code `connection_timeout`/`receive_timeout`/`send_timeout` → timeout
  ///   - code `connection_error` → network
  /// - [TimeoutException]（dart:async）→ timeout
  /// - `_StreamErrorException`（toString 含 "StreamError"）→ network
  /// - 其他 → unknown
  ///
  /// `rawError` 为异常 toString() 截断前 2000 字符，供技术用户诊断。
  ///
  /// 截断长度演变： 初版 500 字符； 放宽到 2000 字符
  /// （堆栈信息通常 > 500 字符，500 截断后丢失关键调用链）。
  ({String category, int? httpStatus, String? rawError}) classifyError(
    Object error,
  ) {
    final String category;
    final int? httpStatus;

    if (error is AppHttpException) {
      httpStatus = error.statusCode;
      final status = error.statusCode;
      final code = error.code;
      if (status == 401 || status == 403) {
        category = auth;
      } else if (status == 429) {
        category = rateLimit;
      } else if (isModelUnavailableText(error.toString())) {
        // 网关在模型下线/无可用通道时返回
        // 400+文案，状态码判不出——对齐故事侧  口径归 server
        //（等待重试/换模型），此前落 unknown/S009 误导排查。
        category = server;
      } else if (status != null && status >= 500) {
        category = server;
      } else if (status != null && status >= 400) {
        category = server;
      } else if (code == 'connection_timeout' ||
          code == 'receive_timeout' ||
          code == 'send_timeout') {
        category = timeout;
      } else if (code == 'connection_error') {
        category = network;
      } else {
        category = unknown;
      }
    } else if (error is TimeoutException) {
      httpStatus = null;
      category = timeout;
    } else if (_isStreamError(error)) {
      // 流错误识别：ChatModeController 将 LlmStreamError 包装为
      // Exception('STREAM_ERROR: ...')（code 带下划线），Intermediate 模式
      // 使用 StreamErrorException（toString 含 'StreamError' 无下划线）。
      // 2026-07-30 修复：原 contains('streamerror') 无法匹配 'stream_error'
      // （带下划线），导致 Simple 模式所有流错误落入 unknown（S009），
      // 修复意图完全失效。改为同时匹配两种格式。
      final result = _classifyStreamErrorString(error.toString());
      httpStatus = result.httpStatus;
      category = result.category;
    } else {
      httpStatus = null;
      category = unknown;
    }

    final rawError = _truncate(error.toString(), 2000);
    return (category: category, httpStatus: httpStatus, rawError: rawError);
  }

  /// 判断异常是否为流错误。
  ///
  /// Simple 模式 ChatModeController 将 LlmStreamError 包装为
  /// `Exception('STREAM_ERROR: ...')`，toString() 小写后含 `stream_error`。
  /// Intermediate 模式使用 `StreamErrorException`，toString() 含 `StreamError`。
  /// 两种格式都需匹配。
  static bool _isStreamError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('stream_error') || text.contains('streamerror');
  }

  /// 从流错误信息字符串中解析 HTTP 状态码并分类。
  ///
  /// 2026-07-29 新增：流错误（LlmStreamError / _StreamErrorException）
  /// 的 message 通常包含 "status XXX" 模式的 HTTP 状态码，例如：
  /// "STREAM_ERROR: Stream interrupted: AppHttpException: SSE request
  ///  failed with status 400 | Response: ..."
  ///
  /// 解析规则：
  /// - 401/403 → auth（S003）
  /// - 429 → rateLimit（S004）
  /// - 400/其他 4xx → config（S001，参数验证错误通常是配置问题）
  /// - 5xx → server（S005）
  /// - 无状态码 → network（S002，真正的网络连接问题）
  ({String category, int? httpStatus}) _classifyStreamErrorString(
    String errorText,
  ) {
    // 流错误串同样检测模型不可用文案（网关 400 形态
    // 常无 status 码或带 400——对齐故事侧流内 error 块口径）
    if (isModelUnavailableText(errorText)) {
      return (category: server, httpStatus: null);
    }
    final match = RegExp(r'status (\d{3})').firstMatch(errorText);
    if (match == null) {
      return (category: network, httpStatus: null);
    }
    final status = int.tryParse(match.group(1) ?? '');
    if (status == null) {
      return (category: network, httpStatus: null);
    }
    if (status == 401 || status == 403) {
      return (category: auth, httpStatus: status);
    }
    if (status == 429) {
      return (category: rateLimit, httpStatus: status);
    }
    if (status >= 500) {
      return (category: server, httpStatus: status);
    }
    // 400 和其他 4xx：客户端参数错误，分类为 config
    return (category: config, httpStatus: status);
  }

  /// 按分类返回错误码 S001-S009。
  ///
  /// S001 config / S002 network / S003 auth / S004 rateLimit / S005 server /
  /// S006 timeout / S007 format / S008 persist / S009 unknown。
  String errorCodeFromCategory(String category) {
    switch (category) {
      case config:
        return 'S001';
      case network:
        return 'S002';
      case auth:
        return 'S003';
      case rateLimit:
        return 'S004';
      case server:
        return 'S005';
      case timeout:
        return 'S006';
      case format:
        return 'S007';
      case persist:
        return 'S008';
      default:
        return 'S009';
    }
  }

  /// 按分类返回通俗提示文案（"发生了什么"）。
  ///
  /// 文案来自 i18n chat.failure.messages.<category>。未知分类回退到 unknown。
  String resolveMessage(String category) {
    final m = t.chat.failure.messages;
    switch (category) {
      case config:
        return m.config;
      case network:
        return m.network;
      case auth:
        return m.auth;
      case rateLimit:
        return m.rateLimit;
      case server:
        return m.server;
      case timeout:
        return m.timeout;
      case format:
        return m.format;
      case persist:
        return m.persist;
      default:
        return m.unknown;
    }
  }

  /// 按分类返回可操作建议文案（"如何具体操作"）。
  ///
  /// 与 [resolveMessage] 区分，
  /// messages 描述"发生了什么+一般提示"，suggestedActions 给出"具体可操作步骤"。
  ///
  /// 文案来自 i18n chat.failure.suggestedActions.<category>。未知分类回退到 unknown。
  String resolveSuggestion(String category) {
    final s = t.chat.failure.suggestedActions;
    switch (category) {
      case config:
        return s.config;
      case network:
        return s.network;
      case auth:
        return s.auth;
      case rateLimit:
        return s.rateLimit;
      case server:
        return s.server;
      case timeout:
        return s.timeout;
      case format:
        return s.format;
      case persist:
        return s.persist;
      default:
        return s.unknown;
    }
  }

  /// 组合「友好提示（错误码）」用于助手消息持久化展示。
  ///
  /// 例如 category=network, errorCode='S002' → "网络连接失败，请检查网络后重试（S002）"。
  ///
  /// 注意：此方法不含建议行，仅用于向后兼容或无需建议的场景。
  /// 新代码应优先使用 [formatDisplayWithSuggestion]。
  String formatDisplay(String category, String errorCode) {
    return t.chat.failure.displayFormat(
      message: resolveMessage(category),
      code: errorCode,
    );
  }

  /// 组合「友好提示（错误码）+ 建议：xxx」用于助手消息持久化展示。
  ///
  /// 在错误码后追加 `\n建议：xxx` 行，
  /// _ErrorMessage 组件识别 `\n建议：` 分隔符单独渲染建议行（高亮+图标）。
  ///
  /// 例如 category=network, errorCode='S002' →
  /// "网络连接失败，请检查网络后重试（S002）\n建议：切换 Wi-Fi/移动数据，或重启路由器后重试"。
  ///
  /// 2026-07-29 新增 [rawError] 参数：传入供应商返回的原始错误信息，
  /// 在建议行后追加 `\n详细信息：xxx` 行，_ErrorMessage 组件识别并渲染为
  /// 可折叠区域（默认折叠），帮助用户定位 400 参数错误等具体原因。
  /// rawError 为 null 或空时不追加详细信息行（向后兼容）。
  String formatDisplayWithSuggestion(
    String category,
    String errorCode, {
    String? rawError,
  }) {
    // 截断 rawError，避免过长错误信息撑爆 UI
    final detail = (rawError != null && rawError.isNotEmpty)
        ? _truncate(rawError, 500)
        : null;
    if (detail != null) {
      return t.chat.failure.displayFormatWithDetail(
        message: resolveMessage(category),
        code: errorCode,
        suggestionLabel: t.chat.failure.suggestionLabel,
        suggestion: resolveSuggestion(category),
        detailLabel: t.chat.failure.detailLabel,
        detail: detail,
      );
    }
    return t.chat.failure.displayFormatWithSuggestion(
      message: resolveMessage(category),
      code: errorCode,
      suggestionLabel: t.chat.failure.suggestionLabel,
      suggestion: resolveSuggestion(category),
    );
  }

  /// 结构化载荷——新写入统一走此入口。
  ///
  /// 与 [formatDisplayWithSuggestion] 同源取值（message/suggestion 按
  /// 分类解析，detail 截断 500），但以 [SimpleErrorPayload.encode] 落库。
  SimpleErrorPayload buildErrorPayload(
    String category,
    String errorCode, {
    String? rawError,
  }) {
    final detail = (rawError != null && rawError.isNotEmpty)
        ? _truncate(rawError, 500)
        : null;
    return SimpleErrorPayload(
      message: resolveMessage(category),
      code: errorCode,
      suggestion: resolveSuggestion(category),
      detail: detail,
    );
  }

  /// 持久化形态（lmerr: JSON）——controller 各落库/
  /// 横幅调用点的统一入口。
  String formatPersisted(
    String category,
    String errorCode, {
    String? rawError,
  }) {
    return buildErrorPayload(category, errorCode, rawError: rawError).encode();
  }

  /// 截断字符串到最大长度。
  String _truncate(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
}
