/// resource_ai 的 agent 工具三件套（update_draft / finalize_draft / read_skill）。
///
/// 工具无状态：每次 invoke 经 `readState` 取当前草稿，纯函数变换后经
/// `onDraftChanged` 回写（控制器负责替换状态）。所有参数错误走失败信封，
/// 不抛异常（弱模型容错，错误文本须可操作）。
library;

import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';

const _cardActions = {'set_card_field', 'set_card_tags'};
const _bookActions = {
  'set_book_meta',
  'add_book_entry',
  'update_book_entry',
  'remove_book_entry',
};

String _kindLabel(DraftKind kind) =>
    kind == DraftKind.characterCard ? '角色卡' : '世界书';

/// 草稿更新工具：按会话种类分发到卡/书的字段级变换。
class UpdateDraftTool implements AgentTool {
  UpdateDraftTool({
    required this.kind,
    required this.readState,
    required this.onDraftChanged,
  });

  final DraftKind kind;
  final DraftState Function() readState;
  final void Function(DraftState state) onDraftChanged;

  @override
  String get name => 'update_draft';

  @override
  AgentToolPermission get permission => AgentToolPermission.write;

  @override
  String get description {
    final label = _kindLabel(kind);
    final actions = kind == DraftKind.characterCard
        ? _cardActions.join('、')
        : _bookActions.join('、');
    return '更新当前$label草稿。当前会话为$label模式，只可用 $actions action。每次只改一处；写完全部内容后调用 finalize_draft。';
  }

