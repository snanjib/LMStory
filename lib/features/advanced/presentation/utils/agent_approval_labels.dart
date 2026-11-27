import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart'
    show AgentFactsDeltaInput;
import 'package:lmstory/features/memory/domain/entities/facts_projection_note.dart';
import 'package:lmstory/i18n/factual_labels.dart';
import 'package:lmstory/i18n/strings.g.dart';

ApprovalSummaryData approvalSummaryDataOf(
  String toolName,
  Map<String, dynamic> arguments,
) {
  String? readName(String idKey, String nameKey) {
    final name = arguments[nameKey];
    if (name is String && name.trim().isNotEmpty) return name;
    final id = arguments[idKey];
    return id is String && id.isNotEmpty ? id : null;
  }

  return switch (toolName) {
    'update_facts' => ApprovalSummaryData(
        factCount:
            AgentFactsDeltaInput.decodeList(arguments['deltas'])?.length ?? 1,
      ),
    'update_story_anchor' => ApprovalSummaryData(
        anchorFields: [
          if (arguments['arc'] != null) ApprovalAnchorField.arc,
          if (arguments['foreshadows'] != null) ApprovalAnchorField.foreshadow,
          if (arguments['one_liner'] != null) ApprovalAnchorField.mainline,
        ],
      ),
    'merge_entities' => ApprovalSummaryData(
        source: readName('source_entity_id', 'source_name'),
        target: readName('target_entity_id', 'target_name'),
      ),
    _ => const ApprovalSummaryData(),
  };
}

String formatApprovalSummary(
  Translations t,
  String toolName,
  ApprovalSummaryData data,
) {
  final s = t.advanced.hitl;
  return switch (toolName) {
    'update_facts' => s.approvalFacts(count: data.factCount),
    'update_story_anchor' when data.anchorFields.isNotEmpty =>
      s.approvalAnchorWithParts(
        parts: data.anchorFields
            .map(
              (field) => switch (field) {
                ApprovalAnchorField.arc => s.approvalPartNewArc,
                ApprovalAnchorField.foreshadow => s.approvalPartForeshadow,
                ApprovalAnchorField.mainline => s.approvalPartMainline,
                ApprovalAnchorField.time => t.advanced.approval.anchorFieldTime,
              },
            )
            .join(t.$meta.locale == AppLocale.zhCn ? '、' : ', '),
      ),
    'update_story_anchor' => s.approvalAnchor,
    'record_event_memory' => s.approvalEvent,
    'merge_entities' => s.approvalMerge(
        source: data.source ?? s.approvalUnknownEntity,
        target: data.target ?? s.approvalUnknownEntity,
      ),
    _ => s.approvalGeneric,
  };
}

typedef ApprovalRowText = ({
  String entityName,
  String? attributeLabel,
  String? before,
  String? after,
  String? note,
});

