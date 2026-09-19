import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
import 'prediction.dart';
import 'track.dart';

/// sqflite 래퍼.
///
/// ★ 접근 규칙 (isolate 안전성)
/// - 수집 중(서비스 실행 중)에는 **서비스 isolate만** 쓰기를 한다.
/// - UI isolate는 수집이 정지된 상태에서만 읽기(목록/CSV 내보내기)를 한다.
///   예외로 세션 삭제와 판정 캐시(prediction_*) 쓰기를 하는데, 둘 다 세션 목록에서만
///   들어가는 경로라 수집이 정지된 상태가 보장된다.
/// - 두 isolate는 각자의 static _db 인스턴스를 갖는다. 동시 쓰기를 하지 않으므로
///   sqlite의 파일 락 충돌이 발생하지 않는다.
class AppDb {
  static Database? _db;

  /// ★ 1 -> 2. 올리는 순간이 이 프로젝트의 **첫 마이그레이션 시행**이다.
  ///   한 번에 한 가지만 바꾼다: 테이블 추가만 하고 ALTER/DROP은 하지 않는다.
  /// 2 -> 3: 서버 판정 캐시 테이블 추가. 같은 규칙으로 테이블만 늘린다.
  static const _dbVersion = 3;

  static Future<Database> get instance async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    // ★ 파일명은 'bike_tracker.db'로 유지한다. 패키지명을 my_gps_tracker로
    //   통일하는 정리(§13)에 이 이름은 포함되지 않는다 - 바꾸는 순간
    //   1단계에서 모은 실주행 로그가 통째로 사라진다.
    final path = p.join(dir, 'bike_tracker.db');
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createV1Tables(db);
        // ★ 새로 설치한 기기도 v2 테이블이 필요하다. 이걸 빠뜨리는 것이
        //   sqflite 마이그레이션에서 가장 흔한 사고다. 개발자 폰은 업그레이드
        //   경로라 멀쩡하고, 신규 설치에서만 'no such table: batches'가 난다.
        await _createV2Tables(db);
        await _createV3Tables(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          // ★ 테이블 추가만. ALTER/DROP/데이터 이동 전부 금지.
          //   폰에 실주행 데이터가 들어 있다.
          await _createV2Tables(db);
        }
        if (oldV < 3) {
          await _createV3Tables(db);
        }
      },
    );
    return _db!;
  }

  static Future<void> _createV1Tables(Database db) async {
    await db.execute('''
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        user_id    TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at   INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE points (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        ts         INTEGER NOT NULL,
        lat        REAL NOT NULL,
        lng        REAL NOT NULL,
        acc        REAL,
        spd        REAL,
        alt        REAL,
        label      TEXT NOT NULL DEFAULT 'NONE',
        uploaded   INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_points_session_ts ON points(session_id, ts)',
    );
  }

  /// 전송 큐 (§9-1). 좌표를 복사하지 않고 `[from_ts, to_ts)` 구간만 잡는다.
  static Future<void> _createV2Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS batches (
        session_id  TEXT    NOT NULL,
        seq         INTEGER NOT NULL,
        from_ts     INTEGER NOT NULL,
        to_ts       INTEGER NOT NULL,
        point_count INTEGER NOT NULL,
        is_last     INTEGER NOT NULL DEFAULT 0,
        state       TEXT    NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        next_try_at INTEGER,
        created_at  INTEGER NOT NULL,
        sent_at     INTEGER,
        PRIMARY KEY (session_id, seq)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS session_upload_state (
        session_id           TEXT    PRIMARY KEY,
        remote_state         TEXT    NOT NULL,
        successor_session_id TEXT,
        last_watermark_ts    INTEGER,
        updated_at           INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_batches_queue ON batches (state, next_try_at)');
    // idx_points_session_ts는 v1 onCreate에 이미 있다. IF NOT EXISTS라 무해하다.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_points_session_ts ON points (session_id, ts)');
  }

  /// 서버 판정 캐시. `points`에 컬럼을 붙이지 않고 따로 둔다.
  ///
  /// ★ 따로 두는 이유:
  ///   - ALTER 금지 규칙(위 _dbVersion 참고). 폰에 실주행 데이터가 있다.
  ///   - 서버 좌표는 폰 좌표의 부분집합이다. 정확도 20m 초과·ts 역행 좌표는
  ///     서버에 없어서 `points` 행에 1:1로 붙지 않는다. 폰과 맞출 때는 (session_id, ts)로 잇는다.
  ///   - 새로고침마다 세션 단위로 통째로 바꾼다. 수집 데이터(`points`) 행을 건드리지 않고
  ///     지우고 다시 넣을 수 있다.
  static Future<void> _createV3Tables(Database db) async {
    // 조회 한 번의 머리 정보. 행이 있으면 캐시가 있는 것이다.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS prediction_fetch (
        session_id           TEXT    PRIMARY KEY,
        fetched_at           INTEGER NOT NULL,
        session_state        TEXT    NOT NULL,
        total_points         INTEGER NOT NULL,
        predicted_points     INTEGER NOT NULL,
        unpredictable_points INTEGER NOT NULL,
        waiting_batches      INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS prediction_points (
        session_id          TEXT    NOT NULL,
        ts                  INTEGER NOT NULL,
        lat                 REAL    NOT NULL,
        lng                 REAL    NOT NULL,
        predicted_label     TEXT,
        predicted_prob_bike REAL,
        PRIMARY KEY (session_id, ts)
      )
    ''');
  }

  /// 이 isolate가 들고 있는 핸들을 닫는다.
  /// UI가 읽기를 마친 뒤 호출해 두면 서비스 시작 시 락 충돌 여지가 줄어든다.
  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ── 세션 ────────────────────────────────────────────────

  static Future<void> createSession({
    required String sessionId,
    required String userId,
    required int startedAt,
  }) async {
    final db = await instance;
    await db.insert(
      'sessions',
      {
        'session_id': sessionId,
        'user_id': userId,
        'started_at': startedAt,
        'ended_at': null,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> endSession(String sessionId, int endedAt) async {
    final db = await instance;
    await db.update(
      'sessions',
      {'ended_at': endedAt},
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  static Future<List<SessionSummary>> listSessions() async {
    final db = await instance;
    final rows = await db.rawQuery('''
      SELECT s.session_id, s.user_id, s.started_at, s.ended_at,
             (SELECT COUNT(*) FROM points p WHERE p.session_id = s.session_id) AS cnt
      FROM sessions s
      ORDER BY s.started_at DESC
    ''');
    return rows
        .map((r) => SessionSummary(
              sessionId: r['session_id'] as String,
              userId: r['user_id'] as String,
              startedAt: r['started_at'] as int,
              endedAt: r['ended_at'] as int?,
              pointCount: (r['cnt'] as int?) ?? 0,
            ))
        .toList();
  }

  static Future<void> deleteSession(String sessionId) async {
    final db = await instance;
    // ★ PRAGMA foreign_keys는 켜져 있지만 FK 선언이 없어 무효다(§6-3).
    //   모든 테이블을 손으로 지우는 것이 유일한 방법이다.
    await db.transaction((txn) async {
      await txn.delete('prediction_points',
          where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('prediction_fetch',
          where: 'session_id = ?', whereArgs: [sessionId]);
      await txn
          .delete('points', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn
          .delete('batches', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('session_upload_state',
          where: 'session_id = ?', whereArgs: [sessionId]);
      await txn
          .delete('sessions', where: 'session_id = ?', whereArgs: [sessionId]);
    });
  }

  // ── 좌표 ────────────────────────────────────────────────

  /// 버퍼에 모인 좌표를 한 트랜잭션으로 일괄 삽입한다.
  /// 매 건 개별 insert 하면 1Hz에서 I/O 부담이 커진다.
  static Future<void> insertPoints(List<GpsPoint> points) async {
    if (points.isEmpty) return;
    final db = await instance;
    final batch = db.batch();
    for (final pt in points) {
      batch.insert('points', pt.toMap());
    }
    await batch.commit(noResult: true);
  }

  static Future<int> countPoints(String sessionId) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM points WHERE session_id = ?',
      [sessionId],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// CSV 내보내기용. 대용량 세션에서도 메모리를 아끼려면
  /// limit/offset으로 나눠 읽는다.
  static Future<List<Map<String, Object?>>> readPointsChunk(
    String sessionId, {
    required int limit,
    required int offset,
  }) async {
    final db = await instance;
    return db.query(
      'points',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'ts ASC, id ASC',
      limit: limit,
      offset: offset,
    );
  }

  /// 주행 기록 지도용. 좌표 세 컬럼만 ts 순으로 읽는다. **읽기만 한다** -
  /// 화면에서 솎아낸 좌표를 여기로 되돌려 쓰지 않는다.
  static Future<List<TrackPoint>> readTrackPoints(String sessionId) async {
    final db = await instance;
    final rows = await db.query(
      'points',
      columns: ['ts', 'lat', 'lng'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'ts ASC, id ASC',
    );
    return [
      for (final r in rows)
        TrackPoint(
          ts: r['ts'] as int,
          lat: (r['lat'] as num).toDouble(),
          lng: (r['lng'] as num).toDouble(),
        ),
    ];
  }

  /// 배치가 잡은 `[from_ts, to_ts)` 구간을 그대로 다시 읽는다 (§5 페이로드 뒤바뀜).
  static Future<List<Map<String, Object?>>> readPointsRange(
    String sessionId, {
    required int fromTs,
    required int toTs,
  }) async {
    final db = await instance;
    return db.query(
      'points',
      where: 'session_id = ? AND ts >= ? AND ts < ?',
      whereArgs: [sessionId, fromTs, toTs],
      orderBy: 'ts ASC, id ASC',
    );
  }

  static Future<int> countPointsRange(
    String sessionId, {
    required int fromTs,
    required int toTs,
  }) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM points '
      'WHERE session_id = ? AND ts >= ? AND ts < ?',
      [sessionId, fromTs, toTs],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// 워터마크 복구용 (§9-4). 서비스가 죽었다 살아나도 이어진다.
  static Future<int?> maxPointTs(String sessionId) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT MAX(ts) AS m FROM points WHERE session_id = ?',
      [sessionId],
    );
    return r.first['m'] as int?;
  }

  // ── 전송 큐 (§9-1, §9-6) ────────────────────────────────

  /// 배치를 절단해 PENDING으로 적재하고 확정된 `seq`를 돌려준다.
  ///
  /// ★ seq 채번과 INSERT가 한 트랜잭션이어야 한다 (§5 ②).
  ///   `points.uploaded`로는 복구가 불가능하므로 `MAX(seq)+1`이 유일한 채번식이고,
  ///   조회와 삽입이 갈라지면 재시작 후 같은 좌표에 다른 seq가 붙어
  ///   서버 dedup(session_id, seq)을 그대로 통과한다.
  static Future<int> insertBatch({
    required String sessionId,
    required int fromTs,
    required int toTs,
    required int pointCount,
    required bool isLast,
    required int createdAt,
  }) async {
    final db = await instance;
    return db.transaction<int>((txn) async {
      final r = await txn.rawQuery(
        'SELECT COALESCE(MAX(seq) + 1, 0) AS s FROM batches WHERE session_id = ?',
        [sessionId],
      );
      final seq = (r.first['s'] as int?) ?? 0;
      await txn.insert('batches', {
        'session_id': sessionId,
        'seq': seq,
        'from_ts': fromTs,
        'to_ts': toTs,
        'point_count': pointCount,
        'is_last': isLast ? 1 : 0,
        'state': BatchState.pending,
        'retry_count': 0,
        'next_try_at': null,
        'created_at': createdAt,
        'sent_at': null,
      });
      return seq;
    });
  }

  /// 보낼 차례가 된 배치. **세션으로 거르지 않는다** - 이전 세션 백로그도
  /// 같은 큐에서 이어 보낸다. 전송 순서는 정확성에 영향이 없다 (§9-6).
  static Future<List<Map<String, Object?>>> dueBatches({
    required int now,
    required int limit,
  }) async {
    final db = await instance;
    return db.rawQuery(
      'SELECT * FROM batches '
      " WHERE state IN ('${BatchState.pending}', '${BatchState.failed}') "
      '   AND (next_try_at IS NULL OR next_try_at <= ?) '
      ' ORDER BY created_at ASC, seq ASC '
      ' LIMIT ?',
      [now, limit],
    );
  }

  /// 미전송(=아직 큐에 살아 있는) 배치 수. 절단 보류 판단에 쓴다 (§9-5).
  static Future<int> countUnsentBatches() async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM batches '
      " WHERE state IN ('${BatchState.pending}', '${BatchState.failed}')",
    );
    return (r.first['c'] as int?) ?? 0;
  }

  static Future<void> markBatchSent(
      String sessionId, int seq, int sentAt) async {
    final db = await instance;
    await db.update(
      'batches',
      {'state': BatchState.sent, 'sent_at': sentAt},
      where: 'session_id = ? AND seq = ?',
      whereArgs: [sessionId, seq],
    );
  }

  /// 재시도 예약. `retryCount`는 호출부가 증가시킨 값을 넘긴다.
  static Future<void> markBatchRetry(
    String sessionId,
    int seq, {
    required int retryCount,
    required int nextTryAt,
  }) async {
    final db = await instance;
    await db.update(
      'batches',
      {
        'state': BatchState.failed,
        'retry_count': retryCount,
        'next_try_at': nextTryAt,
      },
      where: 'session_id = ? AND seq = ?',
      whereArgs: [sessionId, seq],
    );
  }

  /// 서버가 `retryable:false`를 준 경우. 큐에서 빠지고 DB에는 남는다.
  static Future<void> markBatchDead(String sessionId, int seq) async {
    final db = await instance;
    await db.update(
      'batches',
      {'state': BatchState.dead},
      where: 'session_id = ? AND seq = ?',
      whereArgs: [sessionId, seq],
    );
  }

  // ── 세션의 서버측 상태 (§9-1, C-2) ──────────────────────

  static Future<Map<String, Object?>?> uploadState(String sessionId) async {
    final db = await instance;
    final rows = await db.query(
      'session_upload_state',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<String?> remoteState(String sessionId) async =>
      (await uploadState(sessionId))?['remote_state'] as String?;

  /// remote_state를 기록한다. `successorSessionId`/`watermarkTs`는
  /// null을 넘기면 기존 값을 지우지 않고 그대로 둔다.
  static Future<void> putUploadState(
    String sessionId, {
    required String remoteState,
    String? successorSessionId,
    int? watermarkTs,
  }) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final existing = await txn.query('session_upload_state',
          where: 'session_id = ?', whereArgs: [sessionId], limit: 1);
      final row = <String, Object?>{
        'session_id': sessionId,
        'remote_state': remoteState,
        'successor_session_id': successorSessionId ??
            (existing.isEmpty
                ? null
                : existing.first['successor_session_id'] as String?),
        'last_watermark_ts': watermarkTs ??
            (existing.isEmpty
                ? null
                : existing.first['last_watermark_ts'] as int?),
        'updated_at': now,
      };
      await txn.insert('session_upload_state', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// 아직 어떤 배치에도 안 잡힌 첫 좌표의 ts. 열린 창의 `from_ts`가 된다.
  ///
  /// ★ 서비스가 안드로이드에 죽었다 살아난 경우가 이 함수가 있는 이유다.
  ///   메모리의 열린 창은 사라졌지만 마지막 배치의 `to_ts`가 그 자리를 안다.
  ///   배치가 하나도 없으면 세션의 첫 좌표부터다. null이면 좌표가 아직 없다.
  static Future<int?> firstUncutTs(String sessionId) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT COALESCE('
      '  (SELECT MAX(to_ts) FROM batches WHERE session_id = ?),'
      '  (SELECT MIN(ts)    FROM points  WHERE session_id = ?)'
      ') AS t',
      [sessionId, sessionId],
    );
    return r.first['t'] as int?;
  }

  /// 구간 안에서 `offset`번째 좌표의 ts. 창 하나가 MAX_POINTS_PER_BATCH를
  /// 넘길 때 쪼갤 경계를 찾는 데만 쓴다.
  static Future<int?> pointTsAtOffset(
    String sessionId, {
    required int fromTs,
    required int toTs,
    required int offset,
  }) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT ts FROM points '
      ' WHERE session_id = ? AND ts >= ? AND ts < ? '
      ' ORDER BY ts ASC LIMIT 1 OFFSET ?',
      [sessionId, fromTs, toTs, offset],
    );
    return r.isEmpty ? null : r.first['ts'] as int?;
  }

  /// 세션의 배치 상태별 개수. 판정 화면의 "전송 중" 표시용 (서버를 부르지 않는다).
  static Future<Map<String, int>> countBatchesByState(String sessionId) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT state, COUNT(*) AS c FROM batches WHERE session_id = ? GROUP BY state',
      [sessionId],
    );
    return {for (final r in rows) r['state'] as String: (r['c'] as int?) ?? 0};
  }

  /// 세션을 가리지 않은 배치 상태 집계. 전송 큐가 세션으로 거르지 않으므로
  /// 홈 화면의 "미전송 N건"과 동기화 결과의 DEAD 건수는 이 값을 쓴다.
  static Future<Map<String, int>> countBatchesByStateAll() async {
    final db = await instance;
    final rows =
        await db.rawQuery('SELECT state, COUNT(*) AS c FROM batches GROUP BY state');
    return {for (final r in rows) r['state'] as String: (r['c'] as int?) ?? 0};
  }

  /// 아직 서버에 못 보낸 배치가 있는 세션 목록 (오래된 세션 먼저).
  /// 동기화가 끝난 뒤 어느 판정 화면으로 보낼지 정하는 데 쓴다.
  static Future<List<String>> sessionIdsWithUnsentBatches() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT session_id, MIN(created_at) AS first_at FROM batches '
      " WHERE state IN ('${BatchState.pending}', '${BatchState.failed}') "
      ' GROUP BY session_id ORDER BY first_at ASC',
    );
    return [for (final r in rows) r['session_id'] as String];
  }

  /// FAILED 배치의 재시도 대기(`next_try_at`)를 풀어 곧바로 보낼 수 있게 한다.
  /// 바뀐 행 수를 돌려준다.
  ///
  /// ★ 수동 동기화에서만 부른다. 백오프는 "서버가 곧 살아난다"는 전제인데,
  ///   사용자가 직접 [서버로 보내기]를 눌렀다면 그 전제가 이미 깨진 것이다.
  ///
  /// ★ DEAD는 건드리지 않는다. 서버가 "절대 성공 못 한다"고 답한 배치다.
  ///   `retry_count`도 그대로 둔다 - 다시 실패하면 원래 간격으로 이어진다.
  static Future<int> clearRetryBackoff() async {
    final db = await instance;
    return db.update(
      'batches',
      {'next_try_at': null},
      where: 'state = ? AND next_try_at IS NOT NULL',
      whereArgs: [BatchState.failed],
    );
  }

  // ── 서버 판정 캐시 ──────────────────────────────────────

  /// 세션의 캐시를 [snap]으로 통째로 바꾼다. 도중에 실패하면 이전 캐시가 남는다.
  static Future<void> replacePredictions(PredictionSnapshot snap) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete('prediction_points',
          where: 'session_id = ?', whereArgs: [snap.sessionId]);
      await txn.insert(
        'prediction_fetch',
        {
          'session_id': snap.sessionId,
          'fetched_at': snap.fetchedAt,
          'session_state': snap.sessionState,
          'total_points': snap.totalPoints,
          'predicted_points': snap.predictedPoints,
          'unpredictable_points': snap.unpredictablePoints,
          'waiting_batches': snap.waitingBatches,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      for (final p in snap.points) {
        batch.insert(
          'prediction_points',
          {
            'session_id': snap.sessionId,
            'ts': p.ts,
            'lat': p.lat,
            'lng': p.lng,
            'predicted_label': p.label,
            'predicted_prob_bike': p.probBike,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// 캐시가 없으면 null.
  static Future<PredictionSnapshot?> loadPredictions(String sessionId) async {
    final db = await instance;
    final head = await db.query('prediction_fetch',
        where: 'session_id = ?', whereArgs: [sessionId], limit: 1);
    if (head.isEmpty) return null;
    final h = head.first;
    final rows = await db.query('prediction_points',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'ts ASC');
    return PredictionSnapshot(
      sessionId: sessionId,
      sessionState: h['session_state'] as String,
      totalPoints: h['total_points'] as int,
      predictedPoints: h['predicted_points'] as int,
      unpredictablePoints: h['unpredictable_points'] as int,
      waitingBatches: h['waiting_batches'] as int,
      fetchedAt: h['fetched_at'] as int,
      points: [
        for (final r in rows)
          PredictedPoint(
            ts: r['ts'] as int,
            lat: (r['lat'] as num).toDouble(),
            lng: (r['lng'] as num).toDouble(),
            label: r['predicted_label'] as String?,
            probBike: (r['predicted_prob_bike'] as num?)?.toDouble(),
          ),
      ],
    );
  }
}
