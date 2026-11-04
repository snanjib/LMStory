import 'package:lmstory/core/llm/reasoning_effort.dart';

/// 端点家族（baseUrl 判定，见 ThinkingParamBuilder._familyOf）
enum _EndpointFamily {
  deepseekOfficial,
  zhipuOfficial,
  aliyunOfficial,
  moonshotOfficial,
  agnesOfficial,
  openrouter,

  /// 第三方/自部署 OpenAI 兼容端点（AMD、siliconflow、vLLM 等）及无法判定者
  unknown,
}

/// 模型思考参数统一构建器——端点家族 × 模型能力两步路由（2026-09-09 重构）
///
/// **设计原则：wire 方言跟着端点走，不跟模型名走。**
///
/// 第一步按 `baseUrl` 判定端点家族；第二步在家族内用 modelId 做**能力判定**
/// （是否本厂思考模型、支持哪些档位），modelId 不再直接决定键名。
///
/// **背景**（两次同模式故障，2026-09-09 重构动因）：
/// - 2026-09-08：导演模式接 AMD 端点 `developer.amd.com.cn`（OpenAI 兼容）+
///   `DeepSeek-V4-Flash-Vision-Exp`，模型名命中 DeepSeek 分支发出官方方言
///   `thinking:{type:enabled}`，而第三方端点只认 OpenAI 标准 `reasoning_effort`，
///   400（BAD_REQUEST 不可重试）→ 导演轮 EAGENT 失败。
/// - 2026-09-08（4edb95e7）：GLM-5.3 发 medium 档被端点 400 拒收——按模型名推断
///   方言的第一次失败。
///
/// **业界共识**（2026-09-08 五路源码级调研：opencode/Chatbox/SillyTavern/
/// Cherry Studio/LobeChat）：openai-compatible 兼容端点一律 `reasoning_effort`
/// 或零参数；厂商原生方言仅官方端点发送；运行期正则识别模型是反模式
/// （Cherry Studio 架构文档明列为 non-goal）。降级发生在构建期；
/// 400 后自动去参重试业界无人做，本类同样不做。
///
/// **端点家族判定**（baseUrl 小写包含即命中，先官方后 openrouter 后未知）：
///
/// | 家族 | 判定串 |
/// |------|--------|
/// | deepseek 官方 | `deepseek.com`（api./beta.） |
/// | 智谱官方 | `bigmodel.cn` |
/// | 阿里官方 | `dashscope`（国内站 + intl 站） |
/// | moonshot 官方 | `moonshot.cn`、`moonshot.ai` |
/// | agnes 官方 | `agnes-ai.com` |
/// | openrouter | `openrouter.ai`，或 baseUrl 空且 modelId 含 `/` |
/// | 其他/未知 | 以上皆否（AMD、siliconflow、自部署 vLLM、OpenAI 官方等） |
///
/// **行为矩阵（启用档位 low/medium/high）**：
///
/// | 家族 | 方言 |
/// |------|------|
/// | deepseek 官方 | 本厂思考模型（V3.1+/V4/R1）发 `thinking:{type:enabled}`（high 档另加 `reasoning_effort:high`）；其余默认 `reasoning_effort` |
/// | 智谱官方 | GLM-5.2/5.3 发 `reasoning_effort`（medium→high 升格）；GLM-4.6/4.5/z1/glm-5/5.1 发 `thinking:{type:enabled}`；其余默认 `reasoning_effort` |
/// | 阿里官方 | qwen3/qwq 发 `enable_thinking:true` + `thinking_budget`；其余默认 `reasoning_effort` |
/// | moonshot 官方 | kimi 思考模型发 `enable_thinking:true` + `reasoning_effort:max`；其余默认 `reasoning_effort` |
/// | agnes 官方 | agnes-2 系发 `chat_template_kwargs:{enable_thinking:true}`；其余默认 `reasoning_effort` |
/// | openrouter | `reasoning:{effort:...}` |
/// | 其他/未知 | 统一 `reasoning_effort` 档位直发（o-series 与旧默认分支本就如此） |
///
/// **行为矩阵（disabled 显式禁用）**：
///
/// | 家族 | 方言 |
/// |------|------|
/// | deepseek 官方 | `thinking:{type:disabled}`（R1/reasoner 纯思考模型不发参） |
/// | 智谱官方 | GLM-4.6 系 `thinking:{type:disabled}`；GLM-5.2/5.3 始终思考不发参；其余不发参 |
/// | 阿里官方 | qwen3/qwq `enable_thinking:false`；其余不发参 |
/// | moonshot 官方 | kimi `enable_thinking:false`；其余不发参 |
/// | agnes 官方 | `chat_template_kwargs:{enable_thinking:false}`（agnes-2 系） |
/// | openrouter | `reasoning:{enabled:false}` |
/// | 其他/未知 | 不发任何参数（保守默认，对标 Chatbox/SillyTavern；OpenAI 标准无关闭值） |
///
/// 家族内的模型检测只认本厂检测器：官方端点上出现跨厂模型名（病态配置）时落
/// 家族默认（启用=`reasoning_effort`，禁用=不发参），符合「方言是端点属性」。
///
/// **agnes-2 系特别说明**（2026-07-27 实测）：Agnes 官方 OpenAI 兼容协议下启用
/// Thinking 必须用 `chat_template_kwargs:{enable_thinking:true}`，而非
/// `thinking:{type:enabled}`（后者是 Anthropic 兼容协议格式，实测触发 TLS 重置）。
/// 文档：https://agnes-ai.com/zh-Hans/docs/agnes-20-flash
///
/// **优先级**（2026-07-28 修订，本次重构不变）：
/// 1. `reasoningEffort == disabled`（显式禁用）→ 发送显式关闭参数，优先级最高，
///    覆盖 providerOptions 透传。背景：对绝大多数思考模型，不发参数 = 模型默认
///    行为 = 开启思考，"禁用"按钮会无效。
/// 2. `providerOptions.thinking` 或 `providerOptions.reasoning` 存在 → 直接透传
///    （高级用户逃生舱，仅在用户未显式禁用时生效）
/// 3. `reasoningEffort` 启用（非 null 非 disabled）→ 按上方矩阵适配
/// 4. `reasoningEffort == null`（未配置）→ 返回空 Map（不发送任何思考参数，
///    跟随模型默认行为）
///
/// **SSE 思考链解析**：本类只负责请求参数构建，响应解析由 `SseParser` 统一处理
///（兼容 `delta.reasoning_content` 和 `delta.reasoning` 两种字段）。
///
/// 实现依据：DOC-12 §5.6 思考参数统一适配（v1.7，2026-09-09 端点化路由）。
class ThinkingParamBuilder {
  ThinkingParamBuilder._();

