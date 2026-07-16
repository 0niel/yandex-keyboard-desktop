import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_processing_repository.dart';

typedef RetryDelay = Future<void> Function(Duration duration);

final class YandexTextProcessingRepository implements TextProcessingRepository {
  YandexTextProcessingRepository({
    required http.Client client,
    Uri? baseUri,
    TextAssistantRuntimePolicyProvider? policyProvider,
    Duration? requestTimeout,
    RetryDelay retryDelay = _defaultRetryDelay,
  })  : _client = client,
        _baseUri = _validatedBaseUri(
          baseUri ?? Uri.parse('https://keyboard.yandex.net/gpt/'),
        ),
        _policyProvider = policyProvider ??
            FixedTextAssistantRuntimePolicyProvider(
              requestTimeout == null
                  ? const TextAssistantRuntimePolicy.defaults()
                  : TextAssistantRuntimePolicy(
                      requestTimeout: requestTimeout,
                      retryAttempts: 0,
                      restoreOriginalClipboard: true,
                      defaultAction: TextAction.rewrite,
                    ),
            ),
        _retryDelay = retryDelay;

  static const int maximumRequestBytes = 64 * 1024;
  static const int maximumResponseBytes = 128 * 1024;

  final http.Client _client;
  final Uri _baseUri;
  final TextAssistantRuntimePolicyProvider _policyProvider;
  final RetryDelay _retryDelay;

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) async {
    final token = cancellationToken ?? TextProcessingCancellationToken();
    _throwIfCancelled(token);
    final requestBody = Uint8List.fromList(
      utf8.encode(jsonEncode({'text': text})),
    );
    if (requestBody.length > maximumRequestBytes) {
      throw const TextProcessingException(
        kind: TextProcessingFailureKind.inputTooLarge,
        diagnosticCode: 'transform_input_too_large',
      );
    }

    final operationPolicy = policy ?? _policyProvider.current;
    final elapsed = Stopwatch()..start();
    for (var attempt = 0; attempt <= operationPolicy.retryAttempts; attempt++) {
      _throwIfCancelled(token);
      try {
        return await _processOnce(
          requestBody: requestBody,
          action: action,
          requestTimeout: operationPolicy.requestTimeout,
          elapsed: elapsed,
          cancellationToken: token,
        );
      } on TextProcessingException catch (error) {
        if (attempt == operationPolicy.retryAttempts || !_isRetryable(error)) {
          rethrow;
        }
        await _waitBeforeRetry(
          Duration(milliseconds: 150 * (1 << attempt)),
          requestTimeout: operationPolicy.requestTimeout,
          elapsed: elapsed,
          cancellationToken: token,
        );
      }
    }
    // coverage:ignore-start
    throw StateError('The bounded retry loop must return or throw.');
    // coverage:ignore-end
  }

  Future<String> _processOnce({
    required Uint8List requestBody,
    required TextAction action,
    required Duration requestTimeout,
    required Stopwatch elapsed,
    required TextProcessingCancellationToken cancellationToken,
  }) async {
    final remaining = _remaining(requestTimeout, elapsed);
    final abort = _RequestAbortSignal(
      cancellationToken: cancellationToken,
      timeout: remaining,
    );
    try {
      final endpoint = _baseUri.resolve(_pathFor(action));
      final request = http.AbortableRequest(
        'POST',
        endpoint,
        abortTrigger: abort.trigger,
      )
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll(const {
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
        })
        ..bodyBytes = requestBody;

      final response = await abort.race(_client.send(request));
      final responseUri = response.request?.url;
      if (responseUri != null && !_sameOrigin(responseUri, _baseUri)) {
        abort.abortTransport();
        throw const TextProcessingException(
          kind: TextProcessingFailureKind.invalidResponse,
          diagnosticCode: 'transform_response_origin_invalid',
        );
      }
      if (response.isRedirect ||
          (response.statusCode >= 300 && response.statusCode < 400)) {
        abort.abortTransport();
        throw TextProcessingException(
          kind: TextProcessingFailureKind.rejected,
          diagnosticCode: 'transform_redirect_rejected',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode != 200) {
        abort.abortTransport();
        throw TextProcessingException(
          kind: TextProcessingFailureKind.rejected,
          diagnosticCode: 'transform_http_rejected',
          statusCode: response.statusCode,
        );
      }
      if ((response.contentLength ?? 0) > maximumResponseBytes) {
        const error = TextProcessingException(
          kind: TextProcessingFailureKind.responseTooLarge,
          diagnosticCode: 'transform_response_too_large',
        );
        abort.fail(error);
        throw error;
      }

      final responseBytes = await abort.race(
        _readBoundedResponse(response.stream, abort),
      );
      _throwIfCancelled(cancellationToken);
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object.');
      }
      final transformed = decoded['response'];
      if (transformed is! String || transformed.trim().isEmpty) {
        throw const FormatException('Missing transformed text.');
      }
      return transformed;
    } on TextProcessingException {
      rethrow;
    } on http.RequestAbortedException {
      throw abort.failure ??
          const TextProcessingException(
            kind: TextProcessingFailureKind.network,
            diagnosticCode: 'transform_request_aborted',
          );
    } on TimeoutException {
      throw const TextProcessingException(
        kind: TextProcessingFailureKind.timeout,
        diagnosticCode: 'transform_timeout',
      );
    } on http.ClientException {
      throw const TextProcessingException(
        kind: TextProcessingFailureKind.network,
        diagnosticCode: 'transform_network_error',
      );
    } on FormatException {
      throw const TextProcessingException(
        kind: TextProcessingFailureKind.invalidResponse,
        diagnosticCode: 'transform_invalid_response',
      );
    } finally {
      abort.dispose();
    }
  }

  Future<Uint8List> _readBoundedResponse(
    Stream<List<int>> stream,
    _RequestAbortSignal abort,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maximumResponseBytes) {
        const error = TextProcessingException(
          kind: TextProcessingFailureKind.responseTooLarge,
          diagnosticCode: 'transform_response_too_large',
        );
        abort.fail(error);
        throw error;
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _waitBeforeRetry(
    Duration duration, {
    required Duration requestTimeout,
    required Stopwatch elapsed,
    required TextProcessingCancellationToken cancellationToken,
  }) async {
    _throwIfCancelled(cancellationToken);
    final remaining = _remaining(requestTimeout, elapsed);
    await Future.any<void>([
      _retryDelay(duration),
      cancellationToken.whenCancelled.then<void>((_) {
        throw const TextProcessingException(
          kind: TextProcessingFailureKind.cancelled,
          diagnosticCode: 'transform_cancelled',
        );
      }),
    ]).timeout(
      remaining,
      onTimeout: () => throw const TextProcessingException(
        kind: TextProcessingFailureKind.timeout,
        diagnosticCode: 'transform_timeout',
      ),
    );
  }

  Duration _remaining(Duration timeout, Stopwatch elapsed) {
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw const TextProcessingException(
        kind: TextProcessingFailureKind.timeout,
        diagnosticCode: 'transform_timeout',
      );
    }
    return remaining;
  }

  void _throwIfCancelled(TextProcessingCancellationToken token) {
    if (token.isCancelled) {
      throw const TextProcessingException(
        kind: TextProcessingFailureKind.cancelled,
        diagnosticCode: 'transform_cancelled',
      );
    }
  }

  bool _isRetryable(TextProcessingException error) =>
      error.kind == TextProcessingFailureKind.rejected &&
      error.diagnosticCode == 'transform_http_rejected' &&
      ((error.statusCode ?? 0) >= 500 || error.statusCode == 408);

  String _pathFor(TextAction action) => switch (action) {
        TextAction.emojify => 'emoji',
        TextAction.rewrite => 'rewrite',
        TextAction.fix => 'fix',
      };
}

