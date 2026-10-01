/// 草稿变更与卡字段的本地化文案映射（纯展示层工具，无 widget）。
///
/// 草稿预览（字段区块标题）与聊天流过程线（[draftChangeLabel]）共用，
/// 保证「预览里叫什么、过程线就说改了什么」口径一致。
library;

import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/draft_change_summary.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 卡字段 → 本地化标签（预览与过程线共用）。
String cardFieldLabel(Translations t, CardField field) => switch (field) {
      CardField.name => t.resourceAi.fieldName,
      CardField.description => t.resourceAi.fieldDescription,
      CardField.personality => t.resourceAi.fieldPersonality,
      CardField.scenario => t.resourceAi.fieldScenario,
      CardField.firstMes => t.resourceAi.fieldFirstMes,
      CardField.mesExample => t.resourceAi.fieldMesExample,
      CardField.creatorNotes => t.resourceAi.fieldCreatorNotes,
    };

/// 标签字段（CardDraft.tags 用）。
String cardTagsLabel(Translations t) => t.resourceAi.fieldTags;

/// 过程线文案：按变更种类映射 slang 模板。
String draftChangeLabel(Translations t, DraftChangeRecord change) =>
    switch (change.kind) {
      DraftChangeKind.fieldUpdated => t.resourceAi.changeField(
          label: cardFieldLabel(t, change.field ?? CardField.name),
        ),
      DraftChangeKind.tagsUpdated => t.resourceAi.changeTags,
      DraftChangeKind.bookMetaUpdated => t.resourceAi.changeBookMeta,
      DraftChangeKind.entryAdded => t.resourceAi.changeEntryAdded(
          title: change.entryTitle ?? '',
        ),
      DraftChangeKind.entryUpdated => t.resourceAi.changeEntryUpdated(
          title: change.entryTitle ?? '',
        ),
      DraftChangeKind.entryRemoved => t.resourceAi.changeEntryRemoved(
          title: change.entryTitle ?? '',
        ),
      DraftChangeKind.draftFinalized => t.resourceAi.changeFinalized,
    };
