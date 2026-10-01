import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/diagnostics/data/repositories/failure_log_repository_impl.dart';

/// FailureLogRepositoryImpl 单元测试（诊断包）
///
/// 使用内存 drift 数据库（NativeDatabase.memory()），验证：
/// - insertLog 返回含回填 id 的 entry（id > 0）
/// - getRecentLogs 按 createdAt 降序、limit 截断、mode/sessionId 过滤
/// - clearAll 清空全部
/// - deleteBySession 仅清当前 session，不影响其他 session
/// - 静默降级：数据库关闭后所有操作返回安全默认值，不抛异常
///
/// 权威设计： 计划 / DOC-05（待  补充接口索引）。
void main() {
  late AppDatabase db;
  late FailureLogRepositoryImpl repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = FailureLogRepositoryImpl(database: db);
  });

  tearDown(() async => db.close());

  // ── insertLog ────────────────────────────────────────────────────────

  group('insertLog', () {
    test('1. 返回含回填 id 的 entry（id > 0），字段透传正确', () async {
      final entry = await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'network',
        errorCode: 'E012',
        failedPhase: 'generating',
        httpStatus: 500,
        errorMessage: '网络异常',
        rawError: 'SocketException: Connection refused',
      );

      expect(entry.id, greaterThan(0));
      expect(entry.sessionId, 's1');
      expect(entry.mode, 'intermediate');
      expect(entry.errorCategory, 'network');
      expect(entry.errorCode, 'E012');
      expect(entry.failedPhase, 'generating');
      expect(entry.httpStatus, 500);
      expect(entry.errorMessage, '网络异常');
      expect(entry.rawError, 'SocketException: Connection refused');
      expect(entry.createdAt, isNotNull);
    });

    test('2. 可选字段为 null 时正常写入', () async {
      final entry = await repo.insertLog(
        sessionId: 's1',
        mode: 'simple',
        errorCategory: 'unknown',
      );

      expect(entry.id, greaterThan(0));
      expect(entry.errorCode, isNull);
      expect(entry.failedPhase, isNull);
      expect(entry.httpStatus, isNull);
      expect(entry.errorMessage, isNull);
      expect(entry.rawError, isNull);
    });
  });

  // ── getRecentLogs ────────────────────────────────────────────────────

  group('getRecentLogs', () {
    test('3. 多条日志按 createdAt 降序返回（最新在前）', () async {
      // 用间隔插入确保 createdAt 时间戳递增（避免同毫秒）
      for (var i = 1; i <= 3; i++) {
        await repo.insertLog(
          sessionId: 's1',
          mode: 'intermediate',
          errorCategory: 'network',
          errorCode: 'E0$i',
        );
        // 10ms 间隔确保 createdAt 不同毫秒
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final logs = await repo.getRecentLogs();

      expect(logs.length, 3);
      // 最新插入的在前，最早在后
      expect(logs[0].errorCode, 'E03');
      expect(logs[1].errorCode, 'E02');
      expect(logs[2].errorCode, 'E01');
      // 时间戳严格递减
      expect(logs[0].createdAt.isAfter(logs[1].createdAt), true);
      expect(logs[1].createdAt.isAfter(logs[2].createdAt), true);
    });

    test('4. limit 截断', () async {
      for (var i = 0; i < 5; i++) {
        await repo.insertLog(
          sessionId: 's1',
          mode: 'intermediate',
          errorCategory: 'network',
        );
      }

      final logs = await repo.getRecentLogs(limit: 2);
      expect(logs.length, 2);
    });

    test('5. mode 过滤：仅返回指定模式的日志', () async {
      await repo.insertLog(
        sessionId: 's1',
        mode: 'simple',
        errorCategory: 'unknown',
      );
      await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'network',
      );
      await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'config',
      );

      final intermediateLogs = await repo.getRecentLogs(mode: 'intermediate');
      expect(intermediateLogs.length, 2);
      expect(intermediateLogs.every((e) => e.mode == 'intermediate'), true);

      final simpleLogs = await repo.getRecentLogs(mode: 'simple');
      expect(simpleLogs.length, 1);
      expect(simpleLogs.first.mode, 'simple');
    });

    test('6. sessionId 过滤：仅返回指定会话的日志', () async {
      await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'network',
      );
      await repo.insertLog(
        sessionId: 's2',
        mode: 'intermediate',
        errorCategory: 'config',
      );

      final s1Logs = await repo.getRecentLogs(sessionId: 's1');
      expect(s1Logs.length, 1);
      expect(s1Logs.first.sessionId, 's1');
    });

    test('7. mode + sessionId 联合过滤', () async {
      await repo.insertLog(
        sessionId: 's1',
        mode: 'simple',
        errorCategory: 'unknown',
      );
      await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'network',
      );
      await repo.insertLog(
        sessionId: 's2',
        mode: 'intermediate',
        errorCategory: 'config',
      );

      final logs = await repo.getRecentLogs(
        mode: 'intermediate',
        sessionId: 's1',
      );
      expect(logs.length, 1);
      expect(logs.first.mode, 'intermediate');
      expect(logs.first.sessionId, 's1');
    });

    test('8. 空表返回空列表', () async {
      final logs = await repo.getRecentLogs();
      expect(logs, isEmpty);
    });
  });

  // ── clearAll ─────────────────────────────────────────────────────────

  group('clearAll', () {
    test('9. 清空全部日志（跨会话跨模式）', () async {
      await repo.insertLog(
        sessionId: 's1',
        mode: 'simple',
        errorCategory: 'unknown',
      );
      await repo.insertLog(
        sessionId: 's2',
        mode: 'intermediate',
        errorCategory: 'network',
      );

      await repo.clearAll();

      final logs = await repo.getRecentLogs();
      expect(logs, isEmpty);
    });
  });

  // ── deleteBySession ──────────────────────────────────────────────────

  group('deleteBySession', () {
    test('10. 仅删当前 session，其他 session 不受影响', () async {
      await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'network',
      );
      await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'config',
      );
      await repo.insertLog(
        sessionId: 's2',
        mode: 'intermediate',
        errorCategory: 'network',
      );

      final deleted = await repo.deleteBySession('s1');
      expect(deleted, 2);

      final s1Logs = await repo.getRecentLogs(sessionId: 's1');
      expect(s1Logs, isEmpty);

      final s2Logs = await repo.getRecentLogs(sessionId: 's2');
      expect(s2Logs.length, 1);
    });

    test('11. 删除不存在的 session 返回 0，无副作用', () async {
      await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'network',
      );

      final deleted = await repo.deleteBySession('non-existent');
      expect(deleted, 0);

      final logs = await repo.getRecentLogs();
      expect(logs.length, 1);
    });
  });

  // ── 静默降级 ─────────────────────────────────────────────────────────
  // 日志是诊断辅助，操作失败不应影响主流程。所有方法 catch → 返回安全默认值。
  //
  // 触发降级方式：DROP failure_logs 表让 SQL 操作抛异常。
  // （db.close() 后 drift 仍可能缓冲操作，DROP TABLE 更可靠。）

  group('静默降级（DROP TABLE 后）', () {
    test('12. insertLog 返回 id=-1 占位 entry，不抛异常', () async {
      await db.customStatement('DROP TABLE failure_logs');

      final entry = await repo.insertLog(
        sessionId: 's1',
        mode: 'intermediate',
        errorCategory: 'network',
        errorCode: 'E012',
      );

      expect(entry.id, -1);
      expect(entry.sessionId, 's1');
      expect(entry.errorCategory, 'network');
    });

    test('13. getRecentLogs 返回空列表，不抛异常', () async {
      await db.customStatement('DROP TABLE failure_logs');

      final logs = await repo.getRecentLogs();
      expect(logs, isEmpty);
    });

    test('14. clearAll 不抛异常', () async {
      await db.customStatement('DROP TABLE failure_logs');

      // 不应抛异常
      await repo.clearAll();
    });

    test('15. deleteBySession 返回 0，不抛异常', () async {
      await db.customStatement('DROP TABLE failure_logs');

      final deleted = await repo.deleteBySession('s1');
      expect(deleted, 0);
    });
  });
}
