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
}
