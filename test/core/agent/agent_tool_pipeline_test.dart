import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/agent_tool_pipeline.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';

class _RecordingTool implements AgentTool {
  _RecordingTool(this.behavior);

  final Future<AgentToolResult> Function(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) behavior;

  Map<String, dynamic>? lastArgs;

  @override
  String get name => 'update_facts';

  @override
  String get description => 'test tool';

  @override
  AgentToolPermission get permission => AgentToolPermission.write;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    lastArgs = arguments;
    return behavior(invocation, arguments);
  }
}

Future<ToolPipelineOutcome> _run({
  required AgentTool tool,
  Map<String, dynamic> args = const {'value': 'x'},
  List<AgentPreExecuteHook>? preHooks,
  List<AgentToolGuard>? guards,
  AgentApprovalSeam? approvalSeam,
  List<AgentPostExecuteHook>? postHooks,
  bool approvalRequired = false,
}) {
  final pipeline = AgentToolPipeline(
    preExecuteHooks: preHooks,
    guards: guards,
    approvalSeam: approvalSeam ?? const UnattendedApprovalSeam(),
    postExecuteHooks: postHooks,
  );
  return pipeline.execute(
    tool: tool,
    callId: 'call_1',
    stepIndex: 0,
    sessionId: 'test',
    cancellation: AgentCancellationToken(),
    arguments: args,
    approvalRequired: approvalRequired,
  );
}

