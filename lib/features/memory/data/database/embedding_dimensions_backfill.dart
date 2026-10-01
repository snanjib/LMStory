import 'package:lmstory/features/chat/data/database/app_database.dart';

/// 幂等回填 experiential_memories.embedding_dimensions
///
/// 只处理「有向量但维度列为 NULL」的行（旧库升级 / 旧备份导入）；
/// `LENGTH(blob)` 返回字节数，Float32 每元素 4 字节。
///
/// 调用方：AppDatabase.beforeOpen（每次开库幂等跑，覆盖升级路径）、
/// BackupRepositoryImpl 导入后（旧备份缺列的行即刻补齐，不等下次启动）。
Future<void> backfillEmbeddingDimensions(AppDatabase database) async {
  await database.customStatement(
    'UPDATE experiential_memories '
    'SET embedding_dimensions = LENGTH(embedding) / 4 '
    'WHERE embedding IS NOT NULL AND embedding_dimensions IS NULL',
  );
}
