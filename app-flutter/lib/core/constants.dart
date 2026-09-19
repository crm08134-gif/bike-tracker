/// 앱 전역 상수. 서비스 isolate와 UI isolate 양쪽에서 참조한다.
class K {
  // SharedPreferences 키
  static const prefsUserId = 'user_id';

  /// 서버 `device_id`. 설치마다 한 번 만드는 UUID v4 (재설치하면 바뀐다).
  /// 서비스 isolate만 읽고 쓴다 (background_service.dart).
  static const prefsDeviceId = 'device_id';
  static const prefsPendingSessionId = 'pending_session_id';
  static const prefsActiveSessionId = 'active_session_id';
  static const prefsStartedAt = 'session_started_at';

  /// 서버 주소 (예: `http://192.168.0.10:8080`). 없으면 [defaultApiBaseUrl].
  /// UI(설정 화면)가 쓰고, 서비스 isolate는 시작할 때 reload해서 읽는다.
  static const prefsServerBaseUrl = 'server_base_url';

  /// 서비스를 **전송 전용 모드**로 띄우라는 표시. UI가 [서버로 보내기]를 누를 때
  /// 켜고, 전송이 끝나면 서비스가 스스로 끈다. 켜져 있으면 onStart가 수집 경로
  /// 대신 전송 루프로 분기한다.
  static const prefsSyncOnly = 'sync_only';

  /// 마지막 동기화 결과(JSON). 서비스가 내려가기 직전에 쓰고 UI가 읽는다.
  ///
  /// ★ invoke만으로는 부족하다. 마지막 이벤트와 stopSelf가 경합해서 UI가
  ///   결과를 못 받는 경우가 있다. prefs에 남기면 서비스가 내려간 뒤에 읽는다.
  static const prefsSyncResult = 'sync_last_result';

  // 알림 채널
  // ★ 'bike_tracker_' 접두는 남긴다. 패키지명 통일(§13)에서 제외한 두 이름
  //   중 하나다 - 채널 ID를 바꾸면 안드로이드가 새 채널을 만들고, 기기에
  //   이미 있는 채널은 설정 목록에 유령으로 남는다. 나머지 하나는
  //   'bike_tracker.db' 파일명이다(app_db.dart 참고).
  static const notificationChannelId = 'bike_tracker_tracking';
  static const notificationChannelName = '궤적 수집';
  static const notificationId = 8801;

  // 서비스 <-> UI 이벤트 이름
  static const evtTick = 'tick';          // 서비스 -> UI (1초마다)
  static const evtSetLabel = 'setLabel';  // UI -> 서비스
  static const evtStop = 'stopService';   // UI -> 서비스. 전송 전용 모드의 취소도 겸한다
  static const evtSetServerUrl = 'setServerUrl'; // UI -> 서비스
  static const evtSyncTick = 'syncTick';  // 전송 전용 모드 -> UI (한 바퀴마다)

  // 버퍼 정책: 이 개수가 차거나 이 시간이 지나면 DB에 flush
  static const bufferFlushCount = 10;
  static const bufferFlushMs = 3000;

  // 결측 경고 임계값 (UI 색상 변경용)
  static const staleWarnMs = 3000;
  static const staleAlertMs = 10000;

  /// 위치 스트림을 구독했는데 이만큼 첫 fix가 없으면 다시 구독한다.
  static const firstFixResubscribeMs = 30000;

  // ── 업로드 (API 계약 v1 §12 튜닝 손잡이) ──────────────────
  /// 배치 절단 창. 기준 시각은 GNSS ts(lastAcceptedTs)이지 로컬 시계가 아니다.
  static const batchWindowMs = 30000;

  /// 미전송 배치가 이만큼 쌓이면 **절단을 멈춘다**. 좌표는 계속 points에 쌓인다.
  /// 버리지 않는다 (§9-5). 500 x 30초 = 약 4시간 무손실.
  static const maxQueuedBatches = 500;

  /// 서버와 공유하는 상한. 초과 시 413(retryable:false).
  static const maxPointsPerBatch = 1000;

  static const backoffBaseMs = 1000;
  static const backoffCapMs = 300000;
  static const maxConcurrentUploads = 3;

  // ── 수동 동기화 (전송 전용 모드) ─────────────────────────
  // ★ 추적 중에는 전송하지 않는다. 밖에서는 서버에 닿지 않는 것이 정상이라
  //   초당 한 번씩 실패 요청을 날릴 이유가 없다. 배치는 큐에 쌓아 두었다가
  //   집에서 [서버로 보내기]로 한 번에 보낸다.

  /// 동기화 경로 **전용** 타임아웃. 서버에 못 닿는다는 사실은 몇 초면 안다.
  /// 수집 경로는 [connectTimeoutMs]/[receiveTimeoutMs]를 그대로 쓴다.
  static const syncConnectTimeoutMs = 3000;
  static const syncReceiveTimeoutMs = 5000;

  /// 성공 없이 이만큼 실패가 이어지면 즉시 멈춘다. 서버가 꺼져 있는데 수백 건을
  /// 하나씩 타임아웃까지 기다리면 사용자가 수십 분을 붙잡힌다.
  ///
  /// ★ DEAD는 여기 세지 않는다. 서버가 응답했다는 뜻이라 연결은 살아 있다.
  static const syncMaxConsecutiveFailures = 4;

