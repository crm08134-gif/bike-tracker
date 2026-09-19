import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../data/api_client.dart';
import '../data/app_db.dart';
import '../data/server_config.dart';
import 'uploader.dart';

/// ═══════════════════════════════════════════════════════════════
/// 백그라운드 수집 서비스
///
/// ★ 이 파일의 onStart()는 UI와 **완전히 분리된 isolate**에서 실행된다.
///   - 전역 변수나 Riverpod Provider를 UI와 공유할 수 없다.
///   - 서비스 -> UI 는 service.invoke(K.evtTick, {...}) 로만 전달한다.
///   - UI -> 서비스 는 service.on(K.evtSetLabel) 으로만 수신한다.
///   - 진입점 최상단의 DartPluginRegistrant.ensureInitialized() 가 없으면
///     geolocator/sqflite 호출 시 MissingPluginException이 발생한다.
///   - 그 호출 때 logcat에 "`flutter_background_service_android` threw an
///     error: ...only be used in the main isolate" 가 찍히는 것은 정상이다.
///     UI용 클래스 등록만 실패하고(생성된 registrant가 try/catch로 삼킴)
///     나머지 플러그인은 정상 등록된다. 이 isolate는 ServiceInstance만
///     쓰므로 영향이 없다. 무시할 것.
///
/// ★ 포그라운드 서비스와 알림은 flutter_background_service가 단독 소유한다.
///   geolocator의 LocationSettings에 foregroundNotificationConfig를
///   절대 넣지 말 것 (알림 중복 및 서비스 타입 충돌 원인).
/// ═══════════════════════════════════════════════════════════════

/// UI isolate에서 앱 기동 시 1회 호출.
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  // Android 8+ 는 알림 채널이 먼저 존재해야 포그라운드 서비스가 뜬다.
  final notifications = FlutterLocalNotificationsPlugin();
  const channel = AndroidNotificationChannel(
    K.notificationChannelId,
    K.notificationChannelName,
    description: '자전거 궤적을 백그라운드에서 수집하는 동안 표시됩니다.',
    importance: Importance.low, // 소리/진동 없이 상주
  );
  await notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, // 사용자가 [추적 시작]을 눌러야 시작
      // ★ 기본값이 true다. 켜져 있으면 BootReceiver가 재부팅뿐 아니라
      //   MY_PACKAGE_REPLACED(= 앱을 새로 빌드해 설치할 때마다)에도 서비스를
      //   띄운다. 사용자가 누르지도 않았는데 [추적 종료] 상태로 뜨는 원인.
      autoStartOnBoot: false,
      isForegroundMode: true,
      notificationChannelId: K.notificationChannelId,
      initialNotificationTitle: '궤적 수집 대기',
      initialNotificationContent: '준비 중...',
      foregroundServiceNotificationId: K.notificationId,
      // flutter_background_service 5.1.0+ 에서 지원.
      // 이 파라미터가 없는 버전이라면 이 줄을 지우고
      // AndroidManifest.xml의 foregroundServiceType="location" 선언만으로도 동작한다.
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

/// iOS는 1단계 범위 밖. Background Fetch는 1Hz 연속 수집을 보장하지 못한다.
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// ─────────────────────────────────────────────────────────────────
// 서비스 isolate 진입점
// ─────────────────────────────────────────────────────────────────

/// 종료 명령과 초기화 완료 사이의 경합을 푼다.
class _StopGate {
  bool requested = false;
  Future<void> Function()? handler;

  /// 초기화가 끝나 shutdown을 걸 수 있게 됐다. 그 사이에 종료 명령이 이미
  /// 와 있었다면 바로 종료하고 true를 돌려준다.
  bool attach(Future<void> Function() h) {
    handler = h;
    if (requested) h();
    return requested;
  }
}

