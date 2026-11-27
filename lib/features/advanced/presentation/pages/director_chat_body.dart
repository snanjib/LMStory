import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/narrative_identity.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/follow_scroll_executor.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart'
    show streamingFollowCushionPx;
import 'package:lmstory/core/widgets/conversation_navigation.dart';
import 'package:lmstory/core/widgets/conversation_text_reveal.dart';
// TODO(decouple): 临时依赖，P1/P2 迁往 advanced/story_runtime 后消除
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_timeline_assembler.dart';
import 'package:lmstory/features/advanced/presentation/utils/director_human_presenter.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_act_unit.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_work_group.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/features/story_runtime/presentation/pages/memory_browser_page.dart';
// 变体切换器自本文件提取为 story_runtime 共享组件
import 'package:lmstory/features/story_runtime/presentation/widgets/message_variant_switcher.dart';
import 'package:lmstory/i18n/strings.g.dart';

part 'director_history_viewport.dart';

/// Director mode reading stream composed of integrated Act Units.
///
/// Each round opens with a light act header (`Act N · Story time`), a
/// left-ruled director directive, frameless narrative prose directly on the
/// reading ground, an always-visible subtle action row, and human-readable
/// tail change pills that expand an in-place world diff drawer.
///
/// Live writing collapses behind a single-line human progress pulse while
///  maintenance occupies a fixed-height dashed tail slot to avoid
/// viewport jumps. Error and warning tool steps remain rendered via
/// `DirectorToolCard`.
class DirectorChatBody extends StatefulWidget {
  const DirectorChatBody({
    required this.state,
    required this.onCopy,
    required this.onRegenerate,
    required this.onEdit,
    required this.onDeleteRound,
    this.onUseExample,
    this.windowRounds = 5,
    this.onUndoCompaction,
    this.onSwitchVariant,
    this.onDeleteVariant,
    this.onVariantFlashConsumed,
    this.onEditAnchor,
    this.onOpenMemory,
    this.onOpenWorldStatus,
    this.entityNameMap,
    this.pureReading = false,
    this.initialFocusMessageId,
    this.onVisibleHistoryTurns,
    this.fontScale = 1.0,
    super.key,
  });

  final AdvancedChatState state;
  final void Function(ChatMessage) onCopy;
  final void Function(ChatMessage) onRegenerate;
  final void Function(ChatMessage) onEdit;
  final void Function(ChatMessage) onDeleteRound;

  /// Optional quick-fill callback for the empty-state opening prompt.
  final void Function(String example)? onUseExample;

  /// Font scale ratio applied to narrative prose and directive copy.
  final double fontScale;

  /// Number of recent rounds eligible for destructive operations.
  final int windowRounds;

  /// Undo compaction callback; null hides undo on summary cards.
  final Future<void> Function()? onUndoCompaction;

  /// Switch assistant manuscript variant; null disables the switcher.
  final Future<void> Function(ChatMessage assistant, int variantIndex)?
      onSwitchVariant;

  /// Delete a non-active manuscript variant.
  final Future<void> Function(ChatMessage assistant, int variantIndex)?
      onDeleteVariant;

  /// Called once the new-variant highlight flash finishes.
  final VoidCallback? onVariantFlashConsumed;

  /// Edit the current story anchor (exposed only on the latest completed act).
  final ValueChanged<StoryAnchor>? onEditAnchor;

  /// Optional callback to open the Memory Browser from an act diff drawer.
  /// Falls back to pushing [MemoryBrowserPage] when null.
  final VoidCallback? onOpenMemory;

  /// Optional callback to open the World Status surface.
  final VoidCallback? onOpenWorldStatus;

  /// Optional read-only `entityId -> primaryName` lookup for legacy records.
  final Map<String, String>? entityNameMap;

  /// Target message ID to scroll to when entering from search results.
  final String? initialFocusMessageId;

  /// Requests round details for the history rows materialized by the viewport.
  final Future<void> Function(Iterable<int> turns)? onVisibleHistoryTurns;

  /// Pure reading mode hides directives, backstage actions, and action rows.
  final bool pureReading;

  @override
  State<DirectorChatBody> createState() => _DirectorChatBodyState();
}

