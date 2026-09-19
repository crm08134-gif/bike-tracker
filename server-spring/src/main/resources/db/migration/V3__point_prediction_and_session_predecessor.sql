-- ─────────────────────────────────────────────────────────────
-- D1. 좌표별 최종 판정. 혼동행렬(정답 label x predicted_label)을 만들려고 둡니다.
-- track_point 는 bike 판정만 담으므로 "bike 를 walk 로 틀린" 경우가 남지 않습니다.
-- 여기에는 겹침 규칙이 적용돼 확정되는 시점에 모든 좌표의 판정을 bike 여부와 무관하게 적습니다.
-- 200점 미만이라 버린 구간의 좌표는 판정이 없으므로 NULL 로 남습니다.
-- ─────────────────────────────────────────────────────────────
ALTER TABLE gps_point
    ADD COLUMN predicted_label     TEXT,              -- 겹침 규칙 적용 후 최종 판정 (소문자)
    ADD COLUMN predicted_prob_bike DOUBLE PRECISION,  -- 그 판정에 쓰인 bike 확률 (AVERAGE_PROBS 면 평균)
    ADD COLUMN model_version       TEXT;              -- 판정에 쓰인 모델 버전

-- 라벨 대소문자 통일. 앱은 BIKE, 모델은 bike 를 씁니다. 저장 시점부터 소문자로 정규화하고
-- 이미 들어간 값도 여기서 바꿉니다. raw_batch.payload 는 받은 원본 그대로 둡니다.
UPDATE gps_point SET label = lower(label) WHERE label IS NOT NULL AND label <> lower(label);

-- ─────────────────────────────────────────────────────────────
-- D2. 세션 승계 자리. 앱이 ABANDONED 를 받고 새 session_id 로 갈아탔을 때 이전 세션을 가리킵니다.
-- 아직 채우는 로직은 없습니다. 앞 세션이 서버에 한 번도 안 왔을 수 있어 FK 는 걸지 않습니다.
-- ─────────────────────────────────────────────────────────────
ALTER TABLE session ADD COLUMN previous_session_id UUID;
