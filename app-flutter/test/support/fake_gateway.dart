import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 조각 A 흉내. dio의 어댑터만 갈아끼워 실제 ApiClient 코드를 그대로 통과시킨다.
///
/// 상태 코드 해석·retryable 판정 같은 판단이 ApiClient 안에 있으므로,
/// 여기서 응답만 정해 주면 그 판단이 진짜로 검증된다.
class FakeGateway implements HttpClientAdapter {
  FakeGateway({this.state = 'ACTIVE'});

  /// 받은 요청 본문. 순서대로 쌓인다.
  ///
  /// ★ `session_id`는 본문이 아니라 **경로**에서 뽑아 채워 넣은 값이다.
  ///   본문에 `session_id`가 있으면 계약 위반이라 [fetch]가 바로 던진다.
  final List<Map<String, dynamic>> requests = [];

  /// 받은 요청 경로. [requests]와 같은 순서.
  final List<String> paths = [];

  static final _batchPath = RegExp(r'^/api/v1/sessions/([^/]+)/batches$');

  /// 기본 응답에 실을 session_state.
  String state;

  /// 지정하면 이 함수가 (상태코드, 본문)을 정한다.
  (int, Map<String, Object?>)? Function(Map<String, dynamic> req)? responder;

  /// 지정하면 전송 자체가 실패한다 (타임아웃/연결 거부 흉내).
  DioExceptionType? transportError;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    final req = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final m = _batchPath.firstMatch(options.uri.path);
    if (m == null) {
      throw StateError('계약에 없는 경로: ${options.method} ${options.uri.path}');
    }
    if (req.containsKey('session_id')) {
      throw StateError('session_id는 경로로만 보내야 한다: $req');
    }
    req['session_id'] = Uri.decodeComponent(m.group(1)!);
    paths.add(options.uri.path);
    requests.add(req);

    if (transportError != null) {
      throw DioException(
          requestOptions: options,
          type: transportError!,
          message: 'fake transport failure');
    }

    final custom = responder?.call(req);
    final status = custom?.$1 ?? 202;
    final body = custom?.$2 ??
        <String, Object?>{
          'session_id': req['session_id'],
          'seq': req['seq'],
          'session_state': state,
          'duplicate': false,
          'server_time': DateTime.now().millisecondsSinceEpoch,
        };

    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
