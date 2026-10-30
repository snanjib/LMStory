import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 快捷键作用域。
///
/// 作用域决定「谁能在什么位置消费这个键」：越靠内层的作用域在运行时覆盖
/// 外层（Flutter 的键事件从主焦点向上冒泡，先命中的 `Shortcuts` 消费掉）。
enum LmShortcutScope {
  /// 应用壳层（桌面壳 `MainLayout`）：与会话无关的全局动作。
  app,

  /// 会话页（对话 / 故事 / 导演）页体内：随页面进出生效。
  session,

  /// 浮层（对话框 / 底部浮层）：只覆盖其下方的作用域。
  overlay,

  /// 控件级：单个可聚焦控件自身的激活键（玻璃工厂的 Enter/Space）。
  control,
}

/// 平台无关的按键组合。
///
/// **为什么需要这一层**：Windows / Linux 用 `control`，macOS 用 `meta`——
/// 这不是同一个东西。Flutter 的 [SingleActivator] **不做平台映射**
/// （`control: true` 在 macOS 上同样要求物理 Control 键），所以历史上每个
/// 键位都在调用点手写「control 一支 + meta 一支」两遍。这里只写一遍
/// （`primary: true`），由 [activators] 展开成两支——**调用点禁止再手写两遍**。
class LmKeyCombo {
  const LmKeyCombo(
    this.key, {
    this.primary = false,
    this.shift = false,
    this.alt = false,
    this.includeRepeats = true,
  });

  /// 非修饰键（按下的那个键）。
  final LogicalKeyboardKey key;

  /// 「主修饰键」：Windows / Linux / Web = `control`，macOS = `meta`。
  final bool primary;

  final bool shift;
  final bool alt;

  /// 长按是否重复触发（方向键类导航为 true，动作类一般保持默认 true）。
  final bool includeRepeats;

  /// 展开为平台变体（`primary` 为真时给出 `control` 与 `meta` 两支）。
  Iterable<SingleActivator> get activators sync* {
    if (primary) {
      yield SingleActivator(
        key,
        control: true,
        shift: shift,
        alt: alt,
        includeRepeats: includeRepeats,
      );
      yield SingleActivator(
        key,
        meta: true,
        shift: shift,
        alt: alt,
        includeRepeats: includeRepeats,
      );
    } else {
      yield SingleActivator(
        key,
        shift: shift,
        alt: alt,
        includeRepeats: includeRepeats,
      );
    }
  }

  /// 冲突判据用的规范化指纹。
  ///
  /// 由于 `primary` 的组合恒展开为 {control, meta} 同构两支，两个组合是否
  /// 落在同一组按键上，等价于「键位 + 是否主修饰 + shift + alt + 重复」五元组
  /// 是否相等——不必逐个比较展开后的 [SingleActivator]。
  String get signature => '${key.keyId}|${primary ? 'primary' : 'plain'}'
      '|${shift ? 'shift' : '-'}|${alt ? 'alt' : '-'}'
      '|${includeRepeats ? 'repeat' : 'once'}';

  /// 键位的可读名（键位清单表用）。
  String get keyLabel => switch (key) {
        LogicalKeyboardKey.escape => 'Esc',
        LogicalKeyboardKey.enter => 'Enter',
        LogicalKeyboardKey.numpadEnter => 'NumEnter',
        LogicalKeyboardKey.space => 'Space',
        LogicalKeyboardKey.comma => ',',
        LogicalKeyboardKey.arrowUp => 'Up',
        LogicalKeyboardKey.arrowDown => 'Down',
        LogicalKeyboardKey.arrowLeft => 'Left',
        LogicalKeyboardKey.arrowRight => 'Right',
        _ => key.keyLabel.isEmpty ? 'Key#${key.keyId}' : key.keyLabel,
      };

  /// 完整键位写法（`Ctrl/Cmd+Shift+N` 形态）。
  String get label => [
        if (primary) 'Ctrl/Cmd',
        if (shift) 'Shift',
        if (alt) 'Alt',
        keyLabel,
      ].join('+');
}

