import 'dart:async';
import 'dart:convert';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../data/app_db.dart';
import '../../data/permission_manager.dart';

/// UI가 표시하는 전부. 서비스 isolate가 invoke로 보내준 값으로만 채워진다.
class TrackingState {
  final bool running;

  /// [추적 종료]를 눌렀고 서비스가 flush/전송 마무리 후 내려가길 기다리는 중.
  /// 오프라인이면 수 초 걸린다. 이 동안 시작/종료 버튼을 막는다.
  final bool stopping;
  final String? sessionId;
  final String label;
  final int count;
  final int buffered;
  final int elapsedMs;
  final int staleMs; // 마지막 수신 후 경과. -1 = 아직 한 번도 못 받음

  /// 아직 서버가 받지 못한 배치 수 (PENDING/FAILED). 이전 세션 백로그도 포함한다.
  final int queued;

  /// ts 워터마크가 버린 좌표 누계 (§9-4).
  /// STEP G "볼 것 2번(ts 중복 유무)"이 여기서 실시간으로 보인다.
  final int droppedTs;

  final double? lat, lng, acc, spd;

  const TrackingState({
    this.running = false,
    this.stopping = false,
    this.sessionId,
    this.label = TripLabel.none,
    this.count = 0,
    this.buffered = 0,
    this.elapsedMs = 0,
    this.staleMs = -1,
    this.queued = 0,
    this.droppedTs = 0,
    this.lat,
    this.lng,
    this.acc,
    this.spd,
  });

  TrackingState copyWith({
    bool? running,
    bool? stopping,
    String? sessionId,
    String? label,
    int? count,
    int? buffered,
    int? elapsedMs,
    int? staleMs,
    int? queued,
    int? droppedTs,
    double? lat,
    double? lng,
    double? acc,
    double? spd,
  }) =>
      TrackingState(
        running: running ?? this.running,
        stopping: stopping ?? this.stopping,
        sessionId: sessionId ?? this.sessionId,
        label: label ?? this.label,
        count: count ?? this.count,
        buffered: buffered ?? this.buffered,
        elapsedMs: elapsedMs ?? this.elapsedMs,
        staleMs: staleMs ?? this.staleMs,
        queued: queued ?? this.queued,
        droppedTs: droppedTs ?? this.droppedTs,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        acc: acc ?? this.acc,
        spd: spd ?? this.spd,
      );

  String get elapsedText {
    final s = elapsedMs ~/ 1000;
    final h = (s ~/ 3600).toString().padLeft(2, '0');
    final m = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$h:$m:$sec';
  }
}

final trackingProvider =
    StateNotifierProvider<TrackingController, TrackingState>(
  (ref) => TrackingController(),
);

class TrackingController extends StateNotifier<TrackingState> {
  TrackingController() : super(const TrackingState()) {
    _bind();
  }

  final _service = FlutterBackgroundService();
  StreamSubscription<Map<String, dynamic>?>? _sub;

  /// 마지막 tick 수신 시각. 서비스가 살아 있기만 하고 돌지 않는지(좀비) 판별한다.
  int? _lastTickAt;
  Future<void>? _stopping;

  /// ★ 서비스 isolate로부터의 유일한 수신 경로.
  void _bind() {
    _sub = _service.on(K.evtTick).listen((data) {
      if (data == null) return;
      // 종료를 요청한 뒤 늦게 도착한 tick이 running을 되살리지 않게 한다.
      if (state.stopping) return;
      _lastTickAt = DateTime.now().millisecondsSinceEpoch;
      state = state.copyWith(
        running: true,
        sessionId: data['sessionId'] as String?,
        label: data['label'] as String? ?? TripLabel.none,
        count: (data['count'] as num?)?.toInt() ?? 0,
        buffered: (data['buffered'] as num?)?.toInt() ?? 0,
        elapsedMs: (data['elapsedMs'] as num?)?.toInt() ?? 0,
        staleMs: (data['staleMs'] as num?)?.toInt() ?? -1,
        queued: (data['queued'] as num?)?.toInt() ?? 0,
        droppedTs: (data[K.evtDroppedTs] as num?)?.toInt() ?? 0,
        lat: (data['lat'] as num?)?.toDouble(),
        lng: (data['lng'] as num?)?.toDouble(),
        acc: (data['acc'] as num?)?.toDouble(),
        spd: (data['spd'] as num?)?.toDouble(),
      );
    });
  }

