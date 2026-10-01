///  批2：流式 Markdown 块切分器（纯函数，无 UI 依赖）
///
/// 冻结前缀渲染的基础：把累计全文切成「块」，除尾部不稳定窗口（默认
/// 2 块，见 StreamingMarkdownBody.unstableTailBlocks）外全部冻结（各自
/// 只解析一次，缓存 widget 复用），每 delta 只重解析尾块——把 O(全文)
/// 的重解析降为 O(尾块)，消灭长文流式的 O(n²) 累积。
///
/// 切分规则（保守，宁可少切不切错）：
/// 1. 块边界 = 一个或多个空行之后的第一个非空行；
/// 2. 未闭合围栏（``` / ~~~，允许 ≤3 个前导空格）与 `$$` 数学块
///    **内部的空行不切**（代码块/公式常含空行）。闭合判定与 CommonMark
///    收敛：同标记字符、长度 ≥ 开栏、标记后只允许空白（2026-09-10
///    修复：混合标记 / 更短围栏 / ` ``` lang ` 形式的行不闭合——误闭合
///    会让围栏内部的空行变成块边界，把代码块切碎产生错误渲染）；
/// 3. 空行后的延续行不切（CommonMark 语义：以下整体是一个块）：
///    - 列表标记行跟在列表标记行之后（同一列表的松散条目）；
///    - `>` 行跟在 `>` 行之后（同一引用块）；
///    - 缩进行（≥4 空格 / Tab）跟在列表/引用行之后（条目续行）。
///
/// 已知取舍（记入设计文档 §四）：跨块的链接引用定义
/// （`[ref]: url` 在前块、`[text][ref]` 在后块）在独立解析尾块时失效
/// （渲染为字面文本）；LLM 叙事输出几乎不用引用定义，接受。
/// 非 CommonMark 一致性实现——它是渲染缓存切分器，不是解析器；
/// 切分过保守的代价只是冻结变少（退化为全文重解析），不产生错误渲染。
List<int> markdownBlockStarts(String text) {
  if (text.isEmpty) return const [];
  final starts = <int>[0];
  var inFence = false;
  // 开栏围栏的标记字符（` / ~）与跑长——闭合须同字符且 ≥ 此长度
  var fenceMarker = 0;
  var fenceLength = 0;
  var inMath = false;
  var sawBlank = false;
  // 上一非空行是否列表/引用（供延续判定）
  var prevIsListOrQuote = false;

  for (var i = 0; i < text.length;) {
    final lineEnd = text.indexOf('\n', i);
    final end = lineEnd == -1 ? text.length : lineEnd;
    final line = text.substring(i, end);
    final trimmedLeft = line.replaceFirst(_upToThreeLeadingSpaces, '');
    final isBlank = line.trim().isEmpty;

    if (!isBlank) {
      if (inFence) {
        // 围栏闭合判定：同标记字符、长度 ≥ 开栏、标记后只剩空白
        //（CommonMark：闭合栏不得带 info 字符串）。更严格的方向是
        // 安全的——不闭合只是整块留活跃（少冻结），误闭合会把围栏
        // 内部切碎（错误渲染）。
        final run = _fenceRunOf(trimmedLeft);
        if (run != null &&
            run.marker == fenceMarker &&
            run.length >= fenceLength &&
            trimmedLeft.substring(run.length).trim().isEmpty) {
          inFence = false;
        }
      } else if (inMath) {
        if (line.trim() == r'$$') inMath = false;
      } else {
        final run = _fenceRunOf(trimmedLeft);
        final isFenceOpener = run != null;
        final isMathOpener = line.trim() == r'$$';
        // 围栏/数学块起始行本身就是块边界（延续判定不适用——围栏标记
        // 不是任何块的延续）
        if (sawBlank && !isFenceOpener && !isMathOpener) {
          if (!_continuesBlock(line, prevIsListOrQuote)) {
            starts.add(i);
          }
        } else if (sawBlank) {
          starts.add(i);
        }
        if (isFenceOpener) {
          inFence = true;
          fenceMarker = run.marker;
          fenceLength = run.length;
        } else if (isMathOpener) {
          inMath = true;
        }
        prevIsListOrQuote =
            _isListMarkerLine(line) || line.trimLeft().startsWith('>');
      }
      sawBlank = false;
    } else if (!inFence && !inMath) {
      sawBlank = true;
    }
    if (lineEnd == -1) break;
    i = lineEnd + 1;
  }
  return starts;
}

/// 行首围栏标记跑（入参须已去 ≤3 前导空格）：≥3 个连续同字符的
/// ``` 或 ~~~。返回 (marker: 字符码, length: 跑长)；非围栏行返回 null。
({int marker, int length})? _fenceRunOf(String trimmedLeft) {
  if (trimmedLeft.length < 3) return null;
  final marker = trimmedLeft.codeUnitAt(0);
  if (marker != 0x60 /* ` */ && marker != 0x7E /* ~ */) return null;
  var length = 0;
  while (
      length < trimmedLeft.length && trimmedLeft.codeUnitAt(length) == marker) {
    length++;
  }
  return length >= 3 ? (marker: marker, length: length) : null;
}