/// 一条快捷键注册项：标识 / 可读描述 / 默认按键 / 作用域。
///
/// [description] 是**代码级可读描述（英文）**，供开发者与键位清单表使用。
/// 用户可见的中文文案必须走 slang：本文件位于 `lib/core/theme/**`，受仓库
/// 「中文字面量门禁」（`tool/ci_guards/check_chinese_literals.py`）约束；而本轮
/// 红线禁止新增 i18n 键 —— 键位清单表若要在应用内（帮助 / wiki 页）呈现，
/// 所需文案键已登记「需主控决策」（见交付报告的剩余项）。
class LmShortcut {
  const LmShortcut({
    required this.id,
    required this.description,
    required this.scope,
    required this.combos,
  });

  /// 稳定标识（`<作用域>.<动作>`）。调用点请用 [LmShortcuts] 的 id 常量。
  final String id;

  /// 代码级可读描述（英文，见类注释的文案口径说明）。
  final String description;

  final LmShortcutScope scope;

  /// 默认按键（可多组）。
  final List<LmKeyCombo> combos;

  /// 展开后的全部 [SingleActivator]（含 control / meta 平台变体）。
  Iterable<SingleActivator> get activators =>
      combos.expand((c) => c.activators);

  /// 键位清单表的「键位」列。
  String get keysLabel => combos.map((c) => c.label).join(' / ');
}

/// 桌面键盘交互层（**唯一事实源**）：可枚举的快捷键注册表 + 统一消费包装件。
///
/// ## 为什么需要它
///
/// 这个 app 主要跑桌面，但键盘交互此前是四份散落的 `CallbackShortcuts`：
/// 无注册表、无冲突检测、无可读描述（不可发现），`FocusTraversalGroup` /
/// `FocusTraversalOrder` 全仓 0 处（Tab 顺序 = 代码构造顺序）。本类把
/// 「有哪些键位、按键干什么、在哪个作用域生效」收成一份**可枚举**的表，
/// 页面侧只通过 [LmShortcutHost] 消费，不再裸写 `CallbackShortcuts`
/// （守卫 `test/core/theme/t11_shortcuts_guard_test.dart` 白名单闭集）。
///
/// ## 边界：哪些东西**不进**这张表
///
/// 文本编辑与焦点局部键**不是**全局快捷键，刻意留在组件内（`onKeyEvent`）：
///
/// | 位置 | 键 | 为什么不进表 |
/// |---|---|---|
/// | `chat_mode_input_area.dart` | Enter / Shift+Enter 发送与换行 | 用户可配置（设置里的「发送键 / 换行键」），且属 IME 上下文 |
/// | `in_session_search_bar.dart` | Enter / Shift+Enter / Esc 命中跳转 | 只在搜索框获焦时成立，属输入框自身的编辑语义 |
/// | `commit_slider.dart` | 方向键 / Home / End 调值 | 滑杆的值键语义（与 ARIA slider 同构） |
///
/// 这三处以外的键盘绑定都必须来自本表——守卫会扫「`lib/` 内 `lm_shortcuts.dart`
/// 之外是否还有裸 `SingleActivator(` / `CallbackShortcuts`」。
///
/// ## 平台修饰键
///
/// 见 [LmKeyCombo]：`primary` 只在表里写一遍，展开成交互层消费的两支。
abstract final class LmShortcuts {
  LmShortcuts._();

  // ── 注册项 id（调用点不得写裸字符串）─────────────────────────────

  /// 应用壳层：新建会话（`Ctrl/Cmd+N`）。
  static const String idNewChat = 'app.newChat';

  /// 应用壳层：新建故事（`Ctrl/Cmd+Shift+N`）。
  static const String idNewStory = 'app.newStory';

  /// 应用壳层：打开设置（`Ctrl/Cmd+,`）。
  static const String idSettings = 'app.settings';

