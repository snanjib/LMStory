/// finish_round 参数流的 prose 值提取器（导演模式正文交付契约设计 §4.2）
///
/// 输入是完整参数 JSON 的增量分片（`{"prose":"正文…"}` 整体的分片，不是
/// prose 值的分片）。流式状态机：跳过 JSON 结构定位 "prose" 键，进入其
/// 字符串值后增量反转义输出到 liveBlocks（复用 content 直播机制）。
///
/// 提取与最终 JSON 解析成败**无关**——参数尾部被截断（`finish_reason=
/// length` 中途砍断）导致 `fromRawArgs` 解析失败时，[buffer] 中已提取的
/// 正文仍在，是通道 B（JSON 崩了文字活着）的实现基础。
///
/// hold-back 反转义：字符 `\` 到达时扣住等下一片判定转义类型；`\u` 扣满
/// 4 个 hex 才解码；字面 UTF-16 高代理扣住等低代理合成（跨片安全）。
/// 其它键的值（未来 finish_round 若增参数）跳过不输出。
class AgentProseExtractor {
  final StringBuffer _buffer = StringBuffer();
  final StringBuffer _out = StringBuffer();

  _ExtractorState _state = _ExtractorState.seeking;

  // ── 字符串 token（键名/非提取值）状态 ──
  final StringBuffer _token = StringBuffer();
  bool _tokenEscape = false;

  // ── skipValue（其它键的值）状态 ──
  int _skipDepth = 0;
  bool _inSkipString = false;
  bool _skipEscape = false;

  // ── proseValue 提取状态（hold-back）──
  bool _escapeStarted = false;
  int? _hexLeft;
  final StringBuffer _hexDigits = StringBuffer();
  int? _heldHighSurrogate;

  /// 喂入一个参数 JSON 分片，返回本次新解码的正文文本
  String push(String chunk) {
    _out.clear();
    for (final cu in chunk.codeUnits) {
      _consume(cu);
    }
    return _out.toString();
  }

  /// 累计已提取的正文文本（截断场景下即通道 B 的收割来源）
  String get buffer => _buffer.toString();

  /// prose 字符串是否已闭合（闭合后进入 done，后续分片全部丢弃）
  bool get isStringClosed => _state == _ExtractorState.done;

  void _consume(int cu) {
    switch (_state) {
      case _ExtractorState.done:
        return;
      case _ExtractorState.seeking:
        if (cu == _quote) {
          _token.clear();
          _tokenEscape = false;
          _state = _ExtractorState.stringToken;
        }
      // 其它结构字符（{ } [ ] , : 与空白）无需动作
      case _ExtractorState.stringToken:
        _consumeTokenChar(cu);
      case _ExtractorState.afterStringToken:
        if (_isWhitespace(cu)) return;
        if (cu == _colon) {
          _state = _token.toString() == 'prose'
              ? _ExtractorState.expectProseValue
              : _skipValueReset();
          return;
        }
        // 非冒号 = 该字符串是值不是键；分隔符交回 seeking
        _state = _ExtractorState.seeking;
        _consume(cu);
      case _ExtractorState.skipValue:
        _consumeSkipChar(cu);
      case _ExtractorState.expectProseValue:
        if (_isWhitespace(cu)) return;
        if (cu == _quote) {
          _state = _ExtractorState.proseValue;
          return;
        }
        // prose 的值不是字符串（畸形输入）：按普通值跳过，继续找下一个键
        _state = _skipValueReset();
        _consumeSkipChar(cu);
      case _ExtractorState.proseValue:
        _consumeProseChar(cu);
    }
  }

  /// 字符串 token 读取（键名比对用；转义序列原样跳过不做解码）
  void _consumeTokenChar(int cu) {
    if (_tokenEscape) {
      _tokenEscape = false;
      return;
    }
    if (cu == _backslash) {
      _tokenEscape = true;
      return;
    }
    if (cu == _quote) {
      _state = _ExtractorState.afterStringToken;
      return;
    }
    _token.writeCharCode(cu);
  }

