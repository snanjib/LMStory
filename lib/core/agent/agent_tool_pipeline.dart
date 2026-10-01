import 'dart:async';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/utils/logger.dart';

/// 工具执行请求（进入管线的身份快照）
class ToolExecutionRequest {
  const ToolExecutionRequest({
    required this.callId,
    required this.toolName,
    required this.arguments,
    required this.permission,
  });

  final String callId;
  final String toolName;

  /// 深拷贝后的参数快照（钩子只能基于副本改写，不能污染原始值）
  final Map<String, dynamic> arguments;

  final AgentToolPermission permission;
}

/// pre-execute 决策
sealed class AgentPreExecuteDecision {
  const AgentPreExecuteDecision();
}

/// 放行（可携带改写后的参数）
class AgentPreExecuteAllow extends AgentPreExecuteDecision {
  const AgentPreExecuteAllow({this.rewrittenArgs});

  final Map<String, dynamic>? rewrittenArgs;
}

/// 拒绝（原因会以可操作文本回带模型）
class AgentPreExecuteDeny extends AgentPreExecuteDecision {
  const AgentPreExecuteDeny(this.reason);

  final String reason;
}

typedef AgentPreExecuteHook = Future<AgentPreExecuteDecision> Function(
  ToolExecutionRequest request,
);

/// 单调 guard：只能 deny（返回原因）或弃权（返回 null），没有 allow 分支
///
/// 因此无论监听器顺序如何，任何 guard 的拒绝都不可能被后续钩子翻回允许
/// （dsh 工具管线核心纪律，设计报告 §7.4）。
typedef AgentToolGuard = String? Function(ToolExecutionRequest request);

/// 审批结论
sealed class AgentApprovalVerdict {
  const AgentApprovalVerdict();
}

class AgentApprovalGranted extends AgentApprovalVerdict {
  const AgentApprovalGranted();
}

/// 用户明确拒绝（可带反馈，回带模型）
class AgentApprovalDenied extends AgentApprovalVerdict {
  const AgentApprovalDenied(this.feedback);

  final String? feedback;
}

/// 无审批通道 / 审批异常（fail-closed：视同拒绝，但 reason 可区分）
class AgentApprovalUnavailable extends AgentApprovalVerdict {
  const AgentApprovalUnavailable(this.reason);

  final String reason;
}

/// 审批 seam（fail-closed）
///
/// 无 answerer / 异常 / 非法值 → `AgentApprovalUnavailable`；
/// 工具侧把非 grant 全部映射 deny 且文案各异，模型分得清
/// "人说 no"和"没有审批通道"。
// ignore: one_member_abstracts, 单方法抽象接口为审批通道多实现（UI/无人值守）所需
abstract class AgentApprovalSeam {
  Future<AgentApprovalVerdict> requestApproval(ToolExecutionRequest request);
}

/// 无人值守审批 seam：全部返回 unavailable（fail-closed 兜底）
class UnattendedApprovalSeam implements AgentApprovalSeam {
  const UnattendedApprovalSeam();

  @override
  Future<AgentApprovalVerdict> requestApproval(
    ToolExecutionRequest request,
  ) async {
    return const AgentApprovalUnavailable('当前无审批通道（无人值守模式）');
  }
}

/// post-execute 决策
sealed class AgentPostExecuteDecision {
  const AgentPostExecuteDecision();
}

class AgentPostExecuteAccept extends AgentPostExecuteDecision {
  const AgentPostExecuteAccept();
}

/// 替换结果（内容审计/脱敏）
class AgentPostExecuteReplace extends AgentPostExecuteDecision {
  const AgentPostExecuteReplace(this.result);

  final AgentToolResult result;
}

typedef AgentPostExecuteHook = Future<AgentPostExecuteDecision> Function(
  ToolExecutionRequest request,
  AgentToolResult result,
);

/// 工具执行中的进度上报（：工具体内 `invocation.onProgress?.call`
/// 的出口；null = 无监听者，工具内调用为空操作）
typedef AgentToolProgressReporter = void Function(String message);

