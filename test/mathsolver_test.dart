import 'dart:convert';
import 'dart:io' show Platform;
import 'package:mathsolver/mathsolver.dart';
import 'package:test/test.dart';

// v0.2 protocol fixtures: the model returns program/steps/check — never an answer.
const good = '{"program": "let d = 11 - 3;\\nlet x = d / 2;\\nresult = x", "steps": ["Subtract 3: 2x = 8", "Divide by 2: x = 4"], "check": "2*{x} + 3 - 11"}';
const noCheck = '{"program": "result = 0.15 * 80", "steps": ["Compute 15% of 80"]}';
const wrongCheck = '{"program": "let d = 11 - 3;\\nresult = d / 2", "steps": ["..."], "check": "2*{x} + 3 - 12"}';
const brokenProgram = '{"program": "result = undefinedvar + 1", "steps": []}';

Matcher isCode(String code) => predicate((e) => e is SolverException && e.code == code);
Matcher isCodePrefix(String prefix) =>
    predicate((e) => e is SolverException && e.code.startsWith(prefix));

void main() {
  group('evalExpression', () {
    test('precedence', () {
      expect(evalExpression('2*3+4'), closeTo(10, 1e-9));
      expect(evalExpression('2+3*4'), closeTo(14, 1e-9));
      expect(evalExpression('(2+3)*4'), closeTo(20, 1e-9));
      expect(evalExpression('2^3^2'), closeTo(512, 1e-9));
      expect(evalExpression('-3^2'), closeTo(-9, 1e-9));
    });
    test('functions and constants', () {
      expect(evalExpression('sqrt(16)'), closeTo(4, 1e-9));
      expect(evalExpression('min(3,5)'), closeTo(3, 1e-9));
      expect(evalExpression('pi'), closeTo(3.141592653589793, 1e-12));
      expect(evalExpression('log(1000)'), closeTo(3, 1e-9));
    });
    test('env variables', () {
      expect(evalExpression('d / 2', {'d': 8}), closeTo(4, 1e-9));
      expect(evalExpression('x + y', {'x': 1.5, 'y': 2.5}), closeTo(4, 1e-9));
      expect(() => evalExpression('d'), throwsA(isA<SolverException>()));
      expect(evalExpression('pi', {'pi': 3}), closeTo(3, 1e-12)); // env shadows constant
    });
    test('rejects bad input', () {
      for (final bad in ['Process.run("x")', '1+2)', 'foo(1)', '']) {
        expect(() => evalExpression(bad), throwsA(isA<SolverException>()));
      }
    });
  });

  group('runProgram', () {
    test('let + result + bare', () {
      expect(runProgram('let d = 11 - 3;\nlet x = d / 2;\nresult = x'), closeTo(4, 1e-9));
      expect(runProgram('let a = 3; let b = 4; a * b'), closeTo(12, 1e-9));
      expect(runProgram('0.15 * 80'), closeTo(12, 1e-9));
    });
    test('rejects bad programs', () {
      for (final bad in ['result = undefinedvar + 1', '', 'let a = 1; let b = 2']) {
        expect(() => runProgram(bad), throwsA(isA<SolverException>()));
      }
    });
  });

  test('runCheck substitutes {x}', () {
    final pass = runCheck('2*{x} + 3 - 11', 4);
    expect(pass.passed, true);
    expect(pass.value, closeTo(0, 1e-9));
    final fail = runCheck('2*{x} + 3 - 12', 4);
    expect(fail.passed, false);
    expect(fail.value, closeTo(-1, 1e-9));
    expect(runCheck('80*15/100 - {x}', 12).passed, true);
  });

  group('solve', () {
    test('answer from execution, verified first try', () async {
      var calls = 0;
      String? seenUrl, seenKey;
      Map<String, dynamic>? seenBody;
      final solver = MathSolverClient(apiKey: 'sk-test', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat',
          transport: (url, body, key) async {
        calls++;
        seenUrl = url;
        seenKey = key;
        seenBody = jsonDecode(body) as Map<String, dynamic>;
        return good;
      });
      final r = await solver.solve('2x + 3 = 11, solve for x');
      // 答案=执行产物(4), 代回检验=0; 模型 JSON 里没有 answer 字段
      expect(r.verified, true);
      expect(r.retries, 0);
      expect(r.answer, closeTo(4, 1e-9));
      expect(r.checkValue, closeTo(0, 1e-9));
      expect(calls, 1);
      expect(seenUrl, 'https://api.deepseek.com/v1/chat/completions');
      expect(seenKey, 'sk-test');
      expect(seenBody!['model'], 'deepseek-chat');
      expect(seenBody!['temperature'], 0);
      expect((jsonDecode(good) as Map).containsKey('answer'), false);
    });

    test('no check -> unverified, answer from execution', () async {
      final r = await MathSolverClient(apiKey: 'sk', transport: (u, b, k) async => noCheck).solve('15% of 80');
      expect(r.answer, closeTo(12, 1e-9));
      expect(r.verified, false);
      expect(r.check, isNull);
      expect(r.checkValue, isNull);
    });

    test('check fails -> retry recovers', () async {
      var n = 0;
      final r = await MathSolverClient(apiKey: 'sk', transport: (u, b, k) async {
        n++;
        return n == 1 ? wrongCheck : good;
      }).solve('2x+3=11');
      expect(r.verified, true);
      expect(r.retries, 1);
      expect(r.answer, closeTo(4, 1e-9));
    });

    test('program error -> retry recovers', () async {
      var n = 0;
      final r = await MathSolverClient(apiKey: 'sk', transport: (u, b, k) async {
        n++;
        return n == 1 ? brokenProgram : good;
      }).solve('2x+3=11');
      expect(r.verified, true);
      expect(r.answer, closeTo(4, 1e-9));
    });

    test('program error persists -> PROGRAM_*/EXPR_* thrown', () async {
      await expectLater(
        MathSolverClient(apiKey: 'sk', transport: (u, b, k) async => brokenProgram).solve('2x+3=11'),
        throwsA(anyOf(isCodePrefix('PROGRAM_'), isCodePrefix('EXPR_'))),
      );
    });

    test('invalid json then ok', () async {
      var n = 0;
      final r = await MathSolverClient(apiKey: 'sk', transport: (u, b, k) async {
        n++;
        return n == 1 ? 'no json' : good;
      }).solve('1+1');
      expect(r.verified, true);
    });

    test('invalid twice raises', () async {
      await expectLater(
        MathSolverClient(apiKey: 'sk', transport: (u, b, k) async => 'nothing').solve('1+1'),
        throwsA(isCode('INVALID_JSON')),
      );
    });

    test('no api key throws at construction', () {
      expect(
        () => MathSolverClient(apiKey: ''),
        throwsA(isCode('NO_API_KEY')),
      );
    });

    test('http error no retry', () async {
      var calls = 0;
      await expectLater(
        MathSolverClient(apiKey: 'sk', transport: (u, b, k) async {
          calls++;
          throw const SolverException('HTTP_ERROR', '401');
        }).solve('1+1'),
        throwsA(isCode('HTTP_ERROR')),
      );
      expect(calls, 1);
    });

    test('check still failing after retry -> unverified, answer kept', () async {
      final r = await MathSolverClient(apiKey: 'sk', transport: (u, b, k) async => wrongCheck).solve('2x+3=11');
      expect(r.answer, closeTo(4, 1e-9));
      expect(r.verified, false);
      expect(r.retries, 1);
    });
  });

  // HTTP-interface mock: inject an httpPost seam so the DEFAULT transport runs
  // its real code path (URL, headers, body, status, envelope parsing) against
  // synthetic OpenAI-shaped responses. No server, no sockets.
  group('http mock', () {
    (MathSolverClient, List<Map<String, dynamic>>) mocked(String apiKey, List<String> contents, List<int> statuses) {
      final calls = <Map<String, dynamic>>[];
      var n = 0;
      final client = MathSolverClient(
        apiKey: apiKey,
        baseUrl: 'https://mock.test/v1',
        model: 'mock-model',
        httpPost: (url, headers, bodyJson) async {
          final i = n++;
          calls.add({'url': url, 'headers': headers, 'body': jsonDecode(bodyJson)});
          final content = i < contents.length ? contents[i] : good;
          final status = i < statuses.length ? statuses[i] : 200;
          return status >= 300
              ? (status, 'upstream boom')
              : (200, jsonEncode({'choices': [{'message': {'content': content}}]}));
        },
      );
      return (client, calls);
    }

    test('full round trip via default transport', () async {
      final (solver, calls) = mocked('sk-mock', [good], []);
      final r = await solver.solve('2x + 3 = 11, solve for x');
      expect(r.answer, closeTo(4, 1e-9));
      expect(r.verified, true);
      expect(r.retries, 0);
      expect(calls.length, 1);
      expect(calls[0]['url'], 'https://mock.test/v1/chat/completions');
      expect((calls[0]['headers'] as Map)['Authorization'], 'Bearer sk-mock');
      expect(calls[0]['body']['model'], 'mock-model');
      expect(calls[0]['body']['temperature'], 0);
      final messages = calls[0]['body']['messages'] as List;
      expect(messages[0]['role'], 'system');
      expect((messages[0]['content'] as String).contains('STRICT JSON'), true);
    });

    test('check fails -> corrective retry carries reason', () async {
      final (solver, calls) = mocked('sk', [wrongCheck, good], []);
      final r = await solver.solve('2x+3=11');
      expect(r.verified, true);
      expect(r.retries, 1);
      expect(calls.length, 2);
      final messages = calls[1]['body']['messages'] as List;
      expect(messages.any((m) => (m['content'] as String).contains('failed verification')), true);
    });

    test('invalid json -> re-ask -> ok', () async {
      final (solver, calls) = mocked('sk', ['certainly not json', good], []);
      final r = await solver.solve('1+1');
      expect(r.verified, true);
      expect(calls.length, 2);
    });

    test('500 -> HTTP_ERROR no retry', () async {
      final (solver, calls) = mocked('sk', [], [500]);
      await expectLater(solver.solve('1+1'), throwsA(isCode('HTTP_ERROR')));
      expect(calls.length, 1);
    });

    test('401 -> HTTP_ERROR', () async {
      final (solver, _) = mocked('sk-bad', [], [401]);
      await expectLater(solver.solve('1+1'), throwsA(isCode('HTTP_ERROR')));
    });
  });

  test('smoke: real API round-trip', () async {
    final key = Platform.environment['SMOKE_API_KEY'];
    final env = Platform.environment;
    final base = (env['SMOKE_BASE_URL'] == null || env['SMOKE_BASE_URL']!.isEmpty)
        ? 'https://api.openai.com/v1'
        : env['SMOKE_BASE_URL']!;
    final model = (env['SMOKE_MODEL'] == null || env['SMOKE_MODEL']!.isEmpty)
        ? 'gpt-4o-mini'
        : env['SMOKE_MODEL']!;
    final solver = MathSolverClient(apiKey: key!, baseUrl: base, model: model);
    final r = await solver.solve('2x + 3 = 11, solve for x');
    print('smoke: answer=${r.answer} verified=${r.verified} retries=${r.retries}');
    expect(r.verified, true);
    expect(r.answer, 4);
  }, skip: Platform.environment['SMOKE_API_KEY'] == null ? 'smoke: set SMOKE_API_KEY to run' : false);
}
