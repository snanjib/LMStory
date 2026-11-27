import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_step_surface_source.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_event_source.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/advanced/domain/services/surface_representations.dart';

/// 表面完整性违例（完整性守卫触发，fail-closed 停轮）。
///
/// 配对非法/重复 callId/双表示不一致——重发必被协议拒绝或产生孤儿
/// 调用/结果。守卫先落 surface/guard 留痕事件再抛本异常（不静默修复：
/// 不猜配对、不生成 UUID 修 id、不丢一边表示保另一边）。
class AgentSurfaceIntegrityException implements Exception {
  const AgentSurfaceIntegrityException(this.detail);

  final String detail;

  @override
  String toString() => 'AgentSurfaceIntegrityException: $detail';
}

/// [AgentStepSurfaceSource] 的导演实现：每步出站消息的账本投影源。
///
/// 职责（幂等）：flush durable 缓冲 → 读账本 → 纪元窗投影（滤 frozen）
/// → 跨脑清思考/签名表示 → 前置冻结前缀 → 完整性守卫 →
/// 确定性摘要。出站消息唯一来自本投影（关闭态不构造本源，走既有
/// preStep 路径）。
class DirectorStepSurfaceSource implements AgentStepSurfaceSource {
  DirectorStepSurfaceSource({
    required DurableAgentEventSink durableSink,
    required AgentEventLogStore repository,
    required this.sessionId,
    this.currentSource,
    this.thinkingReplayAllowed = true,
  })  : _durableSink = durableSink,
        _repository = repository;

  final DurableAgentEventSink _durableSink;
  final AgentEventLogStore _repository;
  final String sessionId;

  /// 当前请求的来源三元组（跨脑判定基准；null = 当前来源未知，全部
  /// 按跨脑清表示——保守侧）
  final AgentEventSourceMeta? currentSource;

  /// 当前轮思考回传判定（anthropic 走 CompatOptions；其余=effort 未禁用）
  final bool thinkingReplayAllowed;

  /// 上一次出站面（逐请求分叉度量的比对基准；null=本轮首步）
  List<AgentMessage>? _lastOutbound;
  int _projectCount = 0;

  @override
  Future<AgentStepSurface> project() async {
    // 进模型的必已入日志：投影前先落账全部缓冲事件（幂等——缓冲空时
    // no-op，与 request 钩子的 flush 互不重复落账）。
    await _durableSink.flush();
    final events = await _repository.readEvents(sessionId);
    final frozen = DirectorSurfaceV2.latestFrozenPrefixOf(events);
    final window = DirectorSurfaceV2.epochWindowEvents(events);
    final safeWindow = stripUnreplayableRepresentations(
      events: window,
      currentSource: currentSource,
      thinkingReplayAllowed: thinkingReplayAllowed,
    );
    final projection = deriveAgentSurface(safeWindow);
    final messages = DirectorSurfaceV2.assemble(
      epochWindowMessages: projection.messages,
      frozenPrefix: frozen,
    );

    // 完整性守卫：违例先留痕再 fail-closed（轮停，不静默修复）。
    final violation = validateSurfaceIntegrity(messages);
    if (violation != null) {
      await _durableSink.appendNow(
        AgentDurableEvent(
          type: AgentEventTypes.surfaceGuard,
          data: {'kind': 'surface-integrity', 'detail': violation},
        ),
      );
      throw AgentSurfaceIntegrityException(violation);
    }

    // 逐请求分叉度量（log-only）：前缀分叉位置+断点策略摘要
    final digest = _digestOf(messages);
    final stepIndex = _projectCount++;
    final previous = _lastOutbound;
    _lastOutbound = messages;
    var divergedAtIndex = -1;
    var prefixChars = 0;
    if (previous != null) {
      final prevCount = previous.length;
      final common = prevCount < messages.length ? prevCount : messages.length;
      for (var i = 0; i < common; i++) {
        if (_messageFingerprint(previous[i]) !=
            _messageFingerprint(messages[i])) {
          divergedAtIndex = i;
          break;
        }
        prefixChars += messages[i].content?.length ?? 0;
      }
      if (divergedAtIndex < 0 && prevCount != messages.length) {
        divergedAtIndex = common;
      }
    }
    await _durableSink.appendNow(
      AgentDurableEvent(
        type: AgentEventTypes.requestMetric,
        data: {
          'stepIndex': stepIndex,
          // 首步/全新面无前缀可比（-1）；断点策略=frozen 前缀头断点
          'divergedAtIndex': previous == null ? null : divergedAtIndex,
          'prefixChars': prefixChars,
          'prevMessageCount': previous?.length,
          'newMessageCount': messages.length,
          'frozenPrefixChars': frozen?.length ?? 0,
          'digest': digest,
        },
      ),
    );

    return AgentStepSurface(
      messages: List.unmodifiable(messages),
      contentGeneration: projection.contentGeneration,
      digest: digest,
    );
  }

  /// 消息指纹（分叉比较口径）：role+实际可回传表示序列化——思考块等
  /// 不可回传表示不参与（清表示后投影本就不含）
  static String _messageFingerprint(AgentMessage m) {
    return jsonEncode({
      'role': m.role,
      'toolCallId': m.toolCallId,
      'content': m.content,
      'toolCalls': m.toolCalls
          ?.map((c) => {'id': c.id, 'name': c.name, 'arguments': c.arguments})
          .toList(),
    });
  }

  /// 投影确定性摘要（MD5 over 表面序列化；同账本同摘要，跨进程稳定）
  static String _digestOf(List<AgentMessage> messages) {
    final payload = jsonEncode([
      for (final m in messages) agentMessageToSurfaceData(m),
    ]);
    return crypto.md5.convert(utf8.encode(payload)).toString();
  }
}
