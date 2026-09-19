import 'package:flutter_test/flutter_test.dart';

import 'package:my_gps_tracker/core/constants.dart';
import 'package:my_gps_tracker/data/app_db.dart';

import 'support/db_harness.dart';

/// 수동 동기화(전송 전용 모드)가 쓰는 큐 조회·갱신.
///
/// ★ 전송 루프 자체는 uploader_test가 덮는다. 여기서는 "무엇을 보낼지"와
///   "재시도 대기를 어떻게 푸는지"만 본다.
void main() {
  setUpAll(() => initTestDb('sync_queue'));

  setUp(resetDb);
  tearDown(closeDb);

  Future<int> addBatch(String sessionId,
      {required String state, int? nextTryAt, int createdAt = 0}) async {
    final seq = await AppDb.insertBatch(
      sessionId: sessionId,
      fromTs: createdAt,
      toTs: createdAt + 30000,
      pointCount: 30,
      isLast: false,
      createdAt: createdAt,
    );
    if (state != BatchState.pending) {
      final db = await AppDb.instance;
      await db.update('batches', {'state': state, 'next_try_at': nextTryAt},
          where: 'session_id = ? AND seq = ?', whereArgs: [sessionId, seq]);
    }
    return seq;
  }

  test('countBatchesByStateAll은 세션을 가리지 않고 센다', () async {
    await addBatch('s1', state: BatchState.pending);
    await addBatch('s1', state: BatchState.failed);
    await addBatch('s2', state: BatchState.sent);
    await addBatch('s2', state: BatchState.dead);
    await addBatch('s2', state: BatchState.dead);

    final counts = await AppDb.countBatchesByStateAll();

    expect(counts[BatchState.pending], 1);
    expect(counts[BatchState.failed], 1);
    expect(counts[BatchState.sent], 1);
    expect(counts[BatchState.dead], 2);
    // 홈 화면의 "미전송"은 PENDING + FAILED다. DEAD는 빠진다.
    expect(await AppDb.countUnsentBatches(), 2);
  });

  test('clearRetryBackoff는 FAILED의 대기만 풀고 DEAD는 두지 않는다', () async {
    final future = DateTime.now().millisecondsSinceEpoch + 300000;
    await addBatch('s1', state: BatchState.failed, nextTryAt: future);
    await addBatch('s1', state: BatchState.failed, nextTryAt: future);
    await addBatch('s1', state: BatchState.dead, nextTryAt: future);
    await addBatch('s1', state: BatchState.pending);

    final revived = await AppDb.clearRetryBackoff();

    // PENDING은 원래 대기가 없고, DEAD는 큐에서 제외라 건드리지 않는다.
    expect(revived, 2);

    final due = await AppDb.dueBatches(
        now: DateTime.now().millisecondsSinceEpoch, limit: 10);
    // 백오프가 풀려 FAILED 2건 + PENDING 1건이 지금 바로 보낼 수 있다.
    expect(due, hasLength(3));
    expect(due.every((r) => r['state'] != BatchState.dead), isTrue);

    final db = await AppDb.instance;
    final dead = await db.query('batches',
        where: 'state = ?', whereArgs: [BatchState.dead]);
    expect(dead.single['next_try_at'], future);
  });

  test('clearRetryBackoff는 retry_count를 되돌리지 않는다', () async {
    await addBatch('s1', state: BatchState.failed, nextTryAt: 1);
    await AppDb.markBatchRetry('s1', 0, retryCount: 4, nextTryAt: 9999999999999);

    await AppDb.clearRetryBackoff();

    final db = await AppDb.instance;
    final row = (await db.query('batches')).single;
    expect(row['retry_count'], 4); // 다시 실패하면 원래 간격으로 이어진다
    expect(row['next_try_at'], isNull);
  });

  test('sessionIdsWithUnsentBatches는 미전송이 있는 세션만 오래된 순으로 준다', () async {
    await addBatch('newer', state: BatchState.failed, createdAt: 200);
    await addBatch('older', state: BatchState.pending, createdAt: 100);
    await addBatch('done', state: BatchState.sent, createdAt: 50);
    await addBatch('rejected', state: BatchState.dead, createdAt: 10);

    expect(await AppDb.sessionIdsWithUnsentBatches(), ['older', 'newer']);
  });
}
