-- ═══════════════════════════════════════════════════════════════════════════
-- M6 실주행 분석 쿼리 (PostgreSQL / PostGIS, DB: biketracker)
--
--   docker exec -i server-spring-postgis-1 psql -U biketracker -d biketracker < docs/m6_analysis.sql
--   또는 IntelliJ / DBeaver 에서 쿼리 하나씩 실행
--
-- 전제
-- - gps_point.ts 는 GNSS epoch millis (UTC). 사람이 보는 시각은 Asia/Seoul 로 바꿔 표시한다.
-- - 앱은 사람이 라벨을 달지 않으므로 label 이 거의 전부 'none' 이다. 그래서 정답은 주행 중 메모한
--   전환 시각으로 넣는다 (아래 truth CTE). point_label_comparison 뷰는 none 을 빼므로 비어 있을 수 있다.
-- - 판정(predicted_*)은 구간이 확정된 좌표에만 있다. 200점 미만이라 버린 구간과 아직 처리 중인 구간은 NULL.
-- - truth CTE 는 3번, 5번 쿼리에 각각 들어 있다. 두 곳의 VALUES 를 같은 값으로 채운다.
--
-- truth 시각 넣는 법 (KST 로 메모한 시각 -> epoch ms)
--   (extract(epoch FROM timestamptz '2026-09-20 14:05:00+09') * 1000)::bigint
-- ═══════════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────────
-- 0. 세션 목록: 분석할 session_id 와 주행 시간대를 찾는다
-- ───────────────────────────────────────────────────────────────────────────
SELECT s.session_id,
       s.state,
       to_timestamp(min(p.ts) / 1000.0) AT TIME ZONE 'Asia/Seoul' AS first_fix_kst,
       to_timestamp(max(p.ts) / 1000.0) AT TIME ZONE 'Asia/Seoul' AS last_fix_kst,
       round((max(p.ts) - min(p.ts)) / 60000.0, 1)               AS minutes,
       count(DISTINCT g.id)                                        AS segments,
       count(p.*)                                                  AS stored_points
FROM session s
JOIN segment g   ON g.session_id = s.session_id
JOIN gps_point p ON p.segment_id = g.id
GROUP BY s.session_id, s.state
ORDER BY first_fix_kst DESC;


-- ───────────────────────────────────────────────────────────────────────────
-- 1a. 판정 NULL 좌표 개수와 전체 대비 비율: 200점 미만이라 판정을 못 받은 좌표가 얼마나 되나
--     (세션별 + 맨 아래 전체 합계. 처리 중인 구간은 따로 센다)
-- ───────────────────────────────────────────────────────────────────────────
SELECT coalesce(g.session_id::text, '== 전체 ==')                                       AS session_id,
       count(*)                                                                        AS points,
       count(*) FILTER (WHERE p.predicted_label IS NULL)                              AS null_points,
       round(100.0 * count(*) FILTER (WHERE p.predicted_label IS NULL) / count(*), 1) AS null_pct,
       count(*) FILTER (WHERE p.predicted_label IS NULL AND g.discarded)              AS null_discarded_under_200,
       count(*) FILTER (WHERE p.predicted_label IS NULL AND NOT g.finalized)          AS null_still_processing,
       count(DISTINCT g.id) FILTER (WHERE g.discarded)                                AS discarded_segments,
       count(DISTINCT g.id)                                                            AS segments
FROM gps_point p
JOIN segment g ON g.id = p.segment_id
GROUP BY ROLLUP (g.session_id)
ORDER BY (g.session_id IS NULL), g.session_id;


-- ───────────────────────────────────────────────────────────────────────────
-- 1b. 받은 점 vs 저장된 점: 정확도 필터·ts 역행으로 gps_point 에 들어가기도 전에 버려진 점이 얼마나 되나
--     (NULL 판정과 별개로 사라지는 몫. 사유별 개수는 Spring 로그 "배치 반영 ... dropped:" 참고)
-- ───────────────────────────────────────────────────────────────────────────
WITH received AS (
    SELECT session_id,
           sum(jsonb_array_length(payload -> 'points'))                                          AS received_points,
           sum((SELECT count(*) FROM jsonb_array_elements(payload -> 'points') e
                WHERE e ->> 'acc' IS NULL OR (e ->> 'acc')::real > 20))                           AS acc_filtered_points
    FROM raw_batch
    GROUP BY session_id
), stored AS (
    SELECT g.session_id, count(*) AS stored_points
    FROM gps_point p JOIN segment g ON g.id = p.segment_id
    GROUP BY g.session_id
)
SELECT r.session_id,
       r.received_points,
       coalesce(s.stored_points, 0)                                                     AS stored_points,
       r.received_points - coalesce(s.stored_points, 0)                                 AS dropped_points,
       round(100.0 * (r.received_points - coalesce(s.stored_points, 0)) / nullif(r.received_points, 0), 1) AS dropped_pct,
       r.acc_filtered_points                                                            AS of_which_acc_null_or_over_20m