/// 管线执行结果
class ToolPipelineOutcome {
  const ToolPipelineOutcome({
    required this.result,
    required this.wasDenied,
  });

  final AgentToolResult result;

  /// 是否被 pre-execute / guard / 审批拒绝
  final bool wasDenied;
}

/// 工具执行管线：pre-execute → 单调 guard → 审批 → 工具体 → post-execute
///
/// 顺序与各环节职责对齐 dsh `tools/*` 瀑布（设计报告 §7.4）：
/// 1. **pre-execute**：逐个执行；首个 Deny 短路；Allow.rewrittenArgs
///    替换后续环节（含工具体）看到的参数。
/// 2. **guard**（单调）：任意 guard 返回非 null 即拒绝，无翻案可能。
/// 3. **审批**（fail-closed）：仅当 `approvalRequired`（Watch Mode 开启
///    且工具为写/控制档）时询问；非 grant 一律拒绝。
/// 4. **工具体**：参数为 pre-execute 改写后的快照副本；异常捕获为
///    可操作失败信封，不中断轮次。
/// 4.5 **输出预算**：非豁免工具的超长输出 head+tail 截断并附
///    取回自指引，原长记入 metadata。
/// 5. **post-execute**：可替换结果。
class AgentToolPipeline {
  AgentToolPipeline({
    List<AgentPreExecuteHook>? preExecuteHooks,
    List<AgentToolGuard>? guards,
    this.approvalSeam = const UnattendedApprovalSeam(),
    List<AgentPostExecuteHook>? postExecuteHooks,
    this.toolOutputLimit = kDefaultToolOutputLimit,
    this.executionTimeout = const Duration(seconds: 120),
    this.enforceOutputSchema = false,
    Logger? logger,
  })  : preExecuteHooks = List.unmodifiable(preExecuteHooks ?? const []),
        guards = List.unmodifiable(guards ?? const []),
        postExecuteHooks = List.unmodifiable(postExecuteHooks ?? const []),
        _logger = logger;

  final List<AgentPreExecuteHook> preExecuteHooks;
  final List<AgentToolGuard> guards;

  /// 审批 seam（null 时用 fail-closed 的无人值守实现）
  final AgentApprovalSeam approvalSeam;
  final List<AgentPostExecuteHook> postExecuteHooks;

  /// 工具输出字符预算；null = 禁用截断。
  // ignore: avoid_redundant_argument_values, 默认值即推荐值
  final int? toolOutputLimit;

  /// 单工具执行超时；null = 禁用。
  ///
  /// Dart 无法强杀已启动的异步体：超时 = **放弃等待该 future 并继续本轮**
  ///（返回可行动失败信封，轮次不中断）。control 档豁免——ask_user 有
  /// 自身 HITL 超时、spawn 有子代理预算、finish_round 是提交通道。
  // ignore: avoid_redundant_argument_values, 默认值即推荐值
  final Duration? executionTimeout;

  /// INVALID_TOOL_OUTPUT 是否拦截。默认 false = 灰度档「警告不
  /// 拦截」：违规信封附在输出尾部、原输出保留；true = 违规直接替换为
  /// 失败信封。灰度一轮确认无误杀后再翻 true。
  final bool enforceOutputSchema;

  final Logger? _logger;

  /// 输出预算豁免清单：ask_user（HITL 回答本身短且是用户原话）与
  /// finish_round（提交回执，terminal 语义）。
  /// 注意 spawn 虽是 control 档但**不豁免**——其交付物是  点名的
  /// 无上不封口之一，恰恰是本预算的主要对象。
  static const Set<String> _outputBudgetExempt = {'ask_user', 'finish_round'};

