import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/calc/calc_date_engine.dart';
import 'package:lmstory/core/agent/calc/calc_eval_engine.dart';
import 'package:lmstory/core/agent/calc/calc_limits.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';

/// Read-only exact arithmetic tool. Results are backstage references and never
/// commit story text, memories, or facts.
class CalcEvalTool implements AgentTool {
  CalcEvalTool(this._deps, {CalcEvalEngine engine = const CalcEvalEngine()})
      : _engine = engine;
  final AgentToolDeps _deps;
  final CalcEvalEngine _engine;

  static const Map<String, String> kOutputSchema = {
    'tool': 'string',
    'expression': 'string',
    'exactFraction': 'string',
    'decimal': 'string',
    'truncated': 'boolean',
  };

  @override
  String get name => 'calc_eval';

  @override
  String get description =>
      '幕后 calc 精确计算：求值四则、幂、模和有限函数，使用 BigInt 分数避免浮点误差。用于核对数值，不改变故事事实、叙事当前时间，也不能替代 finish_round。表达式长度、嵌套与结果位数有上限，超限返回 limit_exceeded，请改写更小的表达式。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {
        'type': 'object',
        'properties': {
          'expression': {'type': 'string', 'description': '表达式（四则、^/**、%、函数）'},
          'places': {
            'type': 'integer',
            'minimum': 0,
            'maximum': 1000,
            'default': 20,
            'description': '十进制展示位数',
          },
        },
        'required': ['expression'],
      };

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final raw = arguments['expression'];
    if (raw is! String || raw.trim().isEmpty) {
      return AgentToolResult.failure(
        title: '缺少表达式',
        output: 'expression 必须是非空字符串，请传入要计算的表达式。',
      );
    }
    final placesArg = parseIntegerArg(
      arguments,
      'places',
      min: 0,
      max: 1000,
      fallback: 20,
    );
    final places = placesArg.value;
    final placesError = placesArg.error;
    if (places == null || placesError != null) {
      return AgentToolResult.failure(
        title: 'places 参数无效',
        output: placesError ?? 'places 必须是 0 到 1000 的整数。',
      );
    }
    try {
      final result = _engine.evaluate(raw, places: places);
      _deps.draft.calledTools.add(name);
      // 成功回显做长度截断：大数值原文不整段灌入模型上下文。
      final exact = truncateForEcho(
        result.exactFraction,
        limit: CalcLimits.maxEchoLength,
      );
      final decimal = truncateForEcho(
        result.decimal,
        limit: CalcLimits.maxEchoLength,
      );
      return AgentToolResult.success(
        title: 'calc · 精确计算',
        output: '精确值：$exact\n十进制：$decimal\n已截断：${result.truncated ? '是' : '否'}',
        metadata: {
          'tool': name,
          'expression': raw,
          'exactFraction': exact,
          'decimal': decimal,
          'truncated': result.truncated,
        },
        outputSchema: kOutputSchema,
      );
    } on CalcEvalException catch (e) {
      return AgentToolResult.failure(
        title: 'calc · 计算失败',
        output: '计算失败（${e.code}）：${e.message} 请修正参数后重试。',
        metadata: {'tool': name, 'code': e.code},
      );
    }
  }
}

class CalcDateTool implements AgentTool {
  CalcDateTool(this._deps, {CalcDateEngine engine = const CalcDateEngine()})
      : _engine = engine;
  final AgentToolDeps _deps;
  final CalcDateEngine _engine;

  static const Map<String, String> kOutputSchema = {
    'tool': 'string',
    'operation': 'string',
    'result': 'string',
  };

  @override
  String get name => 'calc_date';

  @override
  String get description =>
      '幕后 calc 日期算术：严格解析显式 ISO 日期/Unix 时间戳，执行 1y2mo3d 加减或两日期间隔；add 与 to 可同给（先加时长再算到 to 的间隔）。支持 0001-01-01 至 9999-12-31 范围。无输入时钟，不支持 IANA/DST；结果只供参考，不能把它当作故事当前时间或外部事实。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {
        'type': 'object',
        'properties': {
          'date': {
            'type': 'string',
            'description': '显式 ISO 日期/日期时间或 Unix 秒/毫秒',
          },
          'add': {'type': 'string', 'description': '可选时长，如 1y2mo3d 或 -3d'},
          'to': {
            'type': 'string',
            'description':
                '可选目标日期；返回 elapsed + calendar 间隔，可与 add 组合（先加时长再算间隔）',
          },
        },
        'required': ['date'],
      };

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final date = arguments['date'];
    if (date is! String || date.trim().isEmpty) {
      return AgentToolResult.failure(
        title: '缺少日期',
        output: 'date 必须是显式 ISO 日期或 Unix 时间戳字符串，不能省略或使用 now。',
      );
    }
    final add = arguments['add'];
    final to = arguments['to'];
    if (add != null && add is! String || to != null && to is! String) {
      return AgentToolResult.failure(
        title: '日期参数类型无效',
        output: 'add 与 to 必须是字符串；请修正参数后重试。',
      );
    }
    try {
      final result = _engine.evaluate(
        date: date,
        add: add as String?,
        to: to as String?,
      );
      _deps.draft.calledTools.add(name);
      final resultText = result.data['result']?.toString() ??
          result.data['iso']?.toString() ??
          result.data['calendar']?.toString() ??
          result.data.toString();
      final showsInterval =
          result.operation == 'diff' || result.operation == 'add_diff';
      return AgentToolResult.success(
        title: 'calc · 日期${result.operation}',
        output:
            '基准：${date.trim()}\n结果：$resultText${showsInterval ? '\n间隔：${result.data['calendar']}' : ''}',
        metadata: {
          'tool': name,
          'operation': result.operation,
          'result': resultText,
          ...result.data,
        },
        outputSchema: {...kOutputSchema, 'result': 'string'},
      );
    } on CalcDateException catch (e) {
      return AgentToolResult.failure(
        title: 'calc · 日期失败',
        output: '日期计算失败（${e.code}）：${e.message} 请修正参数后重试。',
        metadata: {'tool': name, 'code': e.code},
      );
    }
  }
}