class _DirectorChatBodyState extends State<DirectorChatBody>
    with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController(keepScrollOffset: false);

  // ── ：时间线装配签名缓存 ──────────────────────
  //
  // build 期每次都跑 AgentTimelineAssembler.assemble（O(blocks+steps)），
  // 但装配输入只在 live 增量/步事件变化时才变。输入（实体均不可变，
  // final 字段）按元素 identical 比较 + 升格下标构成签名：命中则复用
  // 上次装配的 List（无关重建——压缩流式/上下文用量回流/相位标量——
  // 不再重跑装配）；元素实例被替换（文本追加、步状态翻转）即失效。
  List<AgentTimelineBlock>? _timelineCache;
  var _timelineInputBlocks = const <AgentLiveBlock>[];
  var _timelineInputSteps = const <AgentWorkStep>[];
  int? _timelineInputPromoted;

  final _rowIndices = <String, int>{};
  var _roundItems = <int>[];
  List<ChatMessage>? _indexedMessages;
  String? _indexedPending;
  bool? _indexedPure;
  bool _indexedLiveManuscript = false;
  bool _indexedRetry = false;

  var _viewport = _DirectorHistoryViewport();
  _DirectorOrigin _origin = _DirectorOrigin.start;
  String? _anchorId;
  String? _selectedId;
  bool _aligning = false;
  bool _initialized = false;
  bool _allowReadingTail = false;
  double _innerOffset = 0;
  int _alignmentVersion = 0;
  bool _focusHandled = false;
  PageStorageBucket? _bucket;

  final _readingMarkers = <String, GlobalKey>{};
  bool _bookmarkScheduled = false;
  bool _instructionStripVisible = false;

  final _requestedTurns = <int>{};
  final _turnsToRequest = <int>{};
  int _detailEpoch = 0;
  bool _detailsScheduled = false;

  late final FollowScrollExecutor _followExecutor;

  @override
  void initState() {
    super.initState();
    _followExecutor =
        FollowScrollExecutor(controller: _scrollController, vsync: this);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bucket = PageStorage.maybeOf(context);
    _refreshIndex();
    _applyEntryPosition();
  }

  @override
  void didUpdateWidget(DirectorChatBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final state = widget.state;
    final old = oldWidget.state;
    final switched = old.session.sessionId != state.session.sessionId;
    if (switched) {
      _saveBookmark(old);
      _initialized = false;
      _focusHandled = false;
      _followExecutor.reset();
    }
    if (switched ||
        (!old.loadingHistory && state.loadingHistory) ||
        !identical(old.messages, state.messages) ||
        old.compactedTurnBase != state.compactedTurnBase ||
        (old.isPreparingRegenerate && !state.isPreparingRegenerate) ||
        (old.phase == IntermediatePhase.persisting &&
            state.phase != old.phase)) {
      _detailEpoch++;
      _detailsScheduled = false;
      _requestedTurns.clear();
      _turnsToRequest.clear();
    }
    if (widget.initialFocusMessageId != oldWidget.initialFocusMessageId) {
      _focusHandled = false;
    }
    final modeChanged = oldWidget.pureReading != widget.pureReading;
    final messagesChanged = !identical(old.messages, state.messages);
    final compactionChanged = old.compactedTurnBase != state.compactedTurnBase;
    final detailsChanged =
        !identical(old.artifactsByTurnNumber, state.artifactsByTurnNumber) ||
            !identical(old.variantsByTurn, state.variantsByTurn);
    final reading = !_aligning &&
            !_followExecutor.state.following &&
            (messagesChanged ||
                modeChanged ||
                compactionChanged ||
                detailsChanged)
        ? _visibleBookmark(old)
        : null;
    final oldItem = reading == null ? null : _rowIndices[reading.id];
    _refreshIndex();
    if (!_initialized ||
        !_focusHandled && widget.initialFocusMessageId != null) {
      if (_applyEntryPosition()) return;
    }

    final item = reading == null ? null : _rowIndices[reading.id];
    final draftChanged = messagesChanged &&
        oldItem != null &&
        item != null &&
        oldItem <= old.messages.length &&
        item <= state.messages.length &&
        old.messages[oldItem - 1].content != state.messages[item - 1].content;
    if (modeChanged ||
        draftChanged ||
        compactionChanged ||
        _anchorId != null && !_rowIndices.containsKey(_anchorId)) {
      // A switch can replace the text in place. A compaction can remove
      // the viewport's original anchor while retaining the manuscript in view.
      if (reading != null &&
          item != null &&
          (!modeChanged ||
              (reading.fromProse &&
                  item <= state.messages.length &&
                  state.messages[item - 1].role == 'assistant'))) {
        _setOrigin(
          _DirectorOrigin.message,
          id: reading.id,
          offsetInRow: reading.offsetInRow,
          fromProse: reading.fromProse,
        );
      } else {
        final previous = reading?.id ?? _selectedId;
        final target = previous == null ? null : _focusTarget(previous);
        if (target == null && previous != null && compactionChanged) {
          _setCompactionBoundary();
        } else {
          _setOrigin(
            target == null ? _DirectorOrigin.latest : _DirectorOrigin.message,
            id: target,
          );
        }
      }
      return;
    }

    if (reading != null && (messagesChanged || detailsChanged)) {
      _preserveReadingPosition(reading);
    }

    final pendingAppeared =
        old.pendingUserMessage == null && state.pendingUserMessage != null;
    if (pendingAppeared) {
      _setOrigin(_DirectorOrigin.latest);
    } else if (!_aligning &&
        _followExecutor.state.following &&
        !state.inMaintenancePhase &&
        (state.messages.length > old.messages.length ||
            !identical(
              state.artifactsByTurnNumber,
              old.artifactsByTurnNumber,
            ) ||
            _liveContentGrew(old, state) ||
            state.agentSteps.length > old.agentSteps.length)) {
      _followExecutor.followGrowth();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _aligning || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (!state.inMaintenancePhase &&
          !_viewport.hasReadingTail &&
          pos.hasContentDimensions &&
          pos.extentAfter <= _followExecutor.state.resumeAtBottomPx &&
          !_followExecutor.state.following) {
        _followExecutor.state.forceFollowing();
      }
      _syncInstructionStrip();
    });
  }

  @override
  void deactivate() {
    _saveBookmark(widget.state);
    super.deactivate();
  }

  @override
  void dispose() {
    _followExecutor.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  bool get _isWorking =>
      widget.state.phase != IntermediatePhase.idle &&
      widget.state.phase != IntermediatePhase.failed;

  bool get _hasAnyContent =>
      widget.state.messages.isNotEmpty ||
      widget.state.pendingUserMessage != null ||
      widget.state.liveBlocks.isNotEmpty ||
      widget.state.agentSteps.isNotEmpty;

  static bool _liveContentGrew(
    AdvancedChatState oldState,
    AdvancedChatState newState,
  ) {
    final old = oldState.liveBlocks;
    final next = newState.liveBlocks;
    if (next.length != old.length) return next.length > old.length;
    return next.isNotEmpty && next.last.text.length > old.last.text.length;
  }

  void _refreshIndex() {
    final state = widget.state;
    final messages = state.messages;
    final pending = state.pendingUserMessage?.messageId;
    final hasRetry =
        widget.pureReading && _isWorking && state.agentRetryWait != null;
    final liveManuscript = widget.pureReading &&
        pending != null &&
        AgentLiveTranscript.manuscriptIndex(state.liveBlocks) >= 0;
    if (identical(messages, _indexedMessages) &&
        pending == _indexedPending &&
        widget.pureReading == _indexedPure &&
        liveManuscript == _indexedLiveManuscript &&
        hasRetry == _indexedRetry) {
      return;
    }
    _indexedMessages = messages;
    _indexedPending = pending;
    _indexedPure = widget.pureReading;
    _indexedLiveManuscript = liveManuscript;
    _indexedRetry = hasRetry;
    _rowIndices.clear();
    _roundItems = [];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      _rowIndices[message.messageId] = i + 1;
      if (!message.isSummary &&
          (widget.pureReading
              ? message.role == 'assistant' &&
                  (message.content?.isNotEmpty ?? false)
              : message.role == 'user')) {
        _roundItems.add(i + 1);
      }
    }
    if (pending != null && (!widget.pureReading || liveManuscript)) {
      final item = messages.length + 1 + (hasRetry ? 1 : 0);
      _rowIndices[pending] = item;
      _roundItems.add(item);
    }
  }

  String? _idAtItem(int item) {
    final messages = widget.state.messages;
    if (item > 0 && item <= messages.length) {
      return messages[item - 1].messageId;
    }
    final pending = widget.state.pendingUserMessage?.messageId;
    return pending != null && item == _rowIndices[pending] ? pending : null;
  }

  int _rankAt(int item) {
    var low = 0;
    var high = _roundItems.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_roundItems[middle] <= item) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low - 1;
  }

  String? _focusTarget(String id) {
    final item = _rowIndices[id];
    if (item == null) return null;
    final rank = _rankAt(item);
    if (rank >= 0 && _roundItems[rank] == item) return id;
    if (widget.pureReading &&
        item <= widget.state.messages.length &&
        widget.state.messages[item - 1].role == 'user') {
      if (rank + 1 >= _roundItems.length) return null;
      final next = _roundItems[rank + 1];
      for (var cursor = item + 1; cursor < next; cursor++) {
        if (cursor > widget.state.messages.length ||
            widget.state.messages[cursor - 1].role == 'user') {
          return null;
        }
      }
      return _idAtItem(next);
    }
    if (rank >= 0) return _idAtItem(_roundItems[rank]);
    return id;
  }

  bool _applyEntryPosition() {
    if (!_hasAnyContent) return false;
    final focus = widget.initialFocusMessageId;
    final id = !_focusHandled && focus != null ? _focusTarget(focus) : null;
    if (id != null) {
      _initialized = true;
      _focusHandled = true;
      _setOrigin(_DirectorOrigin.message, id: id);
      return true;
    }
    if (_initialized) return false;
    _initialized = true;
    final bookmark = _bucket?.readState(
      context,
      identifier: 'director-reading-${widget.state.session.sessionId}',
    );
    if (bookmark == _DirectorOrigin.start) {
      _setOrigin(_DirectorOrigin.start);
    } else if (bookmark is _DirectorBookmark &&
        _rowIndices.containsKey(bookmark.id)) {
      _setOrigin(
        _DirectorOrigin.message,
        id: bookmark.id,
        offsetInRow: bookmark.offsetInRow,
        fromProse: bookmark.fromProse,
      );
    } else if (bookmark is _DirectorBookmark &&
        widget.state.compactedTurnBase > 0) {
      _setCompactionBoundary();
    } else {
      _setOrigin(_DirectorOrigin.latest);
    }
    return true;
  }

  // filterByCompactionPoint puts the replacement summary before all
  // surviving turns. A removed reading position resumes at that boundary.
  void _setCompactionBoundary() {
    final first = widget.state.messages.firstOrNull;
    final id = (first?.isSummary ?? false) || _roundItems.isEmpty
        ? first?.messageId
        : _idAtItem(_roundItems.first);
    _setOrigin(
      id == null ? _DirectorOrigin.start : _DirectorOrigin.message,
      id: id,
      fromProse: first?.isSummary != true,
    );
  }

  GlobalKey _markerFor(String id) {
    _scheduleBookmark();
    return _readingMarkers.putIfAbsent(id, GlobalKey.new);
  }

  // Scrollables detach before a route's State is deactivated. Keep the last
  // laid-out reading position in the route's bucket while its rows are live.
  void _scheduleBookmark() {
    if (_bookmarkScheduled) return;
    _bookmarkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bookmarkScheduled = false;
      if (!mounted) return;
      _readingMarkers.removeWhere((_, key) => key.currentContext == null);
      _saveBookmark(widget.state);
    });
  }

  _DirectorBookmark? _visibleBookmark(AdvancedChatState state) {
    final first = _viewport.firstVisible();
    if (first == null || first.item < 1 || first.item > state.messages.length) {
      return null;
    }
    final id = state.messages[first.item - 1].messageId;
    final marker = _readingMarkers[id];
    final render = marker?.currentContext?.findRenderObject();
    final origin = _revealOf(marker);
    if (render is RenderBox && origin != null) {
      final top = origin - _scrollController.position.pixels;
      if (top <= 0.5 && top + render.size.height > 0.5) {
        return _DirectorBookmark(id, -top, fromProse: true);
      }
    }
    return _DirectorBookmark(id, -first.top);
  }

  void _saveBookmark(AdvancedChatState state) {
    if (!_initialized || _aligning) return;
    Object? reading;
    if (!_followExecutor.state.following) {
      reading = _visibleBookmark(state);
      if (reading == null) {
        if (_viewport.firstVisible()?.item != 0) return;
        reading = _DirectorOrigin.start;
      }
    }
    _bucket?.writeState(
      context,
      reading,
      identifier: 'director-reading-${state.session.sessionId}',
    );
  }

  void _preserveReadingPosition(_DirectorBookmark reading) {
    final version = _alignmentVersion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _alignmentVersion != version ||
          _aligning ||
          !_scrollController.hasClients ||
          _followExecutor.state.following) {
        return;
      }
      final pos = _scrollController.position;
      if (pos.isScrollingNotifier.value) return;
      final item = _rowIndices[reading.id];
      if (item == null) return;
      final rowTop = _viewport.rowTop(item);
      final origin = reading.fromProse
          ? _revealOf(_readingMarkers[reading.id])
          : rowTop == null
              ? null
              : pos.pixels + rowTop;
      if (origin == null) {
        setState(
          () => _setOrigin(
            _DirectorOrigin.message,
            id: reading.id,
            offsetInRow: reading.offsetInRow,
            fromProse: reading.fromProse,
          ),
        );
        return;
      }
      final desired = (origin + reading.offsetInRow)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((desired - pos.pixels).abs() <= 0.5) return;
      _aligning = true;
      pos.jumpTo(desired);
      _followExecutor.rebase();
      _aligning = false;
      _scheduleBookmark();
    });
  }

  void _setOrigin(
    _DirectorOrigin origin, {
    String? id,
    double offsetInRow = 0,
    bool fromProse = true,
  }) {
    _followExecutor.stop();
    _origin = origin;
    _requestedTurns.clear();
    // Short histories can be laid out from the title. This also keeps a
    // conversation which fits on screen naturally aligned at the top.
    final messages = widget.state.messages;
    _anchorId = origin == _DirectorOrigin.latest && messages.length > 8
        ? messages.last.messageId
        : id;
    _selectedId = origin == _DirectorOrigin.message ? id : null;
    _allowReadingTail = _selectedId != null;
    _innerOffset = offsetInRow > 0 ? offsetInRow : 0;
    _viewport = _DirectorHistoryViewport();
    _aligning = true;
    if (origin == _DirectorOrigin.latest) {
      _followExecutor.state.forceFollowing();
    } else {
      _followExecutor.state.pauseFollowing();
    }
    _finishAlignment(++_alignmentVersion, offsetInRow, fromProse: fromProse);
  }

  void _finishAlignment(
    int version,
    double offsetInRow, {
    required bool fromProse,
    bool corrected = false,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          version != _alignmentVersion ||
          !_scrollController.hasClients) {
        return;
      }
      final pos = _scrollController.position;
      if (!pos.hasContentDimensions) return;
      final before = _viewport.extentBeforeOrigin;
      if (_origin == _DirectorOrigin.latest &&
          _anchorId != null &&
          before != null &&
          before < pos.viewportDimension) {
        // Even several short turns can fit on a tablet. In that case a
        // lower-edge origin would invent an empty, scrollable area above.
        setState(() {
          _anchorId = null;
          _viewport = _DirectorHistoryViewport();
        });
        _finishAlignment(version, offsetInRow, fromProse: fromProse);
        return;
      }
      var target = switch (_origin) {
        _DirectorOrigin.latest => pos.maxScrollExtent,
        _DirectorOrigin.start => pos.minScrollExtent,
        _DirectorOrigin.message => offsetInRow,
      };
      if (_origin == _DirectorOrigin.message &&
          fromProse &&
          (offsetInRow > 0 || !widget.pureReading)) {
        final marker = _readingMarkers[_anchorId];
        final render = marker?.currentContext?.findRenderObject();
        if (offsetInRow > 0 &&
            render is RenderBox &&
            render.hasSize &&
            offsetInRow >= render.size.height) {
          // A shorter manuscript no longer contains the previously read line.
          // Remove the excess tail and show the beginning of this version.
          setState(() => _innerOffset = 0);
          _finishAlignment(version, 0, fromProse: true);
          return;
        }
        target = (_revealOf(marker) ?? 0) + offsetInRow;
      }
      if (!corrected &&
          _allowReadingTail &&
          target > pos.maxScrollExtent + 0.5) {
        setState(() => _innerOffset = target);
        _finishAlignment(
          version,
          offsetInRow,
          fromProse: fromProse,
          corrected: true,
        );
        return;
      }
      final offset = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((offset - pos.pixels).abs() > 0.5) {
        pos.jumpTo(offset);
        if (!corrected) {
          _finishAlignment(
            version,
            offsetInRow,
            fromProse: fromProse,
            corrected: true,
          );
          return;
        }
      }
      _aligning = false;
      _followExecutor.rebase();
      _scheduleBookmark();
      _syncInstructionStrip();
    });
  }

  double? _revealOf(GlobalKey? row) {
    if (!_scrollController.hasClients) return null;
    final render = row?.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    final viewport = RenderAbstractViewport.of(render);
    return _scrollController.position.pixels +
        render.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  void _onScroll() {
    if (_aligning || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    _followExecutor.handleScrollMetrics(
      position.pixels,
      position.maxScrollExtent,
    );
    if (_viewport.hasReadingTail) _followExecutor.state.pauseFollowing();
    _scheduleBookmark();
    _syncInstructionStrip();
  }

  void _onUserScroll() {
    _requestedTurns.clear();
    _alignmentVersion++;
    if (_aligning) _followExecutor.rebase();
    _aligning = false;
    _selectedId = null;
  }

  void _syncInstructionStrip() {
    final state = widget.state;
    final eligible =
        _isWorking && !widget.pureReading && state.pendingUserMessage != null;
    var visible = false;
    if (eligible &&
        _scrollController.hasClients &&
        _scrollController.position.hasContentDimensions) {
      final pending = _readingMarkers[state.pendingUserMessage?.messageId];
      final render = pending?.currentContext?.findRenderObject();
      final pos = _scrollController.position;
      final top = _revealOf(pending);
      visible = render is! RenderBox ||
          top == null ||
          top < pos.pixels - 4 ||
          top + render.size.height > pos.pixels + pos.viewportDimension + 4;
    }
    if (visible != _instructionStripVisible) {
      setState(() => _instructionStripVisible = visible);
    }
  }

  void _jumpToPendingRow() {
    final id = widget.state.pendingUserMessage?.messageId;
    if (id != null) setState(() => _setOrigin(_DirectorOrigin.message, id: id));
  }

  int _activeRank() {
    final selected = _selectedId;
    final item = selected == null ? null : _rowIndices[selected];
    final current = item ?? _viewport.firstVisible()?.item ?? 0;
    final rank = _rankAt(current);
    if (rank >= 0 || _roundItems.isEmpty || !_scrollController.hasClients) {
      return rank;
    }
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return rank;
    final top = _viewport.rowTop(_roundItems.first);
    // The opening and compaction summary can share a screen with the first
    // instruction. It already counts as the current round once it is visible.
    return top != null && top < position.viewportDimension - 0.5 ? 0 : rank;
  }

  bool _canJumpRound({required bool forward}) {
    final rank = _activeRank() + (forward ? 1 : -1);
    return rank >= 0 && rank < _roundItems.length;
  }

  void _jumpRound({required bool forward}) {
    final rank = _activeRank() + (forward ? 1 : -1);
    if (rank < 0 || rank >= _roundItems.length) return;
    final id = _idAtItem(_roundItems[rank]);
    if (id != null) setState(() => _setOrigin(_DirectorOrigin.message, id: id));
  }

  void _queueTurnDetails(int turn) {
    if (widget.onVisibleHistoryTurns == null || !_requestedTurns.add(turn)) {
      return;
    }
    _turnsToRequest.add(turn);
    if (_detailsScheduled) return;
    _detailsScheduled = true;
    final epoch = _detailEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _detailEpoch) return;
      _detailsScheduled = false;
      final turns = Set<int>.of(_turnsToRequest);
      _turnsToRequest.clear();
      final load = widget.onVisibleHistoryTurns;
      if (load != null && turns.isNotEmpty) {
        unawaited(
          load(turns).catchError((Object error) {
            if (mounted && epoch == _detailEpoch) {
              _requestedTurns.removeAll(turns);
            }
          }),
        );
      }
    });
  }

  /// 逐元素 identical（实体不可变：实例相同 ⟺ 内容相同）；长度或任一
  /// 元素被替换即视为输入变化。
  static bool _sameByElement<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;

    if (state.messages.isEmpty &&
        state.pendingUserMessage == null &&
        state.liveBlocks.isEmpty &&
        state.agentSteps.isEmpty) {
      // 历史加载中渲染骨架而非空态引导——重会话打开瞬间不再
      // 闪「发送第一句话开始」
      if (state.loadingHistory) return const _HistoryLoadingSkeleton();
      return _DirectorEmptyState(onUseExample: widget.onUseExample);
    }

    // 尾部进行中轮（pending 气泡 / live 折叠组 / 稿件卡或呼吸占位）在
    // build 期预判槽位与数据（装配一次，itemBuilder 复用）。
    final blocks = state.liveBlocks;
    final manuscriptIndex = AgentLiveTranscript.manuscriptIndex(blocks);
    // Producer identity is known before generation finishes. Ordinary speech
    // stays in the process; explicit prose alone streams into the manuscript.
    final promotedIndex = manuscriptIndex >= 0 ? manuscriptIndex : null;
    final splitIndex = state.inMaintenancePhase
        ? state.maintenanceStepStart.clamp(0, state.agentSteps.length)
        : state.agentSteps.length;
    final task1Steps = state.inMaintenancePhase
        ? state.agentSteps.sublist(0, splitIndex)
        : state.agentSteps;
    final task2Steps = state.inMaintenancePhase
        ? state.agentSteps.sublist(splitIndex)
        : const <AgentWorkStep>[];
    final task1Blocks = !state.inMaintenancePhase
        ? blocks
        : manuscriptIndex >= 0
            ? blocks.sublist(0, manuscriptIndex + 1)
            : (task2Steps.isNotEmpty &&
                    task2Steps.first.stepIndex >
                        (task1Steps.lastOrNull?.stepIndex ?? -1))
                ? [
                    for (final b in blocks)
                      if (b.stepIndex < task2Steps.first.stepIndex) b,
                  ]
                : blocks;
    // 输入签名命中 → 复用上次装配结果（见 _timelineCache 注释）
    final timelineUnchanged = _timelineCache != null &&
        _sameByElement(task1Blocks, _timelineInputBlocks) &&
        _sameByElement(task1Steps, _timelineInputSteps) &&
        promotedIndex == _timelineInputPromoted;
    final liveTimeline = timelineUnchanged
        ? _timelineCache!
        : task1Blocks.isEmpty && task1Steps.isEmpty
            ? const <AgentTimelineBlock>[]
            : AgentTimelineAssembler.assemble(
                liveBlocks: task1Blocks,
                agentSteps: task1Steps,
                promotedIndex: promotedIndex,
              );
    if (!timelineUnchanged) {
      _timelineCache = liveTimeline;
      _timelineInputBlocks = task1Blocks;
      _timelineInputSteps = task1Steps;
      _timelineInputPromoted = promotedIndex;
    }
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final manuscriptBlock =
        manuscriptIndex >= 0 ? blocks[manuscriptIndex] : null;
    final liveActNumber = _latestCompletedTurn(state) + 1;
    final livePresentation = DirectorHumanPresenter.presentLive(
      state: state,
      t: t,
      actNumber: liveActNumber,
      entityNames: widget.entityNameMap,
    );
    final hasPending = state.pendingUserMessage != null && !widget.pureReading;
    final hasLivePulse =
        ((liveTimeline.isNotEmpty && !state.inMaintenancePhase) ||
                (_isWorking && !state.inMaintenancePhase) ||
                (!state.inMaintenancePhase && livePresentation.hasErrors)) &&
            !widget.pureReading;
    final hasRetryRow = _isWorking && state.agentRetryWait != null;
    final hasMaintenanceCapsule = state.inMaintenancePhase &&
        (_isWorking || task2Steps.any((s) => s.isError || s.isWarning));
    final hasTailBody = manuscriptBlock != null || hasMaintenanceCapsule;
    final tailItemCount = (hasPending ? 1 : 0) +
        (hasRetryRow ? 1 : 0) +
        (hasLivePulse ? 1 : 0) +
        (hasTailBody ? 1 : 0);

    return Stack(
      children: [
        ConversationNavigation(
          controller: _scrollController,
          onTop: () => setState(() => _setOrigin(_DirectorOrigin.start)),
          onBottom: () => setState(() => _setOrigin(_DirectorOrigin.latest)),
          canJumpRound: _canJumpRound,
          jumpRound: _jumpRound,
          onUserScroll: _onUserScroll,
          hasReadingTail: () => _viewport.hasReadingTail,
          narrative: true,
          child: RepaintBoundary(
            child: Center(
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
                child: _viewport.build(
                  controller: _scrollController,
                  pivotIndex: (_rowIndices[_anchorId] ?? 0) +
                      (_origin == _DirectorOrigin.latest && _anchorId != null
                          ? 1
                          : 0),
                  anchorAtBottom:
                      _origin == _DirectorOrigin.latest && _anchorId != null,
                  allowReadingTail: _allowReadingTail,
                  innerOffset: _innerOffset,
                  itemCount: state.messages.length + tailItemCount + 2,
                  indexForKey: (key) =>
                      key is ValueKey<String> ? _rowIndices[key.value] : null,
                  itemBuilder: (context, item) {
                    if (item == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(
                          IntermediateSpacing.sMd,
                          IntermediateSpacing.sMd,
                          IntermediateSpacing.sMd,
                          0,
                        ),
                        child: state.messages.isEmpty
                            ? const SizedBox.shrink()
                            : StoryOpening(
                                title: state.session.title,
                                modeLabel: t.chat.sidebar.modeDirector,
                              ),
                      );
                    }
                    if (item == state.messages.length + tailItemCount + 1) {
                      return const SizedBox(
                        height:
                            IntermediateSpacing.sMd + streamingFollowCushionPx,
                      );
                    }
                    final index = item - 1;
                    Widget buildRow() {
                      if (index < state.messages.length) {
                        return _buildPersistedItem(state, index, t);
                      }
                      var tailIndex = index - state.messages.length;
                      if (hasPending) {
                        if (tailIndex == 0) {
                          return _pendingUserRow(state, livePresentation, t);
                        }
                        tailIndex--;
                      }
                      if (hasRetryRow) {
                        if (tailIndex == 0) {
                          return AgentRetryWaitRow(
                            key: const ValueKey('agent-retry-wait-row'),
                            wait: state.agentRetryWait!,
                          );
                        }
                        tailIndex--;
                      }
                      if (hasLivePulse) {
                        if (tailIndex == 0) {
                          return DirectorLivePulse(
                            presentation: livePresentation,
                            timeline: liveTimeline,
                            activity: state.agentActivity,
                            activeStepIndex: state.agentActivityStepIndex,
                            waitingUser: !state.inMaintenancePhase &&
                                (state.agentAskPrompt != null ||
                                    state.agentApprovalPrompt != null),
                            interrupted:
                                state.phase == IntermediatePhase.failed ||
                                    (!_isWorking &&
                                        state.pendingUserMessage != null),
                          );
                        }
                        tailIndex--;
                      }
                      if (hasTailBody) {
                        return Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: LmLayout.readingWidthOf(context),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (widget.pureReading &&
                                    manuscriptBlock != null)
                                  DirectorActHeader(
                                    title: livePresentation.headerTitle,
                                    showTopDivider: state.messages.isNotEmpty,
                                  ),
                                if (manuscriptBlock != null)
                                  _ManuscriptCard(
                                    key: widget.pureReading &&
                                            state.pendingUserMessage != null
                                        ? _markerFor(
                                            state.pendingUserMessage!.messageId,
                                          )
                                        : const ValueKey('live-manuscript'),
                                    text: manuscriptBlock.text,
                                    streaming:
                                        _isWorking && !state.inMaintenancePhase,
                                    fontScale: widget.fontScale,
                                    failed:
                                        state.phase == IntermediatePhase.failed,
                                  ),
                                if (hasMaintenanceCapsule)
                                  DirectorMaintenanceSlot(
                                    key: const ValueKey(
                                      'maintenance-progress-capsule',
                                    ),
                                    presentation: livePresentation,
                                    maintenanceSteps: task2Steps,
                                    waitingUser: state.agentAskPrompt != null ||
                                        state.agentApprovalPrompt != null,
                                    pureReading: widget.pureReading,
                                  ),
                              ],
                            ),
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    }

                    return Padding(
                      key: index < state.messages.length
                          ? ValueKey(state.messages[index].messageId)
                          : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: IntermediateSpacing.sMd,
                      ),
                      child: buildRow(),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        // 工作态指令浮条：指令气泡被直播尾区挤出视口时置顶提示
        //（点击回看；滚动/内容增长经 _syncInstructionStrip 对账）。
        if (_instructionStripVisible && state.pendingUserMessage != null)
          Positioned(
            top: IntermediateSpacing.sSm,
            left: IntermediateSpacing.sMd,
            right: IntermediateSpacing.sMd,
            child: Align(
              alignment: Alignment.topCenter,
              child: _ActiveInstructionStrip(
                label: t.advanced.activeInstructionLabel,
                text: state.pendingUserMessage!.content ?? '',
                onTap: _jumpToPendingRow,
              ),
            ),
          ),
        // 重生成/编辑重发「准备中」遮罩（照抄故事侧
        // DOC-09A-1 样板）——DB 删除 await 期间覆盖聊天区，半透明底 +
        // 居中转圈 + AbsorbPointer 拦截列表交互。
        if (state.isPreparingRegenerate)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: colors.bg.withValues(alpha: 0.5),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(height: IntermediateSpacing.sSm),
                      Text(
                        t.advanced.chat.preparingRegenerate,
                        style: IntermediateTextStyles.label.copyWith(
                          color: colors.ink,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPersistedItem(
    AdvancedChatState state,
    int index,
    Translations t,
  ) {
    final messages = state.messages;
    final message = messages[index];
    if (message.role == 'user' && widget.pureReading) {
      return const SizedBox.shrink();
    }
    if (message.role == 'user') {
      final turn = _turnNumberOf(message) ?? 1;
      if (turn > 0) _queueTurnDetails(turn);
      final artifacts = state.artifactsByTurnNumber?[turn];
      final previousAnchor = _previousAnchorFor(state, turn);
      final presentation = DirectorHumanPresenter.presentRound(
        actNumber: turn,
        artifacts: artifacts,
        previousAnchor: previousAnchor,
        entityNames: widget.entityNameMap,
        t: t,
      );
      final statusText = presentation.worldChangeCount > 0
          ? t.advanced.actUnit.settledChanges(
              count: presentation.worldChangeCount,
            )
          : t.advanced.actUnit.settled;
      return _userRow(
        message,
        headerTitle: presentation.headerTitle,
        statusText: statusText,
        showTopDivider: index > 0,
      );
    }
    if (message.isSummary) {
      return _summaryRow(message);
    }
    if (message.role == 'assistant' &&
        index > 0 &&
        messages[index - 1].role == 'user') {
      return _persistedRoundGroup(state, message, index, t);
    }
    return _assistantRow(message);
  }

  VoidCallback _openMemoryCallback(AdvancedChatState state) {
    if (widget.onOpenMemory != null) return widget.onOpenMemory!;
    return () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MemoryBrowserPage(session: state.session),
          ),
        );
  }

  StoryAnchor? _previousAnchorFor(AdvancedChatState state, int turn) {
    if (turn <= 1) return null;
    return state.artifactsByTurnNumber?[turn - 1]?.storyAnchor;
  }

  /// Completed act unit body: open narrative prose + always-visible subtle
  /// actions + variant switcher + human-readable change pills & diff drawer.
  Widget _persistedRoundGroup(
    AdvancedChatState state,
    ChatMessage assistant,
    int index,
    Translations t,
  ) {
    final turn = _turnNumberOf(assistant) ?? 0;
    if (turn > 0) _queueTurnDetails(turn);
    final artifacts = state.artifactsByTurnNumber?[turn];
    final previousAnchor = _previousAnchorFor(state, turn);
    final anchor = artifacts?.storyAnchor;
    final presentation = DirectorHumanPresenter.presentRound(
      actNumber: turn > 0 ? turn : 1,
      artifacts: artifacts,
      previousAnchor: previousAnchor,
      entityNames: widget.entityNameMap,
      fallbackThinkingContent: assistant.thinkingContent,
      t: t,
    );
    final thinkingInDrawer = presentation.hasPills && presentation.hasThinking;

    return Padding(
      key: ValueKey('director-round-${assistant.messageId}'),
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.pureReading && turn > 0)
                DirectorActHeader(
                  title: presentation.headerTitle,
                  showTopDivider: index > 1,
                ),
              _assistantRow(
                assistant,
                hideThinking: widget.pureReading || thinkingInDrawer,
                variants: state.variantsByTurn?[turn],
                currentVariantIndex: artifacts?.currentVariantIndex,
                flashNewVariant: state.variantFlashTurn == turn,
                flashStartedAtMs: state.variantFlashStartedAtMs,
                bottomPadding: 0,
              ),
              DirectorChangePillsAndDrawer(
                presentation: presentation,
                anchor: anchor,
                pureReading: widget.pureReading,
                onOpenMemory: _openMemoryCallback(state),
                onEditAnchor: turn == _latestCompletedTurn(state) &&
                        widget.onEditAnchor != null
                    ? widget.onEditAnchor
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pendingUserRow(
    AdvancedChatState state,
    DirectorLivePresentation livePresentation,
    Translations t,
  ) {
    final isFailed = state.phase == IntermediatePhase.failed;
    final statusText = isFailed
        ? t.advanced.draftBadge.label
        : !_isWorking
            ? t.advanced.actUnit.interrupted
            : state.inMaintenancePhase
                ? t.advanced.actUnit.maintaining
                : t.advanced.actUnit.writing;
    return _userRow(
      state.pendingUserMessage!,
      headerTitle: livePresentation.headerTitle,
      statusText: statusText,
      isActive: _isWorking,
      isError: isFailed,
      showTopDivider: state.messages.isNotEmpty,
      interactive: (state.phase == IntermediatePhase.idle || isFailed) &&
          !state.isManualCompacting,
      canOperateOverride: true,
    );
  }

  Widget _userRow(
    ChatMessage message, {
    required String headerTitle,
    String? statusText,
    bool isActive = false,
    bool isError = false,
    bool showTopDivider = true,
    bool interactive = true,
    bool? canOperateOverride,
  }) {
    final actionsEnabled = !widget.state.isManualCompacting;
    return Column(
      key: _markerFor(message.messageId),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DirectorActHeader(
          title: headerTitle,
          statusText: statusText,
          isActive: isActive,
          isError: isError,
          showTopDivider: showTopDivider,
        ),
        DirectorDirectiveBlock(
          content: message.content ?? '',
          fontScale: widget.fontScale,
          actionsEnabled: actionsEnabled,
          canOperate: canOperateOverride ?? _canOperateMessage(message),
          windowRounds: widget.windowRounds,
          interactive: interactive,
          onCopy: interactive ? () => widget.onCopy(message) : () {},
          onRegenerate:
              interactive ? () => widget.onRegenerate(message) : () {},
          onEdit: interactive ? () => widget.onEdit(message) : () {},
          onDeleteRound:
              interactive ? () => widget.onDeleteRound(message) : () {},
        ),
      ],
    );
  }

  /// 压缩摘要隔断卡（与故事模式同款组件）。
  ///
  /// 导演态无 compactionFloorWarningTurn / archivedTurnRange 数据源
  ///（AdvancedChatState 未携带，属 domain 实体），两可选项维持组件默认
  /// 关闭；纯展示、零消息操作。
  Widget _summaryRow(ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: IntermediateSpacing.sSm),
      child: context.lmUi.compactionSummaryCard(
        context,
        content: message.content ?? '',
        // U2（2026-09-04 撤销压缩）：与故事模式同构，仅 idle 且非压缩中可撤销
        onUndo: widget.onUndoCompaction,
        undoEnabled: widget.state.phase == IntermediatePhase.idle &&
            !widget.state.isManualCompacting,
      ),
    );
  }

  ///  批3：轮号推导 memo（messages 引用 + 压缩基数为键）。
  ///
  /// [turnNumberForMessage] 是 O(index) 的向前扫描（配对推导），
  /// 历史轮装配一次 + `_canOperateMessage` 每行一次，长会话每 build
  /// 合计 O(n²)——流式期间每 delta 全量重算。messages 列表只在 persist
  /// 时换引用，直播 delta 不动它；按引用缓存后每 build 只为新增轮付费。
  ///  懒构建后仅可见轮触发推导，memo 继续兜底滚回历史时的复算。
  List<ChatMessage>? _turnCacheMessages;
  int? _turnCacheCompactedBase;
  final Map<String, int?> _turnByMessageId = {};

  int? _turnNumberOf(ChatMessage assistant) {
    final state = widget.state;
    if (!identical(_turnCacheMessages, state.messages) ||
        _turnCacheCompactedBase != state.compactedTurnBase) {
      _turnCacheMessages = state.messages;
      _turnCacheCompactedBase = state.compactedTurnBase;
      _turnByMessageId.clear();
    }
    return _turnByMessageId.putIfAbsent(
      assistant.messageId,
      () => turnNumberForMessage(
        message: assistant,
        messages: state.messages,
        compactedTurnBase: state.compactedTurnBase,
      ),
    );
  }

  /// 最新已完成幕的轮次号（completedTurnCount 共享公式——
  /// 压缩基数 + 可见对话轮数）；Recap 编辑入口只挂在这一幕。
  int _latestCompletedTurn(AdvancedChatState state) {
    return completedTurnCount(
      compactedTurnBase: state.compactedTurnBase,
      messages: state.messages,
    );
  }

  /// Fork 可操作窗口门控（DOC-09A-1），与故事模式同构。
  ///
  /// 窗口公式与故事模式 intermediate.canOperateMessage 同构（本组件不持
  /// controller 引用，页面层只回传操作回调；controller 侧旧同名方法已随
  ///  删除）；轮次推导复用
  /// 同一共享工具 [turnNumberForMessage]——controller 侧 `_computeTurnNumber`
  /// 委托的同一实现，两侧窗口语义保持一致：
  /// `canOperate = targetTurn >= totalRounds - windowRounds + 1`。
  bool _canOperateMessage(ChatMessage message) {
    final targetTurn = _turnNumberOf(message);
    if (targetTurn == null) return false;
    final totalRounds = widget.state.session.messageCount ~/ 2;
    return targetTurn >= totalRounds - widget.windowRounds + 1;
  }

  Widget _assistantRow(
    ChatMessage message, {
    bool hideThinking = false,
    List<MessageVariantRecord>? variants,
    int? currentVariantIndex,
    bool flashNewVariant = false,
    int? flashStartedAtMs,
    double bottomPadding = IntermediateSpacing.sMd,
  }) {
    final showSwitcher = variants != null &&
        variants.length > 1 &&
        currentVariantIndex != null &&
        widget.onSwitchVariant != null;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!hideThinking &&
                  (message.thinkingContent?.isNotEmpty ?? false))
                _ThinkingToggle(content: message.thinkingContent!),
              _ManuscriptCard(
                key: _markerFor(message.messageId),
                text: message.content ?? '',
                streaming: false,
                fontScale: widget.fontScale,
              ),
              if (!widget.state.isManualCompacting && !widget.pureReading)
                _SubtleMessageActions(
                  child: context.lmUi.messageActions(
                    context,
                    isUser: false,
                    canOperate: _canOperateMessage(message),
                    windowRounds: widget.windowRounds,
                    onCopy: () => widget.onCopy(message),
                    onRegenerate: () => widget.onRegenerate(message),
                    onEdit: () => widget.onEdit(message),
                    onDeleteRound: () => widget.onDeleteRound(message),
                  ),
                ),
              if (showSwitcher && !widget.pureReading)
                MessageVariantSwitcher(
                  assistantMessage: message,
                  variants: variants,
                  currentIndex: currentVariantIndex,
                  flash: flashNewVariant,
                  flashStartedAtMs: flashStartedAtMs,
                  onSwitch: (index) => widget.onSwitchVariant!(message, index),
                  onDelete: widget.onDeleteVariant == null
                      ? null
                      : (index) => widget.onDeleteVariant!(message, index),
                  onFlashConsumed: widget.onVariantFlashConsumed,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Frameless narrative prose block sitting directly on the reading surface.
///
/// Streams via [StreamingMarkdownBody] with frozen-prefix chunk caching while
/// active, and settles with a delicate [_CurtainLine] (or [_DraftBadge] when
/// a round failed mid-generation).
class _ManuscriptCard extends StatelessWidget {
  const _ManuscriptCard({
    required this.text,
    required this.streaming,
    this.failed = false,
    this.fontScale = 1.0,
    super.key,
  });

  final String text;
  final bool streaming;
  final double fontScale;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: IntermediateSpacing.s2xs,
        bottom: IntermediateSpacing.sXs,
      ),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (streaming)
              StreamingMarkdownBody(
                data: text,
                blockGap: IntermediateSpacing.s2xs,
                revealPacing: true,
                cacheKey: fontScale,
                plainTextStyle: context.lmUi.markdownParagraphStyle(
                  context,
                  isUser: false,
                  fontScale: fontScale,
                ),
                blockBuilder: (segment) => context.lmUi.markdownBody(
                  context,
                  narrative: true,
                  data: segment,
                  fontScale: fontScale,
                ),
              )
            else
              context.lmUi.markdownBody(
                context,
                narrative: true,
                data: text,
                fontScale: fontScale,
              ),
            if (streaming)
              const _StreamingCursor()
            else if (!failed)
              const _CurtainLine()
            else
              const _DraftBadge(),
          ],
        ),
      ),
    );
  }
}