/// 초기화를 끝내지 못한 서비스를 버린다. 좀비로 남으면 UI는 계속
/// [추적 종료]를 보여주고, 새 [추적 시작]은 "이미 실행 중"으로 무시된다.
Future<void> _abortService(ServiceInstance service) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(K.prefsPendingSessionId);
    await prefs.remove(K.prefsActiveSessionId);
  } catch (_) {
    // prefs를 못 지워도 종료는 한다.
  }
  service.stopSelf();
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // ★ 반드시 최상단. 이게 빠지면 이 isolate에서 플러그인이 동작하지 않는다.
  DartPluginRegistrant.ensureInitialized();

  // ★ 종료 리스너는 어떤 await보다 먼저 건다. 예전에는 초기화(DB, 업로더)가
  //   끝난 뒤에야 걸려서, 초기화 중에 멈추거나 예외가 나면 [추적 종료]를
  //   눌러도 아무 일도 일어나지 않았다. 서비스를 UI에서 직접 죽일 방법은
  //   없으므로(stopSelf는 서비스 isolate만 부를 수 있다) 이게 유일한 출구다.
  final gate = _StopGate();
  service.on(K.evtStop).listen((_) {
    gate.requested = true;
    final h = gate.handler;
    if (h != null) {
      h();
      return;
    }
    // 아직 초기화 중. 잠깐 기다려도 안 끝나면 버리고 종료한다.
    Future<void>.delayed(const Duration(seconds: 10), () {
      if (gate.handler == null) _abortService(service);
    });
  });

  try {
    // 전송 전용 모드인지 먼저 본다. UI가 [서버로 보내기]로 켠 표시다.
    // ★ prefs 캐시는 isolate마다 따로라 reload가 필요하다.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.getBool(K.prefsSyncOnly) == true) {
      await _runSyncService(service, gate, prefs);
      return;
    }
    await _runService(service, gate);
  } catch (e, st) {
    // ignore: avoid_print
    print('[service] !! 초기화 실패 - 스스로 종료: $e\n$st');
    await _abortService(service);
  }
}

