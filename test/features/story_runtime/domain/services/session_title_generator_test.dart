import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';

void main() {
  group('SessionTitleGenerator.fallbackTitle', () {
    test('普通消息截取前 20 字符并清理换行', () {
      final title = SessionTitleGenerator.fallbackTitle(
        '第一行内容\n第二行内容超出二十个字符部分省略',
        defaultTitle: '新建会话',
      );
      expect(title, '第一行内容 第二行内容超出二十个字符部分');
      expect(title.length, 20);
    });

    test('空消息或纯空白回退到 defaultTitle', () {
      expect(
        SessionTitleGenerator.fallbackTitle(
          '',
          defaultTitle: '新建会话',
        ),
        '新建会话',
      );
      expect(
        SessionTitleGenerator.fallbackTitle(
          '   \n\t  ',
          defaultTitle: 'New Session',
        ),
        'New Session',
      );
    });
  });
}
