import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/streaming_markdown_blocks.dart'
    show
        MarkdownBlockStartsTracker,
        StreamingPlainTextGate,
        looksLikePlainText,
        markdownBlockStarts;

///  批2 增量化守卫：增量路径与纯函数在任意前缀链上逐位恒等。
///
/// 纯函数 [markdownBlockStarts]/[looksLikePlainText] 是行为真源（各自
/// 的独立单测仍在 streaming_markdown_blocks_test.dart）；这里证明增量
/// 替换后语义零变化——含停点行重复处理的幂等性（追加块切在行中间）、
/// 围栏/数学块跨块追加、失败行 O(1) 短路与出范围重续。
void main() {
  /// 覆盖全部切块规则形态的文档行（fence 开闭/混合标记/更短围栏/info
  /// 字符串、数学块、松散列表与缩进续行、引用延续、空行序列、有序列表）。
  const docLines = [
    '第一段：夜色沉下去的时候，走廊尽头的灯还亮着。',
    '对话在两个方向之间摇摆，一边是试探，一边是坦白。',
    '',
    '```dart',
    'final x = 1;',
    '',
    '```',
    '',
    '- 列表项一',
    '- 列表项二',
    '  缩进续行',
    '',
    '> 引用行一',
    '> 引用行二',
    '',
    r'$$',
    'E = mc^2',
    r'$$',
    '',
    '~~~',
    '波浪围栏内容',
    '```',
    '波浪内伪闭合（不同标记，不闭合）',
    '~~~',
    '',
    '2. 有序列表',
    '3) 括号有序',
    '',
    '尾段继续写下去，雨声盖过了电话铃声。',
  ];

  test('切块 Tracker：任意粒度前缀链与纯函数恒等（含行中切块）', () {
    final tracker = MarkdownBlockStartsTracker();
    final doc = docLines.join('\n');
    // 以不规则字符步长推进（7 是素数，会落在各种行中/行界/围栏中间），
    // 每一步断言增量结果 == 纯函数结果。
    for (var end = 0; end <= doc.length; end += 7) {
      final prefix = doc.substring(0, end);
      expect(
        tracker.scan(prefix),
        markdownBlockStarts(prefix),
        reason: '前缀长度 $end 增量切块必须与纯函数恒等',
      );
    }
    // 终态全文再对一次（含末行无换行形态）。
    expect(tracker.scan(doc), markdownBlockStarts(doc));
  });

  test('切块 Tracker：等值不同对象返回缓存、替换全量重建后续链恒等', () {
    final tracker = MarkdownBlockStartsTracker();
    const base = '一段正文。\n\n第二段正文。';
    expect(tracker.scan(base), markdownBlockStarts(base));
    // 等值不同对象：结果不变。
    expect(tracker.scan('一段正文。\n\n第二段正文。'), markdownBlockStarts(base));

    // 替换（非前缀延展）：全量重建。
    const replaced = '完全不同的文本\n\n```dart\ncode\n```\n\n尾段';
    expect(tracker.scan(replaced), markdownBlockStarts(replaced));
    // 替换后继续追加：链恢复恒等。
    const tail = '追加内容一行\n\n再一行。';
    for (var extra = 0; extra <= tail.length; extra += 3) {
      final text = replaced + tail.substring(0, extra);
      expect(tracker.scan(text), markdownBlockStarts(text));
    }
  });

  test('判纯 Gate：前缀链与纯函数恒等（纯→特征字符→持续追加）', () {
    final gate = StreamingPlainTextGate();
    final buf = StringBuffer();
    const gateFrom = 0;
    // 纯散文若干行。
    for (var i = 0; i < 6; i++) {
      buf
        ..write('夜色沉下去的时候，走廊尽头的灯还亮着。第 $i 次也是。')
        ..write('\n');
    }
    // 注入特征字符（强调 *），此后恒非纯。
    buf
      ..write('她数着台阶*下楼，第三级永远比其余的响。')
      ..write('\n');
    for (var i = 0; i < 6; i++) {
      buf
        ..write('对话在两个方向之间摇摆，一边是试探，一边是坦白。$i')
        ..write('\n');
    }
    final doc = buf.toString();

    for (var end = 0; end <= doc.length; end += 11) {
      final prefix = doc.substring(0, end);
      expect(
        gate.isPlainFrom(prefix, gateFrom),
        looksLikePlainText(prefix.substring(gateFrom)),
        reason: '前缀长度 $end 判纯必须与纯函数恒等',
      );
    }
  });

  test('判纯 Gate：失败行出范围（from 越过）后重续判定', () {
    final gate = StreamingPlainTextGate();
    const doc = '第一段纯文本\n\n第二段*带特征字符\n\n第三段纯文本';
    // 整体非纯（第二段有 *）。
    expect(gate.isPlainFrom(doc, 0), isFalse);
    // from 越过失败行后（0 → 第三段起点），当前范围全纯 → true。
    final thirdStart = doc.indexOf('第三段');
    expect(gate.isPlainFrom(doc, thirdStart), isTrue);
    expect(looksLikePlainText(doc.substring(thirdStart)), isTrue);
  });

  test('判纯 Gate：reset 回到首观察态', () {
    final gate = StreamingPlainTextGate();
    const doc = '含`特征\n\n纯文本';
    expect(gate.isPlainFrom(doc, doc.indexOf('纯文本')), isTrue);
    expect(gate.isPlainFrom(doc, 0), isFalse);
    gate.reset();
    expect(gate.isPlainFrom(doc, doc.indexOf('纯文本')), isTrue);
  });

  test('切块 Tracker + 判纯 Gate：空串与首帧边界', () {
    final tracker = MarkdownBlockStartsTracker();
    expect(tracker.scan(''), isEmpty);
    expect(tracker.scan(''), isEmpty);
    expect(
      tracker.scan('单行无换行'),
      markdownBlockStarts('单行无换行'),
    );
    final gate = StreamingPlainTextGate();
    expect(gate.isPlainFrom('', 0), isTrue);
    expect(gate.isPlainFrom('纯文本', 0), isTrue);
  });
}
