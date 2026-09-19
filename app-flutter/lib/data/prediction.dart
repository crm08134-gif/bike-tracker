// 서버 판정 조회(`GET /api/v1/sessions/{id}/predictions`) 결과와 그 요약.
//
// ★ 앱은 "판정이 끝났는지"를 판별하지 않는다. 서버가 준 숫자를 그대로 보여줄 뿐이다.

/// 좌표 하나의 판정. 판정 전이거나 판정 불가면 [label]이 null이다.
///
/// ★ `predicted_prob_bike`는 저장만 하고 화면에는 쓰지 않는다 (보류 지시).
class PredictedPoint {
  final int ts;
  final double lat;
  final double lng;
  final String? label;
  final double? probBike;

  const PredictedPoint({
    required this.ts,
    required this.lat,
    required this.lng,
    this.label,
    this.probBike,
  });
}

/// 한 번 조회한 결과 전체. 로컬 캐시의 단위이기도 하다 - 새로고침마다 통째로 바뀐다.
class PredictionSnapshot {
  final String sessionId;

  /// 서버 세션 상태. ACTIVE / CLOSED / ABANDONED.
  final String sessionState;

  /// 서버가 필터(정확도 20m, ts 역행)를 통과시켜 저장한 좌표 수. 폰 좌표 수보다 적을 수 있다.
  final int totalPoints;
  final int predictedPoints;

  /// 200점 묶음이 안 만들어져 서버가 버린 구간의 좌표 수. 영영 판정되지 않는다.
  final int unpredictablePoints;

  /// 서버가 받았지만 앞 번호 배치를 기다리느라 아직 반영하지 못한 배치 수.
  final int waitingBatches;

  /// 이 기기 시계로 잰 조회 시각 (epoch ms).
  final int fetchedAt;

  final List<PredictedPoint> points;

  const PredictionSnapshot({
    required this.sessionId,
    required this.sessionState,
    required this.totalPoints,
    required this.predictedPoints,
    required this.unpredictablePoints,
    required this.waitingBatches,
    required this.fetchedAt,
    required this.points,
  });

  factory PredictionSnapshot.fromJson(Map<String, dynamic> j,
      {required int fetchedAt}) {
    final progress = j['progress'] as Map<String, dynamic>;
    final pts = (j['points'] as List)
        .cast<Map<String, dynamic>>()
        .map((p) => PredictedPoint(
              ts: (p['ts'] as num).toInt(),
              lat: (p['lat'] as num).toDouble(),
              lng: (p['lng'] as num).toDouble(),
              label: p['predicted_label'] as String?,
              probBike: (p['predicted_prob_bike'] as num?)?.toDouble(),
            ))
        .toList();
    return PredictionSnapshot(
      sessionId: j['session_id'] as String,
      sessionState: j['session_state'] as String,
      totalPoints: (progress['total_points'] as num).toInt(),
      predictedPoints: (progress['predicted_points'] as num).toInt(),
      unpredictablePoints: (progress['unpredictable_points'] as num).toInt(),
      waitingBatches: (j['waiting_batches'] as num?)?.toInt() ?? 0,
      fetchedAt: fetchedAt,
      points: pts,
    );
  }
}

/// 같은 판정이 이어진 한 덩어리.
class PredictionRun {
  final String? label;
  final int startTs;

  /// 다음 덩어리가 곧바로 이어지면 그 시작 ts, 공백으로 끊겼으면 자기 마지막 좌표의 ts.
  final int endTs;
  final int pointCount;

  const PredictionRun({
    required this.label,
    required this.startTs,
    required this.endTs,
    required this.pointCount,
  });

  int get durationMs => endTs - startTs;
}

/// 서버가 구간을 끊는 공백과 같은 값. 이보다 긴 공백은 어느 덩어리의 시간에도 넣지 않는다.
const _segmentGapMs = 300000;

/// ts 순 좌표를 같은 판정끼리 묶는다.
///
/// 좌표 사이 시간은 앞 좌표의 판정 몫으로 센다. 그래서 판정이 바뀌는 경계의 1초는
/// 앞 덩어리에 들어가고, 덩어리 시간의 합이 주행 시간(공백 제외)과 같아진다.
List<PredictionRun> summarizeRuns(List<PredictedPoint> points) {
  final runs = <PredictionRun>[];
  if (points.isEmpty) return runs;

  var start = 0;
  for (var i = 1; i <= points.length; i++) {
    final atEnd = i == points.length;
    final gap = !atEnd && points[i].ts - points[i - 1].ts > _segmentGapMs;
    if (atEnd || gap || points[i].label != points[start].label) {
      final contiguous = !atEnd && !gap;
      runs.add(PredictionRun(
        label: points[start].label,
        startTs: points[start].ts,
        endTs: contiguous ? points[i].ts : points[i - 1].ts,
        pointCount: i - start,
      ));
      start = i;
    }
  }
  return runs;
}

/// 판정별 합계 시간(ms). 등장 순서를 유지한다.
Map<String?, int> totalDurationByLabel(List<PredictionRun> runs) {
  final out = <String?, int>{};
  for (final r in runs) {
    out[r.label] = (out[r.label] ?? 0) + r.durationMs;
  }
  return out;
}

/// 모델 라벨(소문자) -> 화면 이름.
String predictionLabelKorean(String? label) {
  switch (label) {
    case 'bike':
      return '자전거';
    case 'walk':
      return '도보';
    case 'bus':
      return '버스';
    case 'car':
      return '자동차';
    case 'subway':
      return '지하철';
    case null:
      return '판정 없음';
    default:
      return label;
  }
}
