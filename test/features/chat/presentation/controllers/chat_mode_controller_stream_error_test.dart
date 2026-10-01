import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// 对话模式流错误可见性回归测试（2026-09-08 用户报告：Gemini 3.8 生成
/// 消息静默消失、不显示报错，仅网络连不通可见错误）。
///
/// 覆盖两条错误链路：
/// 1. 首个 delta 前流错误（HTTP 400/401/429 等在 SSE 建立前失败）——
///    必须创建带 error 的助手消息卡（可见反馈），而不是静默清 busy 态；
/// 2. 部分 delta 后流错误（流中途 4xx/5xx/截断）——半截内容保留且
///    消息携带 error 字段。
void main() {
  late _RecordingChatRepository repo;
  late _FakeSettingsRepository settingsRepo;
  late _ScriptedLlmService llmService;
  late StreamController<LlmStreamEvent> events;

  setUp(() {
    repo = _RecordingChatRepository();
    settingsRepo = _FakeSettingsRepository();
    llmService = _ScriptedLlmService();
    events = StreamController<LlmStreamEvent>();
    llmService.stream = events.stream;
  });

  tearDown(() {
    unawaited(events.close());
  });

  ChatModeController build() {
    final compaction = CompactionService(
      chatRepository: repo,
      tokenCounter: TokenCounter(),
      settingsRepository: settingsRepo,
      presetRepository: _NoopPresetRepository(),
      streamer: CompactionStreamer(llmService: llmService),
      llmService: llmService,
    );
    return ChatModeController(
      chatRepository: repo,
      presetRepository: _NoopPresetRepository(),
      settingsRepository: settingsRepo,
      compactionService: compaction,
      llmService: llmService,
      logger: const Logger('test'),
      failureLogRepository: const StubFailureLogRepository(),
      session: _session(),
      streamDeltaCoalesceInterval: Duration.zero,
    );
  }

  Future<void> until(bool Function() cond) async {
    for (var i = 0; i < 200 && !cond(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(cond(), isTrue, reason: '等待条件超时');
  }

  test('A. 首 delta 前流错误（Gemini 400 INVALID_ARGUMENT 形态）→ 落库带 error 的助手消息卡',
      () async {
    final controller = build();
    await until(() => !controller.state.isLoading);

    unawaited(controller.sendMessage('你好'));
    await until(() => controller.state.isStreaming);
    // Gemini streamGenerateContent 对非法 generationConfig 直接 HTTP 400，
    // 解析层映射为 LlmStreamError（code 4xx 语义）且无任何 delta。
    events.add(
      const LlmStreamError(
        'SSE request failed with status 400: Invalid value at thinking_level "off"',
        code: 'CONFIG',
      ),
    );
    await events.close();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 内存态：必须存在带 error 的助手消息（用户可见的失败反馈）
    final errorMessages = controller.state.messages
        .where((m) => m.role == 'assistant' && m.error != null)
        .toList();
    expect(errorMessages, hasLength(1), reason: '首个 delta 前的失败必须有可见错误卡');
    // 落库：错误卡必须持久化（重进会话仍可见）
    expect(
      repo.addMessageCalls
          .where((m) => m.role == 'assistant' && m.error != null),
      hasLength(1),
      reason: '错误卡必须入库，不能只存内存',
    );
  });

  test('B. 部分 delta 后流错误 → 半截内容保留 + error 字段可见', () async {
    final controller = build();
    await until(() => !controller.state.isLoading);

    unawaited(controller.sendMessage('写个故事'));
    events.add(const LlmTextDelta('深夜的便利店，'));
    await until(
      () =>
          (controller.state.messages.lastOrNull?.content ?? '').contains('便利店'),
    );
    events.add(
      const LlmStreamError(
        'Gemini stream interrupted: connection closed',
        code: 'SERVER',
      ),
    );
    await events.close();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final assistant = controller.state.messages
        .where((m) => m.role == 'assistant' && (m.content ?? '').isNotEmpty)
        .lastOrNull;
    expect(assistant, isNotNull, reason: '半截内容不能随错误消失');
    expect(assistant!.error, isNotNull, reason: '错误必须标注在消息上（可见）');
  });

  // ── ：流终点统一清态 helper ─────────
  //
  // _finalizeStream 收口七个开口（三早退/catch 落库/LlmStreamError/
  // _handleStreamError 两分支），逐路径断言同一清态集：
  // busy 清零（按钮恢复）、isThinking 清零（CH10-N2/ 回归锚）、
  // 后台生成标志清零、当前助手锚点清零。
  group('P7-4（D2）：流终点统一清态', () {
    ChatModeController buildWith({String? apiKey, StateError? throwOnStream}) {
      settingsRepo.apiKey = apiKey ?? 'test-key';
      llmService.throwOnStream = throwOnStream;
      return build();
    }

    void expectFinalized(ChatModeController c, String path) {
      expect(c.state.isStreaming, isFalse, reason: '$path：busy 清零（按钮恢复）');
      expect(
        c.state.isThinking,
        isFalse,
        reason: '$path：isThinking 清零（CH10-N2/SM10-N3 回归锚）',
      );
      expect(
        c.state.isGeneratingInBackground,
        isFalse,
        reason: '$path：后台生成标志清零',
      );
      expect(c.state.currentAssistantMessageId, isNull, reason: '$path：助手锚点清零');
      expect(
        c.state.generatingAnchorUserMsgId,
        isNull,
        reason: '$path：生成锚点清零',
      );
    }

    test('1. 正常完成（LlmStreamDone）→ 全部清零', () async {
      final controller = buildWith();
      await until(() => !controller.state.isLoading);

      unawaited(controller.sendMessage('你好'));
      await until(() => controller.state.isStreaming);
      events.add(const LlmThinkingDelta('思考片段'));
      await until(() => controller.state.isThinking);
      events
        ..add(const LlmTextDelta('正文'))
        ..add(const LlmStreamDone());
      await events.close();
      await until(() => !controller.state.isStreaming);
      await Future<void>.delayed(Duration.zero);

      expectFinalized(controller, '正常完成');
    });

    test('2. 早退（无 API Key）→ 错误卡落库+全部清零', () async {
      final controller = buildWith(apiKey: '');
      await until(() => !controller.state.isLoading);

      await controller.sendMessage('你好');

      expectFinalized(controller, '早退');
      expect(
        controller.state.messages.where((m) => m.error != null),
        isNotEmpty,
        reason: '早退必须有可见错误卡',
      );
    });

    test('3. 订阅建立异常（catch 落库）→ 全部清零', () async {
      final controller = buildWith(throwOnStream: StateError('boom'));
      await until(() => !controller.state.isLoading);

      await controller.sendMessage('你好');

      expectFinalized(controller, 'catch 落库');
      expect(
        controller.state.messages.where((m) => m.error != null),
        isNotEmpty,
        reason: '异常必须有可见错误卡',
      );
    });

    test('4. LlmStreamError（思考期）→ 全部清零', () async {
      final controller = buildWith();
      await until(() => !controller.state.isLoading);

      unawaited(controller.sendMessage('你好'));
      await until(() => controller.state.isStreaming);
      events.add(const LlmThinkingDelta('思考被打断'));
      await until(() => controller.state.isThinking);
      events.add(
        const LlmStreamError('stream error mid-thinking', code: 'SERVER'),
      );
      await events.close();
      await until(() => !controller.state.isStreaming);
      await Future<void>.delayed(Duration.zero);

      expectFinalized(controller, 'LlmStreamError');
    });

    test('5. 取消（CancelledException 分支）→ 全部清零+error 清空', () async {
      final controller = buildWith();
      await until(() => !controller.state.isLoading);

      unawaited(controller.sendMessage('你好'));
      await until(() => controller.state.isStreaming);
      events.add(const LlmThinkingDelta('思考中取消'));
      await until(() => controller.state.isThinking);
      events.addError(const CancelledException('测试取消'));
      await events.close();
      await until(() => !controller.state.isStreaming);
      await Future<void>.delayed(Duration.zero);

      expectFinalized(controller, '取消');
      expect(controller.state.error, isNull, reason: '取消路径显式清空 error');
    });

    test('6. 流错误 else 分支（普通异常）→ 全部清零', () async {
      final controller = buildWith();
      await until(() => !controller.state.isLoading);

      unawaited(controller.sendMessage('你好'));
      await until(() => controller.state.isStreaming);
      events.add(const LlmThinkingDelta('思考后出错'));
      await until(() => controller.state.isThinking);
      events.addError(StateError('connection reset'));
      await events.close();
      await until(() => !controller.state.isStreaming);
      await Future<void>.delayed(Duration.zero);

      expectFinalized(controller, 'else 分支');
    });
  });
}

ChatSession _session() => ChatSession(
      sessionId: 's1',
      title: '测试',
      mode: 'simple',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
      presetId: 'p1',
      modelId: 'm1',
    );

class _RecordingChatRepository implements ChatRepository {
  List<ChatMessage> messages = [];
  List<ForkAnchor> forkAnchors = [];
  final List<ChatMessage> addMessageCalls = [];

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => messages;

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async =>
      forkAnchors;

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(String sessionId) =>
      Future.value(const []);

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    addMessageCalls.add(message);
    return message;
  }

  @override
  Future<int> updateMessageError(String messageId, String? error) async =>
      messages.any((m) => m.messageId == messageId) ? 1 : 0;

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {}

  @override
  Future<int> getMessageCount(String sessionId) async => messages.length;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _ScriptedLlmService implements LlmService {
  Stream<LlmStreamEvent>? stream;

  ///  测试：throwOnStream 非空时 streamChat 同步抛出
  /// （覆盖 _sendToApi catch 落库分支）。
  StateError? throwOnStream;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    if (throwOnStream != null) throw throwOnStream!;
    return stream!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _FakeSettingsRepository implements SettingsRepository {
  ///  测试：早退场景注入空 Key
  String? apiKey = 'test-key';

  @override
  Future<AppConfig> getResolvedConfig() async =>
      const AppConfig(version: 'test', broadcastChat: BroadcastChatConfig());

  @override
  Future<String?> getApiKey(String presetId) async => apiKey;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _NoopPresetRepository implements ApiPresetRepository {
  @override
  Future<ApiPreset> getPreset(String presetId) async => ApiPreset(
        presetId: presetId,
        name: 'Test Provider',
        baseUrl: 'https://api.test.com/v1',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  ///  早退测试：空 Key 回退链会遍历其他 preset——返回空列表
  /// 让 (null, presetId) 干净返回，走 _sendToApi 早退路径。
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
