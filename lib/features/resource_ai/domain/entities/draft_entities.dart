/// AI 建卡（resource_ai）草稿值对象。
///
/// 不可变值对象：所有变换返回新实例，供 agent 工具与控制器以
/// 「回调新草稿 → 状态替换」的方式驱动；序列化（JSON 构建/patch）在
/// `draft_json_builder.dart`。
library;

/// 角色卡可写字段（V2 `data` 段内的 V1 兼容子集）。
enum CardField {
  name,
  description,
  personality,
  scenario,
  firstMes,
  mesExample,
  creatorNotes;

  /// SillyTavern 兼容的 JSON 键名（蛇形）。
  String get jsonName => switch (this) {
        CardField.name => 'name',
        CardField.description => 'description',
        CardField.personality => 'personality',
        CardField.scenario => 'scenario',
        CardField.firstMes => 'first_mes',
        CardField.mesExample => 'mes_example',
        CardField.creatorNotes => 'creator_notes',
      };
}

/// 本工具会话的草稿种类。
enum DraftKind { characterCard, worldbook }

/// 世界书词条（SillyTavern World Info 条目的可写子集 + 整包 extensions）。
class WorldEntry {
  const WorldEntry({
    required this.id,
    required this.keys,
    required this.content,
    this.secondaryKeys = const [],
    this.comment = '',
    this.constant = false,
    this.selective = false,
    this.insertionOrder = 100,
    this.enabled = true,
    this.positionBeforeChar = true,
    this.extensions = const {},
  });

  /// 端内分配的稳定 id（`e<n>`），patch 时用于对位既有条目。
  final String id;
  final List<String> keys;
  final List<String> secondaryKeys;
  final String comment;
  final String content;
  final bool constant;
  final bool selective;

  /// ST 惯例：数值越大越重要（越靠前注入）。
  final int insertionOrder;
  final bool enabled;

  /// true = before_char，false = after_char。
  final bool positionBeforeChar;

  /// v1 可写子集之外的整包保留（编辑场景：depth/probability 等原样带回）。
  final Map<String, dynamic> extensions;
}

/// 角色卡草稿：七个文本字段 + 标签。
class CardDraft {
  const CardDraft({
    Map<CardField, String> fields = const {},
    this.tags = const [],
  }) : _fields = fields;

  factory CardDraft.initial() => const CardDraft();

  final Map<CardField, String> _fields;
  final List<String> tags;

  String value(CardField field) => _fields[field] ?? '';

  String get name => value(CardField.name);

  /// 任一字段或标签非空即视为已动笔。
  bool get isDirty =>
      tags.isNotEmpty || CardField.values.any((f) => value(f).isNotEmpty);

  CardDraft withField(CardField field, String value) => CardDraft(
        fields: {..._fields, field: value},
        tags: tags,
      );

  CardDraft withTags(List<String> value) =>
      CardDraft(fields: _fields, tags: List.of(value));
}

/// 世界书草稿：书级元信息 + 词条表。
class WorldbookDraft {
  const WorldbookDraft({
    this.name = '',
    this.description = '',
    this.entries = const [],
  });

  factory WorldbookDraft.initial() => const WorldbookDraft();

  final String name;
  final String description;
  final List<WorldEntry> entries;

  bool get isDirty =>
      name.isNotEmpty || description.isNotEmpty || entries.isNotEmpty;

  /// 分配下一个不与现有条目冲突的数字递增 id。
  String nextEntryId() {
    var max = 0;
    for (final e in entries) {
      final n = int.tryParse(e.id.replaceFirst(RegExp('^e'), ''));
      if (n != null && n > max) {
        max = n;
      }
    }
    return 'e${max + 1}';
  }

  /// 按 id 覆盖或追加（追加放在表尾）。
  WorldbookDraft upsertEntry(WorldEntry entry) {
    final next = <WorldEntry>[];
    var replaced = false;
    for (final e in entries) {
      if (e.id == entry.id) {
        next.add(entry);
        replaced = true;
      } else {
        next.add(e);
      }
    }
    if (!replaced) {
      next.add(entry);
    }
    return WorldbookDraft(
      name: name,
      description: description,
      entries: next,
    );
  }

  WorldbookDraft removeEntry(String id) => WorldbookDraft(
        name: name,
        description: description,
        entries: [...entries.where((e) => e.id != id)],
      );

  /// 更新书级元信息（null 表示保持原值）。
  WorldbookDraft withMeta({String? name, String? description}) =>
      WorldbookDraft(
        name: name ?? this.name,
        description: description ?? this.description,
        entries: entries,
      );
}

/// 会话级草稿状态：kind 决定持有哪种草稿，`hasConversation` 供退出拦截，
/// `finalized` 由 finalize_draft 工具置位（可再改，非终止）。
class DraftState {
  const DraftState({
    required this.kind,
    this.hasConversation = false,
    this.finalized = false,
  })  : card = null,
        book = null;

  const DraftState._card({
    required this.card,
    this.hasConversation = false,
    this.finalized = false,
  })  : kind = DraftKind.characterCard,
        book = null;

  const DraftState._book({
    required this.book,
    this.hasConversation = false,
    this.finalized = false,
  })  : kind = DraftKind.worldbook,
        card = null;

  /// 空草稿起步（卡模式给空卡，书模式给空书）。
  factory DraftState.empty(DraftKind kind) => switch (kind) {
        DraftKind.characterCard => const DraftState._card(card: CardDraft()),
        DraftKind.worldbook => const DraftState._book(book: WorldbookDraft()),
      };

  final DraftKind kind;
  final CardDraft? card;
  final WorldbookDraft? book;
  final bool hasConversation;
  final bool finalized;

  /// 当前草稿是否已动笔（卡/书各自口径）。
  bool get isDirty => switch (kind) {
        DraftKind.characterCard => card?.isDirty ?? false,
        DraftKind.worldbook => book?.isDirty ?? false,
      };

  DraftState withCard(CardDraft value) => DraftState._card(
        card: value,
        hasConversation: hasConversation,
        finalized: finalized,
      );

  DraftState withBook(WorldbookDraft value) => DraftState._book(
        book: value,
        hasConversation: hasConversation,
        finalized: finalized,
      );

  DraftState withConversation() => switch (kind) {
        DraftKind.characterCard => DraftState._card(
            card: card,
            hasConversation: true,
            finalized: finalized,
          ),
        DraftKind.worldbook => DraftState._book(
            book: book,
            hasConversation: true,
            finalized: finalized,
          ),
      };

  DraftState withFinalized({required bool value}) => switch (kind) {
        DraftKind.characterCard => DraftState._card(
            card: card,
            hasConversation: hasConversation,
            finalized: value,
          ),
        DraftKind.worldbook => DraftState._book(
            book: book,
            hasConversation: hasConversation,
            finalized: value,
          ),
      };
}
