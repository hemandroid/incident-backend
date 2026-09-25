/// Turns a captured incident into an [Analysis] via an OpenAI-compatible
/// chat-completions endpoint (Groq today, Azure AI Foundry tomorrow).
/// Everything provider-specific is a constructor parameter, so swapping
/// provider is a config change, never a code change.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contracts.dart';
import 'incident_context.dart';
import 'source_reader.dart';

class GroqAnalyzer implements IncidentAnalyzer {
  GroqAnalyzer({
    required String endpoint,
    required String authHeaderName,
    required String authHeaderValue,
    required String model,
    String? apiVersion,
    required Duration timeout,
    required http.Client client,
    required Log log,
    SourceReader? sourceReader,
    int maxOutputTokens = _maxOutputTokens,
  })  : _sourceReader = sourceReader,
        _outputTokenCap = maxOutputTokens,
        _endpoint = endpoint,
        _authHeaderName = authHeaderName,
        _authHeaderValue = authHeaderValue,
        _model = model,
        _apiVersion = apiVersion,
        _log = log,
        _timeout = timeout,
        _client = client;

  final String _endpoint;
  final String _authHeaderName;
  final String _authHeaderValue;
  final String _model;
  final String? _apiVersion;
  final Duration _timeout;
  final int _outputTokenCap;
  final http.Client _client;
  final Log _log;

  /// Absent when no source checkout is configured; the prompt then never
  /// mentions code_before/code_after, so the model cannot invent them.
  final SourceReader? _sourceReader;

  // Keeps the request small and cheap while keeping the highest-signal
  // fields: top stack frames and the most recent routes/breadcrumbs.
  static const int _maxStackTraceChars = 4000;
  static const int _maxRoutes = 15;
  static const int _maxBreadcrumbs = 20;
  static const int _maxRequests = 5;

  // The entry count caps above bound how many breadcrumbs are kept, not how
  // long each one is — a 16KB log ring buffer spread over 20 short-looking
  // entries can still blow the prompt past a provider's request-size limit.
  // This caps the joined text itself, same as _maxStackTraceChars/_maxCodeChars.
  static const int _maxBreadcrumbTextChars = 4000;

  // Groq reserves the model's whole output allowance (16k) against the free
  // tier's 1000 output-tokens-per-minute ceiling and rejects the call with a
  // 429 before the model runs, so the cap has to be stated. 900 is what the
  // schema needs and no more: title, root_cause and repro_steps cost ~250
  // tokens together, leaving room for both 3000-char code blocks to come back
  // whole (see _maxCodeChars) rather than truncated mid-line. A paid tier
  // lifts the OTPM ceiling, so this is a constructor parameter — raise it
  // there, not here.
  static const int _maxOutputTokens = 900;

  static const Set<String> _validSeverities = {'blocker', 'major', 'minor'};

  @override
  Future<Analysis?> analyse(Incident incident, String symbolicatedTrace) async {
    // A broad catch: a slow/broken model must never delay ticket filing, and
    // an exception's toString() could echo the request back into a log line.
    try {
      final response = await _client
          .post(
            _requestUri(),
            headers: {
              'Content-Type': 'application/json',
              _authHeaderName: _authHeaderValue,
            },
            body: jsonEncode({
              'model': _model,
              'messages': [
                {'role': 'user', 'content': _buildPrompt(incident, symbolicatedTrace)},
              ],
              'max_tokens': _outputTokenCap,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        return _fail('http ${response.statusCode}: '
            '${response.body.substring(0, response.body.length.clamp(0, 200))}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return _fail('response body was not a JSON object');
      }

      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return _fail('no choices');

      final firstChoice = choices.first;
      final message = firstChoice is Map ? firstChoice['message'] : null;
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.isEmpty) {
        return _fail('empty content; finish_reason='
            '${firstChoice is Map ? firstChoice['finish_reason'] : '?'}');
      }

      return _parseAnalysis(content, incident);
    } catch (e) {
      // Type only: the exception message can carry the request body and key.
      return _fail('threw ${e.runtimeType}');
    }
  }

  /// Every give-up path logs which, so a ticket with no root cause is
  /// traceable to a reason.
  Null _fail(String reason) {
    _log('[analyzer] no analysis: $reason');
    return null;
  }


  Uri _requestUri() {
    final base = Uri.parse(_endpoint);
    if (_apiVersion == null) return base;
    // Azure needs `?api-version=...`; Groq ignores the extra param.
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'api-version': _apiVersion,
    });
  }

