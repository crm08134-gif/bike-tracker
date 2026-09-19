import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:my_gps_tracker/core/constants.dart';
import 'package:my_gps_tracker/data/app_db.dart';
import 'package:my_gps_tracker/data/track.dart';

import 'support/db_harness.dart';

const _sid = '55555555-5555-4555-8555-555555555555';
const _t0 = 1789360450000;

/// 위도 37.5에서 동쪽으로 [eastM] m, 북쪽으로 [northM] m 떨어진 좌표.
TrackPoint _p(int sec, {double eastM = 0, double northM = 0}) => TrackPoint(
      ts: _t0 + sec * 1000,
      lat: 37.5 + northM / 111195.0,
      lng: 127.0 + eastM / (111195.0 * 0.7933533),
    );

void main() {
  group('simplifyTrack', () {
    test('허용 오차 안의 흔들림은 빠지고 양 끝은 남는다', () {
      final pts = [
        for (var i = 0; i <= 100; i++)
          _p(i, eastM: i * 5.0, northM: i.isEven ? 0.8 : -0.8),
      ];
      final out = simplifyTrack(pts, 2.0);
      expect(out.length, lessThan(10));
      expect(out.first, LatLng(pts.first.lat, pts.first.lng));
      expect(out.last, LatLng(pts.last.lat, pts.last.lng));
    });

    test('오차보다 크게 꺾인 곳은 남는다', () {
      final pts = [
        for (var i = 0; i <= 10; i++) _p(i, eastM: i * 5.0),
        for (var i = 1; i <= 10; i++) _p(10 + i, eastM: 50, northM: i * 5.0),
      ];
      final out = simplifyTrack(pts, 2.0);
      expect(out, [
        LatLng(pts[0].lat, pts[0].lng),
        LatLng(pts[10].lat, pts[10].lng),
        LatLng(pts[20].lat, pts[20].lng),
      ]);
    });

    test('같은 길로 되돌아온 막다른 길을 지우지 않는다', () {
      // 0 -> 동쪽 100 m -> 되돌아와 0 -> 서쪽 10 m. 직선 거리로 재면 전부 0에 가깝다.
      final pts = [
        for (var i = 0; i <= 10; i++) _p(i, eastM: i * 10.0),
        for (var i = 1; i <= 10; i++) _p(10 + i, eastM: 100 - i * 10.0),
        _p(21, eastM: -10),
      ];
      final out = simplifyTrack(pts, 2.0);
      expect(out, contains(LatLng(pts[10].lat, pts[10].lng)));
    });

    test('입력 목록을 바꾸지 않는다', () {
      final pts = [for (var i = 0; i < 50; i++) _p(i, eastM: i.toDouble())];
      final copy = List.of(pts);
      simplifyTrack(pts, 5.0);
      expect(pts, copy);
    });
  });

  group('buildTrackView', () {
    test('판정 데이터가 없으면 한 덩어리 단색이고 분포를 만들지 않는다', () {
      final pts = [for (var i = 0; i < 30; i++) _p(i, eastM: i * 5.0)];
      final v = buildTrackView(pts);
      expect(v.runs, hasLength(1));
      expect(v.runs.single.kind, isNull);
      expect(v.stats, isNull);
      expect(v.rawCount, 30);
    });

    test('판정 null과 판정 결과에 없는 좌표는 숨기지 않고 판정 없음으로 칠한다', () {
      // 직선 위라 솎아내기가 있어도 덩어리 양 끝은 남는다.
      final pts = [for (var i = 0; i < 10; i++) _p(i, eastM: i * 5.0)];
      final labels = <int, String?>{
        pts[0].ts: 'bike',
        pts[1].ts: 'bike',
        pts[2].ts: 'bike',
        pts[3].ts: null, // 서버에 있지만 판정 불가
        // pts[4]: 서버 판정 결과에 없음 (정확도 필터 등)
        pts[5].ts: 'walk',
        pts[6].ts: 'walk',
        pts[7].ts: 'bus',
        pts[8].ts: 'car',
        pts[9].ts: 'bike',
      };
      final v = buildTrackView(pts, labelsByTs: labels);

      expect(v.runs.map((r) => r.kind), [
        TrackKind.bike,
        TrackKind.unjudged,
        TrackKind.walk,
        TrackKind.others,
        // 맨 끝 bike 좌표 하나는 선분이 없어 덩어리가 없다. 앞 선의 끝점으로 그려진다.
      ]);
      final s = v.stats!;
      expect(s.bike, 4);
      expect(s.walk, 2);
      expect(s.others, 2);
      expect(s.nullLabel, 1);
      expect(s.notInPredictions, 1);
      expect(s.unjudged, 2);
    });

    test('덩어리 사이가 뜨지 않는다 - 끝점이 다음 덩어리 첫 점이다', () {
      final pts = [for (var i = 0; i < 60; i++) _p(i, eastM: i * 5.0)];
      final labels = <int, String?>{
        for (var i = 0; i < 60; i++)
          pts[i].ts: i < 20 ? 'bike' : (i < 40 ? null : 'walk'),
      };
      final v = buildTrackView(pts, labelsByTs: labels);
      expect(v.runs, hasLength(3));
      for (var i = 0; i + 1 < v.runs.length; i++) {
        expect(v.runs[i].points.last, v.runs[i + 1].points.first);
      }
      expect(v.runs[0].points.last, LatLng(pts[20].lat, pts[20].lng));
      expect(v.runs[1].points.last, LatLng(pts[40].lat, pts[40].lng));
      // 직선이라 덩어리마다 양 끝만 남는다: 2+2+2 에서 경계 2개 중복 제외.
      expect(v.shownCount, 4);
    });

    test('출발·도착은 솎아내기와 무관하게 원본 첫/마지막 좌표다', () {
      final pts = [
        for (var i = 0; i < 20; i++) _p(i, eastM: i * 5.0, northM: 0.3 * (i % 3)),
      ];
      final v = buildTrackView(pts);
      expect(v.start, LatLng(pts.first.lat, pts.first.lng));
      expect(v.end, LatLng(pts.last.lat, pts.last.lng));
    });

    test('좌표가 없거나 하나여도 터지지 않는다', () {
      final empty = buildTrackView(const []);
      expect(empty.runs, isEmpty);
      expect(empty.start, isNull);

      final one = buildTrackView([_p(0)], labelsByTs: const {});
      expect(one.runs, isEmpty);
      expect(one.start, one.end);
      expect(one.bounds, hasLength(1));
      expect(one.stats!.notInPredictions, 1);
    });
  });

  group('AppDb.readTrackPoints', () {
    setUpAll(() => initTestDb('track'));
    setUp(resetDb);
    tearDown(closeDb);

    test('ts 순으로 읽고 원본 행을 바꾸지 않는다', () async {
      await AppDb.createSession(sessionId: _sid, userId: 'u', startedAt: _t0);
      // 일부러 ts 역순으로 넣는다.
      await AppDb.insertPoints([
        for (var i = 99; i >= 0; i--)
          GpsPoint(
            sessionId: _sid,
            ts: _t0 + i * 1000,
            lat: 37.5,
            lng: 127.0 + i * 0.00005,
            acc: 4,
            label: TripLabel.none,
          ),
      ]);
      final db = await AppDb.instance;
      final before = await db.query('points', orderBy: 'id');

      final pts = await AppDb.readTrackPoints(_sid);
      buildTrackView(pts);

      expect(pts, hasLength(100));
      expect(pts.first.ts, _t0);
      expect(pts.last.ts, _t0 + 99000);
      expect(await db.query('points', orderBy: 'id'), before);
    });
  });
}
