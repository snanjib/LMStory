import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

/// looksLikeAppBackupJson：外部"打开方式/分享"JSON 的备份分流判定
///
/// 备份（全量/单会话，v1/v2/v3）必须命中；带 version 字段的第三方资源
/// 格式（SillyTavern 卡 spec_version 是字符串、个别世界书顶层 version）
/// 不得误命中。
void main() {
  group('DataManagementService.looksLikeAppBackupJson', () {
    test('v3 全量备份命中', () {
      expect(
        DataManagementService.looksLikeAppBackupJson(
          '{"version":3,"exportedAt":"2026-09-25T00:00:00Z","sessions":[]}',
        ),
        isTrue,
      );
    });

    test('单会话导出命中', () {
      expect(
        DataManagementService.looksLikeAppBackupJson(
          '{"version":3,"exportedAt":"x","sessions":[{}]}',
        ),
        isTrue,
      );
    });

    test('旧版备份命中（version + presets）', () {
      expect(
        DataManagementService.looksLikeAppBackupJson(
          '{"version":1,"presets":[]}',
        ),
        isTrue,
      );
    });

    test('带 BOM 的备份命中', () {
      expect(
        DataManagementService.looksLikeAppBackupJson(
          '\uFEFF{"version":2,"exportedAt":"x"}',
        ),
        isTrue,
      );
    });

    test('角色卡 JSON 不命中（spec_version 是字符串）', () {
      expect(
        DataManagementService.looksLikeAppBackupJson(
          '{"spec":"chara_card_v2","spec_version":"2.0",'
          '"data":{"name":"x"}}',
        ),
        isFalse,
      );
    });

    test('带 version 的第三方世界书不命中（无载荷键）', () {
      expect(
        DataManagementService.looksLikeAppBackupJson(
          '{"version":1,"entries":{}}',
        ),
        isFalse,
      );
    });

    test('非 JSON 不命中', () {
      expect(
        DataManagementService.looksLikeAppBackupJson('not json'),
        isFalse,
      );
    });

    test('顶层数组不命中', () {
      expect(DataManagementService.looksLikeAppBackupJson('[1,2]'), isFalse);
    });

    test('深嵌套内容不命中（粗检先于 jsonDecode，不栈溢出）', () {
      expect(
        DataManagementService.looksLikeAppBackupJson(
          '{"version":3,"exportedAt":"x","deep":${'[' * 600 + ']' * 600}}',
        ),
        isFalse,
      );
    });
  });
}
