/// 首次启动演示数据包模型与解析校验。
///
/// 格式契约见
///` §7。
/// 解析器同时是结构校验器：合法包全量通过，坏包抛
/// [DemoPackFormatException]（消息含 JSON 路径）。离线校验 CLI
/// （tool/demo/verify_pack.dart）与运行时加载器共用本实现。
library;

import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';

/// 数据包格式/结构错误
class DemoPackFormatException implements Exception {
  const DemoPackFormatException(this.message);

  final String message;

  @override
  String toString() => 'DemoPackFormatException: $message';
}

/// 资产缺失或与当前源码指纹不符（体验入口应隐藏，不进入半兼容回放）
class DemoPackUnavailableException implements Exception {
  const DemoPackUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'DemoPackUnavailableException: $message';
}

class DemoPackManifest {
  const DemoPackManifest({
    required this.formatVersion,
    required this.sceneId,
    required this.kind,
    required this.locale,
    required this.contentVersion,
    required this.templateId,
    required this.templateHash,
    required this.promptHash,
    required this.toolFingerprint,
    required this.embeddingDimensions,
    required this.embeddingModelLabel,
    this.replayProfile,
    this.sourceCommit,
    this.source,
    this.notes = const <String>[],
  });

  final int formatVersion;
  final String sceneId;

  /// sample（测试样本，UI 标注）/ official（真实采集审核包）
  final String kind;
  final String locale;
  final String contentVersion;
  final String templateId;
  final String templateHash;
  final String promptHash;
  final String toolFingerprint;
  final int embeddingDimensions;
  final String embeddingModelLabel;

  /// 回放能力画像（formatVersion=2 必需；v1 隐式默认为 conservativeRelay）
  final DemoReplayProfile? replayProfile;
  final String? sourceCommit;
  final Map<String, dynamic>? source;
  final List<String> notes;

  bool get isSample => kind == 'sample';
}

/// 流式回放步（一个 LLM 请求的完整事件序列）
class PackStreamStep {
  const PackStreamStep({
    required this.purpose,
    required this.turn,
    required this.events,
  });

  final String purpose;
  final int turn;

  /// 已过结构校验的原始事件 map（type 字段合法、字段类型正确、
  /// 工具调用 id 配对完整）
  final List<Map<String, dynamic>> events;
}

/// 非流式回放条目
class PackChatEntry {
  const PackChatEntry({
    required this.purpose,
    required this.turn,
    required this.response,
  });

  final String purpose;
  final int turn;

  /// 已过结构校验的响应 map
  final Map<String, dynamic> response;
}

class PackEmbedding {
  const PackEmbedding({
    required this.kind,
    required this.inputHash,
    required this.dimensions,
    required this.values,
    required this.inputPreview,
  });

  final String kind;
  final String inputHash;
  final int dimensions;
  final List<double> values;
  final String inputPreview;
}

class DemoPackExpectations {
  const DemoPackExpectations({
    required this.proseContains,
    required this.entityNames,
    required this.eventSummaryContains,
    required this.nextTurn,
    required this.messageRoles,
  });

  final List<String> proseContains;
  final List<String> entityNames;
  final List<String> eventSummaryContains;
  final int nextTurn;
  final List<String> messageRoles;
}

class DemoPack {
  const DemoPack({
    required this.manifest,
    required this.prompt,
    required this.streamSteps,
    required this.chatEntries,
    required this.embeddings,
    required this.expectations,
  });

  factory DemoPack.parse(Map<String, dynamic> json) {
    try {
      return parseValidatedMap(json);
    } on DemoPackFormatException {
      rethrow;
    } catch (e) {
      throw DemoPackFormatException('unexpected parse failure: $e');
    }
  }

  static const int currentFormatVersion = 2;
  static const Set<int> supportedFormatVersions = <int>{1, 2};
  static const Set<String> allowedKinds = <String>{'sample', 'official'};
  static const Set<String> allowedEmbeddingKinds = <String>{'query', 'passage'};

