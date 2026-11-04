import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';

///  SKILL.md 提到的工具名必须 ⊆ 在役工具集
///
/// 差距剖析 ：skill 正文曾引用不存在的工具（update_outline /
/// add_alias 当工具用 / 掷骰工具），触发后给出失效指导。本测试提取全部
/// snake_case 词元，剔除非工具白名单（update_facts 的 delta 动作名与
/// 字段名），其余必须是在役工具——skill 文案漂移在 CI 即暴露。
void main() {
  // 非工具 snake_case 词元白名单：
  // - update_facts 的六种 delta 动作（create_entity / add_alias 等）
  // - 资源库字段名（force_inject）
  const nonToolWhitelist = {
    'create_entity',
    'update_attr',
    'append_list',
    'remove_from_list',
    'add_alias',
    'archive_entity',
    'force_inject',
  };

  /// resource_ai 的三个建卡 skill 属另一工具域（update_draft/finalize_
  /// draft/read_skill 是 resource_ai 会话工具，不在导演 ToolPermissions），
  /// 不按导演工具集校验——其目录与工具名由 resource_ai 侧测试锁定
  /// （resource_ai_prompts_test 的 skill 目录断言）。
  const resourceAiSkills = {
    'card-crafting',
    'worldbook-crafting',
    'card-editing',
  };

  final skillFiles = Directory('assets/skills')
      .listSync()
      .whereType<Directory>()
      .where(
        (d) => !resourceAiSkills.contains(d.path.split(RegExp(r'[/\\]')).last),
      )
      .map((d) => File('${d.path}/SKILL.md'))
      .where((f) => f.existsSync())
      .toList();

  test('内置 skill 资产存在', () {
    expect(skillFiles, isNotEmpty);
  });

  for (final file in skillFiles) {
    test('${file.parent.path} 工具引用 ⊆ 在役工具集', () {
      final content = file.readAsStringSync();
      final tokens =
          RegExp('[a-z][a-z0-9]*(?:_[a-z0-9]+)+').allMatches(content);
      final unknown = tokens
          .map((m) => m.group(0)!)
          .where(
            (token) =>
                !nonToolWhitelist.contains(token) &&
                !ToolPermissions.allTools.contains(token),
          )
          .toSet();
      expect(
        unknown,
        isEmpty,
        reason: '${file.path} 引用了不在役或不存在的标识符（工具名请对照 '
            'ToolPermissions.allTools；delta 动作名请加进 nonToolWhitelist）',
      );
    });
  }
}