  /// 执行一次工具调用
  ///
  /// [approvalRequired] 由调用方（runner/控制器）按 Watch Mode 与
  /// [AgentTool.permission] 决定；管线不拥有策略（preset 层不拥有 enforcement）。
  Future<ToolPipelineOutcome> execute({
    required AgentTool tool,
    required String callId,
    required int stepIndex,
    required String sessionId,
    required AgentCancellationToken cancellation,
    required Map<String, dynamic> arguments,
    bool approvalRequired = false,
    AgentToolProgressReporter? onProgress,
    String? finishReason,
    AgentUsageAccumulator? turnUsage,
  }) async {
    var effectiveArgs = deepCopyArguments(arguments);
    var request = ToolExecutionRequest(
      callId: callId,
      toolName: tool.name,
      arguments: effectiveArgs,
      permission: tool.permission,
    );

    // 1. pre-execute 钩子（可拒/可改写参数）
    for (final hook in preExecuteHooks) {
      final decision = await hook(request);
      switch (decision) {
        case AgentPreExecuteDeny(:final reason):
          return _denied(request, reason);
        case AgentPreExecuteAllow(:final rewrittenArgs):
          if (rewrittenArgs != null) {
            effectiveArgs = deepCopyArguments(rewrittenArgs);
            request = ToolExecutionRequest(
              callId: callId,
              toolName: tool.name,
              arguments: effectiveArgs,
              permission: tool.permission,
            );
          }
      }
    }

    // 2. 单调 guard（只能收紧）
    for (final guard in guards) {
      final denyReason = guard(request);
      if (denyReason != null) {
        return _denied(request, denyReason);
      }
    }

    // 3. 审批（fail-closed）
    if (approvalRequired) {
      final verdict = await _requestApprovalFailClosed(request);
      switch (verdict) {
        case AgentApprovalGranted():
          break;
        case AgentApprovalDenied(:final feedback):
          return _denied(
            request,
            feedback == null || feedback.isEmpty
                ? '用户拒绝了本次操作'
                : '用户拒绝：$feedback',
          );
        case AgentApprovalUnavailable(:final reason):
          return _denied(request, '审批不可用（$reason），按拒绝处理');
      }
    }

    // 4. 工具体（异常 → 可操作失败信封）
    AgentToolResult result;
    final stopwatch = Stopwatch()..start();
    try {
      final invocation = AgentToolInvocation(
        callId: callId,
        toolName: tool.name,
        stepIndex: stepIndex,
        sessionId: sessionId,
        cancellation: cancellation,
        //  修复：此前不透传——工具体内十余处
        // `invocation.onProgress?.call()` 全是空操作，"正在检索…"
        // 类过程提示从未到达 UI。
        onProgress: onProgress,
        finishReason: finishReason,
        turnUsage: turnUsage,
      );
      final invokeFuture = tool.invoke(invocation, effectiveArgs);
      // 单工具超时：超时 = 放弃等待该 future 并返回
      // 可行动信封（轮次继续）；底层异步体无法强杀，可能稍后仍完成落库
      // ——信封措辞与该语义一致。control 档豁免（见 [executionTimeout]）。
      final timeout = executionTimeout;
      result = timeout == null || tool.permission == AgentToolPermission.control
          ? await invokeFuture
          : await invokeFuture.timeout(
              timeout,
              onTimeout: () => AgentToolResult.failure(
                title: '工具执行超时',
                // 单条字面量：中文文案在拼接点无空格会触发
                // missing_whitespace_between_adjacent_strings
                output:
                    '工具 ${tool.name} 执行超时（${_formatSeconds(timeout)}），已放弃等待、本轮继续。请缩小查询范围、减少读取轮数后重试，或先用已有信息继续。',
              ),
            );
    } on AgentCancelledException {
      rethrow; // 取消向上传播（轮中断语义），不吞成工具失败
    } on EmbeddingCallFailedException {
      // 致命工具异常通道——embedding 失败（fallback_on_failure
      // =false）不包装成失败信封（信封会让模型静默换路，E104 永不可达），
      // 原样上抛 → runner 判轮失败 → E104 FailureBar → 用户可选临时降级。
      rethrow;
    } on EmbeddingRateLimitedException {
      rethrow; // 同上（E104 限流子场景）
    } catch (e, st) {
      _logger?.warn(
        'Agent tool ${tool.name} threw',
        detail: 'error=$e\n$st',
      );
      result = AgentToolResult.failure(
        title: '工具执行失败',
        output: '工具 ${tool.name} 执行抛出异常：$e。'
            ' 请检查参数是否正确，或换一种方式完成目标。',
      );
    } finally {
      stopwatch.stop();
    }

    // 4.6 输出 schema 校验：在输出预算截断之前，对工具体刚产出的
    // 原始回执按其携带的 outputSchema 校验——截断/替换钩子不参与判定。
    // 灰度档（enforceOutputSchema=false）：警告信封附在输出尾部、原输出
    // 保留、不标 error；拦截档：违规直接替换为 INVALID_TOOL_OUTPUT 失败信封。
    // 审查收官 ：terminal 回执只警告不拦截——终局工具（finish_round）
    // 的副作用（事务提交）已发生，拦截信封会让 runner 循环继续、二次提交。
    final schemaIssues =
        result.terminal ? const <String>[] : validateToolOutputSchema(result);
    if (schemaIssues.isNotEmpty) {
      _logger?.warn(
        'INVALID_TOOL_OUTPUT ${tool.name}',
        detail: 'issues=${schemaIssues.join('; ')}',
      );
      final schemaText = formatToolOutputSchema(result.outputSchema!);
      final issuesText = schemaIssues.join('；');
      if (enforceOutputSchema) {
        result = AgentToolResult.failure(
          title: 'INVALID_TOOL_OUTPUT',
          output: '工具 ${tool.name} 的输出不符合声明结构：$issuesText。'
              ' 期望 schema：$schemaText。'
              ' 这是工具实现故障，请换一种方式完成任务，不要原样重试。',
        );
      } else {
        result = AgentToolResult(
          title: result.title,
          output:
              '${result.output}\n【INVALID_TOOL_OUTPUT 警告】输出与声明结构不符：$issuesText。'
              ' 期望 schema：$schemaText。本警告暂不拦截，请以实际内容为准。',
          metadata: {
            ...?result.metadata,
            'invalidToolOutput': schemaIssues,
          },
          isError: result.isError,
          terminal: result.terminal,
          outputSchema: result.outputSchema,
        );
      }
    }

    // 4.5 输出预算：超长输出 head+tail 截断 + 取回自指引。
    // 在 post-execute 钩子之前执行，保证钩子（含替换结果）看到的输出也已受预算约束。
    if (toolOutputLimit != null && !_outputBudgetExempt.contains(tool.name)) {
      result = applyToolOutputBudget(result, toolOutputLimit!);
    }

    // 5. post-execute 钩子（可替换结果）
    for (final hook in postExecuteHooks) {
      final decision = await hook(request, result);
      if (decision is AgentPostExecuteReplace) {
        result = decision.result;
      }
    }

    return ToolPipelineOutcome(result: result, wasDenied: false);
  }

  Future<AgentApprovalVerdict> _requestApprovalFailClosed(
    ToolExecutionRequest request,
  ) async {
    try {
      final verdict = await approvalSeam.requestApproval(request);
      return switch (verdict) {
        AgentApprovalGranted() ||
        AgentApprovalDenied() ||
        AgentApprovalUnavailable() =>
          verdict,
      };
    } catch (e) {
      return AgentApprovalUnavailable('审批通道异常：$e');
    }
  }

  /// 信封用的人话秒数（毫秒向上取整：120s → "120 秒"，50ms → "1 秒"）
  static String _formatSeconds(Duration d) {
    var seconds = d.inSeconds;
    if (d.inMilliseconds % 1000 > 0) seconds++;
    return '$seconds 秒';
  }

  ToolPipelineOutcome _denied(ToolExecutionRequest request, String reason) {
    return ToolPipelineOutcome(
      wasDenied: true,
      result: AgentToolResult.failure(
        title: '调用被拒绝',
        output: '工具 ${request.toolName} 的调用被拒绝：$reason。'
            ' 请根据原因调整参数或改用其他方式；不要原样重试。',
      ),
    );
  }
}
