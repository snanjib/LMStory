import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/secret_redactor.dart';

void main() {
  test('diagnostics redact SDK socket addresses and keep the error fields', () {
    final connection = SocketException(
      'Connection refused',
      osError: const OSError('Connection refused', 61),
      address: InternetAddress('203.0.113.21'),
      port: 8443,
    );
    final noMessage = SocketException(
      '',
      address: InternetAddress('2001:db8::a'),
    );
    final output = redactDiagnosticText(
      'HTTP retry elapsed=40ms | $connection | second=$noMessage\n'
      'Ordinary text: address = meeting room',
    );
    expect(
      output,
      'HTTP retry elapsed=40ms | SocketException: Connection refused '
      '(OS Error: Connection refused, errno = 61), address = <host>, '
      'port = 8443 | second=SocketException, address = <host>\n'
      'Ordinary text: address = meeting room',
    );
    expect(redactDiagnosticText(output), output);
  });

  test('diagnostic redaction preserves protocol, timing and ordinary text', () {
    const endpoint = 'raw:https://lab-user:lab-pass@gateway.invalid/private/v1';
    const input = 'HTTP 429 POST $endpoint?project=fixture, elapsed=90ms\n'
        'SocketException: Failed host lookup: "other-gateway.invalid"\n'
        r'{"endpoint":"https:\/\/escaped.invalid\/stream?tenant=synthetic",'
        '"X-Goog-API-Key":"quoted key with spaces","stage":"retry"}'
        '\n{Authorization: [Bearer old-list-secret], X-API-Key: plain-token}'
        '\n他推开院门，雨还在下。';
    const expected = 'HTTP 429 POST https://<endpoint>, elapsed=90ms\n'
        'SocketException: Failed host lookup: <host>\n'
        '{"endpoint":"https://<endpoint>","X-Goog-API-Key":"***","stage":"retry"}'
        '\n{Authorization: ***, X-API-Key: ***}'
        '\n他推开院门，雨还在下。';
    expect(redactDiagnosticText(input), expected);
    expect(redactDiagnosticText(expected), expected);
  });

  group('redactSecrets', () {
    test('URL 内嵌凭据被脱敏', () {
      expect(
        redactSecrets('https://user:secret@api.test.com/v1/chat'),
        'https://***@api.test.com/v1/chat',
      );
    });

    test('Authorization 头（含 Bearer）被脱敏', () {
      expect(
        redactSecrets('Authorization: Bearer sk-abc123XYZ'),
        'Authorization: ***',
      );
      expect(
        redactSecrets('authorization=Bearer abc.def-123'),
        'authorization=***',
      );
    });

    test('api_key / access_token 等键值被脱敏，键名保留', () {
      expect(redactSecrets('api_key: sk-abcdefghij'), 'api_key: ***');
      expect(redactSecrets('apiKey=sk-abcdefghij'), 'apiKey=***');
      expect(redactSecrets('access_token: xyz123abc'), 'access_token: ***');
      expect(redactSecrets('token: ABCdef123456'), 'token: ***');
    });

    test('裸 token 前缀被脱敏', () {
      expect(
        redactSecrets('failed with sk-1234567890abcdef'),
        'failed with ***',
      );
      expect(
        redactSecrets('AIzaSyABCDEFGHIJKLMNOP'),
        '***',
      );
    });

    test('普通文本/中文正文不受影响', () {
      const text = '导演执行失败：模型输出被长度上限截断（finish_reason=length，输出上限 4096）';
      expect(redactSecrets(text), text);
      expect(redactSecrets('他推开院门，雨还在下。'), '他推开院门，雨还在下。');
    });
  });
}
