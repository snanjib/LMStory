import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';

/// 工具权限档位（读/写/控制三分，删除类能力永不注册）
enum AgentToolPermission {
  /// 只读（检索/查询）——默认 allow
  readOnly,

  /// 写入（记忆库/大纲等）——默认 allow，可切 ask（Watch Mode）
  write,

  /// 控制（ask_user / finish_round 等流程控制）
  control,
}

/// 工具执行上下文（进入管线后不可变；cancellation 是唯一活对象）
class AgentToolInvocation {
  const AgentToolInvocation({
    required this.callId,
    required this.toolName,
    required this.stepIndex,
    required this.cancellation,
    this.sessionId = '',
    this.onProgress,
    this.finishReason,
    this.turnUsage,
  });

  final String callId;
  final String toolName;
  final int stepIndex;
  final String sessionId;
  final AgentCancellationToken cancellation;

  /// 父轮 usage 累计器（：spawn 工具把子代理消耗并账进父轮预算；
  /// null = 无预算归集场景）
  final AgentUsageAccumulator? turnUsage;

  /// 执行中推送进度（过程卡"正在检索…"）
  final void Function(String progress)? onProgress;

  /// 产生本次工具调用的模型响应结束原因（正文交付契约 §2.4：finish_round
  /// 守卫用它识别「输出上限截断」；null = 未知/非流式回退无此信息）
  final String? finishReason;
}

/// 工具结果统一信封（opencode 式，设计报告 §7.4）
class AgentToolResult {
  const AgentToolResult({
    required this.title,
    required this.output,
    this.metadata,
    this.isError = false,
    this.terminal = false,
    this.outputSchema,
    this.extraMaxStepsDelta = 0,
    this.phaseSoftLandingNotice,
  });

  factory AgentToolResult.success({
    required String title,
    required String output,
    Map<String, dynamic>? metadata,
    Map<String, String>? outputSchema,
    int extraMaxStepsDelta = 0,
    String? phaseSoftLandingNotice,
  }) =>
      AgentToolResult(
        title: title,
        output: output,
        metadata: metadata,
        outputSchema: outputSchema,
        extraMaxStepsDelta: extraMaxStepsDelta,
        phaseSoftLandingNotice: phaseSoftLandingNotice,
      );

  factory AgentToolResult.failure({
    required String title,
    required String output,
    Map<String, dynamic>? metadata,
  }) =>
      AgentToolResult(
        title: title,
        output: output,
        metadata: metadata,
        isError: true,
      );

  /// 终结轮次（finish_round / finish_maintenance：事务提交成功后由 runner 停轮）
  factory AgentToolResult.terminal({
    required String title,
    required String output,
    Map<String, dynamic>? metadata,
    Map<String, String>? outputSchema,
  }) =>
      AgentToolResult(
        title: title,
        output: output,
        metadata: metadata,
        terminal: true,
        outputSchema: outputSchema,
      );

  /// 给 UI 的短标题（过程卡一行字）
  final String title;

  /// 给模型的文本（错误信息必须可操作：告诉模型怎么改）
  final String output;

  /// 结构化元数据（过程卡/时间线渲染，不进模型上下文）
  final Map<String, dynamic>? metadata;

  /// 本工具成功输出的结构声明（最小版）：metadata 必含键 → 类型名
  ///（'string' / 'int' / 'number' / 'boolean'，见 [kToolOutputSchemaTypes]）。
  ///
  /// 工具在成功回执上随信封携带自己的 schema 常量，管线 post-execute
  /// 据此校验（[validateToolOutputSchema]），违规发 INVALID_TOOL_OUTPUT
  /// 信封——先「警告不拦截」灰度（信封附在输出尾部），拦截开关见管线
  /// 的 enforceOutputSchema 字段。失败信封不校验（错误路径的 metadata
  /// 形状不属契约）。
  final Map<String, String>? outputSchema;

  final bool isError;

  /// 控制类工具终结轮次的标记（finish_round / finish_maintenance）
  final bool terminal;

