import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/tutorial/spotlight_target.dart';
import 'package:lmstory/core/widgets/model_config_banner.dart';
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/data/engineering_summarizer.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_input_lock.dart';
import 'package:lmstory/features/advanced/presentation/pages/director_chat_body.dart';
import 'package:lmstory/features/advanced/presentation/utils/auxiliary_generation_feedback.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_compact_composer.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_export_sheet.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_hitl_banner.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_session_settings_sheet.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_world_status_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_projection_service.dart';
import 'package:lmstory/features/settings/domain/entities/input_keys.dart'
    show NewlineKey, SendKey;
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/director_settings_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/font_size_selector_section.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/manual_compact_result.dart';
import 'package:lmstory/features/story_runtime/domain/services/memory_consolidator.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';
import 'package:lmstory/features/story_runtime/presentation/pages/memory_browser_page.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/fact_write_feedback.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/failure_bar.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演模式聊天页面（P2 解耦：从故事模式页面壳复制裁剪，仅保留导演分支）。
///
/// 与 ChatModePage/IntermediateChatPage 接口对齐（session/scaffoldKey/drawer/
/// showHamburgerMenu/onHamburgerPressed/onSessionDeleted），由 main_layout 按
/// session.mode 分发：advanced → 本页（AdvancedChatController + DirectorChatBody）。
///
/// 关键设计（母计划）：
/// - 配色随全局主题（夜航已收编为全局夜间基础）；顶层 Theme 仅覆盖
///   snackbar inset（避让输入区）
/// - 内层 `EntryTransition` 包裹（进入时播放夜航转场）
/// - body 用 Column 叠加消息列表 + FailureBar（：FailureBar 固定底部条）
class AdvancedChatPage extends ConsumerStatefulWidget {
  const AdvancedChatPage({
    required this.session,
    this.scaffoldKey,
    this.drawer,
    this.showHamburgerMenu = false,
    this.onBackToHome,
    this.onHamburgerPressed,
    this.onSessionDeleted,
    this.initialFocusMessageId,
    super.key,
  });

  final ChatSession session;

  /// 是否显示汉堡菜单（移动端）
  final bool showHamburgerMenu;
  final VoidCallback? onBackToHome;

  /// 汉堡菜单回调
  final VoidCallback? onHamburgerPressed;

  /// 当前会话被删除时回调（返回主界面）
  final VoidCallback? onSessionDeleted;

  /// 全局搜索命中进入时携带：定位到命中轮。普通进入为 null。
  final String? initialFocusMessageId;

  /// Scaffold key（移动端控制 Drawer）
  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// Drawer widget（移动端）
  final Widget? drawer;

  @override
  ConsumerState<AdvancedChatPage> createState() => _AdvancedChatPageState();
}

class _AdvancedChatPageState extends ConsumerState<AdvancedChatPage> {
  final _factWriteFeedback = FactWriteFeedback();
  // 2026-07-21：用户主动关闭「未配置嵌入模型」Banner 后，本会话内不再显示
  // 重启 App 或切换会话后重新检测（若仍未配置则再次显示）
  bool _embeddingBannerDismissed = false;

  /// HITL 首释：本会话首张 ask/审批横幅出现时显示一行解释，
  /// 见过一次即静默（页面 State 生命周期内）。
  bool _hitlIntroShown = false;

  /// 纯净阅读模式（按会话记忆偏好）。
  ///
  /// 持久化走 userOverrides kv（`ui.director.pureReading.<sessionId>`），
  /// 不动 chat_sessions 表结构；切会话时随 didUpdateWidget 重载。
  bool _pureReading = false;

  // 2026-07-29 推荐回复：输入框 GlobalKey，供工具栏按钮调用 insertAtCursor
  // 工具栏的"添加引号/括号/推荐回复"通过此 key 在光标位置插入文本。
  /// 按会话隔离的输入草稿（与对话/故事模式同款）
  final Map<String, String> _inputDrafts = {};

  /// 输入防抖落库计时器（500ms 静默后写窄列；dispose 只取消不写）。
  Timer? _draftDebounce;
  Object _draftVisit = Object();
  bool _draftEdited = false;
  String _observedDraft = '';

  /// 输入文本变化 → 防抖 500ms 落库（退出兜底主力；dispose 只取消）。
  void _onDraftTextChanged(String text) {
    if (text == _observedDraft) return;
    _observedDraft = text;
    if (_isInputLocked) return; // 固定提示词不作为用户草稿落库
    _draftEdited = true;
    _draftDebounce?.cancel();
    final session = widget.session;
    // lm-motion-exempt: 草稿落库去抖（交互节流，非过渡动效）
    _draftDebounce = Timer(const Duration(milliseconds: 500), () {
      _persistDraftColumn(session, text);
    });
  }

  void _persistDraftColumn(ChatSession session, String text) {
    unawaited(
      ref
          .read(advancedChatControllerProvider(session).notifier)
          .persistInputDraft(text.isEmpty ? null : text),
    );
  }

  /// 跨重启恢复：页面级 Map 未命中时读库（输入框仍空才落，不覆盖新输入）。
  Future<void> _restoreDraftFromDb(String sessionId) async {
    if (_isInputLocked || widget.session.sessionId != sessionId) return;
    final visit = _draftVisit;
    final String? draft;
    try {
      draft = await ref
          .read<ChatRepository>(chatRepositoryProvider)
          .getSessionDraft(sessionId);
    } catch (_) {
      return; // 读库失败静默降级（不炸页面）
    }
    // await 窗口内锁可能已置位（演示流程 lockTo 先于本异步完成）——
    // 二次判定防擦掉固定提示词
    if (!mounted ||
        _isInputLocked ||
        visit != _draftVisit ||
        _draftEdited ||
        draft == null ||
        draft.isEmpty) {
      return;
    }
    final current = _inputKey.currentState?.currentText ?? '';
    if (current.isEmpty) {
      final state = ref.read(advancedChatControllerProvider(widget.session));
      _showSavedDraft(draft, requestFocus: !state.isAwaitingFirstRound);
    }
  }

  void _showSavedDraft(String text, {required bool requestFocus}) {
    // 恢复和切页校正都会通知 TextEditingController。预先记录文本，
    // 防止程序将未加载的空值当成用户主动清空。
    _observedDraft = text;
    _inputKey.currentState?.setText(text, requestFocus: requestFocus);
  }

  static const double _kWorldInspectorBreakpoint = 900;
  static const double _kWorldInspectorWidth = 332;

  /// Whether the docked right-hand world status inspector is open on wide
  /// screens (>= 900dp).
  bool _desktopWorldInspectorOpen = false;

  /// Incremented when anchor/world data is edited so an open inspector reloads.
  int _worldStatusRevision = 0;

  /// Read-only lookup of entityId -> primaryName for legacy records that lack
  /// persisted primaryName in round artifacts.
  Map<String, String> _entityNameMap = const {};
  final Set<String> _requestedEntityIds = <String>{};
  bool _entityNameResolutionScheduled = false;
  static final RegExp _entityIdPattern = RegExp(r'\b(ent_[A-Za-z0-9_-]+)\b');

  final GlobalKey<DirectorCompactComposerState> _inputKey =
      GlobalKey<DirectorCompactComposerState>();

  // 底部输入区域实际高度，用于 SnackBar margin 避让输入框。
  double _bottomAreaHeight = 84;
  final _bottomAreaKey = GlobalKey();
  bool _bottomAreaMeasurementScheduled = false;

  // 2026-07-22 修复：历史消息加载已移至 AdvancedChatController 构造函数，
  // 与 ChatModeController 一致。之前在 initState 中调用 loadHistory()，
  // 但故事模式->故事模式切换会话时 State 被复用（widget 类型相同且无 key），
  // initState 不重新调用，导致新会话消息不加载、UI 显示空状态。

