CREATE EXTENSION IF NOT EXISTS postgis;

-- ─────────────────────────────────────────────────────────────
-- ingest: 세션과 원본 배치
-- ─────────────────────────────────────────────────────────────

CREATE TABLE session (
    session_id   UUID        PRIMARY KEY,
    device_id    TEXT        NOT NULL,
    state        TEXT        NOT NULL DEFAULT 'ACTIVE'
                             CHECK (state IN ('ACTIVE', 'CLOSED', 'ABANDONED')),
    -- 다음에 이어서 처리할 배치 번호. 이 번호가 도착해야 좌표 스트림이 전진합니다.
    next_seq     INTEGER     NOT NULL DEFAULT 0,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX session_active_idx ON session (last_seen_at) WHERE state = 'ACTIVE';

-- 앱이 보낸 배치 원본. (session_id, seq) 로 중복을 막습니다.
CREATE TABLE raw_batch (
    session_id  UUID        NOT NULL REFERENCES session (session_id),
    seq         INTEGER     NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload     JSONB       NOT NULL,
    consumed    BOOLEAN     NOT NULL DEFAULT FALSE,
    PRIMARY KEY (session_id, seq)
);

-- ─────────────────────────────────────────────────────────────
-- segment: 300초 공백으로 끊은 구간과 그 안의 좌표
-- ─────────────────────────────────────────────────────────────

CREATE TABLE segment (
    id              BIGSERIAL PRIMARY KEY,
    session_id      UUID    NOT NULL REFERENCES session (session_id),
    idx             INTEGER NOT NULL,          -- 세션 안에서 몇 번째 구간인지
    point_count     INTEGER NOT NULL DEFAULT 0,
    last_ts         BIGINT,
    windows_done    INTEGER NOT NULL DEFAULT 0, -- 추론이 끝난 묶음 개수
    flushed_through INTEGER NOT NULL DEFAULT 0, -- 판정이 확정돼 내보낸 좌표 수 (exclusive)
    closed          BOOLEAN NOT NULL DEFAULT FALSE,
    finalized       BOOLEAN NOT NULL DEFAULT FALSE,
    discarded       BOOLEAN NOT NULL DEFAULT FALSE, -- 200점 미만이라 버린 구간
    UNIQUE (session_id, idx)
);

-- 처리할 게 남은 구간만 빠르게 찾기 위한 부분 인덱스
CREATE INDEX segment_pending_idx ON segment (id) WHERE finalized = FALSE;

-- 필터를 통과한 좌표. idx 는 구간 안에서의 0-based 순번입니다.
CREATE TABLE gps_point (
    segment_id BIGINT           NOT NULL REFERENCES segment (id),
    idx        INTEGER          NOT NULL,
    ts         BIGINT           NOT NULL,
    lat        DOUBLE PRECISION NOT NULL,
    lng        DOUBLE PRECISION NOT NULL,
    acc        REAL,
    PRIMARY KEY (segment_id, idx)
);

-- 묶음 하나의 추론 결과
CREATE TABLE inference_window (
    segment_id    BIGINT  NOT NULL REFERENCES segment (id),
    start_idx     INTEGER NOT NULL,
    label         TEXT    NOT NULL,
    probs         JSONB   NOT NULL,
    model_version TEXT    NOT NULL,
    elapsed_ms    INTEGER,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (segment_id, start_idx)
);

-- ─────────────────────────────────────────────────────────────
-- store: 최종 판정이 bike 인 좌표만
-- ─────────────────────────────────────────────────────────────

CREATE TABLE track_point (
    session_id    UUID                     NOT NULL,
    ts            BIGINT                   NOT NULL,
    geom          GEOGRAPHY(POINT, 4326)   NOT NULL,
    model_version TEXT                     NOT NULL,
    PRIMARY KEY (session_id, ts)
);

CREATE INDEX track_point_geom_idx ON track_point USING GIST (geom);
CREATE INDEX track_point_session_idx ON track_point (session_id, ts);
