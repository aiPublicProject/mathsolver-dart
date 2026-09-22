/// mathsolver — BYOK AI math solver with independent verification.
/// An answer is only `verified: true` when the model's verification
/// expression (pure arithmetic) is evaluated locally and matches.
library mathsolver;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as m;

class SolverException implements Exception {
  final String code;
  final String message;
  const SolverException(this.code, this.message);
  @override
  String toString() => '$code: $message';
}

const systemPrompt = 'You are a precise math solver.\n'
    'Reply with STRICT JSON only, no markdown fences, in this exact shape:\n'
    '{"answer": <number>, "steps": [<string>, ...], "verification": {"expression": "<string>"}}\n'
    'Rules:\n'
    '- "answer" must be a single number (the final result).\n'
    '- "steps" must be an array of short plain-language explanation strings.\n'
    '- "verification.expression" must be a pure arithmetic expression that\n'
    '  evaluates to the answer. Allowed: numbers, + - * / % ^ ( ), and the\n'
    '  functions abs sqrt sin cos tan ln log exp floor ceil round min max\n'
    '  (log is base 10, ln is natural), and the constants pi and e.\n'
    '- The expression must recompute the answer independently.';

/* ---------------- expression evaluator ---------------- */

final _funcs = <String, Function>{
  'abs': (double x) => x.abs(),
  'sqrt': m.sqrt,
  'sin': m.sin, 'cos': m.cos, 'tan': m.tan,
  'ln': m.log,
  'log': (double x) => (m.log(x) / m.ln10),
  'exp': m.exp,
  'floor': (double x) => x.floorToDouble(),
  'ceil': (double x) => x.ceilToDouble(),
  'round': (double x) => x.roundToDouble(),
  'min': (double a, double b) => m.min(a, b),
  'max': (double a, double b) => m.max(a, b),
};

class _Tok {
  final String kind; // num | id | single op char
  final double? num;
  final String? id;
  const _Tok(this.kind, {this.num, this.id});
}

List<_Tok> _tokenize(String src) {
  final toks = <_Tok>[];
  final re = RegExp(r'\s*(?:(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+)|([a-zA-Z_][a-zA-Z_0-9]*)|([-+*/%^(),]))');
  var covered = 0;
  for (final match in re.allMatches(src)) {
    if (match.end == match.start) continue;
    covered = match.end;
    if (match.group(1) != null) {
      toks.add(_Tok('num', num: double.parse(match.group(1)!)));
    } else if (match.group(2) != null) {
      toks.add(_Tok('id', id: match.group(2)));
    } else {
      toks.add(_Tok(match.group(3)!));
    }
  }
  if (src.substring(covered).trim().isNotEmpty) {
    throw const SolverException('EXPR_BAD_CHAR', 'unexpected character');
  }
  return toks;
}

/// Evaluate a pure arithmetic expression string.
double evalExpression(String src) {
  if (src.trim().isEmpty) throw const SolverException('EXPR_EMPTY', 'empty expression');
  return _ExprParser(_tokenize(src)).parseAll();
}

class _ExprParser {
  final List<_Tok> tokens;
  int pos = 0;
  _ExprParser(this.tokens);

  _Tok? peek() => pos < tokens.length ? tokens[pos] : null;
  _Tok eat() {
    if (pos >= tokens.length) throw const SolverException('EXPR_SYNTAX', 'expected more tokens');
    return tokens[pos++];
  }

  double parseAll() {
    final v = expr();
    if (pos != tokens.length) throw const SolverException('EXPR_TRAILING', 'trailing tokens');
    if (v.isNaN || v.isInfinite) throw const SolverException('EXPR_NON_FINITE', 'non-finite result');
    return v;
  }

  double expr() {
    var v = term();
    while (peek()?.kind == '+' || peek()?.kind == '-') {
      final op = eat().kind;
      final r = term();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double term() {
    var v = unary();
    while (peek()?.kind == '*' || peek()?.kind == '/' || peek()?.kind == '%') {
      final op = eat().kind;
      final r = unary();
      v = op == '*' ? v * r : (op == '/' ? v / r : v % r);
    }
    return v;
  }

  double unary() {
    if (peek()?.kind == '-') { eat(); return -unary(); }
    if (peek()?.kind == '+') { eat(); return unary(); }
    return power();
  }

  double power() {
    final base = atom();
    if (peek()?.kind == '^') {
      eat();
      return m.pow(base, unary()).toDouble(); // right associative
    }
    return base;
  }

  double atom() {
    final t = eat();
    if (t.kind == 'num') return t.num!;
    if (t.kind == 'id') {
      final name = t.id!.toLowerCase();
      if (peek()?.kind == '(') {
        eat();
        final args = <double>[expr()];
        while (peek()?.kind == ',') { eat(); args.add(expr()); }
        if (eat().kind != ')') throw const SolverException('EXPR_SYNTAX', 'expected )');
        final fn = _funcs[name];
        if (fn == null) throw SolverException('EXPR_UNKNOWN_FUNC', 'unknown function $name');
        return (fn as Function).call(*args) as double;
      }
      if (name == 'pi') return m.pi;
      if (name == 'e') return m.e;
      throw SolverException('EXPR_UNKNOWN_ID', 'unknown identifier $name');
    }
    if (t.kind == '(') {
      final v = expr();
      if (eat().kind != ')') throw const SolverException('EXPR_SYNTAX', 'expected )');
      return v;
    }
    throw SolverException('EXPR_SYNTAX', 'unexpected token ${t.kind}');
  }
}

bool _numericallyEqual(double a, double b) =>
    (a - b).abs() <= 1e-6 * m.max(1, m.max(a.abs(), b.abs()));

/* ---------------- solve ---------------- */

class SolveResult {
  final double answer;
  final List<String> steps;
  final String expression;
  final double? evaluated;
  final bool verified;
  final int retries;
  const SolveResult(this.answer, this.steps, this.expression, this.evaluated, this.verified, this.retries);
}

/// Transport: (url, bodyJson, apiKey) -> model reply text.
typedef Transport = Future<String> Function(String url, String bodyJson, String apiKey);

Future<String> _defaultTransport(String url, String bodyJson, String apiKey) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url))
      ..headers.set('Content-Type', 'application/json')
      ..headers.set('Authorization', 'Bearer $apiKey');
    req.write(bodyJson);
    final res = await req.close();
    if (res.statusCode >= 300) throw SolverException('HTTP_ERROR', 'API responded ${res.statusCode}');
    final raw = await res.transform(utf8.decoder).join();
    final content = jsonDecode(raw)['choices'][0]['message']['content'];
    if (content is! String) throw const SolverException('HTTP_ERROR', 'missing message content');
    return content;
  } catch (e) {
    if (e is SolverException) rethrow;
    throw SolverException('HTTP_ERROR', 'API call failed: $e');
  } finally {
    client.close();
  }
}

