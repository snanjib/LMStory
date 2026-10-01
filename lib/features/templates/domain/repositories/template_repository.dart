import 'package:lmstory/features/templates/domain/entities/template.dart';

/// 模板管理仓库接口
abstract class TemplateRepository {
  /// 获取全部模板
  Future<List<Template>> getAllTemplates();

  /// 按类型获取模板
  Future<List<Template>> getTemplatesByKind(TemplateKind kind);

  /// 获取单个模板
  Future<Template> getTemplate(String templateId);

  /// 创建自定义模板
  Future<Template> createTemplate({
    required String name,
    required TemplateKind kind,
    required String content,
  });

  /// 更新模板（内置模板不可修改）
  Future<Template> updateTemplate(
    String templateId,
    Template Function(Template current) updater,
  );

  /// 删除模板（内置模板不可删除）
  Future<void> deleteTemplate(String templateId);

  /// 复制模板
  Future<Template> copyTemplate(String templateId, {String? newName});

  /// 初始化内置模板（应用启动时调用）
  Future<void> ensureBuiltInTemplates();
}
