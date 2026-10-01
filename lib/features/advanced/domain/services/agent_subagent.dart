import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/doom_loop_detector.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/features/advanced/domain/services/agent_event_bus.dart';

/// 子代理 provider 种类（设计报告 §7.5，决策 8）
///
/// - `spawn`：进程内全新子会话（独立上下文，只传任务文本）——本期实现
/// - `fork`（父日志前缀为种子）/ `acp` / `dshSdk`（跨产品/跨端）——预留；
///   请求未注册的 provider 直接抛错（能力位预检 fail-loud，不静默降级）
enum AgentSubagentProviderKind { spawn, fork, acp, dshSdk }

/// 通用子代理执行器（独立上下文，brief 定义角色）
///
/// system prompt = 固定边界壳（[boundaryShell]，不含角色）+ brief 原文：
/// 主编辑通过 brief 定义子代理是什么（设定考古员、连载校对员、试笔……），
/// harness 不预设角色。
///
/// 工具档位（代替唯一白名单）：
/// - `research`：只读检索（能力位 fail-loud，缺失即抛）
/// - `plain`：空工具集（纯文本任务：试笔片段、起名、第二意见）
/// - **有意不设写档**：写操作只在主上下文，保持单一事务边界
///
/// 递归防护：档位白名单不含 spawn，天然无递归（有意）。
class SubagentRunner {
  SubagentRunner({
    required AgentLlmGateway gateway,
    required this.endpoint,
    required List<AgentTool> availableTools,
    this.defaultMaxSteps = 6,
    this.defaultMaxDuration = const Duration(minutes: 2),
    this.defaultMaxTotalTokens,
    this.doomLoopThreshold = 8,
    AgentEventSink? Function()? externalEventsResolver,
  })  : _gateway = gateway,
        _externalEventsResolver = externalEventsResolver,
        _toolsByName = {
          for (final tool in availableTools) tool.name: tool,
        };

  final AgentLlmGateway _gateway;
  final AgentModelEndpoint endpoint;
  final Map<String, AgentTool> _toolsByName;
  final int defaultMaxSteps;
  final Duration defaultMaxDuration;

  /// 单次 spawn 累计 token 上限（null = 不限制；
  /// 装配点按 主轮 contextWindow × subagent.token_budget_ratio 预算好）。
  final int? defaultMaxTotalTokens;

  /// 子代理 doom 阈值随
  /// advanced.doom_loop.threshold（此前固定默认 8，与主循环配置脱节）。
  final int doomLoopThreshold;

  /// 外部事件出口解析器（：子代理事件多播——spawn 内部可观测）。
  ///
  /// 惰性解析（调用时取）：主侧 durable sink 在工具装配之后才创建，
  /// 构造期拿不到引用。null / 解析为 null = 维持纯缓冲（旧行为）。
  final AgentEventSink? Function()? _externalEventsResolver;

  /// 工具档位（research 档即能力位清单；plain 为空）
  static const Map<String, List<String>> toolsets = {
    'research': [
      'search_story',
      'read_story',
      'query_facts',
      'read_compact_summary',
      'read_skill',
    ],
    'plain': [],
  };

  /// 固定边界壳（不含角色，角色由 brief 定义）
  static const String boundaryShell = '你是被主编辑派出的子代理，在独立上下文中一次性完成下述任务书。\n'
      '纪律：只做任务书交代的事；只使用提供给你的工具（如无工具则纯思考作答）；\n'
      '找不到的信息明确说"未找到"，不猜测。最后输出交付物：结论先行，关键事实带轮号引用，\n'
      '未决项列出。不输出过程叙述。';

  /// 能力位求交集（子代理白名单与主代理 allow 集求交集）。
  ///
  /// 旧实现要求 research 档 5 工具全部在场，deny 任一只读工具后
  /// spawn(research) 必抛 StateError 且失败信封建议模型"调整任务书重试"
  /// （对模型不可行动）。现改为按可用集过滤；交集为空时退化为纯思考
  /// 作答（boundaryShell 已声明"如无工具则纯思考作答"）。
  List<String> effectiveTools(String toolset) {
    final whitelist = toolsets[toolset];
    if (whitelist == null) {
      throw ArgumentError.value(toolset, 'toolset', '未知工具档位');
    }
    return [
      for (final name in whitelist)
        if (_toolsByName.containsKey(name)) name,
    ];
  }

