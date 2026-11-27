import 'dart:io';

import 'package:path/path.dart' as p;

const _databaseName = 'lmstory.db';
const recoveryDirectoryName = 'database_recovery';
const activeRecoveryFileName = 'active';

File originalNativeDatabase(Directory documents) =>
    File(p.join(documents.path, _databaseName));

File recoveredNativeDatabase(Directory recoveryDirectory) =>
    File(p.join(recoveryDirectory.path, _databaseName));

/// An activation record points only to a fully prepared database.
Future<(File, String?)> activeNativeDatabase(Directory documents) async {
  final id = await activeNativeRecoveryId(documents);
  if (id == null) return (originalNativeDatabase(documents), null);
  final root = p.join(documents.path, recoveryDirectoryName);
  final file = recoveredNativeDatabase(Directory(p.join(root, id)));
  if (!file.existsSync()) {
    throw FileSystemException('Activated database is missing', file.path);
  }
  return (file, id);
}

Future<String?> activeNativeRecoveryId(Directory documents) async {
  final root = p.join(documents.path, recoveryDirectoryName);
  final record = File(p.join(root, activeRecoveryFileName));
  if (!record.existsSync()) return null;
  final id = await record.readAsString();
  if (!_recoveryIdPattern.hasMatch(id)) {
    throw const FormatException('Invalid database activation record');
  }
  return id;
}

final _recoveryIdPattern = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
);
