import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// features 层结构实现 import 守卫。
///
/// 不变量：`lib/features/**` 不得 import 结构实现组件路径——
/// - `core/theme/system/structures/**`（结构实现树）
/// - `core/theme/simple/components/**`（垫片目录已退役，禁令防复活）
/// - `core/theme/intermediate/components/**`（垫片目录已退役，禁令防复活）
///
/// 消费面一律走 `LmComponentKit` / `context.lmUi` 结构中立接口；
/// 中立 API（lm_tokens / LmLayout / LmMotion / core/theme/shared 等）不在
/// 禁止前缀内，天然放行。
///
/// 白名单是**尚未等价收编的个案**（domain 实参/胖参数面，强行 kit 化会把
/// features·domain 类型拉进接口层）：条目只减不增，新增即失败；归零的组件
/// 族须同步删除条目与原因注释。
void main() {
  const forbiddenPrefixes = <String>[
    'package:lmstory/core/theme/system/structures/',
    'package:lmstory/core/theme/simple/components/',
    'package:lmstory/core/theme/intermediate/components/',
  ];

  /// 个案白名单：文件 → 允许的结构实现 import（带原因）。
  const whitelist = <String, Map<String, String>>{
    'lib/features/chat/presentation/pages/chat/chat_mode_page.dart': {
      'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_bubble.dart':
          'ChatMessage/DisplayPreferences domain 实参+约 20 参数；子树依赖 '
              'markdown 渲染件，kit 化前须先证皮肤等价',
    },
    'lib/features/chat/presentation/pages/chat/widgets/chat_generating_placeholder.dart':
        {
      'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_bubble.dart':
          '同上（chat 气泡组合体）',
    },
    'lib/features/intermediate/presentation/widgets/panels/retrieval_panel.dart':
        {
      'package:lmstory/core/theme/system/structures/classic/narrative/factual_detail_dialog.dart':
          'FactualEntity 等 domain 实参',
      'package:lmstory/core/theme/system/structures/classic/narrative/memory_detail_dialog.dart':
          'EventSummary/ExperientialMemory domain 实参',
    },
    'lib/features/intermediate/presentation/widgets/panels/facts_change_panel.dart':
        {
      'package:lmstory/core/theme/system/structures/classic/narrative/facts_change_detail_dialog.dart':
          'domain 实参（事实变更明细）',
    },
    'lib/features/intermediate/presentation/widgets/panels/summarize_panel.dart':
        {
      'package:lmstory/core/theme/system/structures/classic/narrative/memory_detail_dialog.dart':
          'EventSummary/ExperientialMemory domain 实参',
    },
    'lib/features/story_runtime/presentation/pages/memory_browser_page.dart': {
      'package:lmstory/core/theme/system/structures/classic/narrative/experience_memory_tab.dart':
          'ExperientialMemory 实参+Riverpod Consumer',
      'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory_tab.dart':
          'mergeService 域服务实参',
    },
  };

  test('features 层零结构实现 import（个案白名单除外，且白名单只减不增）', () {
    final offenders = <String>[];
    var whitelisted = 0;

    for (final entity in Directory('lib/features').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      final allowed = whitelist[rel] ?? const <String, String>{};
      final src = entity.readAsStringSync();

      for (final line in src.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
          continue;
        }
        for (final prefix in forbiddenPrefixes) {
          final idx = trimmed.indexOf(prefix);
          if (idx < 0) continue;
          final end = trimmed.indexOf("'", idx + prefix.length);
          final uri = trimmed.substring(idx, end < 0 ? trimmed.length : end);
          final reason = allowed[uri];
          if (reason != null) {
            whitelisted++;
            continue;
          }
          offenders.add('$rel → $uri'
              '${allowed.isNotEmpty ? '（该文件白名单内条目：${allowed.keys.join(", ")}）' : ''}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'features 层出现白名单外的结构实现 import（应改走 '
          'context.lmUi 结构中立接口，或登记新个案白名单）：\n'
          '${offenders.join('\n')}',
    );

    // 白名单钉死：每条登记都必须仍在消费，防止白名单本身腐烂。
    final whitelistedTotal =
        whitelist.values.map((m) => m.length).fold<int>(0, (a, b) => a + b);
    expect(
      whitelisted,
      whitelistedTotal,
      reason: '白名单登记 $whitelistedTotal 条但实际命中 $whitelisted 条 —— '
          '有条目已不再消费（收编完成或文件移动），须同步删条目。',
    );
  });
}
