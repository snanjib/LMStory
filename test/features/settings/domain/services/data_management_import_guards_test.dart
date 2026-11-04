import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

///  ：覆盖导入域判定与偏好脏值拒收
///
/// 空 `presets: []` 备份（零供应商设备导出的真实形态）此前
/// 覆盖导入会 deleteAllCustomPresets() 删光本机供应商与 Key 且不导入
/// 任何——与  会话域同口径改为「键存在且非空 List 才算有」。
/// a：偏好表叶子全为标量，List/null 脏值从源头拒收计 skipped。
void main() {
  late _RecordingBackupRepository backupRepo;
  late _RecordingSettingsRepository settingsRepo;
  late DataManagementService service;

  setUp(() {
    backupRepo = _RecordingBackupRepository();
    settingsRepo = _RecordingSettingsRepository();
    service = DataManagementService(
      chatRepository: _StubChatRepository(),
      presetRepository: _StubPresetRepository(),
      settingsRepository: settingsRepo,
      backupRepository: backupRepo,
    );
  });

  group('presets 域非空 List 判定', () {
    test('空 presets 数组覆盖导入 → 不删本机供应商（对齐  口径）', () async {
      await service.importBackup(
        '{"version": 2, "presets": [], "preferences": {"a.b": 1}}',
        ImportMode.overwrite,
      );

      expect(
        backupRepo.calls,
        isNot(contains('deleteAllCustomPresets')),
        reason: '空数组=「无数据可导入」，不应等价于清空该域',
      );
      // preferences 键存在仍走正常覆盖链
      expect(settingsRepo.clearedOverrides, isTrue);
      expect(settingsRepo.setOverrides, {'a.b': 1});
    });

    test('非空 presets 数组覆盖导入 → 正常删除+导入（既有语义保持）', () async {
      await service.importBackup(
        '{"version": 2, "presets": [{"presetId": "p1"}]}',
        ImportMode.overwrite,
      );

      expect(backupRepo.calls, contains('deleteAllCustomPresets'));
    });

    test('presets 值非 List（畸形备份）→ 跳过该域不删库', () async {
      await service.importBackup(
        '{"version": 2, "presets": "corrupt"}',
        ImportMode.overwrite,
      );

      expect(backupRepo.calls, isNot(contains('deleteAllCustomPresets')));
    });
  });

  group('偏好脏值拒收', () {
    test('List/null 脏值计 skipped，不落覆盖表', () async {
      final result = await service.importBackup(
        '{"version": 2, "preferences": {"network.connect_timeout_ms": 15000, '
        '"bad.list": [1, 2], '
        '"bad.null": null}}',
        ImportMode.overwrite,
      );

      expect(result.importedPreferences, 1);
      expect(result.skippedPreferences, 2);
      expect(settingsRepo.setOverrides, {'network.connect_timeout_ms': 15000});
    });

    test('标量 Map（嵌套标量）放行', () async {
      final result = await service.importBackup(
        '{"version": 2, "preferences": {"group.key": {"inner": "v"}}}',
        ImportMode.overwrite,
      );

      expect(result.importedPreferences, 1);
      expect(result.skippedPreferences, 0);
    });
  });

  group('深度粗检：数据备份导入链', () {
    test('超深 JSON → FormatException 带明确文案（不栈溢出）', () async {
      final deep = '[' * 600 + ']' * 600;
      await expectLater(
        service.importBackup(
          '{"version": 2, "exportedAt": "x", "deep": $deep}',
          ImportMode.append,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('嵌套过深'),
          ),
        ),
      );
      // 拒收发生在任何写库之前
      expect(backupRepo.calls, isEmpty);
    });

    test('带 BOM 的超深 JSON 同样被前置拒绝', () async {
      final deep = '[' * 600 + ']' * 600;
      await expectLater(
        service.importBackup(
          '\uFEFF{"version": 2, "deep": $deep}',
          ImportMode.append,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

class _RecordingBackupRepository implements BackupRepository {
  final List<String> calls = [];

  @override
  Future<void> deleteAllSessionData() async =>
      calls.add('deleteAllSessionData');

  @override
  Future<void> deleteAllCustomPresets() async =>
      calls.add('deleteAllCustomPresets');

  @override
  Future<int> importSessionData(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    calls.add('importSessionData');
    return 0;
  }

  @override
  Future<bool> importPreset(
    Map<String, dynamic> preset, {
    required ImportMode mode,
  }) async {
    calls.add('importPreset');
    return true;
  }

  @override
  Future<int> importGlobalAssets(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    calls.add('importGlobalAssets');
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _RecordingSettingsRepository implements SettingsRepository {
  final Map<String, dynamic> setOverrides = {};
  bool clearedOverrides = false;

  @override
  Future<void> setUserOverride(String key, dynamic value) async =>
      setOverrides[key] = value;

  @override
  Future<void> clearAllUserOverrides() async => clearedOverrides = true;

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubChatRepository implements ChatRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubPresetRepository implements ApiPresetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
