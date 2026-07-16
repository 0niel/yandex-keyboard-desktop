import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/data/yandex_text_processing_repository.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_processing_repository.dart';

void main() {
  group('YandexTextProcessingRepository', () {
    test('sends UTF-8 text to the action endpoint', () async {
      late http.Request captured;
      final repository = YandexTextProcessingRepository(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({'response': 'Привет 👋 مرحبا'}),
            200,
            request: request,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final result = await repository.process(
        text: 'Привет مرحبا',
        action: TextAction.emojify,
      );

      expect(captured.url.path, '/gpt/emoji');
      expect(jsonDecode(captured.body), {'text': 'Привет مرحبا'});
      expect(result, 'Привет 👋 مرحبا');
    });

    test('returns a typed failure for a rejected request', () async {
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async => http.Response('nope', 429)),
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>()
              .having(
                (error) => error.kind,
                'kind',
                TextProcessingFailureKind.rejected,
              )
              .having((error) => error.statusCode, 'statusCode', 429)
              .having(
                (error) => error.toString(),
                'safe diagnostic',
                isNot(contains('private text')),
              ),
        ),
      );
    });

    test('returns a typed failure for malformed JSON', () async {
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async => http.Response('{', 200)),
      );

      await expectLater(
        repository.process(text: 'text', action: TextAction.rewrite),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.invalidResponse,
          ),
        ),
      );
    });

    test('rejects non-object and empty transformation responses', () async {
      for (final body in [
        jsonEncode(['not', 'an', 'object']),
        jsonEncode({'response': 42}),
        jsonEncode({'response': '   '}),
      ]) {
        final repository = YandexTextProcessingRepository(
          client: MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(
          repository.process(text: 'text', action: TextAction.rewrite),
          throwsA(
            isA<TextProcessingException>().having(
              (error) => error.kind,
              'kind',
              TextProcessingFailureKind.invalidResponse,
            ),
          ),
        );
      }
    });

    test('rejects a response attributed to another origin', () async {
      final repository = YandexTextProcessingRepository(
        baseUri: Uri.parse('https://keyboard.example:8443/gpt/'),
        client: MockClient.streaming((_, __) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'response': 'unsafe'}))),
            200,
            request: http.Request(
              'POST',
              Uri.parse('https://keyboard.example:9443/private'),
            ),
          );
        }),
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.diagnosticCode,
            'diagnosticCode',
            'transform_response_origin_invalid',
          ),
        ),
      );
    });

    test('maps an unexplained client abort to a safe network failure',
        () async {
      final repository = YandexTextProcessingRepository(
        client: MockClient.streaming((request, _) async {
          throw http.RequestAbortedException(request.url);
        }),
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>()
              .having(
                (error) => error.kind,
                'kind',
                TextProcessingFailureKind.network,
              )
              .having(
                (error) => error.diagnosticCode,
                'diagnosticCode',
                'transform_request_aborted',
              ),
        ),
      );
    });

    test('maps an adapter timeout without retrying an uncertain POST',
        () async {
      var calls = 0;
      final repository = YandexTextProcessingRepository(
        client: MockClient.streaming((_, __) async {
          calls++;
          throw TimeoutException('adapter timeout');
        }),
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.timeout,
          ),
        ),
      );
      expect(calls, 1);
    });

    test('rejects an expired deadline before opening the network', () async {
      var calls = 0;
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode({'response': 'unused'}), 200);
        }),
        requestTimeout: Duration.zero,
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.timeout,
          ),
        ),
      );
      expect(calls, 0);
    });

    test('rejects a token cancelled before processing starts', () async {
      var calls = 0;
      final token = TextProcessingCancellationToken()..cancel();
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode({'response': 'unused'}), 200);
        }),
      );

      await expectLater(
        repository.process(
          text: 'private text',
          action: TextAction.fix,
          cancellationToken: token,
        ),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.cancelled,
          ),
        ),
      );
      expect(calls, 0);
    });

    test('applies a bounded request timeout', () async {
      final never = Completer<http.Response>();
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) => never.future),
        requestTimeout: const Duration(milliseconds: 1),
      );

      await expectLater(
        repository.process(text: 'text', action: TextAction.rewrite),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.timeout,
          ),
        ),
      );
    });

    test('never retries an unconfirmed timed-out POST', () async {
      var calls = 0;
      final never = Completer<http.Response>();
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) {
          calls++;
          return never.future;
        }),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(milliseconds: 1),
            retryAttempts: 8,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.rewrite,
          ),
        ),
        retryDelay: (_) async {},
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.rewrite),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.timeout,
          ),
        ),
      );
      expect(calls, 1);
    });

    test('never retries an uncertain transport failure', () async {
      var calls = 0;
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          throw http.ClientException('connection lost');
        }),
        retryDelay: (_) async {},
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.network,
          ),
        ),
      );
      expect(calls, 1);
    });

    test('retries transient failures using the configured bounded policy',
        () async {
      var calls = 0;
      final delays = <Duration>[];
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          if (calls < 3) return http.Response('temporary', 503);
          return http.Response(jsonEncode({'response': 'done'}), 200);
        }),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 1),
            retryAttempts: 2,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.rewrite,
          ),
        ),
        retryDelay: (duration) async => delays.add(duration),
      );

      expect(
        await repository.process(text: 'text', action: TextAction.rewrite),
        'done',
      );
      expect(calls, 3);
      expect(
        delays,
        const [Duration(milliseconds: 150), Duration(milliseconds: 300)],
      );
    });

    test('uses the production retry delay for a confirmed server rejection',
        () async {
      var calls = 0;
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('temporary', 503)
              : http.Response(jsonEncode({'response': 'done'}), 200);
        }),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 1),
            retryAttempts: 1,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.rewrite,
          ),
        ),
      );

      expect(
        await repository.process(text: 'text', action: TextAction.rewrite),
        'done',
      );
      expect(calls, 2);
    });

    test('does not retry a non-transient rejected request', () async {
      var calls = 0;
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          return http.Response('bad request', 400);
        }),
        retryDelay: (_) async {},
      );

      await expectLater(
        repository.process(text: 'text', action: TextAction.fix),
        throwsA(isA<TextProcessingException>()),
      );
      expect(calls, 1);
    });

    test('reads the shared live policy at the start of every request',
        () async {
      var calls = 0;
      final policyProvider = MutableTextAssistantRuntimePolicyProvider(
        initial: const TextAssistantRuntimePolicy(
          requestTimeout: Duration(seconds: 1),
          retryAttempts: 0,
          restoreOriginalClipboard: true,
          defaultAction: TextAction.rewrite,
        ),
      );
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          if (calls == 1 || calls == 2) {
            return http.Response('temporary', 503);
          }
          return http.Response(jsonEncode({'response': 'done'}), 200);
        }),
        policyProvider: policyProvider,
        retryDelay: (_) async {},
      );

      await expectLater(
        repository.process(text: 'first', action: TextAction.fix),
        throwsA(isA<TextProcessingException>()),
      );
      policyProvider.replace(const TextAssistantRuntimePolicy(
        requestTimeout: Duration(seconds: 1),
        retryAttempts: 1,
        restoreOriginalClipboard: false,
        defaultAction: TextAction.fix,
      ));

      expect(
        await repository.process(text: 'second', action: TextAction.fix),
        'done',
      );
      expect(calls, 3);
    });

    test('delivers user cancellation to the HTTP client without retrying',
        () async {
      final client = _AbortObservingClient();
      final token = TextProcessingCancellationToken();
      final repository = YandexTextProcessingRepository(
        client: client,
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 8,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.rewrite,
          ),
        ),
        retryDelay: (_) async {},
      );

      final operation = repository.process(
        text: 'private text',
        action: TextAction.rewrite,
        cancellationToken: token,
      );
      await client.started.future;
      token.cancel();

      await expectLater(
        operation,
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.cancelled,
          ),
        ),
      );
      await client.aborted.future;
      expect(client.calls, 1);
    });

    test('aborts the transport when the total deadline expires', () async {
      final client = _AbortObservingClient();
      final repository = YandexTextProcessingRepository(
        client: client,
        requestTimeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.timeout,
          ),
        ),
      );
      await client.aborted.future;
      expect(client.calls, 1);
    });

    test('the total deadline includes retry backoff', () async {
      var calls = 0;
      final retryStarted = Completer<void>();
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          return http.Response('temporary', 503);
        }),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(milliseconds: 5),
            retryAttempts: 8,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.rewrite,
          ),
        ),
        retryDelay: (_) {
          if (!retryStarted.isCompleted) retryStarted.complete();
          return Completer<void>().future;
        },
      );

      final operation = repository.process(
        text: 'private text',
        action: TextAction.rewrite,
      );
      await retryStarted.future;
      await expectLater(
        operation,
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.timeout,
          ),
        ),
      );
      expect(calls, 1);
    });

    test('cancels retry backoff before another request can start', () async {
      var calls = 0;
      final retryStarted = Completer<void>();
      final token = TextProcessingCancellationToken();
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          return http.Response('temporary', 503);
        }),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 8,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.rewrite,
          ),
        ),
        retryDelay: (_) {
          if (!retryStarted.isCompleted) retryStarted.complete();
          return Completer<void>().future;
        },
      );

      final operation = repository.process(
        text: 'private text',
        action: TextAction.rewrite,
        cancellationToken: token,
      );
      await retryStarted.future;
      token.cancel();

      await expectLater(
        operation,
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.cancelled,
          ),
        ),
      );
      expect(calls, 1);
    });

    test('rejects oversized encoded input before opening the network',
        () async {
      var calls = 0;
      final repository = YandexTextProcessingRepository(
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode({'response': 'unused'}), 200);
        }),
      );

      await expectLater(
        repository.process(
          text: List.filled(
            YandexTextProcessingRepository.maximumRequestBytes,
            'x',
          ).join(),
          action: TextAction.fix,
        ),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.inputTooLarge,
          ),
        ),
      );
      expect(calls, 0);
    });

    test('bounds an unknown-length streamed response', () async {
      final repository = YandexTextProcessingRepository(
        client: MockClient.streaming((_, __) async {
          return http.StreamedResponse(
            Stream.value(
              List.filled(
                YandexTextProcessingRepository.maximumResponseBytes + 1,
                0x61,
              ),
            ),
            200,
          );
        }),
      );

      await expectLater(
        repository.process(text: 'text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.responseTooLarge,
          ),
        ),
      );
    });

    test('rejects an oversized declared response before reading it', () async {
      var listened = false;
      final repository = YandexTextProcessingRepository(
        client: MockClient.streaming((_, __) async {
          return http.StreamedResponse(
            Stream<List<int>>.multi((controller) {
              listened = true;
              controller.close();
            }),
            200,
            contentLength:
                YandexTextProcessingRepository.maximumResponseBytes + 1,
          );
        }),
      );

      await expectLater(
        repository.process(text: 'text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>().having(
            (error) => error.kind,
            'kind',
            TextProcessingFailureKind.responseTooLarge,
          ),
        ),
      );
      expect(listened, isFalse);
    });

    test('disables redirects and reports them without following', () async {
      late http.BaseRequest captured;
      final repository = YandexTextProcessingRepository(
        client: MockClient.streaming((request, _) async {
          captured = request;
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            isRedirect: true,
            headers: {'location': 'https://other.example/private'},
          );
        }),
      );

      await expectLater(
        repository.process(text: 'private text', action: TextAction.fix),
        throwsA(
          isA<TextProcessingException>()
              .having(
                (error) => error.diagnosticCode,
                'diagnosticCode',
                'transform_redirect_rejected',
              )
              .having((error) => error.statusCode, 'statusCode', 302),
        ),
      );
      expect(captured.followRedirects, isFalse);
      expect(captured.maxRedirects, 0);
    });

    test('rejects non-private endpoint configurations', () {
      for (final uri in [
        Uri.parse('http://keyboard.example/gpt/'),
        Uri.parse('https://user:secret@keyboard.example/gpt/'),
        Uri.parse('https://keyboard.example/gpt/?token=secret'),
        Uri.parse('https://keyboard.example/gpt/#fragment'),
      ]) {
        expect(
          () => YandexTextProcessingRepository(
            client: MockClient((_) async => http.Response('', 500)),
            baseUri: uri,
          ),
          throwsArgumentError,
        );
      }
    });
  });
}

final class _AbortObservingClient extends http.BaseClient {
  final Completer<void> started = Completer<void>();
  final Completer<void> aborted = Completer<void>();
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    if (!started.isCompleted) started.complete();
    final abortable = request as http.Abortable;
    await abortable.abortTrigger;
    if (!aborted.isCompleted) aborted.complete();
    throw http.RequestAbortedException(request.url);
  }
}
