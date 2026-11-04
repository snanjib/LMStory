import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/model_config_banner.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/advanced/presentation/pages/director_chat_body.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_export_sheet.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_hitl_banner.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_script_board_sheet.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_session_settings_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_projection_service.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/director_settings_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/font_size_selector_section.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/manual_compact_result.dart';
import 'package:lmstory/features/story_runtime/domain/services/memory_consolidator.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/failure_bar.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/intermediate_chat_input.dart';
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

  /// 未发送草稿窄列持久化（fire-and-forget；空串=清空，发送后调用）。

  /// 输入文本变化 → 防抖 500ms 落库（退出兜底主力；dispose 只取消）。
  void _onDraftTextChanged(String text) {
    _draftDebounce?.cancel();
    final sessionId = widget.session.sessionId;
    // lm-motion-exempt: 草稿落库去抖（交互节流，非过渡动效）
    _draftDebounce = Timer(const Duration(milliseconds: 500), () {
      _persistDraftColumn(sessionId, text);
    });
  }

  void _persistDraftColumn(String sessionId, String text) {
    // 同步+异步双兜底：持久化失败静默降级（草稿非关键路径，不炸页面）
    unawaited(
      () async {
        try {
          await ref
              .read<ChatRepository>(chatRepositoryProvider)
              .setSessionDraft(sessionId, text.isEmpty ? null : text);
        } catch (_) {}
      }(),
    );
  }

  /// 跨重启恢复：页面级 Map 未命中时读库（输入框仍空才落，不覆盖新输入）。
  Future<void> _restoreDraftFromDb(String sessionId) async {
    final String? draft;
    try {
      draft = await ref
          .read<ChatRepository>(chatRepositoryProvider)
          .getSessionDraft(sessionId);
    } catch (_) {
      return; // 读库失败静默降级（不炸页面）
    }
    if (!mounted || draft == null || draft.isEmpty) return;
    if (widget.session.sessionId != sessionId) return;
    final current = _inputKey.currentState?.currentText ?? '';
    if (current.isEmpty) {
      _inputKey.currentState?.setText(draft);
    }
  }

  final GlobalKey<IntermediateChatInputState> _inputKey =
      GlobalKey<IntermediateChatInputState>();

  // 底部输入区域（InputToolbar + IntermediateChatInput）实际高度。
  // 用于 SnackBar margin 计算：SnackBar 上移至输入框上方，避免遮挡。
  double _bottomAreaHeight = 100;
  final _bottomAreaKey = GlobalKey();
  bool _bottomAreaMeasurementScheduled = false;

  // 2026-07-22 修复：历史消息加载已移至 AdvancedChatController 构造函数，
  // 与 ChatModeController 一致。之前在 initState 中调用 loadHistory()，
  // 但故事模式->故事模式切换会话时 State 被复用（widget 类型相同且无 key），
  // initState 不重新调用，导致新会话消息不加载、UI 显示空状态。

  @override
  void dispose() {
    _draftDebounce?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scheduleBottomAreaMeasurement();
    // 页面首次创建时检查是否需要回写草稿（如异常中断后重新进入）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tryRestoreDraft();
      // 跨重启恢复：控制器 userInput 无待恢复时读库（Map 冷启动恒空）
      if (mounted) unawaited(_restoreDraftFromDb(widget.session.sessionId));
    });
    _loadPureReadingPreference();
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
      // 会话切换重置 HITL 首释解释——
      // State 复用导致第二/三个会话的首张 ask/审批横幅永远错过解释行
      _hitlIntroShown = false;
      // 同族修正：嵌入横幅的「切换会话后重新检测」承诺此前同样被 State
      // 复用吞掉（dismissed 标志跨会话残留）
      _embeddingBannerDismissed = false;
      // 纯净阅读按会话重载
      _loadPureReadingPreference();
      // 切走前暂存未发送文字（与故事模式同款）
      final oldText = _inputKey.currentState?.currentText ?? '';
      if (oldText.isNotEmpty) {
        _inputDrafts[oldWidget.session.sessionId] = oldText;
      } else {
        _inputDrafts.remove(oldWidget.session.sessionId);
      }
      _draftDebounce?.cancel();
      _persistDraftColumn(oldWidget.session.sessionId, oldText);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final state = ref.read(advancedChatControllerProvider(widget.session));
        final restorable = state.pendingUserMessage == null &&
            state.userInput != null &&
            state.userInput!.isNotEmpty &&
            state.phase == IntermediatePhase.idle;
        if (restorable) {
          _tryRestoreDraft();
        } else {
          // 无待恢复草稿时优先用页面级暂存，都没有才清空（防串台）
          final stashed = _inputDrafts[widget.session.sessionId] ?? '';
          if (stashed.isNotEmpty) {
            _inputKey.currentState?.setText(stashed);
          } else {
            _inputKey.currentState?.setText('');
            // 跨重启恢复：同 State 会话内暂存未命中时读库
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
    final state = ref.read(
      advancedChatControllerProvider(widget.session),
    );
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
    final state = ref.watch(
      advancedChatControllerProvider(widget.session),
    );

    // 监听 state 变化：中断后（cancel/recoverIfStuck/clearRound 清空
    // pendingUserMessage + 保留 userInput）自动回写到输入框
    ref.listen<AdvancedChatState>(
      advancedChatControllerProvider(widget.session),
      (previous, next) {
        if (previous?.pendingUserMessage != null &&
            next.pendingUserMessage == null &&
            next.userInput != null &&
            next.userInput!.isNotEmpty &&
            next.phase == IntermediatePhase.idle) {
          _tryRestoreDraft();
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
        child: context.lmUi
            .entryTransition(context, child: _buildScaffold(context, state)),
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
    return Scaffold(
      key: widget.scaffoldKey,
      drawer: widget.drawer,
      // 琉璃结构：透明底透出场地渐变；阅读/流式区零 blur（红线）。
      backgroundColor: context.scaffoldBgOf(colors.bg),
      appBar: AppBar(
        leading: widget.onBackToHome != null
            ? IconButton(
                //  语义缺口：复用框架本地化文案（不新增 i18n key）。
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBackToHome,
              )
            : widget.showHamburgerMenu
                ? IconButton(
                    //  语义缺口：复用框架本地化文案（不新增 i18n key）。
                    tooltip:
                        MaterialLocalizations.of(context).openAppDrawerTooltip,
                    icon: const Icon(Icons.menu),
                    onPressed: widget.onHamburgerPressed,
                  )
                : null,
        title: Text(
          state.session.title,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: context.scaffoldBgOf(colors.bg),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        actions: [
          // 纯净阅读模式切换——隐藏全部幕后
          // 只留稿件流+Recap（按会话记忆偏好）
          IconButton(
            icon: Icon(
              _pureReading ? Icons.auto_stories : Icons.auto_stories_outlined,
            ),
            tooltip: t.advanced.pureReading.toggle,
            isSelected: _pureReading,
            onPressed: _togglePureReading,
          ),
          // 会话菜单——稿件导出 / 场记板 / 更新标题
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: t.advanced.export.menuLabel,
            onSelected: (value) {
              switch (value) {
                case 'export':
                  _showExportSheet();
                case 'script-board':
                  _showScriptBoard();
                case 'update-title':
                  _updateSessionTitle();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    const Icon(Icons.file_download_outlined, size: 18),
                    const SizedBox(width: IntermediateSpacing.sSm),
                    Text(t.advanced.export.menuLabel),
                  ],
                ),
              ),
              // 场记板——「AI 眼中的现在」只读视图
              PopupMenuItem(
                value: 'script-board',
                child: Row(
                  children: [
                    const Icon(Icons.movie_creation_outlined, size: 18),
                    const SizedBox(width: IntermediateSpacing.sSm),
                    Text(t.advanced.scriptBoard.menuLabel),
                  ],
                ),
              ),
              // 手动更新标题
              PopupMenuItem(
                value: 'update-title',
                enabled: !isGenerating,
                child: Row(
                  children: [
                    const Icon(Icons.title_outlined, size: 18),
                    const SizedBox(width: IntermediateSpacing.sSm),
                    Text(t.advanced.settings.updateTitle),
                  ],
                ),
              ),
            ],
          ),
          // 会话设置入口：弹出 IntermediateSessionSettingsSheet
          // 生成中也可查看设置（sheet 内部通过 phase 守卫禁用控件）
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            // 导演侧专用键（原借用故事模式文案）
            tooltip: t.advanced.sessionSettingsTitle,
            onPressed: _showSessionSettings,
          ),
        ],
      ),
      // 2026-08-02 修复 v5（一次性全部 4 场景 + 正常状态无空白）。
      // 历史失败原因：
      // v1: Flexible(loose) 不强制收缩 + 内层估算高度不准
      // v2: LayoutBuilder 放 Column 末尾非 Flexible child → height unbounded → ∞
      // v3: Flexible(tight, flex=4/2) → 收起态撑满份额 → 大片空白
      // v3.1: 去 Flexible → Column(mainAxisSize.min) + ConstrainedBox(minHeight=0)
      //       → Flutter 视为"自然高度"，展开详情直接溢出
      // v4: SizedBox(height=H*70%) + SingleChildScrollView
      //       → 正常状态（无 FailureBar）强行占 70% body 高度 → 输入框跑到屏幕中间
      //
      // v5 最终方案（差异化架构，正常/失败态分别处理）：
      // - Scaffold body 整体 LayoutBuilder，拿到 bodyMaxHeight 用于后续计算
      // - 正常状态（phase != failed）：底部区直接用 Column(mainAxisSize.min)，
      //   不强制占比，紧贴屏幕底部，无空白。外层无限高，内部各自渲染。
      // - 失败状态（phase == failed）：底部区外层套
      //   ConstrainedBox(maxHeight: H × 55%/70%) + SingleChildScrollView
      //   → 终极兜底。FailureBar 详情、SuggestOverlay、工具栏、输入框叠加
      //   高度超过 bottomMaxHeight 时内部滚动，不溢出黄黑条纹。
      // - FailureBar 双层约束：外层 ConstrainedBox(maxHeight: bottomMaxHeight×60%)
      //   + 内部 Container(maxHeight) + SingleChildScrollView。
      // - 收起态 FailureBar 用 mainAxisSize.min 只占自身高度，不留空白。
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bodyMaxHeight = constraints.maxHeight;
          final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
          final isFailed = state.phase == IntermediatePhase.failed &&
              state.failureContext != null;

          // 只有失败态才需要计算最大高度；正常态不限高，按自然高度紧贴底部
          final bottomMaxHeight =
              isFailed ? bodyMaxHeight * (keyboardOpen ? 0.55 : 0.70) : null;

          // FailureBar 最大可用高度（失败态 + 键盘弹出时受限）
          final failureBarMaxHeight =
              (isFailed && keyboardOpen && bottomMaxHeight != null)
                  ? bottomMaxHeight * 0.60
                  : null;

          final hasSuggestOverlay = _shouldShowSuggestOverlay(state);

          return Column(
            children: [
              // 体验重构 ：ask_user 横幅（导演决策）与监督模式审批横幅。
              // 头部 muted 倒计时（超时值读 advanced.hitl 配置，0=一直等待）；
              // 每会话首张 HITL 横幅多一行首释解释。
              // 重排版：卡框统一由 viewport 提供（滚动
              // 溢出提示+描边），选项改整行按钮后内容更高——限高从 55%/45%
              // 放宽到 62%/50%，决策时刻以看清选项优先。
              if (state.agentAskPrompt != null ||
                  state.agentApprovalPrompt != null)
                DirectorDecisionViewport(
                  maxHeight: bodyMaxHeight * (keyboardOpen ? 0.50 : 0.62),
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
                            if (mounted) setState(() => _hitlIntroShown = true);
                          },
                          fontScale: fontScale,
                        ),
                      if (state.agentApprovalPrompt != null) ...[
                        // 双横幅同现（罕见）：一张卡框内用分隔线区隔
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
                            if (mounted) setState(() => _hitlIntroShown = true);
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              // 空态 GM 未配置引导（发送前必配，置于嵌入横幅之上）
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
              // 2026-07-21：未配置 embedding 模型时常驻提示 Banner
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
              // 消息列表：占剩余空间（导演模式专属 harness 消息区）
              Expanded(
                child: DirectorChatBody(
                  state: state,
                  pureReading: _pureReading,
                  fontScale: fontScale,
                  onCopy: _handleCopy,
                  onRegenerate: _handleRegenerate,
                  onEdit: _handleEdit,
                  onDeleteRound: _handleDeleteRound,
                  onUseExample: (example) =>
                      _inputKey.currentState?.setText(example),
                  initialFocusMessageId: widget.initialFocusMessageId,
                  // 体验重构 ：与故事模式同源（fork.regenerateWindowRounds）
                  windowRounds: windowRounds,
                  // U2（2026-09-04 撤销压缩）：与故事模式同构
                  onUndoCompaction: _handleUndoCompaction,
                  // 稿件变体切换/删除/高亮消费
                  onSwitchVariant: controller.switchMessageVariant,
                  onDeleteVariant: controller.deleteMessageVariant,
                  onVariantFlashConsumed: controller.clearVariantFlash,
                  // Recap 卡编辑当前剧情锚（写入走与 AI 同一数据源）
                  onEditAnchor: (anchor) async {
                    final ok = await controller.updateStoryAnchor(anchor);
                    if (!context.mounted) return;
                    final t = Translations.of(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(
                          ok
                              ? t.advanced.anchorEdit.saved
                              : t.advanced.anchorEdit.saveBlocked,
                        ),
                      ),
                    );
                  },
                ),
              ),
              // ── 底部区域：正常态/失败态分架构 ────────────────────
              if (!isFailed)
                // 正常态：Column(mainAxisSize.min)，按自然高度，紧贴底部。
                // 不套任何 SizedBox/ConstrainedBox 以免留下空白。
                Column(
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
                          onSelect: (index) =>
                              _handleSelectSuggest(controller, index),
                          onClose: controller.closeSuggest,
                          onToggle: controller.toggleSuggest,
                          onRetry: controller.generateSuggestReplies,
                        ),
                      ),
                    // 输入区域（工具栏 + 输入框）：用 GlobalKey 测量实际高度，
                    // 供 SnackBar margin 计算使用
                    SizeChangedLayoutNotifier(
                      child: Container(
                        key: _bottomAreaKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            context.lmUi.inputToolbar(
                              context,
                              onAddQuote: () => _handleInsertText('""', 1),
                              onAddParen: () => _handleInsertText('()', 1),
                              onSuggest: controller.generateSuggestReplies,
                              isGeneratingSuggest: state.isGeneratingSuggest,
                              canSuggest: state.messages.isNotEmpty,
                              // 上下文圆环 chip 挂工具栏行末（满刻度=
                              // 压缩触发线；12px 边距由 toolbar 自带 padding）
                              trailing: ContextUsageChip(
                                numerator: _latestLastPromptTokens(state),
                                denominator: state.compactionTriggerTokens,
                                onTap: _showContextCapacitySheet,
                              ),
                            ),
                            IntermediateChatInput(
                              key: _inputKey,
                              phase: state.phase,
                              isStopping: state.isStopping,
                              //  同族：手动压缩中禁用
                              // 发送（控制器静默 no-op，UI 须同口径）
                              isManualCompacting: state.isManualCompacting,
                              isDirector: true,
                              onSend: _handleSend,
                              onTextChanged: _onDraftTextChanged,
                              onCancel: controller.cancel,
                              sendKey: sendKey,
                              newlineKey: newlineKey,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              else
                // 失败态：外层 ConstrainedBox(maxHeight) 限制底部区总高。
                // v6.1 修复：v6 把所有组件都包在一个 SingleChildScrollView 里 →
                // 输入框也会被滚走，违背直觉。v6.1 拆分：只有 FailureBar +
                // SuggestOverlay 参与滚动，工具栏 + 输入框永远固定在底部。
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: bottomMaxHeight!),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 可滚动区域：FailureBar + SuggestOverlay
                      // Flexible(loose) 占剩余空间但不超过，内容不满时
                      // 只占自身高度（无空白），超高时 SingleChildScrollView 滚动。
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FailureBar(
                                failureContext: state.failureContext!,
                                onRetry: controller.retry,
                                onClear: () {
                                  controller.clearRound();
                                  _tryRestoreDraft();
                                },
                                onContinueWithFts5:
                                    controller.continueWithFts5Only,
                                onContinueFromFailed:
                                    controller.continueFromFailed,
                                maxHeight: failureBarMaxHeight,
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
                                    onSelect: (index) =>
                                        _handleSelectSuggest(controller, index),
                                    onClose: controller.closeSuggest,
                                    onToggle: controller.toggleSuggest,
                                    onRetry: controller.generateSuggestReplies,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      // 固定区域：工具栏 + 输入框，永远不滚动，始终在底部
                      // 用 GlobalKey 测量实际高度，供 SnackBar margin 计算
                      SizeChangedLayoutNotifier(
                        child: Container(
                          key: _bottomAreaKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              context.lmUi.inputToolbar(
                                context,
                                onAddQuote: () => _handleInsertText('""', 1),
                                onAddParen: () => _handleInsertText('()', 1),
                                onSuggest: controller.generateSuggestReplies,
                                isGeneratingSuggest: state.isGeneratingSuggest,
                                canSuggest: state.messages.isNotEmpty,
                                // 上下文圆环 chip（失败态分支同款）
                                trailing: ContextUsageChip(
                                  numerator: _latestLastPromptTokens(state),
                                  denominator: state.compactionTriggerTokens,
                                  onTap: _showContextCapacitySheet,
                                ),
                              ),
                              IntermediateChatInput(
                                key: _inputKey,
                                phase: state.phase,
                                isStopping: state.isStopping,
                                //  同族：手动压缩中禁用
                                // 发送（失败态分支同款）
                                isManualCompacting: state.isManualCompacting,
                                isDirector: true,
                                onSend: _handleSend,
                                onTextChanged: _onDraftTextChanged,
                                onCancel: controller.cancel,
                                sendKey: sendKey,
                                newlineKey: newlineKey,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
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
  /// 数据取 provider 当前 state（messages/artifactsByTurnNumber 已由
  /// loadHistory 装配），导出全程只读，生成中也可导出已完成幕。
  Future<void> _showExportSheet() async {
    final state = ref.read(advancedChatControllerProvider(widget.session));
    await DirectorExportSheet.show(context, state);
  }

  /// 弹出场记板（「AI 眼中的现在」）。
  ///
  /// 数据由 controller.loadScriptBoard 现算，与 runner 注入面同源
  /// （assembleDirectorCoreBlocks）；只读，随时可看。
  Future<void> _showScriptBoard() async {
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    await DirectorScriptBoardSheet.show(
      context,
      loader: controller.loadScriptBoard,
    );
  }

  /// 顶栏菜单触发：更新会话标题
  Future<void> _updateSessionTitle() async {
    final t = Translations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    final updated = await controller.updateTitle(force: true);
    if (!mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            updated
                ? t.advanced.settings.titleUpdated
                : t.advanced.settings.titleFailed,
          ),
        ),
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
    _inputKey.currentState
        ?.insertAtCursor(text, cursorOffsetFromStart: cursorOffset);
  }

  /// 2026-07-29 推荐回复：选择某条候选回复
  ///
  /// 从 controller 获取选中条文本，插入到输入框光标位置。
  /// 不清空候选列表（用户可能想再选其他条）。
  void _handleSelectSuggest(
    AdvancedChatController controller,
    int index,
  ) {
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
    final currentState = ref.read(
      advancedChatControllerProvider(widget.session),
    );
    if (currentState.pendingUserMessage != null &&
        currentState.phase != IntermediatePhase.failed) {
      final t = Translations.of(context);
      final confirmed = await context.lmUi.confirmDialog(
        context,
        title: t.advanced.chat.messageActions.overwritePendingTitle,
        content: t.advanced.chat.messageActions.overwritePendingConfirm,
        confirmLabel: t.common.confirm,
      );
      if (!confirmed || !mounted) return;
    }
    await ref
        .read(advancedChatControllerProvider(widget.session).notifier)
        .sendMessage(userInput);
    // 已发送即不再是草稿（清窄列；Map 由切走分支维护）
    _persistDraftColumn(widget.session.sessionId, '');
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
  /// - pendingUserMessage：保存=更新内存文本；保存并发送=editPendingUserMessage
  /// - 已持久化用户消息：保存=editMessageContent；保存并发送=editAndResend
  /// - 已持久化助手消息：只有保存=editMessageContent
  Future<void> _handleEdit(ChatMessage message) async {
    final currentState = ref.read(
      advancedChatControllerProvider(widget.session),
    );
    final isPending =
        currentState.pendingUserMessage?.messageId == message.messageId;

    final allowResend = isPending || message.role == 'user';

    final result = await context.lmUi.editDialog(
      context,
      initialContent: message.content ?? '',
      allowResend: allowResend,
    );
    if (result == null || !mounted) return;

    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    if (isPending) {
      if (result.resend) {
        await controller.editPendingUserMessage(result.content);
      } else {
        controller.updatePendingUserMessageContent(result.content);
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
  /// - 是 pendingUserMessage → 调 controller.deletePendingUserMessage（无 DB 删除）
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
      controller.deletePendingUserMessage();
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

  /// 环形指示器分子：最新轮 lastPromptTokens 优先，回退旧会话回填值
  int? _latestLastPromptTokens(AdvancedChatState state) {
    final summary = _latestTurnSummary(state);
    if (summary?.lastPromptTokens != null) return summary!.lastPromptTokens;
    return state.backfilledPromptTokens;
  }

  AgentWorkSummary? _latestTurnSummary(AdvancedChatState state) {
    final artifacts = state.artifactsByTurnNumber;
    if (artifacts == null || artifacts.isEmpty) return null;
    final latestTurn = artifacts.keys.reduce((a, b) => a > b ? a : b);
    return artifacts[latestTurn]?.agentWorkSummary;
  }

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
    final prompt = _latestLastPromptTokens(state);
    final labels = <String, String>{
      'system': t.advanced.contextComposition.system,
      'coreBlocks': t.advanced.contextComposition.coreBlocks,
      'history': t.advanced.contextComposition.history,
      'directive': t.advanced.contextComposition.directive,
    };
    return [
      for (final entry in labels.entries)
        ContextCompositionSegment(
          label: entry.value,
          fraction: (chars[entry.key] ?? 0) / totalChars,
          tokens: prompt == null
              ? null
              : ((chars[entry.key] ?? 0) / totalChars * prompt).round(),
        ),
    ];
  }

  /// 会话加权平均缓存命中率（§3.3：仅统计有 lastPromptTokens 的轮次）
  double? _averageCacheHit(AdvancedChatState state) {
    final summaries = state.artifactsByTurnNumber?.values
        .map((a) => a.agentWorkSummary)
        .whereType<AgentWorkSummary>()
        .where((s) => s.lastPromptTokens != null && s.lastPromptTokens! > 0)
        .toList();
    if (summaries == null || summaries.isEmpty) return null;
    var prompt = 0;
    var cached = 0;
    for (final s in summaries) {
      prompt += s.lastPromptTokens!;
      cached += s.lastCacheReadTokens ?? 0;
    }
    // 跨协议近似口径（与故事侧 averageCacheHit 同步）：Anthropic 的
    // promptTokens 不含 cache-read，OpenAI 的含——分母统一用
    // uncached + cached 输入 token，避免 OpenAI 下系统性低估。
    if (prompt + cached == 0) return null;
    return cached / (cached + prompt);
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
            return ContextUsageDetailSheet(
              contextWindowTokens: state.contextWindowTokens,
              compactionTriggerTokens: state.compactionTriggerTokens,
              lastPromptTokens: _latestLastPromptTokens(state),
              lastCompletionTokens:
                  _latestTurnSummary(state)?.lastCompletionTokens,
              lastCacheReadTokens:
                  _latestTurnSummary(state)?.lastCacheReadTokens ??
                      state.backfilledCacheReadTokens,
              averageCacheHit: _averageCacheHit(state),
              sessionRounds: state.artifactsByTurnNumber?.length ?? 0,
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
                            content: Text(
                              t.common.contextRing.compactDone,
                            ),
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
    AdvancedChatController, AdvancedChatState, ChatSession>(
  (ref, session) {
    return AdvancedChatController(
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
      // 向导「初始化你的角色」卡路径：物化时应用卡（服务无状态，即建即用）
      resourceApplyService: ResourceApplyService(
        resourceRepository: ref.read(resourceLibraryRepositoryProvider),
        projectionService: ResourceProjectionService(
          repository: ref.read(factualRepositoryProvider),
        ),
      ),
    );
  },
);
