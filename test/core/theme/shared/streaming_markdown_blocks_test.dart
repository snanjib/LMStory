import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/streaming_markdown_blocks.dart';

/// 流式 Markdown 块切分器单测（冻结前缀渲染的基础）
void main() {
  /// 便捷：返回各块的文本切片
  List<String> blocksOf(String text) {
    final starts = markdownBlockStarts(text);
    return [
      for (var i = 0; i < starts.length; i++)
        text.substring(
          starts[i],
          i + 1 < starts.length ? starts[i + 1] : text.length,
        ),
    ];
  }

  group('基础切分', () {
    test('空文本无块', () {
      expect(markdownBlockStarts(''), isEmpty);
    });

    test('单段 = 单块', () {
      expect(markdownBlockStarts('只有一段。'), [0]);
      expect(
        markdownBlockStarts('第一行\n第二行\n第三行'),
        [0],
        reason: '段内换行（无空行）是一个块',
      );
    });

    test('空行分段', () {
      final blocks = blocksOf('第一段。\n\n第二段。');
      expect(blocks, ['第一段。\n\n', '第二段。']);
    });

    test('多个空行也算一次边界', () {
      final blocks = blocksOf('第一段。\n\n\n\n第二段。');
      expect(blocks, ['第一段。\n\n\n\n', '第二段。']);
    });

    test('首个块起点恒为 0', () {
      final starts = markdownBlockStarts('\n\n正文');
      expect(starts.first, 0);
      // 开头空行归属首块
      expect(starts, [0, '\n\n正文'.indexOf('正文')]);
    });
  });

  group('围栏与数学块（内部空行不切）', () {
    test('未闭合代码围栏：内部空行不切', () {
      const text = '```dart\nfinal a = 1;\n\nfinal b = 2;\n';
      expect(markdownBlockStarts(text), [0], reason: '围栏未闭合时全部内容是一个块');
    });

    test('已闭合代码围栏后新段切块', () {
      const text = '```\ncode\n```\n\n新段落。';
      final blocks = blocksOf(text);
      expect(blocks, ['```\ncode\n```\n\n', '新段落。']);
    });

    test('围栏内出现 ``` 缩进变体不误闭合（≤3 空格前导算围栏标记）', () {
      const text = '```\ncode\n\n  ```\nmore\n```';
      // 第二个 ```（2 空格前导）合法闭合围栏 → 之后是同块
      expect(markdownBlockStarts(text), [0]);
    });

    test(r'$$ 数学块内部空行不切', () {
      const text = '\$\$\nx = 1\n\ny = 2\n\$\$\n\n正文';
      final blocks = blocksOf(text);
      expect(blocks.length, 2);
      expect(blocks[1], '正文');
    });
  });

  group('嵌套列表中的 fence', () {
    test('列表条目内嵌未闭合 fence：期间空行不切（整块活跃）', () {
      const text = '- 条目：示例代码\n  ```\n  code\n\n  still code\n';
      expect(
        markdownBlockStarts(text),
        [0],
        reason: 'fence 未闭合期间（即使在列表条目内）空行一律不切，整块留在不稳定窗口',
      );
    });

    test('列表条目内 fence 闭合后：空行后的非延续行恢复切块', () {
      const text = '- 条目：示例代码\n  ```\n  code\n  ```\n\n新段落。';
      expect(
        markdownBlockStarts(text),
        [0, text.indexOf('新段落')],
        reason: 'fence 合法闭合后围栏守卫退出，空行后的新段正常切块',
      );
    });

    test('列表条目内 fence 闭合后围栏内部空行仍未切', () {
      const text = '- 条目：示例\n  ```\n  a\n\n  b\n  ```\n\n新段落。';
      final starts = markdownBlockStarts(text);
      expect(starts, [0, text.indexOf('新段落')]);
      // 围栏内的空行（a 与 b 之间）不产生任何额外起点
      expect(starts.where((s) => s > 0 && s < text.indexOf('新段落')), isEmpty);
    });
  });

  group('围栏闭合语义（CommonMark 收敛：宁可不闭合，不可误切）', () {
    // 2026-09-10  审计发现的真实缺陷：闭合判定原为
    // startsWith('```') || startsWith('~~~')——混合标记、更短围栏、带
    // info 字符串的行都会「误闭合」，随后围栏内部的空行被当成块边界，
    // 把一个代码块切碎（两个碎片各自独立解析 → 错误渲染）。CommonMark
    // 规定：闭合围栏必须与开栏同字符、长度 ≥ 开栏、且标记后只能剩空白。
    test('混合标记：~~~ 围栏内的 ``` 行不闭合', () {
      const text = '~~~\n```x\n\nfoo\n~~~\n\nafter';
      expect(
        markdownBlockStarts(text),
        [0, text.indexOf('after')],
        reason: '误闭合会让 "foo" 变成块边界，把 ~~~ 围栏切碎',
      );
    });

    test('短围栏不闭合长围栏（```` 开栏，``` 行是内容）', () {
      const text = '````\n```\n\ninner\n````\n\nafter';
      expect(markdownBlockStarts(text), [0, text.indexOf('after')]);
    });

    test('闭合围栏不得带 info 字符串（``` js 不闭合）', () {
      const text = '```\ncode\n``` js\n\nmore\n```\n\nafter';
      expect(
        markdownBlockStarts(text),
        [0, text.indexOf('after')],
        reason: 'CommonMark 闭合栏后只允许空白；误闭合 + 重开栏会让 '
            '"more" 被切、末段永远留在围栏内',
      );
    });

    test('闭合围栏允许尾随空格', () {
      const text = '```\ncode\n```   \n\nafter';
      expect(markdownBlockStarts(text), [0, text.indexOf('after')]);
    });
  });

  group('延续不切（CommonMark 同块语义）', () {
    test('列表条目间空行（松散列表）不切', () {
      const text = '- 第一项\n\n- 第二项\n\n- 第三项';
      expect(
        markdownBlockStarts(text),
        [0],
        reason: '松散列表是一个块，切成三个块会改变渲染（编号/间距）',
      );
    });

    test('有序列表跨空行不切', () {
      const text = '1. 一\n\n2. 二';
      expect(markdownBlockStarts(text), [0]);
    });

    test('引用块跨空行不切', () {
      const text = '> 第一行\n\n> 第二行';
      expect(markdownBlockStarts(text), [0]);
    });

    test('列表条目的缩进续行不切', () {
      const text = '1. 条目\n\n    续行内容\n\n新段落';
      final blocks = blocksOf(text);
      expect(blocks.length, 2);
      expect(blocks[1], '新段落');
    });

    test('段落后的列表是新块（类型切换要切）', () {
      const text = '这是一段说明。\n\n- 列表项';
      expect(markdownBlockStarts(text), [0, text.indexOf('- 列表项')]);
    });

    test('列表后的段落是新块', () {
      const text = '- 列表项\n\n这是新段落。';
      expect(markdownBlockStarts(text), [0, text.indexOf('这是新段落')]);
    });
  });

  group('混合结构回归', () {
    test('标题/段落/列表/围栏交错只切合法边界', () {
      const text = '## 标题\n'
          '\n'
          '段落一。\n'
          '\n'
          '- 项 A\n'
          '- 项 B\n'
          '\n'
          '```dart\n'
          'final x = 1;\n'
          '\n'
          'final y = 2;\n'
          '```\n'
          '\n'
          '收尾段。';
      final blocks = blocksOf(text);
      expect(blocks.length, 5, reason: '标题/段落/列表/围栏/收尾段');
      expect(blocks[2].startsWith('- 项 A'), isTrue);
      expect(blocks[3].contains('```'), isTrue);
      expect(blocks[4], '收尾段。');
    });

    test('缩进代码块跟段落（非列表/引用前块）要切', () {
      const text = '段落。\n\n    缩进代码';
      expect(markdownBlockStarts(text), [0, text.indexOf('    缩进代码')]);
    });
  });

  group('looksLikePlainText（T8 纯文本快速路径判定）', () {
    test('空串与纯中文散文判纯', () {
      expect(looksLikePlainText(''), isTrue);
      expect(looksLikePlainText('夜色沉下去的时候，走廊尽头的灯还亮着。'), isTrue);
    });

    test('中英混排与段内换行判纯', () {
      expect(
        looksLikePlainText('夜色 fell 沉下去，the light stayed on.'),
        isTrue,
        reason: '中英混排正文是叙事输出的常态',
      );
      expect(
        looksLikePlainText('第一行\n第二行\n第三行'),
        isTrue,
        reason: '无空行的段内换行仍是一个块，Text 渲染换行与正文一致',
      );
    });

    test('中文标点（全角！）不是特征字符', () {
      expect(
        looksLikePlainText('太好了！真的吗？'),
        isTrue,
        reason: '全角 ！？。不是 Markdown 特征字符',
      );
    });

    test('行中数字与小数点不是列表标记', () {
      expect(
        looksLikePlainText('圆周率约 3.14159，共 23 条线索。'),
        isTrue,
        reason: '数字不在行首不构成有序列表',
      );
    });

    test('每个行内特征字符都判非纯（宁漏勿误）', () {
      const cases = <String, String>{
        '`code`': '行内代码',
        '*em*': '强调',
        '_em_': '下划线强调',
        '~~删~~': '删除线',
        '# 标题': 'ATX 标题',
        '> 引用': '引用',
        '| a | b |': '表格',
        '[链接](x)': '链接',
        '![图片]': '图片',
        '<div>': 'HTML/自动链接',
        '&amp;': 'HTML 实体',
        r'\*转义': '反斜杠转义',
        r'价格是 $5': 'LaTeX 公式字符（chat 模式启用 LatexInlineSyntax）',
        'a\r\nb': 'CR（保守视作特征字符）',
      };
      for (final e in cases.entries) {
        expect(looksLikePlainText(e.key), isFalse, reason: e.value);
      }
    });

    test('行首列表/分隔线/setext 标记判非纯', () {
      const cases = <String, String>{
        '- 项': '无序列表',
        '+ 项': '无序列表（+）',
        '* 项': '无序列表（*，行首）',
        '1. 项': '有序列表',
        '1) 项': '有序列表（括号）',
        '23. 项': '多位有序列表',
        '1.项': '无空格有序列表（保守：不放行）',
        '---': '分隔线',
        '===': 'setext 下划线',
        '   - 缩进列表': '≤3 前导空格的列表',
        '    缩进代码': '4 空格缩进代码块',
        '\t缩进代码': 'Tab 缩进代码块',
      };
      for (final e in cases.entries) {
        expect(looksLikePlainText(e.key), isFalse, reason: e.value);
      }
    });

    test('标记只在第二行出现也判非纯（逐行检查）', () {
      expect(looksLikePlainText('普通段落。\n- 但下一行是列表'), isFalse);
      expect(looksLikePlainText('普通段落。\n1. 下一行有序列表'), isFalse);
    });
  });
}
