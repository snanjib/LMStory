import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_event_source.dart';

/// 表面表示层的跨脑清理与完整性守卫。
///
/// 跨脑清理：assistant 事件携带来源三元组（协议/模型/端点指纹）；投影时
/// 「来源未知或与当前请求不同源」→ 清除思考/签名表示（两种表示同步：
/// thinkingBlocks、contentBlocks 内思考块、toolCalls 的
/// thoughtSignature、reasoningContent）——跨厂商重发历史思考/签名有协议
/// 风险，同源且当前轮思考开启才回传。
///
/// 完整性守卫：投影后校验配对合法性/重复 callId/双表示一致性——违例不是数据
/// 损坏即协议非法（重发必被拒），fail-closed 停轮并留痕，不静默修复
/// （不猜配对、不生成 UUID 修 id、不丢一边表示保另一边）。

/// 清理不可回传表示后的窗口事件（纯函数：不改入参，返回新事件列表）。
///
/// [currentSource] 当前请求的三元组；[thinkingReplayAllowed] 当前轮
/// 思考回传判定（anthropic 走 CompatOptions，其余= effort 未禁用）。
/// 非 assistant 事件原样保留；keepThinking 判定按事件自身 source。
List<AgentDurableEvent> stripUnreplayableRepresentations({
  required List<AgentDurableEvent> events,
  required AgentEventSourceMeta? currentSource,
  required bool thinkingReplayAllowed,
}) {
  if (currentSource == null) {
    // 当前来源未知（异常装配）：全部按跨脑处理（保守清表示，不清正文）
    return [
      for (final event in events)
        if (event.type == AgentEventTypes.assistantMessage)
          _strippedAssistant(event)
        else
          event,
    ];
  }
  return [
    for (final event in events)
      if (event.type == AgentEventTypes.assistantMessage &&
          !_sameSource(event.data, currentSource, thinkingReplayAllowed))
        _strippedAssistant(event)
      else
        event,
  ];
}

bool _sameSource(
  Map<String, dynamic> data,
  AgentEventSourceMeta currentSource,
  bool thinkingReplayAllowed,
) {
  if (!thinkingReplayAllowed) return false;
  final meta = AgentEventSourceMeta.fromData(data);
  return meta != null &&
      meta.matches(
        otherProtocol: currentSource.protocol,
        otherModelId: currentSource.modelId,
        otherEndpointFingerprint: currentSource.endpointFingerprint,
      );
}

AgentDurableEvent _strippedAssistant(AgentDurableEvent event) {
  final data = Map<String, dynamic>.of(event.data)
    ..remove('reasoningContent')
    ..remove('thinkingBlocks');
  final toolCalls = data['toolCalls'];
  if (toolCalls is List) {
    data['toolCalls'] = [
      for (final tc in toolCases(toolCalls))
        {
          for (final entry in tc.entries)
            if (entry.key != 'thoughtSignature') entry.key: entry.value,
        },
    ];
  }
  final blocks = data['contentBlocks'];
  if (blocks is List) {
    data['contentBlocks'] = [
      for (final b in blocks)
        if (b is Map<String, dynamic> &&
            b['type'] != 'thinking' &&
            b['type'] != 'redacted_thinking')
          b,
    ];
    if ((data['contentBlocks'] as List).isEmpty) {
      data.remove('contentBlocks');
    }
  }
  return AgentDurableEvent(
    seq: event.seq,
    type: event.type,
    time: event.time,
    data: data,
    surfaceOp: event.surfaceOp,
    replaceStart: event.replaceStart,
    replaceEnd: event.replaceEnd,
    sourceEventSeqs: event.sourceEventSeqs,
  );
}

/// toolCalls 载荷的 Map 视图（容错：非 Map 元素丢弃——守卫另行兜底）
Iterable<Map<String, dynamic>> toolCases(List<dynamic> raw) => [
      for (final tc in raw)
        if (tc is Map<String, dynamic>) tc,
    ];

/// 投影完整性校验：返回违例描述（null = 通过）。
///
/// 检查项（dsh serialize 悬空即拒 + 旧实验完整性守卫移植）：
/// - 空/重复 callId（同表面内 assistant 声明的调用 id 不得重复、不得为空）
/// - 孤儿 tool 结果（结果的 callId 无先前 assistant 调用声明）
/// - 悬空 tool 调用（assistant 声明的调用无后续结果——轮内表面恒闭合；
///   取消/崩溃轮由占位结果与恢复器闭合，出现即漂移）
/// - 双表示不一致（平行 toolCalls 与 contentBlocks 的 tool_use 数量/
///   id/参数不齐——最终 wire 会出现孤儿调用或结果）
String? validateSurfaceIntegrity(List<AgentMessage> messages) {
  final declaredCallIds = <String>{};
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message.role == 'assistant') {
      final calls = message.toolCalls ?? const <AgentToolCall>[];
      final blockToolUses = [
        for (final b in message.contentBlocks ?? const <LlmContentBlock>[])
          if (b is LlmToolUseContentBlock) b,
      ];
      // 双表示一致性
      if (calls.isNotEmpty && blockToolUses.isNotEmpty) {
        if (calls.length != blockToolUses.length) {
          return 'representation-mismatch at $i: toolCalls='
              '${calls.length} vs blocks=${blockToolUses.length}';
        }
        for (var j = 0; j < calls.length; j++) {
          if (calls[j].id != blockToolUses[j].toolCallId ||
              calls[j].name != blockToolUses[j].name) {
            return 'representation-mismatch at $i: call j=$j '
                '(${calls[j].id}/${calls[j].name}) vs block '
                '(${blockToolUses[j].toolCallId}/${blockToolUses[j].name})';
          }
        }
      }
      for (final call in calls) {
        if (call.id.isEmpty) {
          return 'empty-call-id at $i (${call.name})';
        }
        if (!declaredCallIds.add(call.id)) {
          return 'duplicate-call-id at $i (${call.id})';
        }
      }
    } else if (message.role == 'tool') {
      final callId = message.toolCallId ?? '';
      if (callId.isEmpty || !declaredCallIds.contains(callId)) {
        return 'orphan-tool-result at $i ($callId)';
      }
    }
  }
  // 悬空调用：遍历结束后仍未被结果应答的声明（结果到达即从待答集移除）
  final pending = <String>{};
  for (final message in messages) {
    if (message.role == 'assistant') {
      for (final call in message.toolCalls ?? const <AgentToolCall>[]) {
        pending.add(call.id);
      }
    } else if (message.role == 'tool') {
      pending.remove(message.toolCallId ?? '');
    }
  }
  if (pending.isNotEmpty) {
    return 'dangling-tool-call (${pending.join(',')})';
  }
  return null;
}
