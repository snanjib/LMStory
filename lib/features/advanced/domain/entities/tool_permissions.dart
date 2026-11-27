import 'dart:convert';

/// 工具三态权限（opencode 式，设计文档 §5.1）
///
/// - [allow]：直接执行（内置默认）
/// - [ask]：走 AgentToolPipeline 审批 seam → 横幅确认，超时 fail-closed
/// - [deny]：工具不注册（模型不可见，系统提示词工具索引同步移除）
enum ToolPermissionState { allow, ask, deny }

/// 18 工具的权限 map（键=工具名，值=三态字符串）与求值。
///
/// 求值链（设计文档 §5.2，逐工具后写优先）：
/// 内置默认 allow → 全局 advanced.tools → 会话 chat_sessions.tool_permissions。
/// 新工具注册时默认 allow，无需改配置。
class ToolPermissions {
  /// 全部 18 工具（分类固定，随 buildAgentTools 维护，设计文档 §5.3）
  static const allTools = [
    // 只读
    'search_story', 'search_story_text', 'read_story', 'list_facts',
    'query_facts',
    'query_memory_changes',
    'read_compact_summary',
    'read_skill',
    'calc_eval', 'calc_date',
    // 写入
    'update_facts', 'merge_entities', 'update_story_anchor',
    'record_event_memory',
    // 控制
    'spawn', 'ask_user', 'finish_round', 'finish_maintenance',
  ];

  /// 「监督模式」预设（= 旧 watchMode=true 的行为，dsh permission-presets 模式）：
  /// 写入+spawn → ask，只读与 ask_user/finish_round/finish_maintenance → allow。
  /// 为 18 工具完整 map（watchMode 迁移物化时整体写入，设计文档 §6.3）。
  static const Map<String, String> supervised = {
    // 只读 → allow
    'search_story': 'allow',
    'search_story_text': 'allow',
    'read_story': 'allow',
    'list_facts': 'allow',
    'query_facts': 'allow',
    'query_memory_changes': 'allow',
    'read_compact_summary': 'allow',
    'read_skill': 'allow',
    'calc_eval': 'allow',
    'calc_date': 'allow',
    // 写入 → ask
    'update_facts': 'ask',
    'merge_entities': 'ask',
    'update_story_anchor': 'ask',
    'record_event_memory': 'ask',
    // 控制：spawn → ask；ask_user/finish_round/finish_maintenance → allow
    'spawn': 'ask',
    'ask_user': 'allow',
    'finish_round': 'allow',
    'finish_maintenance': 'allow',
  };

  /// 求值：会话未设置（NULL）= 监督关；已设置时快照全量生效、
  /// 未提名工具回落全局。
  ///
  /// - 会话 NULL：全工具按内置默认 allow 运行（不继承全局监督约束——
  ///   运行时无 ask/deny，不弹审批横幅；与设置面板「未设置=关」的
  ///   读侧口径对齐）。
  /// - 会话非 NULL（含全 allow 快照）：逐工具 后写优先，
  ///   快照未提名的工具回落全局。
  ///
  /// `finish_round`（提交本轮）与 `finish_maintenance`（结束周期维护）锁死 allow——
  /// 它们是每轮正文与收尾唯一交付通道，历史会话/全局配置里存的 deny/ask 值一律
  /// 按 allow 兜底（消灭"能配但配了崩"）。
  static ToolPermissionState effective({
    required Map<String, String>? session,
    required Map<String, String> global,
    required String toolName,
  }) {
    if (isLockedAllow(toolName)) {
      return ToolPermissionState.allow;
    }
    if (session == null) return ToolPermissionState.allow;
    final s = session[toolName];
    if (s != null) return _parse(s);
    final g = global[toolName];
    if (g != null) return _parse(g);
    return ToolPermissionState.allow;
  }

  /// 锁死 allow 的工具集合
  static const Set<String> lockedAllowTools = {
    'finish_round',
    'finish_maintenance',
  };

  /// 锁死 allow 的主工具名（向后兼容常量）
  static const String lockedAllowTool = 'finish_round';

  /// 判断工具是否锁死为 allow
  static bool isLockedAllow(String toolName) =>
      lockedAllowTools.contains(toolName);

  /// 旧 watchMode 列 → 会话权限 map（schema 44 迁移用；
  /// false/null = NULL 跟随全局）
  static Map<String, String>? forLegacyWatchMode({bool? watchMode}) =>
      watchMode ?? false ? supervised : null;

  /// 解析 tool_permissions 列的 JSON（null/空串/损坏/非法值 → null 跟随全局）
  /// 监督开关读侧判据——快照宪法下拨「关」写的是
  /// 全 allow 快照（写侧不动），「关」只能靠「无任何 ask/deny 约束」表达：
  /// null 与全 allow 同为关，含 ask/deny（预设或自定义）为开。
  static bool hasActiveConstraints(Map<String, String>? sessionMap) =>
      sessionMap != null && sessionMap.values.any((v) => v != 'allow');

  static Map<String, String>? fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final result = <String, String>{};
    for (final entry in decoded.entries) {
      if (!_isValid(entry.value)) return null;
      result[entry.key] = entry.value as String;
    }
    return result;
  }

  static String? toJson(Map<String, String>? map) =>
      map == null ? null : jsonEncode(map);

  static ToolPermissionState _parse(String v) => switch (v) {
        'allow' => ToolPermissionState.allow,
        'ask' => ToolPermissionState.ask,
        _ => ToolPermissionState.deny,
      };

  static bool _isValid(Object? v) => v == 'allow' || v == 'ask' || v == 'deny';
}