  /// 构建思考参数 Map，可直接合并到 OpenAI 兼容请求体
  ///
  /// 返回空 Map 表示不发送任何思考参数。
  ///
  /// 参数：
  /// - [modelId]：模型 ID（家族内能力判定，如 `deepseek-v3.2`、`qwen3-32b`）
  /// - [reasoningEffort]：用户配置的思考档位（null/disabled=不开启）
  /// - [providerOptions]：协议特有参数透传（含 thinking/reasoning 时最高优先级）
  /// - [baseUrl]：API 基础地址（端点家族判定，空串视为未知家族）
  static Map<String, dynamic> build({
    required String modelId,
    required ReasoningEffort? reasoningEffort,
    Map<String, dynamic>? providerOptions,
    String baseUrl = '',
  }) {
    // 1. 显式禁用：按端点家族路由发送显式关闭参数（最高优先级，覆盖 providerOptions）
    // 2026-07-28 修复：原代码把 disabled 与 null 都当作"不发参数"，但对绝大多
    // 数思考模型，不发参数 = 模型默认 = 开启思考，导致"禁用"按钮无效。
    if (reasoningEffort == ReasoningEffort.disabled) {
      return _buildDisabledParams(modelId, baseUrl);
    }

    // 2. providerOptions 透传（仅当用户未显式禁用时生效，高级用户手动配置）
    if (providerOptions != null) {
      final thinking = providerOptions['thinking'];
      if (thinking != null) {
        return {'thinking': thinking};
      }
      final reasoning = providerOptions['reasoning'];
      if (reasoning != null) {
        return {'reasoning': reasoning};
      }
    }

    // 3. 用户未配置：不发送参数（跟随模型默认行为）
    if (reasoningEffort == null) {
      return {};
    }

    final id = modelId.toLowerCase();
    final family = _familyOf(baseUrl, id);

    // 4. 按端点家族输出方言
    switch (family) {
      case _EndpointFamily.unknown:
        // 2026-09-09 端点化路由核心改动：第三方/未知端点统一 OpenAI 标准方言，
        // 档位原样直发（含 o-series——其旧分支行为即 reasoning_effort）。
        // AMD 故障修复点：deepseek-v4 模型名在非 DeepSeek 端点不再发 thinking:{type}。
        return {'reasoning_effort': reasoningEffort.toJson()};

      case _EndpointFamily.openrouter:
        // OpenRouter 聚合层：统一 reasoning:{effort:...}
        return {
          'reasoning': {'effort': reasoningEffort.toJson()},
        };

      case _EndpointFamily.agnesOfficial:
        // agnes-2 系必须用 chat_template_kwargs（thinking:{type} 实测 TLS 重置）
        if (_isAgnesFlash(id)) {
          return {
            'chat_template_kwargs': {'enable_thinking': true},
          };
        }
        return {'reasoning_effort': reasoningEffort.toJson()};

      case _EndpointFamily.deepseekOfficial:
        if (_isDeepSeekThinking(id)) {
          final params = <String, dynamic>{
            'thinking': {'type': 'enabled'},
          };
          // V3.1+ 支持 reasoning_effort: high/max，low/medium 不发（默认中等）
          if (reasoningEffort == ReasoningEffort.high) {
            params['reasoning_effort'] = 'high';
          }
          return params;
        }
        return {'reasoning_effort': reasoningEffort.toJson()};

      case _EndpointFamily.zhipuOfficial:
        // GLM-5.2/5.3：reasoning_effort 三档模型（始终思考）
        // 智谱自 5.2 起以顶层 reasoning_effort 取代 4.x 的 thinking:{type}；
        // GLM-5.3 仅支持 low/high/max（5.2 的 medium/xhigh 被裁撤），发 medium
        // 会被端点 400 拒收（2026-09-08 EAGENT 故障根因）。medium 按官方迁移
        // 指南升为 high。glm-5/5.1 无此参数，落到下方 thinking 分支。
        if (_isGlm5EffortModel(id)) {
          return {'reasoning_effort': _glm5EffortValue(reasoningEffort)};
        }
        // GLM-4.6/4.5/z1 及 glm-5/5.1：thinking:{type:enabled}
        if (_isGlmThinking(id)) {
          return {
            'thinking': {'type': 'enabled'},
          };
        }
        return {'reasoning_effort': reasoningEffort.toJson()};

      case _EndpointFamily.aliyunOfficial:
        if (_isQwenThinking(id)) {
          return {
            'enable_thinking': true,
            'thinking_budget': _qwen3Budget(reasoningEffort),
          };
        }
        return {'reasoning_effort': reasoningEffort.toJson()};

      case _EndpointFamily.moonshotOfficial:
        // Kimi K2-thinking/K3：enable_thinking + reasoning_effort:max
        if (_isKimiThinking(id)) {
          return {
            'enable_thinking': true,
            'reasoning_effort': 'max',
          };
        }
        return {'reasoning_effort': reasoningEffort.toJson()};
    }
  }

