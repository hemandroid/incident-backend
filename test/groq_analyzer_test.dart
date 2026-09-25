import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:incident_backend/src/contracts.dart';
import 'package:incident_backend/src/groq_analyzer.dart';
import 'package:incident_backend/src/source_reader.dart';
import 'package:test/test.dart';

class _FakeSourceFileSystem implements SourceFileSystem {
  _FakeSourceFileSystem(this.files);

  final Map<String, List<String>> files;

  @override
  List<String>? readLines(String path) => files[path];
}

Incident _incident({Map<String, dynamic> context = const {}}) => Incident(
      id: 'inc-1',
      capturedAt: DateTime.utc(2026, 1, 1),
      source: IncidentSource.flutterError,
      error: 'RangeError: index out of range',
      stackTrace: 'unsymbolicated',
      appVersion: '1.2.3',
      commitSha: 'abc123',
      platform: 'android',
      errorContext: 'building CartScreen',
      context: context,
    );

GroqAnalyzer _analyzer(
  http.Client client, {
  Duration timeout = const Duration(seconds: 5),
  String? apiVersion,
  SourceReader? sourceReader,
  Log? log,
}) =>
    GroqAnalyzer(
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      authHeaderName: 'Authorization',
      authHeaderValue: 'Bearer test-secret-key',
      model: 'qwen/qwen3.8-27b',
      apiVersion: apiVersion,
      timeout: timeout,
      client: client,
      log: log ?? (_) {},
      sourceReader: sourceReader,
    );

http.Response _chatResponse(String content, {int statusCode = 200}) => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': content},
          },
        ],
      }),
      statusCode,
    );

const _validJson = '''
{
  "title": "Cart crashes on checkout with empty cart",
  "root_cause": "CartScreen reads items[0] before checking the list is non-empty.",
  "repro_steps": ["Open the app", "Remove all cart items", "Tap checkout"],
  "severity": "major",
  "suggested_fix": "Guard the checkout button on items.isEmpty."
}
''';