void main() {
  group('AgentToolPipeline', () {
    test('正常执行：工具体收到参数，结果透传', () async {
      final tool = _RecordingTool(
        (inv, args) async =>
            AgentToolResult.success(title: 'ok', output: 'written'),
      );

      final outcome = await _run(tool: tool);

      expect(outcome.wasDenied, isFalse);
      expect(outcome.result.output, 'written');
      expect(tool.lastArgs, {'value': 'x'});
    });

    test('pre-execute 拒绝：可操作失败信封，工具体不执行', () async {
      var executed = false;
      final tool = _RecordingTool((inv, args) async {
        executed = true;
        return AgentToolResult.success(title: 'ok', output: 'x');
      });

      final outcome = await _run(
        tool: tool,
        preHooks: [
          (request) async => const AgentPreExecuteDeny('频率限制：3 轮内修改次数已达上限'),
        ],
      );

      expect(outcome.wasDenied, isTrue);
      expect(executed, isFalse);
      expect(outcome.result.output, contains('频率限制'));
      expect(outcome.result.output, contains('不要原样重试'));
    });

    test('pre-execute 改写参数：工具体看到改写后的快照', () async {
      final tool = _RecordingTool(
        (inv, args) async => AgentToolResult.success(title: 'ok', output: 'ok'),
      );

      await _run(
        tool: tool,
        preHooks: [
          (request) async => const AgentPreExecuteAllow(
                rewrittenArgs: {'value': 'rewritten'},
              ),
        ],
      );

      expect(tool.lastArgs, {'value': 'rewritten'});
    });

    test('单调 guard：deny 后 pre-execute 的 allow 无法翻案', () async {
      // 顺序：pre-execute 先放行，guard 再拒绝
      var executed = false;
      final tool = _RecordingTool((inv, args) async {
        executed = true;
        return AgentToolResult.success(title: 'ok', output: 'x');
      });

      final outcome = await _run(
        tool: tool,
        preHooks: [
          (request) async => const AgentPreExecuteAllow(),
        ],
        guards: [
          (request) => null,
          (request) => '只读保护：该实体来自世界书，禁止修改',
        ],
      );

      expect(outcome.wasDenied, isTrue);
      expect(executed, isFalse);
      expect(outcome.result.output, contains('世界书'));
    });

    test('审批 fail-closed：无 answerer → unavailable → 拒绝且文案可区分', () async {
      var executed = false;
      final tool = _RecordingTool((inv, args) async {
        executed = true;
        return AgentToolResult.success(title: 'ok', output: 'x');
      });

      final outcome = await _run(
        tool: tool,
        approvalRequired: true,
        approvalSeam: const UnattendedApprovalSeam(),
      );

      expect(outcome.wasDenied, isTrue);
      expect(executed, isFalse);
      expect(outcome.result.output, contains('审批不可用'));
    });

    test('审批 fail-closed：seam 抛异常 → 视同 unavailable', () async {
      final tool = _RecordingTool(
        (inv, args) async => AgentToolResult.success(title: 'ok', output: 'x'),
      );

      final outcome = await _run(
        tool: tool,
        approvalRequired: true,
        approvalSeam: _ThrowingSeam(),
      );

      expect(outcome.wasDenied, isTrue);
      expect(outcome.result.output, contains('审批通道异常'));
    });

    test('用户明确拒绝：拒绝原因带用户反馈', () async {
      final tool = _RecordingTool(
        (inv, args) async => AgentToolResult.success(title: 'ok', output: 'x'),
      );

      final outcome = await _run(
        tool: tool,
        approvalRequired: true,
        approvalSeam: const _StaticSeam(AgentApprovalDenied('换个措辞再写')),
      );

      expect(outcome.wasDenied, isTrue);
      expect(outcome.result.output, contains('用户拒绝：换个措辞再写'));
    });

    test('审批通过：正常执行', () async {
      final tool = _RecordingTool(
        (inv, args) async => AgentToolResult.success(title: 'ok', output: 'ok'),
      );

      final outcome = await _run(
        tool: tool,
        approvalRequired: true,
        approvalSeam: const _StaticSeam(AgentApprovalGranted()),
      );

      expect(outcome.wasDenied, isFalse);
      expect(outcome.result.output, 'ok');
    });

    test('批准批注（P1）：成功回执尾部追加信封，无批注零变化', () async {
      final tool = _RecordingTool(
        (inv, args) async => AgentToolResult.success(title: 'ok', output: '已暂存 2 处变更'),
      );

      // 有批注：尾部信封 + metadata 标记
      final noted = await _run(
        tool: tool,
        approvalRequired: true,
        approvalSeam: const _StaticSeam(
          AgentApprovalGranted(feedback: '把表演和真性格区分开'),
        ),
      );
      expect(noted.wasDenied, isFalse);
      expect(noted.result.output, startsWith('已暂存 2 处变更'));
      expect(
        noted.result.output,
        contains('\n——\n导演批注（随本次批准下发）：把表演和真性格区分开'),
      );
      expect(noted.result.metadata?['approvalFeedback'], isTrue);

      // 无批注：与旧行为完全一致（P1「不填什么都不追加」）
      final plain = await _run(
        tool: tool,
        approvalRequired: true,
        approvalSeam: const _StaticSeam(AgentApprovalGranted()),
      );
      expect(plain.result.output, '已暂存 2 处变更');
      expect(plain.result.metadata?['approvalFeedback'], isNull);

      // 空白批注 = 无批注
      final blank = await _run(
        tool: tool,
        approvalRequired: true,
        approvalSeam: const _StaticSeam(AgentApprovalGranted(feedback: '   ')),
      );
      expect(blank.result.output, '已暂存 2 处变更');
    });

    test('批准批注：工具失败信封不追加（失败已有行动指引）', () async {
      final tool = _RecordingTool(
        (inv, args) async =>
            AgentToolResult.failure(title: '失败', output: '实体不存在'),
      );

      final outcome = await _run(
        tool: tool,
        approvalRequired: true,
        approvalSeam: const _StaticSeam(
          AgentApprovalGranted(feedback: '下次注意'),
        ),
      );

      expect(outcome.result.isError, isTrue);
      expect(outcome.result.output, isNot(contains('导演批注')));
    });

    test('工具体抛异常：捕获为可操作失败信封，不中断', () async {
      final tool = _RecordingTool((inv, args) async {
        throw StateError('db locked');
      });

      final outcome = await _run(tool: tool);

      expect(outcome.result.isError, isTrue);
      expect(outcome.result.output, contains('db locked'));
      expect(outcome.result.output, contains('请检查参数'));
    });

    test('工具体抛取消异常：向上传播（轮中断语义）', () async {
      final token = AgentCancellationToken();
      final tool = _RecordingTool((inv, args) async {
        throw const AgentCancelledException('用户取消');
      });

      final pipeline = AgentToolPipeline();
      await expectLater(
        pipeline.execute(
          tool: tool,
          callId: 'c',
          stepIndex: 0,
          sessionId: 's',
          cancellation: token,
          arguments: const {},
        ),
        throwsA(isA<AgentCancelledException>()),
      );
    });

    test('B12 致命工具异常：EmbeddingCallFailedException 不包信封，原样上抛', () async {
      final tool = _RecordingTool((inv, args) async {
        throw const EmbeddingCallFailedException('embedding 端点 503');
      });

      await expectLater(
        _run(tool: tool),
        throwsA(isA<EmbeddingCallFailedException>()),
        reason: '包装成失败信封会让模型静默换路，E104 链路不可达',
      );
    });

    test('post-execute 替换结果', () async {
      final tool = _RecordingTool(
        (inv, args) async =>
            AgentToolResult.success(title: 'ok', output: '原始输出'),
      );

      final outcome = await _run(
        tool: tool,
        postHooks: [
          (request, result) async => AgentPostExecuteReplace(
                AgentToolResult.success(title: '脱敏', output: '替换输出'),
              ),
        ],
      );

      expect(outcome.result.output, '替换输出');
    });

    test('参数深拷贝：pre-execute 改写不影响原始调用参数', () async {
      final original = <String, dynamic>{'value': 'original'};
      final tool = _RecordingTool(
        (inv, args) async => AgentToolResult.success(title: 'ok', output: 'ok'),
      );

      await _run(
        tool: tool,
        args: original,
        preHooks: [
          (request) async {
            // 钩子内篡改入参（不应泄漏到原始 map）
            request.arguments['value'] = 'hacked';
            return AgentPreExecuteAllow(rewrittenArgs: request.arguments);
          },
        ],
      );

      expect(original['value'], 'original');
      expect(tool.lastArgs!['value'], 'hacked');
    });
  });

  group('输出预算', () {
    AgentTool namedTool(
      String name,
      AgentToolPermission permission,
      String output, {
      bool terminal = false,
    }) {
      return _NamedTool(
        name: name,
        permission: permission,
        result: terminal
            ? AgentToolResult.terminal(title: 'done', output: output)
            : AgentToolResult.success(title: 'ok', output: output),
      );
    }

    test('超长输出截断：head/tail 完整、标记与自指引存在、metadata 记原长', () async {
      final longOutput = 'A' * 8000 + 'B' * 8000 + 'C' * 8000; // 24000 字符
      final outcome = await _run(
        tool: namedTool('read_story', AgentToolPermission.readOnly, longOutput),
      );

      final output = outcome.result.output;
      expect(output, contains('【输出超长已截断：已省略约 6000 字符'));
      expect(output, contains('search_story'));
      expect(output, contains('read_story'));
      // head（预算 60% = 12000 字符）与 tail（30% = 6000 字符）保序保留
      expect(output.startsWith('A' * 8000 + 'B' * 4000), isTrue);
      expect(output.endsWith('C' * 6000), isTrue);
      // 原长进 metadata（不进模型上下文）
      expect(outcome.result.metadata?['outputTruncated'], isTrue);
      expect(outcome.result.metadata?['originalOutputLength'], 24000);
    });

    test('短输出逐字节不变（无截断痕迹）', () async {
      const short = '短短的输出';
      final outcome = await _run(
        tool: namedTool('query_facts', AgentToolPermission.readOnly, short),
      );
      expect(outcome.result.output, short);
      expect(
        outcome.result.metadata?.containsKey('outputTruncated'),
        isNot(isTrue),
      );
    });

    test('豁免：ask_user 与 finish_round 回执不截断', () async {
      final long = 'x' * 25000;
      final ask = await _run(
        tool: namedTool('ask_user', AgentToolPermission.control, long),
      );
      expect(ask.result.output, hasLength(25000));

      final finish = await _run(
        tool: namedTool(
          'finish_round',
          AgentToolPermission.control,
          long,
          terminal: true,
        ),
      );
      expect(finish.result.output, hasLength(25000));
      expect(finish.result.terminal, isTrue);
    });

    test('spawn（control 档）不豁免——子代理交付物是主要预算对象', () async {
      final long = 'x' * 25000;
      final outcome = await _run(
        tool: namedTool('spawn', AgentToolPermission.control, long),
      );
      expect(outcome.result.output, contains('已省略约'));
    });

    test('toolOutputLimit = null 关闭截断（显式禁用）', () async {
      final long = 'x' * 25000;
      final pipeline = AgentToolPipeline(toolOutputLimit: null);
      final outcome = await pipeline.execute(
        tool: namedTool('read_story', AgentToolPermission.readOnly, long),
        callId: 'c',
        stepIndex: 0,
        sessionId: 's',
        cancellation: AgentCancellationToken(),
        arguments: const {},
      );
      expect(outcome.result.output, hasLength(25000));
    });
  });

  group('输出 schema 校验（B7-3 最小版）', () {
    AgentTool schemaTool(
      Map<String, String>? schema,
      Map<String, dynamic>? metadata,
    ) {
      return _NamedTool(
        name: 'search_story',
        permission: AgentToolPermission.readOnly,
        result: AgentToolResult.success(
          title: 'ok',
          output: '正常输出',
          metadata: metadata,
          outputSchema: schema,
        ),
      );
    }

    test('违规（缺键）：灰度档警告信封附尾、原输出保留、不标 error', () async {
      final outcome = await _run(
        tool: schemaTool(
          {'query': 'string', 'hitCount': 'int'},
          {'query': '古碑'}, // 缺 hitCount
        ),
      );

      expect(outcome.result.isError, isFalse, reason: '先警告不拦截（灰度档）');
      expect(outcome.result.output, contains('正常输出'), reason: '原输出保留');
      expect(outcome.result.output, contains('INVALID_TOOL_OUTPUT 警告'));
      expect(outcome.result.output, contains('hitCount'));
      expect(outcome.result.output, contains('期望 schema'));
      expect(outcome.result.output, contains('{query: string, hitCount: int}'));
      expect(outcome.result.metadata?['invalidToolOutput'], isNotNull);
    });

    test('违规（类型不符）：int 键收到 string → 警告含期望与实际类型', () async {
      final outcome = await _run(
        tool: schemaTool(
          {'hitCount': 'int'},
          {'hitCount': '七条'},
        ),
      );

      expect(outcome.result.output, contains('期望 int'));
      expect(outcome.result.output, contains('String'));
    });

    test('合规：声明键齐备且类型正确 → 无警告痕迹', () async {
      final outcome = await _run(
        tool: schemaTool(
          {'query': 'string', 'hitCount': 'int'},
          {'query': '古碑', 'hitCount': 3},
        ),
      );

      expect(outcome.result.output, '正常输出');
      expect(
        outcome.result.metadata?.containsKey('invalidToolOutput'),
        isNot(isTrue),
      );
    });

    test('豁免面：失败信封与未声明 schema 的结果不校验', () async {
      final failure = await _run(
        tool: _NamedTool(
          name: 'search_story',
          permission: AgentToolPermission.readOnly,
          result: AgentToolResult.failure(
            title: '失败',
            output: '失败输出',
          ),
        ),
      );
      expect(failure.result.output, '失败输出');

      final noSchema = await _run(
        tool: schemaTool(null, null),
      );
      expect(noSchema.result.output, '正常输出');
    });

    test('审查收官 R4-P2-3：terminal 回执只警告不拦截（副作用已发生不可回滚）', () async {
      final pipeline = AgentToolPipeline(enforceOutputSchema: true);
      final outcome = await pipeline.execute(
        tool: _NamedTool(
          name: 'finish_round',
          permission: AgentToolPermission.control,
          result: AgentToolResult.terminal(
            title: '本轮完成',
            output: '已提交',
            outputSchema: {'committed': 'boolean'},
          ),
        ),
        callId: 'c',
        stepIndex: 0,
        sessionId: 's',
        cancellation: AgentCancellationToken(),
        arguments: const {},
      );

      expect(outcome.result.terminal, isTrue, reason: '终局标记不得因 schema 拦截丢失');
      expect(outcome.result.isError, isFalse);
      expect(outcome.result.output, '已提交');
    });

    test('拦截档（enforceOutputSchema=true）：违规替换为 INVALID_TOOL_OUTPUT 失败信封',
        () async {
      final pipeline = AgentToolPipeline(enforceOutputSchema: true);
      final outcome = await pipeline.execute(
        tool: schemaTool({'hitCount': 'int'}, null),
        callId: 'c',
        stepIndex: 0,
        sessionId: 's',
        cancellation: AgentCancellationToken(),
        arguments: const {},
      );

      expect(outcome.result.isError, isTrue);
      expect(outcome.result.title, 'INVALID_TOOL_OUTPUT');
      expect(outcome.result.output, contains('期望 schema'));
      expect(outcome.result.output, contains('不要原样重试'));
      expect(outcome.wasDenied, isFalse, reason: '工具已执行，非前置拒绝');
    });
  });

  group('单工具超时', () {
    test('挂起的非 control 工具 → 超时信封（轮次继续，非中断）', () async {
      final pipeline = AgentToolPipeline(
        executionTimeout: const Duration(milliseconds: 50),
      );

      final outcome = await pipeline.execute(
        tool: _HangingTool(
          name: 'search_story',
          permission: AgentToolPermission.readOnly,
        ),
        callId: 'c',
        stepIndex: 0,
        sessionId: 's',
        cancellation: AgentCancellationToken(),
        arguments: const {},
      );

      expect(outcome.wasDenied, isFalse);
      expect(outcome.result.isError, isTrue);
      expect(outcome.result.title, '工具执行超时');
      expect(outcome.result.output, contains('执行超时（1 秒）'));
      // 措辞与"放弃等待并继续"语义一致 + 可行动指引
      expect(outcome.result.output, contains('已放弃等待'));
      expect(outcome.result.output, contains('缩小查询范围'));
    });

    test('control 档豁免：ask_user 慢归慢但不受管线超时切断', () async {
      final pipeline = AgentToolPipeline(
        executionTimeout: const Duration(milliseconds: 50),
      );

      final outcome = await pipeline.execute(
        tool: _SlowControlTool(
          name: 'ask_user',
          delay: const Duration(milliseconds: 150),
        ),
        callId: 'c',
        stepIndex: 0,
        sessionId: 's',
        cancellation: AgentCancellationToken(),
        arguments: const {},
      );

      expect(outcome.result.isError, isFalse);
      expect(outcome.result.output, '导演答：慢慢来');
    });

    test('executionTimeout = null 关闭超时（显式禁用）', () async {
      final pipeline = AgentToolPipeline(executionTimeout: null);
      final outcome = await pipeline.execute(
        tool: _SlowControlTool(
          name: 'search_story',
          delay: const Duration(milliseconds: 120),
          permission: AgentToolPermission.readOnly,
        ),
        callId: 'c',
        stepIndex: 0,
        sessionId: 's',
        cancellation: AgentCancellationToken(),
        arguments: const {},
      );
      expect(outcome.result.isError, isFalse);
    });
  });
}

