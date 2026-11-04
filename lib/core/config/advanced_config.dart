import 'package:lmstory/core/config/intermediate_config.dart'
    show
        ConsolidationConfig,
        ContextBudget,
        ContextConfig,
        EmbeddingConfig,
        GenerationConfig,
        MemoryConfig,
        PromptsConfig,
        RetrievalConfig,
        SuggestReplyConfig;

/// 导演模式配置（顶层聚合），对应 default_config.json 的 `advanced` 段。
///
/// 与 IntermediateConfig 平级、零配置依赖（"两个产品"原则，设计文档 §2.1）：
/// 仅复用值类（代码资产）；embedding/memory/consolidation/retrieval 等键
/// 虽与 intermediate 同名同默认，但为独立真相，各自演化。
class AdvancedConfig {
  const AdvancedConfig({
    this.systemPrompt = '',
    this.generatingPresetId = '',
    this.generatingModelId = '',
    this.generation = const GenerationConfig(),
    this.defaults = const AdvancedDefaultsConfig(),
    this.budget = const AdvancedBudgetConfig(),
    this.doomLoop = const AdvancedDoomLoopConfig(),
    this.hitl = const AdvancedHitlConfig(),
    this.subagent = const AdvancedSubagentConfig(),
    this.harness = const AdvancedHarnessConfig(),
    this.context = const ContextConfig(),
    this.contextBudget = const ContextBudget(),
    this.tools = const {},
    this.narrativePacing = 'balanced',
    this.embeddingPresetId = '',
    this.embeddingModelId = '',
    this.embedding = const EmbeddingConfig(),
    this.memory = const MemoryConfig(),
    this.consolidation = const ConsolidationConfig(),
    this.retrieval = const RetrievalConfig(),
    this.suggestReply = const SuggestReplyConfig(),
    this.prompts = const PromptsConfig(),
    this.reviewEnabled = false,
  });

  factory AdvancedConfig.fromJson(Map<String, dynamic> json) => AdvancedConfig(
        systemPrompt: json['system_prompt'] as String? ?? '',
        generatingPresetId: (json['phase_models'] as Map<String, dynamic>? ??
                const {})['generating_preset_id'] as String? ??
            '',
        generatingModelId: (json['phase_models'] as Map<String, dynamic>? ??
                const {})['generating_model_id'] as String? ??
            '',
        generation: GenerationConfig.fromJson(
          json['generation'] as Map<String, dynamic>? ?? const {},
        ),
        defaults: AdvancedDefaultsConfig.fromJson(
          json['defaults'] as Map<String, dynamic>? ?? const {},
        ),
        budget: AdvancedBudgetConfig.fromJson(
          json['budget'] as Map<String, dynamic>? ?? const {},
        ),
        doomLoop: AdvancedDoomLoopConfig.fromJson(
          json['doom_loop'] as Map<String, dynamic>? ?? const {},
        ),
        hitl: AdvancedHitlConfig.fromJson(
          json['hitl'] as Map<String, dynamic>? ?? const {},
        ),
        subagent: AdvancedSubagentConfig.fromJson(
          json['subagent'] as Map<String, dynamic>? ?? const {},
        ),
        harness: AdvancedHarnessConfig.fromJson(
          json['harness'] as Map<String, dynamic>? ?? const {},
        ),
        context: ContextConfig.fromJson(
          json['context'] as Map<String, dynamic>? ?? const {},
        ),
        contextBudget: ContextBudget.fromJson(
          json['contextBudget'] as Map<String, dynamic>? ?? const {},
        ),
        tools: _parseTools(json['tools'] as Map<String, dynamic>?),
        narrativePacing:
            _parseNarrativePacing(json['narrative_pacing'] as String?),
        embeddingPresetId: json['embedding_preset_id'] as String? ?? '',
        embeddingModelId: json['embedding_model_id'] as String? ?? '',
        embedding: EmbeddingConfig.fromJson(
          json['embedding'] as Map<String, dynamic>? ?? const {},
        ),
        memory: MemoryConfig.fromJson(
          json['memory'] as Map<String, dynamic>? ?? const {},
        ),
        consolidation: ConsolidationConfig.fromJson(
          json['consolidation'] as Map<String, dynamic>? ?? const {},
        ),
        retrieval: RetrievalConfig.fromJson(
          json['retrieval'] as Map<String, dynamic>? ?? const {},
        ),
        suggestReply: SuggestReplyConfig.fromJson(
          json['suggest_reply'] as Map<String, dynamic>? ?? const {},
        ),
        prompts: PromptsConfig.fromJson(
          json['prompts'] as Map<String, dynamic>? ?? const {},
        ),
        reviewEnabled: json['review_enabled'] as bool? ?? false,
      );

  /// 全局项目规则默认（空串 = 回退内置编辑部规则）
  final String systemPrompt;

