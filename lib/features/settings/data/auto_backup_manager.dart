import 'dart:io';

import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:path_provider/path_provider.dart';

/// 自动备份管理器（备份完整性立项，2026-09-02）
///
/// 启动后空闲（首帧后延迟）静默检查：
/// 1. 开关（用户偏好 `data.auto_backup_enabled`，默认**开启**）
/// 2. 距上份备份 > 24h（按应用文档目录 `backups/` 内最新文件 mtime）
/// 3. 有会话数据（空库不备份）
///
/// 满足则静默导出全量备份（**默认不含 API Key**）写入 `backups/`，
/// 滚动保留最近 [keepCount] 份。任何失败仅记日志——自动备份绝不打扰
/// 启动流程，也绝不因文件系统异常崩溃。
///
/// 文件 IO 位于本类（data 层）而非 Presentation：自动备份没有 UI 宿主，
/// 与 db_storage_info 同模式。目录与时钟可注入以便测试。
class AutoBackupManager {
  AutoBackupManager({
    required DataManagementService dataManagementService,
    required SettingsRepository settingsRepository,
    required ChatRepository chatRepository,
    Future<Directory> Function()? documentsDirectory,
    DateTime Function()? clock,
  })  : _dataManagementService = dataManagementService,
        _settingsRepository = settingsRepository,
        _chatRepository = chatRepository,
        _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory,
        _clock = clock ?? DateTime.now;

  static const Logger _logger = Logger('AutoBackupManager');

  final DataManagementService _dataManagementService;
  final SettingsRepository _settingsRepository;
  final ChatRepository _chatRepository;
  final Future<Directory> Function() _documentsDirectory;
  final DateTime Function() _clock;

  /// 用户偏好键：自动备份开关（缺省 = 开启）
  static const String enabledKey = 'data.auto_backup_enabled';

  /// 最近一次自动备份失败记录键——值=ISO 时间|异常
  /// 类型名（不含敏感细节），成功备份后清除；数据管理页状态行据此提示。
  static const String lastFailureKey = 'data.auto_backup_last_failure';

  /// 备份间隔（距上份自动/手动备份不足此值不重复备份）
  static const Duration backupInterval = Duration(hours: 24);

  /// 滚动保留份数
  static const int keepCount = 3;

  /// 备份文件名前缀/目录名
  static const String directoryName = 'backups';
  static const String fileNamePrefix = 'lmstory_auto_backup_';

  /// 覆盖导入前置快照前缀与保留份数。
  ///
  /// 保留 2 份（「最近一次」口径 + 一次保险余量：连续两次导入失败
  /// 实验时，倒数第二份保住「两次导入前」的原始库）。与自动备份的
  /// 3 份窗口互不挤占（[_rollingTrim] 与 [listBackups] 均按前缀过滤，
  /// 外来 .json 一并不动—— 08 分册改进机会 2 顺手收口）。
  static const String preImportFileNamePrefix = 'lmstory_pre_import_';
  static const int preImportKeepCount = 2;

  /// 原子写 `.json.tmp` 孤儿的清理时限。写入目标名后、
  /// rename 前崩溃/断电会留下孤儿——listBackups/_rollingTrim 都按 `.json`
  /// 过滤看不到它，只能无限累积。超过此时限的 `*.json.tmp` 在滚动清理时
  /// 顺带删除；时限内的可能是另一链路正在写的 tmp，不得误删。
  static const Duration tmpOrphanMaxAge = Duration(days: 1);

  /// 开关状态（缺省 = 开启）
  Future<bool> isEnabled() async {
    try {
      final overrides = await _settingsRepository.getUserOverrides();
      final value = overrides[enabledKey];
      return value is! bool || value;
    } catch (e) {
      _logger.warn(
        'Read auto backup switch failed, default to enabled',
        detail: '$e',
      );
      return true;
    }
  }

  /// 设置开关（数据管理页开关接线）
  Future<void> setEnabled({required bool enabled}) =>
      _settingsRepository.setUserOverride(enabledKey, enabled);

