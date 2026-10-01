import 'package:flutter/services.dart' show rootBundle;
import 'package:lmstory/core/agent/agent_skill_registry.dart';
import 'package:lmstory/core/utils/logger.dart';

/// 内置 skill 资产清单（assets/skills/<name>/SKILL.md）
const List<String> kBuiltinSkillAssets = [
  'skills/deai-flavor/SKILL.md',
  'skills/dialogue-scenes/SKILL.md',
  'skills/combat-scenes/SKILL.md',
  'skills/suspense-pacing/SKILL.md',
  'skills/tabletop-gm/SKILL.md',
  'skills/worldbook-style/SKILL.md',
];

/// 内置 skill 加载器（Data 层：rootBundle 读资产）
///
///  扩展为 rank 分层 provider（项目 .lmstory/skills > 用户目录 > 内置）。
class AssetSkillLoader {
  AssetSkillLoader({Logger? logger}) : _logger = logger;

  final Logger? _logger;

  /// 加载全部内置 skill（单条损坏跳过，不整体失败）
  Future<List<AgentSkill>> loadBuiltin() async {
    final skills = <AgentSkill>[];
    for (final path in kBuiltinSkillAssets) {
      try {
        final raw = await rootBundle.loadString('assets/$path');
        final skill = AgentSkillRegistry.parse(path, raw);
        if (skill != null) {
          skills.add(skill);
        } else {
          _logger?.warn('Skill frontmatter invalid', detail: path);
        }
      } catch (e) {
        _logger?.warn('Skill asset load failed', detail: '$path: $e');
      }
    }
    return skills;
  }

  /// 单独读取一个 skill 正文（read_skill 工具用；按名字匹配内置清单）
  Future<String?> loadBody(String name) async {
    for (final path in kBuiltinSkillAssets) {
      try {
        final raw = await rootBundle.loadString('assets/$path');
        final skill = AgentSkillRegistry.parse(path, raw);
        if (skill != null && skill.name == name) return skill.body;
      } on Exception catch (_) {
        continue;
      }
    }
    return null;
  }
}

/// 测试/非 Flutter 环境用的直接字符串加载器
class InMemorySkillLoader {
  InMemorySkillLoader(this.sources);

  final Map<String, String> sources;

  List<AgentSkill> load() {
    return sources.entries
        .map((e) => AgentSkillRegistry.parse(e.key, e.value))
        .whereType<AgentSkill>()
        .toList();
  }
}
