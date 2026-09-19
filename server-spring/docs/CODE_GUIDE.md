# bike-tracker · Spring 서버 코드 설명서

> 대상: `D:\bike-tracker\server-spring`
> 스택: Spring Boot 4.1.1 · Java 21 · Gradle(Kotlin DSL) · PostgreSQL + PostGIS · Flyway · JDBC(JdbcTemplate)
> 루트 패키지: `io.github.crm08134.biketracker`

---

## 0. 이 문서의 구성

| 절 | 내용 |
| --- | --- |
| [1](#1-한눈에-보기) | 서버가 하는 일과 설계 원칙 |
| [2](#2-전체-아키텍처) | 시스템 구성, 데이터 흐름 |
| [3](#3-핵심-도메인-개념-5가지) | session / batch / segment / window / verdict |
| [4](#4-db-스키마) | 테이블·컬럼 전부와 마이그레이션 이력 |
| [5](#5-요청-처리-흐름-코드-단위) | 메서드 단위 동작 설명 |
| [6](#6-묶음-절단-규칙-windowspec) | 200/100 슬라이딩 윈도우 수학 |
| [7](#7-겹침-규칙-verdictresolver) | 한 좌표가 두 묶음에 겹칠 때 |
| [8](#8-추론-서버-연동-infer) | 재시도, 기동 대조, 배치 분할 |
| [9](#9-오류-응답-규약-common) | `retryable` 계약 |
| [10](#10-설정-레퍼런스) | `application.yml` 전 항목 |
| [11](#11-동시성정합성-설계-포인트) | 잠금 순서, 경합 처리 |
| [12](#12-테스트-지도) | 테스트가 무엇을 지키는지 |
| [13](#13-실행-방법) | 로컬/도커 |
| [14](#14-알려진-미결-지점과-주의사항) | 남은 숙제 |

---

## 1. 한눈에 보기

### 서버가 하는 일

앱(Flutter)이 30초마다 GPS 좌표 배치를 던지면, 서버는

1. **받아 적고 즉시 `202 Accepted`** 로 끊습니다 (판별 결과는 응답에 없음)
2. 좌표를 **필터**하고(정확도 20m 초과 / `acc` 없음 / `ts` 역행 → 폐기)
3. **300초 공백**을 기준으로 주행을 **구간(segment)** 으로 끊고
4. 구간 안에서 **200점씩, 100점 간격으로** 묶음(window)을 만들어
5. Python 추론 서버(`/v1/predict`)에 **뒤에서(워커)** 판별을 맡기고
6. 겹치는 묶음의 결과를 **겹침 규칙**으로 합쳐 좌표마다 최종 판정을 붙이고
7. 판정이 `bike` 인 좌표만 **PostGIS `track_point`** 에 적재합니다

### 설계 원칙 3가지

| 원칙 | 이유 |
| --- | --- |
| **앱 응답과 추론을 분리** | 추론이 느려도(묶음당 ~120ms) 앱은 30초 주기를 못 지키면 안 됨. 그래서 수신은 `202`, 추론은 `@Scheduled` 워커가 3초마다 |
| **`seq` 순서대로만 반영** | 좌표 순번(`idx`)이 어긋나면 "어떤 200점이 한 묶음인가"가 달라짐. 3번이 먼저 와도 2번이 올 때까지 `raw_batch` 에 눕혀둠 |
| **설정 불일치는 기동 거부** | `window_size`/`stride`/`accuracy_limit` 이 학습 때와 다르면 추론은 **에러 없이 조용히 틀림**. 기동 시 `/v1/model` 로 대조 |

### 패키지 책임

```
io.github.crm08134.biketracker
├── BikeTrackerApplication      진입점. @EnableScheduling + @EnableConfigurationProperties
├── common/                     오류 응답 형식 (ApiError, ApiException, 두 종류의 핸들러)
├── config/                     TrackerProperties(도메인 설정), HttpClientConfig(HTTP/1.1 고정)
├── ingest/                     배치 수신 · 중복 제거 · 필터 · 구간 분리 · 세션 상태
│   └── dto/                    BatchRequest / BatchResponse / PointDto
├── segment/                    묶음 절단 · 추론 호출 · 겹침 규칙 · 확정 · 워커
├── infer/                      Python 추론 서버 클라이언트 + 기동 대조 가드
├── query/                      GET /predictions (읽기 전용)
└── store/                      bike 좌표만 PostGIS 적재
```

---

## 2. 전체 아키텍처

### 시스템 구성

```
┌──────────────┐   POST /api/v1/sessions/{id}/batches   ┌───────────────────┐
│  Flutter 앱   │ ─────────── 30초마다, 202 ──────────► │                   │
│              │                                        │   Spring 서버      │
│              │ ◄──── GET .../predictions (gzip) ───── │   (:8080)         │
└──────────────┘                                        │                   │
                                                        └───┬───────────┬───┘
                                    POST /v1/predict        │           │  JDBC
                                    POST /v1/predict/batch  │           │
                                    GET  /v1/model          ▼           ▼
                                              ┌───────────────┐  ┌──────────────┐
                                              │ FastAPI 추론   │  │  PostGIS 16  │
                                              │  (:8000)      │  │  (:5432)     │
                                              └───────────────┘  └──────────────┘
```

### 두 개의 독립된 경로

**① 동기 경로 (앱 → 202)**

```
IngestController.receive
  └─ IngestService.accept                 @Transactional
       ├─ SessionRepository.findOrCreateForUpdate   ← 세션 행 FOR UPDATE 잠금
       ├─ RawBatchRepository.insertIfAbsent         ← (session_id, seq) 중복 제거
       └─ drain()                                   ← next_seq 부터 연속된 배치만 반영
            └─ append()                             ← 필터 + 구간 분리 + gps_point INSERT
```

여기서 **추론은 한 번도 호출되지 않습니다.**

**② 비동기 경로 (워커 → 추론 → 적재)**

```
SegmentWorker.tick  @Scheduled(fixedDelay=3s)
  └─ SegmentRepository.findPending(20)              ← finalized = FALSE 인 구간
       └─ SegmentProcessor.process(segmentId)       @Transactional
            ├─ runInference()   → InferenceClient   → FastAPI
            ├─ flush()          → VerdictResolver   → gps_point.predicted_* UPDATE
            │                                       → TrackRepository → track_point INSERT
            └─ finalizeUnlessChanged()              ← 낙관적 잠금
```

### 시간 순서로 본 한 주행

```
t=0s     앱: seq=0 배치(좌표 30개) ──► 202 {session_state: ACTIVE, next_seq: 1}
t=30s    앱: seq=1 배치           ──► 202 {..., next_seq: 2}
         ...
t=200s   좌표 누적 200개 도달
t=201s   워커: 묶음 0 [0,200) 추론 → label=bike
         → 좌표 0..99 확정 → track_point 적재       ※ settledExclusive(1) = 100
t=300s   좌표 300개
         워커: 묶음 1 [100,300) 추론
         → 좌표 100..199 확정 (묶음 0·1 평균)
         ...
t=1800s  앱: POST /close
         → 열린 구간 close → 워커가 남은 묶음 처리 후
           끝부분(마지막 묶음 뒤 1~99점)을 마지막 묶음 판정으로 확정 → finalized
```

---

## 3. 핵심 도메인 개념 5가지

### 3.1 session — 주행 하나

- 앱이 만든 UUID. 상태는 `ACTIVE` → `CLOSED` 또는 `ABANDONED`
- `next_seq`: **서버가 다음에 기다리는 배치 번호.** 응답으로 앱에 돌려줘 재전송 지점을 알려줌
- `CLOSED` 가 되는 경로 2가지: `POST /close`, 또는 `is_last_batch: true` 배치가 **순서대로 반영되는 시점**
- `ABANDONED`: 마지막 배치 후 15분 조용하면 워커가 강등. **늦게 온 배치를 거부하지는 않음** — "더 기다리지 않는다"는 표시일 뿐

### 3.2 raw_batch — 앱이 보낸 원본

- PK `(session_id, seq)` 로 **중복 전송을 DB 제약으로 막음** (앱 재시도 안전)
- `consumed` 플래그: 좌표 스트림에 반영됐는지
- 원본 JSON 을 `jsonb` 로 통째로 보관 → 나중 분석·재처리 가능

### 3.3 segment — 300초 공백으로 끊은 구간

**왜 끊는가**: 신호가 5분 이상 끊기면 그 사이 어디로 갔는지 모릅니다. 이어 붙이면 순간이동 좌표가 생겨 속도 특징이 망가집니다.

| 컬럼 | 의미 |
| --- | --- |
| `idx` | 세션 안에서 몇 번째 구간 |
| `point_count` | 이 구간에 쌓인 좌표 수 |
| `last_ts` | 마지막 좌표 시각 (다음 좌표의 공백 판정용) |
| `windows_done` | 추론이 끝난 묶음 개수 |
| `flushed_through` | 판정이 확정돼 내보낸 좌표 수 (exclusive) |
| `closed` | 더 이상 좌표가 안 붙음 |
| `finalized` | 처리 완료 (워커가 더 안 봄) |
| `discarded` | 200점 미만이라 통째로 버림 |

### 3.4 window(묶음) — 추론 단위

- 구간 안에서 **200점**을, **100점 간격**으로 잘라낸 것
- 좌표 450개 구간이면 묶음 3개: `[0,200) [100,300) [200,400)` + 끝부분 50점
- **200점이 안 되면 묶음 0개** → 구간 통째로 `discarded`

### 3.5 verdict(판정) — 좌표 하나의 최종 결론

- 한 좌표는 최대 2개 묶음에 겹침 → `OverlapStrategy` 로 합침
- 판정은 **bike 여부와 무관하게 전부** `gps_point.predicted_label` 에 기록 (혼동행렬용)
- **bike 인 것만** `track_point` 에 PostGIS geography 로 적재

---

## 4. DB 스키마

### 마이그레이션 이력 (`src/main/resources/db/migration/`)

| 파일 | 내용 |
| --- | --- |
| `V1__init.sql` | 5개 테이블 전부 + PostGIS extension |
| `V2__gps_point_label_and_seq_gap.sql` | `gps_point.label`(앱 정답 라벨), `raw_batch` 부분 인덱스 |
| `V3__point_prediction_and_session_predecessor.sql` | `gps_point.predicted_*` 3컬럼, `session.previous_session_id` |
| `V4__label_group_view.sql` | `point_label_comparison` 뷰 (3그룹 혼동행렬용) |

### 테이블

```sql
session
  session_id          UUID PK
  device_id           TEXT NOT NULL
  state               TEXT CHECK (ACTIVE | CLOSED | ABANDONED)
  next_seq            INTEGER DEFAULT 0     -- 다음에 기다리는 배치 번호
  started_at          TIMESTAMPTZ
  last_seen_at        TIMESTAMPTZ           -- ABANDONED 판정 기준
  previous_session_id UUID                  -- V3. 아직 채우는 로직 없음
  INDEX (last_seen_at) WHERE state = 'ACTIVE'    -- 부분 인덱스

raw_batch
  (session_id, seq)   PK                    -- 중복 전송 방어
  received_at         TIMESTAMPTZ
  payload             JSONB NOT NULL        -- 앱이 보낸 원본 그대로
  consumed            BOOLEAN DEFAULT FALSE
  INDEX (session_id, seq) WHERE consumed = FALSE -- seq 빈자리 감시용

segment
  id                  BIGSERIAL PK
  session_id          UUID FK
  idx                 INTEGER               -- UNIQUE (session_id, idx)
  point_count, last_ts, windows_done, flushed_through
  closed, finalized, discarded  BOOLEAN
  INDEX (id) WHERE finalized = FALSE        -- 워커가 훑는 부분 인덱스

gps_point                                   -- 필터를 통과한 좌표
  (segment_id, idx)   PK                    -- idx 는 구간 안 0-based 순번
  ts                  BIGINT                -- epoch millis
  lat, lng            DOUBLE PRECISION
  acc                 REAL
  label               TEXT                  -- V2. 앱 정답 라벨(소문자 정규화)
  predicted_label     TEXT                  -- V3. 겹침 규칙 적용 후 최종 판정
  predicted_prob_bike DOUBLE PRECISION      -- V3. 그 판정의 bike 확률
  model_version       TEXT                  -- V3

inference_window                            -- 묶음 하나의 추론 결과
  (segment_id, start_idx) PK
  label               TEXT
  probs               JSONB                 -- {"bike":0.9,"walk":0.1,...}
  model_version       TEXT
  elapsed_ms          INTEGER
  created_at          TIMESTAMPTZ

track_point                                 -- 최종 산출물. bike 만.
  (session_id, ts)    PK
  geom                GEOGRAPHY(POINT, 4326)
  model_version       TEXT
  INDEX USING GIST (geom)
  INDEX (session_id, ts)
```

### 뷰: `point_label_comparison` (V4)

앱 라벨(`bike/walk/other/none`)과 모델 라벨(`bike/bus/car/subway/walk`)은 집합이 달라 그대로 비교가 안 됩니다. 양쪽을 **3그룹(bike / walk / others)** 으로 접습니다.

- `label = 'none'`(정답 없음)과 `label IS NULL`(V2 이전 데이터)은 **제외**
- 매핑에 없는 값은 NULL 이 아니라 **`'unmapped'`** 로 드러냄 (조용히 빠지지 않게)
- 판정 없는 좌표는 `predicted_group = NULL` 로 남김 (M6 분석에서 그 빈도를 봐야 하므로)

분석 쿼리 모음은 리포지토리 루트의 `docs/m6_analysis.sql`.

---

## 5. 요청 처리 흐름 (코드 단위)

### 5.1 `POST /api/v1/sessions/{sessionId}/batches`

**`IngestController.receive`** — `@Valid @RequestBody BatchRequest`, `@ResponseStatus(ACCEPTED)`

요청 본문 (snake_case):

```json
{
  "device_id": "16fd2706-...",
  "seq": 0,
  "is_last_batch": false,
  "points": [
    {"ts": 1757750400000, "lat": 37.5665, "lng": 126.9779,
     "acc": 4.5, "spd": 5.25, "alt": 38.7, "label": "BIKE"}
  ]
}
```

**`BatchRequest` 검증 규칙**

- `device_id`, `seq`(≥0), `points` 는 `@NotNull`
- `@AssertTrue isPointsPresentUnlessLast()` — **빈 `points` 는 마지막 배치일 때만 허용**. 좌표를 하나도 못 받고 끝난 주행의 종료 신호가 이 모양으로 옵니다
- `@JsonIgnore` 가 붙어 있음 — 없으면 Jackson 이 이 검증 메서드를 속성으로 보고 `raw_batch.payload` 에 `points_present_unless_last: true` 를 적어버립니다

**`PointDto`**: 모델이 쓰는 건 `ts·lat·lng` 뿐. `acc` 는 필터에만, `spd·alt` 는 받되 무시. `label` 은 사용자가 고른 정답 라벨로, 판정에는 쓰지 않고 `gps_point` 에 그대로 적습니다.

**응답**: `202` + `{"session_state": "ACTIVE", "next_seq": 1}`

---

### 5.2 `IngestService.accept` — 수신 트랜잭션

```java
@Transactional
public BatchResponse accept(UUID sessionId, BatchRequest body) {
    SessionRow session = sessions.findOrCreateForUpdate(sessionId, body.deviceId());  // ①
    if (session.state() != SessionState.ACTIVE) { log.info("끝난 세션에 배치 수신, 이어 붙입니다 ..."); }
    boolean fresh = batches.insertIfAbsent(sessionId, body.seq(), toJson(body));      // ②
    Drained d = drain(session);                                                       // ③
    return new BatchResponse(d.state(), d.nextSeq());
}
```

**① `findOrCreateForUpdate` — 왜 `FOR UPDATE` 인가**

`INSERT ... ON CONFLICT DO NOTHING` 후 `SELECT ... FOR UPDATE`.

> 앱은 배치를 **동시에 3건까지** 보냅니다. 잠그지 않으면 두 요청이 같은 `next_seq` 를 읽고, 늦게 끝난 쪽이 앞선 쪽이 올려둔 `next_seq` 를 **되돌려 씁니다.** 되돌아간 번호의 배치는 이미 `consumed = TRUE` 라 다시 읽히지 않으므로 **그 세션은 영원히 멈춥니다.**

이게 이 서버에서 가장 중요한 잠금입니다.

**② `insertIfAbsent`** — `ON CONFLICT (session_id, seq) DO NOTHING`. 이미 있으면 `false`(중복 재전송)지만 그래도 `drain` 은 돕니다.

**③ `drain`** — 아래.

---

### 5.3 `drain` — seq 순서 보장

```java
private Drained drain(SessionRow session) {
    int seq = session.nextSeq();
    while (true) {
        String payload = batches.findPayload(sessionId, seq);   // consumed = FALSE 인 것만
        if (payload == null) break;                             // 빈 자리 → 여기서 멈춤
        BatchRequest batch = readBatch(payload);
        append(sessionId, seq, batch.points());
        batches.markConsumed(sessionId, seq);
        if (batch.lastBatch() && state == ACTIVE) { state = CLOSED; sessions.setState(...); }
        seq++;
    }
    if (state != ACTIVE) segments.closeOpen(sessionId);
    sessions.touch(sessionId, seq);      // next_seq 갱신 + last_seen_at = now()
    return new Drained(state, seq);
}
```

**핵심 3가지**

1. **`next_seq` 부터 연속으로 도착해 있는 배치만** 반영합니다. seq 2가 없으면 3,4,5가 이미 와 있어도 `raw_batch` 에 그대로 눕습니다 → 나중에 2가 오면 그 요청에서 2,3,4,5가 한 번에 반영됩니다
2. `is_last_batch` 처리는 **받은 시점이 아니라 순서대로 반영되는 시점**에 합니다. 받은 시점에 닫으면 동시 전송으로 먼저 도착한 마지막 배치가 앞 번호보다 먼저 세션을 닫아버립니다
3. `ACTIVE` 에서만 `CLOSED` 로 갑니다. `ABANDONED` 는 종착 상태라 그대로 둡니다

**끝난 세션에 배치가 오면**: 거부하지 않고 이어 붙인 뒤 `closeOpen()` 으로 다시 닫습니다. 같은 주행인지 아닌지는 **300초 공백 규칙**이 정합니다.

---

### 5.4 `append` — 필터 + 구간 분리

좌표 하나하나에 대해:

```
① acc == null            → 폐기 (noAcc++)
② acc > 20m              → 폐기 (inaccurate++)
③ ts <= 직전 ts          → 폐기 (nonIncreasing++)   ※ 속도가 inf 가 되는 걸 막는 방어
④ ts - 직전 ts > 300초   → 현재 구간 close, 새 구간 open
⑤ gps_point INSERT (segment_id, idx=point_count, ts, lat, lng, acc, label)
```

로그: `배치 반영 session=.. seq=.. received=30 stored=28 dropped: no_acc=1 acc_over_limit=1 ts_non_increasing=0`

**성능 포인트**: `SegmentRow.withAppended(ts)` 로 메모리에서 카운트를 올리고, **DB `UPDATE segment` 는 배치 끝에 딱 한 번**(`updateTail`)입니다. 좌표 30개마다 30번 UPDATE 하지 않습니다.

**`closedTail` 분기**: 열린 구간이 없으면(= 끝난 세션에 늦은 배치가 온 경우) 마지막 닫힌 구간을 `FOR UPDATE` 로 잠그고, 300초 안이면 **다시 엽니다**(`reopen`). 300초를 넘었으면 새 구간을 엽니다.

---

### 5.5 `reopen` — 확정을 무르는 유일한 경로

```java
private SegmentRow reopen(SegmentRow seg) {
    int settled = Math.min(seg.flushedThrough(), spec.settledExclusive(seg.windowsDone()));
    if (seg.flushedThrough() > settled) {
        tracks.deleteBySegmentRange(seg.sessionId(), seg.id(), settled, seg.flushedThrough());
        segments.clearPredictions(seg.id(), settled, seg.flushedThrough());
    }
    return segments.reopen(seg, settled);
}
```

**왜 필요한가**: 구간이 닫힐 때 끝부분(마지막 묶음 뒤 1~99점)은 "마지막 묶음의 판정"으로 **임시 확정**됐습니다. 여기에 좌표가 더 붙으면 새 묶음이 만들어져 판정이 달라집니다. 그래서:

- `settled` = **진짜로 안 바뀌는 지점**(`windows_done * stride`)
- 그 뒤는 `track_point` 삭제 + `gps_point.predicted_*` NULL 로 되돌림
- `segment` 는 `closed=FALSE, finalized=FALSE, discarded=FALSE` 로 복구 → **200점 미만이라 버렸던 구간도 다시 기회를 얻습니다**

---

### 5.6 `POST /api/v1/sessions/{sessionId}/close`

```java
@Transactional
public BatchResponse close(UUID sessionId) {
    SessionRow session = sessions.requireForUpdate(sessionId);   // 없으면 404 SESSION_NOT_FOUND
    int nextSeq = drain(session).nextSeq();                      // 도착해 있는 배치 먼저 반영
    segments.closeOpen(sessionId);
    sessions.setState(sessionId, SessionState.CLOSED, nextSeq);
    return new BatchResponse(SessionState.CLOSED, nextSeq);
}
```

`closeOpen` 이 열린 구간을 닫으면, 다음 워커 주기에 **끝부분 규칙**이 적용되고 `finalized` 됩니다.

---

### 5.7 `SegmentWorker` — 3개의 스케줄 작업

```java
@Scheduled(fixedDelayString = "${tracker.worker.fixed-delay}")        // PT3S
public void tick() {
    for (SegmentRow seg : segments.findPending(props.getWorker().getBatchSize())) {  // 20건
        try { processor.process(seg.id()); }
        catch (SegmentChangedException e)       { /* 정상 경합. 다음 주기 */ }
        catch (InferenceUnavailableException e) { /* 추론 서버 대기. 다음 주기 */ }
        catch (RuntimeException e) { log.error(...); }   // 구간 하나가 죽어도 나머지는 진행
    }
}

@Scheduled(fixedDelayString = "${tracker.worker.seq-gap-scan-delay}")  // PT5M → SeqGapMonitor.scan()
@Scheduled(fixedDelayString = "${tracker.worker.abandon-scan-delay}")  // PT5M → IngestService.abandonStale()
```

예외를 **세 단계로 구분**하는 게 핵심입니다. 경합(INFO) / 일시 장애(WARN) / 진짜 버그(ERROR).

---

### 5.8 `SegmentProcessor.process` — 구간 하나 진행

```java
@Transactional
public void process(long segmentId) {
    SegmentRow seg = segments.findById(segmentId).orElse(null);
    if (seg == null) return;

    int available = spec.windowCount(seg.pointCount());                 // 만들 수 있는 묶음 수

    // ① 아직 안 보낸 묶음을 추론에 보낸다 (한 주기에 batchChunkSize 개까지만)
    int target = Math.min(available, seg.windowsDone() + model.batchChunkSize());
    if (target > seg.windowsDone()) runInference(seg, seg.windowsDone(), target);

    List<WindowResult> results = windows.findAll(segmentId);

    // ② 확정된 좌표를 내보낸다
    int settled = spec.settledExclusive(results.size());
    int flushed = flush(seg, results, seg.flushedThrough(), settled);

    // 아직 열려 있거나 묶음이 덜 끝났으면 진행분만 기록하고 종료
    if (!seg.closed() || results.size() < available) {
        segments.markProgress(segmentId, results.size(), flushed);
        return;
    }

    // ③ 구간이 닫혔다 — 200점 미만이면 통째로 폐기
    if (results.isEmpty()) { finalizeUnlessChanged(seg, true); return; }

    // 끝부분(1~99점)을 마지막 묶음 판정으로 확정
    flushed = flush(seg, results, flushed, seg.pointCount());
    segments.markProgress(segmentId, results.size(), flushed);
    finalizeUnlessChanged(seg, false);
}
```

**`batchChunkSize` 로 끊어 보내는 이유**: 오프라인 백로그로 묶음이 수백 개 밀려도

- 요청 하나가 `read-timeout`(30s)을 넘지 않고
- 트랜잭션이 짧게 끊겨 **진행분이 주기마다 커밋**됩니다 (전부 실패 → 전부 롤백을 피함)

**`finalizeUnlessChanged` — 낙관적 잠금**

```sql
UPDATE segment SET finalized = TRUE, discarded = ?
WHERE id = ? AND point_count = ? AND finalized = FALSE
```

읽었을 때의 `point_count` 와 다르면 0행 → `SegmentChangedException` → **이번 트랜잭션 전체(끝부분 적재 포함) 롤백.** 처리 도중 늦은 배치가 구간을 다시 열었다는 뜻이고, 그대로 마무리하면 새로 붙은 좌표가 영영 처리되지 않습니다.

---

### 5.9 `runInference` — 묶음을 추론에 보내기

```java
if (requests.size() >= props.getInference().getBatchThreshold()) {    // 기본 2
    responses = inference.predictBatch(requests);                     // POST /v1/predict/batch
    if (responses.size() != requests.size()) throw new InferenceUnavailableException(...);
} else {
    for (PredictRequest r : requests) responses.add(inference.predict(r));   // POST /v1/predict
}
for (int i = 0; i < responses.size(); i++)
    windows.save(seg.id(),
        new WindowResult(spec.startIdx(from + i), r.label(), r.probs(), r.modelVersion()), r.elapsedMs());
```

**`buildRequest`** 는 묶음 크기를 반드시 검증합니다:

```java
if (pts.size() != spec.size())
    throw new IllegalStateException("묶음 크기가 맞지 않습니다 segment=.. window=.. size=..");
```

추론 서버는 200점이 아니면 `422 WINDOW_SIZE` 로 거부하므로, 여기서 먼저 잡아 원인을 명확히 남깁니다.

`window_start_ts` 는 그 묶음 **첫 좌표의 ts** 입니다.

`WindowRepository.save` 는 `ON CONFLICT (segment_id, start_idx) DO NOTHING` — 재처리해도 안전(멱등)합니다.

---

### 5.10 `flush` — 확정과 적재

```java
private int flush(SegmentRow seg, List<WindowResult> results, int from, int to) {
    if (to <= from || results.isEmpty()) return from;
    for (SegmentPoint p : segments.findPoints(seg.id(), from, to)) {
        Verdict v = resolver.resolve(p.idx(), results);
        predictions.add(new PointPrediction(p.idx(), v.label(), v.probs().get("bike"), v.modelVersion()));
        if ("bike".equals(v.label())) bike.add(new BikePoint(p.ts(), p.lat(), p.lng(), v.modelVersion()));
    }
    segments.savePredictions(seg.id(), predictions);   // batchUpdate: gps_point UPDATE
    tracks.insertBikePoints(seg.sessionId(), bike);    // batchUpdate: track_point INSERT
    return to;
}
```

**판정은 전부 기록, 적재는 bike 만.** `track_point` 는 bike 만 담으므로 "bike 를 walk 로 틀린" 경우가 남지 않습니다. 혼동행렬을 만들려면 `gps_point.predicted_label` 이 필요해서 V3 에서 추가됐습니다.

**`TrackRepository.insertBikePoints`**

```sql
INSERT INTO track_point (session_id, ts, geom, model_version)
VALUES (?, ?, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)
ON CONFLICT (session_id, ts) DO NOTHING
```

> ⚠️ `ST_MakePoint` 는 **(경도, 위도)** 순서입니다. 코드에서 `setDouble(3, p.lng()); setDouble(4, p.lat());` 로 뒤집어 넣습니다.

---

### 5.11 `GET /api/v1/sessions/{sessionId}/predictions`

```java
@Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
public PredictionsResponse find(UUID sessionId) { ... }
```

**`REPEATABLE_READ` 인 이유**: 쿼리 4개(상태 / 진행 / 대기배치 / 좌표목록)를 **한 스냅숏**에서 읽어야 합니다. `READ COMMITTED` 면 쿼리 사이에 워커가 판정을 적어 "진행 숫자와 좌표 목록이 서로 다른 시점"을 보여줍니다.

**응답**

```json
{
  "session_id": "...",
  "session_state": "CLOSED",
  "progress": { "total_points": 1800, "predicted_points": 1700, "unpredictable_points": 50 },
  "waiting_batches": 0,
  "points": [ {"ts":0, "lat":0, "lng":0, "predicted_label":"bike", "predicted_prob_bike":0.93} ]
}
```

| 필드 | 의미 |
| --- | --- |
| `total_points` | 필터를 통과해 **저장된** 좌표 수 (폰 좌표 수보다 적을 수 있음) |
| `predicted_points` | 판정이 적힌 좌표 수 |
| `unpredictable_points` | `segment.discarded` 구간의 좌표 = **영영 판정되지 않음** |
| 대기 중 | `total - predicted - unpredictable` (앱에서 직접 계산) |
| `waiting_batches` | `consumed = FALSE` 인 배치 수. **0 이 아니면 `total_points` 가 나중에 늘어남** |

**페이지를 나누지 않는 이유**: 앱은 좌표 전부를 캐시로 통째로 교체합니다. 나눠 받으면 그 사이 워커가 판정을 적어 페이지끼리·진행 숫자와 어긋납니다. 크기는 gzip(`server.compression.enabled`)으로 줄입니다. 30분 ≈ 1800점 ≈ 200KB.

---

### 5.12 `SeqGapMonitor` — 멈춘 세션 감시

앱이 어떤 배치를 영영 안 보내면(앱에서 DEAD 처리 등) 그 뒤 배치는 `raw_batch` 에 쌓이기만 합니다. **자동으로 건너뛰지 않고 멈췄다는 사실만 알립니다.**

```sql
-- SessionRepository.findSeqGaps
SELECT s.session_id, s.state, s.next_seq, COUNT(*) AS waiting,
       MIN(r.seq) AS first_waiting_seq, MIN(r.received_at) AS blocked_since
FROM session s
JOIN raw_batch r ON r.session_id = s.session_id AND r.consumed = FALSE AND r.seq > s.next_seq
WHERE NOT EXISTS (SELECT 1 FROM raw_batch x
                  WHERE x.session_id = s.session_id AND x.seq = s.next_seq AND x.consumed = FALSE)
GROUP BY s.session_id, s.state, s.next_seq
HAVING MIN(r.received_at) < ?    -- 5분 이상 기다린 것만
```

로그 정책 (`ConcurrentHashMap<UUID, Integer> reported` 로 상태 유지):

- 멈춘 자리 **하나당 ERROR 한 번**
- 풀리면 **INFO 한 번** 남기고 기록 삭제
- 같은 세션이 풀린 뒤 **다른 번호에서 다시 멈추면 새로 ERROR**
- 기록은 메모리에만 → 서버 재기동 시 아직 멈춘 자리를 한 번 더 알립니다

---

### 5.13 `abandonStale` — 조용한 세션 정리

```java
for (UUID id : sessions.findStale(abandonAfter)) {
    if (!sessions.abandonIfStale(id, abandonAfter)) continue;   // 조회 뒤 배치가 들어왔으면 skip
    segments.closeOpen(id);
}
```

`abandonIfStale` 은 `UPDATE ... WHERE state='ACTIVE' AND last_seen_at < ?` 로 **조건부 갱신**합니다. 조회와 갱신 사이에 배치가 들어왔으면 0행 → 건너뜁니다.

> 잠금 순서: **세션 행 먼저, 구간 나중.** 배치 수신 경로와 같은 순서라 교착이 나지 않습니다.

---

## 6. 묶음 절단 규칙 (`WindowSpec`)

```java
public record WindowSpec(int size, int stride) {   // 200, 100
```

생성자에서 불변식을 검사합니다: `size > 0`, `stride > 0`, **`stride <= size`**(아니면 어느 묶음에도 안 들어가는 좌표가 생김).

| 메서드 | 정의 | 예 (450점) |
| --- | --- | --- |
| `windowCount(n)` | `n < size ? 0 : (n - size)/stride + 1` | `windowCount(450) = 3` |
| `startIdx(w)` | `w * stride` | 0, 100, 200 |
| `endIdx(w)` | `w * stride + size` | 200, 300, 400 |
| `settledExclusive(w)` | `w * stride` | 묶음 3개 끝 → 좌표 0..299 확정 |
| `firstCoveringWindow(i)` | `max(0, ceilDiv(i - size + 1, stride))` | |
| `lastCoveringWindow(i, done)` | `min(done - 1, i / stride)` | |

### 450점 구간 전체 그림

```
좌표 idx   0        100       200       300       400   450
           |─────────|─────────|─────────|─────────|─────|
묶음 0     [=================]                            [0,200)
묶음 1               [=================]                  [100,300)
묶음 2                         [=================]        [200,400)
끝부분                                             [=====] 50점, 덮는 묶음 없음
```

| 좌표 구간 | 덮는 묶음 | 판정 |
| --- | --- | --- |
| 0 ~ 99 | 0 | 묶음 0 그대로 |
| 100 ~ 199 | 0, 1 | **겹침 규칙** |
| 200 ~ 299 | 1, 2 | **겹침 규칙** |
| 300 ~ 399 | 2 | 묶음 2 그대로 |
| 400 ~ 449 | (없음) | 마지막 묶음(2)의 판정 |

### 확정 시점의 증명

> 좌표 `i` 를 덮을 수 있는 **마지막** 묶음은 `i / stride` 번입니다. 그보다 뒤에서 시작하는 묶음은 시작점이 `i` 보다 커서 `i` 를 포함하지 않습니다.
> 따라서 묶음 `w` 까지 계산이 끝났다면 `i / stride <= w` 인 좌표, 즉 **`i < (w+1) * stride`** 인 좌표는 판정이 더 바뀌지 않습니다.

이게 `settledExclusive(windowsDone) = windowsDone * stride` 의 근거이고, 좌표를 **기다리지 않고 즉시 적재**할 수 있게 하는 핵심입니다.

| 묶음 완료 | 확정 좌표 |
| --- | --- |
| 0개 | 없음 |
| 1개 | 0 ~ 99 |
| 2개 | 0 ~ 199 |
| 3개 | 0 ~ 299 |
| 구간 close | 300 ~ 449 (끝부분 규칙) |

**200점 미만 구간**: `windowCount(199) = 0` → 묶음 0개 → 통째로 `discarded`. `GET /predictions` 의 `unpredictable_points` 에 잡힙니다.

---

## 7. 겹침 규칙 (`VerdictResolver`)

```java
public Verdict resolve(int idx, List<WindowResult> windows) {
    if (windows.isEmpty()) return null;                    // 200점 미만 → 버릴 구간
    List<WindowResult> covering = covering(idx, windows);
    if (covering.isEmpty()) covering = List.of(마지막 묶음);   // 끝부분 규칙
    return switch (strategy) {
        case AVERAGE_PROBS -> averaged(covering);
        case STRICT_BIKE   -> strictBike(covering);
        case LATEST_WINDOW -> single(마지막);
    };
}
```

### 세 전략

| 전략 | 동작 | 특징 |
| --- | --- | --- |
| **`AVERAGE_PROBS`** (기본) | 덮는 묶음들의 확률을 라벨별로 평균 → argmax | 계획서 제안. 부드러움 |
| `STRICT_BIKE` | 덮는 묶음이 **전부** bike 일 때만 bike. 아니면 bike 를 뺀 나머지 중 최고 | DB 오염은 적지만 궤적이 자주 끊김 |
| `LATEST_WINDOW` | 나중 묶음 판정 그대로 | 가장 단순 |

### 실제 계산 예 (`VerdictResolverTest`)

묶음 0: `bike 0.90 / walk 0.10`, 묶음 1: `bike 0.40 / walk 0.60`, 묶음 2: `bike 0.95 / walk 0.05`

| 좌표 | 덮는 묶음 | AVERAGE_PROBS | STRICT_BIKE | LATEST_WINDOW |
| --- | --- | --- | --- | --- |
| 50 | 0 | bike (0.90) | bike | bike |
| 150 | 0, 1 | **bike** (0.65 vs 0.35) | **walk** | **walk** |
| 250 | 1, 2 | bike (0.675) | bike 아님 | bike |
| 420 | (끝부분→2) | bike (0.95) | bike | bike |

### `argmax` 의 결정성

```java
if (e.getValue() > bestValue
        || (e.getValue() == bestValue && best != null && e.getKey().compareTo(best) < 0)) {
```

동점이면 **라벨 알파벳 순**으로 고정합니다. `HashMap` 순회 순서에 결과가 흔들리면 같은 입력에 다른 답이 나오기 때문입니다.

---

## 8. 추론 서버 연동 (`infer`)

### 8.1 `InferenceClient`

| 메서드 | 엔드포인트 | 재시도 |
| --- | --- | --- |
| `modelInfo()` | `GET /v1/model` | ❌ (기동 가드가 직접 기다림) |
| `predict(req)` | `POST /v1/predict` | ✅ |
| `predictBatch(reqs)` | `POST /v1/predict/batch` | ✅ |

**오류 번역 (`translate`)**

```java
boolean retryable = body != null ? body.retryable() : status.is5xxServerError();
if (retryable) return new InferenceUnavailableException(...);   // 워커가 다음 주기로 미룸
return new IllegalStateException("추론 요청이 거부됐습니다: " + detail);   // 우리 버그
```

- `503 MODEL_NOT_READY`, 네트워크 오류 → 재시도
- `422 WINDOW_SIZE` / `NON_INCREASING_TS` → **우리가 보낸 묶음이 잘못된 것.** 재시도해도 똑같으니 터뜨립니다

**`withRetry`**: 최대 3회, 백오프는 `retryBackoff * attempt`(1s, 2s, 3s — 선형 증가). `InterruptedException` 시 인터럽트 플래그를 복원하고 예외로 전환합니다.

### 8.2 `HttpClientConfig` — HTTP/1.1 고정 (⚠️ 중요)

```java
@Bean
ClientHttpRequestFactoryBuilderCustomizer<JdkClientHttpRequestFactoryBuilder> http11Only() {
    return builder -> builder.withHttpClientCustomizer(b -> b.version(HttpClient.Version.HTTP_1_1));
}
```

> JDK `HttpClient` 는 기본이 HTTP/2 라서 `http://` 주소에 `Upgrade: h2c` 헤더를 붙입니다. uvicorn 은 이 업그레이드를 지원하지 않아 **"Unsupported upgrade request"** 를 남기고 POST 본문을 읽지 못합니다.
> 결과: `/v1/predict` 가 `422 (body: Field required)` 로 거부되는데, **GET 인 `/v1/model` 은 멀쩡해서 기동 대조는 통과해버립니다.** 즉 기동은 성공하고 추론만 전부 실패하는 최악의 형태라 반드시 고정합니다.

### 8.3 `InferenceModelGuard` — 기동 대조

`SmartInitializingSingleton` 을 구현 → **모든 빈이 만들어진 직후, 웹 서버가 요청을 받기 전**에 실행됩니다. 잘못된 설정으로는 배치를 한 건도 받지 않습니다.

**대조 항목 5가지**

| 항목 | `application.yml` | `/v1/model` |
| --- | --- | --- |
| `window_size` | `tracker.window-size` | `window_size` |
| `stride` | `tracker.stride` | `stride` |
| `accuracy_limit` | `tracker.accuracy-limit-m` | `accuracy_limit` |
| `seg_gap_sec` (ms 환산) | `tracker.segment-gap-ms` | `seg_gap_sec * 1000` |
| `classes` 포함 여부 | `tracker.bike-label` | `classes` 배열 |

하나라도 다르면 항목명과 **양쪽 값을 모두 찍고** `IllegalStateException` 으로 기동을 거부합니다:

```
항목=window_size application.yml(tracker.window-size)=200 추론서버(/v1/model)=180
```

**`fetch`**: 모델 로드 중(503)이면 `startup-timeout`(90s)까지 2초 간격으로 폴링합니다. 도커 compose 의 `depends_on: service_healthy` 와 중복 방어입니다.

**`batchChunkSize()`**: `max(1, min(서버의 max_batch_size, tracker.inference.max-batch-chunk))`

- 서버가 알려주는 256 × 묶음당 ~120ms = **30.7초 → `read-timeout`(30s) 초과**
- 30s / 120ms = 250 이 한계. 추론 지연이 흔들리는 걸 감안해 **안전계수 2배로 120**
- 남은 묶음은 다음 워커 주기에 이어서 전송합니다

---

## 9. 오류 응답 규약 (`common`)

### 계약

```json
{ "error": "INVALID_REQUEST", "detail": "points[0].ts: must not be null", "retryable": false }
```

> **모든 4xx/5xx 응답에 `retryable` 이 들어가야 합니다.** 앱은 이 값만 보고 재시도 여부를 정하고, 값이 없으면 4xx 를 재시도하지 않습니다(DEAD). **누락이 곧 데이터 손실입니다.**

```java
public static boolean retryableFor(int status) {
    return status >= 500 || status == 408 || status == 429;
}
```

### 두 개의 핸들러 — 왜 둘인가

| 클래스 | 담당 범위 |
| --- | --- |
| `GlobalExceptionHandler` (`@RestControllerAdvice`) | **컨트롤러까지 온** 요청의 오류. `ResponseEntityExceptionHandler` 를 상속해 404/405/415/본문 파싱 실패/경로변수 형변환 실패까지 커버 |
| `ApiErrorAttributes` (`extends DefaultErrorAttributes`) | **컨트롤러 밖**(필터, 컨테이너, `/error` 로 넘어간 요청)의 오류 |

Boot 기본 본문은 `{timestamp, status, error: "Not Found", path}` 라 `retryable` 이 없고 `error` 에 코드가 아닌 사유 문구가 들어갑니다. 이 빈이 있으면 Boot 는 `DefaultErrorAttributes` 를 따로 만들지 않습니다.

### 필드명 변환

```java
private static String snake(String field) {
    return field.replaceAll("([a-z0-9])([A-Z])", "$1_$2").toLowerCase();
}
```

검증 실패 메시지에서 `deviceId` → `device_id`. 앱이 **보낸 이름 그대로** 돌려주기 위함입니다.

`detail` 은 300자로 자릅니다. 5xx 의 `detail` 은 내부 정보를 흘리지 않도록 항상 `"서버 내부 오류"` 로 고정합니다.

### `ApiException` — 우리가 직접 내는 오류

| 상황 | status | error | retryable |
| --- | --- | --- | --- |
| 없는 세션 | 404 | `SESSION_NOT_FOUND` | false |
| 배치 직렬화 실패 | 400 | `INVALID_REQUEST` | false |
| 검증 실패 | 400 | `INVALID_REQUEST` | false |
| 미처리 예외 | 500 | `INTERNAL_ERROR` | **true** (DB 연결 끊김 같은 일시 장애일 수 있음) |

---

## 10. 설정 레퍼런스

### `tracker.*` (`TrackerProperties`)

| 키 | 기본값 | 의미 |
| --- | --- | --- |
| `accuracy-limit-m` | 20 | 이 값 초과(또는 null)인 좌표 폐기 🔒 |
| `segment-gap-ms` | 300000 | 이 시간 이상 끊기면 새 구간 🔒 |
| `window-size` | 200 | 묶음 크기 🔒 |
| `stride` | 100 | 묶음 간격 🔒 |
| `overlap-strategy` | `AVERAGE_PROBS` | 겹침 규칙 |
| `bike-label` | `bike` | 적재 대상 라벨 🔒 |

🔒 = **`inference_artifacts.pkl` 의 전처리 값과 반드시 같아야 함.** 기동 시 `/v1/model` 로 대조합니다.

### `tracker.inference.*`

| 키 | 기본값 | 의미 |
| --- | --- | --- |
| `base-url` | `${INFERENCE_URL:http://inference:8000}` | 추론 서버 주소 |
| `max-retries` | 3 | 재시도 횟수 |
| `retry-backoff` | 1s | 백오프 단위 (attempt 배수) |
| `batch-threshold` | 2 | 이만큼 이상 밀렸으면 `/v1/predict/batch` |
| `max-batch-chunk` | 120 | 한 요청 묶음 수 상한 |
| `verify-on-startup` | true | **운영에서 끄지 말 것** (false 는 DB만 쓰는 테스트용) |
| `startup-timeout` | 90s | `/v1/model` 대기 한도 |

### `tracker.session.*` / `tracker.worker.*`

| 키 | 기본값 | 의미 |
| --- | --- | --- |
| `session.abandon-after` | 15m | 이후 `ABANDONED`. 늦은 배치를 거부하진 않음 |
| `session.seq-gap-alert-after` | 5m | 이만큼 막혀 있으면 ERROR 로그 |
| `worker.fixed-delay` | PT3S | 세그먼트 처리 주기 (ISO-8601 — `@Scheduled` 용) |
| `worker.abandon-scan-delay` | PT5M | ABANDONED 검사 주기 |
| `worker.seq-gap-scan-delay` | PT5M | seq 빈자리 검사 주기 |
| `worker.batch-size` | 20 | 한 주기에 처리할 구간 수 |

### `spring.*` 주요 설정

| 키 | 값 | 이유 |
| --- | --- | --- |
| `jackson.property-naming-strategy` | `SNAKE_CASE` | 앱·추론 서버 모두 snake_case. Java DTO 는 camelCase 로 두고 **여기서 한 번에** 변환 |
| `jackson.deserialization.fail-on-unknown-properties` | false | 앱이 `user_id`, `sent_at` 등 서버가 안 쓰는 필드를 보냄 |
| `http.clients.imperative.factory` | `jdk` | HTTP/1.1 고정은 `HttpClientConfig` |
| `http.clients.connect-timeout` / `read-timeout` | 2s / 30s | 추론 호출 타임아웃 |
| `server.compression.enabled` | true | `/predictions` 가 페이지 없이 전부 줌 (2KB 미만은 압축 안 함) |
| `datasource.hikari.maximum-pool-size` | 10 | |

### 프로필

| 프로필 | DB | 추론 서버 |
| --- | --- | --- |
| (기본) | `postgis:5432` (compose 네트워크) | `http://inference:8000` |
| `local` | `localhost:5433` | `http://localhost:8000` |

`build.gradle.kts` 의 `bootRun` 태스크가 `SPRING_PROFILES_ACTIVE` 가 없으면 `local` 을 켭니다.

> ⚠️ IntelliJ 의 **"Spring Boot" 실행 구성**(Gradle 이 아닌 것)에는 적용되지 않습니다. 거기서는 Active profiles 에 `local` 을 직접 넣으세요.
> ⚠️ 호스트 포트가 **5433** 인 이유는 5432 를 로컬 PostgreSQL 이 쓰기 때문입니다.

---

## 11. 동시성·정합성 설계 포인트

이 서버에서 제일 신경 쓴 부분입니다. 한곳에 모았습니다.

### ① 세션 행 `FOR UPDATE` — 동시 배치 3건

앱이 동시에 3건을 보내므로 `next_seq` 를 읽고 쓰는 구간을 직렬화해야 합니다. 안 하면 `next_seq` 가 되돌아가고 그 번호 배치는 이미 `consumed` 라 **세션이 영구 정지**합니다.

### ② 잠금 순서 고정: 세션 → 구간

- 수신: `findOrCreateForUpdate`(session) → `findLastForUpdate`(segment)
- 정리: `abandonIfStale`(session UPDATE) → `closeOpen`(segment UPDATE)

같은 순서라 교착이 없습니다.

### ③ 낙관적 잠금으로 마무리 보호

`markFinalized` 가 `point_count` 를 조건에 넣어, 처리 중 좌표가 붙었으면 0행 → `SegmentChangedException` → 롤백 → 다음 주기 재처리. **오류가 아니라 정상적인 경합**이라 INFO 로 로그합니다.

### ④ `is_last_batch` 는 반영 시점에 처리

받은 시점에 닫으면 동시 전송으로 먼저 도착한 마지막 배치가 앞 번호 배치보다 먼저 세션을 닫습니다.

### ⑤ 멱등성

| 연산 | 방법 |
| --- | --- |
| 배치 수신 | `ON CONFLICT (session_id, seq) DO NOTHING` |
| 좌표 삽입 | `ON CONFLICT (segment_id, idx) DO NOTHING` |
| 묶음 결과 | `ON CONFLICT (segment_id, start_idx) DO NOTHING` |
| bike 적재 | `ON CONFLICT (session_id, ts) DO NOTHING` |

재처리·재시도·서버 재기동 어디서 끊겨도 중복이 안 생깁니다.

### ⑥ 조회는 `REPEATABLE_READ`

쿼리 4개가 같은 스냅숏을 봐야 진행 숫자와 좌표 목록이 일치합니다.

### ⑦ 트랜잭션 길이 관리

`batchChunkSize` 로 묶음을 끊어 보내 트랜잭션이 짧게 끝나고, 진행분이 주기마다 커밋됩니다.

### ⑧ DB 쓰기 최소화

`append` 는 좌표를 메모리 `SegmentRow.withAppended` 로 누적하고 `UPDATE segment` 는 배치 끝에 한 번. `savePredictions` / `insertBikePoints` 는 `JdbcTemplate.batchUpdate`.

---

## 12. 테스트 지도

| 테스트 | 종류 | DB/추론 필요 | 지키는 것 |
| --- | --- | --- | --- |
| `WindowSpecTest` | 단위 | ❌ | 계획서 7절 450점 예시 (묶음 3개, 끝 50점, 커버리지) |
| `VerdictResolverTest` | 단위 | ❌ | 세 전략의 실제 계산값 |
| `SeqGapMonitorTest` | 단위 | ❌ | 멈춤당 ERROR 1회 / 해소 INFO 1회 / 자리 이동 시 새 ERROR |
| `InferenceModelGuardTest` | 단위 | ❌ | 불일치 시 기동 거부 + 로그에 양쪽 값, chunk = min(server, config) |
| `ApiErrorAttributesTest` | 단위 | ❌ | 4xx/5xx 별 `retryable`, `timestamp` 미노출 |
| `ProfileConfigTest` | 설정 | ❌ | 기본/`local` 프로필이 보는 주소 |
| `IngestContractTest` | `@WebMvcTest` | ❌ | **앱이 실제로 보낸 JSON** 이 필드 손실 없이 DTO 로 들어오는지, 오류에 `retryable` 이 붙는지 |
| `IngestServiceDbTest` | `@SpringBootTest` | PostGIS | 수신 경로 전체 (동시성 포함) |
| `SegmentProcessorDbTest` | `@SpringBootTest` | PostGIS | 좌표별 판정 저장(D1), 배치 분할(D4-2) |
| `PredictionQueryDbTest` | `@SpringBootTest` | PostGIS | 진행 숫자 3개가 구간 상태대로 갈리는지 |
| `InferenceGoldenE2eTest` | E2E | PostGIS + 추론 | 수신→분할→추론→겹침→저장 전 구간, 기동 대조 켠 채 |

### 실행

```bash
./gradlew test          # 단위 테스트는 항상 실행
```

**DB 테스트**는 `biketracker_test` DB 가 있어야 하고, 없으면 `@EnabledIf("dbAvailable")` 로 **조용히 건너뜁니다**.

```bash
docker exec server-spring-postgis-1 psql -U biketracker -d postgres -c "CREATE DATABASE biketracker_test"
```

**E2E 테스트**는 환경변수가 있을 때만 돕니다:

```bash
E2E_INFERENCE_URL=http://localhost:18000 ./gradlew test --tests '*InferenceGoldenE2eTest'
```

골든셋 창 11개 중 `10656_0` 과 `10656_100` 은 100점 겹치는 창이라, 합쳐 300점 구간 하나로 보내면 **겹침 규칙이 실제로 적용**됩니다. 끝나도 데이터를 지우지 않습니다(혼동행렬 쿼리를 직접 보려고).

DB 테스트는 공통적으로 `@MockitoBean SegmentWorker worker` 로 **스케줄 작업이 테스트 도중 끼어들지 않게** 막습니다.

---

## 13. 실행 방법

### 전부 도커로

```bash
cd D:\bike-tracker
docker compose up --build       # postgis + inference + spring
```

- `postgis` 는 `restart: unless-stopped` (Docker Desktop 재시작에도 살아남음)
- `inference` 는 **포트를 밖으로 열지 않음** — Spring 만 `http://inference:8000` 으로 부릅니다
- `spring` 은 두 서비스가 `healthy` 가 된 뒤에 뜹니다
- 볼륨 `pgdata` 는 `external: true, name: server-spring_pgdata` 로 고정 → 어느 프로젝트 이름으로 띄워도 같은 볼륨. **compose 가 만들지도, `down -v` 로 지우지도 않습니다**

### IntelliJ 에서 Spring 만 호스트로

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d   # 추론 서버 포트 8000 개방
./gradlew bootRun                                                      # local 프로필 자동
```

> ⚠️ `docker-compose.dev.yml` 을 `docker-compose.override.yml` 로 **이름을 바꾸지 마세요.** 도커가 자동으로 읽어 운영에서도 포트가 열립니다.

### 엔드포인트

| 메서드 | 경로 | 응답 |
| --- | --- | --- |
| POST | `/api/v1/sessions/{sessionId}/batches` | 202 `BatchResponse` |
| POST | `/api/v1/sessions/{sessionId}/close` | 202 `BatchResponse` |
| GET | `/api/v1/sessions/{sessionId}/predictions` | 200 `PredictionsResponse` (gzip) |
| GET | `/actuator/health`, `/actuator/prometheus` | Actuator + Micrometer |

---

## 14. 알려진 미결 지점과 주의사항

### 계획서상 미결

| 항목 | 현재 상태 |
| --- | --- |
| **겹침 규칙 확정** | 기본 `AVERAGE_PROBS`. 세 전략 모두 테스트 있음. 실주행 데이터(M6)로 결정 필요 |
| **ABANDONED 승계** | `session.previous_session_id` 컬럼만 있고 **채우는 로직 없음**. 새 `session_id` 는 완전히 새 구간으로 시작. 이어 붙이려면 `IngestService.append` 에서 직전 세션의 꼬리 좌표를 끌어오면 됨 |
| **`spring-boot-properties-migrator`** | `runtimeOnly` 로 들어가 있음. 기동 로그 확인 후 **제거해야 함**(운영 성능 부담) |

### Spring Boot 4 관련 (마이그레이션 시 주의)

- **Jackson 3**: 패키지가 `tools.jackson.*`, 주입받는 빈은 `ObjectMapper` 가 아니라 **`JsonMapper`**, 예외가 **unchecked** 로 바뀜
  - 단, `BatchRequest` 의 `@JsonIgnore` 는 아직 `com.fasterxml.jackson.annotation` 에서 가져옵니다(애너테이션 패키지는 유지)
- `spring-boot-starter-web` → **`spring-boot-starter-webmvc`** 로 개명
- `RestClient` 는 별도 모듈 → **`spring-boot-starter-restclient`** 필요. `RestTemplateBuilder` 는 deprecated 이므로 자동 설정된 `RestClient.Builder` 사용
- Flyway 도 별도 → **`spring-boot-starter-flyway`**
- `@WebMvcTest` / `MockMvc` 자동 설정도 별도 → **`spring-boot-starter-webmvc-test`**
- `spring.http.client.*`(단수) deprecated → **`spring.http.clients.*`**(복수)

### 코드를 읽을 때 걸리기 쉬운 지점

1. **`ST_MakePoint(경도, 위도)`** — `TrackRepository` 에서 `lng` 를 먼저 넣습니다
2. **라벨 대소문자** — 앱은 `BIKE`, 모델은 `bike`. `PointRepository.insert` 와 `savePredictions` 에서 **저장 시점에 소문자 정규화.** `raw_batch.payload` 는 원본 그대로
3. **`@JsonIgnore` on `isPointsPresentUnlessLast()`** — 없으면 검증 메서드가 JSON 속성으로 새어나갑니다
4. **`findPending` 은 `finalized = FALSE` 만 보고 "묶음이 찼는지"는 SQL 에서 안 봅니다** — 후보를 넓게 뽑고 `process()` 에서 거릅니다. 처리할 게 없는 구간도 매 주기 `findById` 로 한 번 읽습니다
5. **`unpredictable_points` 는 영구적이지 않습니다** — 300초 안에 늦은 좌표가 와서 `reopen` 되면 `discarded` 가 풀려 다시 대기 중으로 돌아갑니다
6. **`SeqGapMonitor` 의 기록은 메모리** — 서버 재기동 시 이미 알린 자리를 한 번 더 알립니다
7. **`TrackRepository.deleteBySegmentRange` 는 `ts` 로 지웁니다** — `track_point` 에 `segment_id` 가 없기 때문에 서브쿼리로 `gps_point` 의 `ts` 를 끌어옵니다

### 살펴볼 만한 개선 여지

- `SegmentRepository.findPending` 이 `ORDER BY id LIMIT 20` 이라, 앞쪽에 계속 실패하는 구간이 쌓이면 뒤쪽 구간이 밀릴 수 있습니다 (실패해도 `finalized` 가 안 되므로 계속 후보에 남습니다)
- 워커는 단일 스레드입니다. 세션이 많아지면 `@Scheduled` 대신 큐 + 병렬 처리가 필요할 수 있습니다
- `gps_point` 에 `(segment_id, idx)` PK 외 인덱스가 없어, `PredictionRepository.findPoints` 의 `ORDER BY s.idx, p.idx` 는 세션 단위 정렬을 매번 수행합니다

---

## 부록: 파일별 한 줄 요약

| 파일 | 요약 |
| --- | --- |
| `BikeTrackerApplication` | `@SpringBootApplication` + `@EnableScheduling` + `@EnableConfigurationProperties` |
| `common/ApiError` | `{error, detail, retryable}` 레코드 + 상태코드→retryable/code 매핑 |
| `common/ApiException` | 우리가 직접 내는 오류 (status/error/retryable 보유) |
| `common/GlobalExceptionHandler` | 컨트롤러까지 온 오류 전부를 `ApiError` 로 |
| `common/ApiErrorAttributes` | 컨트롤러 밖 오류(`/error`)를 `ApiError` 로 |
| `config/TrackerProperties` | `tracker.*` 설정 바인딩 + `windowSpec()` 팩토리 |
| `config/HttpClientConfig` | JDK HttpClient 를 HTTP/1.1 로 고정 |
| `infer/InferenceClient` | `/v1/model`, `/v1/predict`, `/v1/predict/batch` + 재시도 |
| `infer/InferenceModelGuard` | 기동 시 모델 설정 대조, 불일치면 기동 거부. `batchChunkSize()` 제공 |
| `infer/InferenceUnavailableException` | 재시도 가능한 일시 장애 |
| `infer/ModelInfo` `PredictRequest` `PredictResponse` | 추론 서버 DTO |
| `ingest/IngestController` | `POST /batches`, `POST /close` |
| `ingest/IngestService` | 수신·중복제거·필터·구간분리·세션상태의 전부 |
| `ingest/SessionRepository` | 세션 CRUD + `FOR UPDATE` + stale/seq-gap 조회 |
| `ingest/RawBatchRepository` | 원본 배치 저장/조회/소비 표시 |
| `ingest/PointRepository` | `gps_point` INSERT (라벨 소문자 정규화) |
| `ingest/SeqGapMonitor` | 멈춘 seq 감시 + 로그 중복 억제 |
| `ingest/SessionRow` `SessionState` | 세션 레코드 / `ACTIVE·CLOSED·ABANDONED` |
| `ingest/dto/*` | `BatchRequest`(검증 포함), `BatchResponse`, `PointDto` |
| `segment/SegmentWorker` | `@Scheduled` 3종 (처리 / seq감시 / abandon) |
| `segment/SegmentProcessor` | 구간 하나 진행: 추론 → 확정 → 마무리 |
| `segment/WindowSpec` | 묶음 절단 수학 (record, 불변식 검사) |
| `segment/VerdictResolver` | 겹침 규칙 3전략 + 결정적 argmax |
| `segment/SegmentRepository` | `segment` 테이블 전체 + 판정 저장/삭제 + 좌표 조회 |
| `segment/WindowRepository` | `inference_window` 저장/조회 (probs JSONB) |
| `segment/SegmentRow` `SegmentPoint` `WindowResult` `Verdict` `OverlapStrategy` | 값 타입들 |
| `segment/SegmentChangedException` | 처리 중 구간 변경 (정상 경합) |
| `query/PredictionController` | `GET /predictions` |
| `query/PredictionService` | `REPEATABLE_READ` 로 4쿼리를 한 스냅숏에서 |
| `query/PredictionRepository` | 상태/진행/대기배치/좌표목록 조회 |
| `query/PredictionsResponse` | 응답 DTO (`Progress`, `PredictedPoint` 중첩) |
| `store/TrackRepository` | bike 좌표만 PostGIS 적재 + 범위 삭제 |
| `store/BikePoint` | 적재용 값 타입 |
