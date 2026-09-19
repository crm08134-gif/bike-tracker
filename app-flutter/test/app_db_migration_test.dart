import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:my_gps_tracker/core/constants.dart';
import 'package:my_gps_tracker/data/app_db.dart';
import 'package:my_gps_tracker/data/prediction.dart';

import 'support/db_harness.dart';

/// 마이그레이션은 폰에 든 실주행 데이터를 걸고 하는 일이라 여기서 막는다.
void main() {
  setUpAll(() => initTestDb('migration'));

  setUp(resetDb);
  tearDown(closeDb);

  test('신규 설치(onCreate)에도 v2·v3 테이블이 있다', () async {
    // ★ onCreate에 _createV2Tables를 빠뜨리는 것이 sqflite에서 가장 흔한
    //   사고다. 개발자 폰은 업그레이드 경로라 멀쩡하고 신규 설치만 터진다.
    final db = await AppDb.instance;

    expect(await tableExists(db, 'batches'), isTrue);
    expect(await tableExists(db, 'session_upload_state'), isTrue);
    expect(await tableExists(db, 'prediction_fetch'), isTrue);
    expect(await tableExists(db, 'prediction_points'), isTrue);
    expect(await db.getVersion(), 3);
  });

  test('v2 -> v3 업그레이드가 기존 좌표와 전송 큐를 그대로 둔다', () async {
    // 현재 폰(v2) 상태를 만든다: v3 코드로 만든 뒤 판정 테이블을 지우고 버전을 내린다.
    await AppDb.createSession(sessionId: 's-v2', userId: 'u', startedAt: 100);
    await AppDb.insertPoints([
      const GpsPoint(
          sessionId: 's-v2', ts: 100, lat: 1, lng: 2, label: TripLabel.bike),
    ]);
    await AppDb.insertBatch(
        sessionId: 's-v2',
        fromTs: 100,
        toTs: 200,
        pointCount: 1,
        isLast: false,
        createdAt: 100);
    final v3 = await AppDb.instance;
    await v3.execute('DROP TABLE prediction_points');
    await v3.execute('DROP TABLE prediction_fetch');
    await v3.setVersion(2);
    await AppDb.close();

    final db = await AppDb.instance;

    expect(await db.getVersion(), 3);
    expect(await tableExists(db, 'prediction_fetch'), isTrue);
    expect(await tableExists(db, 'prediction_points'), isTrue);
    expect(await AppDb.countUnsentBatches(), 1);
    final pts = await AppDb.readPointsChunk('s-v2', limit: 10, offset: 0);
    expect(pts, hasLength(1));
    expect(pts.first['label'], TripLabel.bike);
  });

  test('v1 -> v2 업그레이드가 기존 좌표를 그대로 둔다', () async {
    // 버전 1 시절의 DB를 손으로 만든다.
    final v1 = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE sessions (session_id TEXT PRIMARY KEY,'
              ' user_id TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER)');
          await db.execute('CREATE TABLE points (id INTEGER PRIMARY KEY AUTOINCREMENT,'
              ' session_id TEXT NOT NULL, ts INTEGER NOT NULL, lat REAL NOT NULL,'
              ' lng REAL NOT NULL, acc REAL, spd REAL, alt REAL,'
              " label TEXT NOT NULL DEFAULT 'NONE', uploaded INTEGER NOT NULL DEFAULT 0)");
          await db.execute(
              'CREATE INDEX idx_points_session_ts ON points(session_id, ts)');
        },
      ),
    );
    await v1.insert('sessions', {
      'session_id': 's-old',
      'user_id': 'u',
      'started_at': 1000,
      'ended_at': 2000,
    });
    await v1.insert('points', {
      'session_id': 's-old',
      'ts': 1500,
      'lat': 37.5,
      'lng': 127.0,
      'label': 'BIKE',
    });
    await v1.close();

    final db = await AppDb.instance;

    expect(await db.getVersion(), 3);
    expect(await tableExists(db, 'batches'), isTrue);
    expect(await tableExists(db, 'session_upload_state'), isTrue);

    // ★ 백필하지 않는다 (§9-2). 이미 끝난 세션이고 CSV로 이미 값을 뽑았다.
    //   백필하면 과거 덤프 로그가 통째로 서버로 올라간다.
    expect(await AppDb.countUnsentBatches(), 0);

    // 기존 좌표는 손대지 않는다.
    final pts = await AppDb.readPointsChunk('s-old', limit: 10, offset: 0);
    expect(pts, hasLength(1));
    expect(pts.first['label'], 'BIKE');
    expect(pts.first['ts'], 1500);
  });

  test('deleteSession이 판정 캐시까지 모든 테이블을 지운다', () async {
    // FK 선언이 없어 PRAGMA foreign_keys가 무효라(§6-3) 손으로 지워야 한다.
    await AppDb.createSession(
        sessionId: 's1', userId: 'u', startedAt: 100);
    await AppDb.insertPoints([
      const GpsPoint(
          sessionId: 's1', ts: 100, lat: 1, lng: 2, label: TripLabel.bike),
    ]);
    await AppDb.insertBatch(
        sessionId: 's1',
        fromTs: 100,
        toTs: 200,
        pointCount: 1,
        isLast: false,
        createdAt: 100);
    await AppDb.putUploadState('s1',
        remoteState: RemoteSessionState.active);
    await AppDb.replacePredictions(const PredictionSnapshot(
      sessionId: 's1',
      sessionState: 'CLOSED',
      totalPoints: 1,
      predictedPoints: 1,
      unpredictablePoints: 0,
      waitingBatches: 0,
      fetchedAt: 300,
      points: [PredictedPoint(ts: 100, lat: 1, lng: 2, label: 'bike')],
    ));

    await AppDb.deleteSession('s1');

    final db = await AppDb.instance;
    for (final t in [
      'points',
      'batches',
      'session_upload_state',
      'sessions',
      'prediction_fetch',
      'prediction_points',
    ]) {
      final rows = await db.query(t, where: 'session_id = ?', whereArgs: ['s1']);
      expect(rows, isEmpty, reason: '$t 에 고아 행이 남았다');
    }
  });
}
