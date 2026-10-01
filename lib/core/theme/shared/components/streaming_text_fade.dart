/// 流式新增段淡入——chatbox streaming-text-fade.ts
/// Flutter 移植（纯 Dart 部分：段追踪器 + 进展计算）
///
/// 语义：只追踪最近 [streamingFadeRetention] 留存窗口内「追加增长」的
/// 文本区间（旧文是全文前缀）；替换/收缩（重生成、压缩）全量清空且
/// 不淡入，避免整段闪烁重放历史。
///
/// R（2026-09-10 复验修复）：首次观察只把尾部
/// [streamingFadeFirstObservationTailCodeUnits] 码元当作新增段——新消息
/// 的开头文字照样淡入，而流式中途重挂（纯文本↔Markdown 段落切换、思考
/// 标签剥离等）不会把整段历史文字重放淡入（那会表现为「整块内容闪一下」）。
///
/// 渲染侧（streaming_fade_text.dart）只用「逐段颜色 alpha」表达淡入，
/// 不引入 WidgetSpan 原子盒：段落换行与行高与纯文本逐字符一致。原子盒
/// 会把不可断行的盒子整体推到下一行、到期又缩回，是复验中「换行/位置
/// 在跳」与「尾行下方半透明幽灵」的根因；其数量预算（8）小于留存窗口内
/// 的段数（350ms/32ms ≈ 11），超预算的段整段直出不淡入，又表现为
/// 「一次蹦出好几个字」。
typedef StreamingFadeSegment = ({int start, int end, DateTime createdAt});

// lm-motion-exempt: 流式淡出时长（性能红线区引擎节奏，文件内已具名单源）
/// 淡入时长：300ms 内由透明推进到完全不透明（chatbox Block.css 300ms
/// ease-out 的同量级取值；300ms 单段尺度上线性与 ease-out 肉眼不可辨，
/// 故不引入曲线依赖）。
const Duration streamingFadeDuration = Duration(milliseconds: 300);

// lm-motion-exempt: 流式淡出保留窗（性能红线区引擎节奏，文件内已具名单源）
/// 新增段留存窗口：350ms（chatbox STREAMING_TEXT_FADE_RETENTION_MS）。
/// 淡入 300ms 完成后区间仍保留到 350ms 才回收；回收时该段 alpha 已是
/// 1.0，因此回收本身不产生任何视觉变化（不再有「到期重组跳一下」）。
const Duration streamingFadeRetention = Duration(milliseconds: 350);

/// 首次观察（或数据清空后重新开始）时只把尾部这么多码元当作新增段
/// （≈ 一行中文）。既保留「新消息首字浮现」的手感，又避免中途重挂时
/// 整段历史文字重放淡入。
const int streamingFadeFirstObservationTailCodeUnits = 40;

/// 段在 [now] 时刻的淡入进度：0 = 刚出现，1 = 完全不透明。
double streamingFadeProgress(StreamingFadeSegment segment, DateTime now) {
  final elapsed = now.difference(segment.createdAt);
  if (elapsed <= Duration.zero) return 0;
  if (elapsed >= streamingFadeDuration) return 1;
  return elapsed.inMicroseconds / streamingFadeDuration.inMicroseconds;
}

/// 追踪最近留存窗口内的新增文本区间，供纯文本快速路径表达淡入。
class StreamingFadeSegmentTracker {
  /// 默认取单源常量 [streamingFadeRetention]；测试可注入窄窗口。
  StreamingFadeSegmentTracker({
    this.retention = streamingFadeRetention,
    this.firstObservationTailCodeUnits =
        streamingFadeFirstObservationTailCodeUnits,
  });

  final Duration retention;

  /// 首次观察时只淡入的尾部长度（见常量注释）。
  final int firstObservationTailCodeUnits;

  final List<StreamingFadeSegment> _segments = [];
  String _previous = '';

  /// 当前活跃的新增段（起始偏移基于喂入的累计文本）。
  List<StreamingFadeSegment> get segments => List.unmodifiable(_segments);

  /// 每次 build 调用（[now] 为单调时钟，宿主用帧时间戳保证可测性）。
  void update(String text, DateTime now) {
    _segments.removeWhere((s) => now.difference(s.createdAt) > retention);
    if (text.length > _previous.length && text.startsWith(_previous)) {
      // 追加增长：新增区间 = 旧文长度到新文长度。首观察（旧文为空）时
      // 只取尾部窗口，避免长文重挂整体重放淡入。
      final start = _previous.isEmpty ? _tailStart(text) : _previous.length;
      _segments.add((start: start, end: text.length, createdAt: now));
    } else if (text != _previous) {
      // 替换/收缩（重生成、压缩）：清空且不淡入（不重放历史）。
      _segments.clear();
    }
    _previous = text;
  }

  /// 回到首观察态（数据清空后重新开始流式）。
  void reset() {
    _segments.clear();
    _previous = '';
  }

  int _tailStart(String text) {
    if (text.length <= firstObservationTailCodeUnits) return 0;
    var start = text.length - firstObservationTailCodeUnits;
    // 不切在 UTF-16 代理对中间（emoji 等增补平面字符不可截断）。
    while (start < text.length && _isLowSurrogate(text.codeUnitAt(start))) {
      start++;
    }
    return start;
  }

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}
