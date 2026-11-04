import 'dart:convert';

/// 导演模式单个工具执行步骤状态（opencode 式工具卡三态 + 可恢复失败态）
enum AgentStepStatus {
  /// 正在执行（标题微光扫过，不可展开）
  running,

  /// 已完成（静态灰，可展开看结果）
  done,

  /// 执行失败但本轮未中断（黄色警告变体）——模型通常能按提示重试成功
  warning,

  /// 执行失败且本轮对话被中断（红色变体）
  error,
}

/// 导演模式单个工具执行步骤（消息区 harness 样式展示用）
///
/// 与 story 模式的六步面板不同：agent 的每一步工具调用是一条可折叠的
/// 步骤卡。L1 过程行与卡片头部使用剧场语言（舞台动词由 UI 层 i18n
/// toolName 映射），[title]（工具结果信封的人话标题，如
/// `「古碑」· 12 处命中`）作为头部摘要；等宽工具名/参数/原始输出只
/// 存在于 L2 审计展开层。
///
/// [callId] 关联工具执行的 started/finished 事件，
/// 使 running 态能在 started 时占位、finished 时原地更新为 done/error，
/// 保证生成中与生成结束共用同一条时间线（不塌缩、不重排）。
class AgentWorkStep {
  const AgentWorkStep({
    required this.toolName,
    this.callId = '',
    this.argsPreview = '',
    this.title = '',
    this.output = '',
    this.status = AgentStepStatus.done,
    this.durationMs = 0,
    this.stepIndex = 0,
    this.startedAtMs,
    this.order,
  });

