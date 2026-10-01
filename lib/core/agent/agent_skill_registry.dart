import 'dart:convert';

/// Agent Skill（SKILL.md 渐进披露，设计报告 §7.7）
///
/// - frontmatter（name + description）常驻目录摘要，<100 token/skill
/// - 正文按需由 read_skill 工具读入
///
/// 体验重构 （三层防线）新增常驻层：`alwaysInject: true` 的 skill，
/// 其 `<!--resident-->…<!--/resident-->` 标记的精编正文（≤500 token）
/// 并入冻结 system 前缀——每轮命中 prompt cache、永不被压缩稀释，
/// 等价于 Claude Code "CLAUDE.md 压缩后重注入"。
class AgentSkill {
  const AgentSkill({
    required this.name,
    required this.description,
    required this.body,
    this.alwaysInject = false,
    this.residentBody = '',
  });

  final String name;
  final String description;
  final String body;

  /// 写作必读类标记（frontmatter `alwaysInject: true`）
  final bool alwaysInject;

  /// 常驻精编版正文（`<!--resident-->` 标记段；空 = 无常驻层）
  final String residentBody;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'body': body,
        'alwaysInject': alwaysInject,
        'residentBody': residentBody,
      };
}

/// Skill 注册表（解析 SKILL.md + 目录构建）
class AgentSkillRegistry {
  const AgentSkillRegistry(this.skills);

  /// rank 分层预留（：项目 > 用户 > 内置）； 仅内置
  final List<AgentSkill> skills;

  /// 目录摘要正文（注入冻结前缀的技能目录层）
  ///
  /// read_skill 未注册（deny/不支持）时不拼指引尾句——目录仍列
  /// （供模型知晓技能存在），但不再指向一个不可用的动作。
  String buildCatalogText({bool readSkillAvailable = true}) {
    if (skills.isEmpty) return '';
    final buffer = StringBuffer('【可用技能（写相关内容前先读对应技能）】');
    for (final skill in skills) {
      buffer.write('\n- ${skill.name}：${skill.description}');
    }
    if (readSkillAvailable) {
      buffer.write('\n用 read_skill 工具读取技能全文（每次最多读 1 个）。');
    }
    return buffer.toString();
  }

  AgentSkill? find(String name) {
    for (final skill in skills) {
      if (skill.name == name) return skill;
    }
    return null;
  }

  /// 解析 SKILL.md 文本（frontmatter + 正文）
  ///
  /// frontmatter 格式：
  /// ```yaml
  /// ---
  /// name: xxx
  /// description: yyy
  /// alwaysInject: true
  /// ---
  /// 正文…（`<!--resident-->…<!--/resident-->` 标记常驻精编段）
  /// ```
  static AgentSkill? parse(String fileName, String raw) {
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('---')) return null;
    final end = trimmed.indexOf('---', 3);
    if (end == -1) return null;

    final frontmatter = trimmed.substring(3, end).trim();
    final body = trimmed.substring(end + 3).trim();

    String? name;
    String? description;
    var alwaysInject = false;
    for (final line in frontmatter.split('\n')) {
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      if (key == 'name') name = value;
      if (key == 'description') description = value;
      if (key == 'alwaysInject') {
        alwaysInject = value.toLowerCase() == 'true';
      }
    }
    if (name == null || name.isEmpty) return null;
    return AgentSkill(
      name: name,
      description: description ?? '',
      body: body,
      alwaysInject: alwaysInject,
      residentBody: _extractResident(body),
    );
  }

  /// 提取 `<!--resident-->…<!--/resident-->` 标记的常驻精编段（无标记返回空）
  static String _extractResident(String body) {
    const open = '<!--resident-->';
    const close = '<!--/resident-->';
    final start = body.indexOf(open);
    if (start == -1) return '';
    final end = body.indexOf(close, start + open.length);
    if (end == -1) return '';
    return body.substring(start + open.length, end).trim();
  }
}

/// SKILL.md 目录 JSON 编码（清单落盘/事件 data 用）
String encodeAgentSkills(List<AgentSkill> skills) =>
    jsonEncode(skills.map((s) => s.toJson()).toList());

/// SKILL.md 目录 JSON 解码（容错）
List<AgentSkill> decodeAgentSkills(String raw) {
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(
          (m) => AgentSkill(
            name: m['name'] as String? ?? '',
            description: m['description'] as String? ?? '',
            body: m['body'] as String? ?? '',
            alwaysInject: m['alwaysInject'] as bool? ?? false,
            residentBody: m['residentBody'] as String? ?? '',
          ),
        )
        .toList();
  } catch (_) {
    return const [];
  }
}
