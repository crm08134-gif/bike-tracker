import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../data/api_client.dart';
import '../data/app_db.dart';

/// 배치 절단 + 전송 루프.
///
/// ★ 전부 **서비스 isolate**에서 돈다 (§6-1 제약 3). UI isolate에서 큐를
///   돌리면 "수집 중 DB 쓰기는 서비스만" 규칙이 깨진다.
///
/// ★ 좌표를 복사하지 않는다. 배치는 `[from_ts, to_ts)` 구간만 잡고,
///   전송 직전에 그 구간을 points에서 다시 읽는다 (§9-1).
class Uploader {
  Uploader({
    required this.userId,
    required this.deviceId,
    required String sessionId,
    required this.onSessionSwitch,
    required this.flushBuffer,
    required this.onLog,
    required ApiClient api,
  })  : _sessionId = sessionId,
        _api = api;

  final String userId;
  final String deviceId;

  /// ★ 서비스가 서버 주소를 읽어 만들어 넘긴다. 주소 변경은 서비스가 이
  ///   객체의 `baseUrl`을 바꿔서 반영한다 - 업로더는 주소를 모른다.
  final ApiClient _api;

  /// 새 session_id를 발급했을 때 서비스에 알린다. 서비스는 sessions 행 생성 +
  /// prefs 갱신 + 자신의 sessionId 교체를 한다.
  final Future<void> Function(String oldId, String newId) onSessionSwitch;

  /// 서비스의 메모리 버퍼를 DB로 내린다.
  ///
  /// ★ 절단 전에 반드시 부른다. 배치는 DB의 구간을 가리키는데 그 구간의
  ///   좌표가 아직 버퍼에 있으면 빈 배치가 나가고, 좌표는 어느 배치에도
  ///   안 잡힌 채 남는다.
  final Future<void> Function() flushBuffer;

  final void Function(String message) onLog;

  String _sessionId;
  String get sessionId => _sessionId;

  /// 열린 창의 시작. null이면 아직 이 세션의 좌표를 하나도 못 봤다.
  int? _openFrom;

  /// 미전송 배치 수 캐시 (§9-5 절단 보류 판정).
  int _unsent = 0;
  int get queuedBatches => _unsent;

  // ── 집계 (수동 동기화의 진행 표시·종료 판정용) ──────────
  //
  // ★ 전송 판단에는 쓰지 않는다. 세기만 한다. 이 객체가 사는 동안의 누계다.
  int _sent = 0;
  int _failed = 0;
  int _dead = 0;
  UploadFailure? _lastFailure;

  /// 202를 받은 배치 수 (duplicate 포함).
  int get sentCount => _sent;

  /// 재시도로 넘긴 실패 수. 연결 실패·5xx·타임아웃이 여기 들어간다.
  int get failedCount => _failed;

  /// 서버가 재시도 불가라고 답해 DEAD로 끝난 배치 수.
  int get deadCount => _dead;

  /// 마지막 실패. 화면에 이유를 보여줄 때 쓴다.
  UploadFailure? get lastFailure => _lastFailure;