  @override
  Map<String, dynamic> buildParametersSchema() {
    final entryShape = {
      'keys': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'keysecondary': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'comment': {'type': 'string'},
      'content': {'type': 'string'},
      'constant': {'type': 'boolean'},
      'selective': {'type': 'boolean'},
      'order': {'type': 'integer'},
      'enabled': {'type': 'boolean'},
      'position': {
        'type': 'string',
        'enum': ['before_char', 'after_char'],
      },
      'extensions': {'type': 'object'},
    };
    return {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [..._cardActions, ..._bookActions],
          'description': '当前会话为${_kindLabel(kind)}模式，'
              '只可用${kind == DraftKind.characterCard ? _cardActions.join('、') : _bookActions.join('、')}',
        },
        'field': {
          'type': 'string',
          'enum': [for (final f in CardField.values) f.jsonName],
          'description': 'set_card_field 专用：卡字段名',
        },
        'value': {'type': 'string', 'description': 'set_card_field 专用：字段全文'},
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'set_card_tags 专用：完整标签列表（整表覆盖）',
        },
        'name': {'type': 'string', 'description': 'set_book_meta 专用：书名'},
        'description': {
          'type': 'string',
          'description': 'set_book_meta 专用：书描述',
        },
        'entry': {
          'type': 'object',
          'description': 'add_book_entry 专用：完整词条',
          'properties': entryShape,
        },
        'id': {
          'type': 'string',
          'description': 'update/remove_book_entry 专用：条目 id',
        },
        'patch': {
          'type': 'object',
          'description': 'update_book_entry 专用：要覆盖的字段子集',
          'properties': entryShape,
        },
      },
      'required': ['action'],
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final action = arguments['action']?.toString() ?? '';
    final state = readState();

    AgentToolResult bad(String why) => AgentToolResult.failure(
          title: '草稿未更新',
          output: why,
        );

    if (kind == DraftKind.characterCard) {
      if (!_cardActions.contains(action)) {
        return bad(_wrongActionText(action, _cardActions));
      }
      return _invokeCard(state, action, arguments);
    }
    if (!_bookActions.contains(action)) {
      return bad(_wrongActionText(action, _bookActions));
    }
    return _invokeBook(state, action, arguments);
  }

  String _wrongActionText(String action, Set<String> allowed) {
    final label = _kindLabel(kind);
    final list = allowed.join('、');
    if (action.isEmpty) {
      return '缺少 action 参数。当前会话为$label模式，只可用：$list。';
    }
    return 'action「$action」不可用：当前会话为$label模式，只可用：$list。';
  }

  AgentToolResult _invokeCard(
    DraftState state,
    String action,
    Map<String, dynamic> arguments,
  ) {
    final card = state.card;
    if (card == null) {
      return AgentToolResult.failure(
        title: '草稿未更新',
        output: '当前会话不是角色卡模式。',
      );
    }
    switch (action) {
      case 'set_card_field':
        final rawField = arguments['field']?.toString() ?? '';
        CardField? field;
        for (final f in CardField.values) {
          if (f.jsonName == rawField) {
            field = f;
          }
        }
        if (field == null) {
          final names =
              [for (final f in CardField.values) f.jsonName].join('、');
          return AgentToolResult.failure(
            title: '草稿未更新',
            output: '未知字段「$rawField」。合法字段：$names。',
          );
        }
        if (!arguments.containsKey('value') || arguments['value'] is! String) {
          return AgentToolResult.failure(
            title: '草稿未更新',
            output: 'set_card_field 需要字符串参数 value（字段${field.jsonName}的完整新内容）。',
          );
        }
        final next = card.withField(field, arguments['value'] as String);
        onDraftChanged(state.withCard(next));
        return AgentToolResult.success(
          title: '已更新 ${field.jsonName}',
          output:
              '字段 ${field.jsonName} 已写入（${(arguments['value'] as String).length} 字）。',
        );
      case 'set_card_tags':
        final raw = arguments['tags'];
        if (raw is! List) {
          return AgentToolResult.failure(
            title: '草稿未更新',
            output: 'set_card_tags 需要字符串数组参数 tags（整表覆盖）。',
          );
        }
        final tags = [for (final t in raw) t.toString()];
        onDraftChanged(state.withCard(card.withTags(tags)));
        return AgentToolResult.success(
          title: '已更新标签',
          output: '标签已写入：${tags.join('、')}。',
        );
    }
    return AgentToolResult.failure(
      title: '草稿未更新',
      output: _wrongActionText(action, _cardActions),
    );
  }

  AgentToolResult _invokeBook(
    DraftState state,
    String action,
    Map<String, dynamic> arguments,
  ) {
    final book = state.book;
    if (book == null) {
      return AgentToolResult.failure(
        title: '草稿未更新',
        output: '当前会话不是世界书模式。',
      );
    }
    switch (action) {
      case 'set_book_meta':
        final name = arguments['name'];
        final description = arguments['description'];
        if (name == null && description == null) {
          return AgentToolResult.failure(
            title: '草稿未更新',
            output: 'set_book_meta 至少需要 name 或 description 之一。',
          );
        }
        final next = book.withMeta(
          name: name is String ? name : null,
          description: description is String ? description : null,
        );
        onDraftChanged(state.withBook(next));
        return AgentToolResult.success(
          title: '已更新书信息',
          output: '书级元信息已写入。',
        );
      case 'add_book_entry':
        final raw = arguments['entry'];
        if (raw is! Map) {
          return AgentToolResult.failure(
            title: '草稿未更新',
            output: 'add_book_entry 需要 entry 对象（keys/content 必填，id 由系统分配勿传）。',
          );
        }
        final entry = _entryFromArgs(Map<String, dynamic>.from(raw));
        final err = _validateEntryShape(entry, requireContent: true);
        if (err != null) {
          return AgentToolResult.failure(title: '草稿未更新', output: err);
        }
        final id = book.nextEntryId();
        final next = book.upsertEntry(
          WorldEntry(
            id: id,
            keys: entry.keys,
            secondaryKeys: entry.secondaryKeys,
            comment: entry.comment,
            content: entry.content,
            constant: entry.constant,
            selective: entry.selective,
            insertionOrder: entry.insertionOrder,
            enabled: entry.enabled,
            positionBeforeChar: entry.positionBeforeChar,
            extensions: entry.extensions,
          ),
        );
        onDraftChanged(state.withBook(next));
        return AgentToolResult.success(
          title: '已加词条 $id',
          output: '词条已加入草稿（id=$id，共 ${next.entries.length} 条）。',
        );
      case 'update_book_entry':
        final id = arguments['id']?.toString() ?? '';
        final raw = arguments['patch'];
        final existing = book.entries.where((e) => e.id == id).firstOrNull;
        if (existing == null) {
          return AgentToolResult.failure(
            title: '草稿未更新',
            output: '条目「$id」不存在。当前条目 id：'
                '${book.entries.map((e) => e.id).join('、')}',
          );
        }
        if (raw is! Map) {
          return AgentToolResult.failure(
            title: '草稿未更新',
            output: 'update_book_entry 需要字段子集对象 patch（只覆盖给出的字段）。',
          );
        }
        final next = book.upsertEntry(
          _applyPatch(existing, Map<String, dynamic>.from(raw)),
        );
        onDraftChanged(state.withBook(next));
        return AgentToolResult.success(
          title: '已改词条 $id',
          output: '词条「$id」已更新。',
        );
      case 'remove_book_entry':
        final id = arguments['id']?.toString() ?? '';
        if (book.entries.where((e) => e.id == id).isEmpty) {
          return AgentToolResult.failure(
            title: '草稿未更新',
            output: '条目「$id」不存在。当前条目 id：'
                '${book.entries.map((e) => e.id).join('、')}',
          );
        }
        onDraftChanged(state.withBook(book.removeEntry(id)));
        return AgentToolResult.success(
          title: '已删词条 $id',
          output: '词条「$id」已移除。',
        );
    }
    return AgentToolResult.failure(
      title: '草稿未更新',
      output: _wrongActionText(action, _bookActions),
    );
  }
}

