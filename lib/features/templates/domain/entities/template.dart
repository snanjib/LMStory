/// 模板类型枚举
///
/// 类型收敛记录：
/// - CF-7：`suggestReply` 移除——全仓零运行时消费
///   （推荐回复提示词实际走 `*.suggest_reply.prompt` 配置段），创建下拉
///   也从未提供该选项。
/// - ：`consolidation`（折叠模板）移除——
///   编辑不生效（真压缩提示词在故事模式分段自定义，`*.prompts.*` 配置段）。
/// -  #28：`toolUpdateWorld` 全下架——对应的
///   Advanced/HUD 执行链已不存在（半下架状态清零），存量行按同口径
///   保留在库中但不映射。
///
/// 存量行回退策略 = **保留行但过滤**：[tryFromDbValue] 对已移除/未知值
/// 返回 null，仓库映射层跳过该行——数据行留在库中（数据保全），但任何
/// 列表/编辑入口都不可见。决策依据"死内容不得变活"：CF-7 先例的
/// suggestReply → systemPrompt 回退会把死内容变成"活的系统提示词模板"，
/// 本次按更安全口径执行（CF-7 旧值同口径收紧，见 template_test）。
enum TemplateKind {
  systemPrompt;

  /// 从数据库存储的字符串值解析。
  ///
  /// 返回 null = 已移除类型（'toolUpdateWorld' / 'consolidation' /
  /// 'suggestReply'， #28 全下架）或未知值：
  /// 行保留在库中但被仓库过滤，不映射为任何存活类型的模板。
  static TemplateKind? tryFromDbValue(String value) => switch (value) {
        'systemPrompt' => TemplateKind.systemPrompt,
        _ => null,
      };

  /// 转换为数据库存储的字符串值
  String toDbValue() => name;
}

/// 模板实体
class Template {
  const Template({
    required this.templateId,
    required this.name,
    required this.kind,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.isBuiltIn = false,
    this.nameEn,
    this.contentEn,
  });

  final String templateId;
  final String name;
  final TemplateKind kind;
  final String content;
  final bool isBuiltIn;

  /// 英文名（内置模板双语；NULL = 无英文版，回退 [name]）。
  /// 显示与运行时消费的本地化口径见 presentation/support/template_l10n.dart。
  final String? nameEn;

  /// 英文正文（内置模板双语；NULL = 无英文版，回退 [content]）。
  final String? contentEn;
  final DateTime createdAt;
  final DateTime updatedAt;

  Template copyWith({
    String? name,
    TemplateKind? kind,
    String? content,
    bool? isBuiltIn,
    String? nameEn,
    String? contentEn,
    DateTime? updatedAt,
  }) =>
      Template(
        templateId: templateId,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        content: content ?? this.content,
        isBuiltIn: isBuiltIn ?? this.isBuiltIn,
        nameEn: nameEn ?? this.nameEn,
        contentEn: contentEn ?? this.contentEn,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
