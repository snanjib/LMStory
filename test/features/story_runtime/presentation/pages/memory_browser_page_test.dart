import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/story_runtime/presentation/pages/memory_browser_page.dart';

/// 归并模型解析回归测试
///
/// 口径：归并使用会话当前「生成」模型（与故事/导演主管线同源），
/// 不再走 summarizing→generating 回落链——旧链读会话物化时的
/// 「总结」快照，模型已下架/换配时归并会一直调死模型。
///
/// 按会话模式分流——导演会话走
/// resolveAdvancedGeneratingNamingConfig（advanced.generating*），
///故事会话走 resolveIntermediatePhaseNamingConfig（intermediate 链）。
void main() {
  ChatSession session({String mode = 'intermediate'}) => ChatSession(
        sessionId: 's1',
        title: '测试会话',
        mode: mode,
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 0,
      );

  test('解析会话 generating 阶段模型，且只解析一次（不走 summarizing 回落）', () async {
    final stub = _RecordingResolver((sess, phase) async {
      return const NamingConfig(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-test',
        modelId: 'glm-4.5-air',
      );
    });

    final config = await resolveSessionMergeNamingConfig(stub, session());

    expect(config, isNotNull);
    expect(config!.modelId, 'glm-4.5-air');
    // 恰好一次调用，phase=generating：恢复 summarizing 回落链会在这里暴露
    expect(stub.phaseCalls, ['generating']);
  });

  test('generating 未配置（null）时原样返回 null', () async {
    final stub = _RecordingResolver((sess, phase) async => null);

    final config = await resolveSessionMergeNamingConfig(stub, session());

    expect(config, isNull);
    expect(stub.phaseCalls, ['generating']);
  });

  test('导演会话（mode=advanced）走导演 GM 模型链，不读故事 phase 链', () async {
    final stub = _RecordingResolver(
      (sess, phase) async => null,
      advanced: (sess) async => const NamingConfig(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-adv',
        modelId: 'director-gm',
      ),
    );

    final config = await resolveSessionMergeNamingConfig(
      stub,
      session(mode: 'advanced'),
    );

    expect(config, isNotNull);
    expect(config!.modelId, 'director-gm');
    // 导演会话不得读故事模式模型链：错源会导致误报未配置或静默用错模型
    expect(stub.advancedCalls, hasLength(1));
    expect(stub.phaseCalls, isEmpty);
  });

  test('导演会话且导演模型未配置 → 原样返回 null（不回落故事链）', () async {
    final stub = _RecordingResolver(
      (sess, phase) async => const NamingConfig(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-test',
        modelId: 'story-model',
      ),
      advanced: (sess) async => null,
    );

    final config = await resolveSessionMergeNamingConfig(
      stub,
      session(mode: 'advanced'),
    );

    expect(config, isNull);
    expect(stub.advancedCalls, hasLength(1));
    expect(stub.phaseCalls, isEmpty);
  });

  test('故事会话（mode=intermediate）仍走故事 phase 链，不触导演链', () async {
    final stub = _RecordingResolver(
      (sess, phase) async => const NamingConfig(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-test',
        modelId: 'glm-4.5-air',
      ),
      advanced: (sess) async => throw StateError('不应触达导演链'),
    );

    final config = await resolveSessionMergeNamingConfig(stub, session());

    expect(config, isNotNull);
    expect(config!.modelId, 'glm-4.5-air');
    expect(stub.phaseCalls, ['generating']);
    expect(stub.advancedCalls, isEmpty);
  });
}

/// 记录 phase 调用序列的 [ConfigurationResolver] 桩（其余成员 noSuchMethod 兜底）
class _RecordingResolver implements ConfigurationResolver {
  _RecordingResolver(
    Future<NamingConfig?> Function(ChatSession, String) handler, {
    Future<NamingConfig?> Function(ChatSession)? advanced,
  })  : _handler = handler,
        _advancedHandler = advanced;

  final Future<NamingConfig?> Function(ChatSession, String phase) _handler;
  final Future<NamingConfig?> Function(ChatSession)? _advancedHandler;

  final List<String> phaseCalls = [];
  final List<int> advancedCalls = [];

  @override
  Future<NamingConfig?> resolveIntermediatePhaseNamingConfig(
    ChatSession session,
    String phase,
  ) {
    phaseCalls.add(phase);
    return _handler(session, phase);
  }

  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) {
    advancedCalls.add(1);
    return _advancedHandler!(session);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
