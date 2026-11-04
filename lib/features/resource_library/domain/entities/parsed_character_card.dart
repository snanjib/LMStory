import 'package:lmstory/features/resource_library/domain/entities/normalized_world_entry.dart';
import 'package:meta/meta.dart';

/// 解析后的角色卡（DOC-15 §5.1 / §6.1）
///
/// 从 SillyTavern 角色卡 JSON（V1 扁平 / V2 / V3 混合结构）中抽取 A 类字段
/// （name/description/personality）与内嵌世界书词条。B/C 类字段丢弃（详情展示
/// 从资源表原始 rawJson 解析）。
@immutable
class ParsedCharacterCard {
  const ParsedCharacterCard({
    required this.name,
    required this.description,
    required this.personality,
    required this.specVersion,
    required this.embeddedEntries,
    this.scenario = '',
    this.firstMes = '',
    this.alternateGreetings = const [],
    this.mesExample = '',
    this.tags = const [],
    this.creatorNotes = '',
    this.systemPrompt = '',
    this.creator = '',
    this.nickname = '',
    this.age = '',
    this.extraFields = const [],
  });

  /// 角色名 → 实体 primaryName
  final String name;

  /// 角色描述 → 属性 background（single 基线）
  final String description;

  /// 性格 → 属性 personality（single 基线）
  final String personality;

  /// 卡规范版本：`v1` / `v2` / `v3`
  final String specVersion;

  /// 内嵌世界书词条（character_book）→ `lore` 只读实体
  final List<NormalizedWorldEntry> embeddedEntries;

  // ── 富字段（内容查看器消费；导入链不读取，缺省空值零影响）──

  /// 场景（V2 scenario）
  final String scenario;

  /// 开场白（V2 first_mes）
  final String firstMes;

  /// 替代开场白（V2 alternate_greetings）
  final List<String> alternateGreetings;

  /// 对话示例（V2 mes_example）
  final String mesExample;

  /// 标签（V2 tags）
  final List<String> tags;

  /// 作者注（V2 creator_notes）
  final String creatorNotes;

  /// 系统提示（V2 system_prompt）
  final String systemPrompt;

  /// 作者（V2 creator）
  final String creator;

  /// 昵称（V3 nickname，数组形态合并为一行）
  final String nickname;

  /// 年龄（V3 age，数字形态转字符串）
  final String age;

  /// 未消费的字符串/字符串列表字段（内容查看器「其他字段」折叠组；
  /// 复杂结构不入列——查看器不出原始 JSON）。
  final List<CardExtraField> extraFields;
}

/// 卡上未消费的简单字段（查看器「其他字段」组行：原始键名+消毒值）。
@immutable
class CardExtraField {
  const CardExtraField({required this.key, required this.value});

  final String key;
  final String value;
}
