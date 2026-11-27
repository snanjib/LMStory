import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';

/// Anthropic 端点身份（只按 host 判定，不读模型名）。
enum AnthropicEndpointKind { official, thirdParty }

/// 思考配置形态。
enum AnthropicThinkingDirective {
  /// 不发送 thinking 字段。
  omit,

  /// 使用 providerOptions['thinking'] 的原始 JSON。
  providerJson,

  /// thinking:{type:"adaptive"} + output_config.effort。
  adaptive,

  /// thinking:{type:"disabled"}。
  disabled,

  /// thinking:{type:"between_tools"}（Claude Sonnet 5.5）。
  betweenTools,
}

/// max_tokens 的来源（诊断/测试用）。
enum AnthropicMaxTokensSource { configured, modelMax, defaultFallback }

/// Anthropic 请求画像保留键（providerOptions）。
const String kAnthropicVersionOption = 'anthropic_version';
const String kAnthropicSendSamplingOption = 'anthropic_send_sampling';
const String kAnthropicThinkingModeOption = 'anthropic_thinking_mode';
const String kAnthropicEffortOption = 'anthropic_effort';
const String kAnthropicCapabilitiesOption = 'anthropic_capabilities';

/// 内部降级键：只存在于内存请求，不写回数据库。
const String kAnthropicDropSamplingInternal = '_lm_anthropic_drop_sampling';
const String kAnthropicDropThinkingInternal = '_lm_anthropic_drop_thinking';
const String kAnthropicToolChoiceAutoInternal =
    '_lm_anthropic_tool_choice_auto';

/// Anthropic 请求的唯一形态判定。
///
/// 判定依据只有 baseUrl host、providerOptions、reasoningEffort 与 max_tokens
/// 数值；**不读取 modelId**。官方与第三方差异收敛在这里，适配器与 400
/// 降级器共用同一份结果。
class AnthropicCompatOptions {
  const AnthropicCompatOptions({
    required this.endpointKind,
    required this.apiVersion,
    required this.sendSampling,
    required this.thinking,
    required this.providerThinking,
    required this.effort,
    required this.allowToolChoiceNone,
    required this.allowStableSystemCache,
    required this.maxTokens,
    required this.maxTokensSource,
  });

  factory AnthropicCompatOptions.resolve({
    required String baseUrl,
    Map<String, dynamic>? providerOptions,
    ReasoningEffort? reasoningEffort,
    int? requestedMaxTokens,
    int? modelMaxOutputTokens,
  }) {
    final options = providerOptions ?? const <String, dynamic>{};
    final endpointKind = _endpointKindOf(baseUrl);

    final explicitVersion = options[kAnthropicVersionOption];
    final apiVersion =
        explicitVersion is String && explicitVersion.trim().isNotEmpty
            ? explicitVersion.trim()
            : endpointKind == AnthropicEndpointKind.official
                ? officialApiVersion
                : thirdPartyApiVersion;

    final sendSampling = _resolveSendSampling(
      options: options,
      apiVersion: apiVersion,
    );

    final explicitThinking = options['thinking'];
    final (thinking, providerThinking) = _resolveThinking(
      options: options,
      endpointKind: endpointKind,
      reasoningEffort: reasoningEffort,
      explicitThinking: explicitThinking,
    );

    final effort = thinking == AnthropicThinkingDirective.adaptive
        ? _resolveEffort(options, reasoningEffort)
        : null;

    final allowToolChoiceNone = _resolveToolChoiceNone(
      options: options,
      endpointKind: endpointKind,
    );

    final allowStableSystemCache = _resolveStableSystemCache(
      options: options,
      endpointKind: endpointKind,
    );

    final (maxTokens, maxTokensSource) = _resolveMaxTokens(
      requested: requestedMaxTokens,
      modelMaxOutput: modelMaxOutputTokens,
    );

    return AnthropicCompatOptions(
      endpointKind: endpointKind,
      apiVersion: apiVersion,
      sendSampling: sendSampling,
      thinking: thinking,
      providerThinking: providerThinking,
      effort: effort,
      allowToolChoiceNone: allowToolChoiceNone,
      allowStableSystemCache: allowStableSystemCache,
      maxTokens: maxTokens,
      maxTokensSource: maxTokensSource,
    );
  }