  /// 앱 기동/복귀 시 서비스의 실제 상태를 읽는다.
  ///
  /// ★ `isRunning()`만 믿으면 안 된다. 예전에는 이것만 보고 running=true를
  ///   세웠고, 그래서 종료 처리 중이거나 초기화에 실패해 멈춘 서비스도
  ///   [추적 종료] + 수집 0으로 보였다. 세 경우로 나눈다:
  ///   - 서비스 O, pending 키 O → 수집 중. 단 tick이 안 오면 좀비 → 정리.
  ///   - 서비스 O, pending 키 X → shutdown이 키를 먼저 지운 상태 = 종료 처리 중.
  ///   - 서비스 X              → 대기.
  Future<void> syncRunningState() async {
    if (_stopping != null) return;
    final running = await _service.isRunning();
    if (!running) {
      state = const TrackingState();
      return;
    }

    // 서비스 isolate가 쓴 값이라 UI isolate의 캐시를 갱신해야 보인다.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final pending = prefs.getString(K.prefsPendingSessionId);

    if (pending == null) {
      // ★ 전송 전용 모드면 좀비가 아니다. 여기서 stop을 보내면 사용자가 누른
      //   동기화가 취소된다. 수집 UI만 대기 상태로 둔다.
      if (prefs.getBool(K.prefsSyncOnly) == true) {
        state = const TrackingState();
        return;
      }
      await _awaitStopped(sendStop: true);
      return;
    }
    state = state.copyWith(running: true, sessionId: pending);
    _checkAlive(const Duration(seconds: 5));
  }

  /// [grace] 뒤에도 tick이 한 번도 안 왔으면 서비스를 정리한다.
  void _checkAlive(Duration grace) {
    final since = DateTime.now().millisecondsSinceEpoch;
    Future<void>.delayed(grace, () async {
      if (!mounted || _stopping != null || !state.running) return;
      final t = _lastTickAt;
      if (t != null && t >= since) return; // 정상
      if (await _service.isRunning()) {
        // 살아는 있는데 돌지 않는다. 종료 명령은 서비스가 맨 처음 거는
        // 리스너로 받으므로 초기화 중에 멈췄어도 통한다.
        await stop();
      } else {
        // 서비스가 스스로 내려갔다 (세션 정보 없음, 초기화 실패 등).
        state = const TrackingState();
      }
    });
  }