  final DemoPackManifest manifest;
  final String prompt;
  final List<PackStreamStep> streamSteps;
  final List<PackChatEntry> chatEntries;
  final List<PackEmbedding> embeddings;
  final DemoPackExpectations expectations;

  /// (kind, inputHash) → embedding 查找（小列表线性查找即可）
  PackEmbedding? embeddingFor(String kind, String inputHash) {
    for (final e in embeddings) {
      if (e.kind == kind && e.inputHash == inputHash) return e;
    }
    return null;
  }

  /// 某用途某回合的流式步数（回放诊断用）
  int streamStepCount(String purpose, int turn) =>
      streamSteps.where((s) => s.purpose == purpose && s.turn == turn).length;

  /// 某用途的非流式条目（按包内顺序）
  List<PackChatEntry> chatEntriesOf(String purpose) =>
      chatEntries.where((c) => c.purpose == purpose).toList();
}

/// 校验并构建包对象（[DemoPack.parse] 的实现体）
DemoPack parseValidatedMap(Map<String, dynamic> json) {
  final ctx = _Ctx();
  final manifestMap = ctx.map(json, 'manifest');
  final manifest = _parseManifest(ctx.at('manifest'), manifestMap);

  final prompt = ctx.string(json, 'prompt');
  if (prompt.trim().isEmpty) {
    throw const DemoPackFormatException('prompt: 不得为空');
  }

  final responsesMap = ctx.map(json, 'responses');
  final streamList = ctx.list(responsesMap, 'stream');
  final streamSteps = <PackStreamStep>[];
  for (var i = 0; i < streamList.length; i++) {
    streamSteps.add(
      _parseStreamStep(ctx.at('responses.stream[$i]'), streamList[i]),
    );
  }
  final chatList = ctx.list(responsesMap, 'chat');
  final chatEntries = <PackChatEntry>[];
  for (var i = 0; i < chatList.length; i++) {
    chatEntries.add(_parseChatEntry(ctx.at('responses.chat[$i]'), chatList[i]));
  }

  final embList = ctx.list(json, 'embeddings');
  final embeddings = <PackEmbedding>[];
  final embKeys = <String>{};
  for (var i = 0; i < embList.length; i++) {
    final e = _parseEmbedding(ctx.at('embeddings[$i]'), embList[i]);
    final key = '${e.kind}:${e.inputHash}';
    if (!embKeys.add(key)) {
      throw DemoPackFormatException(
        'embeddings[$i]: 重复 (kind,inputHash)=$key',
      );
    }
    if (e.dimensions != manifest.embeddingDimensions) {
      throw DemoPackFormatException(
        'embeddings[$i]: dimensions=${e.dimensions} 与 '
        'manifest.embeddingDimensions=${manifest.embeddingDimensions} 不符',
      );
    }
    embeddings.add(e);
  }

  final expMap = ctx.map(json, 'expectations');
  final expectations = DemoPackExpectations(
    proseContains: ctx.stringList(expMap, 'proseContains'),
    entityNames: ctx.stringList(expMap, 'entityNames'),
    eventSummaryContains: ctx.stringList(expMap, 'eventSummaryContains'),
    nextTurn: ctx.intOf(expMap, 'nextTurn'),
    messageRoles: ctx.stringList(expMap, 'messageRoles'),
  );
  if (expectations.nextTurn < 2) {
    throw const DemoPackFormatException('expectations.nextTurn: 必须 ≥2');
  }

  // 通道与画像一致性核验（契约 §22.5）
  final profile = manifest.replayProfile ?? DemoReplayProfile.conservativeRelay;
  final caps = profile.resolveCapabilities();
  final hasStreamAgentStep = streamSteps.any((s) => s.purpose == 'agent_step');
  final hasChatAgentStep = chatEntries.any((c) => c.purpose == 'agent_step');

  if (caps.streamingToolCallsReliable) {
    if (hasChatAgentStep) {
      throw DemoPackFormatException(
        '画像 "${profile.id}" 为流式工具通道 (streamingToolCallsReliable=true)， '
        '但包内包含非流式 agent_step (responses.chat)',
      );
    }
    if (manifest.kind == 'official' && !hasStreamAgentStep) {
      throw DemoPackFormatException(
        '官方包画像 "${profile.id}" 为流式工具通道，但 responses.stream 缺失 agent_step',
      );
    }
  } else {
    if (hasStreamAgentStep) {
      throw DemoPackFormatException(
        '画像 "${profile.id}" 为非流式工具通道 (streamingToolCallsReliable=false)， '
        '但包内包含流式 agent_step (responses.stream)',
      );
    }
    if (manifest.kind == 'official' && !hasChatAgentStep) {
      throw DemoPackFormatException(
        '官方包画像 "${profile.id}" 为非流式工具通道，但 responses.chat 缺失 agent_step',
      );
    }
  }

  _scanSecrets(json);

  return DemoPack(
    manifest: manifest,
    prompt: prompt,
    streamSteps: streamSteps,
    chatEntries: chatEntries,
    embeddings: embeddings,
    expectations: expectations,
  );
}

