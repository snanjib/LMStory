import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/services/file_drop_receiver.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/brand_logo.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/system/lm_focus_order.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_shortcuts.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/mac_window_close_guard.dart';
import 'package:lmstory/core/widgets/file_drop_scope.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/advanced/presentation/pages/advanced_chat_page.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/chat_mode_page.dart';
import 'package:lmstory/features/chat/presentation/pages/home_page.dart';
import 'package:lmstory/features/chat/presentation/widgets/chat_sidebar.dart';
import 'package:lmstory/features/chat/presentation/widgets/global_search_dialog.dart';
import 'package:lmstory/features/director_wizard/domain/entities/director_wizard_outcome.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart';
import 'package:lmstory/features/intermediate/presentation/intermediate_mode_flag.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_page.dart';
import 'package:lmstory/features/onboarding/presentation/controllers/onboarding_controller.dart';
import 'package:lmstory/features/onboarding/presentation/pages/onboarding_page.dart';
import 'package:lmstory/features/resource_library/presentation/widgets/incoming_import_listener.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:uuid/uuid.dart';

/// 导演模式"生成中"判定：非 idle/failed 即视为进行中（阶段缺口，
/// 2026-08-24）。旧集合只含 generating/reviewing 两族，漏掉
/// extracting/summarizing/compacting 等 LLM 流式阶段——这些阶段里呼吸点
/// 消失、删除不受拦截，轮次随后向已删会话写回孤儿数据。
bool isAdvancedGenerating(AdvancedChatState state) {
  // 手动压缩全程 phase 恒为 idle——必须显式计入，否则压缩的
  /// LLM 流式+落库窗口内会话不被视为生成中（呼吸点不亮/可被删）
  return state.isManualCompacting ||
      (state.phase != IntermediatePhase.idle &&
          state.phase != IntermediatePhase.failed);
}

/// 中级模式"生成中"判定：非 idle/failed 即视为进行中（同上）。
bool isIntermediateGenerating(IntermediateChatState state) {
  // OH-1：故事模式手动压缩与导演侧同构——
  /// manualCompact() 全程只置 isManualCompacting 不改 phase，漏判会让
  /// 压缩的 LLM 流式+落库窗口内呼吸点不亮、侧边栏删除放行、删后孤儿落库
  return state.isManualCompacting ||
      (state.phase != IntermediatePhase.idle &&
          state.phase != IntermediatePhase.failed);
}

/// 对话模式"生成中"判定（完整忙集合，与 chat_mode_page 菜单
/// 守卫同口径）。 批1从三处内联条件收编为顶层函数：
/// `_trackGeneratingSessions` 与呼吸点 listen 守卫共用。
bool isChatGenerating(ChatModeState state) =>
    state.isSending || state.isStreaming || state.isCompressing;

/// OH-5：移动端会话点选是否需要压栈——与栈顶为同一会话
/// 时返回 false（重复点选 no-op）。无此守卫时抽屉中再点当前已打开的
/// 会话会无限压栈（[null, A, A]），系统返回键需按 N 次才能退出。
bool shouldPushMobileSession(List<ChatSession?> stack, ChatSession session) {
  if (stack.isEmpty) return true;
  return stack.last?.sessionId != session.sessionId;
}

/// LRU 淘汰纯逻辑——超出容量的最久未访问且非豁免
/// 会话即淘汰候选；全豁免时不强制挤出（下次访问再试）。与 main_layout
/// 状态接线分离，便于行为测试。
List<T> lruEvictCandidates<T>(
  List<T> lru,
  int capacity,
  bool Function(T) isExempt,
) {
  if (lru.length <= capacity) return const [];
  final victims = <T>[];
  var budget = lru.length - capacity;
  for (final item in lru) {
    if (budget <= 0) break;
    if (isExempt(item)) continue;
    victims.add(item);
    budget--;
  }
  return victims;
}

