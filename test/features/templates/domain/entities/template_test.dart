import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';

/// TemplateKind 收敛测试
///
/// `suggestReply` 移除——全仓零运行时消费。
///
/// `consolidation`（折叠模板）移除——编辑
/// 不生效（真压缩提示词在故事模式分段自定义，`*.prompts.*` 配置段）。
/// 存量行回退策略 = **保留行但过滤**（[TemplateKind.tryFromDbValue] 返回
/// null，仓库映射层跳过）：死内容不得变活——区别于  先例的
/// suggestReply → systemPrompt 回退（那会把死内容变成"活的系统提示词
/// 模板"）。
void main() {
  group('TemplateKind（A1 折叠模板下架）', () {
    test('枚举仅保留有运行时归宿的类型', () {
      expect(TemplateKind.values, hasLength(1));
      expect(TemplateKind.values, containsAll([TemplateKind.systemPrompt]));
    });

    test('数据库旧值 consolidation → null（保留行但过滤，不回退活类型）', () {
      expect(TemplateKind.tryFromDbValue('consolidation'), isNull);
    });

    test('数据库旧值 toolUpdateWorld → null（同口径）', () {
      expect(TemplateKind.tryFromDbValue('toolUpdateWorld'), isNull);
    });

    test('数据库旧值 suggestReply（旧值）→ null（同口径收紧）', () {
      expect(TemplateKind.tryFromDbValue('suggestReply'), isNull);
    });

    test('未知值 → null（死内容不得变活）', () {
      expect(TemplateKind.tryFromDbValue('nonexistent'), isNull);
    });

    test('存活类型 roundtrip 不变', () {
      for (final kind in TemplateKind.values) {
        expect(TemplateKind.tryFromDbValue(kind.toDbValue()), kind);
      }
    });
  });
}
