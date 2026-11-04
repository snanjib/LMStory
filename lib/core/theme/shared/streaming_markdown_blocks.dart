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
/// 切块扫描器的逐行可变状态（[markdownBlockStarts] 纯函数与
/// [MarkdownBlockStartsTracker] 增量路径共享同一份行循环，单源）。
class MarkdownBlockScanState {
  MarkdownBlockScanState() : starts = <int>[0];

  /// 已发现的块起点（升序；首元素恒 0）。
  final List<int> starts;
  bool inFence = false;

  /// 开栏围栏的标记字符（` / ~）与跑长——闭合须同字符且 ≥ 此长度
  int fenceMarker = 0;
  int fenceLength = 0;
  bool inMath = false;
  bool sawBlank = false;

  /// 上一非空行是否列表/引用（供延续判定）
  bool prevIsListOrQuote = false;
}

/// 「最后一个完整行边界」的定稿快照：处理完 [end] 之前的所有行之后的
/// 全部扫描器状态（标量拷贝 + starts 定稿长度）。末行（无 `\n`，仍在
/// 增长）的效果**不携带**——它的判定会随内容变化（如围栏开栏行），下一
/// 次调用从快照重放，与一次性扫描推进到该边界完全同基线。
class _ScanCommit {
  _ScanCommit(this.end, MarkdownBlockScanState s)
      : startsLength = s.starts.length,
        inFence = s.inFence,
        fenceMarker = s.fenceMarker,
        fenceLength = s.fenceLength,
        inMath = s.inMath,
        sawBlank = s.sawBlank,
        prevIsListOrQuote = s.prevIsListOrQuote;

  /// 定稿边界（行首偏移，续扫起点）。
  final int end;
  final int startsLength;
  final bool inFence;
  final int fenceMarker;
  final int fenceLength;
  final bool inMath;
  final bool sawBlank;
  final bool prevIsListOrQuote;

  void restore(MarkdownBlockScanState live) {
    live.starts.length = startsLength;
    live
      ..inFence = inFence
      ..fenceMarker = fenceMarker
      ..fenceLength = fenceLength
      ..inMath = inMath
      ..sawBlank = sawBlank
      ..prevIsListOrQuote = prevIsListOrQuote;
  }
}

/// 从行首偏移 [from] 扫 [text] 到末尾（[from] 须为行首，state 须为推进
/// 到 [from] 时的状态——增量路径经 [_ScanCommit.restore] 重建该基线）。
/// 返回最后一个**完整行**边界的定稿快照；本次没处理完整行时原样返回
/// [committed]。
_ScanCommit? _scanLines(
  String text,
  int from,
  MarkdownBlockScanState state,
  _ScanCommit? committed,
) {
  final starts = state.starts;
  var best = committed;
  var i = from;
  for (; i < text.length;) {
    final lineEnd = text.indexOf('\n', i);
    final end = lineEnd == -1 ? text.length : lineEnd;
    final line = text.substring(i, end);
    final trimmedLeft = line.replaceFirst(_upToThreeLeadingSpaces, '');
    final isBlank = line.trim().isEmpty;

    if (!isBlank) {
      if (state.inFence) {
        // 围栏闭合判定：同标记字符、长度 ≥ 开栏、标记后只剩空白
        //（CommonMark：闭合栏不得带 info 字符串）。更严格的方向是
        // 安全的——不闭合只是整块留活跃（少冻结），误闭合会把围栏
        // 内部切碎（错误渲染）。
        final run = _fenceRunOf(trimmedLeft);
        if (run != null &&
            run.marker == state.fenceMarker &&
            run.length >= state.fenceLength &&
            trimmedLeft.substring(run.length).trim().isEmpty) {
          state.inFence = false;
        }
      } else if (state.inMath) {
        if (line.trim() == r'$$') state.inMath = false;
      } else {
        final run = _fenceRunOf(trimmedLeft);
        final isFenceOpener = run != null;
        final isMathOpener = line.trim() == r'$$';
        // 围栏/数学块起始行本身就是块边界（延续判定不适用——围栏标记
        // 不是任何块的延续）
        if (state.sawBlank && !isFenceOpener && !isMathOpener) {
          if (!_continuesBlock(line, state.prevIsListOrQuote)) {
            starts.add(i);
          }
        } else if (state.sawBlank) {
          starts.add(i);
        }
        if (isFenceOpener) {
          state
            ..inFence = true
            ..fenceMarker = run.marker
            ..fenceLength = run.length;
        } else if (isMathOpener) {
          state.inMath = true;
        }
        state.prevIsListOrQuote =
            _isListMarkerLine(line) || line.trimLeft().startsWith('>');
      }
      state.sawBlank = false;
    } else if (!state.inFence && !state.inMath) {
      state.sawBlank = true;
    }
    if (lineEnd == -1) break;
    i = lineEnd + 1;
    best = _ScanCommit(i, state);
  }
  return best;
}

