/// mathsolver — BYOK AI math solver with execution-based verification (v0.2).
///
/// Correctness model (PAL-style): the model never states the answer.
/// It returns a small JavaScript-like PROGRAM; this package executes the
/// program deterministically and the execution output IS the answer.
/// For equations, a CHECK expression ({x} placeholder) must evaluate to 0
/// when the computed answer is substituted back into the original equation.
library mathsolver;

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
    '{"program": "<string>", "steps": [<string>, ...], "check": "<string>"}\n'
    'Rules:\n'
    '- "program" is a small JavaScript-like program that computes the final answer.\n'
    '  One statement per line (or ; separated). Allowed statements:\n'
    '      let NAME = EXPRESSION\n'
    '      result = EXPRESSION\n'
    '  EXPRESSIONs may use numbers, + - * / % ^ ( ), the functions\n'
    '  abs sqrt sin cos tan ln log exp floor ceil round min max\n'
    '  (log is base 10, ln is natural), the constants pi and e, and any\n'
    '  variable defined by an earlier let. The value assigned to "result"\n'
    '  is the answer. Never state the answer as a number in text.\n'
    '- "steps" is an array of short plain-language explanation strings.\n'
    '- "check" is a verification expression containing the placeholder {x}.\n'
    '  After solving, {x} is replaced by the computed answer and the whole\n'
    '  expression must evaluate to 0.\n'
    '  For equations, substitute the answer back into the original equation\n'
    '  (e.g. 2x+3=11 -> "2*{x}+3-11").\n'
    '  For arithmetic, recompute via a different path and subtract the answer\n'
    '  (e.g. 15% of 80 -> "80*15/100-{x}"). Provide "check" whenever possible.';

String correctionPrompt(String reason) =>
    'Your submission failed verification: $reason. '
    'Re-derive the problem carefully and reply again with the same strict JSON shape.';

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
/// [env] maps variable names (case-sensitive, shadow pi/e) to values.
double evalExpression(String src, [Map<String, double>? env]) {
  if (src.trim().isEmpty) throw const SolverException('EXPR_EMPTY', 'empty expression');
  return _ExprParser(_tokenize(src), env).parseAll();
}