  @override
  void dispose() {
    _factWriteFeedback.dismissOnSessionExit();
    _draftDebounce?.cancel();
    super.dispose();
  }

  /// 输入锁（通用能力；根作用域恒 null=无锁，仅演示作用域注入）。
  /// 锁存在时：输入只读+固定文本、草稿三层恢复/落库全跳过、工具栏
  /// 插入回调 no-op——发送仍由用户亲自点击（不自动发送）。
  DirectorInputLock? get _inputLock =>
      ref.read(directorInputLockProvider).value;

  bool get _isInputLocked => _inputLock != null;

  @override
  void initState() {
    super.initState();
    _scheduleBottomAreaMeasurement();
    // 页面首次创建时检查是否需要回写草稿（如异常中断后重新进入）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_isInputLocked) _tryRestoreDraft();
      // 跨重启恢复：控制器 userInput 无待恢复时读库（Map 冷启动恒空）
      if (mounted && !_isInputLocked) {
        unawaited(_restoreDraftFromDb(widget.session.sessionId));
      }
      _enforceLockedText();
    });
    _loadPureReadingPreference();
  }

  /// 锁存在时强制输入框为固定文本（防迟到的草稿恢复/任何入口改写）。
  /// 输入组件尚未挂载（currentState 为 null）时排一帧重试——锁在页面
  /// 首帧前已置位的场景（恢复直达会话步）依赖这次补跑。
  bool _lockEnforcementScheduled = false;

  /// 锁文本校正入口：帧尾执行（输入组件挂载后）。
  void _scheduleLockEnforcement() {
    if (_lockEnforcementScheduled) return;
    _lockEnforcementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lockEnforcementScheduled = false;
      if (!mounted) return;
      _enforceLockedText();
    });
  }

  void _enforceLockedText([DirectorInputLock? lock]) {
    final l = lock ?? _inputLock;
    if (l == null || !mounted) return;
    final inputState = _inputKey.currentState;
    if (inputState == null) {
      _scheduleLockEnforcement();
      return;
    }
    if (inputState.currentText != l.fixedText) {
      inputState.setText(l.fixedText);
    }
  }

  /// 装载当前会话的纯净阅读偏好（无记录 = 关）
  Future<void> _loadPureReadingPreference() async {
    final repo = ref.read(settingsRepositoryProvider);
    final overrides = await repo.getUserOverrides();
    if (!mounted) return;
    final value = overrides[_pureReadingKey(widget.session.sessionId)];
    setState(() => _pureReading = value == true);
  }

  static String _pureReadingKey(String sessionId) =>
      'ui.director.pureReading.$sessionId';

  /// 切换纯净阅读并按会话持久
  Future<void> _togglePureReading() async {
    setState(() => _pureReading = !_pureReading);
    await ref.read(settingsRepositoryProvider).setUserOverride(
          _pureReadingKey(widget.session.sessionId),
          _pureReading,
        );
  }

  @override
  void didUpdateWidget(covariant AdvancedChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切会话时检查新会话是否需要回写草稿
    if (oldWidget.session.sessionId != widget.session.sessionId) {
      _factWriteFeedback.dismissOnSessionExit();
      // 会话切换重置 HITL 首释解释——
      // State 复用导致第二/三个会话的首张 ask/审批横幅永远错过解释行
      _hitlIntroShown = false;
      // 同族修正：嵌入横幅的「切换会话后重新检测」承诺此前同样被 State
      // 复用吞掉（dismissed 标志跨会话残留）
      _embeddingBannerDismissed = false;
      // 纯净阅读按会话重载
      _loadPureReadingPreference();
      _entityNameMap = const {};
      _requestedEntityIds.clear();
      _entityNameResolutionScheduled = false;
      if (_draftEdited) {
        _inputDrafts[oldWidget.session.sessionId] = _observedDraft;
        _persistDraftColumn(oldWidget.session, _observedDraft);
      }
      _draftDebounce?.cancel();
      _draftEdited = false;
      final visit = _draftVisit = Object();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _draftVisit != visit) return;
        _enforceLockedText();
        if (_isInputLocked) return;
        final state = ref.read(advancedChatControllerProvider(widget.session));
        final restorable = state.pendingUserMessage == null &&
            state.userInput != null &&
            state.userInput!.isNotEmpty &&
            state.phase == IntermediatePhase.idle;
        if (restorable) {
          _tryRestoreDraft();
        } else {
          final stashed = _inputDrafts[widget.session.sessionId];
          _showSavedDraft(
            stashed ?? '',
            requestFocus: stashed?.isNotEmpty ?? false,
          );
          if (stashed == null) {
            unawaited(_restoreDraftFromDb(widget.session.sessionId));
          }
        }
      });
    }
  }

  /// 检测中断后需要回写输入框的场景，把 userInput 回写到输入框。
  ///
  /// 触发条件：pendingUserMessage 为空（气泡已消失）+ userInput 非空
  /// + phase=idle。覆盖取消生成、后台恢复中断、清空本轮等场景。
  /// 回写后立即清空 userInput，避免重复触发。
  void _tryRestoreDraft() {
    if (_isInputLocked) return;
    final state = ref.read(advancedChatControllerProvider(widget.session));
    if (state.pendingUserMessage == null &&
        state.userInput != null &&
        state.userInput!.isNotEmpty &&
        state.phase == IntermediatePhase.idle) {
      _inputKey.currentState?.setText(state.userInput!);
      ref
          .read(advancedChatControllerProvider(widget.session).notifier)
          .clearUserInput();
    }
  }

  void _scheduleMissingEntityNameResolution(AdvancedChatState state) {
    if (_entityNameResolutionScheduled) return;
    final missing = <String>{};

    void collectIdsFromText(String? text) {
      if (text == null || !text.contains('ent_')) return;
      for (final match in _entityIdPattern.allMatches(text)) {
        final id = match.group(1);
        if (id != null &&
            !_requestedEntityIds.contains(id) &&
            !_entityNameMap.containsKey(id)) {
          missing.add(id);
        }
      }
    }

    final artifactsMap = state.artifactsByTurnNumber;
    if (artifactsMap != null) {
      for (final artifact in artifactsMap.values) {
        for (final change in artifact.factsChanges) {
          final id = change.entityId;
          if (id != null &&
              id.isNotEmpty &&
              (change.primaryName == null ||
                  change.primaryName!.trim().isEmpty) &&
              !_requestedEntityIds.contains(id) &&
              !_entityNameMap.containsKey(id)) {
            missing.add(id);
          }
          collectIdsFromText(change.attrKey);
          collectIdsFromText(change.oldValue);
          collectIdsFromText(change.newValue);
        }
        for (final step in artifact.agentSteps) {
          collectIdsFromText(step.title);
        }
      }
    }
    for (final step in state.agentSteps) {
      collectIdsFromText(step.title);
    }

    if (missing.isEmpty) return;
    _requestedEntityIds.addAll(missing);
    _entityNameResolutionScheduled = true;
    final session = widget.session;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _entityNameResolutionScheduled = false;
      if (!mounted || widget.session.sessionId != session.sessionId) return;
      final resolved = await ref
          .read(advancedChatControllerProvider(session).notifier)
          .loadEntityPrimaryNames(missing);
      if (!mounted ||
          widget.session.sessionId != session.sessionId ||
          resolved.isEmpty) {
        return;
      }
      setState(() {
        _entityNameMap = {..._entityNameMap, ...resolved};
      });
    });
  }

  void _scheduleBottomAreaMeasurement() {
    if (_bottomAreaMeasurementScheduled) return;
    _bottomAreaMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomAreaMeasurementScheduled = false;
      if (!mounted) return;
      final box =
          _bottomAreaKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final height = box.size.height + 8;
      if ((height - _bottomAreaHeight).abs() > 1) {
        setState(() => _bottomAreaHeight = height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(advancedChatControllerProvider(widget.session));
    // 输入锁：每帧同步校正（幂等；锁不存在零开销）。State/Element 复用
    // 会吞掉一次性监听——锁置位晚于页面创建只能靠这里兜底。
    _enforceLockedText();
    _scheduleMissingEntityNameResolution(state);

    // 监听 state 变化：中断后（cancel/recoverIfStuck/clearRound 清空
    // pendingUserMessage + 保留 userInput）自动回写到输入框
    ref.listen<AdvancedChatState>(
      advancedChatControllerProvider(widget.session),
      (previous, next) {
        final warning = next.factWriteWarning;
        if (warning != null && warning != previous?.factWriteWarning) {
          _factWriteFeedback.show(context, warning.count);
        }
        if (previous?.pendingUserMessage != null &&
            next.pendingUserMessage == null &&
            next.userInput != null &&
            next.userInput!.isNotEmpty &&
            next.phase == IntermediatePhase.idle) {
          if (!_isInputLocked) _tryRestoreDraft();
        }
        // 「系统替你做了决定」的三类
        // 时刻（溢出自愈/请示超时/审批超时 fail-closed）以 3s toast 现身
        if (next.overflowHealedTick > (previous?.overflowHealedTick ?? 0)) {
          _showSystemNotice(t.advanced.overflowHealedToast);
        }
        if (next.hitlAskTimeoutTick > (previous?.hitlAskTimeoutTick ?? 0)) {
          _showSystemNotice(t.advanced.hitl.askTimeout);
        }
        if (next.hitlApprovalTimeoutTick >
            (previous?.hitlApprovalTimeoutTick ?? 0)) {
          _showSystemNotice(t.advanced.hitl.approvalTimeout);
        }
        // 变体切换被拒（后续轮/压缩区无法安全交换记忆层）
        if (next.variantSwitchBlockedTick >
            (previous?.variantSwitchBlockedTick ?? 0)) {
          final notice = switch (next.variantSwitchBlockedReason) {
            'compacted' => t.advanced.variant.switchBlockedCompacted,
            'restore' => t.advanced.variant.switchBlockedRestore,
            _ => t.advanced.variant.switchBlockedDownstream,
          };
          _showSystemNotice(notice);
        }
      },
    );

    // 1. 顶层 Theme 包裹夜航主题（页面级，不改全局）
    // SnackBar insetPadding 覆盖：上移至输入框上方，避免遮挡输入框
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _scheduleBottomAreaMeasurement();
        return false;
      },
      child: Theme(
        // 仅覆盖 snackbar inset（避让输入区）；配色随全局主题。
        data: Theme.of(context).copyWith(
          snackBarTheme: Theme.of(context).snackBarTheme.copyWith(
                insetPadding: EdgeInsets.fromLTRB(16, 0, 16, _bottomAreaHeight),
              ),
        ),
        child: context.lmUi.entryTransition(
          context,
          child: _buildScaffold(context, state),
        ),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context, AdvancedChatState state) {
    // 空态 GM 未配置引导（判定链同 resolveAdvancedGeneratingNamingConfig）。
    // 解析期间不显示，避免配置完成折返时闪横幅。
    final gmReady = ref.watch(directorGmReadyProvider(state.session));
    final colors = context.lm.palette;
    // 导演配置来源：advanced 段（"两个产品"零依赖，2026-08-27 导演设置体系）。
    // 配置未加载时 embedding 横幅不展示（与原 intermediateConfig 判空同构）。
    final advancedConfig = ref.watch(advancedConfigProvider).valueOrNull;
    // fork 窗口轮数：导演无 fork 配置键（设计文档 §4），用值类默认 5
    //（导演设置  起不再读 intermediate.fork.regenerate_window_rounds）
    final windowRounds = const ForkConfig().regenerateWindowRounds;
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    final t = Translations.of(context);
    final isGenerating = state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed;

    // 字体大小 → 缩放比例（与 ChatModePage/故事页共享 kFontSizeBaseSize）
    // 导演模式基准字号（稿件卡 16px / 用户 15px）保持不变，fontScale 应用到
    // 基准上，让通用设置中的「字体大小」同时控制三模式的显示大小。
    final fontSize = ref.watch(
      settingsNotifierProvider.select((s) => s.fontSize),
    );
    final fontScale =
        fontSize.clamp(kFontSizeMin, kFontSizeMax) / kFontSizeBaseSize;
    final sendKey = ref.watch(
      settingsNotifierProvider.select((s) => s.sendKey),
    );
    final newlineKey = ref.watch(
      settingsNotifierProvider.select((s) => s.newlineKey),
    );

    // 返回手势由外层 MainLayout 的 PopScope 统一处理（与 ChatModePage 对齐）。
    // controller 是 non-autoDispose，生成中返回后台继续，重新进入可查看进度。
    // Scaffold strips its consumed insets from the body's MediaQuery.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final headerSubtitle = _buildHeaderSubtitle(state);
    return LayoutBuilder(
      builder: (context, pageConstraints) {
        final isWide = pageConstraints.maxWidth >= _kWorldInspectorBreakpoint;
        final showDesktopInspector = isWide && _desktopWorldInspectorOpen;

        return Scaffold(
          key: widget.scaffoldKey,
          drawer: widget.drawer,
          // 琉璃结构：透明底透出场地渐变；阅读/流式区零 blur（红线）。
          backgroundColor: context.scaffoldBgOf(colors.bg),
          appBar: AppBar(
            leading: widget.onBackToHome != null
                ? IconButton(
                    tooltip:
                        MaterialLocalizations.of(context).backButtonTooltip,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: widget.onBackToHome,
                  )
                : widget.showHamburgerMenu
                    ? IconButton(
                        tooltip: MaterialLocalizations.of(context)
                            .openAppDrawerTooltip,
                        icon: const Icon(Icons.menu),
                        onPressed: widget.onHamburgerPressed,
                      )
                    : null,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  state.session.title,
                  style: IntermediateTextStyles.title.copyWith(
                    fontSize: 16,
                    height: 1.25,
                    color: colors.ink,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (headerSubtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      headerSubtitle,
                      style: IntermediateTextStyles.captionSm.copyWith(
                        color: colors.muted,
                        fontWeight: FontWeight.w400,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            backgroundColor: context.scaffoldBgOf(colors.bg),
            foregroundColor: colors.ink,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Divider(
                height: 1,
                thickness: 0.5,
                color: colors.divider,
              ),
            ),
            actions: [
              _WorldStatusNavChip(
                active: showDesktopInspector,
                onTap: () => _handleWorldStatusPressed(isWide: isWide),
              ),
              const SizedBox(width: IntermediateSpacing.s2xs),
              SpotlightTarget(
                id: DemoTargetIds.sessionSettingsButton,
                child: IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: t.advanced.sessionSettingsTitle,
                  onPressed: _showSessionSettings,
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sXs),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final bodyMaxHeight = constraints.maxHeight;
              final hasDecision = state.agentAskPrompt != null ||
                  state.agentApprovalPrompt != null;
              final decisionMaxHeight = hasDecision
                  ? bodyMaxHeight * (keyboardOpen ? 0.50 : 0.62)
                  : 0.0;
              final heightBelowDecision = bodyMaxHeight - decisionMaxHeight;
              final isFailed = state.phase == IntermediatePhase.failed &&
                  state.failureContext != null;
              final failureFooterMaxHeight =
                  heightBelowDecision * (keyboardOpen ? 0.80 : 0.70);
              final hasSuggestOverlay = _shouldShowSuggestOverlay(state);
              final suggestFailure = state.suggestFailure;
              final suggestFailureMessage = suggestFailure == null
                  ? null
                  : directorAuxiliaryFailureText(t, suggestFailure);
              final modelNotices = <Widget>[
                if (state.messages.isEmpty &&
                    state.pendingUserMessage == null &&
                    state.liveBlocks.isEmpty &&
                    state.agentSteps.isEmpty &&
                    !state.loadingHistory &&
                    gmReady.value == false)
                  ModelConfigBanner(
                    title: t.advanced.modelConfigBanner.title,
                    message: t.advanced.modelConfigBanner.message,
                    actionLabel: t.advanced.modelConfigBanner.configure,
                    dismissTooltip: t.advanced.modelConfigBanner.dismiss,
                    onConfigure: _goToGmConfig,
                  ),
                if (advancedConfig != null &&
                    !_embeddingBannerDismissed &&
                    (advancedConfig.embeddingPresetId.isEmpty ||
                        advancedConfig.embeddingModelId.isEmpty))
                  context.lmUi.embeddingMissingBanner(
                    context,
                    onConfigure: _goToEmbeddingSettings,
                    onDismiss: () =>
                        setState(() => _embeddingBannerDismissed = true),
                  ),
              ];
              final conversation = SpotlightTarget(
                id: DemoTargetIds.sessionChatBody,
                child: DirectorChatBody(
                  state: state,
                  onVisibleHistoryTurns: controller.loadHistoryTurnDetails,
                  pureReading: _pureReading,
                  fontScale: fontScale,
                  onCopy: _handleCopy,
                  onRegenerate: _handleRegenerate,
                  onEdit: _handleEdit,
                  onDeleteRound: _handleDeleteRound,
                  onUseExample: (example) =>
                      _inputKey.currentState?.setText(example),
                  initialFocusMessageId: widget.initialFocusMessageId,
                  windowRounds: windowRounds,
                  onUndoCompaction: _handleUndoCompaction,
                  onSwitchVariant: controller.switchMessageVariant,
                  onDeleteVariant: controller.deleteMessageVariant,
                  onVariantFlashConsumed: controller.clearVariantFlash,
                  onEditAnchor: (anchor) => unawaited(_saveStoryAnchor(anchor)),
                  onOpenMemory: _openMemoryBrowser,
                  onOpenWorldStatus: () =>
                      _handleWorldStatusPressed(isWide: isWide),
                  entityNameMap: _entityNameMap,
                ),
              );

              final mainColumn = Column(
                children: [
                  if (hasDecision)
                    DirectorDecisionViewport(
                      maxHeight: decisionMaxHeight,
                      accentColor: state.agentAskPrompt != null
                          ? colors.primary
                          : colors.warning,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (state.agentAskPrompt != null)
                            DirectorAskBanner(
                              prompt: state.agentAskPrompt!,
                              onAnswer: controller.answerDirectorAsk,
                              onSkip: () => controller.answerDirectorAsk(null),
                              timeout: _askUserTimeout(advancedConfig),
                              showIntro: !_hitlIntroShown,
                              onIntroSeen: () {
                                if (mounted) {
                                  setState(() => _hitlIntroShown = true);
                                }
                              },
                              fontScale: fontScale,
                            ),
                          if (state.agentApprovalPrompt != null) ...[
                            if (state.agentAskPrompt != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: IntermediateSpacing.sSm,
                                ),
                                child: Divider(
                                  height: 1,
                                  thickness: 0.5,
                                  color: colors.divider,
                                ),
                              ),
                            DirectorApprovalBanner(
                              prompt: state.agentApprovalPrompt!,
                              onResolve: controller.resolveDirectorApproval,
                              timeout: _approvalTimeout(advancedConfig),
                              showIntro: !_hitlIntroShown,
                              onIntroSeen: () {
                                if (mounted) {
                                  setState(() => _hitlIntroShown = true);
                                }
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, remaining) => Column(
                        children: [
                          if (modelNotices.isNotEmpty)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: remaining.maxHeight *
                                    (keyboardOpen ? 0.60 : 0.80),
                              ),
                              child: SingleChildScrollView(
                                primary: false,
                                child: Column(children: modelNotices),
                              ),
                            ),
                          Expanded(child: conversation),
                        ],
                      ),
                    ),
                  ),
                  if (!isFailed)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: heightBelowDecision,
                      ),
                      child: SingleChildScrollView(
                        primary: false,
                        reverse: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasSuggestOverlay)
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: IntermediateSpacing.sMd,
                                ),
                                child: context.lmUi.suggestReplyOverlay(
                                  context,
                                  replies: state.suggestReplies,
                                  isGenerating: state.isGeneratingSuggest,
                                  isExpanded: state.suggestExpanded,
                                  isFailed: state.suggestFailed,
                                  failureMessage: suggestFailureMessage,
                                  onSelect: (index) =>
                                      _handleSelectSuggest(controller, index),
                                  onClose: controller.closeSuggest,
                                  onToggle: controller.toggleSuggest,
                                  onRetry: controller.generateSuggestReplies,
                                ),
                              ),
                            SpotlightTarget(
                              id: DemoTargetIds.sessionInputArea,
                              child: _buildComposerShell(
                                state: state,
                                controller: controller,
                                sendKey: sendKey,
                                newlineKey: newlineKey,
                                isGenerating: isGenerating,
                                applyDemoLock: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: failureFooterMaxHeight,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: SingleChildScrollView(
                              primary: false,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FailureBar(
                                    failureContext: state.failureContext!,
                                    onRetry: controller.retry,
                                    onClear: () async {
                                      final session = widget.session;
                                      await controller.clearRound();
                                      if (mounted &&
                                          widget.session == session) {
                                        _tryRestoreDraft();
                                      }
                                    },
                                    onContinueWithFts5:
                                        controller.continueWithFts5Only,
                                    onContinueFromFailed:
                                        controller.continueFromFailed,
                                  ),
                                  if (hasSuggestOverlay)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: IntermediateSpacing.sMd,
                                      ),
                                      child: context.lmUi.suggestReplyOverlay(
                                        context,
                                        replies: state.suggestReplies,
                                        isGenerating: state.isGeneratingSuggest,
                                        isExpanded: state.suggestExpanded,
                                        isFailed: state.suggestFailed,
                                        failureMessage: suggestFailureMessage,
                                        onSelect: (index) =>
                                            _handleSelectSuggest(
                                          controller,
                                          index,
                                        ),
                                        onClose: controller.closeSuggest,
                                        onToggle: controller.toggleSuggest,
                                        onRetry:
                                            controller.generateSuggestReplies,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: failureFooterMaxHeight * 0.65,
                            ),
                            child: SingleChildScrollView(
                              primary: false,
                              reverse: true,
                              child: _buildComposerShell(
                                state: state,
                                controller: controller,
                                sendKey: sendKey,
                                newlineKey: newlineKey,
                                isGenerating: isGenerating,
                                applyDemoLock: false,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );

              return Row(
                children: [
                  Expanded(child: mainColumn),
                  AnimatedSize(
                    duration: LmMotion.durationFor(context, LmMotion.emphasis),
                    curve: LmMotion.easeEmphasis,
                    alignment: Alignment.centerLeft,
                    child: showDesktopInspector
                        ? SizedBox(
                            width: _kWorldInspectorWidth,
                            height: bodyMaxHeight,
                            child: Row(
                              children: [
                                VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: colors.divider,
                                ),
                                Expanded(
                                  child: DirectorWorldStatusPanel(
                                    key: const ValueKey(
                                      'desktop-world-status-panel',
                                    ),
                                    loader: controller.loadScriptBoard,
                                    fallbackAnchor: state.agentStoryAnchor ??
                                        state.session.storyAnchor,
                                    fallbackNarrativeTime:
                                        state.session.currentNarrativeTime,
                                    entityNameMap: _entityNameMap,
                                    pureReading: _pureReading,
                                    isGenerating: isGenerating,
                                    onOpenMemory: _openMemoryBrowser,
                                    onTogglePureReading: () =>
                                        unawaited(_togglePureReading()),
                                    onExport: () =>
                                        unawaited(_showExportSheet()),
                                    onUpdateTitle: () =>
                                        unawaited(_updateSessionTitle()),
                                    onEditAnchor: _saveStoryAnchor,
                                    onClose: () => setState(
                                      () => _desktopWorldInspectorOpen = false,
                                    ),
                                    refreshToken: (
                                      state.session.sessionId,
                                      state.messages.length,
                                      state.agentStoryAnchor?.updatedTurn,
                                      state.session.storyAnchor?.updatedTurn,
                                      _worldStatusRevision,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  String? _buildHeaderSubtitle(AdvancedChatState state) {
    final anchor = state.agentStoryAnchor ?? state.session.storyAnchor;
    final rawTime = anchor?.narrativeTime?.trim();
    final time = (rawTime != null && rawTime.isNotEmpty)
        ? rawTime
        : state.session.currentNarrativeTime?.trim();
    final rawArc = anchor?.arc?.trim();
    final rawOneLiner = anchor?.oneLiner?.trim();
    final summary = (rawArc != null && rawArc.isNotEmpty)
        ? rawArc
        : (rawOneLiner != null && rawOneLiner.isNotEmpty)
            ? rawOneLiner
            : null;
    final parts = <String>[
      if (time != null && time.isNotEmpty) time,
      if (summary != null && summary.isNotEmpty) summary,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _buildComposerShell({
    required AdvancedChatState state,
    required AdvancedChatController controller,
    required SendKey sendKey,
    required NewlineKey newlineKey,
    required bool isGenerating,
    required bool applyDemoLock,
  }) {
    final locked = applyDemoLock &&
        (_isInputLocked ||
            (ref.watch(demoBridgeProvider) != null && isGenerating));
    return SizeChangedLayoutNotifier(
      child: Container(
        key: _bottomAreaKey,
        child: DirectorCompactComposer(
          key: _inputKey,
          phase: state.phase,
          isStopping: state.isStopping,
          isManualCompacting: state.isManualCompacting,
          isPreparingRegenerate: state.isPreparingRegenerate,
          preserveWhitespace: state.isAwaitingFirstRound,
          locked: locked,
          onSend: _handleSend,
          onTextChanged: _onDraftTextChanged,
          onCancel: controller.cancel,
          onAddQuote: () => _handleInsertText('""', 1),
          onAddParen: () => _handleInsertText('()', 1),
          onSuggest: controller.generateSuggestReplies,
          isGeneratingSuggest: state.isGeneratingSuggest,
          canSuggest: state.messages.isNotEmpty,
          sendKey: sendKey,
          newlineKey: newlineKey,
          contextNumerator: _currentEstimateTokens(state),
          contextDenominator: state.compactionTriggerTokens,
          onContextTap: _showContextCapacitySheet,
          queuedMessageSlot: state.queuedMessage != null
              ? _buildQueuedMessageChip(state)
              : null,
        ),
      ),
    );
  }

  /// ask_user 挂起超时：advanced.hitl.ask_user_timeout_minutes，
  /// 0 = 永不超时（null，横幅显示「一直等待你的回复」），缺省 3 分钟。
  /// P2 永等开关（approval_timeout_enabled，2026-10-15）同盖提问横幅：
  /// 关闭时同样永不超时。钳制真源在 AdvancedHitlConfig（与 runner 同源）。
  Duration? _askUserTimeout(AdvancedConfig? config) {
    return config?.hitl.effectiveAskUserTimeout ?? const Duration(minutes: 3);
  }

  /// 审批挂起超时：与 runner 侧 completer.timeout 共用
  /// AdvancedHitlConfig.effectiveApprovalTimeout 真源（修 此前
  /// 页面直用原始配置值、runner 侧 0→5 钳制，两侧口径漂移；
  /// P2 开关关闭 → null 永不超时）。
  Duration? _approvalTimeout(AdvancedConfig? config) {
    return config?.hitl.effectiveApprovalTimeout ?? const Duration(minutes: 5);
  }

  /// 系统裁决时刻的 3s 浮动提示（floating 规范）
  void _showSystemNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ── ：会话设置入口 ─────────────────────────────────────────────

  /// 弹出会话设置面板（IntermediateSessionSettingsSheet）。
  ///
  /// sheet 内部通过 [advancedChatControllerProvider] 直接读写 controller，
  /// 无需回调。生成中也可打开（sheet 通过 phase 守卫禁用控件）。
  /// backgroundColor: transparent 让 sheet 自带的圆角容器背景生效。
  void _showSessionSettings() {
    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // 内容自绘把手。
      glassHandle: false,
      builder: (_) => DirectorSessionSettingsSheet(session: widget.session),
    );
  }

  /// 弹出稿件导出选项 sheet。
  ///
  Future<void> _showExportSheet() async {
    final provider = advancedChatControllerProvider(widget.session);
    final controller = ref.read(provider.notifier);
    final snapshot = ref.read(provider);
    final failed = Translations.of(context).advanced.export.failed;
    await DirectorExportSheet.show(
      context,
      snapshot,
      loadArtifacts: () async {
        final artifacts = await controller.loadSessionArtifacts(
          snapshot.session.sessionId,
        );
        // A different revision must not combine old text with new backstage or recap.
        if (!mounted) throw StateError(failed);
        final current = ref.read(provider);
        if (!identical(current.messages, snapshot.messages) ||
            current.compactedTurnBase != snapshot.compactedTurnBase) {
          throw StateError(failed);
        }
        return artifacts;
      },
    );
  }

  void _openMemoryBrowser() {
    final session =
        ref.read(advancedChatControllerProvider(widget.session)).session;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemoryBrowserPage(session: session),
      ),
    );
  }

  Future<bool> _saveStoryAnchor(StoryAnchor anchor) async {
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    final ok = await controller.updateStoryAnchor(anchor);
    if (!mounted) return ok;
    if (ok) {
      setState(() => _worldStatusRevision++);
    }
    final t = Translations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          ok ? t.advanced.anchorEdit.saved : t.advanced.anchorEdit.saveBlocked,
        ),
      ),
    );
    return ok;
  }

  void _handleWorldStatusPressed({required bool isWide}) {
    if (isWide) {
      setState(() {
        _desktopWorldInspectorOpen = !_desktopWorldInspectorOpen;
      });
      return;
    }
    final currentState = ref.read(
      advancedChatControllerProvider(widget.session),
    );
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    final generating = currentState.phase != IntermediatePhase.idle &&
        currentState.phase != IntermediatePhase.failed;
    unawaited(
      DirectorWorldStatusSheet.show(
        context,
        loader: controller.loadScriptBoard,
        fallbackAnchor:
            currentState.agentStoryAnchor ?? currentState.session.storyAnchor,
        fallbackNarrativeTime: currentState.session.currentNarrativeTime,
        entityNameMap: _entityNameMap,
        pureReading: _pureReading,
        isGenerating: generating,
        onOpenMemory: _openMemoryBrowser,
        onTogglePureReading: () => unawaited(_togglePureReading()),
        onExport: () => unawaited(_showExportSheet()),
        onUpdateTitle: () => unawaited(_updateSessionTitle()),
        onEditAnchor: _saveStoryAnchor,
      ),
    );
  }

  /// 顶栏菜单触发：更新会话标题
  Future<void> _updateSessionTitle() async {
    final sessionId = widget.session.sessionId;
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    final result = await controller.updateTitleWithResult(force: true);
    if (!mounted || widget.session.sessionId != sessionId) return;
    final message = directorTitleUpdateText(Translations.of(context), result);
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
      );
  }

  // 跳导演模式设置页并定位「检索与记忆」分区。
  // 旧实现跳故事模式嵌入模型页，写入 intermediate.embedding_* 键——导演
  // 运行时只读 advanced.embedding_*（无回退），按引导配置后横幅不会消失。
  void _goToEmbeddingSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const DirectorSettingsPage(focusSection: 'memory'),
      ),
    );
  }

  /// 空态「导演主模型（GM）未配置」横幅「去配置」：直达导演设置页
  /// （模型与生成区常驻置顶）。折返后失效判定 provider 重估。
  Future<void> _goToGmConfig() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DirectorSettingsPage()),
    );
    if (mounted) {
      ref.invalidate(
        directorGmReadyProvider(
          ref.read(advancedChatControllerProvider(widget.session)).session,
        ),
      );
    }
  }

  // ──  Fork 动作回调处理 ──────────────────────────────────────────

  /// 2026-07-29 推荐回复：判断是否显示气泡浮层
  ///
  /// 显示条件：正在生成 OR 已有候选回复 OR 生成失败
  /// 不显示：无候选且非生成中且非失败（初始态/已关闭/已发送）
  bool _shouldShowSuggestOverlay(AdvancedChatState state) {
    return state.isGeneratingSuggest ||
        state.suggestReplies.isNotEmpty ||
        state.suggestFailed;
  }

  /// 2026-07-29 推荐回复：在输入框光标位置插入成对符号
  ///
  /// 供"添加引号"/"添加括号"按钮使用。插入成对符号后光标移到中间位置。
  /// - 引号 `""`：光标在两个引号之间
  /// - 括号 `()`：光标在两个括号之间
  void _handleInsertText(String text, int cursorOffset) {
    if (_isInputLocked) return; // 锁定期间插入类改写全部无效
    _inputKey.currentState?.insertAtCursor(
      text,
      cursorOffsetFromStart: cursorOffset,
    );
  }

  /// 2026-07-29 推荐回复：选择某条候选回复
  ///
  /// 从 controller 获取选中条文本，插入到输入框光标位置。
  /// 不清空候选列表（用户可能想再选其他条）。
  void _handleSelectSuggest(AdvancedChatController controller, int index) {
    final selected = controller.selectSuggestReply(index);
    if (selected != null) {
      _inputKey.currentState?.insertAtCursor(selected);
    }
  }

  /// 发送消息：检测残留 pendingUserMessage 时弹确认框
  ///
  /// P3 修订（DOC-09A-2 §6.5）：失败/取消后 pendingUserMessage 保留在 UI。
  /// 若用户未处理旧消息就发新消息，弹确认框询问是否覆盖，避免静默丢失。
  Future<void> _handleSend(String userInput) async {
    final session = widget.session;
    final currentState = ref.read(advancedChatControllerProvider(session));
    final controller = ref.read(
      advancedChatControllerProvider(session).notifier,
    );
    final queueing = controller.canQueueMessage;
    if (!queueing &&
        currentState.phase != IntermediatePhase.idle &&
        currentState.phase != IntermediatePhase.failed) {
      _inputKey.currentState?.setText(userInput);
      return;
    }
    if (!queueing &&
        currentState.pendingUserMessage != null &&
        (controller.hasRetainedInput ||
            currentState.phase != IntermediatePhase.failed)) {
      final t = Translations.of(context);
      final confirmed = await context.lmUi.confirmDialog(
        context,
        title: t.advanced.chat.messageActions.overwritePendingTitle,
        content: t.advanced.chat.messageActions.overwritePendingConfirm,
        confirmLabel: t.common.confirm,
      );
      if (!mounted || widget.session != session) return;
      if (!confirmed) {
        _inputKey.currentState?.setText(userInput);
        return;
      }
    }
    // 生成中发送 → 单槽待发；槽位已占用时先确认覆盖（不静默丢已有待发）
    var overwriteQueued = false;
    if (queueing && currentState.queuedMessage != null) {
      final t = Translations.of(context);
      final confirmed = await context.lmUi.confirmDialog(
        context,
        title: t.advanced.queue.overwriteTitle,
        content: t.advanced.queue.overwriteConfirm(
          queued: currentState.queuedMessage!,
        ),
        confirmLabel: t.common.confirm,
      );
      if (!confirmed || !mounted) {
        _inputKey.currentState?.setText(userInput);
        return;
      }
      overwriteQueued = true;
    }
    if (!mounted || widget.session != session) return;
    if (queueing != controller.canQueueMessage ||
        (overwriteQueued &&
            ref.read(advancedChatControllerProvider(session)).queuedMessage !=
                currentState.queuedMessage)) {
      _inputKey.currentState?.setText(userInput);
      return;
    }
    // 发送消息：立即释放 Demo 输入锁并清空输入框、收起软键盘
    final bridge = ref.read(demoBridgeProvider);
    bridge?.inputLock.release();
    _inputKey.currentState?.clear();
    _draftDebounce?.cancel();
    FocusScope.of(context).unfocus();

    final consumed = await controller.sendMessage(
      userInput,
      overwriteQueued: overwriteQueued,
    );
    if (!mounted || widget.session != session) return;
    if (!consumed) {
      _inputKey.currentState?.setText(userInput);
      if (ref.read(dataStoreOperationGuardProvider).isOverwriting) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.common.backupOverwriteInProgress),
          ),
        );
      }
      return;
    }
    if (queueing) return;
    if (_inputKey.currentState?.currentText.isEmpty ?? true) {
      _draftDebounce?.cancel();
      _persistDraftColumn(session, '');
    }
  }

  /// 单槽待发消息条：显示排队内容 + 撤回（退还输入框可编辑）
  Widget _buildQueuedMessageChip(AdvancedChatState state) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final queued = state.queuedMessage;
    if (queued == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.schedule, size: 16, color: colors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t.advanced.queue.chip(text: queued),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.ink,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final session = widget.session;
                final restored = await ref
                    .read(advancedChatControllerProvider(session).notifier)
                    .withdrawQueuedMessage();
                if (mounted && widget.session == session && restored != null) {
                  _inputKey.currentState?.setText(restored);
                }
              },
              child: Text(t.advanced.queue.withdraw),
            ),
          ],
        ),
      ),
    );
  }

  /// 复制消息内容到剪贴板，并显示 SnackBar 反馈
  void _handleCopy(ChatMessage message) {
    final content = message.content ?? '';
    if (content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: content));
    final t = Translations.of(context);
    // 与 chat 修复口径一致——floating + 防叠
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.advanced.chat.messageActions.copySuccess,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
  }

  /// 重新生成：pendingUserMessage → 重发本轮（未落库，无 DB 删除）；
  /// 已持久化消息 → regenerateMessage（保留 user_N，删 assistant_N + 下游重写）
  ///
  /// 2026-08-17 修复：此前 pending 气泡/悬空末尾 user 消息点「重新生成」
  /// 会静默 no-op（regenerateMessage 找不到成对 assistant 直接 return）。
  Future<void> _handleRegenerate(ChatMessage message) async {
    final currentState = ref.read(
      advancedChatControllerProvider(widget.session),
    );
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    if (currentState.pendingUserMessage?.messageId == message.messageId) {
      await controller.retryPendingUserMessage();
      return;
    }
    await controller.regenerateMessage(message);
  }

  /// 编辑消息（保存 / 保存并发送）
  ///
  /// - pendingUserMessage：保存更新待重试文本；保存并发送=editPendingUserMessage
  /// - 已持久化用户消息：保存=editMessageContent；保存并发送=editAndResend
  /// - 已持久化助手消息：只有保存=editMessageContent
  Future<void> _handleEdit(ChatMessage message) async {
    final session = widget.session;
    final provider = advancedChatControllerProvider(session);
    final currentState = ref.read(provider);
    final controller = ref.read(provider.notifier);
    final isPending =
        currentState.pendingUserMessage?.messageId == message.messageId;
    final isRetained = isPending && controller.hasRetainedInput;

    final allowResend = isPending || message.role == 'user';

    final result = await context.lmUi.editDialog(
      context,
      initialContent: message.content ?? '',
      allowResend: allowResend,
      saveBeforeClosing: isRetained
          ? (content) async {
              if (!mounted ||
                  widget.session != session ||
                  ref.read(provider).pendingUserMessage?.messageId !=
                      message.messageId) {
                return false;
              }
              return controller.updatePendingUserMessageContent(content);
            }
          : null,
      saveErrorMessage: isRetained ? t.advanced.failure.inputSaveFailed : null,
    );
    if (result == null || !mounted || widget.session != session) return;

    if (isRetained) {
      if (result.resend) await controller.retryPendingUserMessage();
    } else if (isPending) {
      if (result.resend) {
        await controller.editPendingUserMessage(result.content);
      } else {
        await controller.updatePendingUserMessageContent(result.content);
      }
    } else if (result.resend) {
      await controller.editAndResend(message, result.content);
    } else {
      await controller.editMessageContent(message, result.content);
    }
  }

  /// 删除整轮 / 删除 pendingUserMessage
  ///
  /// P3 修订：检测 targetMessage 是否为 pendingUserMessage（未持久化）。
  /// - 是 pendingUserMessage → 调 controller.deletePendingUserMessage
  /// - 否 → 调 controller.deleteRound（删 DB 记录）
  /// 两种场景用不同确认文案，让用户清楚自己在删什么。
  Future<void> _handleDeleteRound(ChatMessage message) async {
    final currentState = ref.read(
      advancedChatControllerProvider(widget.session),
    );
    final isPending =
        currentState.pendingUserMessage?.messageId == message.messageId;

    final t = Translations.of(context);
    final confirmed = await context.lmUi.confirmDialog(
      context,
      title: isPending
          ? t.advanced.chat.messageActions.deletePendingTitle
          : t.advanced.chat.messageActions.deleteTitle,
      content: isPending
          ? t.advanced.chat.messageActions.deletePendingConfirm
          : t.advanced.chat.messageActions.deleteConfirm,
      confirmLabel: t.common.delete,
    );
    if (!confirmed || !mounted) return;

    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    if (isPending) {
      await controller.deletePendingUserMessage();
    } else {
      await controller.deleteRound(message);
    }
  }

  /// 撤销压缩（U2，2026-09-04）：控制器守卫兜底，结果用 snackbar 反馈
  Future<void> _handleUndoCompaction() async {
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    final ok = await controller.undoCompaction();
    if (!mounted) return;
    final t = Translations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          ok
              ? t.advanced.chat.compaction.undoSuccess
              : t.advanced.chat.compaction.undoFailed,
        ),
      ),
    );
  }

  // ── 上下文用量指示（上下文用量指示设计 §4.1/§4.3）────────────────

  /// 最近一次主请求的协议原生 prompt（兼容旧面板字段/旧日志）
  int? _latestLastPromptTokens(AdvancedChatState state) {
    final summary = state.latestHistoryTurnSummary;
    if (summary?.lastPromptTokens != null) return summary!.lastPromptTokens;
    return state.backfilledPromptTokens;
  }

  /// 主数字：当前预计上下文（压缩后为本地调整值；null = 无数据）
  ///
  /// 不回退历史实报：重进会话/压缩后没有有效估算时保持「—」，
  /// 不把压缩前的旧请求输入复活成当前值。
  int? _currentEstimateTokens(AdvancedChatState state) {
    return state.contextEstimate?.tokens;
  }

  /// 主数字是否为本地估算
  bool _currentEstimateIsLocal(AdvancedChatState state) =>
      state.contextEstimate?.isEstimated ?? false;

  /// 上下文构成段——装配期四段字符占比 × 最近请求 promptTokens
  ///
  /// 真实分段 token 供应商接口不提供：按字符占比把最近一次请求的输入
  /// 拆到各段（面板内有估算口径标注）；无请求数据时仅展示占比。
  List<ContextCompositionSegment>? _compositionSegments(
    AdvancedChatState state,
    Translations t,
  ) {
    final chars = state.contextSegmentChars;
    if (chars == null || chars.isEmpty) return null;
    final totalChars = chars.values.fold<int>(0, (a, b) => a + b);
    if (totalChars <= 0) return null;
    // 与主数字同基准，保证各分项相加 ≈ 主数字（压缩后主数字已调整）
    final prompt = _currentEstimateTokens(state);
    final labels = <String, String>{
      'system': t.advanced.contextComposition.system,
      'coreBlocks': t.advanced.contextComposition.coreBlocks,
      'history': t.advanced.contextComposition.history,
      'directive': t.advanced.contextComposition.directive,
    };
    return [
      for (final entry in labels.entries)
        if ((chars[entry.key] ?? 0) > 0)
          ContextCompositionSegment(
            label: entry.value,
            fraction: (chars[entry.key] ?? 0) / totalChars,
            tokens: prompt == null
                ? null
                : ((chars[entry.key] ?? 0) / totalChars * prompt).round(),
          ),
    ];
  }

  /// 上下文用量详情面板（sheet 内 Consumer watch，流式打字自动刷新）
  void _showContextCapacitySheet() {
    unawaited(
      showLmSheet<void>(
        context: context,
        // 面板自限 0.9 屏高 + 内部滚动兜底（压缩流式区出现时不被 9/16
        // 默认上限挤压溢出）
        isScrollControlled: true,
        builder: (_) => Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(
              advancedChatControllerProvider(widget.session),
            );
            // 数字、命中率与异常标识必须整组取自同一样本（最新轮摘要，
            // 或整组事件回填），不得一半摘要一半回填拼接。
            final requestUsage = state.latestMainRequestUsage;
            final history = state.historyUsageStatistics;
            return ContextUsageDetailSheet(
              contextWindowTokens: state.contextWindowTokens,
              compactionTriggerTokens: state.compactionTriggerTokens,
              lastPromptTokens:
                  requestUsage?.promptTokens ?? _latestLastPromptTokens(state),
              // 主数字（当前预计）与最近请求实报分开，避免把历史值当当前值
              currentEstimateTokens: _currentEstimateTokens(state),
              currentEstimateIsLocal: _currentEstimateIsLocal(state),
              lastRequestInputTokens: requestUsage?.inputTokens,
              requestInputIsComplete: true,
              lastCompletionTokens: requestUsage?.completionTokens,
              lastCacheReadTokens: requestUsage?.cacheReadTokens,
              lastCacheHitRatio: state.latestMainRequestCacheHitRatio,
              lastCacheSampleInvalid: state.latestMainRequestCacheSampleInvalid,
              averageCacheHit: history.averageCacheHit,
              cacheCoveredRounds: history.cacheCoveredRounds,
              sessionRounds: history.sessionRounds,
              // 上下文构成（导演侧装配期埋点；无数据不渲染）
              composition: _compositionSegments(state, t),
              compositionNote: t.advanced.contextComposition.estimateNote,
              isManualCompacting: state.isManualCompacting,
              manualCompactionDelta: state.manualCompactionDelta,
              manualCompactionError: state.manualCompactionError,
              // 生成/压缩轮进行中按钮置灰（controller busy 守卫兜底）
              isRoundActive: state.phase != IntermediatePhase.idle &&
                  state.phase != IntermediatePhase.failed,
              onManualCompact: () {
                // 消费返回值——insufficient/busy 不再静默无反馈
                final messenger = ScaffoldMessenger.of(context);
                unawaited(
                  ref
                      .read(
                        advancedChatControllerProvider(widget.session).notifier,
                      )
                      .manualCompact()
                      .then((result) {
                    if (!mounted) return;
                    switch (result) {
                      case ManualCompactResult.insufficient:
                        messenger.showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            content: Text(
                              t.common.contextRing.compactInsufficient,
                            ),
                          ),
                        );
                      case ManualCompactResult.busy:
                        messenger.showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            content: Text(t.common.contextRing.compactBusy),
                          ),
                        );
                      case ManualCompactResult.failed:
                        // 失败详情走 manualCompactionError（面板内展示）
                        break;
                      case ManualCompactResult.success:
                        // 2026-09-08：成功不再静默——用户反馈「不知道压缩
                        // 有没有成功」。摘要卡已随重载插入会话顶部，此处
                        // SnackBar 给出明确终点反馈。
                        messenger.showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            content: Text(t.common.contextRing.compactDone),
                          ),
                        );
                    }
                  }),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _WorldStatusNavChip extends StatefulWidget {
  const _WorldStatusNavChip({
    required this.active,
    required this.onTap,
  });

  final bool active;
  final VoidCallback onTap;

  @override
  State<_WorldStatusNavChip> createState() => _WorldStatusNavChipState();
}