  /// 非终结工具触发阶段切换时追加的步数预算增量（0 = 不追加）。
  final int extraMaxStepsDelta;

  /// 非终结工具触发阶段切换时替换的预算软着陆提示词（null = 不覆盖）。
  final String? phaseSoftLandingNotice;
}

/// Agent 工具抽象（Domain）
///
/// 与 Core 的 [ToolDefinition]（纯 schema 值对象）配合：
/// `agentToolToDefinition` 把本接口的静态描述转成 LLM 请求的 tools 元素。
abstract class AgentTool {
  String get name;
  String get description;

  /// JSON Schema（`{type: 'object', properties: {...}, required: [...]}`）
  Map<String, dynamic> buildParametersSchema();

  AgentToolPermission get permission;

  /// 工具体。抛出的异常由管线捕获并转为可操作的失败信封，不中断轮次。
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  );
}

/// AgentTool → LLM 请求工具定义
ToolDefinition agentToolToDefinition(AgentTool tool) {
  return ToolDefinition(
    name: tool.name,
    description: tool.description,
    parameters: tool.buildParametersSchema(),
  );
}

List<ToolDefinition> agentToolsToDefinitions(List<AgentTool> tools) {
  return tools.map(agentToolToDefinition).toList();
}

/// 参数深拷贝（进管线即快照，防止钩子间意外共享可变状态）
Map<String, dynamic> deepCopyArguments(Map<String, dynamic> args) {
  final encoded = jsonEncode(args);
  return jsonDecode(encoded) as Map<String, dynamic>;
}

/// 整数参数安全解析
///
/// 弱模型容错：接受 int / num / 整数字符串。非法或越界时返回 null 并给出
/// **可行动错误文本**（指明字段名与期望类型/范围），由工具体原样放进失败
/// 信封——禁止 `as int?` 强转把 Dart 类型错误原文喂给模型。
/// 参数缺失且给了 [fallback] 时用默认值；缺失且无默认值同样产出错误文本。
({int? value, String? error}) parseIntegerArg(
  Map<String, dynamic> arguments,
  String key, {
  int? min,
  int? max,
  int? fallback,
}) {
  String boundsHint() {
    final lower = min?.toString() ?? '不限';
    final upper = max?.toString() ?? '不限';
    return '$lower-$upper';
  }

  String rangeHint() => '整数（允许范围 ${boundsHint()}）';

  final raw = arguments[key];
  if (raw == null) {
    if (fallback != null) return (value: fallback, error: null);
    return (
      value: null,
      error: '参数「$key」缺失，应为${rangeHint()}。请补全后重试。',
    );
  }
  int? parsed;
  if (raw is int) {
    parsed = raw;
  } else if (raw is num) {
    parsed = raw.toInt();
  } else if (raw is String) {
    parsed = int.tryParse(raw.trim());
  }
  if (parsed == null) {
    return (
      value: null,
      error: '参数「$key」应为${rangeHint()}，收到「$raw」。请修正类型后重试。',
    );
  }
  if ((min != null && parsed < min) || (max != null && parsed > max)) {
    return (
      value: null,
      error: '参数「$key」=$parsed 超出允许范围 ${boundsHint()}。请调整后重试。',
    );
  }
  return (value: parsed, error: null);
}

/// 字符串列表参数安全解析
///
/// 弱模型容错：接受字符串数组、JSON 数组字符串，以及逗号/顿号/分号/
/// 竖线/换行分隔的普通字符串。缺失或无法解析时返回空列表；
/// 元素去空白、丢弃空项并去重（保留首次出现顺序）。
List<String> parseStringListArg(
  Map<String, dynamic> arguments,
  String key,
) {
  final raw = arguments[key];
  if (raw == null) return const [];
  if (raw is String) return _normalizeStringItems(_splitStringListArg(raw));
  if (raw is List) return _normalizeStringItems(raw);
  if (raw is num || raw is bool) return [raw.toString()];
  return const [];
}