  String _buildPrompt(Incident incident, String symbolicatedTrace) {
    final trace = _clamp(symbolicatedTrace, _maxStackTraceChars);

    final routes = _recentTail(incident.context['routes'], _maxRoutes);
    final breadcrumbs = _recentTail(incident.context['logs'], _maxBreadcrumbs);
    final breadcrumbsText =
        _clamp(breadcrumbs.join('\n'), _maxBreadcrumbTextChars);
    final requests = recentEntries(incident.context['network'])
        .map(renderRequest)
        .toList();
    final lastRequests = requests.length > _maxRequests
        ? requests.sublist(requests.length - _maxRequests)
        : requests;
    // Same bound as the breadcrumbs: a redacted URL can still be long.
    final requestsText =
        _clamp(lastRequests.join('\n'), _maxBreadcrumbTextChars);

    // Matched against the FULL trace, not the truncated `trace` above the
    // model actually sees — a source excerpt can therefore quote a frame
    // the prompt's stack trace section has already cut off. Left as is: the
    // excerpt is the higher-signal of the two, and worth keeping even when
    // the frame that earned it scrolled out of view.
    final excerpt = _sourceReader?.excerptFor(symbolicatedTrace);

    final buffer = StringBuffer()
      ..writeln(
        'You are a senior engineer triaging a production crash to write a Jira '
        'ticket. Read the incident evidence below and return ONLY a single '
        'JSON object as your entire response — no markdown code fences, no '
        'sentence before or after it.',
      )
      ..writeln(
        'Every key below is required. If the evidence is thin, say so in the '
        'value — never omit a key and never return a partial object.',
      )
      ..writeln('The JSON object must have exactly these keys:')
      ..writeln('  "title": one line, suitable as a Jira summary')
      ..writeln(
        '  "root_cause": an array of short, self-contained statements '
        'ordered from trigger to consequence, readable by a developer who '
        'has never seen this code, grounded only in the evidence below — '
        'must be a JSON array, never a single paragraph string',
      )
      ..writeln(
        '  "repro_steps": an array of strings — a step-by-step sequence to '
        'reproduce the crash, built from the route history below; do not '
        'invent steps it does not support',
      )
      ..writeln('  "severity": one of "blocker", "major", "minor"')
      ..writeln('  "suggested_fix": a concrete suggestion for what to change');

    if (excerpt != null) {
      buffer
        ..writeln(
          '  "code_before": a string holding the exact lines from the SOURCE '
          'AT THE CRASH SITE section below that must change — copied '
          'verbatim, with the "N | " line-number prefixes removed and the '
          'original indentation kept',
        )
        ..writeln(
          '  "code_after": a string holding those same lines rewritten so the '
          'crash cannot happen; same indentation, no commentary, no ellipses',
        )
        ..writeln(
          '  If the source above does not show a safe rewrite, omit both '
          'code_before and code_after rather than inventing one',
        );
    }

    buffer
      ..writeln()
      ..writeln(
        'Do not echo the raw stack trace or user data verbatim into your '
        'answer, and do not invent facts that are not present in the input '
        'below.',
      )
      ..writeln()
      ..writeln('ERROR: ${incident.error}')
      ..writeln('ERROR CONTEXT: ${incident.errorContext ?? 'none'}')
      ..writeln('SOURCE: ${incident.source.name}')
      ..writeln('APP VERSION: ${incident.appVersion}')
      ..writeln('PLATFORM: ${incident.platform}');

    final stall = incident.context[uiStallContextKey];
    if (stall is Map && stall['duration_ms'] != null) {
      buffer.writeln(
        'UI STALL DURATION: ${stall['duration_ms']}ms (main isolate was '
        'blocked this long before capture)',
      );
    }

    buffer
      ..writeln()
      ..writeln('SYMBOLICATED STACK TRACE (may be truncated to the top frames):')
      ..writeln(trace);

    if (excerpt != null) {
      buffer
        ..writeln()
        ..writeln(
          'SOURCE AT THE CRASH SITE — ${excerpt.path}, which the trace blames '
          'at line ${excerpt.line}. The leading "N | " on each line is a line '
          'number, not part of the code:',
        )
        ..writeln(excerpt.numberedLines);
    }

    buffer
      ..writeln()
      ..writeln(
        'ROUTE HISTORY (oldest to newest, most recent $_maxRoutes shown — use '
        'this to build repro_steps):',
      )
      ..writeln(routes.isEmpty ? 'none captured' : routes.join(' -> '))
      ..writeln()
      ..writeln('LOG BREADCRUMBS (most recent $_maxBreadcrumbs shown):')
      ..writeln(breadcrumbs.isEmpty ? 'none captured' : breadcrumbsText)
      ..writeln()
      ..writeln('NETWORK REQUESTS (oldest to newest, most recent '
          '$_maxRequests shown):')
      ..writeln(lastRequests.isEmpty ? 'none captured' : requestsText);

    return buffer.toString();
  }