/// 标记草稿定稿（非终止：模型与用户仍可继续修改）。
class FinalizeDraftTool implements AgentTool {
  FinalizeDraftTool({required this.readState, required this.onDraftChanged});

  final DraftState Function() readState;
  final void Function(DraftState state) onDraftChanged;

  @override
  String get name => 'finalize_draft';

  @override
  String get description => '声明当前草稿已完成，可以交给用户确认保存。定稿后仍可继续用 '
      'update_draft 修改（用户提出新要求时）。';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() {
    return const {
      'type': 'object',
      'properties': <String, dynamic>{},
    };
  }

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final state = readState();
    onDraftChanged(state.withFinalized(value: true));
    return AgentToolResult.success(
      title: '草稿已定稿',
      output: '草稿已标记为完成。请在回复中向用户总结本次草稿的内容要点。',
    );
  }
}

/// 读取建卡规范 skill（advanced 侧 ReadSkillTool 的等价物——core/agent 无
/// 共享实现，本工具只依赖注入的两个回调，不 import advanced）。
class ResourceAiReadSkillTool implements AgentTool {
  ResourceAiReadSkillTool({
    required this.skillNames,
    required this.loadSkillBody,
  });

  final List<String> skillNames;
  final Future<String?> Function(String name) loadSkillBody;

  @override
  String get name => 'read_skill';

  @override
  String get description => '读取一份建卡写作规范的完整正文（目录里只有名字与简介）。动笔前必读'
      '与当前任务相关的规范。可用：${skillNames.isEmpty ? '（无）' : skillNames.join('、')}';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '规范名（见目录）'},
        },
        'required': ['name'],
      };

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final name = arguments['name']?.toString() ?? '';
    if (name.isEmpty) {
      return AgentToolResult.failure(
        title: '缺少规范名',
        output: 'name 不能为空。可用规范：${skillNames.join('、')}。',
      );
    }
    final body = await loadSkillBody(name);
    if (body == null || body.isEmpty) {
      return AgentToolResult.failure(
        title: '没有这份规范',
        output: '规范「$name」不存在。可用规范：${skillNames.join('、')}。',
      );
    }
    return AgentToolResult.success(
      title: '已读取 $name',
      output: body,
      metadata: {'name': name, 'bodyLength': body.length},
      outputSchema: {'name': 'string', 'bodyLength': 'int'},
    );
  }
}

