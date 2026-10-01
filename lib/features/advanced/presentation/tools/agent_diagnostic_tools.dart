import 'package:lmstory/core/agent/agent_tool.dart';

/// Agent Loop 诊断页演示工具集（：开发者自检用，非产品功能）
///
/// 目标是覆盖最小循环的全部形态：
/// - 只读工具调用（echo / get_current_time）
/// - 控制类终结工具（finish_demo → terminal）
/// 通过一套固定的自检提示词驱动，验证多步循环 / 流式增量 / 预算 / 取消。
class EchoTool implements AgentTool {
  const EchoTool();

  @override
  String get name => 'echo';

  @override
  String get description => '原样返回传入的 text 参数。用于连通性自检。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': '要回显的文本'},
      },
      'required': ['text'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final text = arguments['text']?.toString() ?? '';
    return AgentToolResult.success(
      title: 'echo: $text',
      output: text,
      metadata: {'length': text.length},
    );
  }
}

class CurrentTimeTool implements AgentTool {
  const CurrentTimeTool();

  @override
  String get name => 'get_current_time';

  @override
  String get description => '获取设备当前本地时间（ISO 8601 格式）。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final now = DateTime.now();
    return AgentToolResult.success(
      title: '当前时间',
      output: now.toIso8601String(),
    );
  }
}

class FinishDemoTool implements AgentTool {
  const FinishDemoTool();

  @override
  String get name => 'finish_demo';

  @override
  String get description => '完成自检并结束本轮工作。summarize 参数填写一句话总结。';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '一句话总结'},
      },
      'required': ['summary'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final summary = arguments['summary']?.toString() ?? '';
    return AgentToolResult.terminal(
      title: 'finish_demo',
      output: '本轮已结束： $summary',
    );
  }
}

///  诊断页默认提示词（驱动模型走完 3 个工具的最小循环）
const String kAgentDiagnosticPrompt = '你是 LMStory「导演模式」Agent Loop 的'
    ' 连通性自检助手。请严格按顺序完成以下操作：\n'
    '1. 调用 echo 工具，参数 text 设为「导演模式连通性正常」。\n'
    '2. 调用 get_current_time 工具获取当前时间。\n'
    '3. 调用 finish_demo 工具结束本轮，参数 summary 用一句话总结以上两步结果。\n'
    '除工具调用外不要输出多余内容。';