void main() {
  group('GroqAnalyzer.analyse', () {
    test('parses a clean JSON response', () async {
      final client = MockClient((request) async => _chatResponse(_validJson));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.title, 'Cart crashes on checkout with empty cart');
      expect(result.reproSteps, [
        'Open the app',
        'Remove all cart items',
        'Tap checkout',
      ]);
      expect(result.severity, 'major');
      expect(result.suggestedFix, contains('items.isEmpty'));
    });

    test('a bare string root_cause (older model shape) wraps into a single-element list',
        () async {
      final client = MockClient((request) async => _chatResponse(_validJson));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.rootCause, [
        'CartScreen reads items[0] before checking the list is non-empty.',
      ]);
    });

    test('an array root_cause parses into an ordered multi-element list, dropping blanks',
        () async {
      const arrayCause = '''
      {
        "title": "Cart crashes on checkout with empty cart",
        "root_cause": ["Cart was opened with zero items", "   ", "checkout then read items[0] without checking length"],
        "repro_steps": ["Open the app"],
        "severity": "major"
      }
      ''';
      final client = MockClient((request) async => _chatResponse(arrayCause));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.rootCause, [
        'Cart was opened with zero items',
        'checkout then read items[0] without checking length',
      ]);
    });

    test('parses JSON wrapped in ```json fences', () async {
      final client = MockClient((request) async => _chatResponse('```json\n$_validJson\n```'));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.title, 'Cart crashes on checkout with empty cart');
    });

    test('parses JSON preceded by leading prose', () async {
      final client = MockClient(
        (request) async => _chatResponse('Sure, here is the analysis:\n\n$_validJson'),
      );
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.severity, 'major');
    });

    test('a brace inside a string value does not break extraction', () async {
      const withBraceInString = '''
      Here you go:
      {
        "title": "Crash in reducer",
        "root_cause": "The reducer does `state = { ...state, x: 1 }` on a frozen object.",
        "repro_steps": ["Open settings", "Toggle dark mode"],
        "severity": "minor",
        "suggested_fix": "Clone before mutating."
      }
      ''';
      final client = MockClient((request) async => _chatResponse(withBraceInString));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.title, 'Crash in reducer');
    });

    test('malformed JSON returns null', () async {
      final client = MockClient((request) async => _chatResponse('{"title": "oops",'));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('a missing required field returns null', () async {
      const missingRootCause = '''
      {
        "title": "Something broke",
        "repro_steps": ["Open the app"],
        "severity": "minor"
      }
      ''';
      final client = MockClient((request) async => _chatResponse(missingRootCause));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('empty repro_steps keeps the analysis, minus the steps', () async {
      // Discarding a whole analysis over one absent field left half the
      // tickets in a six-failure run with no root cause at all.
      const emptySteps = '''
      {
        "title": "Something broke",
        "root_cause": "Unknown",
        "repro_steps": []
      }
      ''';
      final client = MockClient((request) async => _chatResponse(emptySteps));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.rootCause, ['Unknown']);
      expect(result.reproSteps, isEmpty);
    });

    test('a missing title is synthesised from the incident', () async {
      const noTitle = '{"root_cause": "products.first on an empty list"}';
      final client = MockClient((request) async => _chatResponse(noTitle));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      // `isNotEmpty` passed while the fallback was a literal '${...}' string
      // with escaped dollars — assert the real values reach the title.
      expect(result!.title, contains('RangeError'));
      expect(result.title, contains('android'));
      expect(result.title, isNot(contains(r'$')));
      expect(result.rootCause, ['products.first on an empty list']);
    });

    test('camelCase keys are accepted as readily as snake_case', () async {
      const camel = '''
      {
        "summary": "Empty catalogue crash",
        "rootCause": "first on an empty list",
        "reproSteps": ["open the catalogue"],
        "severity": "Major"
      }
      ''';
      final client = MockClient((request) async => _chatResponse(camel));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.title, 'Empty catalogue crash');
      expect(result.reproSteps, ['open the catalogue']);
      expect(result.severity, 'major', reason: 'severity is case-insensitive');
    });

    test('a missing root cause is still fatal — it is the whole point',
        () async {
      const noCause = '{"title": "Something broke", "repro_steps": ["tap"]}';
      final client = MockClient((request) async => _chatResponse(noCause));

      expect(await _analyzer(client).analyse(_incident(), 'trace'), isNull);
    });

    test('HTTP 429 returns null without throwing', () async {
      final client = MockClient((request) async => http.Response('rate limited', 429));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('HTTP 500 returns null without throwing', () async {
      final client = MockClient((request) async => http.Response('server error', 500));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('empty choices returns null', () async {
      final client = MockClient(
        (request) async => http.Response(jsonEncode({'choices': []}), 200),
      );
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('a slow model times out and returns null instead of hanging', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _chatResponse(_validJson);
      });
      final result = await _analyzer(client, timeout: const Duration(milliseconds: 20))
          .analyse(_incident(), 'trace');

      expect(result, isNull);
    });

    test('never throws even when the underlying client throws', () async {
      final client = MockClient((request) async => throw Exception('socket closed'));

      await expectLater(
        _analyzer(client).analyse(_incident(), 'trace'),
        completion(isNull),
      );
    });

    test('the screenshot field is never sent to the model', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      final screenshotPayload = base64Encode(List.filled(1000, 1));
      await _analyzer(client).analyse(
        _incident(context: {
          'routes': ['/home', '/cart'],
          'logs': ['tapped checkout'],
          'screenshot': screenshotPayload,
        }),
        'trace',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, isNot(contains('screenshot')));
      expect(content, isNot(contains(screenshotPayload)));
      expect(captured!.body, isNot(contains(screenshotPayload)));
      expect(content, contains('/home -> /cart'));
      expect(content, contains('tapped checkout'));
    });

    test('the api key is sent as the configured header and never logged or thrown', () async {
      final printed = <String>[];
      final client = MockClient(
        (request) async => throw Exception('unauthorized, saw key=Bearer test-secret-key'),
      );

      Analysis? result;
      await runZoned(
        () async {
          result = await _analyzer(client).analyse(_incident(), 'trace');
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            printed.add(line);
          },
        ),
      );

      expect(result, isNull);
      expect(printed, isEmpty);
      expect(printed.any((l) => l.contains('test-secret-key')), isFalse);
    });

    test('the real route/log collector shape (a Map wrapping history/entries) reaches the prompt',
        () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      await _analyzer(client).analyse(
        _incident(context: {
          'routes': {
            'history': [
              {'event': 'push', 'route': '/orders', 'at': '2026-09-21T11:35:00.000'},
              {'event': 'pop', 'route': '/orders', 'at': '2026-09-21T11:36:00.000'},
            ],
          },
          'logs': {
            'entries': [
              {'level': 'info', 'message': 'tapped checkout', 'at': '2026-09-21T11:35:30.000'},
            ],
          },
        }),
        'trace',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, contains('push /orders -> pop /orders'));
      expect(content, contains('[info] tapped checkout'));
    });

    test('an oversized breadcrumb log is clamped, not sent to the model whole',
        () async {
      // 20 short-looking entries off a big ring buffer can still carry a
      // huge message each; entry-count capping alone would not catch this.
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });
      final hugeMessage = 'x' * 5000;

      await _analyzer(client).analyse(
        _incident(context: {
          'logs': {
            'entries': [
              {'level': 'info', 'message': hugeMessage},
            ],
          },
        }),
        'trace',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, contains('...(truncated)'));
      expect(content.contains(hugeMessage), isFalse);
    });

    test('a bare List (synthetic test contexts) still reaches the prompt', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      await _analyzer(client).analyse(
        _incident(context: {
          'routes': ['/home', '/cart'],
          'logs': ['tapped checkout'],
        }),
        'trace',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, contains('/home -> /cart'));
      expect(content, contains('tapped checkout'));
    });

    test('a context shape that is neither the collector Map nor a bare List does not throw',
        () async {
      final client = MockClient((request) async => _chatResponse(_validJson));

      final result = await _analyzer(client).analyse(
        _incident(context: {
          'routes': 'unexpected-string',
          'logs': {'unexpected_key': 'nope'},
        }),
        'trace',
      );

      expect(result, isNotNull);
    });

    test('a source window reaches the prompt and its before/after come back',
        () async {
      http.Request? captured;
      const reply = '''
      {
        "title": "Duplicate order ids crash the list",
        "root_cause": ["Two orders share an id"],
        "repro_steps": ["Open /orders"],
        "severity": "major",
        "suggested_fix": "Handle multiple matches gracefully.",
        "code_before": "  final o = orders.singleWhere((x) => x.id == id);",
        "code_after": "  final o = orders.where((x) => x.id == id).firstOrNull;"
      }
      ''';
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(reply);
      });
      final reader = SourceReader(
        '/repo',
        fileSystem: _FakeSourceFileSystem({
          '/repo/lib/store/screens.dart': [
            for (var i = 1; i <= 20; i++)
              i == 12 ? '  final o = orders.singleWhere((x) => x.id == id);' : 'line $i',
          ],
        }),
      );

      final result = await _analyzer(client, sourceReader: reader).analyse(
        _incident(),
        '#0 ListBase.singleWhere (third_party/dart/sdk/lib/collection/list.dart:156:11)\n'
        '#1 _OrdersScreenState.build (/repo/lib/store/screens.dart:12:34)',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, contains('SOURCE AT THE CRASH SITE'));
      expect(content, contains('lib/store/screens.dart'));
      expect(content, contains('12 | '));
      expect(content, contains('"code_before"'));
      expect(content, contains('"code_after"'));

      expect(result!.codeBefore, contains('orders.singleWhere'));
      expect(result.codeAfter, contains('firstOrNull'));
      expect(result.suggestedFix, 'Handle multiple matches gracefully.');
    });

    test('with no source reader the prompt never asks for before/after code',
        () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      final result = await _analyzer(client).analyse(_incident(), 'trace');

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, isNot(contains('code_before')));
      expect(content, isNot(contains('SOURCE AT THE CRASH SITE')));
      expect(result!.codeBefore, isNull);
      expect(result.codeAfter, isNull);
    });

    test('an oversized code block is truncated, not passed through to Jira',
        () async {
      // Uncapped, a looping model's reply blows the ADF field limit, Jira
      // answers 400 and the incident gets no ticket at all.
      final huge = List.filled(500, 'someVeryLongLineOfGeneratedCode();').join('\n');
      final client = MockClient((request) async => _chatResponse(jsonEncode({
            'title': 'Looping model',
            'root_cause': ['Two orders share an id'],
            'code_before': 'final o = orders.singleWhere((x) => x.id == id);',
            'code_after': huge,
          })));

      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(huge.length, greaterThan(4000));
      expect(result!.codeAfter!.length, lessThan(4000));
      expect(result.codeAfter, endsWith('... truncated ...'));
      expect(result.codeBefore, contains('singleWhere'));
    });

    test('a code block returned as a list of lines is joined, not dropped',
        () async {
      final client = MockClient((request) async => _chatResponse(jsonEncode({
            'title': 'List-shaped code',
            'root_cause': ['Two orders share an id'],
            'code_before': ['final o = orders.singleWhere(', '  (x) => x.id == id);'],
            'code_after': ['final o = orders.where(', '  (x) => x.id == id).firstOrNull;'],
          })));

      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result!.codeBefore, 'final o = orders.singleWhere(\n  (x) => x.id == id);');
      expect(result.codeAfter, contains('firstOrNull'));
    });

    test('a reply with only one side of the diff drops both', () async {
      // A lone code block in a ticket reads as the fix rather than the bug.
      const halfDiff = '''
      {
        "title": "Duplicate order ids crash the list",
        "root_cause": ["Two orders share an id"],
        "code_after": "  final o = orders.where((x) => x.id == id).firstOrNull;"
      }
      ''';
      final client = MockClient((request) async => _chatResponse(halfDiff));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result!.codeBefore, isNull);
      expect(result.codeAfter, isNull);
    });

    test('the request names an output cap the free tier can actually grant', () async {
      // With no max_tokens the provider reserves the model's full 16k output
      // budget against a 1000 OTPM ceiling and 429s before the model runs.
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      await _analyzer(client).analyse(_incident(), 'trace');

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['max_tokens'], isA<int>());
      expect(body['max_tokens'] as int, lessThan(1000));
      expect(body['max_tokens'] as int, greaterThan(500));
    });

    test('a paid tier can raise the output cap without a code change', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      await GroqAnalyzer(
        endpoint: 'https://api.groq.com/openai/v1/chat/completions',
        authHeaderName: 'Authorization',
        authHeaderValue: 'Bearer test-secret-key',
        model: 'qwen/qwen3.8-27b',
        timeout: const Duration(seconds: 5),
        client: client,
        log: (_) {},
        maxOutputTokens: 4096,
      ).analyse(_incident(), 'trace');

      expect((jsonDecode(captured!.body) as Map<String, dynamic>)['max_tokens'], 4096);
    });

    test('real newlines inside code_before parse, and the code keeps its line breaks',
        () async {
      // What a model actually returns once it fills code_before with source:
      // literal newlines inside the string value, which jsonDecode rejects.
      const rawNewlines = '{\n'
          '  "title": "Duplicate order ids crash the list",\n'
          '  "root_cause": ["Two orders share an id"],\n'
          '  "severity": "major",\n'
          '  "code_before": "final o = orders.singleWhere(\n  (x) => x.id == id,\n);",\n'
          '  "code_after": "final o = orders.where(\n  (x) => x.id == id,\n).firstOrNull;"\n'
          '}';
      final client = MockClient((request) async => _chatResponse(rawNewlines));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result, isNotNull);
      expect(result!.codeBefore, 'final o = orders.singleWhere(\n  (x) => x.id == id,\n);');
      expect(result.codeAfter, 'final o = orders.where(\n  (x) => x.id == id,\n).firstOrNull;');
    });

    test('a raw tab inside a string survives as a tab, not as backslash-t', () async {
      final client = MockClient(
        (request) async => _chatResponse(
          '{"title": "Tabbed", "root_cause": ["a\tb"], "severity": "minor"}',
        ),
      );
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      expect(result!.rootCause, ['a\tb']);
    });

    test('an already-escaped \\n is not double-escaped', () async {
      final client = MockClient((request) async => _chatResponse(jsonEncode({
            'title': 'Escaped already',
            'root_cause': ['Two orders share an id'],
            'code_before': 'line one\nline two',
            'code_after': 'line one\nline two fixed',
          })));
      final result = await _analyzer(client).analyse(_incident(), 'trace');

      // jsonEncode already wrote the newline as the two characters \ and n; a
      // naive global escape would turn those into a literal backslash-n.
      expect(result!.codeBefore, 'line one\nline two');
      expect(result.codeBefore, isNot(contains(r'\n')));
    });

    test('a reply that is still unparseable after escaping returns null and logs why',
        () async {
      final logs = <String>[];
      // Balanced braces, so extraction succeeds and jsonDecode is the one to
      // refuse it — the path the control-character repair feeds.
      final client = MockClient(
        (request) async => _chatResponse('{"title": "oops" "root_cause": ["x"]}'),
      );

      final result = await _analyzer(client, log: logs.add).analyse(_incident(), 'trace');

      expect(result, isNull);
      expect(logs.single, contains('not valid JSON'));
    });

    test('sends the auth header name/value and api-version query param as configured', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _chatResponse(_validJson);
      });

      await _analyzer(client, apiVersion: '2024-06-01').analyse(_incident(), 'trace');

      expect(captured!.headers['Authorization'], 'Bearer test-secret-key');
      expect(captured!.url.queryParameters['api-version'], '2024-06-01');
    });
  });
}