// ==================== 条目参数解析（纯函数）====================

/// 模型输出的标量常带引号/数值以
/// 字符串到达（"true"/"5"）——裸 `as bool?`/`as num?` 会抛 TypeError
/// 落到泛化错误信封，模型拿不到「哪个字段什么类型」的可修复信息。
/// 宽容转换失败回默认值，由 [_validateEntryShape] 的字段级校验兜底。
bool _coerceBool(Object? v, bool fallback) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    switch (v.trim().toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
    }
  }
  return fallback;
}

int _coerceInt(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    final parsed = int.tryParse(v.trim());
    if (parsed != null) return parsed;
  }
  return fallback;
}

List<String> _coerceStringList(Object? v) {
  if (v is List) return [for (final k in v) k.toString()];
  if (v is String && v.trim().isNotEmpty) return [v.trim()];
  return const [];
}

WorldEntry _entryFromArgs(Map<String, dynamic> raw) {
  final position = raw['position']?.toString();
  return WorldEntry(
    id: raw['id']?.toString() ?? '',
    keys: _coerceStringList(raw['keys']),
    secondaryKeys: _coerceStringList(raw['keysecondary']),
    comment: raw['comment']?.toString() ?? '',
    content: raw['content']?.toString() ?? '',
    constant: _coerceBool(raw['constant'], false),
    selective: _coerceBool(raw['selective'], false),
    insertionOrder: _coerceInt(raw['order'], 100),
    enabled: _coerceBool(raw['enabled'], true),
    positionBeforeChar: position != 'after_char',
    extensions: raw['extensions'] is Map
        ? Map<String, dynamic>.from(raw['extensions'] as Map)
        : const {},
  );
}

String? _validateEntryShape(WorldEntry e, {required bool requireContent}) {
  if (requireContent && e.content.isEmpty) {
    return '词条缺少 content（触发后注入上下文的正文，必须自足）。';
  }
  if (e.keys.isEmpty) {
    return '词条缺少 keys（触发关键词数组）。常驻条目（constant=true）也建议填写以便用户辨认。';
  }
  return null;
}

WorldEntry _applyPatch(WorldEntry existing, Map<String, dynamic> patch) {
  final parsed = _entryFromArgs({
    'keys': patch.containsKey('keys') ? patch['keys'] : existing.keys,
    'keysecondary': patch.containsKey('keysecondary')
        ? patch['keysecondary']
        : existing.secondaryKeys,
    'comment':
        patch.containsKey('comment') ? patch['comment'] : existing.comment,
    'content':
        patch.containsKey('content') ? patch['content'] : existing.content,
    'constant':
        patch.containsKey('constant') ? patch['constant'] : existing.constant,
    'selective': patch.containsKey('selective')
        ? patch['selective']
        : existing.selective,
    'order':
        patch.containsKey('order') ? patch['order'] : existing.insertionOrder,
    'enabled':
        patch.containsKey('enabled') ? patch['enabled'] : existing.enabled,
    'position': patch.containsKey('position')
        ? patch['position']
        : (existing.positionBeforeChar ? 'before_char' : 'after_char'),
    'extensions': patch['extensions'] is Map
        ? <String, dynamic>{
            ...existing.extensions,
            ...Map<String, dynamic>.from(patch['extensions'] as Map),
          }
        : existing.extensions,
  });
  return WorldEntry(
    id: existing.id,
    keys: parsed.keys,
    secondaryKeys: parsed.secondaryKeys,
    comment: parsed.comment,
    content: parsed.content,
    constant: parsed.constant,
    selective: parsed.selective,
    insertionOrder: parsed.insertionOrder,
    enabled: parsed.enabled,
    positionBeforeChar: parsed.positionBeforeChar,
    extensions: parsed.extensions,
  );
}
