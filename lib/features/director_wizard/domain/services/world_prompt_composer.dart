import 'package:flutter/foundation.dart';

/// 世界观问卷：叙事人称（null = 项目规则不写入人称或视角约定）。
enum WorldPerson { first, second, third }

/// 三题问卷答案（题材/文风/人称，各带自定义输入）。
///
/// 一期收敛三题；各字段 null/空 = 未选，
/// 未选不拼块（交给 AI 与组装器）。
@immutable
class WorldQuestionnaireAnswers {
  const WorldQuestionnaireAnswers({
    this.genreId,
    this.genreCustom = '',
    this.styleId,
    this.styleCustom = '',
    this.person,
  });

  ///  世界题材选项 id
  final String? genreId;

  ///  自定义原文（拼装路径原样附加；生成路径编织进正文）
  final String genreCustom;

  ///  文风笔触选项 id
  final String? styleId;

  ///  自定义原文
  final String styleCustom;

  ///  叙事人称（null = 留空）
  final WorldPerson? person;
}

/// 拼装文本源：身份句 + 各维度句子块 + 用户补充前缀。
///
/// 全部文案常量走 slang（zh/en 同步），由 UI 层从 Translations 装配
/// 注入——域层零 slang 依赖，中文白名单与 en parity 由 yaml 层保证。
@immutable
class WorldPromptTextSource {
  const WorldPromptTextSource({
    required this.identity,
    required this.genreBlocks,
    required this.styleBlocks,
    required this.personBlocks,
    required this.userSupplementPrefix,
  });

  /// 固定身份句（叙述者定位 + 不代用户说话/行动/做决定）
  final String identity;

  /// 题材 id → 拼装块
  final Map<String, String> genreBlocks;

  /// 文风 id → 拼装块
  final Map<String, String> styleBlocks;

  /// 人称 → 拼装块（留空无块）
  final Map<WorldPerson, String> personBlocks;

  /// 用户补充行前缀（「用户补充：」）
  final String userSupplementPrefix;
}

/// 世界观规则拼装引擎（本地、零调用）。
///
/// 骨架（问卷报告 §4.1 定稿）：身份句 → 题材块 → 文风块 → 人称块 →
/// 用户补充行；未选不拼；产物不含括号/引号等输入格式约定（§六-3）。
class WorldPromptComposer {
  const WorldPromptComposer._();

  /// 按答案拼装规则文本；未知选项 id 视为未选。
  static String compose(
    WorldQuestionnaireAnswers answers,
    WorldPromptTextSource texts,
  ) {
    final lines = <String>[texts.identity];

    final genre = _block(texts.genreBlocks, answers.genreId);
    if (genre != null) lines.add(genre);
    final style = _block(texts.styleBlocks, answers.styleId);
    if (style != null) lines.add(style);
    final person =
        answers.person == null ? null : texts.personBlocks[answers.person];
    if (person != null) lines.add(person);

    for (final custom in [answers.genreCustom, answers.styleCustom]) {
      final trimmed = custom.trim();
      if (trimmed.isNotEmpty) {
        lines.add('${texts.userSupplementPrefix}$trimmed');
      }
    }
    return lines.join('\n');
  }

  static String? _block(Map<String, String> blocks, String? id) {
    if (id == null || id.isEmpty) return null;
    return blocks[id];
  }
}
