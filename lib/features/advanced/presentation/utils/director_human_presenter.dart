import 'dart:convert';

import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/factual_labels.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:meta/meta.dart';

/// Priority-ordered categories for act-tail change pills.
enum DirectorPillKind {
  factChange,
  foreshadow,
  retrieval,
  maintenance,
  eventMemory,
  backstage,
}

/// A single human-readable pill rendered at the tail of an act unit.
@immutable
class DirectorChangePill {
  const DirectorChangePill({
    required this.id,
    required this.kind,
    required this.label,
    this.isHighlight = false,
    this.worldChangeIndices = const [],
  });

  final String id;
  final DirectorPillKind kind;
  final String label;
  final bool isHighlight;

  /// Indices into [DirectorRoundPresentation.worldChanges] represented by this
  /// pill, allowing single-pill taps to focus the drawer on its exact item(s).
  final List<int> worldChangeIndices;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DirectorChangePill ||
        id != other.id ||
        kind != other.kind ||
        label != other.label ||
        isHighlight != other.isHighlight ||
        worldChangeIndices.length != other.worldChangeIndices.length) {
      return false;
    }
    for (var i = 0; i < worldChangeIndices.length; i++) {
      if (worldChangeIndices[i] != other.worldChangeIndices[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        id,
        kind,
        label,
        isHighlight,
        Object.hashAll(worldChangeIndices),
      );
}

/// Categories of world changes shown in the act diff drawer.
enum DirectorWorldChangeKind {
  fact,
  foreshadowAdded,
  foreshadowResolved,
  storyArc,
  narrativeTime,
  eventLogged,
}

/// Structured diff row for the world-changes section of an act drawer.
@immutable
class DirectorWorldChangeItem {
  const DirectorWorldChangeItem({
    required this.kind,
    required this.subject,
    this.attributeLabel,
    this.oldValue,
    this.newValue,
    this.reason,
    this.factAction,
    this.entityType,
  });

  final DirectorWorldChangeKind kind;
  final String subject;
  final String? attributeLabel;
  final String? oldValue;
  final String? newValue;
  final String? reason;
  final FactAction? factAction;
  final FactualEntityType? entityType;
}

/// A sanitized, deduplicated backstage action for human display.
@immutable
class DirectorHumanAction {
  const DirectorHumanAction({
    required this.verb,
    this.detail,
    this.count = 1,
    this.isRunning = false,
  });

  final String verb;
  final String? detail;
  final int count;
  final bool isRunning;

  /// Formats this action as a single human-readable phrase.
  String summaryText(Translations t) {
    final cleanDetail = detail?.trim();
    if (cleanDetail != null && cleanDetail.isNotEmpty) {
      if (count > 1) {
        return '$verb · $cleanDetail × $count';
      }
      return '$verb · $cleanDetail';
    }
    if (count > 1) {
      return t.advanced.process.aggregatedActions(verb: verb, count: count);
    }
    return verb;
  }

  /// Formats this action cleanly with localized colon pairing (avoiding
  /// monotonous middle dots when separated by visual dot dividers).
  String formattedText(Translations t) {
    final cleanDetail = detail?.trim();
    if (cleanDetail != null && cleanDetail.isNotEmpty) {
      final base = t.advanced.actUnit.actionVerbDetail(
        verb: verb,
        detail: cleanDetail,
      );
      return count > 1 ? '$base × $count' : base;
    }
    if (count > 1) {
      return t.advanced.process.aggregatedActions(verb: verb, count: count);
    }
    return verb;
  }
}

/// A collapsible thinking segment extracted from a round timeline.
@immutable
class DirectorThinkingSegment {
  const DirectorThinkingSegment({
    required this.content,
    this.duration,
  });

  final String content;
  final Duration? duration;
}

/// Complete human-readable presentation ViewModel for a completed act unit.
@immutable
class DirectorRoundPresentation {
  const DirectorRoundPresentation({
    required this.actNumber,
    required this.headerTitle,
    required this.allPills,
    required this.visiblePills,
    required this.overflowCount,
    required this.worldChangeCount,
    required this.worldChanges,
    required this.actions,
    required this.narrations,
    required this.thinkingSegments,
    required this.errorSteps,
    this.narrativeTime,
    this.actionsSummaryLine,
    this.thinkingNotes,
    this.hasMajorReview = false,
    this.isLegacyFallback = false,
  });

  final int actNumber;
  final String? narrativeTime;
  final String headerTitle;
  final List<DirectorChangePill> allPills;
  final List<DirectorChangePill> visiblePills;
  final int overflowCount;
  final int worldChangeCount;
  final List<DirectorWorldChangeItem> worldChanges;
  final List<DirectorHumanAction> actions;
  final String? actionsSummaryLine;
  final List<String> narrations;
  final List<DirectorThinkingSegment> thinkingSegments;
  final String? thinkingNotes;
  final List<AgentWorkStep> errorSteps;
  final bool hasMajorReview;
  final bool isLegacyFallback;

  bool get hasPills => visiblePills.isNotEmpty;
  bool get hasWorldChanges => worldChanges.isNotEmpty;
  bool get hasActions => actions.isNotEmpty;
  bool get hasThinking => thinkingNotes != null && thinkingNotes!.isNotEmpty;
  bool get hasErrors => errorSteps.isNotEmpty;
  bool get hasDrawerContent =>
      hasWorldChanges || hasActions || hasThinking || narrations.isNotEmpty;
}

/// Live presentation ViewModel for the currently streaming or maintaining act.
@immutable
class DirectorLivePresentation {
  const DirectorLivePresentation({
    required this.isWorking,
    required this.inMaintenancePhase,
    required this.hasManuscriptProse,
    required this.headerTitle,
    required this.pulseText,
    required this.pureReadingPulseText,
    required this.actions,
    required this.maintenanceActions,
    required this.errorSteps,
    this.narrativeTime,
    this.currentStep,
    this.maxSteps,
    this.budgetRatio,
    this.latestNarration,
  });

  final bool isWorking;
  final bool inMaintenancePhase;
  final bool hasManuscriptProse;
  final String? narrativeTime;
  final String headerTitle;
  final String pulseText;
  final String pureReadingPulseText;
  final int? currentStep;
  final int? maxSteps;
  final double? budgetRatio;
  final List<DirectorHumanAction> actions;
  final List<DirectorHumanAction> maintenanceActions;
  final String? latestNarration;
  final List<AgentWorkStep> errorSteps;

  bool get hasErrors => errorSteps.isNotEmpty;
}

/// Converts raw director round artifacts and live state into pure human-readable
/// UI ViewModels without exposing internal tool identifiers or entity IDs.
abstract final class DirectorHumanPresenter {
  static const int defaultMaxVisiblePills = 3;

  static const Set<String> _internalControlTools = {
    'finish_round',
    'finish_maintenance',
    'system',
  };

  static const Set<String> _retrievalTools = {
    'search_story',
    'search_story_text',
    'read_story',
    'query_facts',
    'list_facts',
    'query_memory_changes',
    'read_compact_summary',
  };

  static final RegExp _bracketedEntityIdPattern = RegExp(
    r'[\[\(（]\s*(ent_[A-Za-z0-9_-]+)\s*[\]\)）]',
  );
  static final RegExp _bareEntityIdPattern = RegExp(
    r'\b(ent_[A-Za-z0-9_-]+)\b',
  );
  static final RegExp _rawJsonObjectPattern = RegExp(
    r'\{[^{}]*"[^"]*"[^{}]*\}',
  );
  static final RegExp _rawJsonArrayPattern = RegExp(
    r'\[[^\[\]]*"[^"\[\]]*"[^\[\]]*\]',
  );
  static final RegExp _rawToolNamePattern = RegExp(
    r'\b(?:search_story_text|search_story|read_story|query_facts|list_facts|'
    'query_memory_changes|read_compact_summary|update_facts|'
    'record_event_memory|update_story_anchor|merge_entities|ask_user|'
    'finish_round|finish_maintenance|read_skill|calc_eval|calc_date|'
    'extract_facts|create_entity|update_attr|append_list|'
    r'remove_from_list|add_alias|archive_entity|set_importance|spawn)\b',
  );
  static final RegExp _calcPrefixPattern = RegExp(r'^calc\s*[·:：\-]\s*');
  static final RegExp _emptyBracketsPattern = RegExp(
    r'\[\s*\]|\(\s*\)|（\s*）|「\s*」|""|'
    "''",
  );
  static final RegExp _repeatedSeparatorPattern = RegExp(r'(?:\s*·\s*){2,}');
  static final RegExp _leadingEdgeSepPattern = RegExp(r'^[\s·,，、:：\-]+');
  static final RegExp _trailingEdgeSepPattern = RegExp(r'[\s·,，、:：\-]+$');

  /// Returns whether [toolName] is an internal wrap-up or system control tool
  /// that should not appear as a visible user-facing action row.
  static bool isInternalControlTool(String toolName) =>
      _internalControlTools.contains(toolName);

  /// Formats the light act header (`第 N 幕 · 叙事时间` or `第 N 幕`).
  static String formatActHeader(
    int actNumber,
    String? narrativeTime,
    Translations t,
  ) {
    final cleanTime = narrativeTime?.trim();
    if (cleanTime == null || cleanTime.isEmpty) {
      return t.advanced.recap.actLabel(act: actNumber);
    }
    return t.advanced.actUnit.actHeaderWithTime(
      act: actNumber,
      time: sanitizeHumanText(cleanTime, t),
    );
  }

  /// Resolves an entity's human-readable name, falling back to a localized
  /// entity type label and never exposing raw [entityId].
  static String resolveEntityName({
    required Translations t,
    String? primaryName,
    String? entityId,
    String? entityType,
    Map<String, String>? entityNames,
  }) {
    final direct = sanitizeHumanText(
      primaryName ?? '',
      t,
      entityNames: entityNames,
    );
    if (direct.isNotEmpty) return direct;

    final cleanId = entityId?.trim();
    if (cleanId != null && cleanId.isNotEmpty && entityNames != null) {
      final mapped = sanitizeHumanText(
        entityNames[cleanId] ?? '',
        t,
        entityNames: entityNames,
      );
      if (mapped.isNotEmpty) return mapped;
    }

    final parsedType = FactualEntityType.tryFromString(entityType);
    if (parsedType != null) {
      return entityTypeLabel(parsedType, t);
    }
    return t.advanced.actUnit.unknownEntity;
  }

  /// Localizes a [FactualEntityType] under the `advanced.worldSheet` namespace.
  static String entityTypeLabel(FactualEntityType type, Translations t) {
    final labels = t.advanced.worldSheet;
    return switch (type) {
      FactualEntityType.character => labels.entityTypeCharacter,
      FactualEntityType.location => labels.entityTypeLocation,
      FactualEntityType.item => labels.entityTypeItem,
      FactualEntityType.lore => labels.entityTypeLore,
      FactualEntityType.organization => labels.entityTypeOrganization,
      FactualEntityType.misc => labels.entityTypeMisc,
    };
  }

  /// Strips entity IDs, raw tool names, and JSON payloads from user-visible text.
  static String sanitizeHumanText(
    String raw,
    Translations t, {
    Map<String, String>? entityNames,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (AgentLogRecoveryService.isPlaceholderTitle(trimmed)) {
      return t.advanced.process.interruptedToolPlaceholder;
    }

    String replaceId(Match match) {
      final id = match.group(1);
      if (id != null && entityNames != null) {
        final name = entityNames[id]?.trim();
        if (name != null && name.isNotEmpty) {
          return name;
        }
      }
      return '';
    }

    final text = trimmed
        .replaceAllMapped(_bracketedEntityIdPattern, replaceId)
        .replaceAllMapped(_bareEntityIdPattern, replaceId)
        .replaceAll(_rawJsonObjectPattern, '')
        .replaceAll(_rawJsonArrayPattern, '')
        .replaceAll(_rawToolNamePattern, '')
        .replaceFirst(_calcPrefixPattern, '')
        .replaceAll(_emptyBracketsPattern, '');

    return text
        .replaceAll(_repeatedSeparatorPattern, ' · ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .replaceAll(_leadingEdgeSepPattern, '')
        .replaceAll(_trailingEdgeSepPattern, '')
        .trim();
  }

  /// Formats a fact value for display, turning JSON string arrays into
  /// localized lists and sanitizing any embedded IDs or tool names.
  static String? formatFactValue(
    String? rawValue,
    Translations t, {
    Map<String, String>? entityNames,
  }) {
    if (rawValue == null) return null;
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          final items = decoded
              .map(
                (item) => sanitizeHumanText(
                  item?.toString() ?? '',
                  t,
                  entityNames: entityNames,
                ),
              )
              .where((item) => item.isNotEmpty)
              .toList();
          if (items.isEmpty) return t.advanced.approval.emptyListValue;
          final separator = t.$meta.locale == AppLocale.zhCn ? '、' : ', ';
          return items.join(separator);
        }
      } catch (_) {
        // Fall through to plain text sanitization for malformed brackets.
      }
    }

    final clean = sanitizeHumanText(trimmed, t, entityNames: entityNames);
    return clean.isEmpty ? null : clean;
  }

  /// Builds the full human-readable presentation for a completed round.
  static DirectorRoundPresentation presentRound({
    required int actNumber,
    required StoryRoundArtifacts? artifacts,
    required Translations t,
    StoryAnchor? previousAnchor,
    Map<String, String>? entityNames,
    String? fallbackThinkingContent,
    int maxVisiblePills = defaultMaxVisiblePills,
  }) {
    final mergedNames = _mergeKnownEntityNames(artifacts, entityNames);

    final timeline = artifacts?.agentTimeline ?? const <AgentTimelineBlock>[];
    final isLegacyFallback =
        timeline.isEmpty && (artifacts?.agentSteps.isNotEmpty ?? false);

    final rawSteps = timeline.isNotEmpty
        ? [
            for (final block in timeline)
              if (block.isAction && block.action != null) block.action!,
          ]
        : (artifacts?.agentSteps ?? const <AgentWorkStep>[]);

    final errorSteps = _collectErrorSteps(rawSteps);
    final actions = _buildHumanActions(
      rawSteps,
      t,
      entityNames: mergedNames,
    );
    final actionsSummaryLine = _formatActionsSummaryLine(actions, t);
    final narrations =
        _collectNarrations(timeline, t, entityNames: mergedNames);
    final thinkingSegments = _collectThinkingSegments(
      timeline,
      fallbackThinkingContent: fallbackThinkingContent,
    );
    final thinkingNotes = thinkingSegments.isEmpty
        ? null
        : thinkingSegments.map((s) => s.content).join('\n\n');

    final worldChanges = <DirectorWorldChangeItem>[];
    final factPills = _buildFactPillsAndChanges(
      artifacts?.factsChanges ?? const <FactsChangeRecord>[],
      mergedNames,
      t,
      worldChanges,
    );

    final anchorResult = _buildAnchorPillsAndChanges(
      actNumber: actNumber,
      anchor: artifacts?.storyAnchor,
      previousAnchor: previousAnchor,
      steps: rawSteps,
      t: t,
      entityNames: mergedNames,
      worldChanges: worldChanges,
    );

    final eventText = artifacts?.eventSummary?.formatDisplayText(
          emptyPlaceholder: '',
        ) ??
        '';
    final sanitizedEvent = sanitizeHumanText(
      eventText,
      t,
      entityNames: mergedNames,
    );
    int? eventChangeIndex;
    if (sanitizedEvent.isNotEmpty) {
      eventChangeIndex = worldChanges.length;
      worldChanges.add(
        DirectorWorldChangeItem(
          kind: DirectorWorldChangeKind.eventLogged,
          subject: t.advanced.actUnit.chronicleLabel,
          newValue: sanitizedEvent,
        ),
      );
    }

    final retrievalCount = _countRetrievals(rawSteps, artifacts);
    final hasMajorReview =
        (artifacts?.agentWorkSummary?.majorReviewCompleted ?? false) ||
            rawSteps.any(
              (s) => s.toolName == 'finish_maintenance' && s.isSuccess,
            );

    final allPills = <DirectorChangePill>[
      ...factPills,
      ...anchorResult.pills,
      if (retrievalCount > 0)
        DirectorChangePill(
          id: 'retrieval',
          kind: DirectorPillKind.retrieval,
          label: t.advanced.actUnit.pillRetrievalSummary(count: retrievalCount),
        ),
      if (hasMajorReview)
        DirectorChangePill(
          id: 'maintenance',
          kind: DirectorPillKind.maintenance,
          label: t.advanced.actUnit.pillMaintenanceCalibrated,
        ),
    ];

    if (allPills.isEmpty) {
      final hasEventStep = rawSteps.any(
        (s) => s.toolName == 'record_event_memory' && s.isSuccess,
      );
      if (sanitizedEvent.isNotEmpty || hasEventStep) {
        allPills.add(
          DirectorChangePill(
            id: 'event',
            kind: DirectorPillKind.eventMemory,
            label: t.advanced.actUnit.pillEventLogged,
            worldChangeIndices: [
              if (eventChangeIndex != null) eventChangeIndex,
            ],
          ),
        );
      } else if (actions.isNotEmpty) {
        final totalActions = actions.fold<int>(0, (sum, a) => sum + a.count);
        allPills.add(
          DirectorChangePill(
            id: 'backstage',
            kind: DirectorPillKind.backstage,
            label: t.advanced.actUnit.pillBackstageCount(count: totalActions),
          ),
        );
      }
    }

    final pillLimit = maxVisiblePills < 0 ? 0 : maxVisiblePills;
    final visiblePills = allPills.take(pillLimit).toList();
    final overflowCount = allPills.length - visiblePills.length;

    final rawTime = artifacts?.storyAnchor?.narrativeTime?.trim();
    final eventTime = artifacts?.eventSummary?.narrativeTime?.trim();
    final narrativeTime = (rawTime != null && rawTime.isNotEmpty)
        ? sanitizeHumanText(rawTime, t, entityNames: mergedNames)
        : (eventTime != null && eventTime.isNotEmpty)
            ? sanitizeHumanText(eventTime, t, entityNames: mergedNames)
            : null;
    final effectiveTime = (narrativeTime != null && narrativeTime.isNotEmpty)
        ? narrativeTime
        : null;

    return DirectorRoundPresentation(
      actNumber: actNumber,
      narrativeTime: effectiveTime,
      headerTitle: formatActHeader(actNumber, effectiveTime, t),
      allPills: allPills,
      visiblePills: visiblePills,
      overflowCount: overflowCount,
      worldChangeCount: worldChanges.length,
      worldChanges: worldChanges,
      actions: actions,
      actionsSummaryLine: actionsSummaryLine,
      narrations: narrations,
      thinkingSegments: thinkingSegments,
      thinkingNotes: thinkingNotes,
      errorSteps: errorSteps,
      hasMajorReview: hasMajorReview,
      isLegacyFallback: isLegacyFallback,
    );
  }

  /// Builds the live single-line pulse and sanitized step streams for an
  /// in-progress or interrupted round, covering both writing and maintenance.
  static DirectorLivePresentation presentLive({
    required AdvancedChatState state,
    required Translations t,
    int? actNumber,
    Map<String, String>? entityNames,
  }) {
    final isWorking = state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed;
    final blocks = state.liveBlocks;
    final manuscriptIndex = AgentLiveTranscript.manuscriptIndex(blocks);
    final hasManuscriptProse = manuscriptIndex >= 0;

    final splitIndex = state.inMaintenancePhase
        ? state.maintenanceStepStart.clamp(0, state.agentSteps.length)
        : state.agentSteps.length;
    final task1Steps = state.inMaintenancePhase
        ? state.agentSteps.sublist(0, splitIndex)
        : state.agentSteps;
    final task2Steps = state.inMaintenancePhase
        ? state.agentSteps.sublist(splitIndex)
        : const <AgentWorkStep>[];

    final task1Actions = _buildHumanActions(
      task1Steps,
      t,
      entityNames: entityNames,
      includeRunning: true,
    );
    final maintenanceActions = _buildHumanActions(
      task2Steps,
      t,
      entityNames: entityNames,
      includeRunning: true,
    );
    final errorSteps = _collectErrorSteps(state.agentSteps);

    final rawTime = state.agentStoryAnchor?.narrativeTime?.trim() ??
        state.session.currentNarrativeTime?.trim();
    final narrativeTime = (rawTime != null && rawTime.isNotEmpty)
        ? sanitizeHumanText(rawTime, t, entityNames: entityNames)
        : null;
    final effectiveTime = (narrativeTime != null && narrativeTime.isNotEmpty)
        ? narrativeTime
        : null;

    final resolvedAct = actNumber ??
        ((state.session.nextTurn ?? (state.compactedTurnBase + 1)) < 1
            ? 1
            : (state.session.nextTurn ?? (state.compactedTurnBase + 1)));

    final pulseText = _resolveLivePulseText(
      state: state,
      task1Steps: task1Steps,
      task2Steps: task2Steps,
      t: t,
      entityNames: entityNames,
    );

    final latestNarration = _latestNarrationText(blocks, t, entityNames);

    return DirectorLivePresentation(
      isWorking: isWorking,
      inMaintenancePhase: state.inMaintenancePhase,
      hasManuscriptProse: hasManuscriptProse,
      narrativeTime: effectiveTime,
      headerTitle: formatActHeader(resolvedAct, effectiveTime, t),
      pulseText: pulseText,
      pureReadingPulseText: t.advanced.maintenance.pureReadingStatus,
      currentStep: state.agentRoundProgress?.currentStep,
      maxSteps: state.agentRoundProgress?.maxSteps,
      budgetRatio: state.agentRoundProgress?.budgetRatio,
      actions: task1Actions,
      maintenanceActions: maintenanceActions,
      latestNarration: latestNarration,
      errorSteps: errorSteps,
    );
  }

  static Map<String, String> _mergeKnownEntityNames(
    StoryRoundArtifacts? artifacts,
    Map<String, String>? externalNames,
  ) {
    final map = <String, String>{
      if (externalNames != null) ...externalNames,
    };
    if (artifacts != null) {
      for (final fact in artifacts.retrievedFacts) {
        final id = fact.entity.entityId.trim();
        final name = fact.entity.primaryName.trim();
        if (id.isNotEmpty && name.isNotEmpty) {
          map.putIfAbsent(id, () => name);
        }
      }
    }
    return map;
  }

  static List<DirectorChangePill> _buildFactPillsAndChanges(
    List<FactsChangeRecord> records,
    Map<String, String> entityNames,
    Translations t,
    List<DirectorWorldChangeItem> worldChanges,
  ) {
    if (records.isEmpty) return const [];

    final groupedOrder = <String>[];
    final groupedRecords = <String, List<_ResolvedFactRecord>>{};

    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      final entityType = FactualEntityType.tryFromString(record.entityType);
      final name = resolveEntityName(
        t: t,
        primaryName: record.primaryName,
        entityId: record.entityId,
        entityType: record.entityType,
        entityNames: entityNames,
      );
      final attrLabel = _resolveAttributeLabel(
        record: record,
        entityType: entityType,
        entityNames: entityNames,
        t: t,
      );
      final oldValue = formatFactValue(
        record.oldValue,
        t,
        entityNames: entityNames,
      );
      final newValue = formatFactValue(
        record.newValue,
        t,
        entityNames: entityNames,
      );
      final reason = sanitizeHumanText(
        record.reason ?? '',
        t,
        entityNames: entityNames,
      );

      final changeIndex = worldChanges.length;
      worldChanges.add(
        DirectorWorldChangeItem(
          kind: DirectorWorldChangeKind.fact,
          subject: name,
          attributeLabel: attrLabel,
          oldValue: oldValue,
          newValue: newValue ?? (reason.isNotEmpty ? reason : null),
          reason: reason.isNotEmpty ? reason : null,
          factAction: record.action,
          entityType: entityType,
        ),
      );

      final cleanId = record.entityId?.trim();
      final cleanName = record.primaryName?.trim();
      final groupKey = (cleanId != null && cleanId.isNotEmpty)
          ? 'id:$cleanId'
          : (cleanName != null && cleanName.isNotEmpty)
              ? 'name:$cleanName'
              : 'row:$i';
      if (!groupedRecords.containsKey(groupKey)) {
        groupedOrder.add(groupKey);
        groupedRecords[groupKey] = [];
      }
      groupedRecords[groupKey]!.add(
        _ResolvedFactRecord(
          record: record,
          entityName: name,
          attrLabel: attrLabel,
          worldChangeIndex: changeIndex,
        ),
      );
    }

    final pills = <DirectorChangePill>[];
    for (final key in groupedOrder) {
      final entries = groupedRecords[key]!;
      final first = entries.first;
      final label = entries.length > 1
          ? _multiFactPillLabel(entries, t)
          : _singleFactPillLabel(first, t);
      pills.add(
        DirectorChangePill(
          id: 'fact:$key',
          kind: DirectorPillKind.factChange,
          label: label,
          isHighlight: true,
          worldChangeIndices: [
            for (final entry in entries) entry.worldChangeIndex,
          ],
        ),
      );
    }
    return pills;
  }

  static String _multiFactPillLabel(
    List<_ResolvedFactRecord> entries,
    Translations t,
  ) {
    final name = entries.first.entityName;
    final hasCreate =
        entries.any((e) => e.record.action == FactAction.createEntity);
    if (hasCreate) {
      return t.advanced.actUnit.pillEntityCreated(name: name);
    }
    return t.advanced.actUnit.pillEntityMultiUpdated(
      name: name,
      count: entries.length,
    );
  }

  static String _singleFactPillLabel(
    _ResolvedFactRecord entry,
    Translations t,
  ) {
    final name = entry.entityName;
    switch (entry.record.action) {
      case FactAction.createEntity:
        return t.advanced.actUnit.pillEntityCreated(name: name);
      case FactAction.archiveEntity:
        return t.advanced.actUnit.pillEntityArchived(name: name);
      case FactAction.addAlias:
        return t.advanced.actUnit.pillAliasAdded(name: name);
      case FactAction.setImportance:
        return t.advanced.actUnit.pillImportance(name: name);
      case FactAction.updateAttr:
      case FactAction.appendList:
      case FactAction.removeFromList:
        final attr = entry.attrLabel;
        if (attr != null && attr.isNotEmpty) {
          return t.advanced.actUnit.pillAttrUpdated(name: name, attr: attr);
        }
        return t.advanced.actUnit.pillEntityUpdated(name: name);
    }
  }

  static String? _resolveAttributeLabel({
    required FactsChangeRecord record,
    required FactualEntityType? entityType,
    required Map<String, String> entityNames,
    required Translations t,
  }) {
    final attrKey = record.attrKey?.trim();
    switch (record.action) {
      case FactAction.createEntity:
        if (attrKey == null || attrKey.isEmpty) {
          return t.advanced.approval.kindCreate;
        }
        return _localizeAttrKey(attrKey, entityType, entityNames, t);
      case FactAction.archiveEntity:
        return t.advanced.approval.kindArchive;
      case FactAction.addAlias:
        return t.advanced.approval.kindAlias;
      case FactAction.setImportance:
        return t.intermediate.chat.factsActionSetImportance;
      case FactAction.updateAttr:
      case FactAction.appendList:
      case FactAction.removeFromList:
        if (attrKey == null || attrKey.isEmpty) return null;
        return _localizeAttrKey(attrKey, entityType, entityNames, t);
    }
  }

  static String _localizeAttrKey(
    String attrKey,
    FactualEntityType? entityType,
    Map<String, String> entityNames,
    Translations t,
  ) {
    final relObject = AttributeSchema.relationshipObjectOf(attrKey);
    if (relObject != null) {
      final cleanObject = _bareEntityIdPattern.hasMatch(relObject)
          ? resolveEntityName(
              t: t,
              entityId: relObject,
              entityNames: entityNames,
            )
          : sanitizeHumanText(relObject, t, entityNames: entityNames);
      return t.intermediate.memoryBrowser.attributeLabels.relationshipWith(
        name: cleanObject.isEmpty
            ? t.advanced.actUnit.unknownEntity
            : cleanObject,
      );
    }
    final localized = factualAttributeLabel(t, entityType, attrKey);
    if (localized != null && localized.isNotEmpty) return localized;
    final clean = sanitizeHumanText(attrKey, t, entityNames: entityNames);
    return clean.isEmpty ? t.advanced.worldSheet.entityTypeMisc : clean;
  }

  static ({List<DirectorChangePill> pills}) _buildAnchorPillsAndChanges({
    required int actNumber,
    required StoryAnchor? anchor,
    required StoryAnchor? previousAnchor,
    required List<AgentWorkStep> steps,
    required Translations t,
    required Map<String, String> entityNames,
    required List<DirectorWorldChangeItem> worldChanges,
  }) {
    if (anchor == null || anchor.isEmpty) {
      return (pills: const []);
    }

    final hasAnchorStep = steps.any(
      (s) => s.toolName == 'update_story_anchor' && s.isSuccess,
    );
    final changedFromPrevious =
        previousAnchor != null && !_anchorsEqual(previousAnchor, anchor);
    final updatedThisRound =
        anchor.updatedTurn == actNumber || hasAnchorStep || changedFromPrevious;
    if (!updatedThisRound) {
      return (pills: const []);
    }

    final prevTexts = {
      for (final f in previousAnchor?.foreshadows ?? const <AnchorForeshadow>[])
        f.text.trim(),
    };
    final prevResolved = {
      for (final f in previousAnchor?.foreshadows ?? const <AnchorForeshadow>[])
        if (f.resolved) f.text.trim(),
    };

    final addedForeshadows = <String>[];
    final resolvedForeshadows = <String>[];
    for (final f in anchor.foreshadows) {
      final cleanText = sanitizeHumanText(f.text, t, entityNames: entityNames);
      if (cleanText.isEmpty) continue;
      final rawKey = f.text.trim();
      if (f.resolved) {
        if (!prevResolved.contains(rawKey)) {
          resolvedForeshadows.add(cleanText);
        }
      } else if (!prevTexts.contains(rawKey)) {
        addedForeshadows.add(cleanText);
      }
    }

    final resolvedIndices = <int>[];
    for (final text in resolvedForeshadows) {
      resolvedIndices.add(worldChanges.length);
      worldChanges.add(
        DirectorWorldChangeItem(
          kind: DirectorWorldChangeKind.foreshadowResolved,
          subject: t.advanced.actUnit.foreshadowResolved,
          newValue: text,
        ),
      );
    }
    final addedIndices = <int>[];
    for (final text in addedForeshadows) {
      addedIndices.add(worldChanges.length);
      worldChanges.add(
        DirectorWorldChangeItem(
          kind: DirectorWorldChangeKind.foreshadowAdded,
          subject: t.advanced.actUnit.foreshadowNew,
          newValue: text,
        ),
      );
    }

    final curArc = sanitizeHumanText(
      anchor.arc ?? '',
      t,
      entityNames: entityNames,
    );
    final prevArc = sanitizeHumanText(
      previousAnchor?.arc ?? '',
      t,
      entityNames: entityNames,
    );
    final curOneLiner = sanitizeHumanText(
      anchor.oneLiner ?? '',
      t,
      entityNames: entityNames,
    );
    final prevOneLiner = sanitizeHumanText(
      previousAnchor?.oneLiner ?? '',
      t,
      entityNames: entityNames,
    );

    final arcChanged = curArc.isNotEmpty && curArc != prevArc;
    final oneLinerChanged =
        curOneLiner.isNotEmpty && curOneLiner != prevOneLiner;
    final anchorMetaIndices = <int>[];

    if (arcChanged || oneLinerChanged) {
      final newDisplay = [
        if (arcChanged) curArc,
        if (oneLinerChanged && curOneLiner != curArc) curOneLiner,
      ].join(' · ');
      final oldDisplay = [
        if (arcChanged && prevArc.isNotEmpty) prevArc,
        if (oneLinerChanged &&
            prevOneLiner.isNotEmpty &&
            prevOneLiner != prevArc)
          prevOneLiner,
      ].join(' · ');
      anchorMetaIndices.add(worldChanges.length);
      worldChanges.add(
        DirectorWorldChangeItem(
          kind: DirectorWorldChangeKind.storyArc,
          subject: t.advanced.actUnit.arcProgress,
          oldValue: oldDisplay.isNotEmpty ? oldDisplay : null,
          newValue: newDisplay,
        ),
      );
    }

    final curTime = sanitizeHumanText(
      anchor.narrativeTime ?? '',
      t,
      entityNames: entityNames,
    );
    final prevTime = sanitizeHumanText(
      previousAnchor?.narrativeTime ?? '',
      t,
      entityNames: entityNames,
    );
    if (curTime.isNotEmpty && curTime != prevTime) {
      anchorMetaIndices.add(worldChanges.length);
      worldChanges.add(
        DirectorWorldChangeItem(
          kind: DirectorWorldChangeKind.narrativeTime,
          subject: t.advanced.actUnit.narrativeTimeChange,
          oldValue: prevTime.isNotEmpty ? prevTime : null,
          newValue: curTime,
        ),
      );
    }

    final pills = <DirectorChangePill>[];
    for (var i = 0; i < resolvedForeshadows.length; i++) {
      pills.add(
        DirectorChangePill(
          id: 'foreshadow:resolved:$i',
          kind: DirectorPillKind.foreshadow,
          label: t.advanced.actUnit.pillForeshadowResolved(
            text: _truncatePillText(resolvedForeshadows[i]),
          ),
          isHighlight: true,
          worldChangeIndices: [resolvedIndices[i]],
        ),
      );
    }
    for (var i = 0; i < addedForeshadows.length; i++) {
      pills.add(
        DirectorChangePill(
          id: 'foreshadow:new:$i',
          kind: DirectorPillKind.foreshadow,
          label: t.advanced.actUnit.pillForeshadowNew(
            text: _truncatePillText(addedForeshadows[i]),
          ),
          isHighlight: true,
          worldChangeIndices: [addedIndices[i]],
        ),
      );
    }
    if (pills.isEmpty &&
        (arcChanged || oneLinerChanged || curTime.isNotEmpty)) {
      pills.add(
        DirectorChangePill(
          id: 'foreshadow:anchor',
          kind: DirectorPillKind.foreshadow,
          label: t.advanced.actUnit.pillAnchorUpdated,
          isHighlight: true,
          worldChangeIndices: anchorMetaIndices,
        ),
      );
    }

    return (pills: pills);
  }

  static bool _anchorsEqual(StoryAnchor a, StoryAnchor b) {
    if (a.arc != b.arc ||
        a.narrativeTime != b.narrativeTime ||
        a.oneLiner != b.oneLiner ||
        a.foreshadows.length != b.foreshadows.length) {
      return false;
    }
    for (var i = 0; i < a.foreshadows.length; i++) {
      if (a.foreshadows[i].text != b.foreshadows[i].text ||
          a.foreshadows[i].resolved != b.foreshadows[i].resolved) {
        return false;
      }
    }
    return true;
  }

  static String _truncatePillText(String text, {int maxChars = 14}) {
    final trimmed = text.trim();
    if (trimmed.length <= maxChars) return trimmed;
    return '${trimmed.substring(0, maxChars - 1)}…';
  }

  static int _countRetrievals(
    List<AgentWorkStep> steps,
    StoryRoundArtifacts? artifacts,
  ) {
    if (steps.isNotEmpty) {
      return steps
          .where((s) => _retrievalTools.contains(s.toolName) && s.isSuccess)
          .length;
    }
    if (artifacts == null) return 0;
    return artifacts.retrievedFacts.length + artifacts.retrievedMemories.length;
  }

  static List<AgentWorkStep> _collectErrorSteps(List<AgentWorkStep> steps) {
    final seen = <Object>{};
    final result = <AgentWorkStep>[];
    for (final step in steps) {
      if (!step.isError && !step.isWarning) continue;
      final identity = (
        callId: step.callId,
        toolName: step.toolName,
        stepIndex: step.stepIndex,
        order: step.order,
        status: step.status,
      );
      if (seen.add(identity)) {
        result.add(step);
      }
    }
    return result;
  }

  static List<DirectorHumanAction> _buildHumanActions(
    List<AgentWorkStep> steps,
    Translations t, {
    Map<String, String>? entityNames,
    bool includeRunning = false,
  }) {
    final consolidated = <DirectorHumanAction>[];
    final indexByKey = <(String, String?, bool), int>{};

    for (final step in steps) {
      if (isInternalControlTool(step.toolName)) continue;
      if (step.isError || step.isWarning) continue;
      if (!includeRunning && step.isRunning) continue;

      final verb = stageVerbOf(step.toolName, t);
      var detail = sanitizeHumanText(
        step.title,
        t,
        entityNames: entityNames,
      );
      if (detail == verb) {
        detail = '';
      } else if (detail.startsWith('$verb · ')) {
        detail = detail.substring(verb.length + 3).trim();
      } else if (detail.startsWith(verb) && detail.length > verb.length) {
        final rest = detail
            .substring(verb.length)
            .replaceFirst(_leadingEdgeSepPattern, '')
            .trim();
        if (rest.isNotEmpty) detail = rest;
      }

      final normalizedDetail = detail.isEmpty ? null : detail;
      final key = (verb, normalizedDetail, step.isRunning);
      final existingIndex = indexByKey[key];
      if (existingIndex != null && !step.isRunning) {
        final existing = consolidated[existingIndex];
        consolidated[existingIndex] = DirectorHumanAction(
          verb: existing.verb,
          detail: existing.detail,
          count: existing.count + 1,
          isRunning: existing.isRunning,
        );
      } else {
        if (!step.isRunning) {
          indexByKey[key] = consolidated.length;
        }
        consolidated.add(
          DirectorHumanAction(
            verb: verb,
            detail: normalizedDetail,
            isRunning: step.isRunning,
          ),
        );
      }
    }

    return consolidated;
  }

  static String? _formatActionsSummaryLine(
    List<DirectorHumanAction> actions,
    Translations t,
  ) {
    if (actions.isEmpty) return null;
    final parts = [for (final action in actions) action.summaryText(t)];
    return parts.join(' · ');
  }

  static List<String> _collectNarrations(
    List<AgentTimelineBlock> timeline,
    Translations t, {
    Map<String, String>? entityNames,
  }) {
    final result = <String>[];
    for (final block in timeline) {
      if (block.kind != AgentTimelineKind.narration) continue;
      final clean = sanitizeHumanText(
        block.text,
        t,
        entityNames: entityNames,
      );
      if (clean.isNotEmpty) result.add(clean);
    }
    return result;
  }

  static List<DirectorThinkingSegment> _collectThinkingSegments(
    List<AgentTimelineBlock> timeline, {
    String? fallbackThinkingContent,
  }) {
    final segments = <DirectorThinkingSegment>[];
    for (final block in timeline) {
      if (block.kind != AgentTimelineKind.thinking) continue;
      final text = block.text.trim();
      if (text.isEmpty) continue;
      segments.add(
        DirectorThinkingSegment(
          content: text,
          duration: block.duration,
        ),
      );
    }
    if (segments.isEmpty &&
        fallbackThinkingContent != null &&
        fallbackThinkingContent.trim().isNotEmpty) {
      segments.add(
        DirectorThinkingSegment(content: fallbackThinkingContent.trim()),
      );
    }
    return segments;
  }

  static String _resolveLivePulseText({
    required AdvancedChatState state,
    required List<AgentWorkStep> task1Steps,
    required List<AgentWorkStep> task2Steps,
    required Translations t,
    Map<String, String>? entityNames,
  }) {
    if (state.phase == IntermediatePhase.extracting ||
        state.phase == IntermediatePhase.retrieving) {
      return t.advanced.process.preparingActive;
    }
    if (state.phase == IntermediatePhase.compacting) {
      return t.advanced.process.compactingActive;
    }
    if (state.agentAskPrompt != null || state.agentApprovalPrompt != null) {
      return t.advanced.process.waitingUser;
    }
    if (state.phase == IntermediatePhase.persisting ||
        state.phase == IntermediatePhase.summarizing) {
      return t.advanced.process.savingActive;
    }

    if (state.inMaintenancePhase) {
      final activeMaintStep = _findAnchorStep(task2Steps);
      if (activeMaintStep != null) {
        final verb = _humanStepHeadline(
          activeMaintStep,
          t,
          entityNames: entityNames,
        );
        return t.advanced.actUnit.maintenanceStepActive(verb: verb);
      }
      return t.advanced.actUnit.maintenanceHeadline;
    }

    if (state.agentActivity != AgentActivity.tool) {
      return switch (state.agentActivity) {
        AgentActivity.waitingResponse =>
          task1Steps.isEmpty && state.liveBlocks.isEmpty
              ? t.advanced.heartbeat.composing
              : t.advanced.process.waitingResponse,
        AgentActivity.thinking => t.advanced.process.thinkingActive,
        AgentActivity.generating => t.advanced.process.generatingActive,
        AgentActivity.narrating => t.advanced.process.narratingActive,
        AgentActivity.processing => t.advanced.process.processingActive,
        AgentActivity.retryWaiting => t.advanced.process.retryActive,
        AgentActivity.tool => t.advanced.process.processingActive,
      };
    }

    final runningFinish = task1Steps.lastWhere(
      (s) => s.toolName == 'finish_round' && s.isRunning,
      orElse: () => const AgentWorkStep(toolName: ''),
    );
    if (runningFinish.toolName == 'finish_round') {
      return t.advanced.penStreaming;
    }

    final activeStep = _findAnchorStep(task1Steps);
    if (activeStep == null) {
      return t.advanced.heartbeat.composing;
    }
    final verb = _humanStepHeadline(
      activeStep,
      t,
      entityNames: entityNames,
    );
    return t.advanced.process.working(verb: verb);
  }

  static AgentWorkStep? _findAnchorStep(
    List<AgentWorkStep> steps, {
    bool excludeControl = true,
  }) {
    final candidates = excludeControl
        ? steps.where((s) => !isInternalControlTool(s.toolName)).toList()
        : steps;
    if (candidates.isEmpty) return null;
    final runningIndex = candidates.lastIndexWhere((s) => s.isRunning);
    return runningIndex >= 0 ? candidates[runningIndex] : candidates.last;
  }

  static String _humanStepHeadline(
    AgentWorkStep step,
    Translations t, {
    Map<String, String>? entityNames,
  }) {
    final verb = stageVerbOf(step.toolName, t);
    if (step.isRunning && step.title.isNotEmpty) {
      final cleanTitle = sanitizeHumanText(
        step.title,
        t,
        entityNames: entityNames,
      );
      if (cleanTitle.isNotEmpty) return cleanTitle;
    }
    return verb;
  }

  static String? _latestNarrationText(
    List<AgentLiveBlock> blocks,
    Translations t,
    Map<String, String>? entityNames,
  ) {
    final manuscriptIndex = AgentLiveTranscript.manuscriptIndex(blocks);
    for (var i = blocks.length - 1; i >= 0; i--) {
      if (i == manuscriptIndex) continue;
      final block = blocks[i];
      if (block.kind != AgentLiveBlockKind.text) continue;
      final clean = sanitizeHumanText(
        block.text,
        t,
        entityNames: entityNames,
      );
      if (clean.isNotEmpty) return clean;
    }
    return null;
  }
}

class _ResolvedFactRecord {
  const _ResolvedFactRecord({
    required this.record,
    required this.entityName,
    required this.attrLabel,
    required this.worldChangeIndex,
  });

  final FactsChangeRecord record;
  final String entityName;
  final String? attrLabel;
  final int worldChangeIndex;
}