  /// 안전장치. 며칠 밀리면 배치가 수백 개가 되므로 넉넉히 잡는다.
  static const syncBudgetMs = 900000; // 15분

  /// 보낼 것이 아직 없을 때(전부 재시도 대기 중) 한 바퀴 쉬는 시간.
  static const syncIdleSleepMs = 300;

  /// 전송 전용 모드가 업로더에 넘기는 자리표시 세션.
  ///
  /// ★ 실제 session_id(UUID v4)와 절대 같으면 안 된다. 같으면 서버의 ABANDONED
  ///   응답이 승계 세션 발급을 일으킨다. 전송 전용 모드는 절단을 하지 않으므로
  ///   이 값이 배치에 쓰이는 일은 없다.
  static const syncPlaceholderSessionId = 'sync-only';

  // ── 서버 ────────────────────────────────────────────────
  /// 서버 주소 **기본값**. 앱 설정에 저장된 주소가 없을 때만 쓴다.
  /// 직접 읽지 말고 `ServerConfig.load()`를 거친다 (data/server_config.dart).
  ///
  /// `--dart-define=API_BASE_URL=http://127.0.0.1:8080` 으로 덮어쓴다 (USB + adb reverse).
  /// dart-define이 없으면 안드로이드 에뮬레이터에서 호스트를 가리키는 주소다.
  static const defaultApiBaseUrl =
      String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8080');
  static const connectTimeoutMs = 10000;
  static const receiveTimeoutMs = 20000;

  // ── 지도 타일 (주행 기록 지도) ───────────────────────────
  /// OSM 타일 서버. 우리 서버가 아니다 - 판정 조회와 무관하다.
  static const osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// ★ OSM 타일 사용 정책: 앱을 식별하는 User-Agent가 필수다. 없거나
  ///   라이브러리 기본값('flutter_map (unknown)')이면 차단될 수 있다.
  ///   applicationId와 맞춰 둔다 (android/app/build.gradle.kts).
  static const osmTileUserAgent =
      'my_gps_tracker (com.example.my_gps_tracker; flutter_map)';

  // 서비스 -> UI tick 추가 필드 키 (§9-4: 버린 개수를 실시간 노출)
  static const evtDroppedTs = 'droppedTs';
}

/// `batches.state`. PENDING/SENT/FAILED는 계약 §9-1 그대로고,
/// [dead]는 계약에 없는 한 칸을 더 둔 것이다.
///
/// ★ 필요한 이유: §4가 `retryable:false`를 받으면 재시도하지 말라고 하는데,
///   FAILED로 두면 큐 조회에 계속 걸려 영원히 재시도한다. 서버가 "절대 성공
///   못 한다"고 말한 배치를 담아둘 종착 칸이 하나 필요하다. 큐 조회에서 제외되고
///   사람이 볼 수 있게 DB에는 남는다.
class BatchState {
  static const pending = 'PENDING';
  static const sent = 'SENT';
  static const failed = 'FAILED';
  static const dead = 'DEAD';
}

/// `session_upload_state.remote_state` (계약 §6).
class RemoteSessionState {
  static const active = 'ACTIVE';
  static const closed = 'CLOSED';
  static const abandoned = 'ABANDONED';
}

/// 사용자가 수동으로 지정하는 이동수단 라벨.
/// 1단계의 목적은 이 라벨이 붙은 실주행 로그를 확보하는 것이다.
class TripLabel {
  static const none = 'NONE';
  static const bike = 'BIKE';
  static const walk = 'WALK';
  static const other = 'OTHER';

  static const all = [bike, walk, other];

  static String emoji(String label) {
    switch (label) {
      case bike:
        return '🚲';
      case walk:
        return '🚶';
      case other:
        return '❓';
      default:
        return '⏳';
    }
  }

  static String korean(String label) {
    switch (label) {
      case bike:
        return '자전거';
      case walk:
        return '도보';
      case other:
        return '기타';
      default:
        return '미지정';
    }
  }
}

/// 하나의 GPS 표본.
class GpsPoint {
  final String sessionId;
  final int ts; // epoch millis
  final double lat;
  final double lng;
  final double? acc;
  final double? spd;
  final double? alt;
  final String label;

  const GpsPoint({
    required this.sessionId,
    required this.ts,
    required this.lat,
    required this.lng,
    this.acc,
    this.spd,
    this.alt,
    required this.label,
  });

  Map<String, Object?> toMap() => {
        'session_id': sessionId,
        'ts': ts,
        'lat': lat,
        'lng': lng,
        'acc': acc,
        'spd': spd,
        'alt': alt,
        'label': label,
        // ★ 'uploaded'를 쓰지 않는다 (§9-3). batches.state가 단일 진실이다.
        //   컬럼은 DROP 위험 때문에 남겨두되 읽지도 쓰지도 않는다.
      };
}

/// 세션 요약 (목록 화면용).
class SessionSummary {
  final String sessionId;
  final String userId;
  final int startedAt;
  final int? endedAt;
  final int pointCount;

  const SessionSummary({
    required this.sessionId,
    required this.userId,
    required this.startedAt,
    required this.endedAt,
    required this.pointCount,
  });
}
