-- ─────────────────────────────────────────────────────────────
-- E2. 정답 라벨과 모델 판정을 3그룹(bike / walk / others)으로 접어 비교하는 뷰.
-- 앱은 bike/walk/other/none, 모델은 bike/bus/car/subway/walk 를 써서 그대로는 비교가 안 됩니다.
-- gps_point 원본 컬럼은 건드리지 않습니다.
--
--   label (앱)       : bike -> bike, walk -> walk, other -> others, none -> 제외(정답 없음)
--   predicted (모델) : bike -> bike, walk -> walk, bus/car/subway -> others
--
-- 규칙:
-- - 정답 쪽도 bus/car/subway 를 others 로 접습니다. 앱은 보내지 않지만 골든셋 재생 데이터는 이 값을 씁니다.
-- - 매핑에 없는 값은 NULL 이 아니라 'unmapped' 로 드러냅니다. 조용히 빠지지 않게 하려는 것입니다.
-- - 판정이 없는 좌표(200점 미만이라 버린 구간)는 제외하지 않고 predicted_group = NULL 로 남깁니다.
--   M6 에서 그 빈도를 봐야 하기 때문입니다. 혼동행렬만 볼 때는 predicted_group IS NOT NULL 로 거르세요.
-- - label 이 NULL 인 좌표(라벨 컬럼 도입 전 데이터)는 제외합니다.
-- - prob_bike 는 접지 않고 그대로 노출합니다.
-- ─────────────────────────────────────────────────────────────
CREATE VIEW point_label_comparison AS
SELECT s.session_id,
       p.segment_id,
       p.idx,
       p.ts,
       p.label,
       p.predicted_label,
       CASE p.label
           WHEN 'bike'   THEN 'bike'
           WHEN 'walk'   THEN 'walk'
           WHEN 'other'  THEN 'others'
           WHEN 'bus'    THEN 'others'
           WHEN 'car'    THEN 'others'
           WHEN 'subway' THEN 'others'
           ELSE 'unmapped'
       END AS label_group,
       CASE
           WHEN p.predicted_label IS NULL THEN NULL
           WHEN p.predicted_label = 'bike' THEN 'bike'
           WHEN p.predicted_label = 'walk' THEN 'walk'
           WHEN p.predicted_label IN ('bus', 'car', 'subway') THEN 'others'
           ELSE 'unmapped'
       END AS predicted_group,
       p.predicted_prob_bike AS prob_bike,
       p.model_version
FROM gps_point p
JOIN segment s ON s.id = p.segment_id
WHERE p.label IS NOT NULL
  AND p.label <> 'none';
