import 'dart:async';

/// SSE 底层解析器：协议无关的 SSE 事件块切分器
///
/// 职责：
/// - 接收原始字符串流（可能跨 chunk 切分）
/// - 行尾归一化：CRLF/CR → LF（Gemini `streamGenerateContent?alt=sse`
///   真机以 `\r\n\r\n` 分隔事件，Google 官方 SDK 亦按 CRLF 兼容切分）
/// - 按双换行 `\n\n` 切分为独立 SSE 事件块
/// - 提取每个块的 `event:` 和 `data:` 字段（多行 data 用 `\n` 拼接）
/// - 忽略 SSE 注释行（以 `:` 开头，如 DeepSeek 的 `: keep-alive`）
///
/// 输出 `({String? event, String data})` 元组流，供各协议层解析器消费。
///
/// 设计依据：DOC-12 §6.1。
class RawSseChunkParser {
  final StringBuffer _buffer = StringBuffer();

  /// 解析原始 SSE 流，输出 (event, data) 元组
  ///
  /// 实例可复用：每次调用 [parse] 会重置内部缓冲区。
  Stream<({String? event, String data})> parse(
    Stream<String> rawStream,
  ) async* {
    _buffer.clear();
    await for (final chunk in rawStream) {
      _buffer.write(chunk);

      var content = _buffer.toString();
      // 缓冲区末尾的孤立 \r 扣留一轮：它可能与下一 chunk 开头的 \n 组成
      // \r\n，提前折算成 \n 会制造假事件边界（\n\n）把一个事件劈成两个。
      var pendingCr = '';
      if (content.endsWith('\r')) {
        pendingCr = content.substring(content.length - 1);
        content = content.substring(0, content.length - 1);
      }
      content = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      // 按双换行切分事件块
      while (content.contains('\n\n')) {
        final idx = content.indexOf('\n\n');
        final block = content.substring(0, idx);
        content = content.substring(idx + 2);

        final parsed = _parseBlock(block);
        if (parsed != null) {
          yield parsed;
        }
      }
      _buffer
        ..clear()
        ..write(content)
        ..write(pendingCr);
    }

    // 处理缓冲区中可能残留的最后一个块（无 \n\n 结尾）
    final remaining =
        _buffer.toString().replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (remaining.trim().isNotEmpty) {
      final parsed = _parseBlock(remaining);
      if (parsed != null) {
        yield parsed;
      }
    }
    _buffer.clear();
  }

  /// 解析单个 SSE 事件块
  ///
  /// 返回 (event, data) 元组；注释块或无 data 的块返回 null。
  static ({String? event, String data})? _parseBlock(String block) {
    String? event;
    final dataParts = <String>[];

    for (final line in block.split('\n')) {
      // SSE 注释行（以 : 开头），忽略
      if (line.startsWith(':')) continue;

      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        // data: 后的内容保留原始字符（仅去除前导空格，符合 SSE 规范）
        dataParts.add(line.substring(5).trim());
      }
      // 忽略其他字段（id:、retry: 等）
    }

    if (dataParts.isEmpty) return null;

    return (event: event, data: dataParts.join('\n'));
  }
}
