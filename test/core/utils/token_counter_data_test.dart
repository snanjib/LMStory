import 'package:flutter_test/flutter_test.dart';
import 'package:tiktoken/src/ranks/cl100k_base.tiktoken.dart';
import 'package:tiktoken/tiktoken.dart';

/// vendor/tiktoken fork 的数据完整性回归：rank 表由上游的巨型 map 字面量
/// 改为常量字符串 + 运行时解析（fork 缘由见 vendor/tiktoken/VENDORED.md），
/// 解析结果必须与上游逐条等价，编码行为不变。
void main() {
  test('cl100k rank 表条目数与首尾条目（vendored fork）', () {
    expect(cl100kBase.length, 100104);
    expect(cl100kBase['IQ=='], 0);
    expect(cl100kBase['IENvbnZleW9y'], 100255);
  });

  test('getEncoding 编码行为不变', () {
    final encoding = getEncoding('cl100k_base');
    expect(encoding.encode('hello').length, 1);
    expect(encoding.encode('hello world').length, 2);
    expect(encoding.encode(''), isEmpty);
  });
}
