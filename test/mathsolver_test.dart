import 'dart:io' show Platform;
import 'package:mathsolver/mathsolver.dart';
import 'package:test/test.dart';

const good = '{"answer": 4, "steps": ["Subtract 3: 2x = 8", "Divide by 2: x = 4"], "verification": {"expression": "(11-3)/2"}}';
const wrong = '{"answer": 4, "steps": ["..."], "verification": {"expression": "(11-3)/3"}}';

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
    test('rejects bad input', () {
      for (final bad in ['Process.run("x")', '1+2)', 'foo(1)', '']) {
        expect(() => evalExpression(bad), throwsA(isA<SolverException>()));
      }
    });
  });

  group('solve', () {
    test('verified first try', () async {
      var calls = 0;
      String? seenUrl, seenKey;
      final solver = MathSolverClient(apiKey: 'sk-test', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat', transport: (url, body, key) async {
        calls++;
        seenUrl = url; seenKey = key;
        return good;
      });
      final r = await solver.solve('2x + 3 = 11, solve for x');
      expect(r.verified, true);
      expect(r.retries, 0);
      expect(r.evaluated, 4);
      expect(calls, 1);
      expect(seenUrl, 'https://api.deepseek.com/v1/chat/completions');
      expect(seenKey, 'sk-test');
    });

    test('retry recovers', () async {
      var n = 0;
      final r = await MathSolverClient(apiKey: 'sk', transport: (u, b, k) async {
        n++;
        return n == 1 ? wrong : good;
      }).solve('2x+3=11');
      expect(r.verified, true);
      expect(r.retries, 1);
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
        throwsA(predicate((e) => e is SolverException && e.code == 'INVALID_JSON')),
      );
    });

    test('no api key throws at construction', () {
      expect(
        () => MathSolverClient(apiKey: '').solve('1+1'),
        throwsA(predicate((e) => e is SolverException && e.code == 'NO_API_KEY')),
      );
    });

    test('http error no retry', () async {
      var calls = 0;
      await expectLater(
        MathSolverClient(apiKey: 'sk', transport: (u, b, k) async {
          calls++;
          throw const SolverException('HTTP_ERROR', '401');
        }).solve('1+1'),
        throwsA(predicate((e) => e is SolverException && e.code == 'HTTP_ERROR')),
      );
      expect(calls, 1);
    });

    test('still wrong unverified', () async {
      final r = await MathSolverClient(apiKey: 'sk', transport: (u, b, k) async => wrong).solve('2x+3=11');
      expect(r.verified, false);
      expect(r.retries, 1);
    });
  });

  test('smoke: real API round-trip', () async {
    final key = Platform.environment['SMOKE_API_KEY'];
    final base = Platform.environment['SMOKE_BASE_URL'] ?? 'https://api.openai.com/v1';
    final solver = MathSolverClient(apiKey: key!, baseUrl: base);
    final r = await solver.solve('2x + 3 = 11, solve for x');
    print('smoke: answer=${r.answer} verified=${r.verified} retries=${r.retries}');
    expect(r.verified, true);
    expect(r.answer, 4);
  }, skip: Platform.environment['SMOKE_API_KEY'] == null ? 'smoke: set SMOKE_API_KEY to run' : false);
});