  /// 其它键的值跳过：嵌套深度计数 + 内嵌字符串（含转义）整体跳过
  void _consumeSkipChar(int cu) {
    if (_inSkipString) {
      if (_skipEscape) {
        _skipEscape = false;
      } else if (cu == _backslash) {
        _skipEscape = true;
      } else if (cu == _quote) {
        _inSkipString = false;
      }
      return;
    }
    switch (cu) {
      case _quote:
        _inSkipString = true;
      case _lbrace:
      case _lbracket:
        _skipDepth++;
      case _rbrace:
      case _rbracket:
        if (_skipDepth > 0) {
          _skipDepth--;
        } else {
          // 收容对象的闭合括号：值结束，回到键扫描
          _state = _ExtractorState.seeking;
        }
      case _comma:
        if (_skipDepth == 0) _state = _ExtractorState.seeking;
      default:
        break; // 标量字符与空白
    }
  }

  /// prose 值提取主体（hold-back 反转义）
  void _consumeProseChar(int cu) {
    // 1) \uXXXX 的 hex 收集中：扣满 4 位才解码
    final hexLeft = _hexLeft;
    if (hexLeft != null) {
      _hexDigits.writeCharCode(cu);
      if (hexLeft - 1 == 0) {
        _hexLeft = null;
        final unit = _parseHex4(_hexDigits.toString());
        _hexDigits.clear();
        // 非法 hex（畸形输入）：丢弃该转义序列，容错继续
        if (unit != null) _emit(unit);
      } else {
        _hexLeft = hexLeft - 1;
      }
      return;
    }

    // 2) 反斜杠后：判定转义类型
    if (_escapeStarted) {
      _escapeStarted = false;
      switch (cu) {
        case 0x6E: // n
          _emit(0x0A);
        case 0x74: // t
          _emit(0x09);
        case 0x72: // r
          _emit(0x0D);
        case 0x62: // b
          _emit(0x08);
        case 0x66: // f
          _emit(0x0C);
        case 0x75: // u
          _hexDigits.clear();
          _hexLeft = 4;
        default:
          // \" \\ \/ 及弱模型笔误：按字面输出转义后的字符
          _emit(cu);
      }
      return;
    }

    // 3) 高代理扣住：等低代理合成完整码点
    final held = _heldHighSurrogate;
    if (held != null) {
      _heldHighSurrogate = null;
      if (cu >= 0xDC00 && cu <= 0xDFFF) {
        _emit(0x10000 + ((held - 0xD800) << 10) + (cu - 0xDC00));
        return;
      }
      // 非低代理：孤高代理按原样吐出，当前字符继续走常规处理
      _emit(held);
    }

    // 4) 常规字符
    if (cu == _backslash) {
      _escapeStarted = true;
      return;
    }
    if (cu == _quote) {
      _state = _ExtractorState.done;
      return;
    }
    if (cu >= 0xD800 && cu <= 0xDBFF) {
      _heldHighSurrogate = cu;
      return;
    }
    _emit(cu);
  }

  void _emit(int charCode) {
    _buffer.writeCharCode(charCode);
    _out.writeCharCode(charCode);
  }

  /// 进入 skipValue 前重置其嵌套/字符串状态
  _ExtractorState _skipValueReset() {
    _skipDepth = 0;
    _inSkipString = false;
    _skipEscape = false;
    return _ExtractorState.skipValue;
  }

  static int? _parseHex4(String digits) {
    final value = int.tryParse(digits, radix: 16);
    // UTF-16 码单元上限 0xFFFF
    if (value == null || value < 0 || value > 0xFFFF) return null;
    return value;
  }

  static bool _isWhitespace(int cu) =>
      cu == 0x20 || cu == 0x09 || cu == 0x0A || cu == 0x0D;
}

enum _ExtractorState {
  /// 扫描 JSON 结构，等待字符串 token（键名候选）
  seeking,

  /// 读取字符串 token（键名或非提取的字符串值）
  stringToken,

  /// token 闭合，等 `:` 判定键/值
  afterStringToken,

  /// 跳过其它键的值（标量/字符串/嵌套结构）
  skipValue,

  /// prose 键的 `:` 已到，等值开始（`"` 进入提取）
  expectProseValue,

  /// prose 值字符串内：增量反转义输出
  proseValue,

  /// prose 字符串已闭合：后续分片全部丢弃
  done,
}

const int _quote = 0x22;
const int _backslash = 0x5C;
const int _colon = 0x3A;
const int _comma = 0x2C;
const int _lbrace = 0x7B;
const int _rbrace = 0x7D;
const int _lbracket = 0x5B;
const int _rbracket = 0x5D;
