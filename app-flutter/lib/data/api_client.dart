import 'package:dio/dio.dart';

import '../core/constants.dart';
import 'prediction.dart';

/// `202 Accepted` 본문 (계약 §3).
class BatchAck {
  final String sessionId;
  final int seq;
  final String sessionState;
  final bool duplicate;
  final int serverTime;

  const BatchAck({
    required this.sessionId,
    required this.seq,
    required this.sessionState,
    required this.duplicate,
    required this.serverTime,
  });
}

/// 전송 실패. **[retryable]은 서버가 말해준 값이고 앱이 상태 코드로
/// 추론한 값이 아니다** (계약 §4).
///
/// v3에서 데이터가 소멸한 경로가 정확히 "4xx니까 폐기"라는 추론이었다.
class UploadFailure implements Exception {
  final bool retryable;
  final String code;
  final String detail;
  final int? status;

  const UploadFailure({
    required this.retryable,
    required this.code,
    required this.detail,
    this.status,
  });

  @override
  String toString() =>
      'UploadFailure($code, status=$status, retryable=$retryable): $detail';
}

/// [ApiClient.checkServer] 결과.
class ServerCheck {
  final bool ok;
  final String message;

  /// 실패 원인 원문 (예외 종류·상태 코드). 성공이면 null.
  final String? detail;
  final int elapsedMs;

  const ServerCheck({
    required this.ok,
    required this.message,
    this.detail,
    required this.elapsedMs,
  });
}

