import 'dart:async';

import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';

class PausedBackupRestore extends BackupRepositoryImpl {
  PausedBackupRestore({required super.database});

  final entered = Completer<void>();
  final resume = Completer<void>();
  int deletes = 0;
  int writes = 0;

  @override
  Future<void> deleteAllSessionData() {
    deletes++;
    return super.deleteAllSessionData();
  }

  @override
  Future<int> importSessionData(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    writes++;
    entered.complete();
    await resume.future;
    return super.importSessionData(data, mode: mode);
  }
}
