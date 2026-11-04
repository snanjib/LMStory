import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/chat/presentation/pages/main_layout.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';

///  / main_layout 的"生成中"谓词与移动端压栈
/// 去重抽为可测顶层函数后的聚焦单测（main_layout 此前 0 测试基建，
/// 同构点 //→→ 已四次复发，用测试锁止血）。
void main() {
  ChatSession session(String id) => ChatSession(
        sessionId: id,
        title: '测试会话',
        mode: 'intermediate',
        createdAt: DateTime(2026, 9, 4),
        lastActiveAt: DateTime(2026, 9, 4),
        messageCount: 0,
      );

  group('isIntermediateGenerating（手动压缩计入生成中）', () {
    test('手动压缩中 phase 恒为 idle——仍应视为生成中', () {
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: session('s1'),
        isManualCompacting: true,
      );
      expect(
        isIntermediateGenerating(state),
        isTrue,
        reason: '压缩的 LLM 流式+落库窗口内呼吸点应亮、删除应被拦',
      );
    });

    test('idle 且非手动压缩——不视为生成中', () {
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: session('s1'),
      );
      expect(isIntermediateGenerating(state), isFalse);
    });

    test('failed——不视为生成中', () {
      final state = IntermediateChatState(
        phase: IntermediatePhase.failed,
        messages: const [],
        retryCounts: const {},
        session: session('s1'),
      );
      expect(isIntermediateGenerating(state), isFalse);
    });

    test('generating——视为生成中', () {
      final state = IntermediateChatState(
        phase: IntermediatePhase.generating,
        messages: const [],
        retryCounts: const {},
        session: session('s1'),
      );
      expect(isIntermediateGenerating(state), isTrue);
    });
  });

  group('isAdvancedGenerating（既有行为回归锁）', () {
    test('手动压缩中 phase 恒为 idle——仍应视为生成中', () {
      final state = AdvancedChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: session('a1'),
        isManualCompacting: true,
      );
      expect(isAdvancedGenerating(state), isTrue);
    });

    test('idle 且非手动压缩——不视为生成中', () {
      final state = AdvancedChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: session('a1'),
      );
      expect(isAdvancedGenerating(state), isFalse);
    });
  });

  group('isChatGenerating（B1 批1：对话模式生成中判定与 listen 守卫）', () {
    ChatModeState chatState({
      bool isSending = false,
      bool isStreaming = false,
      bool isCompressing = false,
    }) =>
        ChatModeState(
          session: session('c1'),
          isSending: isSending,
          isStreaming: isStreaming,
          isCompressing: isCompressing,
        );

    test('三忙态任一为真——生成中', () {
      expect(isChatGenerating(chatState(isSending: true)), isTrue);
      expect(isChatGenerating(chatState(isStreaming: true)), isTrue);
      expect(isChatGenerating(chatState(isCompressing: true)), isTrue);
    });

    test('全闲——不视为生成中', () {
      expect(isChatGenerating(chatState()), isFalse);
    });

    test('listen 守卫口径：流式 delta（busy 恒真）不应触发全壳重建', () {
      //  批1守卫 = isChatGenerating(prev) != isChatGenerating(next) 才
      // setState——delta 流式期间 prev/next 同为生成中，守卫为 false
      final before = chatState(isStreaming: true);
      final delta = chatState(isStreaming: true);
      expect(
        isChatGenerating(before) != isChatGenerating(delta),
        isFalse,
        reason: '32ms 合帧 delta 不再整壳 setState（此前每 delta 一次）',
      );
      // 生成结束（busy 翻转）必须重建——呼吸点要熄灭
      final done = chatState();
      expect(
        isChatGenerating(delta) != isChatGenerating(done),
        isTrue,
      );
    });
  });

  group('shouldPushMobileSession（同会话重复点选不压栈）', () {
    test('栈顶即同一会话——不再压栈', () {
      final a = session('A');
      expect(
        shouldPushMobileSession([null, a], a),
        isFalse,
        reason: '重复点选当前会话 no-op，否则返回键需按 N 次',
      );
    });

    test('栈顶为另一会话——压栈', () {
      expect(
        shouldPushMobileSession([null, session('A')], session('B')),
        isTrue,
      );
    });

    test('空栈——压栈', () {
      expect(shouldPushMobileSession(<ChatSession?>[], session('A')), isTrue);
    });

    test('连续两次点选同一会话——栈只增长一次', () {
      final stack = <ChatSession?>[null];
      final a = session('A');
      for (var i = 0; i < 2; i++) {
        if (shouldPushMobileSession(stack, a)) {
          stack.add(a);
        }
      }
      expect(stack, hasLength(2), reason: '[null, A] 而非 [null, A, A]');
    });
  });

  group('lruEvictCandidates（LRU 淘汰纯逻辑）', () {
    test('未超容——不淘汰', () {
      final lru = ['a', 'b', 'c'];
      expect(lruEvictCandidates(lru, 8, (_) => false), isEmpty);
    });

    test('恰等容量——不淘汰', () {
      final lru = List.generate(8, (i) => 's$i');
      expect(lruEvictCandidates(lru, 8, (_) => false), isEmpty);
    });

    test('超容——从最旧起淘到回到容量为止', () {
      // 尾部=最近访问，头部=最久未访问
      final lru = List.generate(10, (i) => 's$i');
      final victims = lruEvictCandidates(lru, 8, (_) => false);
      expect(victims, ['s0', 's1']);
    });

    test('豁免项跳过——淘次旧而非强制挤豁免', () {
      final lru = List.generate(10, (i) => 's$i');
      final victims = lruEvictCandidates(lru, 8, (s) => s == 's0');
      expect(victims, ['s1', 's2'], reason: '最旧的 s0 豁免（如仍在导航栈内），淘 s1/s2');
    });

    test('全豁免——不强制定淘（下次访问再试）', () {
      final lru = List.generate(12, (i) => 's$i');
      expect(lruEvictCandidates(lru, 8, (_) => true), isEmpty);
    });
  });
}