  /// 构建"显式禁用思考"参数，按端点家族路由发送厂商原生关闭参数。
  ///
  /// 2026-07-28 新增：修复"禁用"按钮无效的 bug。各思考模型在不发参数时默认开启
  /// 思考，必须显式发送关闭参数才能停止。disabled 与 null（未配置）语义不同：
  /// - `null`（未配置）→ 不发参数，跟随模型默认行为（通常为开启思考）
  /// - `disabled`（显式禁用）→ 发送厂商原生关闭参数，强制关闭思考
  ///
  /// 不支持关闭的纯思考模型（DeepSeek-R1、OpenAI o-series）返回空 Map，
  /// 调用方应理解为"该模型无法关闭思考，需切换模型才能禁用"。
  ///
  /// 未知/第三方端点 disabled 一律不发参数（2026-09-09 端点化路由）：
  /// OpenAI 标准没有"关闭思考"的取值，乱发厂商方言只会 400（见 AMD 故障），
  /// Chatbox/SillyTavern 对自定义端点同样零参数。
  static Map<String, dynamic> _buildDisabledParams(
    String modelId,
    String baseUrl,
  ) {
    final id = modelId.toLowerCase();

    switch (_familyOf(baseUrl, id)) {
      case _EndpointFamily.openrouter:
        // OpenRouter 聚合层：reasoning:{enabled:false} 显式关闭
        return {
          'reasoning': {'enabled': false},
        };

      case _EndpointFamily.agnesOfficial:
        if (_isAgnesFlash(id)) {
          return {
            'chat_template_kwargs': {'enable_thinking': false},
          };
        }
        return {};

      case _EndpointFamily.deepseekOfficial:
        // DeepSeek-R1/Reasoner 是纯思考模型，不支持关闭，返回空 Map
        if (!_isDeepSeekThinking(id)) return {};
        if (id.contains('deepseek-r1') || id.contains('deepseek-reasoner')) {
          return {};
        }
        return {
          'thinking': {'type': 'disabled'},
        };

      case _EndpointFamily.zhipuOfficial:
        // GLM-5.2/5.3：始终思考模型，不支持关闭——发 thinking:{type:disabled}、
        // enable_thinking:false 或 reasoning_effort 非法值都会 400（官方迁移
        // 指南明示该类模型仅 low/high/max）。返回空 Map 不发参数 = 模型默认
        // max 档思考；用户需控制思考强度应显式选 low/high 档而非"禁用"。
        if (_isGlm5EffortModel(id)) return {};
        // GLM-4.6/4.5/z1 及 glm-5/5.1：thinking:{type:disabled}
        if (_isGlmThinking(id)) {
          return {
            'thinking': {'type': 'disabled'},
          };
        }
        return {};

      case _EndpointFamily.aliyunOfficial:
        if (_isQwenThinking(id)) {
          return {'enable_thinking': false};
        }
        return {};

      case _EndpointFamily.moonshotOfficial:
        if (_isKimiThinking(id)) {
          return {'enable_thinking': false};
        }
        return {};

      case _EndpointFamily.unknown:
        // 2026-08-01 修复（沿用到未知家族）：
        // 之前发送 reasoning_effort:'none'，但 'none' 不是 OpenAI 标准值
        //（标准只有 low/medium/high），部分供应商/模型对未知值行为异常：
        // - 某些模型返回空响应（LLM 不输出任何内容），导致 summarize/extract
        //   阶段报"JSON 模式：LLM 未输出任何内容"
        // - 某些模型可能直接报 400 错误
        //
        // 改为返回空 Map，与 null（未配置）行为一致：
        // - 不会导致错误或空响应
        // - 思考模型可能仍开启思考（无法关闭），但至少功能正常
        // - 用户若需确保关闭思考，应选择官方端点模型（Qwen3/GLM/DeepSeek 等）
        return {};
    }
  }

