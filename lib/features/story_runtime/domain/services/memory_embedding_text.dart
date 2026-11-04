import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';

/// 记忆向量化文本构造（故事/导演共享实现，导演设置  提取）。
///
/// 5W1E 字段逐行拼接；全空时回落 [ExperientialMemory.displayText]。
String buildMemoryEmbeddingText(ExperientialMemory memory) {
  final lines = <String>[];
  if (memory.summary != null && memory.summary!.isNotEmpty) {
    lines.add(memory.summary!);
  }
  if (memory.when != null && memory.when!.isNotEmpty) {
    lines.add('时间: ${memory.when}');
  }
  if (memory.where != null && memory.where!.isNotEmpty) {
    lines.add('地点: ${memory.where}');
  }
  if (memory.who != null && memory.who!.isNotEmpty) {
    lines.add('人物: ${memory.who}');
  }
  if (memory.what != null && memory.what!.isNotEmpty) {
    lines.add('事件: ${memory.what}');
  }
  if (memory.significance != null && memory.significance!.isNotEmpty) {
    lines.add('意义: ${memory.significance}');
  }
  if (memory.extra != null && memory.extra!.isNotEmpty) {
    lines.add('补充: ${memory.extra}');
  }
  if (lines.isEmpty) {
    return memory.displayText;
  }
  return lines.join('\n');
}
