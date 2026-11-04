import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_schema.dart';

/// Gemini function schema 裁剪单测：只保留 Schema proto 字段，
/// 递归剥离 additionalProperties 等 JSON Schema 关键字。
void main() {
  group('toGeminiSchema', () {
    test('剥离顶层 additionalProperties', () {
      final input = <String, dynamic>{
        'type': 'object',
        'properties': {
          'characters': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['characters'],
        'additionalProperties': false,
      };

      final result = toGeminiSchema(input);

      expect(result.containsKey('additionalProperties'), isFalse);
      expect(result['type'], 'object');
      expect(result['required'], ['characters']);
    });

    test('递归剥离 properties / items / anyOf 内的 additionalProperties', () {
      final input = <String, dynamic>{
        'type': 'object',
        'properties': {
          'nested': {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
            'additionalProperties': false,
          },
          'list': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
              },
              'additionalProperties': false,
            },
          },
          'either': {
            'anyOf': [
              {
                'type': 'object',
                'additionalProperties': false,
              },
              {'type': 'string'},
            ],
          },
        },
        'additionalProperties': false,
      };

      final result = toGeminiSchema(input);

      expect(jsonEncode(result), isNot(contains('additionalProperties')));
    });

    test('白名单字段（含 enum/minimum/maximum/items）原样保留', () {
      final input = <String, dynamic>{
        'type': 'object',
        'description': 'desc',
        'properties': {
          'count': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 5,
            'enum': [1, 2, 3],
            'description': '数量',
          },
        },
        'required': ['count'],
      };

      expect(toGeminiSchema(input), {
        'type': 'object',
        'description': 'desc',
        'properties': {
          'count': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 5,
            'enum': [1, 2, 3],
            'description': '数量',
          },
        },
        'required': ['count'],
      });
    });

    test(r'丢弃非白名单键（$schema / $ref / allOf / oneOf / const）', () {
      final input = <String, dynamic>{
        'type': 'object',
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        r'$ref': r'#/$defs/Foo',
        'allOf': [
          {'type': 'object'},
        ],
        'oneOf': [
          {'type': 'string'},
        ],
        'const': 'fixed',
      };

      expect(toGeminiSchema(input), {'type': 'object'});
    });

    test('不修改入参（工具定义是共享 const）', () {
      final input = <String, dynamic>{
        'type': 'object',
        'additionalProperties': false,
      };

      toGeminiSchema(input);

      expect(input['additionalProperties'], false);
    });
  });
}