Map<String, dynamic> _parseModelReply(String text) {
  final start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end <= start) throw const SolverException('INVALID_JSON', 'no JSON object in reply');
  final dynamic data = jsonDecode(text.substring(start, end + 1));
  final dynamic answer = data['answer'];
  double parsed;
  if (answer is num) {
    parsed = answer.toDouble();
  } else if (answer is String) {
    final mm = RegExp(r'-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?').firstMatch(answer);
    if (mm == null) throw const SolverException('INVALID_JSON', 'missing numeric answer');
    parsed = double.parse(mm.group(0)!);
  } else {
    throw const SolverException('INVALID_JSON', 'missing numeric answer');
  }
  final dynamic expression = data['verification']?['expression'];
  if (expression is! String) throw const SolverException('INVALID_JSON', 'missing verification.expression');
  final dynamic steps = data['steps'];
  return {
    'answer': parsed,
    'steps': steps is List ? steps.map((s) => s.toString()).toList() : <String>[],
    'expression': expression,
  };
}

/// BYOK client for an OpenAI-compatible endpoint. Instantiate once, solve many.
///
/// ```dart
/// final solver = MathSolverClient(apiKey: 'sk-...', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat');
/// final r = await solver.solve('2x + 3 = 11, solve for x');
/// ```
class MathSolverClient {
  final String apiKey;
  final String baseUrl;
  final String model;
  final Transport? _transport;

  MathSolverClient({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    Transport? transport,
  }) : _transport = transport {
    if (apiKey.isEmpty) throw const SolverException('NO_API_KEY', 'apiKey is required (BYOK)');
    _base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    if (!_base!.startsWith('http://') && !_base!.startsWith('https://')) {
      throw const SolverException('BAD_BASE_URL', 'baseUrl must be an http(s) URL, e.g. https://api.deepseek.com/v1');
    }
  }

  String? _base;

  /// Solve a math problem. `verified` is true only when the model's
  /// verification expression independently re-evaluates to the answer.
  Future<SolveResult> solve(String problem) async {
    if (problem.trim().isEmpty) throw const SolverException('NO_PROBLEM', 'problem must be non-empty');
    final tr = _transport ?? _defaultTransport;
    final url = '$_base/chat/completions';
    final messages = [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': problem},
    ];
    Future<String> call() => tr(url, jsonEncode({'model': model, 'messages': messages, 'temperature': 0}), apiKey);

    Map<String, dynamic> parsed;
    try {
      parsed = _parseModelReply(await call());
    } on SolverException catch (e) {
      if (e.code != 'INVALID_JSON') rethrow;
      messages.add({'role': 'assistant', 'content': 'invalid JSON'});
      messages.add({'role': 'user', 'content': 'Your reply was not valid JSON. Reply again with the exact strict JSON shape.'});
      parsed = _parseModelReply(await call());
    }

    (double?, bool) evaluate(Map<String, dynamic> p) {
      try {
        final ev = evalExpression(p['expression'] as String);
        return (ev, _numericallyEqual(ev, p['answer'] as double));
      } on SolverException {
        return (null, false);
      }
    }

    var (evaluated, verified) = evaluate(parsed);
    var retries = 0;
    if (!verified) {
      retries = 1;
      messages.add({'role': 'user', 'content':
        'Your verification expression evaluated to ${evaluated ?? "an error"}, which does not match your answer ${parsed['answer']}. '
        'Re-derive carefully and reply again with the same strict JSON shape.'});
      try {
        final second = _parseModelReply(await call());
        final (ev2, ok2) = evaluate(second);
        if (ev2 != null) evaluated = ev2;
        if (ok2) { parsed = second; verified = true; }
      } on SolverException {
        // keep first attempt
      }
    }
    return SolveResult(parsed['answer'] as double, (parsed['steps'] as List).cast<String>(),
        parsed['expression'] as String, evaluated, verified, retries);
  }
}