  /// 运行子代理（独立 AgentRunner + 独立预算；随父取消）
  ///
  /// [brief] 任务书原文（角色、目标、交付物格式），进 system prompt。
  /// [toolset] 工具档位（research/plain，见 [toolsets]）。
  /// [maxSteps] 步数上限（null = [defaultMaxSteps]）。
  Future<AgentTurnResult> run({
    required String brief,
    required String toolset,
    required AgentCancellationToken parentCancellation,
    int? maxSteps,
  }) {
    final whitelist = effectiveTools(toolset);

    final runner = AgentRunner(gateway: _gateway);
    final buffer = BufferingAgentEventSink();
    // 外部出口存在时多播（缓冲保留——SpawnTool 并账与测试断言仍读它）
    final external = _externalEventsResolver?.call();
    final sink = external == null
        ? buffer as AgentEventSink
        : CompositeAgentEventSink([buffer, external]);

    return runner.runTurn(
      AgentTurnSpec(
        sessionId: 'subagent-$toolset',
        surface: [
          AgentMessage.system('$boundaryShell\n\n【任务书】\n$brief'),
          AgentMessage.user('开始执行任务书。'),
        ],
        tools: [for (final name in whitelist) _toolsByName[name]!],
        endpoint: endpoint,
        budget: AgentBudget(
          maxSteps: maxSteps ?? defaultMaxSteps,
          maxDuration: defaultMaxDuration,
          // 预算机制走 agent_runner 软着陆→二次真停
          maxTotalTokens: defaultMaxTotalTokens,
        ),
        events: sink,
        cancellation: parentCancellation,
        callConfig: const AgentCallConfig(toolChoice: ToolChoice.auto),
        // 与主循环同一 doom 阈值源（advanced.doom_loop.threshold）
        doomLoopDetector: DoomLoopDetector(threshold: doomLoopThreshold),
      ),
    );
  }
}

/// 同任务书防重 memo
///
/// spawn 与 ask_user 同为 control 档、豁免 doom 检测——但 spawn 没有像
/// ask_user「每轮 2 次」那样的自身上限，主模型把一模一样的任务书反复
/// 派发时每次都白烧 6 步 × 2 分钟子代理。本 memo 拦截该形态：**同 brief
/// 第二次派发不真跑，直接回执上次结论**。
///
/// 语义：
/// - **单槽「最近一次」**：只记最近一次**成功交付**的任务书与结论——
///   拦截的是「紧接着重复派发同一任务书」的浪费形态；中间隔了别的
///   brief 之后再派回旧 brief 属于正常迭代（模型可能就是要重跑），真跑。
/// - 只缓存成功交付物：无结论/失败/取消不记——同 brief 重试应真跑。
/// - 会话级：由 DirectorRoundRunner 持有（每轮 spawnToolFactory 重建
///   SpawnTool，memo 跨轮存活）。
class SubagentBriefMemo {
  String? _brief;
  String? _toolset;
  int? _maxSteps;
  String? _deliverable;
  Map<String, dynamic>? _metadata;

  /// 是否命中（最近一次成功交付与本任务书完全相同）
  bool hits({
    required String brief,
    required String toolset,
    required int maxSteps,
  }) =>
      _brief == brief &&
      _toolset == toolset &&
      _maxSteps == maxSteps &&
      _deliverable != null;

  /// 缓存的交付物（hits 为 true 时非空）
  String get deliverable => _deliverable!;

  /// 缓存的回执 metadata（subagentSteps/subagentTokens/toolset）
  Map<String, dynamic> get metadata => _metadata ?? const {};

  /// 记录一次成功交付（覆盖旧槽）
  void record({
    required String brief,
    required String toolset,
    required int maxSteps,
    required String deliverable,
    required Map<String, dynamic> metadata,
  }) {
    _brief = brief;
    _toolset = toolset;
    _maxSteps = maxSteps;
    _deliverable = deliverable;
    _metadata = metadata;
  }
}

/// spawn 工具（控制档）：主编辑按任务书派出子代理
///
/// description 内嵌两个 brief 范例，教育主 agent 自己发明角色
/// （v1 的"预设即范例"方案，不做独立资产目录）。
class SpawnTool implements AgentTool {
  SpawnTool(this._subagent, {SubagentBriefMemo? briefMemo})
      : _briefMemo = briefMemo;

  /// 成功回执的输出结构声明（管线 post-execute 校验）
  static const Map<String, String> kOutputSchema = {
    'subagentSteps': 'int',
    'subagentTokens': 'int',
    'toolset': 'string',
  };

  final SubagentRunner _subagent;

  /// 同任务书防重：null = 不防重（旧接线/测试直构场景）
  final SubagentBriefMemo? _briefMemo;

  @override
  String get name => 'spawn';

