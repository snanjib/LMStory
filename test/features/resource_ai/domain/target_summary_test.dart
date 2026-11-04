import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_ai/domain/services/target_summary.dart';

void main() {
  group('编辑目标摘要（注入提示词的模型输入，格式冻结）', () {
    test('角色卡：名字 + 来源格式', () {
      expect(
        cardTargetSummary('阿尔', 'png'),
        '目标卡「阿尔」（格式 png）',
      );
    });

    test('角色卡：sourceFormat 缺省按 json 展示', () {
      expect(
        cardTargetSummary('阿尔', null),
        '目标卡「阿尔」（格式 json）',
      );
    });

    test('世界书：仅名字', () {
      expect(bookTargetSummary('剑与世界'), '目标书「剑与世界」');
    });
  });
}
