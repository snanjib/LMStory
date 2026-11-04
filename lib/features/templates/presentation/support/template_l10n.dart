import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模板名/正文的本地化显示（内置模板双语，v53 起）。
///
/// en 界面且模板带英文版时用英文名/正文，否则回退基础值（中文）。
/// 运行时消费（选模板写入会话的系统提示词快照）同口径——选中那一刻的
/// 界面语言决定快照语言，之后切语言不改已写入的快照（快照哲学）。
extension TemplateL10n on Template {
  String localizedName(Translations t) =>
      _isEn(t) && nameEn != null ? nameEn! : name;

  String localizedContent(Translations t) =>
      _isEn(t) && contentEn != null ? contentEn! : content;

  bool _isEn(Translations t) => t.$meta.locale == AppLocale.enUs;
}