FROM received r
LEFT JOIN stored s ON s.session_id = r.session_id
ORDER BY r.session_id;


-- ───────────────────────────────────────────────────────────────────────────
-- 2. 3그룹 혼동행렬: 정답 라벨 그룹별로 모델이 어느 그룹으로 판정했나 (판정 NULL 제외, 행 기준 비율)
--    앱 라벨이 전부 none 이면 0행이다. 그때는 5번(수동 정답 구간)을 쓴다.
-- ───────────────────────────────────────────────────────────────────────────
SELECT label_group,
       predicted_group,
       count(*)                                                                         AS points,
       round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY label_group), 1)       AS pct_of_label_group,
       round(avg(prob_bike)::numeric, 4)                                                AS avg_prob_bike
FROM point_label_comparison
WHERE predicted_group IS NOT NULL
GROUP BY label_group, predicted_group
ORDER BY label_group, predicted_group;


-- ───────────────────────────────────────────────────────────────────────────
-- 3a. [M6 핵심] bike 구간 vs walk 구간의 predicted_prob_bike 분포: 정답 구간마다 5수치 요약
--     구간별 행 + 그룹 전체 행(range_no = NULL). 두 그룹의 p25~p75 가 겹치는 정도를 본다.
--     truth VALUES 에 메모한 구간을 채운다. session_id 를 NULL 로 두면 모든 세션에서 ts 로만 찾는다.
-- ───────────────────────────────────────────────────────────────────────────
WITH truth (range_no, session_id, from_ts, to_ts, truth_group) AS (
    VALUES
        -- (구간번호, 'session_id'::uuid 또는 NULL::uuid, 시작 epoch ms, 끝 epoch ms(미포함), 'bike' | 'walk' | 'others')
        (1, NULL::uuid, (extract(epoch FROM timestamptz '2026-09-20 14:00:00+09') * 1000)::bigint,
                        (extract(epoch FROM timestamptz '2026-09-20 14:10:00+09') * 1000)::bigint, 'walk'),
        (2, NULL::uuid, (extract(epoch FROM timestamptz '2026-09-20 14:10:00+09') * 1000)::bigint,
                        (extract(epoch FROM timestamptz '2026-09-20 14:40:00+09') * 1000)::bigint, 'bike')
), pts AS (
    SELECT t.range_no, t.truth_group, p.predicted_prob_bike AS prob_bike
    FROM truth t
    JOIN segment g   ON (t.session_id IS NULL OR g.session_id = t.session_id)
    JOIN gps_point p ON p.segment_id = g.id AND p.ts >= t.from_ts AND p.ts < t.to_ts
    WHERE p.predicted_prob_bike IS NOT NULL
)
SELECT truth_group,
       range_no,
       count(*)                                                                         AS points,
       round(min(prob_bike)::numeric, 4)                                                AS min,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY prob_bike)::numeric, 4)       AS p25,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY prob_bike)::numeric, 4)       AS median,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY prob_bike)::numeric, 4)       AS p75,
       round(max(prob_bike)::numeric, 4)                                                AS max,
       round(avg(prob_bike)::numeric, 4)                                                AS mean
FROM pts
GROUP BY GROUPING SETS ((truth_group, range_no), (truth_group))
ORDER BY truth_group, range_no NULLS LAST;