  /// 端点家族判定：baseUrl 小写包含即命中，先厂商官方后 openrouter 后未知。
  ///
  /// - deepseek 官方用 `deepseek.com`（覆盖 api. 与 beta. 官方端点，
  ///   与 DeepSeekAdapter.isDeepSeekEndpoint 语义对齐）；
  /// - 阿里用 `dashscope`（同时覆盖国内站 dashscope.aliyuncs.com 与
  ///   intl 站 dashscope-intl.aliyuncs.com）；
  /// - baseUrl 为空（无法判定端点）→ 未知家族，按 OpenAI 标准方言处理。
  static _EndpointFamily _familyOf(String baseUrl, String id) {
    final url = baseUrl.toLowerCase();
    if (url.contains('deepseek.com')) return _EndpointFamily.deepseekOfficial;
    if (url.contains('bigmodel.cn')) return _EndpointFamily.zhipuOfficial;
    if (url.contains('dashscope')) return _EndpointFamily.aliyunOfficial;
    if (url.contains('moonshot.cn') || url.contains('moonshot.ai')) {
      return _EndpointFamily.moonshotOfficial;
    }
    if (url.contains('agnes-ai.com')) return _EndpointFamily.agnesOfficial;
    if (_isOpenRouter(baseUrl, id)) return _EndpointFamily.openrouter;
    return _EndpointFamily.unknown;
  }

  /// 检测是否为 OpenRouter 聚合层
  ///
  /// 判断方式：
  /// - baseUrl 含 `openrouter.ai`
  /// - 或 modelId 含 `/`（OpenRouter 格式：`vendor/model-name`，如 `deepseek/deepseek-r1`）
  static bool _isOpenRouter(String baseUrl, String id) {
    if (baseUrl.isNotEmpty && baseUrl.toLowerCase().contains('openrouter.ai')) {
      return true;
    }
    // OpenRouter modelId 格式：vendor/model-name（如 deepseek/deepseek-r1）
    // 但部分供应商本地部署也可能用 /，所以仅在 baseUrl 也未匹配时作兜底
    if (baseUrl.isEmpty && id.contains('/')) {
      return true;
    }
    return false;
  }