/// ═══════════════════════════════════════════════════════════════
/// 전송 전용 모드 (수동 동기화)
///
/// 위치 구독도, 세션 생성도, 배치 절단도 하지 않는다. 폰 큐에 남은 배치를
/// 서버로 밀어내고 스스로 내려간다.
///
/// ★ 서비스 isolate에서 도는 이유: 업로더의 DB 쓰기는 서비스만 한다는 규칙
///   (§6-1 제약 3) 때문이다. UI isolate에서 보내면 수집 중 서비스와 같은
///   `batches` 테이블을 두 곳에서 쓰게 된다.
///
/// ★ 전송 자체는 기존 [Uploader]를 그대로 쓴다. 여기 있는 것은 "언제 멈출지"와
///   "무엇을 보고할지"뿐이다.
/// ═══════════════════════════════════════════════════════════════
Future<void> _runSyncService(
    ServiceInstance service, _StopGate gate, SharedPreferences prefs) async {
  void log(String m) {
    // ignore: avoid_print
    print('[sync] $m');
  }

  var cancelled = false;
  // 취소는 추적 종료와 같은 통로를 쓴다. attach는 이미 종료 명령이 와 있었으면
  // 핸들러를 바로 부르고 true를 준다.
  gate.attach(() async {
    cancelled = true;
  });

  final userId = prefs.getString(K.prefsUserId);
  final deviceId = prefs.getString(K.prefsDeviceId);

  // ★ 하드코딩된 기본값으로 떨어지지 않게 설정을 거친다. 저장값이 없으면
  //   기본값이 쓰인다는 사실 자체를 결과에 실어 보낸다.
  final baseUrl = await ServerConfig.load();
  final usingDefaultUrl = (await ServerConfig.loadSaved()) == null;

  var sent = 0, failed = 0, deadNew = 0;
  var remaining = 0;
  var deadTotal = 0;
  String reason = 'done';
  String? errorText;
  List<String> sessionIds = const [];

  Future<void> finish() async {
    final result = <String, Object?>{
      'finishedAt': DateTime.now().millisecondsSinceEpoch,
      'reason': reason,
      'sent': sent,
      'failed': failed,
      'deadNew': deadNew,
      'remaining': remaining,
      'deadTotal': deadTotal,
      'url': baseUrl,
      'usingDefaultUrl': usingDefaultUrl,
      'error': errorText,
      'sessions': sessionIds,
    };
    // ★ prefs를 먼저 쓴다. invoke는 stopSelf와 경합해 유실될 수 있지만
    //   prefs는 서비스가 내려간 뒤에도 UI가 읽는다.
    await prefs.setString(K.prefsSyncResult, jsonEncode(result));
    await prefs.remove(K.prefsSyncOnly);
    service.invoke(K.evtSyncTick, {...result, 'done': true});
    log('종료 reason=$reason 전송=$sent 실패=$failed DEAD=$deadNew 남음=$remaining');
    await AppDb.close();
    service.stopSelf();
  }

  // 한 번도 수집한 적이 없으면 보낼 것도 없다.
  if (userId == null || deviceId == null) {
    await finish();
    return;
  }

  final api = ApiClient(
    baseUrl: baseUrl,
    connectTimeout: const Duration(milliseconds: K.syncConnectTimeoutMs),
    receiveTimeout: const Duration(milliseconds: K.syncReceiveTimeoutMs),
  );
  final uploader = Uploader(
    userId: userId,
    deviceId: deviceId,
    // ★ 자리표시. 절단을 하지 않으므로 배치에 쓰이지 않는다.
    sessionId: K.syncPlaceholderSessionId,
    onSessionSwitch: (_, __) async {},
    flushBuffer: () async {},
    onLog: log,
    api: api,
  );
  log('서버 주소: $baseUrl${usingDefaultUrl ? ' (저장된 주소 없음 - 기본값)' : ''}');

  try {
    // 판정 화면 바로가기에 쓴다. 보내기 전에 잡아 둔다.
    sessionIds = await AppDb.sessionIdsWithUnsentBatches();

    // ★ 사용자가 직접 누른 전송이다. 백오프(최대 5분)는 "서버가 곧 살아날 때까지
    //   기다린다"는 전제인데 그 전제가 깨졌으므로 지금 보낸다. DEAD는 건드리지 않는다.
    final revived = await AppDb.clearRetryBackoff();
    if (revived > 0) log('재시도 대기 해제 $revived건');

    await uploader.init();

    final deadline =
        DateTime.now().add(const Duration(milliseconds: K.syncBudgetMs));
    var consecutiveFailures = 0;

    while (true) {
      if (cancelled) {
        reason = 'cancelled';
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        reason = 'budget';
        break;
      }

      remaining = await AppDb.countUnsentBatches();
      if (remaining == 0) {
        reason = 'done';
        break;
      }

      if (service is AndroidServiceInstance &&
          await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: '서버로 전송 중',
          content: '남은 $remaining건 · 전송 $sent건',
        );
      }
      service.invoke(K.evtSyncTick, {
        'done': false,
        'remaining': remaining,
        'sent': sent,
        'failed': failed,
        'deadNew': deadNew,
      });

      final sentBefore = uploader.sentCount;
      final deadBefore = uploader.deadCount;
      final failedBefore = uploader.failedCount;

      // 기존 전송 루프를 그대로 쓴다. 슬롯 3개를 채우고 끝날 때까지 기다린다.
      // 성공이 이어지는 동안은 쉬지 않는다.
      await uploader.pumpAndWait();

      sent = uploader.sentCount;
      failed = uploader.failedCount;
      deadNew = uploader.deadCount;

      final progressed =
          sent > sentBefore || uploader.deadCount > deadBefore;
      if (progressed) {
        // DEAD도 진전으로 본다. 서버가 응답했다는 뜻이라 연결은 살아 있다.
        consecutiveFailures = 0;
      } else if (failed > failedBefore) {
        consecutiveFailures += failed - failedBefore;
      } else {
        // 보낼 것이 없다 = 전부 재시도 대기 중이다. 바쁘게 돌지 않는다.
        await Future<void>.delayed(
            const Duration(milliseconds: K.syncIdleSleepMs));
      }

      if (consecutiveFailures >= K.syncMaxConsecutiveFailures) {
        reason = 'unreachable';
        break;
      }
    }
  } catch (e, st) {
    reason = 'error';
    errorText = '$e';
    log('!! 동기화 중 예외: $e\n$st');
  } finally {
    await uploader.dispose();
    final f = uploader.lastFailure;
    if (errorText == null && f != null && reason != 'done') {
      errorText = '${f.code}${f.status == null ? '' : ' (HTTP ${f.status})'}: '
          '${f.detail}';
    }
    sent = uploader.sentCount;
    failed = uploader.failedCount;
    deadNew = uploader.deadCount;
    try {
      remaining = await AppDb.countUnsentBatches();
      deadTotal =
          (await AppDb.countBatchesByStateAll())[BatchState.dead] ?? 0;
    } catch (_) {
      // DB를 못 읽어도 결과는 남긴다.
    }
    await finish();
  }
}