  /// user_id는 최초 1회만 생성하고 영구 보관한다.
  static Future<String> ensureUserId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(K.prefsUserId);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(K.prefsUserId, id);
    }
    return id;
  }

  /// [추적 시작]
  ///
  /// ★ session_id를 invoke로 넘기지 않고 SharedPreferences에 먼저 쓴다.
  ///   startService() 직후 invoke하면 서비스 isolate가 아직 리스너를
  ///   등록하기 전이라 메시지가 유실될 수 있다.
  Future<String?> start() async {
    if (_stopping != null) return '이전 추적을 종료하는 중입니다. 잠시 후 다시 시도하세요.';
    // ★ 이미 떠 있는 서비스에 startService()를 부르면 네이티브가
    //   "Service already running"으로 무시한다 - onStart가 다시 안 돌아서
    //   새 session_id도, 위치 구독도 없이 버튼만 [추적 종료]로 바뀐다.
    if (await _service.isRunning()) {
      // 전송 전용 모드가 돌고 있을 수 있다. isolate가 같은 `batches`를 쓰므로
      // 겹쳐 띄우지 않는다.
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (prefs.getBool(K.prefsSyncOnly) == true) {
        return '서버로 전송 중입니다. 전송이 끝난 뒤 시작하세요.';
      }
      await syncRunningState();
      return '이미 실행 중인 추적이 있습니다.';
    }

    final report = await PermissionManager.check();
    if (!report.canStart) return '권한 부족: ${report.missing.join(", ")}';

    final prefs = await SharedPreferences.getInstance();
    final userId = await ensureUserId();
    final sessionId = const Uuid().v4();

    // ★ 전송 전용 표시를 반드시 지운다. 동기화 중 프로세스가 죽어 표시가 남아
    //   있으면, 여기서 띄운 서비스가 수집 대신 전송 루프로 들어간다.
    await prefs.remove(K.prefsSyncOnly);
    await prefs.setString(K.prefsUserId, userId);
    await prefs.setString(K.prefsPendingSessionId, sessionId);
    await prefs.setInt(K.prefsStartedAt, DateTime.now().millisecondsSinceEpoch);

    final ok = await _service.startService();
    if (!ok) {
      await prefs.remove(K.prefsPendingSessionId);
      return '서비스를 시작하지 못했습니다.';
    }

    state = TrackingState(running: true, sessionId: sessionId);
    // 서비스 초기화(DB 열기, 업로드 큐 복구)가 끝나고 첫 tick이 올 때까지 여유를 준다.
    _checkAlive(const Duration(seconds: 10));
    return null;
  }

  /// [추적 종료] — 서비스가 버퍼를 flush하고 ended_at을 기록한 뒤 스스로 종료한다.
  ///
  /// ★ 예전에는 900ms만 기다리고 대기 상태로 돌렸다. 서비스의 마감(flush,
  ///   마지막 절단, DB 닫기)이 끝나기 전에 앱을 다시 열거나 [추적 시작]을
  ///   누르면 아직 내려가는 중인 서비스를 붙잡았다. 내려갈 때까지 기다린다.
  Future<void> stop() => _awaitStopped(sendStop: true);

  Future<void> _awaitStopped({required bool sendStop}) {
    return _stopping ??= () async {
      state = state.copyWith(stopping: true);
      try {
        if (sendStop) _service.invoke(K.evtStop);
        final deadline = DateTime.now().add(_stopTimeout);
        while (await _service.isRunning()) {
          if (DateTime.now().isAfter(deadline)) {
            // 명령이 안 먹는다. 한 번 더 보내고 UI는 풀어준다 -
            // 계속 막아 두면 사용자가 할 수 있는 게 없다.
            _service.invoke(K.evtStop);
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      } finally {
        _lastTickAt = null;
        if (mounted) state = const TrackingState();
        _stopping = null;
      }
    }();
  }

  /// 마지막 flush·절단, DB 마감, 엔진 해제까지 넉넉히.
  static const _stopTimeout = Duration(seconds: 15);

  /// 라벨 변경 → 서비스에 전달. 이후 수집되는 좌표에 적용된다.
  void setLabel(String label) {
    _service.invoke(K.evtSetLabel, {'label': label});
    state = state.copyWith(label: label);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════
// 수동 동기화 (전송 전용 모드)
// ═══════════════════════════════════════════════════════════════

/// 한 번의 동기화 결과. 서비스가 prefs에 남긴 JSON을 그대로 읽는다.
class SyncResult {
  /// done | unreachable | budget | cancelled | error
  final String reason;
  final int sent;
  final int failed;
  final int deadNew;

  /// 끝난 뒤에도 폰에 남은 미전송 배치 수.
  final int remaining;

  /// 폰 전체의 DEAD 배치 수 (이번에 생긴 것 포함).
  final int deadTotal;

  /// 실제로 요청한 주소.
  final String url;

  /// 저장된 주소가 없어 빌드 기본값으로 보냈는지.
  final bool usingDefaultUrl;

  final String? error;

  /// 미전송 배치가 있던 세션들 (판정 화면 바로가기용).
  final List<String> sessions;

  const SyncResult({
    required this.reason,
    required this.sent,
    required this.failed,
    required this.deadNew,
    required this.remaining,
    required this.deadTotal,
    required this.url,
    required this.usingDefaultUrl,
    required this.error,
    required this.sessions,
  });

  static SyncResult? fromJsonString(String? s) {
    if (s == null) return null;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return SyncResult(
        reason: j['reason'] as String? ?? 'done',
        sent: (j['sent'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        deadNew: (j['deadNew'] as num?)?.toInt() ?? 0,
        remaining: (j['remaining'] as num?)?.toInt() ?? 0,
        deadTotal: (j['deadTotal'] as num?)?.toInt() ?? 0,
        url: j['url'] as String? ?? '',
        usingDefaultUrl: j['usingDefaultUrl'] == true,
        error: j['error'] as String?,
        sessions: (j['sessions'] as List?)?.cast<String>() ?? const [],
      );
    } catch (_) {
      return null;
    }
  }

  bool get ok => reason == 'done';

  /// 한 줄 요약. **남은 건수와 DEAD를 반드시 함께 보여준다** - "완료"만 보이면
  /// seq 갭 때문에 서버에 아무것도 안 붙었는데도 정상으로 믿게 된다.
  String get summary {
    final parts = <String>['전송 $sent건'];
    if (remaining > 0) parts.add('남은 $remaining건');
    if (deadTotal > 0) parts.add('DEAD $deadTotal건 제외');
    return parts.join(' · ');
  }

  String get reasonText => switch (reason) {
        'done' => '전송 완료',
        'unreachable' => '서버에 닿지 못했습니다',
        'budget' => '시간이 오래 걸려 중단했습니다',
        'cancelled' => '취소했습니다',
        _ => '오류로 중단했습니다',
      };
}

class SyncState {
  /// 전송 전용 서비스가 돌고 있다.
  final bool running;

  /// 폰에 남은 미전송(PENDING/FAILED) 배치 수. 유휴 상태에서 버튼에 쓴다.
  final int unsent;

  /// 폰 전체 DEAD 배치 수.
  final int dead;

  // 진행 중 표시
  final int sent;
  final int failed;
  final int remaining;

  final SyncResult? result;

  const SyncState({
    this.running = false,
    this.unsent = 0,
    this.dead = 0,
    this.sent = 0,
    this.failed = 0,
    this.remaining = 0,
    this.result,
  });

  SyncState copyWith({
    bool? running,
    int? unsent,
    int? dead,
    int? sent,
    int? failed,
    int? remaining,
    SyncResult? result,
    bool clearResult = false,
  }) =>
      SyncState(
        running: running ?? this.running,
        unsent: unsent ?? this.unsent,
        dead: dead ?? this.dead,
        sent: sent ?? this.sent,
        failed: failed ?? this.failed,
        remaining: remaining ?? this.remaining,
        result: clearResult ? null : (result ?? this.result),
      );
}

final syncProvider =
    StateNotifierProvider<SyncController, SyncState>((ref) => SyncController());

/// [서버로 보내기]. 전송 자체는 서비스 isolate의 [Uploader]가 한다.
/// 이 클래스는 서비스를 띄우고, 진행을 받아 보여주고, 끝나면 결과를 읽는다.
class SyncController extends StateNotifier<SyncState> {
  SyncController() : super(const SyncState()) {
    _sub = _service.on(K.evtSyncTick).listen((data) {
      if (data == null) return;
      if (data['done'] == true) {
        // prefs 결과가 정본이다. 여기서는 숫자만 먼저 반영한다.
        state = state.copyWith(
          sent: (data['sent'] as num?)?.toInt() ?? state.sent,
          failed: (data['failed'] as num?)?.toInt() ?? state.failed,
          remaining: (data['remaining'] as num?)?.toInt() ?? state.remaining,
        );
        return;
      }
      state = state.copyWith(
        running: true,
        sent: (data['sent'] as num?)?.toInt() ?? 0,
        failed: (data['failed'] as num?)?.toInt() ?? 0,
        remaining: (data['remaining'] as num?)?.toInt() ?? 0,
      );
    });
  }

  final _service = FlutterBackgroundService();
  StreamSubscription<Map<String, dynamic>?>? _sub;

  /// 폰 큐 상태를 다시 센다.
  ///
  /// ★ 서비스가 돌고 있으면 읽지 않는다. 수집 중에 UI가 DB를 여는 것을 막는
  ///   기존 규칙(세션 목록 버튼 비활성)과 같은 이유다. 읽은 뒤에는 핸들을 닫아
  ///   다음 서비스 시작과 부딪히지 않게 한다.
  Future<void> refreshCounts() async {
    if (state.running) return;
    if (await _service.isRunning()) return;
    try {
      final counts = await AppDb.countBatchesByStateAll();
      final unsent = (counts[BatchState.pending] ?? 0) +
          (counts[BatchState.failed] ?? 0);
      if (!mounted) return;
      state = state.copyWith(unsent: unsent, dead: counts[BatchState.dead] ?? 0);
    } finally {
      await AppDb.close();
    }
  }

  /// 오류 메시지를 돌려준다. null이면 시작했다.
  Future<String?> sync() async {
    if (state.running) return null;
    if (await _service.isRunning()) {
      return '추적이 실행 중입니다. 종료한 뒤 전송하세요.';
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(K.prefsSyncResult);
    await prefs.setBool(K.prefsSyncOnly, true);
    // UI가 연 DB 핸들을 닫는다. 이제부터 batches를 쓰는 것은 서비스뿐이다.
    await AppDb.close();

    state = state.copyWith(
        running: true, sent: 0, failed: 0, remaining: state.unsent, clearResult: true);

    final ok = await _service.startService();
    if (!ok) {
      await prefs.remove(K.prefsSyncOnly);
      if (mounted) state = state.copyWith(running: false);
      return '서비스를 시작하지 못했습니다.';
    }
    unawaited(_awaitFinish());
    return null;
  }

  /// 취소. 추적 종료와 같은 통로를 쓴다 (서비스가 맨 처음 거는 리스너).
  void cancel() => _service.invoke(K.evtStop);

  Future<void> _awaitFinish() async {
    // 서비스가 올라올 때까지 잠깐 기다린다 (startService 직후는 아직 false다).
    final upBy = DateTime.now().add(const Duration(seconds: 5));
    while (!await _service.isRunning() && DateTime.now().isBefore(upBy)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // 예산(15분) + 마지막 요청 타임아웃 여유.
    final deadline = DateTime.now()
        .add(const Duration(milliseconds: K.syncBudgetMs + 60000));
    while (await _service.isRunning() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final result = SyncResult.fromJsonString(prefs.getString(K.prefsSyncResult));
    if (!mounted) return;
    state = state.copyWith(running: false, result: result);
    await refreshCounts();
  }

  void clearResult() => state = state.copyWith(clearResult: true);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
