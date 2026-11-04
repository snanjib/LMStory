import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/secret_redactor.dart';

void main() {
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
