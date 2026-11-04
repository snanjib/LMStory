import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/presentation/pages/data_management_page.dart';

/// 批 H 的页面级含 Key 检测此前是
/// `_importData` 内联逻辑、零测试。提取为 [detectBackupContainsSecrets]
/// 后按审查分册描述的口径锁定边界：
///
/// 1. 含 Key 标记：v3 `contains_secrets == true` 直接命中
/// 2. 兜底扫描：手裁/第三方变体无标记时，扫 presets 内
///    `api_key`（v3）/`apiKey`（v1）字段
/// 3. 误报边界：空串/null Key、presets 非 List、条目非 Map、
///    其它字段名均不得误报
/// 4. 漏报边界：裁掉标记但保留 api_key 的文件必须仍被兜底识别
void main() {
  group('detectBackupContainsSecrets（D6-4 页面级检测）', () {
    // ---------- 含 Key 标记 ----------
    test('contains_secrets 显式标记命中', () {
      expect(
        detectBackupContainsSecrets({
          'version': 3,
          'contains_secrets': true,
          'presets': <dynamic>[],
        }),
        isTrue,
        reason: '标记命中优先，即使 presets 列表里没有可读 Key',
      );
    });

    test('contains_secrets 为 false 时不命中标记，但兜底扫描仍生效', () {
      expect(
        detectBackupContainsSecrets({
          'contains_secrets': false,
          'presets': [
            {'api_key': 'sk-live'},
          ],
        }),
        isTrue,
        reason: '标记只认布尔 true；false 时回落兜底扫描',
      );
    });

    test('contains_secrets 为字符串 "true" 不命中标记（类型严格）', () {
      expect(
        detectBackupContainsSecrets({
          'contains_secrets': 'true',
          'presets': <dynamic>[],
        }),
        isFalse,
      );
    });

    // ---------- 兜底扫描 ----------
    test('兜底扫描 v3 api_key 字段', () {
      expect(
        detectBackupContainsSecrets({
          'version': 3,
          'presets': [
            {'id': 'p1', 'api_key': 'sk-abc'},
          ],
        }),
        isTrue,
      );
    });

    test('兜底扫描 v1 apiKey 字段', () {
      expect(
        detectBackupContainsSecrets({
          'version': 1,
          'presets': [
            {'id': 'p1', 'apiKey': 'sk-old'},
          ],
        }),
        isTrue,
      );
    });

    test('多个预设时任一带 Key 即命中', () {
      expect(
        detectBackupContainsSecrets({
          'presets': [
            {'id': 'p1'},
            {'id': 'p2', 'api_key': 'sk-2'},
          ],
        }),
        isTrue,
      );
    });

    // ---------- 误报边界 ----------
    test('空字符串 Key 不算含 Key', () {
      expect(
        detectBackupContainsSecrets({
          'presets': [
            {'api_key': '', 'apiKey': ''},
          ],
        }),
        isFalse,
      );
    });

    test('null Key 不算含 Key', () {
      expect(
        detectBackupContainsSecrets({
          'presets': [
            {'api_key': null, 'apiKey': null},
          ],
        }),
        isFalse,
      );
    });

    test('其它字段名（secret/token/password）不触发兜底', () {
      expect(
        detectBackupContainsSecrets({
          'presets': [
            {'secret': 'x', 'token': 'y', 'password': 'z'},
          ],
        }),
        isFalse,
      );
    });

    test('presets 非 List（手裁损坏文件）不崩且返回 false', () {
      expect(
        detectBackupContainsSecrets({
          'presets': {'api_key': 'sk-map'},
        }),
        isFalse,
        reason: 'presets 为 Map 时不扫描（现行为口径：只扫 List）',
      );
    });

    test('preset 条目非 Map 时跳过该条目', () {
      expect(
        detectBackupContainsSecrets({
          'presets': <dynamic>['sk-string', null, 42],
        }),
        isFalse,
      );
    });

    test('无 presets 键的正常备份返回 false', () {
      expect(
        detectBackupContainsSecrets({
          'version': 3,
          'sessions': <dynamic>[],
          'characterCards': <dynamic>[],
        }),
        isFalse,
      );
    });

    test('previewMap 为 null（非法 JSON / v1 列表顶层）返回 false', () {
      expect(detectBackupContainsSecrets(null), isFalse);
    });

    // ---------- 漏报边界 ----------
    test('手裁掉 contains_secrets 但保留 api_key 的文件仍被兜底识别', () {
      expect(
        detectBackupContainsSecrets({
          'version': 3,
          // 手工删除了 contains_secrets 标记
          'presets': [
            {'name': '供应商', 'api_key': 'sk-kept'},
          ],
        }),
        isTrue,
        reason: '兜底扫描存在的意义：标记可被裁掉，Key 字段不会说谎',
      );
    });
  });
}