  /// 备份目录（不存在则创建）
  Future<Directory> backupsDirectory() async {
    final docs = await _documentsDirectory();
    final dir =
        Directory('${docs.path}${Platform.pathSeparator}$directoryName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 列出现有自动备份文件（按修改时间新→旧）。
  ///
  /// 只列 [fileNamePrefix] 前缀—— 起 backups/ 内还有 pre_import 快照
  /// 与用户手放文件，间隔检查与滚动清理都不得被它们干扰。
  Future<List<File>> listBackups() async {
    final dir = await backupsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.json') &&
              _baseName(f).startsWith(fileNamePrefix),
        )
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  /// 列出覆盖导入前置快照（按修改时间新→旧）
  Future<List<File>> listPreImportSnapshots() async {
    final dir = await backupsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.json') &&
              _baseName(f).startsWith(preImportFileNamePrefix),
        )
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  static String _baseName(File f) {
    final sep = f.path.lastIndexOf(Platform.pathSeparator);
    return sep == -1 ? f.path : f.path.substring(sep + 1);
  }

  /// 覆盖导入前置快照。
  ///
  /// v3 JSON 全量导出，含会话、配置及资源。调用方确定需要保护时执行，
  /// 读回并验证无密钥的快照后才允许开始覆盖。任何失败均向上返回。
  Future<File> createPreImportSnapshot() async {
    final json = await _dataManagementService.exportFullBackup(
      const DataExportOptions(
        includeSessions: true,
        includePresets: true,
        includePreferences: true,
      ),
    );
    DataManagementService.validatePreImportSnapshot(json);
    final file = await _writeBackupFile(json, prefix: preImportFileNamePrefix);
    if (await file.readAsString() != json) {
      throw const FormatException(
        'Could not read back the pre-import snapshot',
      );
    }
    await _rollingTrim(
      preImportFileNamePrefix,
      preImportKeepCount,
      retainPath: file.path,
    );
    _logger.info(
      'Pre-import snapshot written',
      detail: '${file.path} (${json.length} chars)',
    );
    return file;
  }

  /// 按需执行一次自动备份
  ///
  /// - [force]：跳过 24h 间隔与会话存在性检查（「立即备份」入口）；
  ///   false 时三条件（开关/间隔/有会话）全过才执行
  /// - 返回写入的文件；未执行/失败返回 null（调用方无须区分原因，
  ///   失败细节已在日志中）
  Future<File?> runIfNeeded({bool force = false}) async {
    try {
      if (!force) {
        if (!await isEnabled()) return null;
        final existing = await listBackups();
        if (existing.isNotEmpty) {
          final newest = existing.first.lastModifiedSync();
          if (_clock().difference(newest) < backupInterval) return null;
        }
        final sessions = await _chatRepository.getAllSessions();
        if (sessions.isEmpty) return null;
      }

      final json = await _dataManagementService.exportFullBackup(
        const DataExportOptions(
          includeSessions: true,
          includePresets: true,
          includePreferences: true,
        ),
      );

      final file = await _writeBackupFile(json);
      await _rollingTrim(fileNamePrefix, keepCount);
      // 成功清除失败记录（状态行回到「上次成功」口径）
      await _clearLastFailure();
      _logger.info(
        'Auto backup written',
        detail: '${file.path} (${json.length} chars)',
      );
      return file;
    } catch (e, stackTrace) {
      _logger.warn(
        'Auto backup failed (ignored)',
        detail: '$e\n$stackTrace',
      );
      // 失败落键（数据管理页状态行可见，不再完全无感）
      await _recordLastFailure(e);
      return null;
    }
  }

  /// 记录失败（值=ISO 时间|异常类型名）；键写入失败不打扰主流程。
  Future<void> _recordLastFailure(Object e) async {
    try {
      await _settingsRepository.setUserOverride(
        lastFailureKey,
        '${_clock().toIso8601String()}|${e.runtimeType}',
      );
    } catch (_) {}
  }

  Future<void> _clearLastFailure() async {
    try {
      await _settingsRepository.removeUserOverride(lastFailureKey);
    } catch (_) {}
  }

  /// 写入备份文件。预导入快照遇到同秒文件名时保留两个版本。
  Future<File> _writeBackupFile(String content, {String? prefix}) async {
    final dir = await backupsDirectory();
    final now = _clock();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final stem = '${dir.path}${Platform.pathSeparator}'
        '${prefix ?? fileNamePrefix}$stamp';
    var file = File('$stem.json');
    if (prefix == preImportFileNamePrefix) {
      var suffix = 1;
      while (file.existsSync() || File('${file.path}.tmp').existsSync()) {
        file = File('${stem}_${suffix++}.json');
      }
    }
    // temp+rename 原子写。直写目标名在写途中
    // 崩溃/断电会留半截 JSON——它 mtime 最新，滚动清理反而保留半截、
    // 挤掉完好的旧备份，回滚时 jsonDecode 失败。
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Windows rename 到已存在路径失败：秒级撞名（force 连续备份）时
      // 先移除目标再改名
      if (prefix == preImportFileNamePrefix || !file.existsSync()) rethrow;
      await file.delete();
      await tmp.rename(file.path);
    }
    return file;
  }

  /// 滚动清理：指定前缀保留最近 [keepCount] 份，其余删除。
  ///
  ///  起按前缀分域——自动备份 trim 只看 `lmstory_auto_backup_`，
  /// pre_import 快照与用户手放的 .json 一并不动（改进机会 2 收口：
  /// 此前会删 backups/ 内任意 .json）。
  ///
  /// 顺带清理超过 [tmpOrphanMaxAge]
  /// `*.json.tmp` 原子写孤儿（不限前缀——孤儿只可能产自本类的
  /// temp+rename 管线）。
  Future<void> _rollingTrim(
    String prefix,
    int keepCount, {
    String? retainPath,
  }) async {
    final dir = await backupsDirectory();
    await _cleanupTmpOrphans(dir);
    final files = dir
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              f.path != retainPath &&
              f.path.endsWith('.json') &&
              _baseName(f).startsWith(prefix),
        )
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final stale
        in files.skip(retainPath == null ? keepCount : keepCount - 1)) {
      try {
        stale.deleteSync();
      } catch (e) {
        _logger.warn(
          'Rolling trim skip unremovable file',
          detail: '${stale.path}: $e',
        );
      }
    }
  }

  /// 清理 backups/ 内超过 [tmpOrphanMaxAge] 的 `.json.tmp` 孤儿。
  ///
  /// 时限内的 tmp 可能是并发链路 temp+rename 的中间态，一律不动；
  /// mtime 读取/删除失败仅记日志，不影响主清理流程。
  Future<void> _cleanupTmpOrphans(Directory dir) async {
    final now = _clock();
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json.tmp')) continue;
      try {
        final age = now.difference(entity.lastModifiedSync());
        if (age >= tmpOrphanMaxAge) {
          entity.deleteSync();
          _logger.info('Removed stale tmp orphan', detail: entity.path);
        }
      } catch (e) {
        _logger.warn(
          'Tmp orphan cleanup skip',
          detail: '${entity.path}: $e',
        );
      }
    }
  }
}