  /// 导演主模型（GM）全局默认（导演无六步 phase，仅 generating）
  final String generatingPresetId;
  final String generatingModelId;
  final GenerationConfig generation;
  final AdvancedDefaultsConfig defaults;
  final AdvancedBudgetConfig budget;
  final AdvancedDoomLoopConfig doomLoop;
  final AdvancedHitlConfig hitl;
  final AdvancedSubagentConfig subagent;
  final AdvancedHarnessConfig harness;
  final ContextConfig context;
  final ContextBudget contextBudget;

  /// 工具权限覆盖：工具名 → allow|ask|deny；空 map = 全 allow（内置默认）
  final Map<String, String> tools;

  /// 剧情节奏三档：conservative|balanced|aggressive（剧情节奏档位设计 §5.1；
  /// 会话列 narrative_pacing NULL 时生效）
  final String narrativePacing;
  final String embeddingPresetId;
  final String embeddingModelId;
  final EmbeddingConfig embedding;
  final MemoryConfig memory;
  final ConsolidationConfig consolidation;
  final RetrievalConfig retrieval;
  final SuggestReplyConfig suggestReply;
  final PromptsConfig prompts;
  final bool reviewEnabled;

  static Map<String, String> _parseTools(Map<String, dynamic>? raw) {
    if (raw == null) return const {};
    final result = <String, String>{};
    raw.forEach((tool, value) {
      final v = value as String?;
      if (v != 'allow' && v != 'ask' && v != 'deny') {
        throw FormatException('advanced.tools.$tool 非法值: $v');
      }
      result[tool] = v!;
    });
    return Map.unmodifiable(result);
  }

  /// 剧情节奏三态解析（仿 tools：解析期拒绝非法值，坏配置启动即暴露）
  static String _parseNarrativePacing(String? raw) {
    if (raw == null) return 'balanced';
    if (raw == 'conservative' || raw == 'balanced' || raw == 'aggressive') {
      return raw;
    }
    throw FormatException('advanced.narrative_pacing 非法值: $raw');
  }
}

/// 导演会话 maxSteps 列 NULL 时的回退默认（原硬编码 8）
class AdvancedDefaultsConfig {
  const AdvancedDefaultsConfig({this.maxSteps = 8});
  factory AdvancedDefaultsConfig.fromJson(Map<String, dynamic> json) =>
      AdvancedDefaultsConfig(maxSteps: json['max_steps'] as int? ?? 8);
  final int maxSteps;
}

/// 导演轮运行预算（原 AgentBudget/director_round_runner 硬编码）
class AdvancedBudgetConfig {
  const AdvancedBudgetConfig({
    this.maxDurationMinutes = 5,
    this.tokenBudgetRatio = 0.6,
    this.maxRequestRetries = 5,
  });
  factory AdvancedBudgetConfig.fromJson(Map<String, dynamic> json) =>
      AdvancedBudgetConfig(
        maxDurationMinutes: json['max_duration_minutes'] as int? ?? 5,
        tokenBudgetRatio:
            (json['token_budget_ratio'] as num?)?.toDouble() ?? 0.6,
        maxRequestRetries: json['max_request_retries'] as int? ?? 5,
      );
  final int maxDurationMinutes;
  final double tokenBudgetRatio;
  final int maxRequestRetries;
}

/// doom-loop 判定阈值（连续同工具同参次数，原硬编码 3）
class AdvancedDoomLoopConfig {
  /// 默认阈值 3→8——阈值前 3/5 次同参连调先注入递进提醒，
  /// 给模型自行纠错的机会（提醒触发点见 agent_runner _repeatReminderStreaks）
  const AdvancedDoomLoopConfig({this.threshold = 8});
  factory AdvancedDoomLoopConfig.fromJson(Map<String, dynamic> json) =>
      AdvancedDoomLoopConfig(threshold: json['threshold'] as int? ?? 8);
  final int threshold;
}

/// HITL 双超时
class AdvancedHitlConfig {
  const AdvancedHitlConfig({
    this.askUserTimeoutMinutes = 3,
    this.approvalTimeoutMinutes = 5,
    this.approvalTimeoutEnabled = true,
  });
  factory AdvancedHitlConfig.fromJson(Map<String, dynamic> json) =>
      AdvancedHitlConfig(
        askUserTimeoutMinutes: json['ask_user_timeout_minutes'] as int? ?? 3,
        approvalTimeoutMinutes: json['approval_timeout_minutes'] as int? ?? 5,
        approvalTimeoutEnabled:
            json['approval_timeout_enabled'] as bool? ?? true,
      );
  final int askUserTimeoutMinutes;
  final int approvalTimeoutMinutes;

  /// 确认超时自动拒绝开关（2026-10-15 P2 ，默认 true=现状 fail-closed；
  /// 关闭 = 审批横幅与 ask_user 提问横幅永不超时一直等待——推翻 2026-08
  /// 「审批不开放永等档」旧安全语义；停止按钮/重启中断/无人值守三道
  /// 兜底不变）。**同盖两类 HITL 横幅**（§5-1 默认同盖）。
  final bool approvalTimeoutEnabled;

