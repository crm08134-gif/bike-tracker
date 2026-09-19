import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_gps_tracker/core/constants.dart';
import 'package:my_gps_tracker/data/app_db.dart';
import 'package:my_gps_tracker/data/prediction.dart';
import 'package:my_gps_tracker/ui/sessions_screen.dart';
import 'package:my_gps_tracker/ui/track_map_screen.dart';

import 'support/db_harness.dart';

const _sid = '66666666-6666-4666-8666-666666666666';
const _t0 = 1789360450000;

const _session = SessionSummary(
  sessionId: _sid,
  userId: 'u',
  startedAt: _t0,
  endedAt: null, // 비정상 종료 세션
  pointCount: 1800,
);

Future<void> _seedPoints() async {
  await AppDb.createSession(sessionId: _sid, userId: 'u', startedAt: _t0);
  await AppDb.insertPoints([
    for (var i = 0; i < 1800; i++)
      GpsPoint(
        sessionId: _sid,
        ts: _t0 + i * 1000,
        lat: 37.5 + (i % 600) * 0.00003,
        lng: 127.0 + i * 0.00003,
        acc: 4,
        label: TripLabel.none,
      ),
  ]);
}

/// 투명 1x1 PNG. 테스트 환경의 HTTP는 전부 400이라 실제 타일을 받지 않는다.
final _blankPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0x60,
  0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0xA5, 0xF6, 0x45, 0x40, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _BlankTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_blankPng);
}

/// 지도 화면을 폰 너비(360)로 띄운다. 레이아웃 오류(overflow 등)는 그대로 실패한다.
Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: TrackMapScreen(session: _session, tileProvider: _BlankTiles()),
  ));
  // sqflite ffi는 실제 I/O라 가짜 시계 밖에서 기다리고, 이어지는 코드는 pump로 돌린다.
  for (var i = 0;
      i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  expect(find.byType(CircularProgressIndicator), findsNothing);
  await tester.pump(const Duration(milliseconds: 100));
}

/// 지도를 내려 타이머·타일 요청을 정리한다.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() => initTestDb('track_map'));
  setUp(() async {
    await resetDb();
  });
  tearDown(closeDb);

  testWidgets('판정 캐시가 없으면 단색 + 안내 문구, 서버를 부르지 않는다', (tester) async {
    await tester.runAsync(_seedPoints);
    await _pump(tester);

    expect(find.text('색 구분을 보려면 주행 판정 조회를 먼저 하세요'), findsOneWidget);
    expect(find.textContaining('원본 1800점'), findsOneWidget);
    expect(find.textContaining('종료 기록 없음'), findsOneWidget);

    // 자동으로 받아오지 않았다 = 캐시가 여전히 없다.
    expect(await tester.runAsync(() => AppDb.loadPredictions(_sid)), isNull);
    await _unmount(tester);
  });

  testWidgets('판정 캐시가 있으면 판정별 범례(기타 포함)와 판정 없음이 보인다', (tester) async {
    await tester.runAsync(() async {
      await _seedPoints();
      await AppDb.replacePredictions(PredictionSnapshot(
        sessionId: _sid,
        sessionState: 'CLOSED',
        totalPoints: 1700,
        predictedPoints: 1500,
        unpredictablePoints: 200,
        waitingBatches: 0,
        fetchedAt: _t0 + 3600000,
        points: [
          // 뒤 100점은 서버 결과에 없다.
          for (var i = 0; i < 1700; i++)
            PredictedPoint(
              ts: _t0 + i * 1000,
              lat: 0,
              lng: 0,
              // 모델 라벨 그대로: bus/car/subway는 지도에서 '기타'로 묶인다.
              label: i < 900
                  ? 'bike'
                  : i < 1000
                      ? const ['bus', 'car', 'subway'][i % 3]
                      : (i < 1500 ? 'walk' : null),
            ),
        ],
      ));
    });
    await _pump(tester);

    expect(find.text('자전거 900점'), findsOneWidget);
    expect(find.text('기타 100점'), findsOneWidget);
    expect(find.text('도보 500점'), findsOneWidget);
    expect(find.text('판정 없음 300점'), findsOneWidget);
    expect(find.textContaining('판정 없음 중 100점'), findsOneWidget);
    expect(find.text('색 구분을 보려면 주행 판정 조회를 먼저 하세요'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('세션 목록에 주행 기록 조회가 있고, 좁은 폰에서 목록이 넘치지 않는다',
      (tester) async {
    await tester.runAsync(_seedPoints);
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SessionsScreen()));
    for (var i = 0; i < 100 && find.byTooltip('주행 기록 조회').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    // GPX 내보내기는 그대로 남아 있다.
    expect(find.byTooltip('내보내기'), findsOneWidget);
    expect(find.byTooltip('주행 판정 조회'), findsOneWidget);

    // 좌표가 있는 세션이라 눌린다. 누르지는 않는다 - 앱 화면은 실제 OSM 타일을 요청한다.
    final btn = tester.widget<IconButton>(find.ancestor(
        of: find.byIcon(Icons.map_outlined), matching: find.byType(IconButton)));
    expect(btn.onPressed, isNotNull);
    await _unmount(tester);
  });
}