DemoPackManifest _parseManifest(_Ctx ctx, Map<String, dynamic> m) {
  final version = ctx.intOf(m, 'formatVersion');
  if (!DemoPack.supportedFormatVersions.contains(version)) {
    throw DemoPackFormatException(
      'manifest.formatVersion=$version 不受支持（当前支持 ${DemoPack.supportedFormatVersions}）',
    );
  }
  final sceneId = ctx.string(m, 'sceneId');
  if (sceneId != demoSceneId) {
    throw DemoPackFormatException('manifest.sceneId=$sceneId 与运行场景不符');
  }
  final kind = ctx.string(m, 'kind');
  if (!DemoPack.allowedKinds.contains(kind)) {
    throw DemoPackFormatException('manifest.kind=$kind 非法（sample/official）');
  }
  final locale = ctx.string(m, 'locale');
  if (locale.isEmpty || locale.contains('/')) {
    throw const DemoPackFormatException('manifest.locale 非法');
  }
  final dims = ctx.intOf(m, 'embeddingDimensions');
  if (dims <= 0) {
    throw const DemoPackFormatException('manifest.embeddingDimensions 必须 >0');
  }

  final DemoReplayProfile replayProfile;
  if (version == 1) {
    if (m['replayProfile'] != null) {
      final parsed = DemoReplayProfile.fromJson(
        ctx.map(m, 'replayProfile'),
      );
      if (parsed.id != DemoReplayProfile.conservativeRelayId) {
        throw const DemoPackFormatException(
          'formatVersion=1 数据包不允许声明非 conservativeRelay 画像',
        );
      }
      replayProfile = parsed;
    } else {
      replayProfile = DemoReplayProfile.conservativeRelay;
    }
  } else {
    if (m['replayProfile'] == null) {
      throw const DemoPackFormatException(
        'manifest.replayProfile 缺失 (formatVersion=2 必需)',
      );
    }
    replayProfile = DemoReplayProfile.fromJson(
      ctx.map(m, 'replayProfile'),
    );
  }
  // 校验画像白名单与指纹合法性
  replayProfile.resolveCapabilities();

  return DemoPackManifest(
    formatVersion: version,
    sceneId: sceneId,
    kind: kind,
    locale: locale,
    contentVersion: ctx.string(m, 'contentVersion'),
    templateId: ctx.string(m, 'templateId'),
    templateHash: ctx.string(m, 'templateHash'),
    promptHash: ctx.string(m, 'promptHash'),
    toolFingerprint: ctx.string(m, 'toolFingerprint'),
    embeddingDimensions: dims,
    embeddingModelLabel: ctx.string(m, 'embeddingModelLabel'),
    replayProfile: replayProfile,
    sourceCommit: m['sourceCommit'] as String?,
    source: m['source'] is Map<String, dynamic>
        ? m['source'] as Map<String, dynamic>
        : null,
    notes: m['notes'] is List
        ? [for (final n in m['notes']! as List) n.toString()]
        : const <String>[],
  );
}

const Set<String> _streamEventTypes = <String>{
  'text_delta',
  'thinking_delta',
  'tool_call_start',
  'tool_call_args',
  'tool_call_complete',
  'content_block_complete',
  'thinking_block_complete',
  'done',
  'error',
};