/// Formats the captured approval inputs without repeating a repository read.
ApprovalRowText formatApprovalChange(
  AgentApprovalChange change,
  Translations t,
) {
  final s = t.advanced.approval;
  final key = change.attrKey;
  var entityName = change.entityName;
  var attributeLabel = key == null
      ? null
      : factualAttributeLabel(t, change.entityType, key) ?? key;
  var before = change.before;
  var after = change.after;
  var note = change.note;

  switch (change.details) {
    case ApprovalFactNotes(:final notes):
      note = notes.map((note) => _noteText(note, t)).join('\n');
    case ApprovalAnchorDetails(:final field, :final added, :final removed):
      entityName = s.anchorEntityName;
      attributeLabel = switch (field) {
        ApprovalAnchorField.arc => s.anchorFieldArc,
        ApprovalAnchorField.mainline => s.anchorFieldMainline,
        ApprovalAnchorField.time => s.anchorFieldTime,
        ApprovalAnchorField.foreshadow => s.anchorFieldForeshadow,
      };
      if (field == ApprovalAnchorField.foreshadow) {
        note = change.effective
            ? s.foreshadowDiff(added: added, removed: removed)
            : s.noteUnchanged;
      }
    case ApprovalEventDetails(
        :final previous,
        :final who,
        when: final eventTime,
        where: final eventPlace
      ):
      entityName = s.eventEntityName;
      before = previous?.formatDisplayText(
        emptyPlaceholder: t.intermediate.chat.memoryDetail.empty,
      );
      final significance = change.reason;
      final fields = [
        if (who != null) s.valueLine(label: s.eventFieldWho, value: who),
        if (eventTime != null)
          s.valueLine(label: s.eventFieldWhen, value: eventTime),
        if (eventPlace != null)
          s.valueLine(label: s.eventFieldWhere, value: eventPlace),
        if (significance != null)
          s.valueLine(label: s.eventFieldSignificance, value: significance),
      ];
      final notes = [
        if (fields.isNotEmpty) fields.join(s.eventFieldSeparator),
        if (previous != null) s.noteEventReplace,
      ];
      note = notes.isEmpty ? null : notes.join('\n');
    case ApprovalMergeDetails(:final source, :final target):
      entityName = s.mergePair(source: source, target: target);
      after = s.mergeIntentPlain(source: source, target: target);
      note = s.noteMergeDetail;
    case ApprovalSnapshotDetails(:final attribute):
      after = s.valueLine(
        label: attributeLabel ?? attribute.attrKey,
        value: attribute.formatValue(emptyListPlaceholder: s.emptyListValue),
      );
    case null:
      break;
  }
  return (
    entityName: entityName,
    attributeLabel: attributeLabel,
    before: before,
    after: after,
    note: note,
  );
}

String _noteText(FactsProjectionNote note, Translations t) {
  final s = t.advanced.approval;
  return switch (note) {
    FactsProjectionNote.missingFields => s.noteMissingFields,
    FactsProjectionNote.unknownEntityType => s.noteMissingFields,
    FactsProjectionNote.entityMissing => s.noteEntityMissing,
    FactsProjectionNote.nameIsIdentity => s.noteNameIsIdentity,
    FactsProjectionNote.attrKeyNotWhitelisted => s.noteWhitelist,
    FactsProjectionNote.valueTooLong => s.noteTooLong,
    FactsProjectionNote.tooFrequent => s.noteTooFrequent,
    FactsProjectionNote.valueUnchangedBaseline => s.noteUnchanged,
    FactsProjectionNote.valueUnchanged => s.noteUnchanged,
    FactsProjectionNote.confidenceGate => s.noteConfidenceGate,
    FactsProjectionNote.listRejectsUpdate => s.noteListRejects,
    FactsProjectionNote.baselineSingleRedirect => s.noteBaselineRedirect,
    FactsProjectionNote.appendOnSingleConvertsUpdate => s.noteBaselineRedirect,
    FactsProjectionNote.duplicateExact => s.noteDuplicate,
    FactsProjectionNote.dictRejectsAppend => s.noteDictRejectsAppend,
    FactsProjectionNote.dictKeyCreatesList => s.noteDictKeyCreatesList,
    FactsProjectionNote.noMutableList => s.noteNoMutableList,
    FactsProjectionNote.valueNotInList => s.noteValueNotInList,
    FactsProjectionNote.aliasEmpty => s.noteMissingFields,
    FactsProjectionNote.aliasTooLong => s.noteTooLong,
    FactsProjectionNote.aliasSameAsPrimary => s.noteAliasSameAsPrimary,
    FactsProjectionNote.aliasExists => s.noteDuplicate,
    FactsProjectionNote.aliasLimit => s.noteAliasLimit,
    FactsProjectionNote.alreadyArchived => s.noteAlreadyArchived,
    FactsProjectionNote.sameNameConvertsUpdate => s.noteSameNameUpdate,
    FactsProjectionNote.sameNameConvertsAlias => s.noteSameNameAlias,
    FactsProjectionNote.createsAttrRow => s.noteCreatesAttrRow,
    FactsProjectionNote.importanceOutOfRange => s.noteImportanceOutOfRange,
  };
}