  /// Never touches `incident.context`'s `screenshot` — a base64 image that
  /// would blow the context window and cost if sent to the model.
  List<String> _recentTail(Object? raw, int max) {
    final items = recentEntries(raw).map(_renderEntry).toList();
    return items.length <= max ? items : items.sublist(items.length - max);
  }

  /// Same truncate-with-marker shape as `_maxCodeChars` below: bounds a
  /// prompt section without hiding from the model that it happened.
  static String _clamp(String text, int max) =>
      text.length > max ? '${text.substring(0, max)}\n...(truncated)' : text;

  /// Renders one route/log entry as a short line instead of a raw Map
  /// `toString()`, which a model reads far worse than `push /orders`.
  String _renderEntry(Object? entry) {
    if (entry is Map) {
      final event = entry['event'];
      final route = entry['route'];
      if (event != null && route != null) return '$event $route';
      final level = entry['level'];
      final message = entry['message'];
      if (level != null && message != null) return '[$level] $message';
    }
    return entry.toString();
  }

  /// Models rename keys as readily as they omit them.
  static Object? _pick(Map<String, dynamic> json, List<String> names) {
    for (final name in names) {
      final value = json[name];
      if (value != null) return value;
    }
    return null;
  }

  Analysis? _parseAnalysis(String content, Incident incident) {
    final jsonText = _extractJsonObject(content);
    if (jsonText == null) {
      return _fail('no JSON object found in a ${content.length}-char reply');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      return _fail('extracted text was not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      return _fail('parsed JSON was not an object');
    }

    // Only root cause is worth failing over: a title can be built from the
    // error, and missing repro steps cost a section, not the whole analysis.
    // Accepts the new array shape and, so an older-shaped reply still
    // works, a bare string wrapped into a single-element list.
    final rootCauseRaw = _pick(decoded, ['root_cause', 'rootCause', 'cause']);
    final List<dynamic> rootCauseList = rootCauseRaw is List
        ? rootCauseRaw
        : rootCauseRaw is String
            ? [rootCauseRaw]
            : const [];
    final rootCause = rootCauseList
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (rootCause.isEmpty) {
      return _fail('missing root_cause');
    }

    final titleRaw = _pick(decoded, ['title', 'summary', 'headline']);
    final title = titleRaw is String && titleRaw.trim().isNotEmpty
        ? titleRaw.trim()
        : '${incident.error} (${incident.platform})';

    final reproStepsRaw =
        _pick(decoded, ['repro_steps', 'reproSteps', 'steps', 'reproduction_steps']);
    final reproSteps = reproStepsRaw is List
        ? reproStepsRaw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];

    final severityRaw = _pick(decoded, ['severity', 'priority']);
    final severity =
        severityRaw is String && _validSeverities.contains(severityRaw.toLowerCase())
            ? severityRaw.toLowerCase()
            : null;
    final suggestedFix = _pick(decoded, ['suggested_fix', 'suggestedFix', 'fix']);

    // Half a diff is worse than none, so a reply carrying only one side is
    // discarded rather than rendered as a lone code block.
    final before = _codeString(decoded, ['code_before', 'codeBefore']);
    final after = _codeString(decoded, ['code_after', 'codeAfter']);
    final bothSides = before != null && after != null;

    return Analysis(
      title: title,
      rootCause: rootCause,
      reproSteps: reproSteps,
      severity: severity,
      suggestedFix: suggestedFix is String ? suggestedFix : null,
      codeBefore: bothSides ? before : null,
      codeAfter: bothSides ? after : null,
    );
  }

