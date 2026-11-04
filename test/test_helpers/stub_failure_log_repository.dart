import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';

/// 测试用 FailureLogRepository Stub（所有方法 no-op，不依赖数据库）
///
/// 用于 Controller/Page 测试，避免引入真实 drift 数据库。
/// 域层 Repository 测试（failure_log_repository_impl_test.dart）用真实
/// FailureLogRepositoryImpl + 内存数据库，不用本 Stub。
class StubFailureLogRepository implements FailureLogRepository {
  const StubFailureLogRepository();

  @override
  @override
  Future<void> markRecovered(int logId) async {}

  @override
  Future<FailureLogEntry> insertLog({
    required String sessionId,
    required String mode,
    required String errorCategory,
    String? errorCode,
    String? failedPhase,
    int? httpStatus,
    String? errorMessage,
    String? rawError,
    String? outcome,
  }) async {
    return FailureLogEntry(
      id: 1,
      sessionId: sessionId,
      mode: mode,
      errorCategory: errorCategory,
      errorCode: errorCode,
      failedPhase: failedPhase,
      httpStatus: httpStatus,
      errorMessage: errorMessage,
      rawError: rawError,
      createdAt: DateTime(2026),
    );
  }

  @override
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  }) async {
    return const <FailureLogEntry>[];
  }

  @override
  Future<int> countAll() async => 0;

  @override
  Future<void> clearAll() async {}

  @override
  Future<int> deleteBySession(String sessionId) async => 0;
}