  /// 应用壳层：全局搜索（`Ctrl/Cmd+K`）。
  static const String idGlobalSearch = 'app.globalSearch';

  /// 会话页：会话内搜索（`Ctrl/Cmd+F`）。
  static const String idSessionSearch = 'session.search';

  /// 会话页：收起会话内搜索（`Esc`）。
  static const String idSessionSearchClose = 'session.searchClose';

  /// 浮层：下一个结果 / 下一项（`↓`）。
  static const String idOverlayNext = 'overlay.next';

  /// 浮层：上一个结果 / 上一项（`↑`）。
  static const String idOverlayPrev = 'overlay.prev';

  /// 浮层：关闭浮层（`Esc`）。
  static const String idOverlayDismiss = 'overlay.dismiss';

  /// 控件级：激活当前获焦控件（`Enter` / `Space`）。
  static const String idControlActivate = 'control.activate';

  // ── 注册表 ───────────────────────────────────────────────────────

  /// 全量注册表。新增键位只改这里（页面侧用 [LmShortcutHost] 接处理器）。
  static const List<LmShortcut> registry = <LmShortcut>[
    // 应用壳层（桌面壳）：与会话无关的导航动作。
    LmShortcut(
      id: idNewChat,
      description: 'Start a new chat session',
      scope: LmShortcutScope.app,
      combos: [LmKeyCombo(LogicalKeyboardKey.keyN, primary: true)],
    ),
    LmShortcut(
      id: idNewStory,
      description: 'Start a new story session',
      scope: LmShortcutScope.app,
      combos: [
        LmKeyCombo(LogicalKeyboardKey.keyN, primary: true, shift: true),
      ],
    ),
    LmShortcut(
      id: idSettings,
      description: 'Open settings',
      scope: LmShortcutScope.app,
      combos: [LmKeyCombo(LogicalKeyboardKey.comma, primary: true)],
    ),
    LmShortcut(
      id: idGlobalSearch,
      description: 'Search messages across all sessions',
      scope: LmShortcutScope.app,
      combos: [LmKeyCombo(LogicalKeyboardKey.keyK, primary: true)],
    ),
    // 会话页：与页面生命周期同进退。
    LmShortcut(
      id: idSessionSearch,
      description: 'Search inside the current session',
      scope: LmShortcutScope.session,
      combos: [LmKeyCombo(LogicalKeyboardKey.keyF, primary: true)],
    ),
    LmShortcut(
      id: idSessionSearchClose,
      description: 'Collapse the in-session search bar',
      scope: LmShortcutScope.session,
      combos: [LmKeyCombo(LogicalKeyboardKey.escape)],
    ),
    // 浮层：列表型浮层的键盘导航与关闭。
    LmShortcut(
      id: idOverlayNext,
      description: 'Move to the next result',
      scope: LmShortcutScope.overlay,
      combos: [LmKeyCombo(LogicalKeyboardKey.arrowDown)],
    ),
    LmShortcut(
      id: idOverlayPrev,
      description: 'Move to the previous result',
      scope: LmShortcutScope.overlay,
      combos: [LmKeyCombo(LogicalKeyboardKey.arrowUp)],
    ),
    LmShortcut(
      id: idOverlayDismiss,
      description: 'Dismiss the overlay',
      scope: LmShortcutScope.overlay,
      combos: [LmKeyCombo(LogicalKeyboardKey.escape)],
    ),
    // 控件级：可聚焦控件自身的激活键（与 `ActivateIntent` 同源语义）。
    LmShortcut(
      id: idControlActivate,
      description: 'Activate the focused control',
      scope: LmShortcutScope.control,
      combos: [
        LmKeyCombo(LogicalKeyboardKey.enter),
        LmKeyCombo(LogicalKeyboardKey.space),
      ],
    ),
  ];

  static final Map<String, LmShortcut> _byId = <String, LmShortcut>{
    for (final shortcut in registry) shortcut.id: shortcut,
  };

