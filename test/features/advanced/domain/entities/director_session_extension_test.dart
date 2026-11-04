import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/director_session_extension.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';

/// maxSteps 三口径统一单测。
///
/// 会话列 NULL = 跟随全局当前值（经参数注入）；0 = 无上限；
/// 设置面板回显与 runner 预算读数（AgentBudget.maxSteps）共用本 getter。
ChatSession _session({int? maxSteps}) => ChatSession(
      sessionId: 's1',
      title: '测试',
      mode: 'advanced',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
      maxSteps: maxSteps,
    );

void main() {
  group('DirectorSessionX.effectiveMaxSteps（G-36）', () {
    test('会话列 NULL → 回退全局当前值（12），不再硬编码 8', () {
      expect(_session().effectiveMaxSteps(12), 12);
    });

    test('会话列 NULL 且全局也为默认 8 → 8（口径一致）', () {
      expect(_session().effectiveMaxSteps(8), 8);
    });

    test('会话列已设置（3）→ 会话值优先，全局值不参与', () {
      expect(_session(maxSteps: 3).effectiveMaxSteps(12), 3);
    });

    test('会话列 0（无上限）→ 原样透传（AgentBudget 0=不限制）', () {
      expect(_session(maxSteps: 0).effectiveMaxSteps(12), 0);
    });
  });
}