  /// Agnes 2.x 系检测
  /// 匹配 agnes-2.0-flash / agnes-2-flash / agnes-2.5-flash 等
  /// 不匹配 agnes-1.5-flash（旧版不支持 Thinking）
  static bool _isAgnesFlash(String id) {
    if (!id.contains('agnes')) return false;
    // 必须是 2.0 或 2 开头（1.5 不支持 Thinking）
    return id.contains('agnes-2') || id.contains('agnes2');
  }

  /// DeepSeek 思考模型检测（V3.1+/V4/R1/reasoner）
  static bool _isDeepSeekThinking(String id) {
    return id.contains('deepseek-r1') ||
        id.contains('deepseek-v3.1') ||
        id.contains('deepseek-v3.2') ||
        id.contains('deepseek-v4') ||
        id.contains('deepseek-reasoner');
  }

  /// 智谱 GLM 思考模型检测
  ///
  /// glm-5/5.1（无 reasoning_effort 参数）也归入 thinking:{type} 分支；
  /// glm-5.2/5.3 由 [_isGlm5EffortModel] 前置拦截，不会落到这里。
  static bool _isGlmThinking(String id) {
    return id.contains('glm-4.6') ||
        id.contains('glm-4.5') ||
        id.contains('glm-4-plus-thinking') ||
        id.contains('glm-z1') ||
        _isGlm5Legacy(id);
  }

  /// GLM-5/5.1 检测（无 reasoning_effort 档位参数的 5 系早期版本）
  ///
  /// 兼容 OpenRouter 风格无连字符写法（如 `z-ai/glm5.1`）。
  /// 注意 `glm-5.2`/`glm5.3` 等均含 `glm-5`/`glm5` 子串，先显式排除。
  static bool _isGlm5Legacy(String id) {
    if (_isGlm5EffortModel(id)) return false;
    return id.contains('glm-5') || id.contains('glm5');
  }

  /// GLM-5.2/5.3 系检测（reasoning_effort 三档模型，始终思考）
  ///
  /// 官方文档（docs.bigmodel.cn 核心参数/迁移指南）：reasoning_effort 仅
  /// GLM-5.2 及以上支持，GLM-5.3 收窄为 low/high/max 三档并发送非法档位
  /// 直接 400；模型始终思考，不支持关闭。兼容 `glm-5.3` 与 `glm5.3`
  /// 两种连字符写法，后缀变体（-flash/-air 等）天然命中 contains。
  static bool _isGlm5EffortModel(String id) {
    return id.contains('glm-5.2') ||
        id.contains('glm-5.3') ||
        id.contains('glm5.2') ||
        id.contains('glm5.3');
  }

  /// GLM-5.2/5.3 的档位映射：low→low，medium/high→high
  ///
  /// 5.3 不支持 medium（发即 400）；medium 按官方迁移指南升为 high。
  /// high 不升 max（max 是该系默认最贵档，显式 high 已是增强思考）。
  static String _glm5EffortValue(ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.low:
        return 'low';
      case ReasoningEffort.medium:
      case ReasoningEffort.high:
        return 'high';
      case ReasoningEffort.disabled:
        // 不会走到这里（disabled 已在入口分流到 _buildDisabledParams）
        return 'low';
    }
  }

  /// Kimi 思考模型检测
  static bool _isKimiThinking(String id) {
    return id.contains('kimi-k2-thinking') ||
        id.contains('kimi-k3') ||
        id.contains('moonshot-v1-thinking');
  }

  /// Qwen 思考模型检测（qwen3 系列 / qwq）
  static bool _isQwenThinking(String id) {
    return id.contains('qwen3') || id.contains('qwq');
  }

  /// Qwen3 thinking_budget 档位映射
  static int _qwen3Budget(ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.low:
        return 4096;
      case ReasoningEffort.medium:
        return 8192;
      case ReasoningEffort.high:
        return 16384;
      case ReasoningEffort.disabled:
        return 0; // 不会走到这里（已在外层过滤）
    }
  }
}