-- ───────────────────────────────────────────────────────────────────────────
-- 3b. 같은 분포를 0.1 단위 히스토그램으로 나란히: 두 그룹이 어느 확률대에서 겹치는지 눈으로 본다
--     (bar 는 그룹 안에서의 비율, # 하나 = 2%). truth VALUES 는 3a 와 같게 채운다.
-- ───────────────────────────────────────────────────────────────────────────
WITH truth (range_no, session_id, from_ts, to_ts, truth_group) AS (
    VALUES
        (1, NULL::uuid, (extract(epoch FROM timestamptz '2026-09-20 14:00:00+09') * 1000)::bigint,
                        (extract(epoch FROM timestamptz '2026-09-20 14:10:00+09') * 1000)::bigint, 'walk'),
        (2, NULL::uuid, (extract(epoch FROM timestamptz '2026-09-20 14:10:00+09') * 1000)::bigint,
                        (extract(epoch FROM timestamptz '2026-09-20 14:40:00+09') * 1000)::bigint, 'bike')
), pts AS (
    SELECT t.truth_group, p.predicted_prob_bike AS prob_bike
    FROM truth t
    JOIN segment g   ON (t.session_id IS NULL OR g.session_id = t.session_id)
    JOIN gps_point p ON p.segment_id = g.id AND p.ts >= t.from_ts AND p.ts < t.to_ts
    WHERE p.predicted_prob_bike IS NOT NULL
), bucketed AS (
    SELECT truth_group, least(width_bucket(prob_bike, 0, 1, 10), 10) AS bucket, count(*) AS n
    FROM pts
    GROUP BY 1, 2
), pct AS (
    SELECT truth_group, bucket, n, 100.0 * n / sum(n) OVER (PARTITION BY truth_group) AS pct
    FROM bucketed
)
SELECT trim(to_char((b - 1) / 10.0, '0.0')) || '~' || trim(to_char(b / 10.0, '0.0')) AS prob_bike_range,
       coalesce(max(n)   FILTER (WHERE truth_group = 'bike'), 0)                        AS bike_n,
       round(coalesce(max(pct) FILTER (WHERE truth_group = 'bike'), 0), 1)              AS bike_pct,
       repeat('#', (coalesce(max(pct) FILTER (WHERE truth_group = 'bike'), 0) / 2)::int) AS bike_bar,
       coalesce(max(n)   FILTER (WHERE truth_group = 'walk'), 0)                        AS walk_n,
       round(coalesce(max(pct) FILTER (WHERE truth_group = 'walk'), 0), 1)              AS walk_pct,
       repeat('#', (coalesce(max(pct) FILTER (WHERE truth_group = 'walk'), 0) / 2)::int) AS walk_bar
FROM generate_series(1, 10) AS b
LEFT JOIN pct ON pct.bucket = b
GROUP BY b
ORDER BY b;


-- ───────────────────────────────────────────────────────────────────────────
-- 3c. (라벨이 들어온 경우) 앱 라벨 기준 분포: 3a 와 같은 5수치 요약을 point_label_comparison 뷰로
-- ───────────────────────────────────────────────────────────────────────────
SELECT label_group,
       count(*)                                                                         AS points,
       round(min(prob_bike)::numeric, 4)                                                AS min,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY prob_bike)::numeric, 4)       AS p25,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY prob_bike)::numeric, 4)       AS median,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY prob_bike)::numeric, 4)       AS p75,
       round(max(prob_bike)::numeric, 4)                                                AS max
FROM point_label_comparison
WHERE prob_bike IS NOT NULL AND label_group IN ('bike', 'walk')
GROUP BY label_group
ORDER BY label_group;


-- ───────────────────────────────────────────────────────────────────────────
-- 4a. 판정이 바뀌는 지점: 세션·구간별로 연속된 같은 판정을 한 묶음으로 (시작·끝 ts, 점 개수)
--     판정 NULL 도 '(판정없음)' 묶음으로 드러낸다. 좌표 순서는 구간 안의 idx.
-- ───────────────────────────────────────────────────────────────────────────
WITH ordered AS (
    SELECT g.session_id, g.id AS segment_id, g.idx AS segment_idx, p.idx, p.ts,
           coalesce(p.predicted_label, '(판정없음)') AS verdict
    FROM gps_point p JOIN segment g ON g.id = p.segment_id
), marked AS (
    SELECT *,
           CASE WHEN verdict = lag(verdict) OVER w THEN 0 ELSE 1 END AS is_start
    FROM ordered
    WINDOW w AS (PARTITION BY segment_id ORDER BY idx)
), runs AS (
    SELECT *, sum(is_start) OVER (PARTITION BY segment_id ORDER BY idx) AS run_no
    FROM marked
)
SELECT session_id,
       segment_idx,
       run_no,
       verdict,
       min(ts)                                                                          AS start_ts,
       max(ts)                                                                          AS end_ts,
       to_timestamp(min(ts) / 1000.0) AT TIME ZONE 'Asia/Seoul'                          AS start_kst,
       to_timestamp(max(ts) / 1000.0) AT TIME ZONE 'Asia/Seoul'                          AS end_kst,
       count(*)                                                                         AS points,
       round((max(ts) - min(ts)) / 1000.0)                                              AS seconds
FROM runs
GROUP BY session_id, segment_id, segment_idx, run_no, verdict
ORDER BY session_id, segment_idx, run_no;