  factory AgentWorkStep.fromJson(Map<String, dynamic> json) {
    return AgentWorkStep(
      toolName: json['toolName'] as String,
      callId: (json['callId'] as String?) ?? '',
      argsPreview: (json['argsPreview'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      output: (json['output'] as String?) ?? '',
      status: switch (json['status'] as String?) {
        'running' => AgentStepStatus.running,
        'warning' => AgentStepStatus.warning,
        'error' => AgentStepStatus.error,
        _ => AgentStepStatus.done,
      },
      durationMs: (json['durationMs'] as int?) ?? 0,
      stepIndex: (json['stepIndex'] as num?)?.toInt() ?? 0,
      startedAtMs: (json['startedAtMs'] as num?)?.toInt(),
      order: (json['order'] as num?)?.toInt(),
    );
  }

  final String toolName;
  final String callId;

  /// 工具参数预览（原始 JSON 串，仅 L2 审计展开层展示）
  final String argsPreview;

  /// 人话标题（工具结果信封的 title 承载，如 `「古碑」· 12 处命中`）。
  /// L2 步骤卡头部摘要的数据源；running 占位时为空。
  final String title;

  /// 给模型的完整输出（展开查看）
  final String output;

  final AgentStepStatus status;
  final int durationMs;

  /// 发起该工具调用的模型请求序号（对话流计划 §4.1，schemaVersion 45）
  ///
  /// 轮时间线按 stepIndex 归并排序动作块；旧数据缺省 0（仅影响新装配的
  /// 时间线，旧 artifacts 走 agentSteps-only 回退渲染，不读此字段）。
  final int stepIndex;

  /// 工具开始执行的绝对时刻（事件流 at，epoch 毫秒；旧数据/无时刻为 null）
  ///
  /// 供时间线装配换算动作块相对起止（end = startedAtMs + durationMs）。
  final int? startedAtMs;

  /// First-arrival order shared with thinking and speech blocks.
  final int? order;

  bool get isError => status == AgentStepStatus.error;
  bool get isWarning => status == AgentStepStatus.warning;
  bool get isRunning => status == AgentStepStatus.running;

  /// 调用成功（唯一"成功"判定）。
  ///
  /// 不要用 `!isError` 表达成功：warning（失败但本轮继续）也会落进该
  /// 表达式的"成功"侧，使工作痕迹统计虚报（DD2 审计点）。
  bool get isSuccess => status == AgentStepStatus.done;

  /// 状态改写（其余字段不变）。
  ///
  /// DD2：轮因失败中断时把肇事步骤从 warning 升为 error。
  AgentWorkStep withStatus(AgentStepStatus next) {
    if (next == status) return this;
    return AgentWorkStep(
      toolName: toolName,
      callId: callId,
      argsPreview: argsPreview,
      title: title,
      output: output,
      status: next,
      durationMs: durationMs,
      stepIndex: stepIndex,
      startedAtMs: startedAtMs,
      order: order,
    );
  }

  /// 归一为终态（running → done）。
  ///
  /// 轮结束时任何步骤都不再可能"正在执行"；落库前必须归一，否则历史轮
  /// 会渲染成永久 spinner（重启也不消失，因为状态已随 artifacts 落库）。
  AgentWorkStep toTerminal() {
    if (!isRunning) return this;
    return withStatus(AgentStepStatus.done);
  }

  /// 批量归一（见 [toTerminal]）。
  static List<AgentWorkStep> normalizeTerminal(List<AgentWorkStep> steps) {
    var changed = false;
    final normalized = <AgentWorkStep>[];
    for (final step in steps) {
      if (step.isRunning) {
        normalized.add(step.toTerminal());
        changed = true;
      } else {
        normalized.add(step);
      }
    }
    return changed ? normalized : steps;
  }

  Map<String, dynamic> toJson() => {
        'toolName': toolName,
        if (callId.isNotEmpty) 'callId': callId,
        if (argsPreview.isNotEmpty) 'argsPreview': argsPreview,
        if (title.isNotEmpty) 'title': title,
        if (output.isNotEmpty) 'output': output,
        'status': status.name,
        if (durationMs > 0) 'durationMs': durationMs,
        if (stepIndex > 0) 'stepIndex': stepIndex,
        if (startedAtMs != null) 'startedAtMs': startedAtMs,
        if (order != null) 'order': order,
      };

  /// 反序列化 agent_steps 字段（数据库 TEXT 存储 JSON 数组）
  static List<AgentWorkStep> listFromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return const [];
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! List) return const [];
      return decoded
          .map((e) => AgentWorkStep.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 序列化 agent_steps 字段
  static String listToJsonString(List<AgentWorkStep> steps) {
    return jsonEncode(steps.map((s) => s.toJson()).toList());
  }
}

/// 导演模式本轮工作摘要（L1 过程行的步数/时长/token 数据源）
class AgentWorkSummary {
  const AgentWorkSummary({
    required this.steps,
    required this.totalTokens,
    required this.durationMs,
    this.deliveryChannel = 'tool_args',
    this.lastPromptTokens,
    this.lastCompletionTokens,
    this.lastCacheReadTokens,
    this.styleLintHits,
  });

  /// 从 agent_summary 列 JSON 解析（旧数据缺列时不会被调用）
  factory AgentWorkSummary.fromJson(Map<String, dynamic> json) {
    return AgentWorkSummary(
      steps: (json['steps'] as num?)?.toInt() ?? 0,
      totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      // 旧轮次无此列：prose 契约之前的轮次按文本回退口径留档
      deliveryChannel: json['deliveryChannel'] as String? ?? 'text_fallback',
      // 上下文用量指示：旧 JSON 无字段 → null
      lastPromptTokens: (json['lastPromptTokens'] as num?)?.toInt(),
      lastCompletionTokens: (json['lastCompletionTokens'] as num?)?.toInt(),
      lastCacheReadTokens: (json['lastCacheReadTokens'] as num?)?.toInt(),
      // 风格漂移监测（长会话退化治理）：旧 JSON 无字段 → null，
      // 不参与漂移统计
      styleLintHits: (json['styleLintHits'] as num?)?.toInt(),
    );
  }

  final int steps;
  final int totalTokens;
  final int durationMs;

  /// 正文交付通道留痕（正文交付契约 §2.2：tool_args = prose 参数提交；
  /// text_fallback = 通道 B/C 文本收割。无新表，随 agent_summary 落库）
  final String deliveryChannel;

  /// 该轮最后一次请求的真实 prompt/completion/缓存读 token
  /// （上下文用量指示 §3.1）。null = 旧轮次（实施前），UI 显示空环。
  final int? lastPromptTokens;
  final int? lastCompletionTokens;
  final int? lastCacheReadTokens;

  /// 该轮完稿 lint 的最终违规数（长会话退化治理  风格漂移监测的
  /// 留痕口径；含定向重写后的终值）。null = 旧轮次（实施前），不参与
  /// 漂移统计；0 = 干净轮。
  final int? styleLintHits;

  /// 旧会话回填用（仅内存补 lastPromptTokens，不回写 DB）
  AgentWorkSummary copyWith({int? lastPromptTokens}) {
    return AgentWorkSummary(
      steps: steps,
      totalTokens: totalTokens,
      durationMs: durationMs,
      deliveryChannel: deliveryChannel,
      lastPromptTokens: lastPromptTokens ?? this.lastPromptTokens,
      lastCompletionTokens: lastCompletionTokens,
      lastCacheReadTokens: lastCacheReadTokens,
      styleLintHits: styleLintHits,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'steps': steps,
      'totalTokens': totalTokens,
      'durationMs': durationMs,
      'deliveryChannel': deliveryChannel,
    };
    // 缺省字段不写入：旧数据保持旧形态，零兼容成本
    if (lastPromptTokens != null) json['lastPromptTokens'] = lastPromptTokens;
    if (lastCompletionTokens != null) {
      json['lastCompletionTokens'] = lastCompletionTokens;
    }
    if (lastCacheReadTokens != null) {
      json['lastCacheReadTokens'] = lastCacheReadTokens;
    }
    if (styleLintHits != null) json['styleLintHits'] = styleLintHits;
    return json;
  }
}

/// 累计器分项落 [AgentWorkSummary] 前的口径闸：非正值（端点未回 usage
/// 时累计器留 0）映射为 null——null 才走「—」/空环展示并放行旧会话
/// 回填探针；0 会伪装成「真实为 0」污染面板（内测反馈「全是 —」排查）。
int? positiveOrNullOrNull(int value) => value > 0 ? value : null;

/// 待回答的导演问题（ask_user 横幅展示态，体验重构）
class AgentAskPrompt {
  const AgentAskPrompt({required this.question, this.options = const []});

  final String question;

  /// 可选答案（空 = 自由输入）
  final List<String> options;
}

/// 待确认的工具写入（监督模式审批横幅展示态，体验重构）
class AgentApprovalPrompt {
  const AgentApprovalPrompt({
    required this.toolName,
    required this.summary,
    this.changes = const [],
    this.pendingPriorChanges = 0,
  });

  /// 工具名（审计标识，横幅主体用人话摘要）
  final String toolName;

  /// 人话摘要（如「修订设定集 · 2 处」）
  final String summary;

  /// 结构化变更明细（2026-10-15 批 B：干跑投影合成；空列表 = 无明细可
  /// 展示或组装降级，横幅退化为现状纯摘要）
  final List<AgentApprovalChange> changes;

  /// 本轮此前已批准暂存的变更条数（脚注提示「收笔时统一提交」用）
  final int pendingPriorChanges;
}

/// 审批变更的种类徽标（纯展示模型；不触碰 facts 层 FactAction 枚举）
enum ApprovalChangeKind {
  createEntity,
  updateAttr,
  appendList,
  removeFromList,
  addAlias,
  archiveEntity,
  merge,
  mergeNote,
  entitySnapshot,
  anchor,
  eventMemory,
}

/// 单条审批变更的展示单元（2026-10-15 批 B）
///
/// 由审批投影器（干跑）合成：before 为库侧现查旧值、after 为模型意图
/// 新值；转写/跳过说明进 [note]（已映射人话）。纯展示模型，不进 facts 层。
class AgentApprovalChange {
  const AgentApprovalChange({
    required this.entityName,
    required this.kind,
    this.attrKey,
    this.before,
    this.after,
    this.note,
    this.reason,
    this.confidence,
    this.effective = true,
  });

  /// 人话定位（实体主名；merge 类为「源 → 目标」；锚线/事件类可为空串）
  final String entityName;

  /// 属性名（update/append/remove 类必有；事件/锚线类可为 null）
  final String? attrKey;

  final ApprovalChangeKind kind;

  /// 变更前值（新建类为 null；list 类为旧 JSON 串，展示层解析）
  final String? before;

  /// 变更后值（归档类为 null；append/remove 为单条目值）
  final String? after;

  /// 转写/跳过说明（如「值相同，不会产生变化」「重名，将转为新增别名」）
  final String? note;

  /// 模型给出的修改理由（deltas 自带，判断「一时表演 vs 真性格」的证据链）
  final String? reason;

  /// 模型置信度 1–5（低置信度徽标提示）
  final int? confidence;

  /// 是否实际生效（false = 被防护跳过/值相同不会落库，UI 灰显带说明；
  /// true 含转写后生效——note 携带转写说明）
  final bool effective;
}
