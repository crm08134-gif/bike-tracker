// 주행 기록 지도(TrackMapScreen)에 그릴 선을 만든다. 순수 Dart - 테스트에서 바로 부른다.
//
// ★ 여기서 만든 좌표는 **표시용**이다. 솎아낸 결과를 DB에 쓰지 않는다.
//   원본은 `points` 테이블 그대로 남고, 화면을 열 때마다 새로 만든다.

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// 폰 `points`의 한 행에서 지도에 필요한 것만.
class TrackPoint {
  final int ts;
  final double lat;
  final double lng;

  const TrackPoint({required this.ts, required this.lat, required this.lng});
}

/// 지도에서 색을 나누는 단위.
enum TrackKind {
  bike,
  walk,

  /// bike/walk가 아닌 모든 판정 (bus/car/subway ...).
  others,

  /// 판정이 없는 곳. 서버가 label=null로 준 좌표와, 판정 결과에 아예 없는 좌표 둘 다.
  unjudged,
}

TrackKind trackKindOf(String? label) => switch (label) {
      'bike' => TrackKind.bike,
      'walk' => TrackKind.walk,
      null => TrackKind.unjudged,
      _ => TrackKind.others,
    };

/// 같은 색으로 이어 그리는 한 덩어리.
class TrackRun {
  /// null이면 로컬에 판정 데이터가 없어 단색으로 그리는 선이다.
  final TrackKind? kind;
  final List<LatLng> points;

  const TrackRun(this.kind, this.points);
}

/// 폰 좌표 기준 판정 분포. 판정 데이터가 있을 때만 만든다.
class TrackLabelStats {
  int bike = 0;
  int walk = 0;
  int others = 0;

  /// 서버 판정 결과에 있지만 label이 null인 좌표 (200점 미만 구간·아직 판정 전).
  int nullLabel = 0;

  /// 서버 판정 결과에 ts가 없는 좌표 (정확도·ts 역행 필터, 미전송, 조회 이후 전송).
  int notInPredictions = 0;

  int get unjudged => nullLabel + notInPredictions;

  int count(TrackKind k) => switch (k) {
        TrackKind.bike => bike,
        TrackKind.walk => walk,
        TrackKind.others => others,
        TrackKind.unjudged => unjudged,
      };
}

class TrackView {
  final List<TrackRun> runs;

  /// null이면 판정 데이터가 없다.
  final TrackLabelStats? stats;
  final int rawCount;
  final int shownCount;

  /// 출발·도착 마커. 원본 첫/마지막 좌표다 (솎아내기와 무관).
  final LatLng? start;
  final LatLng? end;

  /// 카메라를 맞출 좌표. 솎아낸 좌표로도 범위는 같다 (각 덩어리 양 끝을 남기므로).
  final List<LatLng> bounds;

  const TrackView({
    required this.runs,
    required this.stats,
    required this.rawCount,
    required this.shownCount,
    required this.start,
    required this.end,
    required this.bounds,
  });
}

/// 표시용 솎아내기 허용 오차(m).
///
/// ★ 2 m인 근거
///   - 폰 GPS 수평 정확도가 보통 3~5 m다. 2 m 안쪽의 흔들림은 원래 믿을 수 없는 값이다.
///   - 도시 줌 18에서 1 논리 px ≈ 0.48 m라 2 m는 약 4 px - 확대해도 선 모양이 거의 같다.
///   - 직선 도로의 1 Hz 좌표는 대부분 이 안에 들어가 빠진다. 굽은 길·되돌아온 길은 남는다.
const double trackDisplayToleranceM = 2.0;