List<int> markdownBlockStarts(String text) {
  if (text.isEmpty) return const [];
  final state = MarkdownBlockScanState();
  _scanLines(text, 0, state, null);
  return state.starts;
}

/// [markdownBlockStarts] 的增量版（批2）：流式 append 场景下
/// 每帧只扫**新增行 + 上一末行**，消灭超长单段的每帧全文行扫描
/// （含每行 substring/regex 分配）。
///
/// 语义：对任意文本，[scan] 的返回值与 [markdownBlockStarts] 恒等
/// （含围栏/数学块/列表引用延续/空行序列）。机制是**定界快照重放**：
/// 每帧从「最后一个完整行边界」的 [_ScanCommit] 重建扫描器基线，重判
/// 末行（仍在增长，判定可变——如围栏开栏行）+ 扫新增行。末行效果
/// 从不进入快照，重放与一次性扫描推进到该边界**完全同基线**，不依赖
/// 状态幂等性（围栏开栏行在 inFence=true 下重放会被误判闭合行——
/// 2026-10-05 实测教训，见 streaming_markdown_blocks_incremental_test）。
/// 非追加延展（替换/收缩）自动全量重建，调用方无须先行失效。
class MarkdownBlockStartsTracker {
  final MarkdownBlockScanState _state = MarkdownBlockScanState();
  _ScanCommit? _committed;
  String _scanned = '';

  List<int> scan(String text) {
    if (text.isEmpty) return const [];
    if (identical(text, _scanned)) return _state.starts;
    final isExtension =
        text.length >= _scanned.length && text.startsWith(_scanned);
    if (!isExtension) {
      _reset();
    } else if (text == _scanned) {
      // 等值不同对象（常见：同帧同长 substring）：结果不变。
      _scanned = text;
      return _state.starts;
    }
    // 从定稿快照重放（无快照 = 首扫描，从 0 起）。
    final committed = _committed;
    if (committed == null) {
      _state.starts.length = 0;
      _state.starts.add(0);
    } else {
      committed.restore(_state);
    }
    _committed = _scanLines(
      text,
      committed?.end ?? 0,
      _state,
      committed,
    );
    _scanned = text;
    return _state.starts;
  }

  void reset() => _reset();

  void _reset() {
    _state.starts
      ..clear()
      ..add(0);
    _state
      ..inFence = false
      ..fenceMarker = 0
      ..fenceLength = 0
      ..inMath = false
      ..sawBlank = false
      ..prevIsListOrQuote = false;
    _committed = null;
    _scanned = '';
  }
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

/// [looksLikePlainText] 的增量版（批2）：流式 append 场景下对
/// 「data[from..] 是否全纯」按行缓存判定，每帧只验**新增行 + 末行**。
///
/// 两个缓存维度（data 绝对坐标，append-only 下行界恒定、行内容不可变）：
/// - [_verifiedEnd]：[0, _verifiedEnd) 内**完整行**已验纯（行对齐推进；
///   末行无 `\n` 不推进——它还在增长，每帧重验，成本 O(行长) 有界）；
/// - [_failStart]：首个失败行起点。append-only 下失败行的特征字符永远
///   在（前缀不可变），命中即 O(1) 返回 false；该行被冻结前缀吞出查询
///   范围（failStart < from）时清除重续——失败只对当前尾窗有意义。
///
/// 与 [looksLikePlainText(trim 后串)] 的等价性：trim 只切空白，空白行两侧
/// 判定同为纯；特征字符非空白，不可能被 trim 裁掉——未 trim 坐标判定
/// 是 trim 后判定的超集且同假值点。
class StreamingPlainTextGate {
  int _verifiedEnd = 0;
  int? _failStart;

  /// data[from..]（from 须为行首/块起点偏移）是否全纯。
  bool isPlainFrom(String data, int from) {
    final fail = _failStart;
    if (fail != null) {
      if (fail >= from) return false;
      _failStart = null;
    }
    var i = _verifiedEnd > from ? _verifiedEnd : from;
    while (i < data.length) {
      final lineEnd = data.indexOf('\n', i);
      final end = lineEnd == -1 ? data.length : lineEnd;
      if (!_lineLooksLikePlainText(data, i, end)) {
        _failStart = i;
        return false;
      }
      if (lineEnd == -1) break;
      i = lineEnd + 1;
      _verifiedEnd = i;
    }
    return true;
  }

  void reset() {
    _verifiedEnd = 0;
    _failStart = null;
  }
}
