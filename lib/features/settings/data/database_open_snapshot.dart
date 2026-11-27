import 'dart:io';

import 'package:lmstory/core/utils/logger.dart';
import 'package:path/path.dart' as p;

/// Preserves the complete file set before SQLite can migrate or checkpoint it.
///
/// An existing database is copied once with filesystem I/O. Normal startup
/// continues using its usual path and releases this temporary copy.
class DatabaseOpenSnapshot {
  DatabaseOpenSnapshot._(this._directory);

  static const _suffixes = ['', '-wal', '-shm', '-journal'];
  static const _openingPrefix = '.lmstory-opening-';
  static const _preservedPrefix = 'lmstory-preserved-';
  static const _log = Logger('DatabaseStartup');

  final Directory _directory;

  String pathFor(File original) =>
      p.join(_directory.path, p.basename(original.path));

  static Future<DatabaseOpenSnapshot?> capture(File file) async {
    if (!file.existsSync() || file.lengthSync() == 0) return null;
    final directory = await file.parent.createTemp(_openingPrefix);
    try {
      File source(String suffix) => File('${file.path}$suffix');
      final before = {
        for (final suffix in _suffixes) suffix: source(suffix).statSync(),
      };
      if (before['']?.type != FileSystemEntityType.file) {
        throw const FileSystemException('Database changed during startup copy');
      }
      for (final entry in before.entries) {
        final type = entry.value.type;
        if (type == FileSystemEntityType.notFound) continue;
        if (type != FileSystemEntityType.file) {
          throw const FileSystemException('Database component is not a file');
        }
        final original = source(entry.key);
        final copy = await original.copy(
          p.join(directory.path, p.basename(original.path)),
        );
        if (copy.lengthSync() != entry.value.size) {
          throw const FileSystemException(
            'Startup database copy is incomplete',
          );
        }
      }
      for (final entry in before.entries) {
        final after = source(entry.key).statSync();
        if (after.type != entry.value.type ||
            after.size != entry.value.size ||
            after.modified != entry.value.modified ||
            after.changed != entry.value.changed) {
          throw const FileSystemException(
            'Database changed during startup copy',
          );
        }
      }
      // Publish only a complete set, before the writable open. If the process
      // exits during that open, the preserved set remains discoverable.
      final nonce = p.basename(directory.path).substring(_openingPrefix.length);
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      final preserved = await directory.rename(
        p.join(file.parent.path, '$_preservedPrefix$timestamp-$nonce'),
      );
      return DatabaseOpenSnapshot._(preserved);
    } on Object {
      await DatabaseOpenSnapshot._(directory).discard();
      rethrow;
    }
  }

  /// The latest and earlier copies stay reachable after a retry or restart.
  static Future<List<String>> preservedPaths(File original) async {
    final paths = <String>[];
    try {
      await for (final entry in original.parent.list(followLinks: false)) {
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith(_preservedPrefix)) {
          continue;
        }
        final candidate = File(p.join(entry.path, p.basename(original.path)));
        if (candidate.existsSync()) paths.add(candidate.path);
      }
    } on FileSystemException catch (error) {
      _log.warn(
        'Could not list preserved database copies',
        detail: error.runtimeType.toString(),
      );
    }
    return paths..sort((a, b) => b.compareTo(a));
  }

  Future<void> discard() async {
    try {
      await _directory.delete(recursive: true);
    } on FileSystemException catch (error) {
      _log.warn(
        'Could not remove startup snapshot',
        detail: error.runtimeType.toString(),
      );
    }
  }
}