/// 未定稿徽标——失败轮的半截稿件不入库，重试将替换此段
class _DraftBadge extends StatelessWidget {
  const _DraftBadge();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sSm),
      child: Align(
        alignment: Alignment.centerRight,
        child: Tooltip(
          message: t.advanced.draftBadge.hint,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sSm,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: colors.accentDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_note, size: 12, color: colors.accent),
                const SizedBox(width: 3),
                Text(
                  t.advanced.draftBadge.label,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 思考过程折叠（opencode 式灰字；旧数据消息行兜底渲染用）
///
/// 收起态显示「思考 · N 字」。直播思考已由 DirectorWorkGroup 组内的
/// 思考块接替，本组件仅服务无 agentTimeline 的历史轮（恒收起态）。
class _ThinkingToggle extends StatefulWidget {
  const _ThinkingToggle({required this.content});

  final String content;

  @override
  State<_ThinkingToggle> createState() => _ThinkingToggleState();
}

class _ThinkingToggleState extends State<_ThinkingToggle> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: colors.faint,
                ),
                const SizedBox(width: IntermediateSpacing.s2xs),
                Text(
                  _expanded
                      ? t.advanced.live.thinkingCollapse
                      : t.advanced.live.thinkingCount(
                          count: widget.content.length,
                        ),
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.faint,
                  ),
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(
                left: IntermediateSpacing.sLg,
                top: IntermediateSpacing.s2xs,
              ),
              child: Text(
                widget.content,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 流式正文末尾的呼吸光标。
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.pulse,
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    //  reduced-motion：减弱动态下**不启动**循环脉冲（不是启动后再停）。
    if (LmMotion.shouldAnimate(context)) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    if (!LmMotion.shouldAnimate(context)) {
      return Container(
        width: 6,
        height: 6,
        margin: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
        decoration: BoxDecoration(
          color: colors.primary,
          shape: BoxShape.circle,
        ),
      );
    }
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _controller,
        child: Container(
          width: 6,
          height: 6,
          margin: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
          decoration: BoxDecoration(
            color: colors.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 落幕线：正文定稿后底部 1px 琥珀细线 240ms 淡入（本轮定稿的视觉句号）。
class _CurtainLine extends StatefulWidget {
  const _CurtainLine();

  @override
  State<_CurtainLine> createState() => _CurtainLineState();
}

class _CurtainLineState extends State<_CurtainLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.sweep,
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // reduced-motion：静态细线，不做淡入
    if (LmMotion.reducedMotion(context)) {
      _controller.value = 1;
    } else if (!_controller.isAnimating && _controller.value != 1) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return FadeTransition(
      opacity:
          CurvedAnimation(parent: _controller, curve: LmMotion.easeStandard),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: 32,
          height: 1,
          margin: const EdgeInsets.only(
            top: IntermediateSpacing.sSm,
            bottom: IntermediateSpacing.s3xs,
          ),
          color: colors.divider.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// Restrained wrapper for always-visible assistant actions beneath open prose.
///
/// Subdues visual weight at rest (54% opacity) and restores full opacity on
/// pointer hover while nudging the leading icon optically flush with the prose
/// margin without shrinking the 44dp touch targets inside.
class _SubtleMessageActions extends StatefulWidget {
  const _SubtleMessageActions({required this.child});

  final Widget child;

  @override
  State<_SubtleMessageActions> createState() => _SubtleMessageActionsState();
}

class _SubtleMessageActionsState extends State<_SubtleMessageActions> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        opacity: _hovered ? 1.0 : 0.54,
        duration: LmMotion.durationFor(context, LmMotion.hover),
        curve: LmMotion.easeStandard,
        child: Transform.translate(
          offset: const Offset(-10, 0),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Floating top pill shown when the active directive scrolls out of view.
class _ActiveInstructionStrip extends StatelessWidget {
  const _ActiveInstructionStrip({
    required this.label,
    required this.text,
    required this.onTap,
  });

  final String label;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final radius = context.lmUi.radius(LmCorner.full);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: colors.divider, width: 0.5),
    );
    return Material(
      color: colors.surfaceElevated,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_upward, size: 13, color: colors.muted),
              const SizedBox(width: IntermediateSpacing.s2xs),
              Flexible(
                child: Text(
                  '$label · $text',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DirectorEmptyState extends StatelessWidget {
  const _DirectorEmptyState({this.onUseExample});

  final void Function(String example)? onUseExample;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(IntermediateSpacing.sXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 28,
              color: colors.faint,
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                t.advanced.emptyHint,
                style: IntermediateTextStyles.bodyUi.copyWith(
                  color: colors.muted,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sLg),
            // 开场语示例：点击一键填入输入框
            Material(
              color: colors.surfaceVariant,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              child: InkWell(
                onTap: onUseExample != null
                    ? () => onUseExample!(t.advanced.emptyState.example)
                    : null,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(
                    horizontal: IntermediateSpacing.sLg,
                    vertical: IntermediateSpacing.sSm,
                  ),
                  child: Column(
                    children: [
                      Text(
                        t.advanced.emptyState.example,
                        style: IntermediateTextStyles.bodyUi.copyWith(
                          color: colors.ink,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: IntermediateSpacing.s2xs),
                      Text(
                        t.advanced.emptyState.exampleAction,
                        style: IntermediateTextStyles.caption.copyWith(
                          color: colors.faint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            Text(
              t.advanced.emptyState.rulesHint,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话历史加载骨架（最近 3 条占位卡）
///
/// 静态占位（无动画，reduced-motion 免适配）；loadHistory 期间替代空态
/// 引导，消除重会话打开瞬间「发送第一句话开始」的误导闪现。
class _HistoryLoadingSkeleton extends StatelessWidget {
  const _HistoryLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    Widget card(double height) => Padding(
          padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
          child: Center(
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
              child: Container(
                width: double.infinity,
                height: height,
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                ),
              ),
            ),
          ),
        );
    return ListView(
      key: const ValueKey('history-loading-skeleton'),
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      children: [
        card(88),
        card(120),
        card(72),
      ],
    );
  }
}