/// 수집 게이트웨이(조각 A) 클라이언트.
///
/// ★ 주소는 반드시 받는다. 기본값으로 떨어지는 길이 있으면 설정을 안 읽은
///   호출부가 조용히 옛 주소로 보낸다. 주소는 `ServerConfig.load()`에서 읽는다.
class ApiClient {
  /// ★ Dio를 통째로 주입받지 않고 어댑터만 갈아끼운다.
  ///   주입받으면 테스트가 `validateStatus`를 빠뜨린 Dio를 넘기는 순간
  ///   4xx가 DioException으로 튀어 "재시도 가능"으로 분류된다 - 프로덕션과
  ///   정반대 판정이 테스트에서만 나는 함정이 생긴다.
  ///
  /// ★ [connectTimeout]/[receiveTimeout]을 주지 않으면 수집 경로와 같은 값이다.
  ///   수동 동기화만 짧은 값을 넘긴다 (서버가 꺼져 있을 때 빨리 포기하려고).
  ApiClient({
    required String baseUrl,
    HttpClientAdapter? adapter,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  })  : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout:
              connectTimeout ?? const Duration(milliseconds: K.connectTimeoutMs),
          receiveTimeout:
              receiveTimeout ?? const Duration(milliseconds: K.receiveTimeoutMs),
          contentType: 'application/json; charset=utf-8',
          // ★ 상태 코드로 예외를 던지지 않게 한다. 4xx/5xx 판단을
          //   한곳(_failureFrom)에서만 하기 위해서다.
          validateStatus: (_) => true,
        )) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final Dio _dio;

  String get baseUrl => _dio.options.baseUrl;

  /// 재시작 없이 주소를 바꾼다. 이미 날고 있는 요청은 옛 주소로 끝나고,
  /// 다음 요청부터 새 주소로 간다.
  set baseUrl(String value) => _dio.options.baseUrl = value;

  /// shutdown() 때 진행 중 요청을 정리하는 손잡이 (§6-2 #4).
  final CancelToken _cancel = CancelToken();

  void dispose() {
    if (!_cancel.isCancelled) _cancel.cancel('service shutdown');
  }

  /// DB 행 -> `points[]` 요소. null 필드는 넣지 않는다 (전부 선택 항목).
  static Map<String, Object?> pointJson(Map<String, Object?> row) {
    final m = <String, Object?>{
      'ts': row['ts'],
      'lat': row['lat'],
      'lng': row['lng'],
    };
    if (row['acc'] != null) m['acc'] = row['acc'];
    if (row['spd'] != null) m['spd'] = row['spd'];
    if (row['alt'] != null) m['alt'] = row['alt'];
    // label은 NOT NULL DEFAULT 'NONE'이라 항상 있다. STEP F 정답 라벨이므로
    // 2단계에서도 계속 보낸다 (§2, §14).
    m['label'] = row['label'];
    return m;
  }

  /// `POST /api/v1/sessions/{session_id}/batches`.
  ///
  /// session_id는 경로로만 보낸다. body에는 넣지 않는다.
  ///
  /// `points`가 빈 배열이어도 보낸다 - 마지막 절단 이후 새 좌표가 없을 때
  /// 세션을 닫는 유일하게 깨끗한 방법이다 (§2). 서버는 `is_last_batch: true`일
  /// 때만 빈 배열을 받는다.
  Future<BatchAck> postBatch({
    required String userId,
    required String deviceId,
    required String sessionId,
    required int seq,
    required bool isLast,
    required List<Map<String, Object?>> points,
  }) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/sessions/${Uri.encodeComponent(sessionId)}/batches',
        cancelToken: _cancel,
        data: {
          'user_id': userId,
          'device_id': deviceId,
          'seq': seq,
          'is_last_batch': isLast,
          'sent_at': DateTime.now().millisecondsSinceEpoch,
          'points': points,
        },
      );
    } on DioException catch (e) {
      // 타임아웃 / 연결 거부 / 취소는 전부 재시도 대상이다 (§4).
      throw UploadFailure(
        retryable: true,
        code: e.type.name,
        detail: e.message ?? e.toString(),
      );
    }

    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) throw _failureFrom(res, status);

    // ★ 2xx면 그 배치는 raw_batch에 확실히 있다. 본문이 깨져 있어도
    //   SENT로 넘긴다 (§3). 요약 필드는 응답 매칭·로그용일 뿐이다.
    final body = res.data is Map ? res.data as Map : const {};
    return BatchAck(
      sessionId: (body['session_id'] as String?) ?? sessionId,
      seq: (body['seq'] as num?)?.toInt() ?? seq,
      sessionState:
          (body['session_state'] as String?) ?? RemoteSessionState.active,
      duplicate: body['duplicate'] == true,
      serverTime: (body['server_time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// `GET /api/v1/sessions/{session_id}/predictions`. 판정 화면의 새로고침/최초 진입에서만 부른다.
  ///
  /// 실패는 [UploadFailure]로 던진다. 이름과 달리 여기서는 재시도에 쓰지 않고
  /// `code`(예: SESSION_NOT_FOUND)만 화면이 본다. 응답은 서버가 gzip으로 주고
  /// dart:io HttpClient가 자동으로 푼다.
  Future<PredictionSnapshot> fetchPredictions(String sessionId) async {
    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        '/api/v1/sessions/${Uri.encodeComponent(sessionId)}/predictions',
      );
    } on DioException catch (e) {
      throw UploadFailure(
        retryable: true,
        code: e.type.name,
        detail: e.message ?? e.toString(),
      );
    }
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) throw _failureFrom(res, status);
    if (res.data is! Map) {
      throw UploadFailure(
          retryable: true, code: 'BAD_BODY', detail: '응답 본문이 JSON 객체가 아닙니다', status: status);
    }
    try {
      return PredictionSnapshot.fromJson(
        (res.data as Map).cast<String, dynamic>(),
        fetchedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } on TypeError catch (e) {
      // 필드가 빠졌거나 형이 다르다. 캐시를 깨진 값으로 덮지 않게 여기서 끊는다.
      throw UploadFailure(
          retryable: false, code: 'BAD_BODY', detail: e.toString(), status: status);
    }
  }

  /// 연결 테스트용으로 부르는 없는 세션. 서버는 이 id를 발급하지 않는다 (앱은 UUID v4).
  static const probeSessionId = '00000000-0000-0000-0000-000000000000';

  /// 연결 테스트. 없는 세션의 판정을 조회해 `404 SESSION_NOT_FOUND`가 오는지 본다.
  ///
  /// ★ `/actuator/health`가 아니라 이 경로를 쓰는 이유: 앱이 실제로 쓰는
  ///   `/api/v1/sessions/...` 경로가 열려 있고, 응답이 우리 서버의 오류 형식이며,
  ///   세션 조회까지 DB가 살아 있다는 것을 한 번에 확인한다. 같은 포트의 다른
  ///   서버나 프록시 오류 페이지는 여기서 걸러진다. 서버에 아무것도 쓰지 않는다.
  Future<ServerCheck> checkServer() async {
    final sw = Stopwatch()..start();
    ServerCheck result(bool ok, String message, [String? detail]) => ServerCheck(
        ok: ok, message: message, detail: detail, elapsedMs: sw.elapsedMilliseconds);

    try {
      await fetchPredictions(probeSessionId);
      // 테스트용 id로 세션이 있을 리 없지만, 응답 형식이 맞았으니 API는 살아 있다.
      return result(true, '서버에 연결됐습니다');
    } on UploadFailure catch (e) {
      if (e.code == 'SESSION_NOT_FOUND') return result(true, '서버에 연결됐습니다');
      final raw = e.status == null ? '${e.code}: ${e.detail}' : 'HTTP ${e.status} ${e.code}: ${e.detail}';
      if (e.status == null) {
        switch (e.code) {
          case 'connectionTimeout':
            return result(false, '응답이 없습니다. 주소·포트·방화벽을 확인하세요', raw);
          case 'connectionError':
            return result(false, '연결할 수 없습니다. 서버가 켜져 있는지, 주소가 맞는지 확인하세요', raw);
          case 'badCertificate':
            return result(false, 'HTTPS 인증서를 신뢰할 수 없습니다', raw);
          default:
            return result(false, '서버에 닿지 못했습니다', raw);
        }
      }
      if (e.status! >= 500) return result(false, '서버가 오류를 냈습니다 (DB나 서버 상태 확인)', raw);
      return result(false, '응답은 왔지만 이 앱의 서버가 아닌 것 같습니다', raw);
    }
  }

  UploadFailure _failureFrom(Response<dynamic> res, int status) {
    final body = res.data is Map ? res.data as Map : const {};
    // 서버가 준 retryable이 유일한 판단 근거다. 없을 때만 보수적으로 채운다:
    // 5xx는 본문을 아예 약속하지 않으므로(§4) 재시도, 4xx는 재시도 금지.
    final declared = body['retryable'];
    return UploadFailure(
      retryable: declared is bool ? declared : status >= 500,
      code: (body['error'] as String?) ?? 'HTTP_$status',
      detail: (body['detail'] as String?) ?? 'status $status',
      status: status,
    );
  }
}