  @override
  String get description =>
      '派出子代理（独立上下文，只回传交付物）。适合大范围调研、需要独立第二意见、或试写。单点查证自己用检索工具更快。brief 决定子代理是什么：\n'
      '例1（调研）：「你是设定考古员。核对‘沈青梧’从首次出场至今的关键状态变化与全部伏笔，列出每条的轮号出处，标出与当前正文冲突之处。」\n'
      '例2（校对）：「你是连载校对员。对下述正文片段与已知设定做连续性对账，只列问题与出处，不改写：〈正文〉」';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'brief': {
          'type': 'string',
          'description': '任务书：角色、目标、必须核对/包含什么、交付物格式。写给一个能力很强但不了解上下文的同事。',
        },
        'toolset': {
          'type': 'string',
          'enum': ['research', 'plain'],
          'description': 'research=可检索故事记忆；plain=纯文本任务（默认 research）',
        },
        'max_steps': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 10,
          'description': '步数上限 1-10（默认 6）',
        },
      },
      'required': ['brief'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final brief = arguments['brief']?.toString() ?? '';
    if (brief.isEmpty) {
      return AgentToolResult.failure(
        title: '参数错误',
        output: 'brief 不能为空。请写明任务书：角色、目标、必须核对/包含什么、交付物格式。',
      );
    }
    final toolsetRaw = arguments['toolset']?.toString().trim();
    final String toolset;
    if (toolsetRaw == null || toolsetRaw.isEmpty) {
      toolset = 'research'; // schema 默认档
    } else if (toolsetRaw == 'research' || toolsetRaw == 'plain') {
      toolset = toolsetRaw;
    } else {
      return AgentToolResult.failure(
        title: '参数错误',
        output: 'toolset「$toolsetRaw」只能是 research 或 plain。',
      );
    }
    // 安全解析（此前 `as num?` 遇字符串直接抛类型错误）
    final maxSteps = parseIntegerArg(
      arguments,
      'max_steps',
      min: 1,
      max: 10,
      fallback: _subagent.defaultMaxSteps,
    );
    if (maxSteps.error != null) {
      return AgentToolResult.failure(title: '参数不对', output: maxSteps.error!);
    }

    //  同任务书防重：同 brief（含 toolset/max_steps 全参一致）第二次
    // 派发直接回执上次成功结论，不再真跑子代理（spawn 豁免 doom 检测，
    // 此前同 brief 反复派发每次白烧 6 步 × 2 分钟）。回执不并账——
    // 子代理未执行，无消耗可计。
    final memo = _briefMemo;
    if (memo != null &&
        memo.hits(
          brief: brief,
          toolset: toolset,
          maxSteps: maxSteps.value ?? _subagent.defaultMaxSteps,
        )) {
      return AgentToolResult.success(
        title: '子代理交付物（回执）',
        output: '同任务书第二次派发：未重新执行，直接回执上次结论。'
            '如需重跑请改写任务书。\n──\n${memo.deliverable}',
        metadata: memo.metadata,
        outputSchema: kOutputSchema,
      );
    }

    final briefPreview =
        brief.length > 40 ? '${brief.substring(0, 40)}…' : brief;
    invocation.onProgress?.call('子代理执行中：$briefPreview');
    try {
      final result = await _subagent.run(
        brief: brief,
        toolset: toolset,
        parentCancellation: invocation.cancellation,
        maxSteps: maxSteps.value ?? _subagent.defaultMaxSteps,
      );
      final deliverable = result.lastAssistantText;
      // 子代理消耗并账进父轮——maxTotalTokens 预算从此对 spawn 生效
      //（明细保留在工具 metadata 供诊断）
      invocation.turnUsage?.merge(result.usage, carryLastRequest: false);
      if (deliverable.isEmpty) {
        return AgentToolResult.success(
          title: '子代理无结论',
          output:
              '子代理结束但未输出交付物（${result.reason.name}）。请自行用检索工具查证，或把任务书写得更具体后重新 spawn。',
          metadata: {
            'subagentSteps': result.steps,
            'subagentTokens': result.usage.totalTokens,
            'toolset': toolset,
          },
          outputSchema: kOutputSchema,
        );
      }
      //  防重：只缓存成功交付物（无结论/失败不记，同 brief 重试应真跑）
      final successMetadata = {
        'subagentSteps': result.steps,
        'subagentTokens': result.usage.totalTokens,
        'toolset': toolset,
      };
      _briefMemo?.record(
        brief: brief,
        toolset: toolset,
        maxSteps: maxSteps.value ?? _subagent.defaultMaxSteps,
        deliverable: deliverable,
        metadata: successMetadata,
      );
      return AgentToolResult.success(
        title: '子代理交付物',
        output: deliverable,
        metadata: successMetadata,
        outputSchema: kOutputSchema,
      );
    } on AgentCancelledException {
      rethrow;
    } catch (e) {
      return AgentToolResult.failure(
        title: '子代理失败',
        output: '子代理执行失败：$e。请改用检索工具自行查证，或调整任务书后重试。',
      );
    }
  }
}