PackStreamStep _parseStreamStep(_Ctx ctx, Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw DemoPackFormatException('${ctx.path}: 必须为对象');
  }
  final purpose = ctx.string(raw, 'purpose');
  final turn = ctx.intOf(raw, 'turn');
  final eventsRaw = ctx.list(raw, 'events');
  if (eventsRaw.isEmpty) {
    throw DemoPackFormatException('${ctx.path}.events: 不得为空');
  }
  final events = <Map<String, dynamic>>[];
  final openToolCalls = <String>{};
  var terminated = false;
  for (var i = 0; i < eventsRaw.length; i++) {
    final eCtx = ctx.at('events[$i]');
    final e = eCtx.mapAny(eventsRaw[i]);
    final type = eCtx.string(e, 'type');
    if (terminated) {
      throw DemoPackFormatException('${eCtx.path}: 终止事件后不得再有事件');
    }
    if (!_streamEventTypes.contains(type)) {
      throw DemoPackFormatException('${eCtx.path}.type=$type 未知');
    }
    switch (type) {
      case 'text_delta':
      case 'thinking_delta':
        eCtx.string(e, 'content');
      case 'tool_call_start':
        final id = eCtx.string(e, 'toolCallId');
        eCtx.string(e, 'name');
        if (!openToolCalls.add(id)) {
          throw DemoPackFormatException(
            '${eCtx.path}: toolCallId=$id 重复 start',
          );
        }
      case 'tool_call_args':
        final id = eCtx.string(e, 'toolCallId');
        eCtx.string(e, 'argsDelta');
        if (!openToolCalls.contains(id)) {
          throw DemoPackFormatException('${eCtx.path}: toolCallId=$id 未 start');
        }
      case 'tool_call_complete':
        final id = eCtx.string(e, 'toolCallId');
        eCtx.string(e, 'name');
        if (e['arguments'] is! Map) {
          throw DemoPackFormatException('${eCtx.path}.arguments: 必须为对象');
        }
        if (!openToolCalls.remove(id)) {
          throw DemoPackFormatException('${eCtx.path}: toolCallId=$id 未 start');
        }
      case 'content_block_complete':
        if (e['block'] is! Map) {
          throw DemoPackFormatException('${eCtx.path}.block: 必须为对象');
        }
      case 'thinking_block_complete':
        eCtx
          ..string(e, 'thinking')
          ..string(e, 'signature');
      case 'done':
        if (e['usage'] != null && e['usage'] is! Map) {
          throw DemoPackFormatException('${eCtx.path}.usage: 必须为对象');
        }
        terminated = true;
      case 'error':
        eCtx.string(e, 'message');
        terminated = true;
    }
    events.add(e);
  }
  if (!terminated) {
    throw DemoPackFormatException('${ctx.path}.events: 缺少 done/error 终止事件');
  }
  if (openToolCalls.isNotEmpty) {
    throw DemoPackFormatException(
      '${ctx.path}.events: 工具调用未 complete: $openToolCalls',
    );
  }
  return PackStreamStep(purpose: purpose, turn: turn, events: events);
}

PackChatEntry _parseChatEntry(_Ctx ctx, Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw DemoPackFormatException('${ctx.path}: 必须为对象');
  }
  final purpose = ctx.string(raw, 'purpose');
  final turn = ctx.intOf(raw, 'turn');
  final resp = ctx.map(raw, 'response');
  final rCtx = ctx.at('response')..string(resp, 'content');
  if (resp['toolCalls'] != null) {
    if (resp['toolCalls'] is! List) {
      throw DemoPackFormatException('${rCtx.path}.toolCalls: 必须为数组');
    }
    for (final tc in resp['toolCalls']! as List) {
      if (tc is! Map ||
          tc['toolCallId'] is! String ||
          tc['name'] is! String ||
          tc['arguments'] is! Map) {
        throw DemoPackFormatException(
          '${rCtx.path}.toolCalls 条目字段不完整（toolCallId/name/arguments）',
        );
      }
    }
  }
  return PackChatEntry(purpose: purpose, turn: turn, response: resp);
}

