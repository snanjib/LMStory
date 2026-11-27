import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show SizedBox, ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/simple/simple_theme.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/data/browser_backup_snapshots.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery_web.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/features/settings/presentation/widgets/database_startup_gate.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'browser inspection reads stored snapshots and UTF-8 files without activation',
    skip: !kIsWeb,
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = Preferences();
      final snapshots = BrowserBackupSnapshots(prefs);
      final service = _SyntheticExportService();
      final older = await snapshots.create(service);
      final middle = await snapshots.create(service);
      final newest = await snapshots.create(service);
      final names = [newest, middle];
      final savedBackups = await snapshots.list();
      expect(savedBackups.map((backup) => backup.name), names);
      expect(savedBackups.map((backup) => backup.name), isNot(contains(older)));
      final picker = _BrowserPicker();
      FilePicker.platform = picker;
      final recovery = _FailedBrowserOpen(createStartupDatabaseRecovery(prefs));
      await tester.pumpWidget(
        DatabaseStartupGate(
          recovery: recovery,
          buildApplication: (_) async => const SizedBox.shrink(),
          lightTheme: SimpleTheme.lightTheme,
          darkTheme: SimpleTheme.darkTheme,
          themeMode: ThemeMode.light,
        ),
      );
      await tester.pumpAndSettle();
      final strings = t.settings.data.startupRecovery;
      expect(find.text(strings.webInstructions), findsOneWidget);

      final saved = find.text(newest);
      await tester.ensureVisible(saved);
      await tester.tap(saved);
      await tester.pumpAndSettle();
      expect(find.text(strings.webCheckPassed), findsOneWidget);
      expect(find.text(strings.useBackup), findsNothing);
      await tester.tap(find.text(t.common.cancel));
      await tester.pumpAndSettle();

      final chooseFile = find.text(strings.chooseFile);
      await tester.ensureVisible(chooseFile);
      await tester.tap(chooseFile);
      await tester.pumpAndSettle();
      expect(picker.usedBytes, isTrue);
      expect(find.text(_BrowserPicker.fileName), findsOneWidget);
      expect(find.text(strings.selectedFile), findsOneWidget);
      expect(find.text(strings.webCheckPassed), findsOneWidget);
      expect(find.text(strings.useBackup), findsNothing);
      expect(find.byType(MyApp), findsNothing);

      for (final (content, message) in [
        ('{"version":3,"sessions":"broken"}', strings.invalidBackup),
        (
          '{"version":3,"exportedAt":"2026-11-20T00:00:00Z"}',
          strings.noRestorableData,
        ),
        (
          '{"version":3,"preferences":{"fixture.good":"sample",'
              '"fixture.bad":["unsupported"]}}',
          strings.webPartialCheck,
        ),
      ]) {
        picker.content = content;
        await tester.ensureVisible(chooseFile);
        await tester.tap(chooseFile);
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        expect(find.text(strings.webCheckPassed), findsNothing);
        expect(find.text(strings.useBackup), findsNothing);
      }
      expect((await snapshots.list()).map((b) => b.name), names);
      expect(tester.takeException(), isNull);
    },
  );
}

class _FailedBrowserOpen implements DatabaseStartupRecovery {
  const _FailedBrowserOpen(this._browser);

  final DatabaseStartupRecovery _browser;

  @override
  bool get supportsActivation => _browser.supportsActivation;

  @override
  Future<OpenedDatabase> open() async => throw const DatabaseOpenFailure();

  @override
  Future<List<RecoveryBackup>> listBackups() => _browser.listBackups();

  @override
  Future<PreparedDatabaseRecovery> prepare(String backup) =>
      _browser.prepare(backup);
}

class _BrowserPicker extends FilePicker {
  static const fileName = '合成备份.json';
  bool usedBytes = false;
  String content = '{"version":3,"preferences":{"user.note":"合成内容"}}';

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    usedBytes = withData;
    final bytes = Uint8List.fromList(utf8.encode(content));
    return FilePickerResult(
      [PlatformFile(name: fileName, size: bytes.length, bytes: bytes)],
    );
  }
}

class _SyntheticExportService extends DataManagementService {
  _SyntheticExportService()
      : super(
          chatRepository: _UnusedRepositories(),
          presetRepository: _UnusedRepositories(),
          settingsRepository: _UnusedRepositories(),
          backupRepository: _UnusedRepositories(),
        );

  var _count = 0;

  @override
  Future<String> exportFullBackup(DataExportOptions options) async =>
      jsonEncode({
        'version': 3,
        'exportedAt': DateTime.utc(2026, 11, 20, ++_count).toIso8601String(),
        'sessions': <Object>[],
        'presets': <Object>[],
        'preferences': {'user.note': '合成内容'},
        'characterCards': <Object>[],
        'worldbooks': <Object>[],
        'userTemplates': <Object>[],
        'agentEvents': <Object>[],
      });
}

class _UnusedRepositories
    implements
        ChatRepository,
        ApiPresetRepository,
        SettingsRepository,
        BackupRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
