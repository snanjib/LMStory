import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/model_registry/model_capability_inferrer.dart';
import 'package:lmstory/core/network/llm_adapters/thinking_param_builder.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';

/// ThinkingParamBuilder + ModelCapabilityInferrer 单元测试
///
/// ThinkingParamBuilder 为端点家族 × 模型能力两步路由（2026-09-09 重构）：
/// 第一步按 baseUrl 判定端点家族（官方端点维持厂商原生方言），第二步在
/// 家族内按 modelId 做能力判定；未知/第三方端点统一 OpenAI 标准
/// `reasoning_effort`（启用直发、禁用不发参）。
///
/// 官方端点 baseUrl 用例值：
/// - deepseek: https://api.deepseek.com/v1
/// - 智谱: https://open.bigmodel.cn/api/paas/v4
/// - 阿里: https://dashscope.aliyuncs.com/compatible-mode/v1
/// - moonshot: https://api.moonshot.cn/v1
/// - agnes: https://api.agnes-ai.com/v1
/// - OpenRouter: https://openrouter.ai/api/v1
///
/// 同时验证 ModelCapabilityInferrer 的 modelId 模式匹配（能力推断与端点无关）。
void main() {
  group('ThinkingParamBuilder.build 基础优先级', () {
    test('reasoningEffort=null 不发送任何思考参数', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-reasoner',
        reasoningEffort: null,
      );
      expect(params, isEmpty);
    });

    test('providerOptions.thinking 透传（最高优先级）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'any-model',
        reasoningEffort: ReasoningEffort.medium,
        providerOptions: {
          'thinking': {'type': 'custom'},
        },
      );
      expect(params, {
        'thinking': {'type': 'custom'},
      });
    });

    test('providerOptions.reasoning 透传（最高优先级）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'any-model',
        reasoningEffort: ReasoningEffort.medium,
        providerOptions: {
          'reasoning': {'effort': 'custom'},
        },
      );
      expect(params, {
        'reasoning': {'effort': 'custom'},
      });
    });
  });

  group('未知/第三方端点（含 baseUrl 缺省）统一 OpenAI 标准方言', () {
    test('未知模型走默认 reasoning_effort', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'some-custom-model',
        reasoningEffort: ReasoningEffort.medium,
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('OpenAI o3-mini medium → reasoning_effort:medium', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'o3-mini',
        reasoningEffort: ReasoningEffort.medium,
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('OpenAI o1 high → reasoning_effort:high', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'o1',
        reasoningEffort: ReasoningEffort.high,
      );
      expect(params, {'reasoning_effort': 'high'});
    });

    test('gpt-4o 不被误判为 o-series', () {
      // gpt-4o 含 o 但不在开头，默认路径照发 reasoning_effort
      final params = ThinkingParamBuilder.build(
        modelId: 'gpt-4o',
        reasoningEffort: ReasoningEffort.medium,
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('OpenAI 官方端点（api.openai.com）归未知家族 → reasoning_effort', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'gpt-5',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('未知端点 disabled → 不发任何参数（保守默认）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'some-custom-model',
        reasoningEffort: ReasoningEffort.disabled,
      );
      expect(params, isEmpty);
    });
  });

  group('端点家族路由矩阵（2026-09-09 端点化路由）', () {
    // ---- AMD 故障场景（2026-09-08 EAGENT 根因回归）----
    test('AMD 端点 DeepSeek-V4 启用 → reasoning_effort，无 thinking 键', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'DeepSeek-V4-Flash-Vision-Exp',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://developer.amd.com.cn/radeon/api/v1',
      );
      expect(params, {'reasoning_effort': 'medium'});
      expect(params.containsKey('thinking'), isFalse);
    });

    test('AMD 端点 DeepSeek-V4 high → reasoning_effort:high 直发', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'DeepSeek-V4-Flash-Vision-Exp',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://developer.amd.com.cn/radeon/api/v1',
      );
      expect(params, {'reasoning_effort': 'high'});
    });

    test('AMD 端点 DeepSeek-V4 disabled → 不发参数（不再发厂商方言）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'DeepSeek-V4-Flash-Vision-Exp',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://developer.amd.com.cn/radeon/api/v1',
      );
      expect(params, isEmpty);
    });

    // ---- 第三方端点上的各厂思考模型名：一律标准方言 ----
    test('第三方端点（siliconflow）qwen3 启用 → reasoning_effort 直发', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'Qwen/Qwen3-32B',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.siliconflow.cn/v1',
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('第三方端点 glm-5.3 medium → reasoning_effort:medium 原样直发（不升格）', () {
      // 升格仅发生在智谱官方端点；兼容端点档位原样直发
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-5.3',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.siliconflow.cn/v1',
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('第三方端点 kimi-k3 启用 → reasoning_effort（不发 enable_thinking:max）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'kimi-k3',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://api.siliconflow.cn/v1',
      );
      expect(params, {'reasoning_effort': 'high'});
    });

    test('第三方端点 agnes-2.0-flash 启用 → reasoning_effort（不发 chat_template_kwargs）',
        () {
      final params = ThinkingParamBuilder.build(
        modelId: 'agnes-2.0-flash',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://developer.amd.com.cn/radeon/api/v1',
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('第三方端点各厂模型名 disabled → 一律不发参数', () {
      for (final modelId in [
        'deepseek-v4',
        'qwen3-32b',
        'glm-4.6',
        'kimi-k2-thinking',
        'agnes-2.0-flash',
      ]) {
        final params = ThinkingParamBuilder.build(
          modelId: modelId,
          reasoningEffort: ReasoningEffort.disabled,
          baseUrl: 'https://api.siliconflow.cn/v1',
        );
        expect(params, isEmpty, reason: '$modelId 在未知端点 disabled 应不发参数');
      }
    });

    // ---- 官方端点上的跨厂模型名（病态配置）：落家族默认 ----
    test('deepseek 官方端点 + glm-4.6 模型名 → 家族默认 reasoning_effort', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-4.6',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.deepseek.com/v1',
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('智谱官方端点 + deepseek-v4 模型名 → 家族默认 reasoning_effort', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-v4',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    // ---- 家族判定边界 ----
    test('beta.deepseek.com 也判定为 deepseek 官方', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-v4',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://beta.deepseek.com/v1',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': 'high',
      });
    });

    test('dashscope intl 站判定为阿里官方', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'qwen3-32b',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
      );
      expect(params, {
        'enable_thinking': true,
        'thinking_budget': 8192,
      });
    });

    test('moonshot.ai 域判定为 moonshot 官方', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'kimi-k3',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.moonshot.ai/v1',
      );
      expect(params, {
        'enable_thinking': true,
        'reasoning_effort': 'max',
      });
    });

    test('baseUrl 大小写不敏感（HTTPS://API.DEEPSEEK.COM → 官方）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-v4',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'HTTPS://API.DEEPSEEK.COM/V1',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
      });
    });

    test('baseUrl 空且 modelId 含 / → OpenRouter 兜底', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek/deepseek-r1',
        reasoningEffort: ReasoningEffort.medium,
      );
      expect(params, {
        'reasoning': {'effort': 'medium'},
      });
    });
  });

  group('deepseek 官方端点', () {
    test('DeepSeek-reasoner medium → thinking:{type:enabled}（无 effort）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-reasoner',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.deepseek.com/v1',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
      });
    });

    test('DeepSeek-r1 high → thinking + reasoning_effort:high', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-r1',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://api.deepseek.com/v1',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': 'high',
      });
    });

    test('DeepSeek-v3.1 low → thinking:{type:enabled}', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-v3.1',
        reasoningEffort: ReasoningEffort.low,
        baseUrl: 'https://api.deepseek.com/v1',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
      });
    });

    test('DeepSeek-v3.2 high → thinking + reasoning_effort:high', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-v3.2',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://api.deepseek.com/v1',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
        'reasoning_effort': 'high',
      });
    });

    test('DeepSeek-V3 旧版走默认 reasoning_effort（非思考模型）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-v3',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.deepseek.com/v1',
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test('DeepSeek-V4 disabled → thinking:{type:disabled}', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-v4',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://api.deepseek.com/v1',
      );
      expect(params, {
        'thinking': {'type': 'disabled'},
      });
    });

    test('DeepSeek-R1 disabled → 不发参数（纯思考模型不支持关闭）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-r1',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://api.deepseek.com/v1',
      );
      expect(params, isEmpty);
    });
  });

  group('智谱官方端点', () {
    test('GLM-4.6 medium → thinking:{type:enabled}', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-4.6',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
      });
    });

    test('GLM-4.5 high → thinking:{type:enabled}', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-4.5',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
      });
    });

    test('GLM-z1 low → thinking:{type:enabled}', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-z1',
        reasoningEffort: ReasoningEffort.low,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
      });
    });

    // ---- GLM-5.2/5.3（reasoning_effort 三档，始终思考）----
    // 2026-09-08 EAGENT 故障：GLM-5.3 仅支持 low/high/max，medium 原样
    // 透传被端点 400 拒收（"该模型始终思考…请使用 low、high 或 max"）。
    test('GLM-5.3 medium → reasoning_effort:high（三档模型升格）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-5.3',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {'reasoning_effort': 'high'});
    });

    test('GLM-5.3 low → reasoning_effort:low', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-5.3',
        reasoningEffort: ReasoningEffort.low,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {'reasoning_effort': 'low'});
    });

    test('GLM-5.3 high → reasoning_effort:high（不升 max）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-5.3',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {'reasoning_effort': 'high'});
    });

    test('GLM-5.3 disabled → 不发参数（不支持关闭，默认 max 档）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-5.3',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, isEmpty);
    });

    test('GLM-5.3-flash 变体后缀命中同一分支', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-5.3-flash',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {'reasoning_effort': 'high'});
    });

    test('glm5.3 无连字符写法命中同一分支', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm5.3',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {'reasoning_effort': 'high'});
    });

    test('GLM-5.2 medium → reasoning_effort:high（统一按三档映射）', () {
      // 5.2 官方虽支持 medium，但统一按 5.3 三档口径映射，避免按小版本分叉
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-5.2',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {'reasoning_effort': 'high'});
    });

    test('GLM-5.1（无档位参数）→ thinking:{type:enabled}', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm5.1',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
      });
    });

    test('GLM-4.6 不被 GLM-5 分支误伤', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-4.6',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {
        'thinking': {'type': 'enabled'},
      });
    });

    test('GLM-4.6 disabled → thinking:{type:disabled}', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'glm-4.6',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(params, {
        'thinking': {'type': 'disabled'},
      });
    });
  });

  group('阿里官方端点（DashScope OpenAI 兼容）', () {
    test('Qwen3-32b medium → enable_thinking + thinking_budget:8192', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'qwen3-32b',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      expect(params, {
        'enable_thinking': true,
        'thinking_budget': 8192,
      });
    });

    test('Qwen3 low → thinking_budget:4096', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'qwen3-235b',
        reasoningEffort: ReasoningEffort.low,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      expect(params, {
        'enable_thinking': true,
        'thinking_budget': 4096,
      });
    });

    test('Qwen3 high → thinking_budget:16384', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'qwen3-high',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      expect(params, {
        'enable_thinking': true,
        'thinking_budget': 16384,
      });
    });

    test('QwQ medium → enable_thinking + thinking_budget:8192', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'qwq-32b',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      expect(params, {
        'enable_thinking': true,
        'thinking_budget': 8192,
      });
    });

    test('Qwen3 disabled → enable_thinking:false', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'qwen3-32b',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      expect(params, {'enable_thinking': false});
    });
  });

  group('moonshot 官方端点', () {
    test('Kimi-k2-thinking medium → enable_thinking + reasoning_effort:max',
        () {
      final params = ThinkingParamBuilder.build(
        modelId: 'kimi-k2-thinking',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.moonshot.cn/v1',
      );
      expect(params, {
        'enable_thinking': true,
        'reasoning_effort': 'max',
      });
    });

    test('Kimi-k3 high → enable_thinking + reasoning_effort:max', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'kimi-k3',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://api.moonshot.cn/v1',
      );
      expect(params, {
        'enable_thinking': true,
        'reasoning_effort': 'max',
      });
    });

    test('Kimi-k3 disabled → enable_thinking:false', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'kimi-k3',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://api.moonshot.cn/v1',
      );
      expect(params, {'enable_thinking': false});
    });
  });

  group('agnes 官方端点', () {
    test('agnes-2.0-flash medium → chat_template_kwargs:{enable_thinking:true}',
        () {
      final params = ThinkingParamBuilder.build(
        modelId: 'agnes-2.0-flash',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.agnes-ai.com/v1',
      );
      expect(params, {
        'chat_template_kwargs': {'enable_thinking': true},
      });
    });

    test('agnes-2.0-flash high → chat_template_kwargs（无档位）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'agnes-2.0-flash',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://api.agnes-ai.com/v1',
      );
      // agnes-2.0-flash 不区分档位，只有开/关
      expect(params, {
        'chat_template_kwargs': {'enable_thinking': true},
      });
    });

    test('agnes-2-flash 简写也能识别', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'agnes-2-flash',
        reasoningEffort: ReasoningEffort.low,
        baseUrl: 'https://api.agnes-ai.com/v1',
      );
      expect(params, {
        'chat_template_kwargs': {'enable_thinking': true},
      });
    });

    test('agnes-1.5-flash 不被识别（旧版无 Thinking）→ 家族默认', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'agnes-1.5-flash',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://api.agnes-ai.com/v1',
      );
      expect(params, {'reasoning_effort': 'medium'});
    });

    test(
        'agnes-2.0-flash disabled → chat_template_kwargs:{enable_thinking:false}',
        () {
      final params = ThinkingParamBuilder.build(
        modelId: 'agnes-2.0-flash',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://api.agnes-ai.com/v1',
      );
      expect(params, {
        'chat_template_kwargs': {'enable_thinking': false},
      });
    });
  });

  group('OpenRouter 聚合层', () {
    test('OpenRouter baseUrl + reasoning_effort 路径', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek/deepseek-r1',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://openrouter.ai/api/v1',
      );
      expect(params, {
        'reasoning': {'effort': 'medium'},
      });
    });

    test('OpenRouter baseUrl 优先于 modelId 路由', () {
      // 即使 modelId 是 deepseek-r1，OpenRouter 走 reasoning 路径
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek-r1',
        reasoningEffort: ReasoningEffort.high,
        baseUrl: 'https://openrouter.ai/api/v1',
      );
      expect(params, {
        'reasoning': {'effort': 'high'},
      });
    });

    test('OpenRouter glm-5.3 medium → effort 原样（聚合层不做厂商升格）', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'z-ai/glm-5.3',
        reasoningEffort: ReasoningEffort.medium,
        baseUrl: 'https://openrouter.ai/api/v1',
      );
      expect(params, {
        'reasoning': {'effort': 'medium'},
      });
    });

    test('OpenRouter disabled → reasoning:{enabled:false}', () {
      final params = ThinkingParamBuilder.build(
        modelId: 'deepseek/deepseek-r1',
        reasoningEffort: ReasoningEffort.disabled,
        baseUrl: 'https://openrouter.ai/api/v1',
      );
      expect(params, {
        'reasoning': {'enabled': false},
      });
    });
  });

  group('ModelCapabilityInferrer.infersReasoning', () {
    test('Agnes 2.0 Flash 识别', () {
      expect(
        ModelCapabilityInferrer.infersReasoning('agnes-2.0-flash'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('agnes-2-flash'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('agnes2.0-flash'),
        isTrue,
      );
    });

    test('Agnes 1.5 Flash 不被识别（旧版无 Thinking）', () {
      expect(
        ModelCapabilityInferrer.infersReasoning('agnes-1.5-flash'),
        isFalse,
      );
    });

    test('OpenAI o-series 识别', () {
      expect(ModelCapabilityInferrer.infersReasoning('o1'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('o3'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('o4'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('o1-mini'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('o3-mini'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('o4-mini'), isTrue);
    });

    test('gpt-4o 不被误判为 o-series', () {
      expect(ModelCapabilityInferrer.infersReasoning('gpt-4o'), isFalse);
      expect(ModelCapabilityInferrer.infersReasoning('gpt-4o-mini'), isFalse);
    });

    test('DeepSeek 思考模型识别', () {
      expect(ModelCapabilityInferrer.infersReasoning('deepseek-r1'), isTrue);
      expect(
        ModelCapabilityInferrer.infersReasoning('deepseek-reasoner'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('deepseek-v3.1'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('deepseek-v3.2'),
        isTrue,
      );
      expect(ModelCapabilityInferrer.infersReasoning('deepseek-v4'), isTrue);
    });

    test('DeepSeek-V3 旧版不被识别（非思考模型）', () {
      expect(ModelCapabilityInferrer.infersReasoning('deepseek-v3'), isFalse);
      expect(ModelCapabilityInferrer.infersReasoning('deepseek-chat'), isFalse);
    });

    test('Qwen3 系列识别', () {
      expect(ModelCapabilityInferrer.infersReasoning('qwen3-32b'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('qwen3-235b'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('qwq-32b'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('qwq'), isTrue);
    });

    test('Qwen 旧版不被识别', () {
      expect(ModelCapabilityInferrer.infersReasoning('qwen-72b'), isFalse);
      expect(ModelCapabilityInferrer.infersReasoning('qwen2-72b'), isFalse);
    });

    test('GLM 思考模型识别', () {
      expect(ModelCapabilityInferrer.infersReasoning('glm-4.6'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('glm-4.5'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('glm-z1'), isTrue);
    });

    test('GLM-5 系识别（始终思考）', () {
      expect(ModelCapabilityInferrer.infersReasoning('glm-5.3'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('glm-5.3-flash'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('z-ai/glm5.1'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('glm-5.2'), isTrue);
    });

    test('GLM 旧版不被识别', () {
      expect(ModelCapabilityInferrer.infersReasoning('glm-4'), isFalse);
      expect(ModelCapabilityInferrer.infersReasoning('glm-4-plus'), isFalse);
    });

    test('Kimi 思考模型识别', () {
      expect(
        ModelCapabilityInferrer.infersReasoning('kimi-k2-thinking'),
        isTrue,
      );
      expect(ModelCapabilityInferrer.infersReasoning('kimi-k3'), isTrue);
      expect(
        ModelCapabilityInferrer.infersReasoning('moonshot-v1-thinking'),
        isTrue,
      );
    });

    test('Kimi 旧版不被识别', () {
      expect(ModelCapabilityInferrer.infersReasoning('kimi-k2'), isFalse);
      expect(
        ModelCapabilityInferrer.infersReasoning('moonshot-v1-8k'),
        isFalse,
      );
    });

    test('Claude thinking 模型识别', () {
      expect(
        ModelCapabilityInferrer.infersReasoning('claude-3-7-sonnet'),
        isTrue,
      );
      expect(ModelCapabilityInferrer.infersReasoning('claude-4-opus'), isTrue);
      expect(ModelCapabilityInferrer.infersReasoning('claude-opus-4'), isTrue);
      expect(
        ModelCapabilityInferrer.infersReasoning('claude-sonnet-4'),
        isTrue,
      );
    });

    test('Claude 旧版不被识别', () {
      expect(
        ModelCapabilityInferrer.infersReasoning('claude-3-5-sonnet'),
        isFalse,
      );
      expect(ModelCapabilityInferrer.infersReasoning('claude-3-opus'), isFalse);
    });

    test('Gemini thinking 模型识别', () {
      expect(
        ModelCapabilityInferrer.infersReasoning('gemini-2.5-pro'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('gemini-3-pro'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('gemini-thinking'),
        isTrue,
      );
    });

    test('通用 -reasoning/-thinking/-reasoner/-thinker 后缀识别', () {
      expect(
        ModelCapabilityInferrer.infersReasoning('custom-reasoning'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('custom-thinking'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('custom-reasoner'),
        isTrue,
      );
      expect(
        ModelCapabilityInferrer.infersReasoning('custom-thinker'),
        isTrue,
      );
    });

    test('空字符串与未知模型返回 false', () {
      expect(ModelCapabilityInferrer.infersReasoning(''), isFalse);
      expect(ModelCapabilityInferrer.infersReasoning('gpt-3.5-turbo'), isFalse);
      expect(ModelCapabilityInferrer.infersReasoning('llama-3'), isFalse);
    });
  });
}
