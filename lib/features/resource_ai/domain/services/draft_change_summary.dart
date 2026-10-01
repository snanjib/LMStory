/// 草稿变更摘要：两个 [DraftState] 之间的差分（过程线的领域源）。
///
/// 工具回调把「旧草稿 → 新草稿」交给 [summarizeDraftChanges]，产出确定
/// 顺序的变更记录列表；控制器据此把每条记录渲染为 role=tool 的过程
/// 消息（实时草稿预览 + 聊天流里的过程线）。纯函数、不可变记录，
/// 不依赖 Flutter。
library;

import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';

/// 单条变更的种类。
enum DraftChangeKind {
  /// 卡字段写入（[DraftChangeRecord.field] 有值）。
  fieldUpdated,

  /// 卡标签整表覆盖。
  tagsUpdated,

  /// 世界书书级元信息（name/description）变更。
  bookMetaUpdated,

  /// 词条新增。
  entryAdded,

  /// 词条内容变更（含 extensions 内部变更）。
  entryUpdated,

  /// 词条删除。
  entryRemoved,

  /// 草稿首次定稿（false → true；反向忽略）。
  draftFinalized,
}

/// 一条变更记录（值对象；kind 决定其余字段的语义）。
class DraftChangeRecord {
  const DraftChangeRecord({
    required this.kind,
    this.field,
    this.entryTitle,
  });

  final DraftChangeKind kind;

  /// [DraftChangeKind.fieldUpdated] 专用：被写入的卡字段。
  final CardField? field;

  /// entry* 三类专用：词条的展示标题（comment 优先，其次 keys，兜底 id）。
  final String? entryTitle;
}

/// 摘要两个草稿状态之间的变更。
///
/// - kind 不一致（模式切换）：防御性返回空列表——工具按模式门控，
///   正常流程到不了这里。
/// - 顺序确定性：卡按字段枚举序后标签；书先书级元信息，再词条
///   （新增/更新按 after 序交错），删除按 before 序，最后定稿标记。
List<DraftChangeRecord> summarizeDraftChanges(
  DraftState before,
  DraftState after,
) {
  if (before.kind != after.kind) return const [];
  final changes = <DraftChangeRecord>[];
  switch (after.kind) {
    case DraftKind.characterCard:
      _collectCard(before.card, after.card, changes);
    case DraftKind.worldbook:
      _collectBook(before.book, after.book, changes);
  }
  if (!before.finalized && after.finalized) {
    changes.add(const DraftChangeRecord(kind: DraftChangeKind.draftFinalized));
  }
  return changes;
}

void _collectCard(
  CardDraft? before,
  CardDraft? after,
  List<DraftChangeRecord> out,
) {
  for (final field in CardField.values) {
    if ((before?.value(field) ?? '') != (after?.value(field) ?? '')) {
      out.add(
        DraftChangeRecord(kind: DraftChangeKind.fieldUpdated, field: field),
      );
    }
  }
  if (!_stringListEquals(before?.tags ?? const [], after?.tags ?? const [])) {
    out.add(const DraftChangeRecord(kind: DraftChangeKind.tagsUpdated));
  }
}

void _collectBook(
  WorldbookDraft? before,
  WorldbookDraft? after,
  List<DraftChangeRecord> out,
) {
  if ((before?.name ?? '') != (after?.name ?? '') ||
      (before?.description ?? '') != (after?.description ?? '')) {
    out.add(const DraftChangeRecord(kind: DraftChangeKind.bookMetaUpdated));
  }

  final beforeById = <String, WorldEntry>{
    for (final e in before?.entries ?? const <WorldEntry>[]) e.id: e,
  };
  final afterIds = {
    for (final e in after?.entries ?? const <WorldEntry>[]) e.id,
  };
  // 新增/更新按 after 序（与用户看到的新草稿顺序一致）
  for (final entry in after?.entries ?? const <WorldEntry>[]) {
    final old = beforeById[entry.id];
    if (old == null) {
      out.add(
        DraftChangeRecord(
          kind: DraftChangeKind.entryAdded,
          entryTitle: _entryTitle(entry),
        ),
      );
    } else if (_entryDiffers(old, entry)) {
      out.add(
        DraftChangeRecord(
          kind: DraftChangeKind.entryUpdated,
          entryTitle: _entryTitle(entry),
        ),
      );
    }
  }
  // 删除按 before 序
  for (final entry in before?.entries ?? const <WorldEntry>[]) {
    if (!afterIds.contains(entry.id)) {
      out.add(
        DraftChangeRecord(
          kind: DraftChangeKind.entryRemoved,
          entryTitle: _entryTitle(entry),
        ),
      );
    }
  }
}

/// 词条展示标题：comment 优先，其次 keys 拼接，兜底 id。
String _entryTitle(WorldEntry entry) => entry.comment.isNotEmpty
    ? entry.comment
    : entry.keys.isNotEmpty
        ? entry.keys.join('、')
        : entry.id;

bool _entryDiffers(WorldEntry a, WorldEntry b) =>
    !_stringListEquals(a.keys, b.keys) ||
    !_stringListEquals(a.secondaryKeys, b.secondaryKeys) ||
    a.comment != b.comment ||
    a.content != b.content ||
    a.constant != b.constant ||
    a.selective != b.selective ||
    a.insertionOrder != b.insertionOrder ||
    a.enabled != b.enabled ||
    a.positionBeforeChar != b.positionBeforeChar ||
    !_deepEquals(a.extensions, b.extensions);

bool _stringListEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 递归深比较（JSON 形态的 Map/List/标量；extensions 等嵌套结构）。
bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