  static const String officialApiVersion = '2026-10-21';
  static const String thirdPartyApiVersion = '2023-06-01';
  static const String officialHost = 'api.anthropic.com';

  final AnthropicEndpointKind endpointKind;
  final String apiVersion;
  final bool sendSampling;
  final AnthropicThinkingDirective thinking;

  /// thinking == providerJson 时的原始 JSON。
  final Map<String, dynamic>? providerThinking;

  /// output_config.effort；仅 adaptive 模式有值。
  final String? effort;

  final bool allowToolChoiceNone;

  /// 是否允许按请求的稳定 system 前缀拆分文本块并打缓存标记。
  ///
  /// 缺省官方端点开启、第三方关闭；`anthropic_capabilities` 中的
  /// `stable_system_cache` 布尔值可显式覆盖。
  final bool allowStableSystemCache;

  final int maxTokens;
  final AnthropicMaxTokensSource maxTokensSource;

  bool get isOfficial => endpointKind == AnthropicEndpointKind.official;

  /// 思考开启所需的最小 max_tokens（与适配器 _minThinkingMaxTokens 同值
  /// ——极小输出预算下发 thinking 会被协议拒绝）。
  static const int minThinkingMaxTokens = 1024;

  /// 最终协议请求是否携带「思考开启」的 thinking 配置。
  ///
  /// 与适配器 `_buildThinkingConfig` 同源（omit 不发 thinking；disabled
  /// 显式发送 `{"type":"disabled"}`；极小 max_tokens 不发 thinking；
  /// providerJson 显式 `type:disabled` 同样视为关闭；其余视为开启）。
  /// 历史思考表示的回传判定（工程上下文模式投影层）必须用本判定，
  /// 不得另维护一份忽略 providerOptions 的推断。
  bool requestThinkingEnabled({required int effectiveMaxTokens}) {
    if (thinking == AnthropicThinkingDirective.omit) return false;
    if (thinking == AnthropicThinkingDirective.disabled) return false;
    if (effectiveMaxTokens <= minThinkingMaxTokens) return false;
    if (thinking == AnthropicThinkingDirective.providerJson) {
      final type = providerThinking?['type'];
      return !(type is String && type.trim().toLowerCase() == 'disabled');
    }
    return true;
  }

  static AnthropicEndpointKind _endpointKindOf(String baseUrl) {
    var raw = baseUrl.trim();
    if (raw.startsWith(ApiUrlResolver.rawPrefix)) {
      raw = raw.substring(ApiUrlResolver.rawPrefix.length);
    }
    final parsed = Uri.tryParse(
      raw.contains('://') ? raw : 'https://$raw',
    );
    final host = parsed?.host.toLowerCase() ?? '';
    return host == officialHost
        ? AnthropicEndpointKind.official
        : AnthropicEndpointKind.thirdParty;
  }

  static bool _resolveSendSampling({
    required Map<String, dynamic> options,
    required String apiVersion,
  }) {
    if (options[kAnthropicDropSamplingInternal] == true) return false;
    if (options['omit_sampling_params'] == true) return false;

    // 2026-10-21 起官方移除 temperature/top_p/top_k，任何值都会 400。
    // 需要采样的用户必须显式把 anthropic_version 覆盖回旧版本。
    if (_isAtLeast(apiVersion, officialApiVersion)) return false;

    return options[kAnthropicSendSamplingOption] == true;
  }

