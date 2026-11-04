import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 测试侧零依赖 PNG 写出（8-bit / RGBA / 无交错 / filter=0）。
///
/// 为什么需要它：本机环境里 `ui.Image.toByteData(format: png)` 不返回
/// （现象：调用后永久挂住，`--timeout` 也不触发，属引擎侧编码器卡死）。
/// 因此截图夹具统一走 `rawStraightRgba` 取原始像素，PNG 容器在 Dart 侧拼装。
/// 参考实现见 `test/core/theme/q2_baseline_shots_test.dart` 的内联版本；
/// 本文件是抽出来的共享版本，供需要落图的用例复用。
///
/// 用法（**必须在 `tester.binding.runAsync` 内调用**，否则真实 dart:io
/// Future 拿不到事件循环调度会永久挂起）：
/// ```dart
/// await tester.binding.runAsync(() async {
///   final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
///   writePngSync('shots/a.png', image.width, image.height, data!.buffer.asUint8List());
/// });
/// ```
void writePngSync(String path, int width, int height, Uint8List rgba) {
  final file = File(path);
  final dir = file.parent;
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  file.writeAsBytesSync(encodePng(width, height, rgba), flush: true);
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) == 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return c ^ 0xFFFFFFFF;
}

List<int> _u32(int value) => <int>[
      (value >>> 24) & 0xFF,
      (value >>> 16) & 0xFF,
      (value >>> 8) & 0xFF,
      value & 0xFF,
    ];

void _addChunk(BytesBuilder out, String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  out
    ..add(_u32(data.length))
    ..add(typeBytes)
    ..add(data)
    ..add(_u32(_crc32(typeBytes + data)));
}

Uint8List encodePng(int width, int height, Uint8List rgba) {
  final raw = BytesBuilder();
  final stride = width * 4;
  for (var y = 0; y < height; y++) {
    raw
      ..addByte(0) // scanline filter = None
      ..add(Uint8List.sublistView(rgba, y * stride, (y + 1) * stride));
  }
  final idat = ZLibCodec().encoder.convert(raw.takeBytes());

  final ihdr = BytesBuilder()
    ..add(_u32(width))
    ..add(_u32(height))
    ..addByte(8) // bit depth
    ..addByte(6) // colour type: truecolour + alpha
    ..addByte(0) // compression
    ..addByte(0) // filter method
    ..addByte(0); // interlace

  final out = BytesBuilder()..add(const <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  _addChunk(out, 'IHDR', ihdr.takeBytes());
  _addChunk(out, 'IDAT', idat);
  _addChunk(out, 'IEND', const <int>[]);
  return out.takeBytes();
}