-- ───────────────────────────────────────────────────────────────────────────
-- 4b. 궤적 끊김 횟수: bike / 비bike 두 값으로만 묶었을 때 세션별 bike 묶음 수와 전환 횟수
--     (bus->subway 같은 비bike 끼리의 변화는 PostGIS 궤적을 끊지 않으므로 합친다.
--      bike_runs 가 1보다 크면 그만큼 bike 궤적이 끊겼다. 300초 공백으로 나뉜 구간 경계도 끊김으로 센다)
-- ───────────────────────────────────────────────────────────────────────────
WITH ordered AS (
    SELECT g.session_id, g.id AS segment_id, p.idx,
           CASE WHEN p.predicted_label IS NULL THEN 'null'
                WHEN p.predicted_label = 'bike' THEN 'bike'
                ELSE 'not_bike' END AS verdict
    FROM gps_point p JOIN segment g ON g.id = p.segment_id
), marked AS (
    SELECT *, CASE WHEN verdict = lag(verdict) OVER (PARTITION BY segment_id ORDER BY idx) THEN 0 ELSE 1 END AS is_start
    FROM ordered
), runs AS (
    SELECT session_id, segment_id, verdict,
           sum(is_start) OVER (PARTITION BY segment_id ORDER BY idx) AS run_no
    FROM marked
), run_list AS (
    SELECT DISTINCT session_id, segment_id, run_no, verdict FROM runs
)
SELECT session_id,
       count(DISTINCT segment_id)                                                       AS segments,
       count(*) FILTER (WHERE verdict = 'bike')                                         AS bike_runs,
       count(*) FILTER (WHERE verdict = 'not_bike')                                     AS not_bike_runs,
       count(*) FILTER (WHERE verdict = 'null')                                         AS null_runs,
       count(*) - count(DISTINCT segment_id)                                            AS verdict_changes_within_segments
FROM run_list
GROUP BY session_id
ORDER BY session_id;


-- ───────────────────────────────────────────────────────────────────────────
-- 5. 수동 정답 구간 템플릿: 메모한 전환 시각으로 정답 구간을 넣고, 구간마다 판정이 어떻게 나왔나
--    정답 그룹과 일치한 비율(match_pct), bike 비율, 판정 NULL 개수, prob_bike 평균을 본다.
--    구간을 늘리려면 VALUES 에 행을 추가한다. 끝 ts 는 미포함.
-- ───────────────────────────────────────────────────────────────────────────
WITH truth (range_no, session_id, from_ts, to_ts, truth_group, note) AS (
    VALUES
        -- (구간번호, 'session_id'::uuid 또는 NULL::uuid, 시작 epoch ms, 끝 epoch ms, 'bike'|'walk'|'others', '메모')
        (1, NULL::uuid, (extract(epoch FROM timestamptz '2026-09-20 14:00:00+09') * 1000)::bigint,
                        (extract(epoch FROM timestamptz '2026-09-20 14:10:00+09') * 1000)::bigint, 'walk', '집 -> 대여소 도보'),
        (2, NULL::uuid, (extract(epoch FROM timestamptz '2026-09-20 14:10:00+09') * 1000)::bigint,
                        (extract(epoch FROM timestamptz '2026-09-20 14:40:00+09') * 1000)::bigint, 'bike', '한강 자전거길')
), pts AS (
    SELECT t.range_no, t.truth_group, t.note, t.from_ts, t.to_ts,
           p.predicted_label,
           CASE WHEN p.predicted_label IS NULL THEN NULL
                WHEN p.predicted_label IN ('bike', 'walk') THEN p.predicted_label
                ELSE 'others' END AS predicted_group,
           p.predicted_prob_bike
    FROM truth t
    JOIN segment g   ON (t.session_id IS NULL OR g.session_id = t.session_id)
    JOIN gps_point p ON p.segment_id = g.id AND p.ts >= t.from_ts AND p.ts < t.to_ts
)
SELECT range_no,
       truth_group,
       note,
       to_timestamp(min(from_ts) / 1000.0) AT TIME ZONE 'Asia/Seoul'                     AS from_kst,
       to_timestamp(min(to_ts) / 1000.0) AT TIME ZONE 'Asia/Seoul'                       AS to_kst,
       count(*)                                                                         AS points,
       count(*) FILTER (WHERE predicted_group IS NULL)                                  AS null_points,
       round(100.0 * count(*) FILTER (WHERE predicted_group = truth_group)
             / nullif(count(*) FILTER (WHERE predicted_group IS NOT NULL), 0), 1)       AS match_pct,
       round(100.0 * count(*) FILTER (WHERE predicted_group = 'bike')
             / nullif(count(*) FILTER (WHERE predicted_group IS NOT NULL), 0), 1)       AS bike_pct,
       count(*) FILTER (WHERE predicted_label = 'bike')                                 AS n_bike,
       count(*) FILTER (WHERE predicted_label = 'walk')                                 AS n_walk,
       count(*) FILTER (WHERE predicted_label IN ('bus', 'car', 'subway'))              AS n_others,
       round(avg(predicted_prob_bike)::numeric, 4)                                      AS avg_prob_bike
FROM pts
GROUP BY range_no, truth_group, note
ORDER BY range_no;
