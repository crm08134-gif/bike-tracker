import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_gps_tracker/core/constants.dart';
import 'package:my_gps_tracker/data/api_client.dart';
import 'package:my_gps_tracker/data/app_db.dart';
import 'package:my_gps_tracker/service/uploader.dart';

import 'support/db_harness.dart';
import 'support/fake_gateway.dart';

const _user = '11111111-1111-4111-8111-111111111111';
const _sid = '22222222-2222-4222-8222-222222222222';
const _device = '33333333-3333-4333-8333-333333333333';

/// 기준 시각. 1Hz 좌표를 ts = _t0 + n*1000 으로 깐다.
const _t0 = 1736412300000;

void main() {
  setUpAll(() => initTestDb('uploader'));

  setUp(resetDb);
  tearDown(closeDb);

  /// [count]개의 1Hz 좌표를 sessionId에 넣고 마지막 ts를 돌려준다.
  Future<int> seedPoints(String sessionId, int count, {int from = _t0}) async {
    await AppDb.createSession(
        sessionId: sessionId, userId: _user, startedAt: from);
    final pts = [
      for (var i = 0; i < count; i++)
        GpsPoint(
          sessionId: sessionId,
          ts: from + i * 1000,
          lat: 37.5 + i * 0.0001,
          lng: 127.0,
          acc: 8.4,
          spd: 4.2,
          alt: 31.5,
          label: TripLabel.bike,
        ),
    ];
    await AppDb.insertPoints(pts);
    return from + (count - 1) * 1000;
  }

  ({Uploader up, FakeGateway gw, List<String> switches}) makeUploader(
      {String sessionId = _sid, FakeGateway? gateway}) {
    final gw = gateway ?? FakeGateway();
    final switches = <String>[];
    final up = Uploader(
      userId: _user,
      deviceId: _device,
      sessionId: sessionId,
      onSessionSwitch: (oldId, newId) async {
        switches.add(newId);
        await AppDb.createSession(
            sessionId: newId, userId: _user, startedAt: _t0);
      },
      flushBuffer: () async {},
      onLog: (_) {},
      api: ApiClient(baseUrl: 'http://fake.local', adapter: gw),
    );
    return (up: up, gw: gw, switches: switches);
  }

  // ── 절단 (§9-5, §9-1) ───────────────────────────────────

  test('30초 창이 차면 자르고, 경계 좌표는 다음 창 몫이다', () async {
    // ts = t0 .. t0+35000 (36점)
    final last = await seedPoints(_sid, 36);
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);

    await h.up.maybeCut(lastAcceptedTs: last);

    final db = await AppDb.instance;
    final rows = await db.query('batches', orderBy: 'seq');
    expect(rows, hasLength(1));
    expect(rows.first['seq'], 0);
    expect(rows.first['from_ts'], _t0);
    // ★ 반열린 구간 [from, to). to_ts와 같은 ts를 가진 좌표는 이번 배치에
    //   들어가지 않는다. 닫힌 구간이면 그 좌표가 두 배치에 모두 들어가고,
    //   서버 dedup은 seq 기준이라 이 중복을 못 잡는다.
    expect(rows.first['to_ts'], last);
    expect(rows.first['point_count'], 35); // 경계 좌표 1개 제외
    expect(rows.first['state'], BatchState.pending);
    expect(rows.first['is_last'], 0);
  });

  test('경계 좌표가 두 배치에 겹쳐 들어가지 않는다', () async {
    final last = await seedPoints(_sid, 70); // t0 .. t0+69000
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);

    await h.up.maybeCut(lastAcceptedTs: _t0 + 35000);
    await h.up.maybeCut(lastAcceptedTs: last);

    final db = await AppDb.instance;
    final rows = await db.query('batches', orderBy: 'seq');
    expect(rows, hasLength(2));
    expect(rows[0]['to_ts'], rows[1]['from_ts'], reason: '구간이 이어져야 한다');

    // 두 배치가 덮는 좌표를 합치면 겹침도 구멍도 없어야 한다.
    final a = await AppDb.readPointsRange(_sid,
        fromTs: rows[0]['from_ts'] as int, toTs: rows[0]['to_ts'] as int);
    final b = await AppDb.readPointsRange(_sid,
        fromTs: rows[1]['from_ts'] as int, toTs: rows[1]['to_ts'] as int);
    final ids = [...a, ...b].map((r) => r['id']).toList();
    expect(ids.toSet(), hasLength(ids.length), reason: '같은 좌표가 두 번 실렸다');
  });

  test('겹쳐 들어온 절단이 같은 구간을 두 번 자르지 않는다', () async {
    // ★ 티커 콜백이 async라 한 틱이 1초를 넘기면 다음 틱이 겹친다. 겹친
    //   두 호출이 같은 _openFrom을 보고 각각 자르면 같은 좌표가 다른 seq로
    //   두 번 올라가고, 서버 dedup은 (session_id, seq) 기준이라 못 잡는다.
    await seedPoints(_sid, 70);
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);

    await Future.wait([
      h.up.maybeCut(lastAcceptedTs: _t0 + 35000),
      h.up.maybeCut(lastAcceptedTs: _t0 + 35000),
    ]);

    final db = await AppDb.instance;
    expect(await db.query('batches'), hasLength(1));
  });

  test('창이 안 찼으면 자르지 않는다', () async {
    final last = await seedPoints(_sid, 10); // 9초치
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);

    await h.up.maybeCut(lastAcceptedTs: last);

    expect(await AppDb.countUnsentBatches(), 0);
  });

  test('큐가 500개면 절단을 멈추되 좌표는 버리지 않는다', () async {
    final last = await seedPoints(_sid, 36);
    // 미전송 배치를 상한까지 채워 둔다.
    for (var i = 0; i < K.maxQueuedBatches; i++) {
      await AppDb.insertBatch(
          sessionId: 'filler',
          fromTs: i,
          toTs: i + 1,
          pointCount: 0,
          isLast: false,
          createdAt: i);
    }
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);

    await h.up.maybeCut(lastAcceptedTs: last);

    final db = await AppDb.instance;
    expect(await db.query('batches', where: 'session_id = ?', whereArgs: [_sid]),
        isEmpty,
        reason: '절단은 멈춰야 한다');
    // ★ 좌표는 그대로 있다. 상한은 절단을 미루는 장치이지 버리는 장치가 아니다.
    expect(await AppDb.countPoints(_sid), 36);
  });

  test('마지막 절단 이후 좌표가 없으면 빈 배치로 세션을 닫는다', () async {
    await AppDb.createSession(
        sessionId: _sid, userId: _user, startedAt: _t0);
    final h = makeUploader();
    await h.up.init();

    // 좌표를 한 번도 못 받고 종료한 세션.
    await h.up.cutFinal(lastAcceptedTs: null);
    await h.up.pumpAndWait();

    expect(h.gw.requests, hasLength(1));
    final req = h.gw.requests.single;
    // ★ 빈 배열이 세션을 닫는 유일하게 깨끗한 방법이다 (§2). 이게 없으면
    //   앱이 "닫을 좌표가 생길 때까지 대기"라는 죽은 분기를 갖게 된다.
    expect(req['points'], isEmpty);
    expect(req['is_last_batch'], true);
  });

  test('마지막 배치는 마지막 좌표까지 포함한다', () async {
    final last = await seedPoints(_sid, 5);
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);

    await h.up.cutFinal(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final req = h.gw.requests.single;
    expect(req['is_last_batch'], true);
    expect((req['points'] as List), hasLength(5));
    expect((req['points'] as List).last['ts'], last);
  });

  // ── seq 멱등성 규약 (§5) ─────────────────────────────────

  test('seq는 0부터 구멍 없이, 재시작해도 MAX(seq)+1로 이어진다', () async {
    await seedPoints(_sid, 100);
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: _t0 + 30000);
    await h.up.maybeCut(lastAcceptedTs: _t0 + 60000);

    // 서비스가 죽었다 살아난다: 메모리 상태를 버리고 DB에서만 복구한다.
    final h2 = makeUploader();
    await h2.up.init();
    await h2.up.maybeCut(lastAcceptedTs: _t0 + 99000);

    final db = await AppDb.instance;
    final seqs = (await db.query('batches',
            columns: ['seq'], where: 'session_id = ?', whereArgs: [_sid], orderBy: 'seq'))
        .map((r) => r['seq'])
        .toList();
    expect(seqs, [0, 1, 2]);
  });

  test('재시작 후에도 열린 창이 이어져 좌표가 구멍나지 않는다', () async {
    await seedPoints(_sid, 100);
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: _t0 + 30000);

    // ★ 재시작하면 메모리의 열린 창이 사라진다. 마지막 배치의 to_ts가
    //   그 자리를 안다 - 이게 없으면 재시작 시점 이전 좌표가 어느 배치에도
    //   안 잡힌 채 영원히 남는다.
    final h2 = makeUploader();
    await h2.up.init();
    await h2.up.maybeCut(lastAcceptedTs: _t0 + 99000);

    final db = await AppDb.instance;
    final rows = await db.query('batches', orderBy: 'seq');
    expect(rows[0]['to_ts'], rows[1]['from_ts']);
  });

  // ── 전송 결과 처리 (§3, §4) ──────────────────────────────

  test('202면 duplicate여도 SENT다', () async {
    final last = await seedPoints(_sid, 36);
    final gw = FakeGateway()
      ..responder = (req) => (
            202,
            {
              'session_id': req['session_id'],
              'seq': req['seq'],
              'session_state': RemoteSessionState.active,
              'duplicate': true,
              'server_time': 1,
            }
          );
    final h = makeUploader(gateway: gw);
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final db = await AppDb.instance;
    final row = (await db.query('batches')).single;
    expect(row['state'], BatchState.sent);
    expect(await AppDb.countUnsentBatches(), 0);
  });

  test('5xx는 재시도 예약, 배치는 큐에 남는다', () async {
    final last = await seedPoints(_sid, 36);
    final gw = FakeGateway()..responder = (_) => (500, <String, Object?>{});
    final h = makeUploader(gateway: gw);
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final db = await AppDb.instance;
    final row = (await db.query('batches')).single;
    expect(row['state'], BatchState.failed);
    expect(row['retry_count'], 1);
    expect(row['next_try_at'], isNotNull);
    expect(await AppDb.countUnsentBatches(), 1, reason: '큐에서 사라지면 안 된다');
  });

  test('타임아웃도 재시도 대상이다', () async {
    final last = await seedPoints(_sid, 36);
    final gw = FakeGateway()..transportError = DioExceptionType.connectionTimeout;
    final h = makeUploader(gateway: gw);
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final db = await AppDb.instance;
    expect((await db.query('batches')).single['state'], BatchState.failed);
  });

  test('retryable:false만 DEAD로 끝난다 - 상태 코드로 추론하지 않는다', () async {
    final last = await seedPoints(_sid, 36);
    final gw = FakeGateway()
      ..responder = (_) => (
            400,
            {
              'error': 'SCHEMA_VIOLATION',
              'detail': 'seq must be >= 0',
              'retryable': false,
            }
          );
    final h = makeUploader(gateway: gw);
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final db = await AppDb.instance;
    expect((await db.query('batches')).single['state'], BatchState.dead);
    expect(await AppDb.countUnsentBatches(), 0);
  });

  test('4xx라도 서버가 retryable:true라고 하면 재시도한다', () async {
    // ★ v3에서 데이터가 소멸한 경로가 정확히 "4xx니까 폐기"라는 추론이었다.
    //   판단은 서버가 명시하고 앱은 따르기만 한다 (§4).
    final last = await seedPoints(_sid, 36);
    final gw = FakeGateway()
      ..responder = (_) => (429, {'error': 'SLOW_DOWN', 'retryable': true});
    final h = makeUploader(gateway: gw);
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final db = await AppDb.instance;
    expect((await db.query('batches')).single['state'], BatchState.failed);
  });

  // ── ABANDONED (§6 C-2) ──────────────────────────────────

  test('ABANDONED: 큐를 비우지 않고 새 세션으로 갈아탄다', () async {
    final last = await seedPoints(_sid, 66); // 두 창 분량
    final gw = FakeGateway(state: RemoteSessionState.abandoned);
    final h = makeUploader(gateway: gw);
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: _t0 + 30000);
    await h.up.maybeCut(lastAcceptedTs: _t0 + 60000);
    await h.up.pumpAndWait();

    expect(h.switches, hasLength(1));
    final successor = h.switches.single;
    expect(successor, isNot(_sid));
    expect(h.up.sessionId, successor);

    final st = await AppDb.uploadState(_sid);
    expect(st!['remote_state'], RemoteSessionState.abandoned);
    expect(st['successor_session_id'], successor);

    // ★ 큐를 비우지 않는다 (C-2). ABANDONED가 오는 순간이 큐가 가장 꽉 찬
    //   시각이다. 서버는 R2에 따라 죽은 세션 배치도 202로 받는다.
    final db = await AppDb.instance;
    final old = await db.query('batches',
        where: 'session_id = ?', whereArgs: [_sid]);
    expect(old, isNotEmpty);
    expect(old.every((r) => r['state'] != BatchState.dead), isTrue);

    // 남은 좌표는 구 세션 몫으로 마저 잘려 있어야 한다.
    expect(await AppDb.firstUncutTs(_sid), last + 1);
  });

  test('ABANDONED 응답이 여러 번 와도 새 세션은 한 번만 발급된다', () async {
    // ★ 이 가드가 없으면 응답 한 개마다 세션이 하나씩 생겨 폭증한다.
    //   판정 기준은 응답의 session_id다.
    await seedPoints(_sid, 100);
    final gw = FakeGateway(state: RemoteSessionState.abandoned);
    final h = makeUploader(gateway: gw);
    await h.up.init();
    h.up.notePoint(_t0);
    for (var t = 30000; t <= 90000; t += 30000) {
      await h.up.maybeCut(lastAcceptedTs: _t0 + t);
    }
    // 죽은 세션의 배치가 여러 개 남아 있어 ABANDONED가 계속 돌아온다.
    await h.up.pumpAndWait();
    await h.up.pumpAndWait();
    await h.up.pumpAndWait();

    expect(h.switches, hasLength(1), reason: '세션이 폭증했다');
  });

  test('ABANDONED 이후 좌표는 승계 세션으로 들어간다', () async {
    final last = await seedPoints(_sid, 36);
    final gw = FakeGateway(state: RemoteSessionState.abandoned);
    final h = makeUploader(gateway: gw);
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final successor = h.switches.single;
    gw.state = RemoteSessionState.active;

    // 승계 세션에 새 좌표가 들어온다. seq는 0부터 다시 시작한다.
    final newFrom = last + 1000;
    await AppDb.insertPoints([
      for (var i = 0; i < 40; i++)
        GpsPoint(
            sessionId: successor,
            ts: newFrom + i * 1000,
            lat: 37.6,
            lng: 127.0,
            label: TripLabel.bike),
    ]);
    h.up.notePoint(newFrom);
    await h.up.maybeCut(lastAcceptedTs: newFrom + 39000);

    final db = await AppDb.instance;
    final rows = await db.query('batches',
        where: 'session_id = ?', whereArgs: [successor], orderBy: 'seq');
    expect(rows, hasLength(1));
    expect(rows.single['seq'], 0, reason: '새 세션의 seq는 0부터다');
  });

  // ── 페이로드 (§2) ───────────────────────────────────────

  test('전송 본문이 계약 §2 모양이다', () async {
    final last = await seedPoints(_sid, 36);
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final req = h.gw.requests.single;
    expect(h.gw.paths.single, '/api/v1/sessions/$_sid/batches');
    expect(req['user_id'], _user);
    expect(req['device_id'], _device);
    // 경로에서 뽑은 값이다. 본문에 있었으면 FakeGateway가 이미 던졌다.
    expect(req['session_id'], _sid);
    expect(req['seq'], 0);
    expect(req['is_last_batch'], false);
    expect(req['sent_at'], isA<int>());

    final pt = (req['points'] as List).first as Map<String, dynamic>;
    expect(pt.keys, containsAll(['ts', 'lat', 'lng', 'acc', 'spd', 'alt', 'label']));
    expect(pt['ts'], _t0);
    // STEP F 정답 라벨이라 2단계에서도 계속 보낸다 (§14).
    expect(pt['label'], TripLabel.bike);
  });

  test('null 필드는 본문에서 빠진다', () async {
    await AppDb.createSession(
        sessionId: _sid, userId: _user, startedAt: _t0);
    await AppDb.insertPoints([
      for (var i = 0; i < 40; i++)
        GpsPoint(
            sessionId: _sid,
            ts: _t0 + i * 1000,
            lat: 37.5,
            lng: 127.0,
            label: TripLabel.none), // acc/spd/alt 없음
    ]);
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);
    await h.up.maybeCut(lastAcceptedTs: _t0 + 39000);
    await h.up.pumpAndWait();

    final pt = ((h.gw.requests.single['points'] as List).first) as Map;
    expect(pt.containsKey('acc'), isFalse);
    expect(pt.containsKey('spd'), isFalse);
    expect(pt['label'], TripLabel.none);
  });

  // ── 큐 (§9-6) ───────────────────────────────────────────

  test('이전 세션 백로그를 같은 큐에서 이어 보낸다', () async {
    // 지난 세션이 미전송 배치를 남기고 끝났다.
    await seedPoints('old-session', 40);
    await AppDb.insertBatch(
        sessionId: 'old-session',
        fromTs: _t0,
        toTs: _t0 + 39000,
        pointCount: 39,
        isLast: true,
        createdAt: _t0);

    // 새 세션이 시작한다.
    final last = await seedPoints(_sid, 36, from: _t0 + 100000);
    final h = makeUploader();
    await h.up.init();
    expect(h.up.queuedBatches, 1, reason: '백로그를 이어받아야 한다');

    h.up.notePoint(_t0 + 100000);
    await h.up.maybeCut(lastAcceptedTs: last);
    await h.up.pumpAndWait();

    final sent = h.gw.requests.map((r) => r['session_id']).toSet();
    expect(sent, containsAll(['old-session', _sid]));
    expect(await AppDb.countUnsentBatches(), 0);
  });

  test('동시 전송은 3건을 넘지 않는다', () async {
    await seedPoints(_sid, 400);
    final h = makeUploader();
    await h.up.init();
    h.up.notePoint(_t0);
    for (var t = 30000; t <= 390000; t += 30000) {
      await h.up.maybeCut(lastAcceptedTs: _t0 + t);
    }
    expect(await AppDb.countUnsentBatches(), 13);

    final started = await h.up.pump();
    expect(started, K.maxConcurrentUploads);

    // 날고 있는 3건을 거둬들이고 끝낸다. tearDown이 DB를 닫으므로
    // 여기서 안 기다리면 전송이 닫힌 DB를 읽는다.
    await h.up.pumpAndWait();
    expect(h.gw.requests, hasLength(K.maxConcurrentUploads));
  });
}
