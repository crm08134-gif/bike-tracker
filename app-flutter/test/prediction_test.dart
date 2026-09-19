import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_gps_tracker/core/constants.dart';
import 'package:my_gps_tracker/data/api_client.dart';
import 'package:my_gps_tracker/data/app_db.dart';
import 'package:my_gps_tracker/data/prediction.dart';

import 'support/db_harness.dart';

const _sid = '44444444-4444-4444-8444-444444444444';
const _t0 = 1789360450000;

/// GET /predictions 한 경로만 흉내 낸다. 받은 경로·메서드를 남긴다.
class _PredictionsGateway implements HttpClientAdapter {
  _PredictionsGateway(this.status, this.body);

  final int status;
  final Map<String, Object?> body;
  final List<String> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add('${options.method} ${options.uri.path}');
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 서버가 실제로 준 모양 (A1 curl 결과를 줄였다).
Map<String, Object?> _serverBody({required List<Map<String, Object?>> points}) => {
      'session_id': _sid,
      'session_state': 'CLOSED',
      'progress': {
        'total_points': points.length,
        'predicted_points': points.where((p) => p['predicted_label'] != null).length,
        'unpredictable_points': 0,
      },
      'waiting_batches': 0,
      'points': points,
    };

PredictedPoint _pt(int sec, String? label) =>
    PredictedPoint(ts: _t0 + sec * 1000, lat: 37.5, lng: 127.0, label: label);

void main() {
  group('summarizeRuns', () {
    test('판정이 바뀌는 곳에서 끊고, 경계 1초는 앞 덩어리 몫이다', () {
      final pts = [
        for (var i = 0; i < 100; i++) _pt(i, 'walk'),
        for (var i = 100; i < 300; i++) _pt(i, 'bike'),
      ];
      final runs = summarizeRuns(pts);

      expect(runs, hasLength(2));
      expect(runs[0].label, 'walk');
      expect(runs[0].pointCount, 100);
      expect(runs[0].durationMs, 100 * 1000); // 0 -> 100초 (다음 덩어리 시작까지)
      expect(runs[1].label, 'bike');
      expect(runs[1].durationMs, 199 * 1000); // 100 -> 299초 (마지막 좌표까지)

      // 합계 = 첫 좌표부터 마지막 좌표까지
      final totals = totalDurationByLabel(runs);
      expect(totals.values.reduce((a, b) => a + b), 299 * 1000);
    });

    test('300초 넘는 공백은 어느 덩어리 시간에도 넣지 않는다', () {
      final pts = [
        for (var i = 0; i < 10; i++) _pt(i, 'bike'),
        for (var i = 0; i < 10; i++) _pt(1000 + i, 'bike'),
      ];
      final runs = summarizeRuns(pts);

      expect(runs, hasLength(2));
      expect(runs[0].durationMs, 9 * 1000);
      expect(runs[1].durationMs, 9 * 1000);
      expect(totalDurationByLabel(runs), {'bike': 18 * 1000});
    });

    test('판정 없음(null)도 한 덩어리로 센다', () {
      final runs = summarizeRuns([_pt(0, 'bike'), _pt(1, null), _pt(2, null)]);
      expect(runs.map((r) => r.label), ['bike', null]);
      expect(predictionLabelKorean(null), '판정 없음');
    });

    test('빈 목록', () {
      expect(summarizeRuns(const []), isEmpty);
    });
  });

  group('캐시와 조회', () {
    setUpAll(() => initTestDb('prediction'));
    setUp(resetDb);
    tearDown(closeDb);

    test('fetchPredictions가 snake_case 응답을 읽는다 (null 판정 포함)', () async {
      final gw = _PredictionsGateway(200, _serverBody(points: [
        {'ts': _t0, 'lat': 37.5443329, 'lng': 126.9244001,
         'predicted_label': 'walk', 'predicted_prob_bike': 0.138},
        {'ts': _t0 + 1000, 'lat': 37.5, 'lng': 127, // 정수로 온 경도
         'predicted_label': null, 'predicted_prob_bike': null},
      ]));
      final api = ApiClient(baseUrl: 'http://fake', adapter: gw);

      final snap = await api.fetchPredictions(_sid);

      expect(gw.calls, ['GET /api/v1/sessions/$_sid/predictions']);
      expect(snap.sessionState, 'CLOSED');
      expect(snap.totalPoints, 2);
      expect(snap.predictedPoints, 1);
      expect(snap.points[0].label, 'walk');
      expect(snap.points[0].probBike, 0.138);
      expect(snap.points[1].label, isNull);
      expect(snap.points[1].lng, 127.0);
    });

    test('404는 SESSION_NOT_FOUND 코드로 던진다', () async {
      final gw = _PredictionsGateway(404, {
        'error': 'SESSION_NOT_FOUND',
        'detail': '없는 세션입니다',
        'retryable': false,
      });
      final api = ApiClient(baseUrl: 'http://fake', adapter: gw);

      await expectLater(
        api.fetchPredictions(_sid),
        throwsA(isA<UploadFailure>()
            .having((e) => e.code, 'code', 'SESSION_NOT_FOUND')
            .having((e) => e.status, 'status', 404)),
      );
    });

    test('필드가 빠진 응답은 BAD_BODY로 끊는다 (캐시를 덮지 않게)', () async {
      final gw = _PredictionsGateway(200, {'session_id': _sid});
      final api = ApiClient(baseUrl: 'http://fake', adapter: gw);

      await expectLater(api.fetchPredictions(_sid),
          throwsA(isA<UploadFailure>().having((e) => e.code, 'code', 'BAD_BODY')));
    });

    test('캐시가 없으면 null, 저장 후에는 그대로 읽힌다', () async {
      expect(await AppDb.loadPredictions(_sid), isNull);

      await AppDb.replacePredictions(PredictionSnapshot(
        sessionId: _sid,
        sessionState: 'ACTIVE',
        totalPoints: 300,
        predictedPoints: 200,
        unpredictablePoints: 0,
        waitingBatches: 1,
        fetchedAt: 111,
        points: [_pt(0, 'bike'), _pt(1, null)],
      ));

      final snap = (await AppDb.loadPredictions(_sid))!;
      expect(snap.sessionState, 'ACTIVE');
      expect(snap.totalPoints, 300);
      expect(snap.predictedPoints, 200);
      expect(snap.waitingBatches, 1);
      expect(snap.fetchedAt, 111);
      expect(snap.points.map((p) => p.label), ['bike', null]);
    });

    test('새로고침은 캐시를 통째로 바꾼다 (이전 좌표가 남지 않는다)', () async {
      PredictionSnapshot snap(int fetchedAt, List<PredictedPoint> pts) =>
          PredictionSnapshot(
            sessionId: _sid,
            sessionState: 'CLOSED',
            totalPoints: pts.length,
            predictedPoints: pts.length,
            unpredictablePoints: 0,
            waitingBatches: 0,
            fetchedAt: fetchedAt,
            points: pts,
          );

      await AppDb.replacePredictions(snap(1, [_pt(0, null), _pt(1, null), _pt(2, null)]));
      await AppDb.replacePredictions(snap(2, [_pt(0, 'bike'), _pt(1, 'bike')]));

      final got = (await AppDb.loadPredictions(_sid))!;
      expect(got.fetchedAt, 2);
      expect(got.points.map((p) => p.label), ['bike', 'bike']);

      // 다른 세션 캐시는 건드리지 않는다
      await AppDb.replacePredictions(const PredictionSnapshot(
        sessionId: 'other',
        sessionState: 'CLOSED',
        totalPoints: 0,
        predictedPoints: 0,
        unpredictablePoints: 0,
        waitingBatches: 0,
        fetchedAt: 3,
        points: [],
      ));
      expect((await AppDb.loadPredictions(_sid))!.points, hasLength(2));
    });

    test('countBatchesByState는 이 세션 배치만 상태별로 센다', () async {
      Future<int> batch(String sid, int from) => AppDb.insertBatch(
          sessionId: sid,
          fromTs: from,
          toTs: from + 30000,
          pointCount: 30,
          isLast: false,
          createdAt: from);
      await batch(_sid, 0);
      final s1 = await batch(_sid, 30000);
      final s2 = await batch(_sid, 60000);
      await batch('other', 0);
      await AppDb.markBatchSent(_sid, s1, 1);
      await AppDb.markBatchDead(_sid, s2);

      expect(await AppDb.countBatchesByState(_sid), {
        BatchState.pending: 1,
        BatchState.sent: 1,
        BatchState.dead: 1,
      });
    });
  });
}