PackEmbedding _parseEmbedding(_Ctx ctx, Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw DemoPackFormatException('${ctx.path}: 必须为对象');
  }
  final kind = ctx.string(raw, 'kind');
  if (!DemoPack.allowedEmbeddingKinds.contains(kind)) {
    throw DemoPackFormatException('${ctx.path}.kind=$kind 非法（query/passage）');
  }
  final hash = ctx.string(raw, 'inputHash');
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
    throw DemoPackFormatException('${ctx.path}.inputHash: 必须 64 位小写 hex');
  }
  final dims = ctx.intOf(raw, 'dimensions');
  final valuesRaw = ctx.list(raw, 'values');
  final values = <double>[];
  for (var i = 0; i < valuesRaw.length; i++) {
    final v = valuesRaw[i];
    if (v is! num) {
      throw DemoPackFormatException('${ctx.path}.values[$i]: 必须为数值');
    }
    values.add(v.toDouble());
  }
  if (values.length != dims) {
    throw DemoPackFormatException(
      '${ctx.path}: values.length=${values.length} 与 dimensions=$dims 不符',
    );
  }
  return PackEmbedding(
    kind: kind,
    inputHash: hash,
    dimensions: dims,
    values: values,
    inputPreview: ctx.string(raw, 'inputPreview'),
  );
}

/// 密钥样式扫描：整包键名与字符串值不得含凭据样式内容
void _scanSecrets(Map<String, dynamic> json) {
  final hits = <String>[];
  void walk(Object? v, String path) {
    if (v is Map) {
      v.forEach((k, value) {
        final ks = k.toString();
        if (RegExp(
          'api[-_]?key|authorization|bearer',
          caseSensitive: false,
        ).hasMatch(ks)) {
          hits.add('$path.$ks');
        }
        walk(value, '$path.$ks');
      });
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        walk(v[i], '$path[$i]');
      }
    } else if (v is String) {
      if (RegExp('sk-[A-Za-z0-9]{16,}').hasMatch(v) ||
          RegExp('Bearer [A-Za-z0-9._-]{16,}').hasMatch(v)) {
        hits.add(path);
      }
    }
  }

  walk(json, '');
  if (hits.isNotEmpty) {
    throw DemoPackFormatException('包内疑似凭据内容: ${hits.take(5).join(', ')}');
  }
}

/// 解析上下文：路径前缀 + 类型化取值（非法类型直接抛格式错误）
class _Ctx {
  String path = '';

  _Ctx at(String segment) {
    final c = _Ctx()..path = path.isEmpty ? segment : '$path.$segment';
    return c;
  }

  Map<String, dynamic> map(Map<String, dynamic> src, String key) {
    final v = src[key];
    if (v is! Map<String, dynamic>) {
      throw DemoPackFormatException('${_p(key)}: 必须为对象');
    }
    return v;
  }

  Map<String, dynamic> mapAny(Object? v) {
    if (v is! Map<String, dynamic>) {
      throw DemoPackFormatException('$path: 必须为对象');
    }
    return v;
  }

  List<dynamic> list(Map<String, dynamic> src, String key) {
    final v = src[key];
    if (v is! List) {
      throw DemoPackFormatException('${_p(key)}: 必须为数组');
    }
    return v;
  }

  String string(Map<String, dynamic> src, String key) {
    final v = src[key];
    if (v is! String) {
      throw DemoPackFormatException('${_p(key)}: 必须为字符串');
    }
    return v;
  }

  int intOf(Map<String, dynamic> src, String key) {
    final v = src[key];
    if (v is! int) {
      throw DemoPackFormatException('${_p(key)}: 必须为整数');
    }
    return v;
  }

  List<String> stringList(Map<String, dynamic> src, String key) {
    final v = src[key];
    if (v is! List || v.any((e) => e is! String)) {
      throw DemoPackFormatException('${_p(key)}: 必须为字符串数组');
    }
    return List<String>.from(v);
  }

  String _p(String key) => path.isEmpty ? key : '$path.$key';
}