/// 폰 좌표를 색 덩어리로 나누고 덩어리마다 표시용으로 솎아낸다.
///
/// [labelsByTs]가 null이면 판정 데이터가 없는 것이다 → 한 덩어리(단색).
/// 있으면 ts로 잇는다. 서버 좌표는 폰 좌표의 부분집합이라 없는 ts가 생기는데,
/// 그 좌표는 **숨기지 않고** [TrackKind.unjudged]로 칠한다.
///
/// 좌표 사이 선분은 앞 좌표의 판정 색으로 칠한다 (summarizeRuns와 같은 규칙).
/// 그래서 덩어리 끝은 다음 덩어리 첫 좌표까지 이어 그려 색 사이가 뜨지 않는다.
TrackView buildTrackView(
  List<TrackPoint> points, {
  Map<int, String?>? labelsByTs,
  double toleranceM = trackDisplayToleranceM,
}) {
  final n = points.length;
  final stats = labelsByTs == null ? null : TrackLabelStats();
  final kinds = List<TrackKind?>.filled(n, null);

  if (labelsByTs != null) {
    for (var i = 0; i < n; i++) {
      final ts = points[i].ts;
      if (!labelsByTs.containsKey(ts)) {
        stats!.notInPredictions++;
        kinds[i] = TrackKind.unjudged;
        continue;
      }
      final k = trackKindOf(labelsByTs[ts]);
      kinds[i] = k;
      switch (k) {
        case TrackKind.bike:
          stats!.bike++;
        case TrackKind.walk:
          stats!.walk++;
        case TrackKind.others:
          stats!.others++;
        case TrackKind.unjudged:
          stats!.nullLabel++;
      }
    }
  }

  final runs = <TrackRun>[];
  final bounds = <LatLng>[];
  var shown = 0;
  var start = 0;
  for (var i = 1; i <= n; i++) {
    if (i < n && kinds[i] == kinds[start]) continue;
    // 다음 덩어리 첫 좌표까지 포함한다. 마지막 덩어리는 자기 끝까지.
    final last = i < n ? i : n - 1;
    final slice = points.sublist(start, last + 1);
    // 좌표 1개짜리(맨 끝 좌표 하나만 판정이 다른 경우)는 칠할 선분이 없다.
    // 그 좌표는 앞 덩어리 선의 끝점으로 이미 그려져 있다.
    if (slice.length >= 2) {
      final simplified = simplifyTrack(slice, toleranceM);
      runs.add(TrackRun(kinds[start], simplified));
      shown += simplified.length;
      bounds.addAll(simplified);
    }
    start = i;
  }
  // 덩어리 경계 좌표는 두 덩어리에 한 번씩 들어가므로 표시 좌표 수에서 한 번 뺀다.
  if (runs.length > 1) shown -= runs.length - 1;

  return TrackView(
    runs: runs,
    stats: stats,
    rawCount: n,
    shownCount: n == 1 ? 1 : shown,
    start: n == 0 ? null : LatLng(points.first.lat, points.first.lng),
    end: n == 0 ? null : LatLng(points.last.lat, points.last.lng),
    bounds: n == 1 ? [LatLng(points.first.lat, points.first.lng)] : bounds,
  );
}

/// Ramer-Douglas-Peucker. 양 끝은 항상 남긴다. 입력을 바꾸지 않는다.
///
/// ★ 거리는 무한 직선이 아니라 **선분**까지 잰다. 직선 거리로 재면 갔다가 같은 길로
///   돌아온 구간(막다른 길)이 통째로 지워진다.
/// ★ 재귀 대신 스택으로 돈다. 몇 시간짜리 세션에서도 스택 깊이 걱정이 없다.
List<LatLng> simplifyTrack(List<TrackPoint> pts, double toleranceM) {
  final n = pts.length;
  if (n <= 2 || toleranceM <= 0) {
    return [for (final p in pts) LatLng(p.lat, p.lng)];
  }

  // 세션 하나 범위(수십 km)에서는 등장방형 근사로 충분하다.
  const r = 6371008.8;
  final lat0 = pts.first.lat * math.pi / 180;
  final kx = r * math.cos(lat0) * math.pi / 180;
  const ky = r * math.pi / 180;
  final xs = [for (final p in pts) p.lng * kx];
  final ys = [for (final p in pts) p.lat * ky];

  final keep = List<bool>.filled(n, false);
  keep[0] = true;
  keep[n - 1] = true;
  final tol2 = toleranceM * toleranceM;
  final stack = <int>[0, n - 1];

  while (stack.isNotEmpty) {
    final b = stack.removeLast();
    final a = stack.removeLast();
    if (b - a < 2) continue;

    final ax = xs[a], ay = ys[a];
    final dx = xs[b] - ax, dy = ys[b] - ay;
    final len2 = dx * dx + dy * dy;
    var maxD2 = -1.0;
    var idx = -1;
    for (var i = a + 1; i < b; i++) {
      var px = xs[i] - ax, py = ys[i] - ay;
      if (len2 > 0) {
        final t = ((px * dx + py * dy) / len2).clamp(0.0, 1.0);
        px -= t * dx;
        py -= t * dy;
      }
      final d2 = px * px + py * py;
      if (d2 > maxD2) {
        maxD2 = d2;
        idx = i;
      }
    }
    if (maxD2 > tol2) {
      keep[idx] = true;
      stack
        ..add(a)
        ..add(idx)
        ..add(idx)
        ..add(b);
    }
  }

  return [
    for (var i = 0; i < n; i++)
      if (keep[i]) LatLng(pts[i].lat, pts[i].lng),
  ];
}