  /// 审批超时（页面倒计时与 runner completer.timeout 共用真源；此前
  /// 页面直用原始配置值、runner 侧 0→5 钳制，两侧口径漂移）。
  ///
  /// - 开关关 → null（永不超时）
  /// - minutes <= 0 → 钳回默认 5（Duration.zero 会让 completer 立即秒拒）
  Duration? get effectiveApprovalTimeout => !approvalTimeoutEnabled
      ? null
      : Duration(
          minutes: approvalTimeoutMinutes <= 0 ? 5 : approvalTimeoutMinutes,
        );

  /// ask_user 提问超时（0=一直等待为既有语义；P2 开关同盖：关闭时同样
  /// 永不超时）
  Duration? get effectiveAskUserTimeout => !approvalTimeoutEnabled
      ? null
      : (askUserTimeoutMinutes <= 0
          ? null
          : Duration(minutes: askUserTimeoutMinutes));
}

/// 子代理预算（原 agent_subagent.dart 硬编码 6 步 / 2 分钟）
class AdvancedSubagentConfig {
  const AdvancedSubagentConfig({
    this.maxSteps = 6,
    this.maxDurationMinutes = 2,
    this.tokenBudgetRatio = 0.6,
  });
  factory AdvancedSubagentConfig.fromJson(Map<String, dynamic> json) =>
      AdvancedSubagentConfig(
        maxSteps: json['max_steps'] as int? ?? 6,
        maxDurationMinutes: json['max_duration_minutes'] as int? ?? 2,
        // 子代理 token 上限比例（对主轮 contextWindow 取）
        tokenBudgetRatio:
            (json['token_budget_ratio'] as num?)?.toDouble() ?? 0.6,
      );
  final int maxSteps;
  final int maxDurationMinutes;

  /// 单次 spawn 累计消耗 token 上限 =
  /// 主轮 contextWindow × 本比例；**0 = 不限制**（对齐主轮
  /// tokenBudgetRatio 语义）。默认 0.6 复用主轮缺省。
  final double tokenBudgetRatio;
}

/// Agent harness 运行件
///
/// 键表：advanced.harness.*。这些是 harness 内核行为开关，非用户产品设置；
/// 默认值与各机制的内置默认一致，仅作为高级覆盖入口。
class AdvancedHarnessConfig {
  const AdvancedHarnessConfig({
    this.toolOutputLimit = 20000,
    this.toolTimeoutSeconds = 120,
    this.coreBlocksInTail = true,
    this.fullChunkEvents = false,
    this.foreshadowCheckInterval = 8,
    this.eventLogRetentionTurns = 20,
  });

  factory AdvancedHarnessConfig.fromJson(Map<String, dynamic> json) =>
      AdvancedHarnessConfig(
        toolOutputLimit: json['tool_output_limit'] as int? ?? 20000,
        toolTimeoutSeconds: json['tool_timeout_seconds'] as int? ?? 120,
        coreBlocksInTail: json['core_blocks_in_tail'] as bool? ?? true,
        fullChunkEvents: json['full_chunk_events'] as bool? ?? false,
        foreshadowCheckInterval: json['foreshadow_check_interval'] as int? ?? 8,
        // 批 I 写侧四处齐全而读侧漏解析，键恒回落
        // 默认 20、「0=不限制」不可达——守门测试已升级为三方逐叶比对
        //（settings_config_roundtrip_test.dart harness 段），防死键复发。
        eventLogRetentionTurns: json['event_log_retention_turns'] as int? ?? 20,
      );

  /// 工具输出字符预算（：超长输出 head+tail 截断 + 取回自指引）
  final int toolOutputLimit;

  /// 单工具执行超时秒数（：control 档豁免；0 = 禁用）
  final int toolTimeoutSeconds;

  /// coreBlocks 挪到对话尾部（workbench-reminder 通道），默认 true。
  /// 2026-09-03 起默认 true（跨轮缓存止血 ：system 段字节跨轮恒定，
  /// Anthropic 端断点 1 永久命中；存量会话切换时一次性缓存失效，已知取舍）。
  final bool coreBlocksInTail;

  /// 流式正文分片全量落盘（：每个文本 delta 一条 assistant/chunk）。
  /// 默认 false——最小粒度（阈值聚合，默认开）已满足中断重建；
  /// true 为诊断档，存储成本高。
  final bool fullChunkEvents;

  /// 伏笔定期清点间隔轮数（每 N 轮：轮尾注入未兑现清单提醒 +
  /// finish_round 伏笔对账闸门拦截一次）。0 = 停用清点与闸门。
  final int foreshadowCheckInterval;

  /// 事件日志滚动保留轮数（批 I；0=不限制）
  final int eventLogRetentionTurns;
}