Iterable<dynamic> _splitStringListArg(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  if (text.startsWith('[')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return decoded;
    } on FormatException {
      // 不是合法 JSON：退回分隔符拆分
    }
  }
  return text.split(RegExp(r'[,，、;；|｜\n]+'));
}

List<String> _normalizeStringItems(Iterable<dynamic> items) {
  final result = <String>[];
  final seen = <String>{};
  for (final item in items) {
    final text = switch (item) {
      final String value => value.trim(),
      num() || bool() => item.toString(),
      _ => '',
    };
    if (text.isEmpty || !seen.add(text)) continue;
    result.add(text);
  }
  return result;
}

// ==================== 输出 schema（最小版）====================

/// 输出 schema 允许的类型名（最小集：四种标量；结构化嵌套不做）
const Set<String> kToolOutputSchemaTypes = {
  'string',
  'int',
  'number',
  'boolean',
};

bool _schemaTypeMatches(Object? value, String typeName) {
  switch (typeName) {
    case 'string':
      return value is String;
    case 'int':
      return value is int;
    case 'number':
      return value is num;
    case 'boolean':
      return value is bool;
    default:
      return false;
  }
}

/// 校验成功回执是否满足其声明的 outputSchema
///
/// 返回违规描述清单（空 = 通过）。失败信封与未声明 schema 的结果恒通过。
List<String> validateToolOutputSchema(AgentToolResult result) {
  final schema = result.outputSchema;
  if (result.isError || schema == null || schema.isEmpty) return const [];
  final issues = <String>[];
  for (final entry in schema.entries) {
    final value = result.metadata?[entry.key];
    if (value == null) {
      issues.add('缺少键「${entry.key}」（期望 ${entry.value}）');
    } else if (!_schemaTypeMatches(value, entry.value)) {
      issues.add(
        '键「${entry.key}」期望 ${entry.value}，实际 ${value.runtimeType}',
      );
    }
  }
  return issues;
}

/// schema 的人话形态（进 INVALID_TOOL_OUTPUT 信封，含期望结构）
String formatToolOutputSchema(Map<String, String> schema) {
  final entries = schema.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  return '{$entries}';
}

// ==================== 输出预算====================

/// 工具输出默认字符预算（对照 Claude Code 25k / opencode 2000 行 50KB 量级；
/// 差距剖析 ：read_story/read_skill/spawn 交付物此前无上限直进上下文）
const int kDefaultToolOutputLimit = 20000;

/// 超长工具输出截断：保留 head（预算的 60%）+ tail（30%），中间替换为
/// 明确省略标记 + 自指引（教模型如何取回原文），原长记入 metadata
/// （供轨迹/UI，不进模型上下文）。
///
/// 纯截断函数，豁免判定（ask_user / finish_round）由管线层负责。
AgentToolResult applyToolOutputBudget(AgentToolResult result, int limit) {
  final output = result.output;
  if (output.length <= limit) return result;
  final headLength = (limit * 0.6).round();
  final tailLength = (limit * 0.3).round();
  final omitted = output.length - headLength - tailLength;
  // 单条字面量：中文文案拼接点无空格会触发 lint
  final marker =
      '\n……【输出超长已截断：已省略约 $omitted 字符。需要完整原文请用 search_story 换更精确的关键词缩小范围，或用 read_story 按单轮取回】……\n';
  return AgentToolResult(
    title: result.title,
    output:
        '${output.substring(0, headLength)}$marker${output.substring(output.length - tailLength)}',
    metadata: {
      ...?result.metadata,
      'outputTruncated': true,
      'originalOutputLength': output.length,
    },
    isError: result.isError,
    terminal: result.terminal,
    // 截断重建回执时保留 schema 声明（校验在截断前，字段随信封
    // 完整传递供诊断）
    outputSchema: result.outputSchema,
    extraMaxStepsDelta: result.extraMaxStepsDelta,
    phaseSoftLandingNotice: result.phaseSoftLandingNotice,
  );
}
