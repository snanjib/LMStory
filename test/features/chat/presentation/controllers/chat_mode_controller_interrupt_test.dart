import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/services/data_store_operation_guard.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';
import '../../../../test_helpers/stub_token_counter.dart';

/// 对话模式「停止/续写」数据链路集成测试
///
/// 覆盖：
/// 1. 停止生成后半截回复必须落库（此前仅内存态，任何刷新即丢，且
///    「继续生成」看不到半截内容导致整篇重复生成）
/// 2. 继续生成必须挂在锚点的当前活跃分支上（此前固定 branchIndex=0，
///    有分支时续写流中切换分支会被误判，DB 活跃分支被错换）
/// 3. 消息加载期有 isLoading 标志（防止首次打开闪现"发送第一条消息"空态）
void main() {
  late _RecordingChatRepository repo;
  late _ScriptedLlmService llmService;
  late StreamController<LlmStreamEvent> events;
  late DataStoreOperationGuard guard;

  setUp(() {
    repo = _RecordingChatRepository();
    llmService = _ScriptedLlmService();
    events = StreamController<LlmStreamEvent>();
    llmService.stream = events.stream;
    guard = DataStoreOperationGuard();
  });

  tearDown(() {
    // 不 await：无监听者的 controller close() 完成时机不确定，会挂起 teardown
    unawaited(events.close());
  });

  ChatModeController build({ChatSession? session}) {
    final tokenCounter = StubTokenCounter();
    final compaction = CompactionService(
      chatRepository: repo,
      tokenCounter: tokenCounter,
      settingsRepository: _FakeSettingsRepository(),
      presetRepository: _NoopPresetRepository(),
      streamer: CompactionStreamer(llmService: llmService),
      llmService: llmService,
    );
    return ChatModeController(
      chatRepository: repo,
      presetRepository: _NoopPresetRepository(),
      settingsRepository: _FakeSettingsRepository(),
      compactionService: compaction,
      llmService: llmService,
      logger: const Logger('test'),
      failureLogRepository: const StubFailureLogRepository(),
      tokenCounter: tokenCounter,
      session: session ?? _session(),
      operationGuard: guard,
      //  流式节流：本组用例以零延迟轮询断言 delta 即时可见，
      // 注入 Duration.zero 关闭 32ms 合帧（生产语义由
      // throttled_delta_buffer_test / stream_handler 专项用例覆盖）
      streamDeltaCoalesceInterval: Duration.zero,
    );
  }

  Future<void> until(bool Function() cond) async {
    for (var i = 0; i < 200 && !cond(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(cond(), isTrue, reason: '等待条件超时');
  }

  DataManagementService buildBackupService(_RecordingBackupRepository backup) =>
      DataManagementService(
        chatRepository: repo,
        presetRepository: _NoopPresetRepository(),
        settingsRepository: _FakeSettingsRepository(),
        backupRepository: backup,
        operationGuard: guard,
      );

  Future<void> expectOverwriteBusy(
    _RecordingBackupRepository backup,
    DataManagementService service,
  ) async {
    var snapshots = 0;
    await expectLater(
      service.importBackup(
        _backupJson,
        ImportMode.overwrite,
        preImportSnapshot: () async => snapshots++,
      ),
      throwsA(isA<BackupOverwriteBusyException>()),
    );
    expect(snapshots, 0);
    expect(backup.calls, isEmpty);
  }

  group('覆盖导入与普通对话', () {
    test('首次历史慢读期间只接收一次发送，读回后保留旧消息', () async {
      repo.messages = [
        ChatMessage(
          messageId: 'existing-message',
          sessionId: _session().sessionId,
          role: 'user',
          content: '已保存的消息',
          createdAt: DateTime(2026),
        ),
      ];
      final entered = Completer<void>();
      final finishRead = Completer<void>();
      repo.beforeFirstMessageRead = () async {
        entered.complete();
        await finishRead.future;
      };
      final controller = build();
      final send = controller.sendMessage('打开时发送的消息');
      try {
        await entered.future;
        expect(await controller.sendMessage('重复发送'), isFalse);
        expect(repo.addMessageCalls, isEmpty);
        final backup = _RecordingBackupRepository();
        await expectOverwriteBusy(backup, buildBackupService(backup));
      } finally {
        finishRead.complete();
      }
      expect(await send, isTrue);
      expect(repo.addMessageCalls.single.content, '打开时发送的消息');
      expect(controller.state.messages.map((message) => message.content), [
        '已保存的消息',
        '打开时发送的消息',
      ]);
      await controller.cancelSendingWithRollback();
    });

    test('覆盖快照等待期间发送不写入用户消息', () async {
      final controller = build();
      await until(() => !controller.state.isLoading);
      final backup = _RecordingBackupRepository();
      final snapshotStarted = Completer<void>();
      final finishSnapshot = Completer<void>();
      final restoreStarted = Completer<void>();
      final finishRestore = Completer<void>();
      backup
        ..hasExistingData = true
        ..beforeRestore = () async {
          restoreStarted.complete();
          await finishRestore.future;
        };
      final importing = buildBackupService(backup).importBackup(
        _backupJson,
        ImportMode.overwrite,
        preImportSnapshot: () async {
          snapshotStarted.complete();
          await finishSnapshot.future;
        },
      );
      await snapshotStarted.future;
      try {
        expect(await controller.sendMessage('准备发送的文本'), isFalse);
        finishSnapshot.complete();
        await restoreStarted.future;
        expect(await controller.sendMessage('准备发送的文本'), isFalse);
        expect(repo.addMessageCalls, isEmpty);
        expect(llmService.lastRequest, isNull);
      } finally {
        if (!finishSnapshot.isCompleted) finishSnapshot.complete();
        finishRestore.complete();
        await importing;
      }
      expect(backup.calls, ['delete', 'import']);
      expect(await controller.sendMessage('准备发送的文本'), isTrue);
      expect(repo.addMessageCalls.single.content, '准备发送的文本');
      await controller.cancelSendingWithRollback();
    });

    test('助手收稿等待写入时覆盖拒绝且未触发快照删除', () async {
      final controller = build();
      await until(() => !controller.state.isLoading);
      final writing = Completer<void>();
      final finishWrite = Completer<void>();
      repo.beforeAddAssistant = () async {
        writing.complete();
        await finishWrite.future;
      };
      expect(await controller.sendMessage('合成对话输入'), isTrue);
      final backup = _RecordingBackupRepository();
      final service = buildBackupService(backup);
      await expectOverwriteBusy(backup, service);
      events
        ..add(const LlmTextDelta('合成助手回复'))
        ..add(const LlmStreamDone());
      await writing.future;
      try {
        await expectOverwriteBusy(backup, service);
      } finally {
        finishWrite.complete();
        await until(() => !controller.state.isStreaming);
      }
      await controller.cancelSendingWithRollback();
      expect(
        repo.addMessageCalls.map((message) => (message.role, message.content)),
        [('user', '合成对话输入'), ('assistant', '合成助手回复')],
      );
      await service.importBackup(_backupJson, ImportMode.overwrite);
      expect(backup.calls, ['delete', 'import']);
    });

    test('发送准备中用户消息尚未写完时覆盖仍拒绝', () async {
      final writing = Completer<void>();
      final finishWrite = Completer<void>();
      repo.beforeAddUser = () async {
        writing.complete();
        await finishWrite.future;
      };
      final controller = build();
      await until(() => !controller.state.isLoading);
      final pendingSend = controller.sendMessage('正在写入用户消息');
      await writing.future;

      final backup = _RecordingBackupRepository();
      final service = buildBackupService(backup);
      try {
        expect(controller.state.isSending, isTrue);
        expect(llmService.lastRequest, isNull);
        await expectOverwriteBusy(backup, service);
      } finally {
        finishWrite.complete();
        expect(await pendingSend, isTrue);
        await controller.cancelSendingWithRollback();
      }
      expect(repo.addMessageCalls.single.content, '正在写入用户消息');
      await service.importBackup(_backupJson, ImportMode.overwrite);
      expect(backup.calls, ['delete', 'import']);
    });

    test('流错误自动重试期间覆盖无法进入，旧流结束不抢收新流', () async {
      final closingAttempt = Completer<void>();
      final finishClosing = Completer<void>();
      final firstEvents = StreamController<LlmStreamEvent>(
        onCancel: () async {
          closingAttempt.complete();
          await finishClosing.future;
        },
      );
      addTearDown(() => unawaited(firstEvents.close()));
      llmService.stream = firstEvents.stream;
      final controller = build();
      await until(() => !controller.state.isLoading);
      expect(await controller.sendMessage('自动重试的用户消息'), isTrue);
      final firstRequest = llmService.lastRequest;
      llmService.stream = events.stream;
      firstEvents
        ..add(const LlmStreamError('status 503', code: 'STREAM_ERROR'))
        ..add(const LlmStreamDone());
      await closingAttempt.future;

      final backup = _RecordingBackupRepository();
      final service = buildBackupService(backup);
      try {
        expect(llmService.lastRequest, same(firstRequest));
        await expectOverwriteBusy(backup, service);
      } finally {
        finishClosing.complete();
      }
      await until(() => !identical(llmService.lastRequest, firstRequest));
      await expectOverwriteBusy(backup, service);
      events
        ..add(const LlmTextDelta('重试后的回复'))
        ..add(const LlmStreamDone());
      await until(() => !controller.state.isStreaming);
      await controller.cancelSendingWithRollback();
      expect(
        repo.addMessageCalls.map((message) => message.content),
        ['自动重试的用户消息', '重试后的回复'],
      );
      await service.importBackup(_backupJson, ImportMode.overwrite);
      expect(backup.calls, ['delete', 'import']);
    });

    test('后台分支停止后仍等待半截回复写入原分支', () async {
      repo
        ..messages = [
          ChatMessage(
            messageId: 'u1',
            sessionId: 's1',
            role: 'user',
            content: '已有消息',
            createdAt: DateTime(2026),
          ),
        ]
        ..forkAnchors = const [
          ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 2),
        ];
      final controller = build();
      await until(() => controller.state.forkAnchors.isNotEmpty);
      expect(await controller.sendMessage('继续提问'), isTrue);
      final userMessage = repo.addMessageCalls.single;
      events.add(const LlmTextDelta('待写入的半截回复'));
      await until(() => controller.state.currentAssistantMessageId != null);
      await controller.switchFork('u1', ForkSwitchDirection.next);
      expect(controller.state.isGeneratingInBackground, isTrue);

      final saving = Completer<void>();
      final finishSaving = Completer<void>();
      repo.beforeAppendSnapshot = () async {
        saving.complete();
        await finishSaving.future;
      };
      final stopping = controller.cancelSendingWithRollback();
      await saving.future;
      final backup = _RecordingBackupRepository();
      final service = buildBackupService(backup);
      try {
        expect(controller.state.isStreaming, isFalse);
        await expectOverwriteBusy(backup, service);
        expect(await controller.sendMessage('收尾未结束的新输入'), isFalse);
      } finally {
        finishSaving.complete();
        await stopping;
      }
      expect(
        repo.snapshotAppendCalls,
        [(anchor: userMessage.messageId, branch: 0)],
      );
      expect(repo.savedSnapshotMessages.single.content, '待写入的半截回复');
      await service.importBackup(_backupJson, ImportMode.overwrite);
      expect(backup.calls, ['delete', 'import']);
    });

    test('正常收稿后仍等待会话标题实际写入', () async {
      final writingTitle = Completer<void>();
      final finishTitle = Completer<void>();
      final session = _session().copyWith(title: 'New Chat');
      repo
        ..storedSession = session
        ..beforeUpdateTitle = () async {
          writingTitle.complete();
          await finishTitle.future;
        };
      final controller = build(session: session);
      await until(() => !controller.state.isLoading);
      expect(await controller.sendMessage('合成标题场景'), isTrue);
      events
        ..add(const LlmTextDelta('合成回答'))
        ..add(const LlmStreamDone());
      await writingTitle.future;
      final backup = _RecordingBackupRepository();
      final service = buildBackupService(backup);
      try {
        await until(() => !controller.state.isStreaming);
        await expectOverwriteBusy(backup, service);
      } finally {
        finishTitle.complete();
        await until(() => controller.state.session.title == '合成标题');
      }
      await service.importBackup(_backupJson, ImportMode.overwrite);
      expect(backup.calls, ['delete', 'import']);
    });
  });

  test('3. 消息加载期 isLoading=true，加载完成置 false', () async {
    final controller = build();
    expect(controller.state.isLoading, isTrue, reason: '构造后立即读取应为加载中');
    await until(() => !controller.state.isLoading);
  });

  test('4. clearError 手动清除错误横幅状态（此前只能重进会话）', () async {
    final controller = build();
    await until(() => !controller.state.isLoading);

    // 模拟发送失败置位（copyWith sentinel 语义允许显式 null 清除）
    controller.state = controller.state.copyWith(error: '配置不完整');
    expect(controller.state.error, '配置不完整');

    controller.clearError();
    expect(controller.state.error, isNull);
  });

  test('1. 停止生成：已累积的部分回复落库（不再只存内存）', () async {
    final controller = build();
    await until(() => !controller.state.isLoading);

    unawaited(controller.sendMessage('写个故事'));
    // 首个 delta 之前 currentAssistantMessageId 尚不存在（由首个 delta 创建），
    // StreamController 会在订阅前缓冲事件
    events.add(const LlmTextDelta('从前有座山，'));
    await until(
      () => (controller.state.messages.lastOrNull?.content ?? '')
          .contains('从前有座山'),
    );

    controller.cancelSending();
    await until(() => !controller.state.isStreaming);
    // 微任务冲刷，确保 unawaited 的落库完成
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final partial = repo.addMessageCalls
        .where((m) => m.role == 'assistant' && (m.content ?? '').isNotEmpty)
        .toList();
    expect(partial, hasLength(1), reason: '停止后半截回复必须落库');
    expect(partial.single.content, contains('从前有座山'));
  });

  test('5. UI 停止路径：cancelSendingWithRollback 在无 Fork 回滚挂起时也落库', () async {
    final controller = build();
    await until(() => !controller.state.isLoading);

    unawaited(controller.sendMessage('写个故事'));
    events.add(const LlmTextDelta('半截内容'));
    await until(
      () => (controller.state.messages.lastOrNull?.content ?? '')
          .contains('半截内容'),
    );

    // 页面停止按钮的真实路径（chat_mode_page._handleCancel →
    // cancelSendingWithRollback）：正常发送中无 pendingForkRollback，
    // 半截回复必须落库——此前被无条件 persistPartial:false 抵消
    await controller.cancelSendingWithRollback();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final partial = repo.addMessageCalls
        .where((m) => m.role == 'assistant' && (m.content ?? '').isNotEmpty)
        .toList();
    expect(partial, hasLength(1), reason: 'UI 停止路径半截回复同样落库');
  });

  test('2. 继续生成：新气泡挂在锚点当前活跃分支（branchIndex=activeIndex）', () async {
    // 预置在构造前：u1 下两个分支，当前活跃分支 1（构造时 _loadMessages 读入）
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '开头',
          createdAt: DateTime(2026),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 1, branchCount: 2),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    events.add(const LlmTextDelta('续写内容'));
    await until(
      () => controller.state.messages
          .any((m) => m.role == 'assistant' && (m.content ?? '').isNotEmpty),
    );
    controller.cancelSending();
    await Future<void>.delayed(Duration.zero);

    final continuation = controller.state.messages
        .where((m) => m.role == 'assistant' && m.parentUserMsgId == 'u1')
        .lastOrNull;
    expect(continuation, isNotNull);
    expect(
      continuation!.branchIndex,
      1,
      reason: '续写气泡必须挂在锚点当前活跃分支，而不是固定 0',
    );
  });

  test('6. 后台分支模式停止：半截内容不再随缓冲清空蒸发', () async {
    // 预置：u1 锚点两分支，构造后从分支 0 发送
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '开头',
          createdAt: DateTime(2026),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 2),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.sendMessage('写个故事'));
    events.add(const LlmTextDelta('后台半截内容'));
    await until(
      () => controller.state.messages
          .any((m) => m.role == 'assistant' && (m.content ?? '').isNotEmpty),
    );

    // 流式中切看其他分支 → 进入后台模式（占位消息移入缓冲区）
    await controller.switchFork('u1', ForkSwitchDirection.next);
    await until(() => controller.state.currentAssistantMessageId == null);
    expect(controller.state.isStreaming, isTrue, reason: '后台模式下生成继续');

    // 用户点停止：此前 _persistPartialAssistantMessage 因 id==null 早退，
    // 半截内容随 state.reset() 直接蒸发；修复后必须落库
    controller.cancelSending();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final partial = repo.addMessageCalls
        .where((m) => m.role == 'assistant' && (m.content ?? '').isNotEmpty)
        .toList();
    expect(partial, hasLength(1), reason: '后台分支形态的半截回复必须落库（快照或回退均可）');
    expect(partial.single.content, contains('后台半截内容'));
  });

  test('. 后台分支模式 lifecycle：置位/切回恢复/完成收口均维护 isGeneratingInBackground', () async {
    // 预置：u1 已有半截回复 a1（续写形态——生成锚=u1，与  报告的
    // 「重生成中切看旧分支」同构；plain send 的锚是新用户消息，切回路径
    // 不经 _restoreBackgroundToState）
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '写个故事',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '从前有座山，',
          parentUserMsgId: 'u1',
          createdAt: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 2),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    events.add(const LlmTextDelta('续写半截'));
    await until(
      () => controller.state.messages.any(
        (m) => m.messageId != 'a1' && (m.content ?? '').isNotEmpty,
      ),
    );
    expect(
      controller.state.isGeneratingInBackground,
      isFalse,
      reason: '前台流式不置后台标志',
    );

    // 流式中切看其他分支 → 后台模式：标志置位（页面据此不渲染误导占位）
    await controller.switchFork('u1', ForkSwitchDirection.next);
    await until(() => controller.state.isGeneratingInBackground);
    expect(controller.state.currentAssistantMessageId, isNull);
    expect(controller.state.isStreaming, isTrue);

    // 切回生成分支 → 恢复前台形态，标志清除（流式继续）；假仓库
    // switchForkBranchWithSnapshot 同步 activeIndex=1，prev 算回 0
    await controller.switchFork('u1', ForkSwitchDirection.prev);
    await until(() => controller.state.currentAssistantMessageId != null);
    expect(
      controller.state.isGeneratingInBackground,
      isFalse,
      reason: '切回生成分支=恢复前台形态，输入区指示应消失',
    );
    expect(controller.state.isStreaming, isTrue);

    // 再切后台后流完成 → 收口必须清除标志（防陈旧 true 吞掉下一轮占位气泡）
    await controller.switchFork('u1', ForkSwitchDirection.next);
    await until(() => controller.state.isGeneratingInBackground);
    await events.close();
    await until(() => !controller.state.isStreaming);
    expect(
      controller.state.isGeneratingInBackground,
      isFalse,
      reason: '后台完成后标志随收口清除',
    );
  });

  test('7. B13 续写接写合并：上下文合并单条 + 完成后追加进被续写消息（单气泡+徽标）', () async {
    // 预置：u1 已有半截回复 a1（停止后已落库形态）
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '写个故事',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '从前有座山，',
          parentUserMsgId: 'u1',
          createdAt: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 1),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    events.add(const LlmTextDelta('山里有个庙。'));
    // 流式期间内容在占位气泡（合并发生在完成时）
    await until(
      () => controller.state.messages.any(
        (m) => m.messageId != 'a1' && (m.content ?? '').contains('庙'),
      ),
    );
    // 流结束（onDone → finish → 合并落库）
    await events.close();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // ① API 上下文：半截 assistant 条目被替换为单条 user（指令前缀+半截）
    final request = llmService.lastRequest;
    expect(request, isNotNull);
    final roles = request!.messages.map((m) => m['role']).toList();
    expect(roles, isNot(contains('assistant')), reason: '半截条目已被合并替换');
    final mergedEntry = request.messages.last;
    expect(mergedEntry['role'], 'user');
    expect(mergedEntry['content'] as String, contains('从前有座山，'));
    expect(mergedEntry['content'] as String, contains('从中断处继续写完'));

    // ② 落库：追加进 a1（单条 UPDATE），无新 assistant INSERT
    expect(repo.appendContinuationCalls, [
      (messageId: 'a1', continuation: '山里有个庙。', tokensUsed: null),
    ]);
    expect(
      repo.addMessageCalls.where((m) => m.role == 'assistant'),
      isEmpty,
      reason: '续写不再落独立气泡',
    );

    // ③ 内存态：单气泡，内容合并 + isContinued 徽标
    final assistants =
        controller.state.messages.where((m) => m.role == 'assistant').toList();
    expect(assistants, hasLength(1));
    expect(assistants.single.messageId, 'a1');
    expect(assistants.single.content, '从前有座山，山里有个庙。');
    expect(assistants.single.isContinued, isTrue);
  });

  test('8. B13 续写中途停止：半截续写段同样并入被续写消息（不落独立气泡）', () async {
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '写个故事',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '从前有座山，',
          parentUserMsgId: 'u1',
          createdAt: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 1),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    events.add(const LlmTextDelta('山里有个'));
    await until(
      () => controller.state.messages.any(
        (m) =>
            m.role == 'assistant' &&
            m.messageId != 'a1' &&
            (m.content ?? '').isNotEmpty,
      ),
    );
    controller.cancelSending();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      repo.appendContinuationCalls.single.messageId,
      'a1',
      reason: '停止时半截续写段并入被续写消息',
    );
    expect(
      repo.appendContinuationCalls.single.continuation,
      contains('山里有个'),
    );
    expect(
      repo.addMessageCalls.where((m) => m.role == 'assistant'),
      isEmpty,
      reason: '续写中途停止也不产生独立气泡',
    );
  });

  test('. 零 delta 空响应：isStreaming 收口回 false（前台形态不再卡死）', () async {
    final controller = build();
    await until(() => !controller.state.isLoading);

    unawaited(controller.sendMessage('你好'));
    await until(() => controller.state.isStreaming);
    // 模型只发 done / 流 onDone 无事件（空 completion 或内容审查拦截）
    await events.close();
    await until(() => !controller.state.isStreaming);
    expect(controller.state.currentAssistantMessageId, isNull);
    expect(controller.state.isThinking, isFalse);
  });

  test('. 后台零 delta 形态：空流完成同样收口', () async {
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '开头',
          createdAt: DateTime(2026),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 2),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.sendMessage('你好'));
    await until(() => controller.state.isStreaming);
    // 无任何 delta 时切看其他分支 → 后台模式（后台缓冲为空）
    await controller.switchFork('u1', ForkSwitchDirection.next);
    await events.close();
    await until(() => !controller.state.isStreaming);
    expect(controller.state.currentAssistantMessageId, isNull);
  });

  test('. 移动端 pause→resume 时序：recoverIfStuck 把前台半截回复落库', () async {
    final controller = build();
    await until(() => !controller.state.isLoading);

    unawaited(controller.sendMessage('写个故事'));
    events.add(const LlmTextDelta('移动端半截'));
    await until(
      () => (controller.state.messages.lastOrNull?.content ?? '')
          .contains('移动端半截'),
    );

    // 模拟移动端时序：paused 时取消令牌（事件循环冻结，CancelledException
    // 排队未投递），resumed 时 recoverIfStuck 先于 _handleStreamError 执行
    controller.onBackgroundInterrupt();
    final recovered = controller.recoverIfStuck();
    expect(recovered, isTrue);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.isStreaming, isFalse);
    expect(controller.state.currentAssistantMessageId, isNull);

    final partial = repo.addMessageCalls
        .where((m) => m.role == 'assistant' && (m.content ?? '').isNotEmpty)
        .toList();
    expect(partial, hasLength(1), reason: '恢复时前台半截必须落库（此前仅后台缓冲落库）');
    expect(partial.single.content, contains('移动端半截'));
  });

  test('. 续写在后台分支完成：接写合并进快照半截（不落独立气泡）', () async {
    // 预置：u1 已有半截回复 a1（停止后已落库形态），u1 有两个分支
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '写个故事',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '从前有座山，',
          parentUserMsgId: 'u1',
          createdAt: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 2),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    events.add(const LlmTextDelta('山里有个庙。'));
    await until(
      () => controller.state.messages.any(
        (m) => m.messageId != 'a1' && (m.content ?? '').contains('庙'),
      ),
    );
    // 续写流中切看其他分支 → 后台模式（半截 a1 随生成分支进快照）
    await controller.switchFork('u1', ForkSwitchDirection.next);
    await until(() => controller.state.currentAssistantMessageId == null);
    // 后台完成
    await events.close();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      repo.continuationSnapshotCalls,
      hasLength(1),
      reason: '后台完成走快照内接写合并',
    );
    final call = repo.continuationSnapshotCalls.single;
    expect(call.anchor, 'u1');
    expect(call.messageId, 'a1');
    expect(call.continuation, '山里有个庙。');
    expect(
      repo.addMessageCalls.where((m) => m.role == 'assistant'),
      isEmpty,
      reason: '后台续写不再落独立新消息（两气泡形态）',
    );
    expect(repo.snapshotAppendCalls, isEmpty, reason: '不走后台独立消息快照追加');
  });

  // 续写流中切看其他分支后**停止**——半截内容
  // 与前台停止同构走快照接写合并，不再落独立无徽标气泡。
  test('D6-7. 续写后台分支中停止：半截并进快照半截（与前台停止同构）', () async {
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '写个故事',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '从前有座山，',
          parentUserMsgId: 'u1',
          createdAt: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 2),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    events.add(const LlmTextDelta('山里有个庙。'));
    await until(
      () => controller.state.messages.any(
        (m) => m.messageId != 'a1' && (m.content ?? '').contains('庙'),
      ),
    );
    // 续写流中切看其他分支 → 后台模式
    await controller.switchFork('u1', ForkSwitchDirection.next);
    await until(() => controller.state.currentAssistantMessageId == null);
    // 用户点停止
    controller.cancelSending();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      repo.continuationSnapshotCalls,
      hasLength(1),
      reason: '后台停止同样走快照内接写合并（与前台停止/后台完成三态统一）',
    );
    final call = repo.continuationSnapshotCalls.single;
    expect(call.anchor, 'u1');
    expect(call.messageId, 'a1');
    expect(call.continuation, '山里有个庙。');
    expect(
      repo.addMessageCalls.where((m) => m.role == 'assistant'),
      isEmpty,
      reason: '不再落独立新消息（两气泡无徽标形态）',
    );
    expect(repo.snapshotAppendCalls, isEmpty);
  });

  test('. 续写只回思考内容：幽灵占位气泡被清理（不残留）', () async {
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '写个故事',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '从前有座山，',
          parentUserMsgId: 'u1',
          createdAt: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 1),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    // 模型只回思考、无正文
    events.add(const LlmThinkingDelta('只思考不说话'));
    await until(
      () => controller.state.messages.any(
        (m) => m.messageId != 'a1' && m.thinkingContent != null,
      ),
    );
    await events.close();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);

    final assistants =
        controller.state.messages.where((m) => m.role == 'assistant').toList();
    expect(assistants, hasLength(1), reason: '纯思考续写不留幽灵占位气泡');
    expect(assistants.single.messageId, 'a1');
    expect(repo.appendContinuationCalls, isEmpty);
    expect(
      repo.addMessageCalls.where((m) => m.role == 'assistant'),
      isEmpty,
      reason: '无正文的续写不落库',
    );
  });

  test('. 续写完成把 usage 写入被续写消息 tokensUsed（重载不回退）', () async {
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '写个故事',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: 's1',
          role: 'assistant',
          content: '从前有座山，',
          parentUserMsgId: 'u1',
          createdAt: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 1),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    events.add(const LlmTextDelta('山里有个庙。'));
    await until(
      () => controller.state.messages.any(
        (m) => m.messageId != 'a1' && (m.content ?? '').isNotEmpty,
      ),
    );
    events.add(const LlmStreamDone(usage: LlmUsage(totalTokens: 777)));
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);

    expect(
      repo.appendContinuationCalls.single.tokensUsed,
      777,
      reason: '续写 usage 随 appendContinuation 落库',
    );
    final target = controller.state.messages.firstWhere(
      (m) => m.messageId == 'a1',
    );
    expect(target.tokensUsed, 777, reason: '内存态同步（既有行为保持）');
  });

  test('9. B13 无半截回复时继续生成：回落旧形态（新气泡照常落库）', () async {
    repo
      ..messages = [
        ChatMessage(
          messageId: 'u1',
          sessionId: 's1',
          role: 'user',
          content: '开头',
          createdAt: DateTime(2026),
        ),
      ]
      ..forkAnchors = const [
        ForkAnchor(parentUserMsgId: 'u1', activeIndex: 0, branchCount: 1),
      ];
    final controller = build();
    await until(() => controller.state.forkAnchors.isNotEmpty);

    unawaited(controller.continueGenerating());
    events.add(const LlmTextDelta('正常回复'));
    await until(
      () => controller.state.messages.any(
        (m) => m.role == 'assistant' && (m.content ?? '').isNotEmpty,
      ),
    );
    await events.close();
    await until(() => !controller.state.isStreaming);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(repo.appendContinuationCalls, isEmpty, reason: '无半截不触发合并');
    expect(
      repo.addMessageCalls.where((m) => m.role == 'assistant'),
      isNotEmpty,
      reason: '回落旧的独立气泡形态',
    );
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
  ChatSession? storedSession;
  final List<ChatMessage> addMessageCalls = [];
  Future<void> Function()? beforeFirstMessageRead;
  Future<void> Function()? beforeAddAssistant;
  Future<void> Function()? beforeAddUser;
  Future<void> Function()? beforeAppendSnapshot;
  Future<void> Function()? beforeUpdateTitle;
  final List<({String anchor, int branch})> snapshotAppendCalls = [];
  final List<ChatMessage> savedSnapshotMessages = [];

  /// 续写合并落库记录（messageId, 追加段, tokensUsed）
  final List<({String messageId, String continuation, int? tokensUsed})>
      appendContinuationCalls = [];

  /// 后台续写接写合并（快照内）记录
  final List<
      ({
        String anchor,
        int branch,
        String messageId,
        String continuation,
        int? tokensUsed,
      })> continuationSnapshotCalls = [];

  @override
  Future<void> appendContinuation(
    String messageId,
    String continuation, {
    int? tokensUsed,
  }) async {
    appendContinuationCalls.add(
      (
        messageId: messageId,
        continuation: continuation,
        tokensUsed: tokensUsed
      ),
    );
    final index = messages.indexWhere((m) => m.messageId == messageId);
    if (index != -1) {
      messages[index] = messages[index].copyWith(
        content: (messages[index].content ?? '') + continuation,
        isContinued: true,
        tokensUsed: tokensUsed,
      );
    }
  }

  /// 默认返回 true（快照可定位），失配场景由 repo 级测试覆盖
  @override
  Future<bool> appendContinuationToBranchSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int branchIndex,
    required String messageId,
    required String continuation,
    int? tokensUsed,
  }) async {
    continuationSnapshotCalls.add(
      (
        anchor: anchorUserMsgId,
        branch: branchIndex,
        messageId: messageId,
        continuation: continuation,
        tokensUsed: tokensUsed,
      ),
    );
    return true;
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    final beforeRead = beforeFirstMessageRead;
    beforeFirstMessageRead = null;
    if (beforeRead == null) return messages;
    final snapshot = List<ChatMessage>.of(messages);
    await beforeRead();
    return snapshot;
  }

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    if (message.role == 'assistant') await beforeAddAssistant?.call();
    if (message.role == 'user') await beforeAddUser?.call();
    addMessageCalls.add(message);
    return message;
  }

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async =>
      forkAnchors;

  /// 记录调用并按配置返回。默认 false → 调用方回退 addMessage
  ///（模拟"生成锚点无分支行"的普通发送后台形态）。
  @override
  Future<bool> appendMessageToBranchSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int branchIndex,
    required ChatMessage message,
  }) async {
    snapshotAppendCalls.add((anchor: anchorUserMsgId, branch: branchIndex));
    if (beforeAppendSnapshot != null) {
      await beforeAppendSnapshot?.call();
      savedSnapshotMessages.add(message);
      return true;
    }
    return false;
  }

  /// 后台模式进入时的普通分支切换：返回另一分支的消息集。
  /// 同步更新锚 activeIndex（模拟 DB 活跃分支写入——真实
  /// getForkAnchors 读回该值，静态假值会让「切回生成分支」永远算不对）
  @override
  Future<List<ChatMessage>> switchForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int newActiveIndex,
    required List<ChatMessage> currentTailMessages,
  }) async {
    forkAnchors = [
      for (final a in forkAnchors)
        if (a.parentUserMsgId == anchorUserMsgId)
          a.copyWith(activeIndex: newActiveIndex)
        else
          a,
    ];
    return [
      ChatMessage(
        messageId: 'other-branch',
        sessionId: sessionId,
        role: 'assistant',
        content: '另一个分支的旧回复',
        parentUserMsgId: anchorUserMsgId,
        createdAt: DateTime(2026),
      ),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(String sessionId) =>
      Future.value(const []);

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  Future<ChatSession> getSession(String sessionId) async =>
      storedSession ?? (throw StateError('Session not initialized'));

  @override
  Future<void> updateSessionTitle(String sessionId, String title) async {
    await beforeUpdateTitle?.call();
    storedSession = storedSession?.copyWith(title: title);
  }

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  ///  测试 9：正常完成路径 _updateMessageCount 依赖（缺实现会
  /// noSuchMethod 抛错，isStreaming 卡 true）
  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {}

  @override
  Future<int> updateMessageError(String messageId, String? error) async =>
      // 真实实现返回受影响行数（消息未 INSERT 时 0），fake 同口径
      messages.any((m) => m.messageId == messageId) ? 1 : 0;

  @override
  Future<int> getMessageCount(String sessionId) async => messages.length;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

const _backupJson = '''
{
  "version": 2,
  "sessions": [
    {"session": {"session_id": "imported-chat", "title": "Imported", "mode": "chat"}}
  ]
}
''';

class _RecordingBackupRepository implements BackupRepository {
  final List<String> calls = [];
  bool hasExistingData = false;
  Future<void> Function()? beforeRestore;

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) => action();

  @override
  Future<BackupOverwriteState> readOverwriteState(
    Set<BackupDataDomain> domains,
  ) async =>
      (hasData: hasExistingData, fingerprint: '');

  @override
  Future<void> deleteAllSessionData() async => calls.add('delete');

  @override
  Future<int> importSessionData(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    calls.add('import');
    await beforeRestore?.call();
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 受控 LlmService：streamChat 返回 [stream]（测试用 StreamController 驱动）。
class _ScriptedLlmService implements LlmService {
  Stream<LlmStreamEvent>? stream;

  /// 捕获最近一次请求（断言续写合并后的 API 上下文）
  LlmRequest? lastRequest;

  @override
  Future<LlmResponse> chat(LlmRequest request) async =>
      const LlmResponse(content: '合成标题');

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    lastRequest = request;
    return stream!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 满足真实 ConfigurationResolver 所需的最小 SettingsRepository：
/// getResolvedConfig 返回全默认配置，getApiKey 返回测试 Key。
class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<AppConfig> getResolvedConfig() async =>
      const AppConfig(version: 'test', broadcastChat: BroadcastChatConfig());

  @override
  Future<String?> getApiKey(String presetId) async => 'test-key';

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

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
