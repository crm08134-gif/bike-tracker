# bike-tracker · Spring 서버

Spring Boot 4.1.1 · Java 21 · Gradle (Kotlin DSL) · 패키지 `io.github.crm08134.biketracker`

계획서(궤적 판별 서비스 계획서)의 Spring 서버입니다. 앱이 보낸 좌표를 받아 필터·절단하고,
Python 추론 서버에 판별을 맡긴 뒤, bike 로 판정된 좌표만 PostGIS 에 적재합니다.

## 패키지

| 패키지 | 하는 일 |
| --- | --- |
| `ingest` | 배치 수신, `(session_id, seq)` 중복 제거, `raw_batch` 적재, 세션 상태, 정확도 20m 필터, 300초 공백 분리 |
| `segment` | 200점/100점 간격 절단, 추론 호출, 겹침·끝부분 규칙, 확정 |
| `infer` | Python 추론 서버 호출 (재시도 포함) |
| `store` | bike 좌표만 PostGIS 적재 |

## 흐름

앱은 배치를 던지고 **202 만** 받습니다. 추론은 `SegmentWorker` 가 3초마다 돌며 뒤에서 처리합니다.
앱 응답 지연과 추론 속도를 분리하기 위해서입니다.

배치는 `seq` 순서대로만 좌표 스트림에 반영합니다. 3번이 먼저 와도 2번이 도착할 때까지
`raw_batch` 에 눕혀만 둡니다. 순서가 어긋나면 구간 안의 좌표 순번이 틀어지고,
그러면 "어떤 200점이 한 묶음인지"가 달라집니다.

## 확정 시점

좌표 i 를 덮을 수 있는 마지막 묶음은 `i / 100` 번입니다. 그래서 묶음 k 개가 끝나면
좌표 `0 .. k*100 - 1` 은 판정이 더 바뀌지 않아 그 자리에서 확정·적재합니다.
나머지는 구간이 닫힐 때(300초 공백 또는 세션 CLOSED/ABANDONED) 마지막 묶음의 판정으로 확정합니다.

`WindowSpecTest` · `VerdictResolverTest` 가 계획서 7절의 450점 예시를 그대로 검증합니다.

```bash
./gradlew test
```

## 실행

```bash
docker compose up --build          # postgis + inference + spring
```

추론 서버(`./inference`)가 아직 없다면 `inference` 서비스와 `depends_on` 항목을 지우고
`INFERENCE_URL` 만 로컬 주소로 띄우면 Spring 쪽만 먼저 돌려볼 수 있습니다.

## API

| 엔드포인트 | 용도 |
| --- | --- |
| `POST /api/v1/sessions/{sessionId}/batches` | 30초 배치 수신 → 202 |
| `POST /api/v1/sessions/{sessionId}/close` | 주행 종료, 열린 구간 마감 |
| `GET /api/v1/sessions/{sessionId}/predictions` | 좌표별 판정 + 진행 상황 (페이지 없음, gzip) |

`predictions` 의 `progress` 는 숫자 세 개입니다. 대기 중 = `total_points - predicted_points - unpredictable_points`.
`unpredictable_points` 는 200점 묶음이 안 만들어져 버린 구간(`segment.discarded`)의 좌표로, 영영 판정되지 않습니다.
`waiting_batches` 는 받았지만 앞 번호 배치를 기다리는 배치 수라, 0 이 아니면 `total_points` 가 나중에 늘어납니다.

JSON 은 앱·추론 서버에 맞춰 **snake_case** 로 주고받습니다
(`spring.jackson.property-naming-strategy: SNAKE_CASE`).

## Spring Boot 4 관련 메모

- JSON 은 **Jackson 3** 입니다. 패키지가 `tools.jackson.*` 이고, 주입받는 빈은
  `ObjectMapper` 가 아니라 `JsonMapper` 입니다. 예외도 unchecked 로 바뀌었습니다.
- 웹 클라이언트가 별도 모듈이라 `spring-boot-starter-restclient` 가 필요합니다.
  `RestTemplateBuilder` 는 deprecated 라 자동 설정된 `RestClient.Builder` 를 받아 씁니다.
- Flyway 도 별도 starter (`spring-boot-starter-flyway`) 입니다.
- `spring-boot-properties-migrator` 를 넣어뒀습니다. 기동 로그에 이름이 바뀐 설정 값이
  뜨는지 한 번 확인하고 지우세요.

## 아직 정해야 할 것

- **겹침 규칙**: 지금 기본값은 `AVERAGE_PROBS`(계획서 제안). `tracker.overlap-strategy` 로
  `STRICT_BIKE` · `LATEST_WINDOW` 로 바꿀 수 있고, 셋 다 테스트가 붙어 있습니다.
- **ABANDONED 승계**: 지금은 새 `session_id` 가 완전히 새 구간으로 시작합니다.
  이어 붙이려면 `IngestService.append` 에서 직전 세션의 꼬리 좌표를 끌어오면 됩니다.
- **기동 시 pkl 대조**: `GET /v1/model` 로 받은 `window_size` · `stride` · `accuracy_limit` 이
  `application.yml` 과 다르면 기동을 거부하는 검사가 아직 없습니다. 추론 서버가 생긴 뒤 붙입니다.
