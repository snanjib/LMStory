import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/agent_events_usage_port.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

/// 存储统计 × 导演事件日志端口
///
/// DataManagementService（settings/domain）此前直接 import advanced/data
/// 的 AgentEventLogRepository——features 内 domain→data 违例。收口后改为
/// 依赖 settings/domain 声明的最小端口 [AgentEventsUsagePort]，实现由
/// 组合根（core/di/providers.dart）适配注入。
void main() {
  test('getStorageStats 经 AgentEventsUsagePort 读取导演事件日志用量', () async {
    final service = DataManagementService(
      chatRepository: _StubChatRepository(),
      presetRepository: _StubPresetRepository(),
      settingsRepository: _StubSettingsRepository(),
      backupRepository: _StubBackupRepository(),
      agentEventsUsagePort: _FakeAgentEventsUsagePort(count: 42, bytes: 1024),
    );

    final stats = await service.getStorageStats(dbSizeBytes: 1);

    expect(stats.agentEventCount, 42);
    expect(stats.agentEventBytes, 1024);
  });

  test('未注入端口时存储统计零值兜底（测试桩可不提供）', () async {
    final service = DataManagementService(
      chatRepository: _StubChatRepository(),
      presetRepository: _StubPresetRepository(),
      settingsRepository: _StubSettingsRepository(),
      backupRepository: _StubBackupRepository(),
    );

    final stats = await service.getStorageStats(dbSizeBytes: 1);

    expect(stats.agentEventCount, 0);
    expect(stats.agentEventBytes, 0);
  });
}

class _FakeAgentEventsUsagePort implements AgentEventsUsagePort {
  _FakeAgentEventsUsagePort({required this.count, required this.bytes});

  final int count;
  final int bytes;

  @override
  Future<({int count, int bytes})> eventsUsage() async =>
      (count: count, bytes: bytes);
}

class _StubChatRepository implements ChatRepository {
  @override
  Future<List<ChatSession>> getAllSessions() async => const [];

  @override
  Future<int> getTotalMessageCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<int> getUserOverrideCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubBackupRepository implements BackupRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