class _NamedTool implements AgentTool {
  _NamedTool({
    required this.name,
    required this.permission,
    required this.result,
  });
  @override
  final String name;

  @override
  String get description => 'test tool';

  @override
  final AgentToolPermission permission;

  final AgentToolResult result;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async =>
      result;
}

/// 永不完成的工具体（模拟内嵌网络调用挂死； 超时路径）
class _HangingTool implements AgentTool {
  _HangingTool({required this.name, required this.permission});

  @override
  final String name;

  @override
  String get description => 'hanging tool';

  @override
  final AgentToolPermission permission;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) =>
      Completer<AgentToolResult>().future;
}

/// 延迟后返回结果的工具（control 档豁免验证）
class _SlowControlTool implements AgentTool {
  _SlowControlTool({
    required this.name,
    required this.delay,
    this.permission = AgentToolPermission.control,
  });

  @override
  final String name;

  final Duration delay;

  @override
  final AgentToolPermission permission;

  @override
  String get description => 'slow tool';

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    await Future<void>.delayed(delay);
    return AgentToolResult.success(
      title: 'ok',
      output: name == 'ask_user' ? '导演答：慢慢来' : 'ok',
    );
  }
}

class _StaticSeam implements AgentApprovalSeam {
  const _StaticSeam(this.verdict);

  final AgentApprovalVerdict verdict;

  @override
  Future<AgentApprovalVerdict> requestApproval(
    ToolExecutionRequest request,
  ) async {
    return verdict;
  }
}

class _ThrowingSeam implements AgentApprovalSeam {
  @override
  Future<AgentApprovalVerdict> requestApproval(
    ToolExecutionRequest request,
  ) async {
    throw StateError('UI 不可用');
  }
}
