import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';

/// FTS description 拼接口径单源——基线+演变全行
/// 进索引（只影响召回，不影响注入/展示）。
///
/// 此前两处重建各自取「首行=基线」（口径），并存演变行时检索只按
/// 基线文本命中；=新旧都进索引。分隔用换行（FTS 分词面，无解析语义）。
String composeFtsDescription(List<String> descriptionValues) =>
    descriptionValues.where((v) => v.isNotEmpty).join('\n');

/// 会话级 FTS5 索引统一重建（2026-09-09 记忆审查 FF6/ 抽取共享）
///
/// 以**落库后的主表**为唯一数据源（禁止出现第三份重建 SQL）：
/// - `factual_fts` 只建 worldbook 词条（与投影写侧覆盖面口径一致），
///   description 取落库后的 `attr_key='description'` 行；
/// - `memories_fts` 按 `experiential_memories` 全量重建——缺
///   `memoriesFts` 行时整会话记忆检索不再静默失效。
///
/// 调用方：备份导入（BackupRepositoryImpl）、复制会话
/// （ChatRepositoryImpl.copySession 搬运记忆后）。
Future<void> rebuildSessionFts(AppDatabase database, String sessionId) async {
  // 1) factual_fts（世界书词条）
  await database.customStatement(
    'DELETE FROM factual_fts WHERE session_id = ?',
    [sessionId],
  );
  final entities = await database.customSelect(
    'SELECT entity_id, primary_name, aliases FROM factual_entities '
    "WHERE session_id = ? AND source = 'worldbook'",
    variables: [Variable.withString(sessionId)],
  ).get();
  if (entities.isNotEmpty) {
    final descriptionRows = await database.customSelect(
      'SELECT entity_id, value FROM factual_attributes '
      "WHERE session_id = ? AND attr_key = 'description' "
      // 显式固化「首行=基线」口径，与
      // getAttributesByKey 的 rowid 排序一致
      'ORDER BY rowid',
      variables: [Variable.withString(sessionId)],
    ).get();
    // 基线+演变全行聚合进索引（原 putIfAbsent 只记首行）
    final descriptionByEntity = <String, List<String>>{};
    for (final row in descriptionRows) {
      descriptionByEntity
          .putIfAbsent(row.read<String>('entity_id'), () => [])
          .add(row.read<String>('value'));
    }
    for (final row in entities) {
      final entityId = row.read<String>('entity_id');
      await database.customStatement(
        'INSERT INTO factual_fts '
        '(primary_name, aliases, description, entity_id, session_id) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          row.read<String>('primary_name'),
          ftsAliasesJoined(row.read<String>('aliases')),
          composeFtsDescription(descriptionByEntity[entityId] ?? const []),
          entityId,
          sessionId,
        ],
      );
    }
  }

  // 2) memories_fts（全部经历记忆，含低重要性行——索引缺失时更该补齐）
  await database.customStatement(
    'DELETE FROM memories_fts WHERE session_id = ?',
    [sessionId],
  );
  final memories = await database.customSelect(
    'SELECT memory_id, summary, when_text, where_text, who_text, what_text, '
    'significance, extra FROM experiential_memories WHERE session_id = ?',
    variables: [Variable.withString(sessionId)],
  ).get();
  for (final row in memories) {
    await database.customStatement(
      'INSERT INTO memories_fts '
      '(summary, when_text, where_text, who_text, what_text, significance, '
      'extra, memory_id, memory_type, session_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        row.read<String?>('summary') ?? '',
        row.read<String?>('when_text') ?? '',
        row.read<String?>('where_text') ?? '',
        row.read<String?>('who_text') ?? '',
        row.read<String?>('what_text') ?? '',
        row.read<String?>('significance') ?? '',
        row.read<String?>('extra') ?? '',
        row.read<String>('memory_id'),
        'experiential',
        sessionId,
      ],
    );
  }
}

/// 解析实体行 aliases 列（JSON 数组字符串）为空格拼接（FTS 口径）
String ftsAliasesJoined(String aliasesValue) {
  try {
    final decoded = jsonDecode(aliasesValue);
    if (decoded is List) {
      return decoded.whereType<String>().join(' ');
    }
  } on FormatException {
    // 兼容异常行：保持原串（trigram 仍可召回其内容）
  }
  return aliasesValue;
}