class _ExprParser {
  final List<_Tok> tokens;
  final Map<String, double>? env;
  int pos = 0;
  _ExprParser(this.tokens, this.env);

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
      final raw = t.id!;
      if (env != null && env!.containsKey(raw)) return env![raw]!;
      final name = raw.toLowerCase();
      if (peek()?.kind == '(') {
        eat();
        final args = <double>[expr()];
        while (peek()?.kind == ',') { eat(); args.add(expr()); }
        if (eat().kind != ')') throw const SolverException('EXPR_SYNTAX', 'expected )');
        final fn = _funcs[name];
        if (fn == null) throw SolverException('EXPR_UNKNOWN_FUNC', 'unknown function $name');
        return Function.apply(fn, args).toDouble();
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

/* ---------------- program interpreter ---------------- */

final _letRe = RegExp(r'^let\s+([a-zA-Z_]\w*)\s*=\s*(.+)$');
final _assignRe = RegExp(r'^([a-zA-Z_]\w*)\s*=\s*(.+)$');
final _checkXRe = RegExp(r'\{\s*x\s*\}', caseSensitive: false);

/// Execute a model-generated program. Statements (one per line or ;
/// separated): let NAME = EXPR | NAME = EXPR | bare EXPR. The answer is
/// the value of `result`, else the last bare expression. The model never
/// states the answer as a number — execution output IS the answer.
double runProgram(String src) {
  if (src.trim().isEmpty) throw const SolverException('PROGRAM_EMPTY', 'empty program');
  final env = <String, double>{};
  var resultDefined = false;
  var lastDefined = false;
  var lastValue = 0.0;
  for (final raw in src.split(RegExp(r'[\n;]+'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final lm = _letRe.firstMatch(line);
    if (lm != null) {
      env[lm.group(1)!] = evalExpression(lm.group(2)!, env);
      if (lm.group(1) == 'result') resultDefined = true;
      continue;
    }
    final am = _assignRe.firstMatch(line);
    if (am != null) {
      env[am.group(1)!] = evalExpression(am.group(2)!, env);
      if (am.group(1) == 'result') resultDefined = true;
      continue;
    }
    lastValue = evalExpression(line, env);
    lastDefined = true;
  }
  if (resultDefined) return env['result']!;
  if (lastDefined) return lastValue;
  throw const SolverException('PROGRAM_NO_RESULT', 'program produced no result');
}

/// Substitute the computed answer into a check expression ({x} placeholder)
/// and evaluate it. Passes when the value is ~0 (scaled tolerance).
({double value, bool passed}) runCheck(String checkSrc, double answer) {
  final substituted = checkSrc.replaceAllMapped(_checkXRe, (_) => '($answer)');
  final value = evalExpression(substituted);
  return (value: value, passed: value.abs() <= 1e-6 * m.max(1, answer.abs()));
}

/* ---------------- solve ---------------- */

class SolveResult {
  /// Output of executing the model's program locally.
  final double answer;
  final List<String> steps;
  /// The executed program (the answer's provenance).
  final String program;
  /// Verification expression; null = none provided.
  final String? check;
  /// Evaluated check expression; null when no check provided.
  final double? checkValue;
  /// True only when the check expression evaluated to ~0.
  final bool verified;
  final int retries;
  const SolveResult(this.answer, this.steps, this.program, this.check,
      this.checkValue, this.verified, this.retries);
}

/// Transport: (url, bodyJson, apiKey) -> model reply text.
typedef Transport = Future<String> Function(String url, String bodyJson, String apiKey);

/// Test seam for the HTTP interface below the default transport:
/// (url, headers, bodyJson) -> (status, raw body).
typedef HttpPost = Future<(int, String)> Function(String url, Map<String, String> headers, String bodyJson);

Future<(int, String)> _realHttpPost(String url, Map<String, String> headers, String bodyJson) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    headers.forEach(req.headers.set);
    req.write(bodyJson);
    final res = await req.close();
    final raw = await res.transform(utf8.decoder).join();
    return (res.statusCode, raw);
  } finally {
    client.close();
  }
}

String contentFromResponse(int status, String raw) {
  if (status >= 300) throw SolverException('HTTP_ERROR', 'API responded $status');
  final dynamic content = jsonDecode(raw)['choices']?[0]?['message']?['content'];
  if (content is! String) throw const SolverException('HTTP_ERROR', 'missing message content');
  return content;
}

Map<String, dynamic> _parseModelReply(String text) {
  final start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end <= start) throw const SolverException('INVALID_JSON', 'no JSON object in reply');
  final dynamic data = _tryJsonDecode(text.substring(start, end + 1));
  if (data is! Map) throw const SolverException('INVALID_JSON', 'reply was not valid JSON');
  final dynamic program = data['program'];
  if (program is! String || program.trim().isEmpty) {
    throw const SolverException('INVALID_JSON', 'missing program');
  }
  final dynamic steps = data['steps'];
  final dynamic check = data['check'];
  return {
    'program': program,
    'steps': steps is List ? steps.map((s) => s.toString()).toList() : <String>[],
    'check': check is String && check.trim().isNotEmpty ? check : null,
  };
}

dynamic _tryJsonDecode(String s) {
  try {
    return jsonDecode(s);
  } on FormatException {
    return null;
  }
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
  final HttpPost? _httpPost;

  MathSolverClient({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    Transport? transport,
    HttpPost? httpPost,
  })  : _transport = transport,
        _httpPost = httpPost {
    if (apiKey.isEmpty) throw const SolverException('NO_API_KEY', 'apiKey is required (BYOK)');
    _base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    if (!_base!.startsWith('http://') && !_base!.startsWith('https://')) {
      throw const SolverException('BAD_BASE_URL', 'baseUrl must be an http(s) URL, e.g. https://api.deepseek.com/v1');
    }
  }

  String? _base;

  /// Solve a math problem. `answer` is the output of executing the model's
  /// program; `verified` is true only when the check expression ({x}
  /// substituted with the answer) evaluated to ~0.
  Future<SolveResult> solve(String problem) async {
    if (problem.trim().isEmpty) throw const SolverException('NO_PROBLEM', 'problem must be non-empty');
    final post = _httpPost ?? _realHttpPost;
    Future<String> Function(String, String, String) tr = _transport ?? (url, bodyJson, apiKey) async {
      final (status, raw) = await post(url, {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      }, bodyJson);
      return contentFromResponse(status, raw);
    };
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

    ({bool ok, double answer, double? checkValue, bool verified, SolverException? err}) attempt(
        Map<String, dynamic> p) {
      try {
        final answer = runProgram(p['program'] as String);
        double? cv;
        var v = false;
        final check = p['check'] as String?;
        if (check != null) {
          final r = runCheck(check, answer);
          cv = r.value;
          v = r.passed;
        }
        return (ok: true, answer: answer, checkValue: cv, verified: v, err: null);
      } on SolverException catch (e) {
        return (ok: false, answer: 0, checkValue: null, verified: false, err: e);
      }
    }

    var outcome = attempt(parsed);
    var retries = 0;
    if (!outcome.ok || !outcome.verified) {
      retries = 1;
      final reason = outcome.ok
          ? 'check evaluated to ${outcome.checkValue} instead of 0'
          : 'program failed to execute (${outcome.err!.code}: ${outcome.err!.message})';
      messages.add({'role': 'assistant', 'content': jsonEncode(parsed)});
      messages.add({'role': 'user', 'content': correctionPrompt(reason)});
      final secondParsed = _parseModelReply(await call()); // second failure throws
      final second = attempt(secondParsed);
      if (!second.ok) throw second.err!; // PROGRAM_* error persisted after retry
      parsed = secondParsed;
      outcome = second;
    }
    return SolveResult(outcome.answer, (parsed['steps'] as List).cast<String>(),
        parsed['program'] as String, parsed['check'] as String?,
        outcome.checkValue, outcome.verified, retries);
  }
}