class _WorldStatusNavChipState extends State<_WorldStatusNavChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final radius = BorderRadius.circular(context.lmUi.radius(LmCorner.full));

    return Center(
      child: Tooltip(
        message: t.advanced.worldSheet.entryTooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('director-world-status-entry'),
              onTap: widget.onTap,
              borderRadius: radius,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Center(
                  child: AnimatedContainer(
                    duration: LmMotion.durationFor(context, LmMotion.micro),
                    padding: const EdgeInsets.symmetric(
                      horizontal: IntermediateSpacing.sMd,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(
                        alpha: widget.active || _hovered ? 0.16 : 0.10,
                      ),
                      borderRadius: radius,
                      border: Border.all(
                        color: colors.primary.withValues(
                          alpha: widget.active ? 0.48 : 0.28,
                        ),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      t.advanced.worldSheet.entryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IntermediateTextStyles.captionSm.copyWith(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// AdvancedChatController Provider
///
/// 仿 chatModeControllerProvider，按 ChatSession.family 创建。
/// 导演依赖（事实层仓库 / durable 事件日志 / 压缩服务）只注入这里——
/// 故事模式的 intermediateChatControllerProvider 不再构造任何导演依赖。
/// 导演 GM 可解析性（空态配置引导横幅显隐判定）。
///
/// 判定链同 resolveAdvancedGeneratingNamingConfig：会话级→全局级
/// generating 模型与 Key 任一缺位即 null。key 为当前会话对象。
final directorGmReadyProvider =
    FutureProvider.autoDispose.family<bool, ChatSession>((ref, session) async {
  final resolver = ref.read(configurationResolverProvider);
  return await resolver.resolveAdvancedGeneratingNamingConfig(session) != null;
});

final advancedChatControllerProvider = StateNotifierProvider.family<
    AdvancedChatController, AdvancedChatState, ChatSession>((ref, session) {
  return AdvancedChatController(
    operationGuard: ref.read(dataStoreOperationGuardProvider),
    chatRepository: ref.read(chatRepositoryProvider),
    configurationResolver: ConfigurationResolver(
      presetRepository: ref.read(apiPresetRepositoryProvider),
      settingsRepository: ref.read(settingsRepositoryProvider),
      logger: ref.read(loggerProvider),
    ),
    llmService: ref.read(llmServiceProvider),
    experienceRepository: ref.read(experienceRepositoryProvider),
    embeddingService: ref.read(embeddingServiceProvider),
    persistenceService: ref.read(intermediatePersistenceServiceProvider),
    failureLogRepository: ref.read(failureLogRepositoryProvider),
    tokenCounter: ref.read(tokenCounterProvider),
    getConfig: () => ref.read(advancedConfigProvider.future),
    logger: ref.read(loggerProvider),
    session: session,
    titleGenerator: SessionTitleGenerator(
      llmService: ref.read(llmServiceProvider),
    ),
    consolidator: MemoryConsolidator(
      llmService: ref.read(llmServiceProvider),
    ),
    // 事实层仓库（agent loop 的 query_facts/update_facts）
    factualRepository: ref.read(factualRepositoryProvider),
    // 导演轮轮前压缩（与故事模式共用压缩服务）
    compactionService: ref.read(intermediateCompactionServiceProvider),
    // v0.3 体验重构 ：durable 事件日志（崩溃恢复 + 过程审计）
    // 散建收口——统一读组合根 provider
    agentEventLogRepository: ref.read(agentEventLogRepositoryProvider),
    // 工程上下文模式原子切换（同一仓库实例实现该接口）
    engineeringContextSwitch: ref.read(agentEventLogRepositoryProvider),
    // 工程压缩事务服务（开启态；生产摘要器按轮懒解析 GM 配置与
    // 账本冻结前缀）
    engineeringCompaction: EngineeringCompactionService(
      database: ref.read(appDatabaseProvider),
      eventRepository: ref.read(agentEventLogRepositoryProvider),
      chatRepository: ref.read(chatRepositoryProvider),
      experienceRepository: ref.read(experienceRepositoryProvider),
      summarizer: _SessionEngineeringSummarizer(
        llmService: ref.read(llmServiceProvider),
        session: session,
        resolver: ref.read(configurationResolverProvider),
        eventRepository: ref.read(agentEventLogRepositoryProvider),
      ),
      // 压缩参数缺省同样来自配置段（配置未加载的瞬时窗口回落解析
      // 兜底默认，值与 JSON 相同；触发/选材/溢出路径按轮以会话实际值
      // 与真实 maxTokens 再覆写）
      tuning: EngineeringCompactionTuning.fromConfig(
        ref.read(advancedConfigProvider).valueOrNull?.engineeringCompaction ??
            const AdvancedEngineeringCompactionConfig(),
      ),
      logger: ref.read(loggerProvider),
    ),
    // 向导「初始化你的角色」卡路径：物化时应用卡（服务无状态，即建即用）
    resourceApplyService: ResourceApplyService(
      resourceRepository: ref.read(resourceLibraryRepositoryProvider),
      projectionService: ResourceProjectionService(
        repository: ref.read(factualRepositoryProvider),
      ),
    ),
    capabilitiesOverride: ref.watch(agentCapabilitiesOverrideProvider),
  );
});

/// 工程摘要器的会话级代理：每次调用按当前 GM 配置与账本冻结前缀构建
/// 共享前部式请求（轮中切换模型后摘要请求随新配置——不做跨模型缓存
/// 命中预期）。
class _SessionEngineeringSummarizer implements EngineeringSummarizer {
  _SessionEngineeringSummarizer({
    required LlmService llmService,
    required this.session,
    required ConfigurationResolver resolver,
    required AgentEventLogRepository eventRepository,
  })  : _llmService = llmService,
        _resolver = resolver,
        _eventRepository = eventRepository;

  final LlmService _llmService;
  final ChatSession session;
  final ConfigurationResolver _resolver;
  final AgentEventLogRepository _eventRepository;

  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async {
    final naming = await _resolver.resolveAdvancedGeneratingNamingConfig(
      session,
    );
    if (naming == null) {
      throw StateError(t.advanced.settings.engineeringSummaryNeedsModel);
    }
    final events = await _eventRepository.readEvents(sessionId);
    final frozen = DirectorSurfaceV2.latestFrozenPrefixOf(events) ?? '';
    return LlmEngineeringSummarizer(
      llmService: _llmService,
      namingConfig: naming,
      frozenPrefix: frozen,
    ).summarize(
      sessionId: sessionId,
      intervalMessages: intervalMessages,
      narrativeBoundaryTurn: narrativeBoundaryTurn,
      tools: tools,
      onDelta: onDelta,
    );
  }
}