  /// 全量注册项。
  static Iterable<LmShortcut> get all => registry;

  /// 按 id 取注册项；未注册返回 null。
  static LmShortcut? maybeById(String id) => _byId[id];

  /// 按 id 取注册项；未注册即断言失败（debug）/ 抛错（release）。
  static LmShortcut byId(String id) {
    final shortcut = _byId[id];
    if (shortcut == null) {
      throw ArgumentError.value(id, 'id', 'unregistered shortcut id');
    }
    return shortcut;
  }

  /// 取某作用域下的全部注册项（顺序与 [registry] 一致）。
  static Iterable<LmShortcut> inScope(LmShortcutScope scope) =>
      registry.where((s) => s.scope == scope);

  /// 展开成 `Shortcuts` 用的 `activator → Intent` 表。
  ///
  /// 控件级消费点（玻璃工厂的 Enter/Space 激活）用这个，而不是自己拼
  /// `SingleActivator` 字面量——键位仍由本表决定。
  static Map<ShortcutActivator, Intent> intentBindings(
    String id,
    Intent intent,
  ) =>
      <ShortcutActivator, Intent>{
        for (final activator in byId(id).activators) activator: intent,
      };

  /// 冲突检测：**同一作用域内**两个注册项落到同一组按键上即返回冲突描述。
  ///
  /// 守卫断言本方法恒为空——这张表一旦烂掉（比如新增键位撞车）就立刻红。
  static List<String> conflicts() {
    final owner = <String, String>{};
    final duplicates = <String>[];
    for (final shortcut in registry) {
      for (final combo in shortcut.combos) {
        final key = '${shortcut.scope.name}/${combo.signature}';
        final prior = owner[key];
        if (prior == null) {
          owner[key] = shortcut.id;
        } else {
          duplicates.add('$key: $prior vs ${shortcut.id}');
        }
      }
    }
    return duplicates;
  }

  /// 同一作用域下重复登记的 id（id 必须全局唯一）。
  static List<String> duplicateIds() {
    final seen = <String>{};
    final duplicates = <String>[];
    for (final shortcut in registry) {
      if (!seen.add(shortcut.id)) duplicates.add(shortcut.id);
    }
    return duplicates;
  }

  /// 键位清单表（Markdown）：键位 / 作用 / 作用域 / id。
  ///
  /// 出图与文档侧用它生成「可发现性」交付物，避免手抄走样。
  static String keymapMarkdown() {
    final buffer = StringBuffer()
      ..writeln('| Key | Action | Scope | id |')
      ..writeln('|---|---|---|---|');
    for (final shortcut in registry) {
      buffer.writeln(
        '| `${shortcut.keysLabel}` | ${shortcut.description} '
        '| `${shortcut.scope.name}` | `${shortcut.id}` |',
      );
    }
    return buffer.toString();
  }
}

