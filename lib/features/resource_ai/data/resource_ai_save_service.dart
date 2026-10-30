/// resource_ai 落库服务：草稿 → 资源库（新建/另存/覆盖三路径）。
library;

import 'dart:convert';

import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/draft_json_builder.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';

class ResourceAiSaveService {
  ResourceAiSaveService({required ResourceLibraryRepository repository})
      : _repository = repository;

  final ResourceLibraryRepository _repository;

  /// 保存角色卡草稿，返回 cardId。
  ///
  /// - [existingCardId] 为 null：新建/另存——buildCardJson 全新构建。
  /// - 非空：覆盖保存——patch [originalRawJson]（编辑会话开始的留底）后
  ///   update，未知字段原样保留，id 不变。
  Future<String> saveCharacterCard({
    required CardDraft draft,
    required String defaultName,
    String? existingCardId,
    String? originalRawJson,
  }) async {
    final name = draft.value(CardField.name).trim().isEmpty
        ? defaultName
        : draft.value(CardField.name).trim();
    if (existingCardId == null) {
      final created = await _repository.createCharacterCard(
        name: name,
        rawJson: jsonEncode(buildCardJson(draft)),
        sourceFormat: 'v2',
      );
      return created.cardId;
    }
    if (originalRawJson == null) {
      throw ArgumentError('覆盖保存必须提供 originalRawJson（编辑留底）');
    }
    final patched = patchCardJson(
      Map<String, dynamic>.from(jsonDecode(originalRawJson) as Map),
      draft,
    );
    await _repository.updateCharacterCard(
      cardId: existingCardId,
      name: name,
      rawJson: jsonEncode(patched),
    );
    return existingCardId;
  }

  /// 保存世界书草稿，返回 bookId（三路径同 [saveCharacterCard]）。
  Future<String> saveWorldbook({
    required WorldbookDraft draft,
    required String defaultName,
    String? existingBookId,
    String? originalRawJson,
  }) async {
    final name = draft.name.trim().isEmpty ? defaultName : draft.name.trim();
    if (existingBookId == null) {
      final created = await _repository.createWorldbook(
        name: name,
        rawJson: jsonEncode(buildWorldbookJson(draft)),
      );
      return created.bookId;
    }
    if (originalRawJson == null) {
      throw ArgumentError('覆盖保存必须提供 originalRawJson（编辑留底）');
    }
    final patched = patchWorldbookJson(
      Map<String, dynamic>.from(jsonDecode(originalRawJson) as Map),
      draft,
    );
    await _repository.updateWorldbook(
      bookId: existingBookId,
      name: name,
      rawJson: jsonEncode(patched),
    );
    return existingBookId;
  }
}