/// 主布局：侧边栏 + 主内容区。
///
/// 导航模型：
/// - 导航栈 _navigationStack：null = 主界面，ChatSession = 会话（含草稿）
/// - 桌面端：侧边栏始终可见，点击会话 = replace 当前会话
/// - 移动端：侧边栏为 Drawer，点击会话 = push 到导航栈（支持无限回退）
/// - 草稿会话：点击"新建对话"时创建临时会话（不入库），发送首条消息时才入库
/// - 返回键：移动端依次回退导航栈，主界面两次返回退出
class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key});

  /// 桌面壳判定（纯函数便于行为锁测试）：
  /// 原生桌面平台恒桌面壳（窄窗由侧栏自动收起适配，不换壳——
  /// 换壳会令全局快捷键静默失效、侧栏变抽屉、出现触屏语义）；
  /// Web 与移动平台保持宽度响应式。
  @visibleForTesting
  static bool isMobileShell({
    required double width,
    required double breakpoint,
    required bool isWeb,
    required TargetPlatform platform,
  }) {
    if (!isWeb &&
        (platform == TargetPlatform.macOS ||
            platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux)) {
      return false;
    }
    return width < breakpoint;
  }

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout>
    with WidgetsBindingObserver {
  /// 侧栏宽度与移动/桌面壳分流的断点都取自大屏口径单源 [LmLayout]。
  static const double _sidebarWidth = LmLayout.sidebarWidth;
  static const double _mobileBreakpoint = LmLayout.compactMax;

  /// 导航栈：null = 主界面，ChatSession = 会话（包括草稿）
  final List<ChatSession?> _navigationStack = [null];

  /// 桌面 replace 切走但仍可能在后台生成的会话：
  /// 生成中判定/禁删守卫/后台中断治理此前只遍历导航栈，桌面端
  /// 栈内最多一个会话——切走后的后台流式会话脱离呼吸点、可被删除、
  /// 切后台不被取消。集合在会话回到 idle/failed 时自动清理。
  final Set<ChatSession> _backgroundSessions = {};

  /// 侧边栏可见性（桌面端）
  bool _sidebarVisible = true;

  /// LRU 有序会话表（最近访问在尾，容量 8）——
  /// 三模式控制器均 non-autoDispose family，不淘汰则每会话全量 messages
  /// 常驻内存。淘汰只 invalidate 完全静止的会话（豁免：导航栈/后台跟踪
  /// 集合/非 idle（含 failed）/chat 后台生成）——静止会话无在途异步回调，
  /// dispose 后无 use-after-dispose 窗口。
  final List<ChatSession> _lruSessions = [];
  static const int _lruCapacity = 8;

  /// Scaffold key（移动端控制 Drawer）
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 主界面两次返回退出的时间戳
  DateTime? _lastBackPress;

  /// 待定位消息：全局搜索命中进入会话时非空，
  /// 由 _selectSession 设置、构建会话页时传入并消费。
  String? _focusMessageId;

  /// 长驻进程的自动备份周期补查定时器（非 Web 平台）
  Timer? _autoBackupTimer;

  /// 侧边栏刷新信号（变化时触发侧边栏重新加载会话列表）
  int _sidebarRefreshSignal = 0;

  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    //  自动备份：首帧后延迟静默检查（>24h 且有会话数据才导出，
    // 不打扰启动渲染；path_provider 不支持 Web，跳过）。
    // 失败由管理器内部吞掉并记日志，绝不影响启动。
    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(seconds: 20), () {
          if (!mounted) return;
          ref.read(autoBackupManagerProvider).runIfNeeded();
        });
      });
      // 长驻进程周期补查——桌面常开不重启的进程
      // 此前永远停在启动后 20s 那一次检查，「24h 间隔」承诺对长会话失效。
      // 每 6h 醒来一次跑 runIfNeeded（间隔/开关/空库三条件仍由管理器
      // 把关，未到 24h 自然空转），退出随 State dispose 取消。
      _autoBackupTimer = Timer.periodic(const Duration(hours: 6), (_) {
        if (!mounted) return;
        ref.read(autoBackupManagerProvider).runIfNeeded();
      });
    }

    // macOS 关窗拦截：生成中点 ×/Cmd+W 先弹确认，防整轮内容静默丢失
    //（助手消息只在完成时落库，杀进程即丢当轮）。其他平台无原生端，零开销。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      MacWindowCloseGuard.register(
        isBusy: () async => mounted && _isAnySessionGenerating(),
        showConfirm: () async {
          if (!mounted) return true;
          final t = Translations.of(context);
          final colors = context.lm.palette;
          final confirmed = await showLmDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(
                t.common.closeWhileGeneratingTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              content: Text(
                t.common.closeWhileGeneratingBody,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(t.common.closeWhileGeneratingKeep),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.error,
                  ),
                  child: Text(t.common.closeWhileGeneratingConfirm),
                ),
              ],
            ),
          );
          return confirmed ?? false;
        },
      );
    }
  }

  @override
  void dispose() {
    _autoBackupTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.paused ||
        // 桌面端切后台只发 hidden 不发
        // paused， 的后台取消在桌面从未触发——hidden（最小化）按同路径
        // 处理；Web 排除（浏览器切标签网络通常仍在，沿用 resumed 延迟检查）
        (appState == AppLifecycleState.hidden && !kIsWeb)) {
      // App 切到后台：主动取消正在进行的 SSE 流，防止 OS 暂停网络后
      // readTimeout 超时触发自动重试（中级模式 _scheduleRetry），
      // 导致回到前台后"从中断步骤继续生成"且上下文可能不完整。
      _handleAppPaused();
    } else if (appState == AppLifecycleState.resumed) {
      // App 从后台恢复：检测会话卡死状态并自动恢复
      if (kIsWeb) {
        // Web 平台：浏览器切标签页/最小化不会真正暂停网络（SSE 流通常仍在工作），
        // 立即检查会误判中断。延迟 60 秒检查，只在真正卡死时才恢复。
        Future.delayed(const Duration(seconds: 60), () {
          if (mounted &&
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed) {
            _handleAppResumed();
          }
        });
      } else {
        // 回前台顺手补一次自动备份检查——iOS 挂起期间 Timer 停摆，
        // 「每次前台不足 20 秒」的轻度用户启动检查与 6h 周期双双落空；
        // 间隔/开关/空库三条件仍由管理器把关，未到点自然空转。
        ref.read(autoBackupManagerProvider).runIfNeeded();
        _handleAppResumed();
      }
    }
  }

  /// App 切到后台时，主动取消导航栈中所有会话正在进行的 SSE 流。
  ///
  /// 为什么需要在 paused 时主动取消：
  /// 中级模式 SSE 超时后 `_fail` 会触发 `_scheduleRetry` 自动重试，
  /// 重试发起的新 SSE 请求会让 `recoverIfStuck`（resumed 时调用）的
  /// `isStreaming == true` 检测失效，导致用户回到前台后看到
  /// "从中断步骤继续生成"--实际是自动重试在使用可能不完整的
  /// `_round` 上下文（如 compacting 修改了 history 但未持久化）生成。
  ///
  /// 主动取消后 `_streamRunner.isCancelled = true`，`_fail` 的 guard
  /// 直接返回不重试；resumed 时 `recoverIfStuck` 干净重置到 idle。
  void _handleAppPaused() {
    for (final session in _governedSessions()) {
      if (_usesAdvancedKernel(session)) {
        ref
            .read(advancedChatControllerProvider(session).notifier)
            .onBackgroundInterrupt();
      } else if (_usesIntermediateKernel(session)) {
        ref
            .read(intermediateChatControllerProvider(session).notifier)
            .onBackgroundInterrupt();
      } else {
        ref
            .read(chatModeControllerProvider(session).notifier)
            .onBackgroundInterrupt();
      }
    }
  }

  /// App 从后台恢复时，检测导航栈中所有会话的生成状态。
  ///
  /// 场景：用户生成中切到后台 → OS 暂停网络 → 30s 超时误杀 SSE 流 →
  /// 流死但 controller 状态卡在 generating/reviewing（Intermediate）或
  /// isStreaming=true（Simple）。切回前台时自动检测并恢复到可操作状态。
  ///
  /// 恢复后显示 toast 提示用户"后台生成已中断，请重新发送"。
  /// 用户的消息历史不丢失（clearTemporary/copyWith 仅清临时字段）。
  void _handleAppResumed() {
    var anyRecovered = false;
    for (final session in _governedSessions()) {
      final recovered = _usesAdvancedKernel(session)
          ? ref
              .read(advancedChatControllerProvider(session).notifier)
              .recoverIfStuck()
          : _usesIntermediateKernel(session)
              ? ref
                  .read(intermediateChatControllerProvider(session).notifier)
                  .recoverIfStuck()
              : ref
                  .read(chatModeControllerProvider(session).notifier)
                  .recoverIfStuck();
      if (recovered) anyRecovered = true;
    }
    if (anyRecovered && mounted) {
      final t = Translations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.chat.backgroundInterrupted,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 桌面原生平台恒桌面壳：此前纯宽度分流，窗口拖窄到断点下整个壳切
  /// 「移动壳」——侧栏变抽屉、全局快捷键（LmShortcutHost 只包桌面分支）
  /// 静默失效、出现触屏语义（汉堡/双击退出）。窄窗改由侧栏自动收起
  /// 腾出内容宽度（[_sidebarForceHidden]），不再换壳。Web 保持宽度响应式。
  bool get _isMobile => MainLayout.isMobileShell(
        width: MediaQuery.of(context).size.width,
        breakpoint: _mobileBreakpoint,
        isWeb: kIsWeb,
        platform: defaultTargetPlatform,
      );

  /// 桌面窄窗强制收侧栏：窗口容不下「侧栏+最小内容宽」时自动收起，
  /// 用户仍可用汉堡手动展开（展开后内容区自行变窄适配）。
  bool get _sidebarForceHidden =>
      !_isMobile &&
      MediaQuery.of(context).size.width <= _mobileBreakpoint + _sidebarWidth;

  /// 侧栏当前是否显示（用户开关 && 窗口宽度未触发强制收起）。
  bool get _sidebarShown => _sidebarVisible && !_sidebarForceHidden;

  /// 该会话是否走故事模式内核（intermediate 控制器）。
  bool _usesIntermediateKernel(ChatSession session) =>
      session.mode == ChatMode.intermediate;

  /// 该会话是否走导演模式内核（advanced 控制器）。
  ///
  /// P2 解耦后 advanced（导演模式）有独立控制器/页面；
  /// 所有"选控制器/监听状态"的分支须分别匹配两种 mode。
  bool _usesAdvancedKernel(ChatSession session) =>
      session.mode == ChatMode.advanced;

  /// 当前导航栈顶部的会话（null 表示在主界面）
  ChatSession? get _currentSession =>
      _navigationStack.isNotEmpty ? _navigationStack.last : null;

  /// 当前会话的真实 sessionId（从 controller.state.session 读取）。
  ///
  /// 2026-07-22 新增：物化后 nav stack 仍是 draft id（family provider key 不变），
  /// 但 controller.state.session 已是 real id。侧边栏选中状态、呼吸点等需要
  /// 用 real id 与 DB 数据匹配的场景，必须用此 getter 而非 _currentSession?.sessionId。
  ///
  /// 草稿未物化时返回 draft id（侧边栏不匹配任何会话，正确：草稿不在列表中）。
  String? get _realCurrentSessionId {
    final current = _currentSession;
    if (current == null) return null;
    if (_usesAdvancedKernel(current)) {
      return ref
          .read(advancedChatControllerProvider(current))
          .session
          .sessionId;
    }
    if (_usesIntermediateKernel(current)) {
      return ref
          .read(intermediateChatControllerProvider(current))
          .session
          .sessionId;
    }
    return ref.read(chatModeControllerProvider(current)).session.sessionId;
  }

  /// 刷新当前选中的会话（从数据库重新加载，用于 rename/auto-naming 后同步）
  ///
  /// 2026-07-22 修复：用 controller.state.session.sessionId（物化后的真实 id）
  /// 判断是否草稿，而非 nav stack 的 sessionId。物化后 nav stack 仍是 draft id，
  /// 但 controller.state.session 已是 real id。若用 draft id 判断，物化后永远
  /// 跳过，无法从 DB 刷新（auto-naming 后标题不同步）。
  ///
  /// 注意：仅在 nav stack sessionId == real sessionId（非草稿场景）时更新 nav stack。
  /// 草稿物化场景（nav stack 是 draft id，real sessionId 不同）不更新 nav stack，
  /// 因为 sessionId 变化会导致 family provider key 不匹配（ChatSession.== 基于
  /// sessionId），创建空的新 controller。草稿物化场景通过 _sidebarRefreshSignal
  /// 刷新侧边栏即可，chat page 标题通过 ref.watch(controller) 自动同步。
  Future<void> _refreshCurrentSession() async {
    final current = _currentSession;
    if (current == null) {
      // 主页态（无当前会话）下侧边栏的删除/收藏/
      // 重命名也要递增信号——此前直接 return，主页"最近会话"不回写，
      // 已删会话仍显示在主页且点击进入已删会话
      if (mounted) {
        setState(() => _sidebarRefreshSignal++);
      }
      return;
    }
    final realSessionId = _realCurrentSessionId;
    if (realSessionId == null) return;
    // 未物化的草稿会话跳过（DB 中无对应记录）
    if (realSessionId.startsWith(ChatModeController.draftSessionIdPrefix) ||
        realSessionId
            .startsWith(IntermediateChatController.draftSessionIdPrefix)) {
      return;
    }
    final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
    final sessions = await chatRepo.getAllSessions();
    final updated = sessions.where((s) => s.sessionId == realSessionId);
    if (updated.isNotEmpty && mounted) {
      final fresh = updated.first;
      setState(() {
        // 仅在 nav stack sessionId == real sessionId 时更新（非草稿场景）。
        // 草稿物化场景不更新 nav stack（sessionId 变化会导致 key 不匹配）。
        if (_navigationStack.isNotEmpty) {
          final lastSession = _navigationStack.last;
          if (lastSession != null && lastSession.sessionId == realSessionId) {
            _navigationStack[_navigationStack.length - 1] = fresh;
          }
        }
        // 无论是否更新 nav stack，都触发 sidebar 刷新
        _sidebarRefreshSignal++;
      });
      // 主区标题读 controller state 的会话值拷贝，
      // ChatSession == 只看 sessionId，替换 nav stack 值不会重建 provider
      // ——把持久化后的标题回填进打开中的 controller，标题才跟着刷新。
      // family key 必须用导航栈对象 current——就地
      // 新建的会话物化后 nav stack 仍是 draft id，页面 watch 的是 draft
      // key 的 provider；此前用 fresh（real id）会 read 出一个无人监听、
      // 非 autoDispose 的幽灵 controller（每次触发再造一个，永不回收），
      // 主区标题永远收不到（根因）。
      if (_usesAdvancedKernel(current)) {
        ref
            .read(advancedChatControllerProvider(current).notifier)
            .applyExternalTitle(fresh.title);
      } else if (_usesIntermediateKernel(current)) {
        ref
            .read(intermediateChatControllerProvider(current).notifier)
            .applyExternalTitle(fresh.title);
      } else {
        ref
            .read(chatModeControllerProvider(current).notifier)
            .applyExternalTitle(fresh.title);
      }
    }
  }

  /// 进入会话时记录 LRU 并尝试淘汰空闲会话
  void _touchLru(ChatSession session) {
    if (session.sessionId.startsWith(ChatModeController.draftSessionIdPrefix) ||
        session.sessionId.startsWith(
          IntermediateChatController.draftSessionIdPrefix,
        )) {
      return; // 草稿不入表（未入库，且恒在导航栈内被豁免）
    }
    _lruSessions
      ..removeWhere((s) => s.sessionId == session.sessionId)
      ..add(session);
    for (final victim
        in lruEvictCandidates(_lruSessions, _lruCapacity, _isLruExempt)) {
      _lruSessions.removeWhere((s) => s.sessionId == victim.sessionId);
      if (_usesAdvancedKernel(victim)) {
        ref.invalidate(advancedChatControllerProvider(victim));
      } else if (_usesIntermediateKernel(victim)) {
        ref.invalidate(intermediateChatControllerProvider(victim));
      } else {
        ref.invalidate(chatModeControllerProvider(victim));
      }
    }
  }

  /// LRU 豁免：导航栈/后台跟踪集合内，或任一「非静止」态（非 idle 全算
  ///——含 failed 重试面与手动压缩窗口；chat 后台生成）
  bool _isLruExempt(ChatSession session) {
    if (_navigationStack.any((s) => s?.sessionId == session.sessionId)) {
      return true;
    }
    if (_backgroundSessions.any((s) => s.sessionId == session.sessionId)) {
      return true;
    }
    if (_usesAdvancedKernel(session)) {
      final state = ref.read(advancedChatControllerProvider(session));
      return state.isManualCompacting || state.phase != IntermediatePhase.idle;
    }
    if (_usesIntermediateKernel(session)) {
      final state = ref.read(intermediateChatControllerProvider(session));
      return state.isManualCompacting || state.phase != IntermediatePhase.idle;
    }
    final state = ref.read(chatModeControllerProvider(session));
    return state.isSending ||
        state.isStreaming ||
        state.isCompressing ||
        state.isGeneratingInBackground;
  }

  /// 是否有任一会话正在生成/压缩（含桌面 replace 切到后台的会话）。
  /// macOS 关窗拦截据此决定是否弹确认；三模式生成态判定与
  /// [_isLruExempt] 的 LRU 豁免同源同口径。
  bool _isAnySessionGenerating() {
    final sessions = <ChatSession>{
      ..._navigationStack.whereType<ChatSession>(),
      ..._backgroundSessions,
    };
    bool busy(ChatSession session) {
      if (_usesAdvancedKernel(session)) {
        final state = ref.read(advancedChatControllerProvider(session));
        return state.isManualCompacting ||
            state.phase != IntermediatePhase.idle;
      }
      if (_usesIntermediateKernel(session)) {
        final state = ref.read(intermediateChatControllerProvider(session));
        return state.isManualCompacting ||
            state.phase != IntermediatePhase.idle;
      }
      final state = ref.read(chatModeControllerProvider(session));
      return state.isSending ||
          state.isStreaming ||
          state.isCompressing ||
          state.isGeneratingInBackground;
    }

    return sessions.any(busy);
  }

  /// 当前是否停在对话（chat）会话——拖放附件的唯一投放场景
  /// （故事/导演会话与主界面走资源导入语义）。
  bool get _isChatSessionActive {
    final current = _currentSession;
    return current != null &&
        !_usesAdvancedKernel(current) &&
        !_usesIntermediateKernel(current);
  }

  /// macOS 拖入文件分发：对话会话→附件注入（pendingDropFilesProvider，
  /// 由输入区消费）；其他场景 PNG/JSON→既有外部导入确认链
  /// （incomingFileEventsProvider）；其余类型提示不支持。
  void _handleDroppedFiles(List<IncomingFile> files) {
    if (files.isEmpty) return;
    final inChat = _isChatSessionActive;
    final actions = FileDropRouting.route(
      inChatSession: inChat,
      fileNames: [for (final f in files) f.fileName],
    );

    final attachments = <IncomingFile>[];
    var imported = 0;
    var unsupported = 0;
    String? unsupportedName;
    for (var i = 0; i < files.length; i++) {
      switch (actions[i]) {
        case FileDropAction.attachment:
          attachments.add(files[i]);
        case FileDropAction.import:
          // 注入既有事件流：IncomingImportListener 弹确认并按
          // 角色卡/世界书/备份分流（emitExternal 绕过双来源去重）
          ref.read(incomingFileReceiverProvider).emitExternal(files[i]);
          imported++;
        case FileDropAction.unsupported:
          unsupported++;
          unsupportedName ??= files[i].fileName;
      }
    }
    if (attachments.isNotEmpty) {
      ref.read(pendingDropFilesProvider.notifier).state = attachments;
    }

    final t = Translations.of(context);
    if (!inChat && imported > 0) {
      // 故事/导演会话或主界面拖入资源文件：说明附件语义不可用
      _snack(t.chat.attachment.dropModeNoAttachment);
    }
    if (unsupported > 0) {
      _snack(
        t.settings.resourceLibrary.dropUnsupportedType(
          name: unsupportedName ?? '',
        ),
      );
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 选择会话：桌面端 replace，移动端 push（支持无限回退）
  ///
  /// [focusMessageId]：全局搜索命中进入时携带，
  /// 会话页据此滚动定位+高亮命中消息；普通进入为 null。
  void _selectSession(ChatSession session, {String? focusMessageId}) {
    // 桌面 replace 会把当前会话挤出导航栈——若它仍在生成
    ///（非 autoDispose controller 后台续跑），纳入跟踪集合保住
    /// 呼吸点/禁删/后台中断治理
    _focusMessageId = focusMessageId;
    if (!_isMobile) {
      final replaced = _navigationStack.last;
      if (replaced != null && replaced.sessionId != session.sessionId) {
        _backgroundSessions.add(replaced);
      }
    }
    setState(() {
      if (_isMobile) {
        // OH-5：同一会话重复点选 no-op（仍刷新侧边栏/关抽屉），防无限压栈
        if (shouldPushMobileSession(_navigationStack, session)) {
          _navigationStack.add(session);
        }
      } else {
        if (_navigationStack.length <= 1) {
          _navigationStack.add(session);
        } else {
          _navigationStack[_navigationStack.length - 1] = session;
        }
      }
      _sidebarRefreshSignal++;
    });
    _touchLru(session);
  }

  /// 新建对话：创建草稿会话（不入库），发送首条消息时才入库
  void _startNewChat() {
    final t = Translations.of(context);
    final settingsState = ref.read(settingsNotifierProvider);
    final draftSession = ChatSession(
      sessionId: '${ChatModeController.draftSessionIdPrefix}${_uuid.v4()}',
      title: t.chat.draft.title,
      mode: ChatMode.chat,
      createdAt: DateTime.now(),
      lastActiveAt: DateTime.now(),
      messageCount: 0,
      modelId: settingsState.defaultModelId,
      presetId: settingsState.defaultPresetId,
    );
    _selectSession(draftSession);
  }

  /// 新建故事：创建中级模式草稿会话（不入库），发送首条消息时才入库
  void _startNewStory() {
    final t = Translations.of(context);
    final settingsState = ref.read(settingsNotifierProvider);
    final draftSession = ChatSession(
      sessionId:
          '${IntermediateChatController.draftSessionIdPrefix}${_uuid.v4()}',
      // 草稿页专用标题（「新故事」），对齐三模式草稿命名
      title: t.intermediate.draft.title,
      mode: 'intermediate',
      createdAt: DateTime.now(),
      lastActiveAt: DateTime.now(),
      messageCount: 0,
      modelId: settingsState.defaultModelId,
      presetId: settingsState.defaultPresetId,
    );
    _selectSession(draftSession);
  }

  /// 新导演：创建 advanced 模式草稿会话（不入库），发送首条消息时才入库
  ///
  /// [phaseModels]：向导产出的会话级 GM 覆盖（null = 空覆盖，跟随全局）；
  /// [systemPromptOverride]：向导规则步确认产物（null = 跟随全局兜底，
  /// 传 '' 会物化成显式无规则、阻断全局回退——跳过规则必须传 null）；
  /// [characterInitPrompt]/[characterCardId]：向导「初始化你的角色」产物
  /// （描述第 1 轮一次性注入；卡在物化时应用并留档 id）。
  void _startNewDirector({
    SessionPhaseModels? phaseModels,
    String? systemPromptOverride,
    String? characterInitPrompt,
    String? characterCardId,
  }) {
    final t = Translations.of(context);
    final settingsState = ref.read(settingsNotifierProvider);
    final draftSession = ChatSession(
      sessionId:
          '${IntermediateChatController.draftSessionIdPrefix}${_uuid.v4()}',
      title: t.advanced.home.newDirector,
      mode: 'advanced',
      createdAt: DateTime.now(),
      lastActiveAt: DateTime.now(),
      messageCount: 0,
      modelId: settingsState.defaultModelId,
      presetId: settingsState.defaultPresetId,
      phaseModels: phaseModels ?? const SessionPhaseModels.empty(),
      systemPromptOverride: systemPromptOverride,
      characterInitPrompt: characterInitPrompt,
      characterInitCardId: characterCardId,
    );
    _selectSession(draftSession);
  }

  /// 导演模式向导入口（2026-10-17 需求）：push 全屏三步向导，
  /// 走完携带产物建配置就绪的导演草稿会话；跳过/中退即弃（无产物）。
  Future<void> _startDirectorWizard() async {
    final outcome = await Navigator.of(context).push<DirectorWizardOutcome>(
      MaterialPageRoute<DirectorWizardOutcome>(
        builder: (_) => const DirectorWizardPage(),
      ),
    );
    if (!mounted || outcome == null) return;
    _startNewDirector(
      phaseModels: outcome.phaseModels,
      systemPromptOverride: outcome.systemPromptOverride,
      characterInitPrompt: outcome.characterInitPrompt,
      characterCardId: outcome.characterCardId,
    );
  }

  /// 返回上一个导航点
  void _popNavigation() {
    // 出栈会话若在生成（非 autoDispose controller
    /// 后台续跑），纳入跟踪集合—— 只盖住 _selectSession 的 replace
    /// 路径，系统返回键这条高频路径此前让会话逃逸治理视图（呼吸点消失/
    /// 禁删失明/后台中断治理失守）
    if (_navigationStack.length > 1) {
      final popped = _navigationStack.last;
      if (popped != null) {
        _backgroundSessions.add(popped);
      }
    }
    // 深链焦点只对本次导航有效——返回后不清会让
    /// 陈旧 id 残留到下一个进入的会话，吞掉其定位恢复（页面深链分支
    /// early return，消息 id 不匹配则静默不定位）
    _focusMessageId = null;
    setState(() {
      if (_navigationStack.length > 1) {
        _navigationStack.removeLast();
      }
      _sidebarRefreshSignal++;
    });
  }

  /// 返回主界面（清空导航栈到 null）
  void _goHome() {
    // 清栈前把所有生成中会话纳入跟踪（与 _popNavigation 同理）
    for (final session in _navigationStack) {
      if (session != null) {
        _backgroundSessions.add(session);
      }
    }
    // 同 _popNavigation——陈旧深链焦点不得跨导航残留
    _focusMessageId = null;
    setState(() {
      _navigationStack
        ..clear()
        ..add(null);
      _sidebarRefreshSignal++;
    });
  }

  Future<void> _onSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
    // 与 HomePage footer 设置入口同款——返回后刷新侧边栏与首页
    ///（Key 配置变化影响黄条/最近会话；此前此路径 fire-and-forget）
    if (!mounted) return;
    setState(() => _sidebarRefreshSignal++);
  }

  void _onHamburgerPressed() {
    if (_isMobile) {
      _scaffoldKey.currentState?.openDrawer();
    } else if (_sidebarForceHidden) {
      // 桌面窄窗：侧栏被宽度判定强制收起，_sidebarVisible 已是 true，
      // 走内嵌侧栏永远弹不出（汉堡按钮曾因此永远无效）——与移动端
      // 同构改开抽屉（抽屉在 _buildMainContentPage 条件挂载）。
      _scaffoldKey.currentState?.openDrawer();
    } else {
      setState(() => _sidebarVisible = true);
    }
  }

  /// 移动端返回键处理：
  /// 1. Drawer 打开 → 关闭 Drawer
  /// 2. 在会话中 → 返回上一个导航点
  /// 3. 在主界面 → 两次返回退出
  void _onPopInvoked(bool didPop) {
    if (didPop) return;

    // 1. Drawer 打开时，优先关闭 Drawer
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      _scaffoldKey.currentState?.closeDrawer();
      return;
    }

    // 2. 导航栈中有会话，返回上一个
    if (_navigationStack.length > 1) {
      _popNavigation();
      return;
    }

    // 3. 在主界面，两次返回退出
    final now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            Translations.of(context).chat.home.pressBackAgain,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 首次启动新手引导（2026-07-20 新增）：
    // - isLoading：显示空白启动屏，避免引导未加载完显示主界面闪烁
    // - !completed：全屏覆盖 OnboardingPage（首次启动模式，完成时写入 completed）
    // - completed：正常显示主界面
    //
    // 注意：onboarding 期间 MainLayout 内的 ref.listen 不会注册——这是 OK 的，
    // 因为用户在 onboarding 期间不与主界面交互；onboarding 完成后 MainLayout
    // 重新构建，所有 ref.listen 自然会注册。
    final onboardingState = ref.watch(onboardingProvider);
    if (onboardingState.isLoading) {
      //  修复：prefs 读取完成前不再返回空白 SizedBox——
      // 慢设备上无反馈的白屏像闪退。改为品牌 logo + 加载指示。
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BrandLogo(size: 56),
              SizedBox(height: 24),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ],
          ),
        ),
      );
    }
    if (!onboardingState.completed) {
      return const OnboardingPage();
    }

    // 监听当前会话的 state，处理生成→真实会话的转换
    // 当草稿会话因首条消息发送而变为真实会话时，刷新侧边栏
    // 按 current.mode 选择监听 Simple 或 Intermediate 的 provider
    final current = _currentSession;
    if (current != null) {
      if (_usesAdvancedKernel(current)) {
        ref.listen<AdvancedChatState>(
          advancedChatControllerProvider(current),
          (previous, next) {
            if (previous != null &&
                (previous.session.sessionId != next.session.sessionId ||
                    // 自动命名后侧边栏/
                    // 主页标题不刷新——标题变化同样 bump 刷新信号
                    previous.session.title != next.session.title)) {
              setState(() => _sidebarRefreshSignal++);
            }
          },
        );
      } else if (_usesIntermediateKernel(current)) {
        ref.listen<IntermediateChatState>(
          intermediateChatControllerProvider(current),
          (previous, next) {
            if (previous != null &&
                (previous.session.sessionId != next.session.sessionId ||
                    // 自动命名后侧边栏/
                    // 主页标题不刷新——标题变化同样 bump 刷新信号
                    previous.session.title != next.session.title)) {
              setState(() => _sidebarRefreshSignal++);
            }
          },
        );
      } else {
        ref.listen<ChatModeState>(
          chatModeControllerProvider(current),
          (previous, next) {
            if (previous != null &&
                (previous.session.sessionId != next.session.sessionId ||
                    // 自动命名后侧边栏/
                    // 主页标题不刷新——标题变化同样 bump 刷新信号
                    previous.session.title != next.session.title)) {
              setState(() => _sidebarRefreshSignal++);
            }
          },
        );
      }
    }

    // 聚合所有导航栈会话的"生成中"状态，传给侧边栏显示呼吸点
    // 同步 ref.read 计算当前集合 + ref.listen 监听后续变化触发重建
    final generatingSessionIds = _trackGeneratingSessions();

    // macOS 文件拖放：挂在壳最外层，两壳统一接收（receiver 仅 macOS
    // 有原生端，其他平台零开销）。
    return FileDropScope(
      inChatSession: _isChatSessionActive,
      onFiles: _handleDroppedFiles,
      child: _buildShell(generatingSessionIds),
    );
  }

  Widget _buildShell(Set<String> generatingSessionIds) {
    // 外部"打开方式/分享"导入：收到文件弹确认框（onboarding 完成后生效）
    if (_isMobile) {
      return IncomingImportListener(
        child: _buildMobileLayout(generatingSessionIds),
      );
    }
    // 桌面全局快捷键：键位与平台变体全部来自 `LmShortcuts.registry`
    // （单源，不再就地手写 control / meta 两份）。焦点落任意子孙
    // （含输入框未消费的组合键）均可触发。
    return LmShortcutHost(
      scope: LmShortcutScope.app,
      handlers: {
        LmShortcuts.idNewChat: _startNewChat,
        // 故事模式入口隐藏时快捷键不响应（入口可见性单源=故事开关）
        LmShortcuts.idNewStory: () {
          if (ref.read(intermediateModeFlagProvider)) _startNewStory();
        },
        LmShortcuts.idSettings: _onSettings,
        LmShortcuts.idGlobalSearch: _openGlobalSearchFromShortcut,
      },
      child: IncomingImportListener(
        child: _buildDesktopLayout(generatingSessionIds),
      ),
    );
  }

  /// Ctrl+K 呼出全局搜索（05）：MainLayout 层直接弹
  /// GlobalSearchDialog——侧边栏折叠时（SizedBox.shrink 不构建）其内部
  /// 方法不可达，此处自持打开与结果选中。
  Future<void> _openGlobalSearchFromShortcut() async {
    await showLmDialog<void>(
      context: context,
      builder: (ctx) => GlobalSearchDialog(
        onResultSelected: (result) {
          Navigator.of(ctx).pop();
          _openSessionById(result.sessionId, focusMessageId: result.messageId);
        },
      ),
    );
    // 移除无条件 hideCurrentSnackBar——对话框关闭后
    /// 它会顺带掐断无关的活动反馈（侧边栏删除失败、后台中断 3s toast），
    /// 用户在提示展示期间按 Ctrl+K 关闭搜索即被吞。对话框自身不弹
    /// SnackBar，无清理必要。
  }

  Future<void> _openSessionById(
    String sessionId, {
    String? focusMessageId,
  }) async {
    final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
    final sessions = await chatRepo.getAllSessions();
    final match = sessions.where((s) => s.sessionId == sessionId);
    if (match.isNotEmpty && mounted) {
      _selectSession(match.first, focusMessageId: focusMessageId);
    }
  }

  /// 计算导航栈中所有正在生成的会话 ID 集合，并注册 ref.listen 以便状态
  /// 变化时触发重建（呼吸点能实时跟随 streaming 状态切换）。
  ///
  /// 设计取舍：
  /// - 遍历整个 _navigationStack（含后台会话）而非仅 current，让用户
  ///   在 A 会话页面也能看到 B 会话（后台）的呼吸点
  /// - 草稿会话（controller.state.session 仍是 draft 前缀）不参与：
  ///   未入库，侧边栏不显示
  /// - 2026-07-22 修复：用 controller.state.session.sessionId 判断是否草稿，
  ///   而非 nav stack 中的 sessionId。物化后 nav stack 仍是 draft id（key 不变），
  ///   但 controller.state.session 已是 real id。若用 nav stack 的 draft id
  ///   判断，物化后永远跳过，呼吸点不显示（bug）。
  /// - 用 controller state.session.sessionId 添加到集合：
  ///   生成→真实转换后，sidebar 按 DB 的真实 ID 显示，呼吸点需匹配真实 ID
  Set<String> _trackGeneratingSessions() {
    final ids = <String>{};
    // 后台跟踪集合中已回到 idle/failed 的会话自动出列
    _backgroundSessions.removeWhere((session) {
      if (_usesAdvancedKernel(session)) {
        final state = ref.read(advancedChatControllerProvider(session));
        return !isAdvancedGenerating(state);
      }
      if (_usesIntermediateKernel(session)) {
        final state = ref.read(intermediateChatControllerProvider(session));
        return !isIntermediateGenerating(state);
      }
      final state = ref.read(chatModeControllerProvider(session));
      // 对话模式完整忙集合（与 chat_mode_page 菜单守卫同口径）
      return !isChatGenerating(state);
    });
    for (final session in _governedSessions()) {
      if (_usesAdvancedKernel(session)) {
        final state = ref.read(advancedChatControllerProvider(session));
        if (state.session.sessionId
            .startsWith(AdvancedChatController.draftSessionIdPrefix)) {
          continue;
        }
        if (isAdvancedGenerating(state)) {
          ids.add(state.session.sessionId);
        }
        ref.listen<AdvancedChatState>(
          advancedChatControllerProvider(session),
          (previous, next) {
            //  批1守卫：呼吸点只关心「生成中」成员资格翻转。
            // 此前无条件 setState——流式期间每 32ms 合帧 delta 都整壳
            // 重建（侧边栏+Scaffold+页面 widget）一次。
            if (isAdvancedGenerating(previous ?? next) !=
                isAdvancedGenerating(next)) {
              setState(() {});
            }
            // 后台自动命名完成时标题变更也要递增
            // 侧边栏刷新信号——此前成员资格翻转只做裸 setState，信号
            // 不变时 chat_sidebar.didUpdateWidget 不重载，列表/主页标题
            // 停留草稿名直到下一次导航动作。
            final previousTitle = previous?.session.title;
            if (previousTitle != null && previousTitle != next.session.title) {
              setState(() => _sidebarRefreshSignal++);
            }
          },
        );
      } else if (_usesIntermediateKernel(session)) {
        final state = ref.read(intermediateChatControllerProvider(session));
        // 用 controller.state.session 判断是否草稿（而非 nav stack 的 session）
        if (state.session.sessionId
            .startsWith(IntermediateChatController.draftSessionIdPrefix)) {
          continue;
        }
        if (isIntermediateGenerating(state)) {
          ids.add(state.session.sessionId);
        }
        ref.listen<IntermediateChatState>(
          intermediateChatControllerProvider(session),
          (previous, next) {
            //  批1守卫：同上，成员资格翻转才整壳重建
            if (isIntermediateGenerating(previous ?? next) !=
                isIntermediateGenerating(next)) {
              setState(() {});
            }
            // 同 advanced 分支——后台自动命名的
            // 标题变更递增侧边栏刷新信号。
            final previousTitle = previous?.session.title;
            if (previousTitle != null && previousTitle != next.session.title) {
              setState(() => _sidebarRefreshSignal++);
            }
          },
        );
      } else {
        final state = ref.read(chatModeControllerProvider(session));
        // 用 controller.state.session 判断是否草稿（而非 nav stack 的 session）
        if (state.session.sessionId
            .startsWith(ChatModeController.draftSessionIdPrefix)) {
          continue;
        }
        if (state.isSending || state.isStreaming || state.isCompressing) {
          ids.add(state.session.sessionId);
        }
        ref.listen<ChatModeState>(
          chatModeControllerProvider(session),
          (previous, next) {
            //  批1守卫：同上，成员资格翻转才整壳重建
            if (isChatGenerating(previous ?? next) != isChatGenerating(next)) {
              setState(() {});
            }
            // 同 advanced 分支——后台自动命名的
            // 标题变更递增侧边栏刷新信号。
            final previousTitle = previous?.session.title;
            if (previousTitle != null && previousTitle != next.session.title) {
              setState(() => _sidebarRefreshSignal++);
            }
          },
        );
      }
    }
    return ids;
  }

  /// 治理视图：导航栈 ∪ 后台跟踪集合（paused/resumed/呼吸点/禁删同源）
  Iterable<ChatSession> _governedSessions() sync* {
    for (final session in _navigationStack) {
      if (session != null) yield session;
    }
    yield* _backgroundSessions;
  }

  // ---------------------------------------------------------------------------
  // Desktop layout: sidebar + main area in a Row
  // ---------------------------------------------------------------------------

  Widget _buildDesktopLayout(Set<String> generatingSessionIds) {
    final colors = context.lm.palette;

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(colors.bg),
      // 路由级与全局根壳已承载场地（LmRouteVenuePageTransitionsBuilder / _GlassVenueShell），
      // 此处不再重复包裹场地，阻断 2~4 层渐变叠加。
      body: LmFocusTraversal(
        child: Row(
          children: [
            AnimatedSize(
              duration: LmMotion.durationFor(context, LmMotion.base),
              curve: LmMotion.easeBoth,
              child: SizedBox(
                width: _sidebarShown ? _sidebarWidth : 0,
                child: _sidebarShown
                    ? LmFocusOrder(
                        region: LmFocusRegion.sidebar,
                        child: _buildSidebar(
                          generatingSessionIds: generatingSessionIds,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            if (_sidebarShown)
              // 侧栏边界是结构分隔线：dividerStrong（对 bg ≥3:1， 语义拆分）。
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: colors.dividerStrong,
              ),
            Expanded(
              child: LmFocusOrder(
                region: LmFocusRegion.conversation,
                child: _buildMainContent(generatingSessionIds),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Mobile layout: drawer + full-width main content
  // ---------------------------------------------------------------------------

  Widget _buildMobileLayout(Set<String> generatingSessionIds) {
    return LmArrival(
      trigger: _currentSession?.mode,
      child: _buildMobileLayoutContent(generatingSessionIds),
    );
  }

  Widget _buildMobileLayoutContent(Set<String> generatingSessionIds) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _onPopInvoked(didPop),
      child: _buildMobileContent(generatingSessionIds),
    );
  }

  Widget _buildMobileContent(Set<String> generatingSessionIds) {
    final drawer = SizedBox(
      width: MediaQuery.of(context).size.width * 0.75,
      child: context.lmUi.panelVenue(
        context,
        _buildSidebar(
          isMobileDrawer: true,
          generatingSessionIds: generatingSessionIds,
        ),
      ),
    );

    // iOS 会话页 leading 换「返回上一级」：会话导航是内部栈非
    // Navigator 路由，边缘侧滑与 PopScope canPop 动态化（会真 pop
    // 根路由导致黑屏）都不可行，系统位置一致的返回箭头是安全入口；
    // 抽屉仍可从屏幕左缘滑开，Android 保持汉堡不变。
    final iosBackToHome = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? _popNavigation
        : null;

    final current = _currentSession;
    if (current != null) {
      // 按 mode 分发：advanced → AdvancedChatPage（导演），
      // intermediate → IntermediateChatPage（故事），其余 → ChatModePage
      if (_usesAdvancedKernel(current)) {
        return AdvancedChatPage(
          session: current,
          scaffoldKey: _scaffoldKey,
          drawer: drawer,
          showHamburgerMenu: true,
          onHamburgerPressed: _onHamburgerPressed,
          onBackToHome: iosBackToHome,
          onSessionDeleted: _goHome,
          initialFocusMessageId: _focusMessageId,
        );
      }
      if (_usesIntermediateKernel(current)) {
        return IntermediateChatPage(
          session: current,
          scaffoldKey: _scaffoldKey,
          drawer: drawer,
          showHamburgerMenu: true,
          onBackToHome: iosBackToHome,
          onHamburgerPressed: _onHamburgerPressed,
          onSessionDeleted: _goHome,
          initialFocusMessageId: _focusMessageId,
        );
      }
      return ChatModePage(
        session: current,
        scaffoldKey: _scaffoldKey,
        drawer: drawer,
        showHamburgerMenu: true,
        onHamburgerPressed: _onHamburgerPressed,
        onBackToHome: iosBackToHome,
        onSessionDeleted: _goHome,
        initialFocusMessageId: _focusMessageId,
      );
    }
    return HomePage(
      scaffoldKey: _scaffoldKey,
      drawer: drawer,
      showHamburgerMenu: true,
      onHamburgerPressed: _onHamburgerPressed,
      onNewChat: _startNewChat,
      onNewStory: _startNewStory,
      onNewDirector:
          ref.watch(advancedModeFlagProvider) ? _startNewDirector : null,
      onDirectorWizard:
          ref.watch(advancedModeFlagProvider) ? _startDirectorWizard : null,
      onSessionSelected: _selectSession,
      //  修复：与侧边栏共用刷新信号，最近会话/Key 黄条随之更新
      refreshSignal: _sidebarRefreshSignal,
    );
  }

  // ---------------------------------------------------------------------------
  // Main content area (desktop)
  // ---------------------------------------------------------------------------

  Widget _buildMainContent(Set<String> generatingSessionIds) {
    return LmArrival(
      trigger: _currentSession?.mode,
      child: _buildMainContentPage(generatingSessionIds),
    );
  }

  Widget _buildMainContentPage(Set<String> generatingSessionIds) {
    final current = _currentSession;
    // 桌面窄窗（侧栏被宽度判定收起）时挂抽屉：汉堡改开抽屉（与移动端
    // 同构）。宽度钳到 320——桌面窗口的 75% 会远超抽屉合理宽度。
    final Widget? narrowDrawer = _sidebarForceHidden
        ? SizedBox(
            width: math.min(320, MediaQuery.of(context).size.width * 0.75),
            child: context.lmUi.panelVenue(
              context,
              _buildSidebar(
                isMobileDrawer: true,
                generatingSessionIds: generatingSessionIds,
              ),
            ),
          )
        : null;
    if (current != null) {
      // 按 mode 分发：advanced → AdvancedChatPage（导演），
      // intermediate → IntermediateChatPage（故事），其余 → ChatModePage
      if (_usesAdvancedKernel(current)) {
        return AdvancedChatPage(
          session: current,
          scaffoldKey: _scaffoldKey,
          drawer: narrowDrawer,
          showHamburgerMenu: !_sidebarShown,
          onHamburgerPressed: _onHamburgerPressed,
          onSessionDeleted: _goHome,
          initialFocusMessageId: _focusMessageId,
        );
      }
      if (_usesIntermediateKernel(current)) {
        return IntermediateChatPage(
          session: current,
          scaffoldKey: _scaffoldKey,
          drawer: narrowDrawer,
          showHamburgerMenu: !_sidebarShown,
          onHamburgerPressed: _onHamburgerPressed,
          onSessionDeleted: _goHome,
          initialFocusMessageId: _focusMessageId,
        );
      }
      return ChatModePage(
        session: current,
        scaffoldKey: _scaffoldKey,
        drawer: narrowDrawer,
        showHamburgerMenu: !_sidebarShown,
        onHamburgerPressed: _onHamburgerPressed,
        onSessionDeleted: _goHome,
        initialFocusMessageId: _focusMessageId,
      );
    }
    return HomePage(
      scaffoldKey: _scaffoldKey,
      drawer: narrowDrawer,
      onNewChat: _startNewChat,
      onNewStory: _startNewStory,
      onNewDirector:
          ref.watch(advancedModeFlagProvider) ? _startNewDirector : null,
      onDirectorWizard:
          ref.watch(advancedModeFlagProvider) ? _startDirectorWizard : null,
      onSessionSelected: _selectSession,
      showHamburgerMenu: !_sidebarShown,
      onHamburgerPressed: _onHamburgerPressed,
      //  修复：同移动端，桌面首页随侧边栏信号刷新
      refreshSignal: _sidebarRefreshSignal,
    );
  }

  // ---------------------------------------------------------------------------
  // Sidebar builder
  // ---------------------------------------------------------------------------

  Widget _buildSidebar({
    bool isMobileDrawer = false,
    Set<String> generatingSessionIds = const {},
  }) {
    return ChatSidebar(
      // 2026-07-22 修复：用 controller.state.session.sessionId（物化后的真实 id），
      // 而非 nav stack 的 sessionId（可能是 draft id）。物化后侧边栏需要高亮
      // 当前真实会话，但若用 draft id 与 DB 的 real id 比较永远不匹配（bug）。
      // 草稿未物化时返回 draft id，侧边栏不匹配任何会话（正确：草稿不在列表中）。
      selectedSessionId: _realCurrentSessionId,
      onSessionSelected: (session, {focusMessageId}) {
        _selectSession(session, focusMessageId: focusMessageId);
        if (isMobileDrawer) Navigator.of(context).pop();
      },
      onNewChat: () {
        if (isMobileDrawer) Navigator.of(context).pop();
        _startNewChat();
      },
      onNewStory: () {
        if (isMobileDrawer) Navigator.of(context).pop();
        _startNewStory();
      },
      onNewDirector: ref.watch(advancedModeFlagProvider)
          ? () {
              if (isMobileDrawer) Navigator.of(context).pop();
              _startNewDirector();
            }
          : null,
      onSettings: () {
        if (isMobileDrawer) Navigator.of(context).pop();
        _onSettings();
      },
      onCollapse: () {
        if (isMobileDrawer) {
          Navigator.of(context).pop();
        } else {
          setState(() => _sidebarVisible = false);
        }
      },
      onSessionUpdated: _refreshCurrentSession,
      onSessionDeleted: (session) {
        // 删除的是当前选中会话时回主页——
        // 此前主区仍停留在已删会话，继续发消息会写入不存在的会话
        // 移动端多级栈中间的已删会话
        // 同步清出，否则返回时落回"幽灵会话"继续写孤儿消息
        if (isMobileDrawer) Navigator.of(context).pop();
        _backgroundSessions
            .removeWhere((s) => s.sessionId == session.sessionId);
        setState(() {
          _navigationStack.removeWhere(
            (s) => s?.sessionId == session.sessionId,
          );
        });
        if (session.sessionId == _realCurrentSessionId) {
          _goHome();
        }
      },
      onGoHome: () {
        if (isMobileDrawer) Navigator.of(context).pop();
        _goHome();
      },
      showCollapseButton: !isMobileDrawer,
      refreshSignal: _sidebarRefreshSignal,
      generatingSessionIds: generatingSessionIds,
    );
  }
}
