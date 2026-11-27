import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';

/// beforeOpen 幂等修复回归测试
///
/// 场景：升级路径的 repairSchema 失败被组件级捕获，而 user_version 由
/// drift 在 onUpgrade 结束后写回——此后 from==to，onUpgrade 不再执行。
/// beforeOpen 修复每次打开幂等重跑 repairSchema 兑现
/// 「下次启动自动重试」承诺。
///
/// 本测试模拟该"半迁移"状态：完整建库 → 原生句柄 DROP 掉一个 v42 列
/// （user_version 保持 43）→ 重新打开 → 断言列被 beforeOpen 补齐。
void main() {
  test('beforeOpen 补齐半迁移库缺失的列（版本号未变时也能自愈）', () async {
    final dir = Directory.systemTemp.createTempSync('lmstory_before_open');
    final file = File('${dir.path}/test.db');
    AppDatabase db;

    try {
      // 1. 完整建库（当前 schema 43）
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customSelect('SELECT 1').get();
      await db.close();

      // 2. 模拟半迁移：版本号仍是 43，但 chat_sessions 缺 v42 的
      //    story_anchor 列（相当于升级时该 ALTER 失败被吞掉）
      final native = NativeDatabase(
        file,
        setup: (raw) {
          final dropped = raw
              .select(
                "SELECT COUNT(*) FROM pragma_table_info('chat_sessions') "
                "WHERE name = 'story_anchor'",
              )
              .first['COUNT(*)'] as int;
          expect(dropped, 1, reason: '测试前置：story_anchor 列应存在');
          raw.execute('ALTER TABLE chat_sessions DROP COLUMN story_anchor');
          final version = raw.select('PRAGMA user_version').first.values.first;
          expect(version, AppDatabase.currentSchemaVersion, reason: '测试前置：版本号保持当前 schema（onUpgrade 不会再跑）');
        },
      );

      // 3. 重新打开：onUpgrade 被跳过，beforeOpen 应补齐缺失列
      db = AppDatabase.forTesting(native);
      await db.customSelect('SELECT 1').get();

      final cols =
          await db.customSelect('PRAGMA table_info(chat_sessions)').get();
      expect(
        cols.map((r) => r.read<String>('name')),
        contains('story_anchor'),
        reason: 'beforeOpen 必须幂等补齐半迁移库的缺失列（A4 承诺成真）',
      );
      await db.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