final class _RequestAbortSignal {
  _RequestAbortSignal({
    required TextProcessingCancellationToken cancellationToken,
    required Duration timeout,
  }) {
    _timer = Timer(timeout, () {
      fail(const TextProcessingException(
        kind: TextProcessingFailureKind.timeout,
        diagnosticCode: 'transform_timeout',
      ));
    });
    unawaited(cancellationToken.whenCancelled.then((_) {
      fail(const TextProcessingException(
        kind: TextProcessingFailureKind.cancelled,
        diagnosticCode: 'transform_cancelled',
      ));
    }));
  }

  final Completer<void> _abort = Completer<void>();
  final Completer<TextProcessingException> _failed =
      Completer<TextProcessingException>();
  Timer? _timer;
  TextProcessingException? failure;

  Future<void> get trigger => _abort.future;

  Future<T> race<T>(Future<T> operation) => Future.any<T>([
        operation,
        _failed.future.then<T>((error) => throw error),
      ]);

  void fail(TextProcessingException error) {
    failure ??= error;
    if (!_abort.isCompleted) _abort.complete();
    if (!_failed.isCompleted) _failed.complete(error);
  }

  void abortTransport() {
    if (!_abort.isCompleted) _abort.complete();
  }

  void dispose() => _timer?.cancel();
}

Uri _validatedBaseUri(Uri value) {
  if (value.scheme.toLowerCase() != 'https' ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.hasQuery ||
      value.hasFragment) {
    throw ArgumentError('A private HTTPS origin is required.');
  }
  final path = value.path.endsWith('/') ? value.path : '${value.path}/';
  return value.replace(path: path);
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    _effectivePort(left) == _effectivePort(right);

int _effectivePort(Uri value) => value.hasPort ? value.port : 443;

Future<void> _defaultRetryDelay(Duration duration) =>
    Future<void>.delayed(duration);