/// 统一消费包装件：把注册表项与处理函数接在一起。
///
/// 页面不再裸写 `CallbackShortcuts`：声明「我在哪个作用域」+「这些 id 我处理」，
/// 键位与平台变体全部来自 [LmShortcuts.registry]。
///
/// - **只安装提供了处理函数的注册项**——「条件绑定」的统一写法就是条件性地
///   往 [handlers] 里放条目（例如会话内搜索条可见时才处理
///   [LmShortcuts.idSessionSearchClose]），不再写 `if (visible) ... : ...`。
/// - **未注册的 id 直接抛错**（不是静默失效）：拼错的 id 在第一次构建时就炸。
/// - **同作用域重复绑定在 debug 直接断言失败**：与 `LmShortcuts.conflicts()`
///   同一条不变量，但在这里当场拦下（防止只在测试里才被发现）。
/// - [autofocus] 为真时（默认）在子树里放一个自动获焦的 [Focus] 作为键事件的
///   起点；该节点 `skipTraversal: true`，**不占 Tab 停靠点**（焦点遍历顺序由
///   `lm_focus_order.dart` 显式声明，不该被快捷键壳多加一站）。
///
/// ## 为什么是 `Focus.onKeyEvent` 而不是 `Shortcuts` + `Actions`
///
/// 直觉写法是 `Shortcuts(shortcuts: 表) + Actions({LmShortcutIntent: ...})`，但
/// **嵌套时会互相吞键**：`Actions.maybeFind` 按 Intent 的**运行时类型**在最近祖先
/// 里命中（`_castAction` 只看 `actions[intent.runtimeType]` 有没有登记，
/// **不看 `isEnabled`**，命中即止）。注册表是「一个 Intent 类型 + id 区分」，
/// 于是**内层 host 会替外层 host 接收全部 `LmShortcutIntent`**——`handlers[id]`
/// 取不到就静默 no-op 并返回 `handled`，外层再也收不到：
///
/// - 会话页（session host）一打开，壳层（app host）的 `Ctrl/Cmd+N`、
///   `Ctrl/Cmd+K` 就全哑了；
/// - 全局搜索浮层的 host 会让统一浮层入口的 Esc 失效（Esc 被吞掉，对话框关不掉）。
///
/// 用 `Focus.onKeyEvent` 自行裁定则没有这个问题：**绑定里没有的键返回
/// `KeyEventResult.ignored`，事件继续沿焦点链向上冒泡**，由真正拥有该键的外层
/// host 消费——这也让 [LmShortcutScope] 的分层在运行时真正成立（越靠内层优先级
/// 越高，与调用点直觉一致）。为了不重造轮子，按键匹配仍复用框架的
/// [SingleActivator.accepts]（含 `includeRepeats` 与平台修饰键口径），
/// 只是把「命中谁」交给冒泡而不是最近的 `Actions`。
class LmShortcutHost extends StatelessWidget {
  const LmShortcutHost({
    required this.scope,
    required this.handlers,
    required this.child,
    this.autofocus = true,
    super.key,
  });

  /// 本包装件生效的作用域（只安装该作用域下的注册项）。
  final LmShortcutScope scope;

  /// 注册项 id → 处理函数。
  final Map<String, VoidCallback> handlers;

  final Widget child;

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    // ⚠️ 绑定表必须在 assert **之外**构建：assert 在 release 会被剥掉，
    // 把建表放进 assert 会让生产包一个快捷键都不生效。下面两条自检同样不包
    // assert —— 它们是这张表「不烂掉」的当场防线，release 也应当拦下。
    // （错误文案用 ASCII：本文件受仓库中文字面量门禁约束。）
    final bindings = <SingleActivator, String>{};
    final owner = <String, String>{};
    for (final id in handlers.keys) {
      final shortcut = LmShortcuts.maybeById(id);
      if (shortcut == null) {
        throw ArgumentError.value(id, 'handlers', 'unregistered shortcut id');
      }
      if (shortcut.scope != scope) {
        throw FlutterError(
          'LmShortcutHost scope mismatch: $id belongs to '
          '${shortcut.scope.name}, but this host declares ${scope.name}.',
        );
      }
      for (final combo in shortcut.combos) {
        final signature = '${scope.name}/${combo.signature}';
        final prior = owner[signature];
        if (prior != null) {
          throw FlutterError(
            'Duplicate shortcut binding in scope ${scope.name}: '
            '$id and $prior both bind ${combo.label}.',
          );
        }
        owner[signature] = id;
        for (final activator in combo.activators) {
          bindings[activator] = id;
        }
      }
    }

    return Focus(
      autofocus: autofocus,
      canRequestFocus: autofocus,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        for (final entry in bindings.entries) {
          if (entry.key.accepts(event, HardwareKeyboard.instance)) {
            handlers[entry.value]?.call();
            return KeyEventResult.handled;
          }
        }
        // 不认识的键**必须**放行：内层 host 只该消费自己绑定过的键，
        // 其余交给外层（见类注释里 `Actions.maybeFind` 吞键的坑）。
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
