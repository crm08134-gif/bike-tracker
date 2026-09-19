-- 앱이 보낸 정답 라벨. 모델 판정과 같은 좌표 단위로 비교하려고 둡니다.
-- 앱 값을 그대로 적습니다 (NONE / BIKE / WALK / OTHER, 대문자). 모델 라벨(bike 등)과 대소문자가 다릅니다.
-- 이 마이그레이션 전에 들어온 좌표는 NULL 입니다.
ALTER TABLE gps_point ADD COLUMN label TEXT;

-- seq 빈 자리 감시가 5분마다 아직 반영 안 한 배치를 훑습니다. raw_batch 는 계속 쌓이므로
-- 반영이 끝난 행을 건너뛸 수 있게 부분 인덱스를 둡니다.
CREATE INDEX raw_batch_unconsumed_idx ON raw_batch (session_id, seq) WHERE consumed = FALSE;