  static (AnthropicThinkingDirective, Map<String, dynamic>?) _resolveThinking({
    required Map<String, dynamic> options,
    required AnthropicEndpointKind endpointKind,
    required ReasoningEffort? reasoningEffort,
    required Object? explicitThinking,
  }) {
    if (options[kAnthropicDropThinkingInternal] == true) {
      return (AnthropicThinkingDirective.omit, null);
    }
    if (explicitThinking is Map<String, dynamic>) {
      return (AnthropicThinkingDirective.providerJson, explicitThinking);
    }

    final mode = options[kAnthropicThinkingModeOption];
    if (mode is String) {
      final normalized = mode.trim().toLowerCase();
      final explicit = switch (normalized) {
        'omit' || 'off' || 'none' => AnthropicThinkingDirective.omit,
        'adaptive' => AnthropicThinkingDirective.adaptive,
        'disabled' => AnthropicThinkingDirective.disabled,
        'between_tools' ||
        'betweentools' =>
          AnthropicThinkingDirective.betweenTools,
        _ => null,
      };
      if (explicit != null) return (explicit, null);
    }

    if (endpointKind == AnthropicEndpointKind.thirdParty) {
      return (AnthropicThinkingDirective.omit, null);
    }

    return switch (reasoningEffort) {
      ReasoningEffort.low || ReasoningEffort.medium || ReasoningEffort.high => (
          AnthropicThinkingDirective.adaptive,
          null
        ),
      ReasoningEffort.disabled => (AnthropicThinkingDirective.disabled, null),
      null => (AnthropicThinkingDirective.omit, null),
    };
  }

  static String? _resolveEffort(
    Map<String, dynamic> options,
    ReasoningEffort? reasoningEffort,
  ) {
    final explicit = options[kAnthropicEffortOption];
    if (explicit is String) {
      final normalized = explicit.trim().toLowerCase();
      if (const {'low', 'medium', 'high', 'xhigh', 'max'}
          .contains(normalized)) {
        return normalized;
      }
    }
    return switch (reasoningEffort) {
      ReasoningEffort.low => 'low',
      ReasoningEffort.medium => 'medium',
      ReasoningEffort.high => 'high',
      ReasoningEffort.disabled || null => null,
    };
  }

  static bool _resolveToolChoiceNone({
    required Map<String, dynamic> options,
    required AnthropicEndpointKind endpointKind,
  }) {
    final capabilities = options[kAnthropicCapabilitiesOption];
    if (capabilities is Map<String, dynamic>) {
      final declared = capabilities['tool_choice_none'];
      if (declared is bool) return declared;
    }
    return endpointKind == AnthropicEndpointKind.official;
  }

  static bool _resolveStableSystemCache({
    required Map<String, dynamic> options,
    required AnthropicEndpointKind endpointKind,
  }) {
    final capabilities = options[kAnthropicCapabilitiesOption];
    if (capabilities is Map<String, dynamic>) {
      final declared = capabilities['stable_system_cache'];
      if (declared is bool) return declared;
    }
    return endpointKind == AnthropicEndpointKind.official;
  }

  static (int, AnthropicMaxTokensSource) _resolveMaxTokens({
    required int? requested,
    required int? modelMaxOutput,
  }) {
    final modelMax =
        modelMaxOutput != null && modelMaxOutput > 0 ? modelMaxOutput : null;
    if (requested != null && requested > 0) {
      final clamped =
          modelMax != null && requested > modelMax ? modelMax : requested;
      return (clamped, AnthropicMaxTokensSource.configured);
    }
    if (modelMax != null) {
      return (modelMax, AnthropicMaxTokensSource.modelMax);
    }
    return (
      OutputTokenPolicy.storyDefaultLimit,
      AnthropicMaxTokensSource.defaultFallback,
    );
  }

  /// 仅比较 yyyy-MM-dd 形态；非标准版本号不参与强制约束。
  static bool _isAtLeast(String version, String threshold) {
    final datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (!datePattern.hasMatch(version) || !datePattern.hasMatch(threshold)) {
      return false;
    }
    return version.compareTo(threshold) >= 0;
  }
}
