/// resource_ai 内置 skill 资产加载器（Data 层：rootBundle 读资产）。
///
/// advanced 侧 AssetSkillLoader 的同构实现（resource_ai 不可 import
/// advanced；AgentSkillRegistry 已随 agent 循环契约下沉 core/agent）。
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:lmstory/core/agent/agent_skill_registry.dart';

const List<String> kResourceAiSkillAssets = [
  'skills/card-crafting/SKILL.md',
  'skills/worldbook-crafting/SKILL.md',
  'skills/card-editing/SKILL.md',
];

class ResourceAiSkillLoader {
  const ResourceAiSkillLoader();

  /// 加载三个建卡规范 skill（单条损坏跳过，不整体失败）。
  Future<AgentSkillRegistry> loadRegistry() async {
    final skills = <AgentSkill>[];
    for (final path in kResourceAiSkillAssets) {
      try {
        final raw = await rootBundle.loadString('assets/$path');
        final skill = AgentSkillRegistry.parse(path, raw);
        if (skill != null) {
          skills.add(skill);
        }
      } on Exception {
        continue;
      }
    }
    return AgentSkillRegistry(skills);
  }

  /// 读取单个 skill 正文（read_skill 工具用）。
  Future<String?> loadBody(String name) async {
    for (final path in kResourceAiSkillAssets) {
      try {
        final raw = await rootBundle.loadString('assets/$path');
        final skill = AgentSkillRegistry.parse(path, raw);
        if (skill != null && skill.name == name) return skill.body;
      } on Exception {
        continue;
      }
    }
    return null;
  }
}