Future<void> _runService(ServiceInstance service, _StopGate gate) async {
  // ★ 서버 주소 변경 리스너는 prefs를 읽기 전에 건다. 수집 도중 설정 화면에서
  //   주소를 바꾸면 prefs에 쓴 뒤 이 이벤트가 온다. reload 이후에 온 변경을
  //   리스너가 없어서 놓치면 이번 세션 내내 옛 주소로 보낸다. 늦게 온 값이 이긴다.
  ApiClient? api;
  String? pushedBaseUrl;
  service.on(K.evtSetServerUrl).listen((event) {
    final v = event?['url'];
    if (v is! String) return;
    pushedBaseUrl = v;
    api?.baseUrl = v;
    // ignore: avoid_print
    print('[upload] 서버 주소 변경: $v');
  });

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  final pendingSessionId = prefs.getString(K.prefsPendingSessionId);
  final userId = prefs.getString(K.prefsUserId);

  if (pendingSessionId == null || userId == null) {
    // 세션 정보 없이 서비스가 살아난 경우 (재부팅 복구 등) 즉시 종료
    service.stopSelf();
    return;
  }

  // ★ final이 아니다. 서버가 ABANDONED를 주면 승계 세션으로 갈아탄다 (C-2).
  //   클로저가 이 변수에 대입하므로 nullable 상태로 두면 타입 승격이 안 걸린다.
  var sessionId = pendingSessionId;

  final startedAt =
      prefs.getInt(K.prefsStartedAt) ?? DateTime.now().millisecondsSinceEpoch;
  await AppDb.createSession(
    sessionId: sessionId,
    userId: userId,
    startedAt: startedAt,
  );
  await prefs.setString(K.prefsActiveSessionId, sessionId);

  void log(String m) {
    // 서비스 isolate의 print는 logcat으로 나간다. 2단계 검증은 여기와
    // `/_debug/sessions/{sid}/seqs` 대조로 한다 (§10).
    // ignore: avoid_print
    print('[upload] $m');
  }

  // ── 서비스 로컬 상태 (UI와 공유되지 않음) ──
  String currentLabel = TripLabel.none;
  final List<GpsPoint> buffer = <GpsPoint>[];
  int totalCount = await AppDb.countPoints(sessionId);
  int lastFlushAt = DateTime.now().millisecondsSinceEpoch;
  int? lastFixAt;

  /// ★ ts 워터마크 (§9-4). 서비스가 죽었다 살아나도 이어지도록 DB에서 복구한다.
  int? lastAcceptedTs = await AppDb.maxPointTs(sessionId);
  int droppedTs = 0;
  int droppedTsAtLastCheck = 0;
  int lastDropCheckAt = DateTime.now().millisecondsSinceEpoch;
  double? lastLat, lastLng, lastAcc, lastSpd;
  bool stopping = false;

  StreamSubscription<Position>? posSub;
  Timer? ticker;

  /// ★ 티커 콜백이 async라 한 틱이 1초를 넘기면 다음 틱이 겹쳐 들어온다.
  ///   절단·전송·DB 쓰기가 겹치면 안 되므로 한 번에 하나만 돈다.
  ///   건너뛴 틱은 UI 갱신 한 번을 거를 뿐이다.
  bool tickBusy = false;

  // ── UI로부터의 명령 수신 ──
  service.on(K.evtSetLabel).listen((event) {
    final v = event?['label'];
    if (v is String) currentLabel = v;
  });

  Future<void> flushBuffer() async {
    if (buffer.isEmpty) return;
    final toWrite = List<GpsPoint>.from(buffer);
    buffer.clear();
    lastFlushAt = DateTime.now().millisecondsSinceEpoch;
    try {
      await AppDb.insertPoints(toWrite);
    } catch (e) {
      // 쓰기 실패 시 되돌려 다음 주기에 재시도
      buffer.insertAll(0, toWrite);
    }
  }

  /// 서버가 이 세션을 ABANDONED로 내인했을 때 승계 세션으로 갈아탄다 (C-2).
  ///
  /// ★ 지금은 호출되지 않는다. 승계는 **전송 응답**으로만 시작되는데 수집 중에는
  ///   전송을 하지 않기 때문이다. 전송 전용 모드는 자리표시 세션을 쓰므로
  ///   응답이 ABANDONED여도 승계를 발급하지 않는다. 판단이 끝날 때까지(M6)
  ///   코드는 남겨 둔다.
  ///
  /// ★ 큐를 비우지 않는다. ABANDONED가 오는 순간은 15분 이상 누적이
  ///   진행된 = 큐가 가장 꽉 찬 시각이다. 구 세션 배치는 구 session_id
  ///   그대로 계속 전송된다 (전송 큐 조회는 세션으로 거르지 않는다).
  Future<void> switchSession(String oldId, String newId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await flushBuffer(); // 구 세션 좌표를 먼저 확정
    await AppDb.endSession(oldId, now);
    await AppDb.createSession(sessionId: newId, userId: userId, startedAt: now);
    // 재시작 복구가 승계 세션을 집도록 prefs도 같이 옮긴다.
    // ★ 종료 중(drain의 응답으로 들어온 경우)에는 쓰지 않는다. shutdown이
    //   이미 지운 키를 되살리면 UI가 다시 "수집 중"으로 읽는다.
    if (!stopping) {
      await prefs.setString(K.prefsPendingSessionId, newId);
      await prefs.setString(K.prefsActiveSessionId, newId);
    }
    sessionId = newId;
    // ★ totalCount와 startedAt은 리셋하지 않는다. 사용자에게는 한 번의
    //   외출이고, 알림의 누적 카운트가 0으로 돌아가면 사고로 보인다 (§14).
  }

  // 서버 device_id. 없으면 여기서 한 번 만들어 영구 저장한다.
  var deviceId = prefs.getString(K.prefsDeviceId);
  if (deviceId == null) {
    deviceId = const Uuid().v4();
    await prefs.setString(K.prefsDeviceId, deviceId);
  }

  // 서버 주소. 위에서 reload했으므로 UI가 저장한 값이 보인다.
  final savedBaseUrl = await ServerConfig.load();
  final client = ApiClient(baseUrl: pushedBaseUrl ?? savedBaseUrl);
  api = client;
  log('서버 주소: ${client.baseUrl}');

  final uploader = Uploader(
    userId: userId,
    deviceId: deviceId,
    sessionId: sessionId,
    onSessionSwitch: switchSession,
    flushBuffer: flushBuffer,
    onLog: log,
    api: client,
  );
  await uploader.init();

  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    ticker?.cancel();
    await posSub?.cancel();

    // ★ 세션 키를 맨 처음 지운다. UI는 "서비스는 살아 있는데 pending 키가
    //   없다"를 "종료 처리 중"으로 읽는다. 끝에서 지우면 마감(flush, 마지막 절단,
    //   DB 닫기) 동안 앱을 다시 열었을 때 수집이 멈춘 [추적 종료] 화면이 뜬다.
    //   종료 도중 프로세스가 죽어도 워치독이 이 세션을 되살리지 않게 된다.
    await prefs.remove(K.prefsActiveSessionId);
    await prefs.remove(K.prefsPendingSessionId);

    await flushBuffer();

    // 마지막 절단 + is_last. 마지막 절단 이후 새 좌표가 없으면 빈 배치가
    // 나가고, 그것이 세션을 닫는 유일하게 깨끗한 방법이다 (§2).
    await uploader.cutFinal(lastAcceptedTs: lastAcceptedTs);

    // ★ 종료 시 큐를 밀어내지 않는다(예전 drain). 오프라인에서 5초를 기다리기만
    //   하다가 끝났고, 지금은 전송 자체를 수동 동기화로 옮겼다. 남은 배치는
    //   DB에 그대로 있고 홈 화면의 [서버로 보내기]가 보낸다.
    await uploader.dispose();

    await AppDb.endSession(sessionId, DateTime.now().millisecondsSinceEpoch);
    await AppDb.close();
    service.stopSelf();
  }

  if (gate.attach(shutdown)) return; // 초기화 중에 이미 종료 명령이 왔다

  // ── 위치 스트림 시작 ──
  // ★ foregroundNotificationConfig를 넣지 않는다. 알림은 서비스가 소유한다.
  final androidSettings = AndroidSettings(
    accuracy: LocationAccuracy.best,
    distanceFilter: 0, // 정지 상태에서도 표본을 받기 위해 0
    intervalDuration: Duration(seconds: 1),
    // ★ FusedLocationProvider는 화면이 꺼지면 intervalDuration을 무시하고
    //   자체적으로 갱신을 묶어서 던진다 (실측: 1초 요청 -> 8.6초 간격).
    //   포그라운드 서비스여도, 배터리 최적화 예외가 걸려 있어도 적용된다.
    //   LocationManager의 GPS_PROVIDER를 직접 쓰면 minTime을 그대로 지키므로
    //   화면 꺼진 상태에서도 원시 GNSS fix가 1Hz로 들어온다.
    forceLocationManager: true,
  );

  // ★ geolocator_android는 자기 GeolocatorLocationService가 아직 bind되지
  //   않았을 때 구독이 들어오면 에러도 없이 그냥 return한다
  //   (StreamHandlerImpl.onListen: "Location background service has not
  //   started correctly"). 스트림은 살아 있는데 좌표가 영영 안 온다.
  //   첫 fix가 너무 오래 없으면 한 번 다시 구독한다 (onTick 참고).
  int streamSubscribedAt = DateTime.now().millisecondsSinceEpoch;
  void subscribePositions() {
    streamSubscribedAt = DateTime.now().millisecondsSinceEpoch;
    posSub =
        Geolocator.getPositionStream(locationSettings: androidSettings).listen(
      (pos) {
        final ts = pos.timestamp.millisecondsSinceEpoch;
        // fix가 들어온 사실 자체는 워터마크와 무관하다. 결측 표시는 그대로 둔다.
        lastFixAt = DateTime.now().millisecondsSinceEpoch;

        // ★ ts 워터마크 (§9-4). buffer.add **직전**, 가장 상단에서 막는다.
        //   등호를 포함한다 - 같은 ts는 §2-8에서 dt == 0 -> inf 속도가 되고
        //   그게 모델 오분류로 이어진다. 같은 값도 버린다.
        //
        //   유효한 fix를 버릴 위험을 안다. 하지만 역행한 좌표는 어차피
        //   dt <= 0을 만들어 §2-11 [FIX-1]이 지적한 오염을 일으킨다.
        if (lastAcceptedTs != null && ts <= lastAcceptedTs!) {
          droppedTs++;
          return;
        }
        lastAcceptedTs = ts;

        lastLat = pos.latitude;
        lastLng = pos.longitude;
        lastAcc = pos.accuracy;
        lastSpd = pos.speed;

        buffer.add(GpsPoint(
          sessionId: sessionId,
          ts: ts,
          lat: pos.latitude,
          lng: pos.longitude,
          acc: pos.accuracy,
          spd: pos.speed,
          alt: pos.altitude,
          label: currentLabel,
        ));
        uploader.notePoint(ts);
        totalCount++;
      },
      onError: (Object e) {
        // 위치 수신 오류는 무시하고 스트림을 유지한다.
        // 터널/실내에서는 표본이 오지 않는 것이 정상이며,
        // 결측 여부는 lastFixAt으로 UI에 표시된다.
      },
      cancelOnError: false,
    );
  }

  subscribePositions();

  // ── 1초 주기 틱: 버퍼 flush + 절단/전송 + 알림 갱신 + UI 통지 ──
  Future<void> onTick() async {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (buffer.length >= K.bufferFlushCount ||
        now - lastFlushAt >= K.bufferFlushMs) {
      await flushBuffer();
    }

    // ── 배치 절단 + 전송 (§9-5, §9-6) ──
    // 절단 기준 시각은 lastAcceptedTs(GNSS 시각)다. 로컬 시계가 아니다.
    // 결측 구간에서는 절단이 자연히 멈추고, 신호가 돌아오면 밀린 구간이
    // 여러 배치로 한 번에 잘린다.
    if (lastAcceptedTs != null) {
      await uploader.maybeCut(lastAcceptedTs: lastAcceptedTs!);
    }
    // ★ 여기서 전송하지 않는다. 밖에서는 서버에 닿지 않는 것이 정상이라
    //   1초마다 실패 요청을 날릴 이유가 없다. 배치는 큐에 쌓아 두고, 집에 와서
    //   홈 화면의 [서버로 보내기](전송 전용 모드)로 한 번에 보낸다.
    //
    // ★ 절단은 그대로 돈다. 전송과 절단은 서로를 부르지 않는다 - 절단은
    //   points/batches만 만지고, 전송은 열린 창(_openFrom)을 건드리지 않는다.

    // 첫 fix가 끝내 안 오면 구독이 조용히 무시된 것일 수 있다 (subscribePositions 참고).
    // 실내 콜드 스타트도 여기 걸리지만 재구독은 GNSS 상태를 날리지 않아 무해하다.
    if (lastFixAt == null &&
        now - streamSubscribedAt >= K.firstFixResubscribeMs) {
      log('!! ${(now - streamSubscribedAt) ~/ 1000}초째 첫 fix 없음 - 위치 스트림 재구독');
      await posSub?.cancel();
      if (stopping) return;
      subscribePositions();
    }

    // ★ 버린 좌표가 비정상적으로 많으면 forceLocationManager의 부작용을
    //   의심할 근거가 된다 (§3-4). 1분에 5개 이상이면 로그에 남긴다.
    if (now - lastDropCheckAt >= 60000) {
      final delta = droppedTs - droppedTsAtLastCheck;
      if (delta >= 5) log('!! ts 역행/중복 $delta개/분 - GNSS 시각 의심');
      droppedTsAtLastCheck = droppedTs;
      lastDropCheckAt = now;
    }

    final elapsedMs = now - startedAt;
    final staleMs = lastFixAt == null ? -1 : now - lastFixAt!;

    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        final mm = (elapsedMs ~/ 60000).toString().padLeft(2, '0');
        final ss = ((elapsedMs ~/ 1000) % 60).toString().padLeft(2, '0');
        service.setForegroundNotificationInfo(
          title: '${TripLabel.emoji(currentLabel)} 궤적 수집 중 · $mm:$ss',
          content: '$totalCount 포인트 수집됨',
        );
      }
    }

    // 서비스 -> UI (유일한 통신 경로)
    service.invoke(K.evtTick, {
      'sessionId': sessionId,
      'count': totalCount,
      'buffered': buffer.length,
      'queued': uploader.queuedBatches,
      // ★ STEP G "볼 것 2번(ts 중복 유무)"의 답이 실시간으로 여기 있다.
      //   덤프 CSV를 다시 분석하지 않아도 된다 (§9-4).
      K.evtDroppedTs: droppedTs,
      'elapsedMs': elapsedMs,
      'staleMs': staleMs,
      'label': currentLabel,
      'lat': lastLat,
      'lng': lastLng,
      'acc': lastAcc,
      'spd': lastSpd,
    });
  }

  ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
    // ★ 한 틱이 1초를 넘기면 다음 틱이 겹쳐 들어온다. 절단이 겹치면 두
    //   호출이 같은 구간을 각각 다른 seq로 잘라 같은 좌표가 두 번 올라간다.
    if (stopping || tickBusy) return;
    tickBusy = true;
    try {
      await onTick();
    } finally {
      tickBusy = false;
    }
  });

  // 시작 직후 포그라운드로 승격
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }
}