final _listMarker = RegExp(r'^ {0,3}(?:[-+*]|\d{1,9}[.)])\s');

/// ≤3 个前导空格（顶层缓存：流式每帧对全文调用一次，RegExp 构造
/// 不宜留在逐行热路径—— 快速路径下它是每帧 32ms 预算的固定开销）
final _upToThreeLeadingSpaces = RegExp('^ {0,3}');

bool _isListMarkerLine(String line) => _listMarker.hasMatch(line);

/// 空行后的这行是否延续前一个块（不切）。
bool _continuesBlock(String line, bool prevIsListOrQuote) {
  if (!prevIsListOrQuote) return false;
  if (_isListMarkerLine(line)) return true;
  if (line.trimLeft().startsWith('>')) return true;
  // 缩进续行（列表条目内的懒延续 / 代码缩进属于列表项）
  return line.startsWith('    ') || line.startsWith('\t');
}

/// 块文本是否「看起来是纯文本」——不含任何 Markdown
/// 特征字符时为 true，调用方可放心用 Text 直渲（跳过 Markdown 重解析）。
///
/// 设计原则：**宁漏勿误**。漏判（其实是纯文本但走了 MarkdownBody 慢路
/// 径）只是损失性能，渲染仍正确；误判（其实含语法却走了 Text）会错误
/// 渲染。因此特征集刻意保守：
///
/// - 行内任意位置出现以下字符即非纯：`` ` ``（行内代码/围栏）、`*`
///   （强调/无序列表/分隔线）、`_`（强调/分隔线）、`~`（删除线/围栏）、
///   `#`（标题）、`>`（引用/自动链接折行）、`|`（表格）、`[`（链接/
///   图片/引用定义）、`!`（图片）、`<`（HTML/自动链接）、`&`（HTML
///   实体）、`\`（转义）、`$`（LaTeX 公式；chat 模式启用
///   LatexInlineSyntax，`$x$` 会渲染成公式）、`\r`（保守把 CR 当特征，
///   交给 MarkdownBody 处理 CRLF）。中文全角标点（！？。——）不受影响。
/// - 行首（≤3 前导空格后）出现以下标记即非纯：`-` / `+`（无序列表/
///   分隔线 `---`）、`=`（setext 下划线）、数字 + `.` / `)`（有序列表，
///   保守起见不要求后随空格——`3.14159` 起头的行只是退回慢路径）。
/// - 缩进 ≥4 空格 / Tab 起头的行是缩进代码块，非纯。
///
/// 纯函数（无 UI 依赖），单测见 streaming_markdown_blocks_test.dart。
bool looksLikePlainText(String block) {
  for (var i = 0; i < block.length;) {
    final lineEnd = block.indexOf('\n', i);
    final end = lineEnd == -1 ? block.length : lineEnd;
    if (!_lineLooksLikePlainText(block, i, end)) return false;
    if (lineEnd == -1) break;
    i = lineEnd + 1;
  }
  return true;
}

bool _lineLooksLikePlainText(String block, int start, int end) {
  var i = start;
  // 前导空白列数（Tab 折 4 列，CommonMark 口径）
  var indent = 0;
  while (i < end) {
    final c = block.codeUnitAt(i);
    if (c == 0x20) {
      indent++;
    } else if (c == 0x09) {
      indent += 4;
    } else {
      break;
    }
    i++;
  }
  // 缩进代码块（≥4 列）不是纯文本段落
  if (indent >= 4) return false;

  if (i < end) {
    final c = block.codeUnitAt(i);
    // 行首列表标记 / 分隔线（- +）/ setext 下划线（=）。
    // `*` `>` `#` `~` 等行首形态已被下方行内字符集覆盖。
    if (c == 0x2D /* - */ || c == 0x2B /* + */ || c == 0x3D /* = */) {
      return false;
    }
    // 有序列表标记：1~9 位数字 + `.` / `)`（保守：不要求后随空格）
    var j = i;
    var digits = 0;
    while (j < end && digits < 9) {
      final d = block.codeUnitAt(j);
      if (d < 0x30 || d > 0x39) break;
      digits++;
      j++;
    }
    if (digits > 0 && j < end) {
      final after = block.codeUnitAt(j);
      if (after == 0x2E /* . */ || after == 0x29 /* ) */) return false;
    }
  }

  // 行内特征字符（保守集，见函数文档）
  for (; i < end; i++) {
    switch (block.codeUnitAt(i)) {
      case 0x60: // `
      case 0x2A: // *
      case 0x5F: // _
      case 0x7E: // ~
      case 0x23: // #
      case 0x3E: // >
      case 0x7C: // |
      case 0x5B: // [
      case 0x21: // !
      case 0x3C: // <
      case 0x26: // &
      case 0x5C: // \
      case 0x24: // $
      case 0x0D: // \r
        return false;
    }
  }
  return true;
}
