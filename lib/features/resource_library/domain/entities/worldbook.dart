import 'package:meta/meta.dart';

/// 世界书资源（DOC-15 §9.1）
///
/// 资源库中的全局世界书资源，存完整原始 JSON（无损）。
/// 词条存 rawJson 内，按需解析。
@immutable
class Worldbook {
  const Worldbook({
    required this.bookId,
    required this.name,
    required this.rawJson,
    required this.createdAt,
    required this.updatedAt,
  });

  final String bookId;
  final String name;
  final String rawJson;
  final DateTime createdAt;
  final DateTime updatedAt;
}