  /// 날고 있는 요청. 키는 `session_id#seq`. 종료·테스트에서 기다릴 수 있게
  /// Future를 들고 있는다.
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};
  bool _abandonSwitchInProgress = false;
  bool _disposed = false;

  /// ★ 절단 재진입 가드. 티커 콜백이 async라 한 틱이 1초를 넘기면 다음 틱이
  ///   겹쳐 들어온다. 겹치면 두 호출이 같은 `_openFrom`을 보고 같은 구간을
  ///   각각 다른 seq로 자른다 - 서버 dedup은 (session_id, seq) 기준이라
  ///   이 중복을 못 잡고 같은 좌표가 두 번 적재된다.
  bool _cutting = false;

  static const _uuid = Uuid();
  final Random _rng = Random();

  Future<void> init() async {
    _openFrom = await AppDb.firstUncutTs(_sessionId);
    _unsent = await AppDb.countUnsentBatches();
    if (_unsent > 0) {
      // 이전 세션의 백로그도 여기 포함된다. 큐 조회는 세션으로 거르지 않는다.
      onLog('업로드 큐 이어받음: 미전송 $_unsent건');
    }
  }

  /// 좌표가 워터마크를 통과해 버퍼에 들어간 직후 호출한다.
  /// 세션의 첫 좌표가 열린 창의 시작을 정한다.
  void notePoint(int ts) => _openFrom ??= ts;

  // ── 절단 (§9-5) ─────────────────────────────────────────

  /// 1초 티커에서 호출.
  Future<void> maybeCut({required int lastAcceptedTs}) async {
    if (_cutting) return;
    final from = _openFrom;
    if (from == null) return;
    if (lastAcceptedTs - from < K.batchWindowMs) return;

    if (_unsent >= K.maxQueuedBatches) {
      // ★ 아무것도 버리지 않는다. 절단만 멈춘다 (§9-5). 좌표는 계속
      //   points에 쌓이고, 큐가 빠지면 밀린 구간을 여러 배치로 이어서 자른다.
      return;
    }

    _cutting = true;
    try {
      await flushBuffer();
      // ★ 반열린 구간이라 to_ts와 같은 ts를 가진 좌표는 이번 배치에 들어가지
      //   않고 다음 창의 첫 좌표가 된다. 경계 좌표가 두 배치에 모두 들어가면
      //   서버 dedup(seq 기준)이 못 잡고 dt == 0 -> inf 속도를 만든다.
      await _cut(toTs: lastAcceptedTs, isLast: false);
    } finally {
      _cutting = false;
    }
  }

  /// 사용자 종료. 마지막 좌표까지 포함해 자르고 `is_last`를 세운다.
  Future<void> cutFinal({required int? lastAcceptedTs}) async {
    await flushBuffer();
    final from = _openFrom;
    if (from == null || lastAcceptedTs == null) {
      // 좌표를 한 번도 못 받고 끝난 세션. 빈 구간으로 종료 신호만 보낸다.
      // 서버는 points: [] + is_last_batch: true를 받아 세션을 CLOSED로 닫는다.
      final now = DateTime.now().millisecondsSinceEpoch;
      await _cut(toTs: now, isLast: true, forceFrom: now);
      return;
    }
    // +1: 반열린 구간이므로 마지막 좌표를 넣으려면 경계를 하나 넘겨야 한다.
    await _cut(toTs: lastAcceptedTs + 1, isLast: true);
  }

  Future<void> _cut({
    required int toTs,
    required bool isLast,
    int? forceFrom,
  }) async {
    var from = forceFrom ?? _openFrom;
    if (from == null) return;
    if (toTs < from) toTs = from;

    var count =
        await AppDb.countPointsRange(_sessionId, fromTs: from, toTs: toTs);

    // ★ 1Hz면 30초 창에 30점이라 걸릴 일이 없다. 그래도 두는 이유는
    //   초과 시 서버가 413 {retryable:false}를 주고, 그 배치는 DEAD로
    //   끝나 좌표가 조용히 사라지기 때문이다. 쪼개서 전부 내보낸다.
    while (count > K.maxPointsPerBatch) {
      final boundary = await AppDb.pointTsAtOffset(
        _sessionId,
        fromTs: from!,
        toTs: toTs,
        offset: K.maxPointsPerBatch,
      );
      if (boundary == null || boundary <= from) break;
      onLog('창 초과($count점) - [$from,$boundary) 로 쪼갬');
      await _insert(
          from: from, to: boundary, count: K.maxPointsPerBatch, isLast: false);
      from = boundary;
      count = await AppDb.countPointsRange(_sessionId, fromTs: from, toTs: toTs);
    }

    await _insert(from: from!, to: toTs, count: count, isLast: isLast);
  }

  Future<void> _insert({
    required int from,
    required int to,
    required int count,
    required bool isLast,
  }) async {
    final seq = await AppDb.insertBatch(
      sessionId: _sessionId,
      fromTs: from,
      toTs: to,
      pointCount: count,
      isLast: isLast,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _openFrom = to;
    _unsent++;
    onLog('절단 seq=$seq [$from,$to) $count점${isLast ? " is_last" : ""}');
  }

  // ── 전송 루프 (§9-6) ────────────────────────────────────

  /// 1초 티커에서 호출. 비어 있는 동시 전송 슬롯을 채운다.
  /// 새로 띄운 요청 수를 돌려준다 (0이면 지금 보낼 게 없다는 뜻).
  Future<int> pump() async {
    if (_disposed) return 0;
    if (_inFlight.length >= K.maxConcurrentUploads) return 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    // 이미 날고 있는 행이 조회 결과를 다 차지하지 않도록 넉넉히 뽑는다.
    final rows =
        await AppDb.dueBatches(now: now, limit: K.maxConcurrentUploads * 2);

    var started = 0;
    for (final row in rows) {
      if (_disposed) break;
      if (_inFlight.length >= K.maxConcurrentUploads) break;
      final key = '${row['session_id']}#${row['seq']}';
      if (_inFlight.containsKey(key)) continue;
      // ★ 중괄호를 쓴다. `() => _inFlight.remove(key)`로 쓰면 Map.remove가
      //   방금 담은 Future를 반환하고, whenComplete는 콜백이 돌려준 Future를
      //   기다리므로 그 Future가 자기 자신을 기다리는 교착이 된다.
      _inFlight[key] = _send(row).whenComplete(() {
        _inFlight.remove(key);
      });
      started++;
    }
    return started;
  }

  /// 슬롯을 채우고 지금 날고 있는 요청이 끝날 때까지 기다린다.
  Future<void> pumpAndWait() async {
    await pump();
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.values.toList());
    }
  }

  Future<void> _send(Map<String, Object?> row) async {
    final sid = row['session_id'] as String;
    final seq = row['seq'] as int;
    final from = row['from_ts'] as int;
    final to = row['to_ts'] as int;
    final expected = row['point_count'] as int;
    final isLast = (row['is_last'] as int) == 1;
    final retryCount = row['retry_count'] as int;

    final points = await AppDb.readPointsRange(sid, fromTs: from, toTs: to);

    // ★ C-3 탐지선. 좌표를 복사하지 않으므로 재전송 페이로드가 첫 전송과
    //   달라질 수 있다. 워터마크가 막고 있어야 정상이고, 여기 걸렸다면
    //   워터마크가 뚫렸다는 신호다. 전송 자체는 막지 않는다.
    if (points.length != expected) {
      onLog('!! 페이로드 뒤바뀜 $sid#$seq: 절단 $expected점 -> 전송 ${points.length}점');
    }

    try {
      final ack = await _api.postBatch(
        userId: userId,
        deviceId: deviceId,
        sessionId: sid,
        seq: seq,
        isLast: isLast,
        points: points.map(ApiClient.pointJson).toList(),
      );

      // 202면 raw_batch에 확실히 있다. duplicate 여부와 무관하게 SENT다 (§3).
      await AppDb.markBatchSent(
          sid, seq, DateTime.now().millisecondsSinceEpoch);
      _decUnsent();
      _sent++;
      if (ack.duplicate) onLog('중복 수용 $sid#$seq');

      await _applySessionState(ack);
    } on UploadFailure catch (f) {
      _lastFailure = f;
      if (!f.retryable) {
        // ★ 상태 코드로 판단하지 않는다. 서버가 재시도 불가라고 말한 것만
        //   여기 온다 (§4). 조용히 사라지지 않게 DEAD로 남겨 둔다.
        await AppDb.markBatchDead(sid, seq);
        _decUnsent();
        _dead++;
        onLog('!! 재시도 불가 $sid#$seq: ${f.code} ${f.detail}');
        return;
      }
      _failed++;
      final next = retryCount + 1;
      await AppDb.markBatchRetry(sid, seq,
          retryCount: next, nextTryAt: _nextTryAt(next));
      onLog('재시도 예약 $sid#$seq (${f.code}, $next회차)');
    } catch (e) {
      // ★ 여기로 오는 건 대개 DB 예외다(종료 중 닫힌 핸들 등). 배치는
      //   PENDING/FAILED 그대로 두고 넘어간다 - 큐에 남아 다음 기회에 다시
      //   간다. 이걸 안 잡으면 티커가 unawaited로 띄운 요청이라
      //   서비스 isolate의 미처리 비동기 오류가 된다.
      //
      // ★ 집계에서는 실패로 센다. 동기화 루프가 "진전 없음"을 알아야
      //   같은 예외로 무한히 돌지 않는다.
      _failed++;
      onLog('!! 전송 중 예외 $sid#$seq: $e');
    }
  }

  void _decUnsent() {
    if (_unsent > 0) _unsent--;
  }

  /// `min(base * 2^retry, cap) * (0.8 ~ 1.2)`.
  ///
  /// ★ 지터가 없으면 복구 시점에 500개 배치가 같은 백오프로 정렬돼
  ///   동시에 깨어난다. 동시 3건 제한이 있어도 서버 입장에선 버스트다.
  int _nextTryAt(int retryCount) {
    final shift = retryCount.clamp(0, 30);
    final base = min(K.backoffBaseMs * (1 << shift), K.backoffCapMs);
    final jitter = 0.8 + _rng.nextDouble() * 0.4;
    return DateTime.now().millisecondsSinceEpoch + (base * jitter).round();
  }

  // ── session_state 반응 (§6) ─────────────────────────────

  Future<void> _applySessionState(BatchAck ack) async {
    switch (ack.sessionState) {
      case RemoteSessionState.abandoned:
        await _handleAbandoned(ack.sessionId);
      case RemoteSessionState.closed:
        if (await AppDb.remoteState(ack.sessionId) !=
            RemoteSessionState.closed) {
          await AppDb.putUploadState(ack.sessionId,
              remoteState: RemoteSessionState.closed);
          onLog('세션 종료 확인 ${ack.sessionId}');
        }
      default:
        // ACTIVE. 응답마다 DB를 쓰지 않는다.
        break;
    }
  }

  /// ★ 멱등해야 한다. 죽은 세션의 백로그가 남아 있는 동안에는 응답마다
  ///   ABANDONED가 돌아온다. 가드가 없으면 응답 한 개마다 새 세션이
  ///   발급되어 세션이 폭증한다. 판정 기준은 **응답의 session_id**다.
  Future<void> _handleAbandoned(String sid) async {
    if (await AppDb.remoteState(sid) == RemoteSessionState.abandoned) return;
    if (_abandonSwitchInProgress) return;
    _abandonSwitchInProgress = true;
    try {
      if (sid != _sessionId) {
        // 이미 지나간 세션이 뒤늦게 내인된 경우. 후계자를 낼 이유가 없다.
        // ★ 큐는 비우지 않는다 (C-2). 서버는 R2에 따라 죽은 세션의 배치도
        //   202로 받아 raw_batch에 적재한다. 버릴 이유가 없다.
        await AppDb.putUploadState(sid,
            remoteState: RemoteSessionState.abandoned);
        onLog('과거 세션 내인 $sid (큐는 그대로 전송)');
        return;
      }

      final successor = _uuid.v4();
      await AppDb.putUploadState(
        sid,
        remoteState: RemoteSessionState.abandoned,
        successorSessionId: successor,
      );

      // 열린 창을 구 세션 몫으로 먼저 끊어 큐에 넣는다.
      // ★ is_last를 세우지 않는다. 이미 종착 상태(ABANDONED)라 서버의
      //   CLOSED 전이는 `state = 'ACTIVE'` 조건에 걸려 어차피 무시된다.
      //
      // ★ 이 경로는 티커가 아니라 전송 응답에서 들어온다. 티커의 절단이
      //   돌고 있으면 끝나기를 기다린다 - 건너뛰면 열린 창이 구 세션에
      //   영영 안 잘린 채 남고, 겹쳐서 돌면 같은 구간을 두 번 자른다.
      while (_cutting) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      _cutting = true;
      try {
        if (_openFrom != null) {
          await flushBuffer();
          final tail = await AppDb.maxPointTs(sid);
          if (tail != null && tail >= _openFrom!) {
            await _cut(toTs: tail + 1, isLast: false);
          }
        }
      } finally {
        _cutting = false;
      }

      await onSessionSwitch(sid, successor);
      _sessionId = successor;
      _openFrom = null; // 새 세션의 첫 좌표가 다시 정한다
      onLog('세션 내인 $sid -> 승계 $successor');
    } finally {
      _abandonSwitchInProgress = false;
    }
  }

  // ── 종료 ────────────────────────────────────────────────

  /// ★ await 해야 한다. `_api.dispose()`가 진행 중 요청을 취소하면 그
  ///   실패 처리가 `markBatchRetry`로 DB를 만진다. 기다리지 않고 호출부가
  ///   바로 `AppDb.close()`를 하면 닫힌 DB에 쓰게 된다.
  Future<void> dispose() async {
    _disposed = true;
    _api.dispose();
    if (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.values.toList());
    }
  }
}