  /// A looping model can return tens of thousands of characters here. Left
  /// uncapped it pushes the Jira description past the ADF field limit, Jira
  /// answers 400 and no ticket is filed at all — worse than the prose ticket
  /// this feature replaces.
  static const int _maxCodeChars = 3000;

  static String? _codeString(Map<String, dynamic> json, List<String> names) {
    final value = _pick(json, names);
    // A list of lines is as common a model shape as one newline-joined string.
    final text = value is String
        ? value
        : value is List
            ? value.map((e) => e.toString()).join('\n')
            : null;
    if (text == null) return null;

    // Trailing whitespace only, so the snippet keeps its leading indentation.
    final trimmed = text.trimRight();
    if (trimmed.trim().isEmpty) return null;
    return trimmed.length <= _maxCodeChars
        ? trimmed
        : '${trimmed.substring(0, _maxCodeChars)}\n... truncated ...';
  }

  /// Pulls a JSON object out of a chat completion's free-form text (models
  /// wrap it in fences or ramble ahead of it). Tracks string/escape state
  /// rather than brace-counting alone, which would misfire on a `}` inside a
  /// quoted string.
  ///
  /// The same state also decides where a raw control character is a bug. A
  /// model filling code_before/code_after with real code writes real newlines
  /// into the string value, which jsonDecode rejects outright — the very
  /// feature that makes the ticket worth reading is the one that loses the
  /// whole analysis. Escaping those is only safe from inside the walk: a
  /// global replace would also eat the newlines between tokens and re-escape
  /// the backslash of an already-correct `\n`.
  String? _extractJsonObject(String content) {
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(content);
    final text = fenced != null ? fenced.group(1)! : content;

    final start = text.indexOf('{');
    if (start == -1) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    final out = StringBuffer();
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          // Already a valid escape sequence's payload: copy it untouched.
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        } else if (ch.codeUnitAt(0) < 0x20) {
          out.write(_jsonEscapeForControl(ch));
          continue;
        }
        out.write(ch);
        continue;
      }
      out.write(ch);
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return out.toString();
      }
    }
    return null;
  }

  /// `\uXXXX` is valid for every control character, but the named forms keep
  /// the repaired text readable when a parse failure has to be diagnosed.
  static const Map<int, String> _namedControlEscapes = {
    0x08: r'\b',
    0x09: r'\t',
    0x0a: r'\n',
    0x0c: r'\f',
    0x0d: r'\r',
  };

  static String _jsonEscapeForControl(String ch) {
    final code = ch.codeUnitAt(0);
    return _namedControlEscapes[code] ??
        '\\u${code.toRadixString(16).padLeft(4, '0')}';
  }
}
