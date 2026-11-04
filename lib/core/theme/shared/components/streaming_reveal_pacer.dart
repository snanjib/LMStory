/// 平滑揭示配速：把「已到达的文本长度」按平滑速率
/// 揭示给渲染层，消除「模型输出快 → 每 32ms 一整批字同时上屏」的蹦字感。
///
/// 机制：文本从网络到界面是**成批**的（控制器 32ms 合帧），模型越快每批
/// 字数越多（每秒 200-400 字时，每批 7-13 字同时出现、一秒 30 次）。淡入
/// 只能改变每批字的透明度，改变不了「同时出现」这件事；要让写入边沿稳定
/// 推进，只能由显示层按平滑速率释放已到达的文本——这正是 chatbox 每 token
/// 小增量手感的来源。
///
/// 保真约束：
/// - **滞后有界**：`maxLag` 是屏幕上文字落后模型输出的上限，排空速率按
///   积压量自适应（积压越多放得越快），因此不论模型多快都不会越拖越远；
/// - **步长收敛**：积压小时每帧只放 1 个码元，写入边沿是连续推进而非跳动；
/// - **首观察/替换直接到位**：挂载时已有的大段文本（切会话、重挂、批量
///   重渲染）不是「正在写入」，不逐帧放出；替换/收缩同样立即对齐；
/// - **不切断代理对**：揭示边界不落在 UTF-16 低代理上（emoji 不裂开）。
///
/// R1 单源：三模式文案载体共用本类，禁止模式私有调参。
library;

// lm-motion-exempt: 流式揭示配速（性能红线区引擎节奏，文件内已具名单源）
/// 屏幕上文本落后模型输出的上限。
const Duration streamingRevealMaxLag = Duration(milliseconds: 250);

/// 单帧至少揭示的码元数：积压很小时也能持续前进（不因取整停住）。
const int streamingRevealMinStepCodeUnits = 1;

// lm-motion-exempt: 流式揭示闲置回弹（性能红线区引擎节奏，文件内已具名单源）
/// 源文本停顿多久后立即补齐（不再保留揭示滞后）。
///
/// 揭示采用「积压按 maxLag 自适应加速」的指数收敛：稳态下屏幕滞后 ≈ maxLag
/// （这正是要的手感），但突发结束后残差会按 maxLag 时间常数慢慢磨——既无
/// 意义又会在生成结束时留下半截文字。因此源停顿超过本阈值即一次性补齐；
/// 副作用是慢速模型（到达间隙本来就大）自动退化为即时显示，不做无谓延迟。
const Duration streamingRevealIdleSnap = Duration(milliseconds: 150);

/// 平滑揭示配速器：输入当帧到达的全文，输出本帧应渲染的长度。
class StreamingRevealPacer {
  StreamingRevealPacer({this.maxLag = streamingRevealMaxLag});

  /// 滞后上限（可注入窄窗口用于测试）。
  final Duration maxLag;

  int _revealed = 0;
  bool _initialized = false;
  String _seen = '';

  /// 源文本停止增长的累计时长（超过 [streamingRevealIdleSnap] 即补齐）。
  Duration _idleFor = Duration.zero;

  /// 当前应渲染的长度（单调不减；替换/收缩时立即对齐到新长度）。
  int get revealed => _revealed;

  /// 推进一帧，返回本帧应渲染的长度。
  ///
  /// [text] 为当帧到达的全文，[dt] 为距上一帧的时长（首帧传
  /// [Duration.zero]，按最小步长前进）。
  ///
  /// 只有「**追加增长**」（新文以旧文为前缀）才配速；首次观察、替换、
  /// 收缩一律立即到位——它们不是「正在写入」，不该被逐帧放出。
  int advance(String text, Duration dt) {
    final target = text.length;
    if (target > _seen.length) {
      _idleFor = Duration.zero;
    } else {
      _idleFor += dt;
    }
    final isAppendGrowth = _initialized && text.startsWith(_seen);
    _seen = text;
    if (!isAppendGrowth) {
      _initialized = true;
      _revealed = target;
      return target;
    }
    if (target <= _revealed) {
      // 收缩（渲染端已超前）：立即对齐（不重放、不拖尾）。
      _revealed = target;
      return target;
    }
    if (_idleFor >= streamingRevealIdleSnap) {
      // 源已停顿：不再保留滞后，一次性补齐（生成结束不留半截文字）。
      _revealed = target;
      return target;
    }
    final backlog = target - _revealed;
    // 排空速率自适应：积压一个 maxLag 的量时按窗口排空，积压更少时按
    // 最小步长前进——两步长取大者，保证既平滑又不落后。
    final drainStep =
        backlog * dt.inMicroseconds / maxLag.inMicroseconds.toDouble();
    var step = drainStep > streamingRevealMinStepCodeUnits
        ? drainStep.floor()
        : streamingRevealMinStepCodeUnits;
    if (step > backlog) {
      step = backlog;
    }
    var next = _revealed + step;
    // 不切断代理对（emoji 等增补平面字符不可裂开渲染）。
    if (next < target && _isLowSurrogate(text.codeUnitAt(next))) {
      next++;
    }
    // clamp 后回写并内联返回（join_return_with_assignment）
    return _revealed = next > target ? target : next;
  }

  /// 回到首观察态（挂载/数据清空后重新开始流式）。
  void reset() {
    _revealed = 0;
    _initialized = false;
    _seen = '';
    _idleFor = Duration.zero;
  }

  /// 立即到位（停止生成、宿主主动揭示全量文本）。
  void snapTo(int target) {
    _revealed = target;
    _initialized = true;
    _idleFor = streamingRevealIdleSnap;
  }

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}
