package io.github.crm08134.biketracker.ingest;

import static org.assertj.core.api.Assertions.assertThat;

import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

import io.github.crm08134.biketracker.ingest.dto.BatchRequest;
import io.github.crm08134.biketracker.ingest.dto.BatchResponse;
import io.github.crm08134.biketracker.ingest.dto.PointDto;
import io.github.crm08134.biketracker.segment.SegmentRepository;
import io.github.crm08134.biketracker.segment.SegmentWorker;

/**
 * 실제 PostGIS 에서 수신 경로를 검증합니다. 개발 DB 를 더럽히지 않도록 같은 컨테이너의
 * biketracker_test DB 를 씁니다. 없으면 이 클래스는 건너뜁니다.
 *
 * <pre>docker exec server-spring-postgis-1 psql -U biketracker -d postgres -c "CREATE DATABASE biketracker_test"</pre>
 */
@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:postgresql://localhost:5433/biketracker_test",
        "tracker.session.abandon-after=15m",
        // 추론 서버 없이 DB 경로만 봅니다.
        "tracker.inference.verify-on-startup=false",
})
@EnabledIf("dbAvailable")
@ExtendWith(OutputCaptureExtension.class)
class IngestServiceDbTest {

    private static final String URL = "jdbc:postgresql://localhost:5433/biketracker_test";
    private static final long T0 = 1_757_750_400_000L;

    static boolean dbAvailable() {
        try (var c = DriverManager.getConnection(URL, "biketracker", "biketracker")) {
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    // 스케줄 작업(추론 호출, ABANDONED 검사)이 테스트 도중 끼어들지 않게 막습니다.
    @MockitoBean SegmentWorker worker;

    @Autowired IngestService ingest;
    @Autowired SessionRepository sessions;
    @Autowired SegmentRepository segments;
    @Autowired JdbcTemplate jdbc;

    private final UUID sid = UUID.randomUUID();

    @BeforeEach
    void clean() {
        jdbc.execute("TRUNCATE track_point, inference_window, gps_point, segment, raw_batch, session CASCADE");
    }

    private static List<PointDto> points(long fromTs, int n, String label) {
        List<PointDto> out = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            out.add(new PointDto(fromTs + i * 1000L, 37.5 + i * 1e-5, 127.0, 5f, 1f, 30f, label));
        }
        return out;
    }

    private BatchResponse send(int seq, boolean last, List<PointDto> pts) {
        return ingest.accept(sid, new BatchRequest("dev-1", seq, last, pts));
    }

    private void forceAbandon() {
        jdbc.update("UPDATE session SET last_seen_at = now() - interval '1 hour' WHERE session_id = ?", sid);
        assertThat(ingest.abandonStale()).isEqualTo(1);
    }

    private List<Map<String, Object>> segmentRows() {
        return jdbc.queryForList("SELECT id, idx, point_count, closed, finalized, discarded, flushed_through "
                + "FROM segment WHERE session_id = ? ORDER BY idx", sid);
    }

    @Autowired org.springframework.http.client.ClientHttpRequestFactory httpFactory;

    @Test
    @DisplayName("추론 호출 HTTP 클라이언트: HTTP/1.1 고정, application.yml 타임아웃 적용")
    void httpClientSettings() throws Exception {
        assertThat(httpFactory).isInstanceOf(org.springframework.http.client.JdkClientHttpRequestFactory.class);
        var clientField = org.springframework.http.client.JdkClientHttpRequestFactory.class.getDeclaredField("httpClient");
        var readField = org.springframework.http.client.JdkClientHttpRequestFactory.class.getDeclaredField("readTimeout");
        clientField.setAccessible(true);
        readField.setAccessible(true);
        java.net.http.HttpClient client = (java.net.http.HttpClient) clientField.get(httpFactory);

        assertThat(client.version()).isEqualTo(java.net.http.HttpClient.Version.HTTP_1_1);
        assertThat(client.connectTimeout()).contains(java.time.Duration.ofSeconds(2));
        assertThat(readField.get(httpFactory)).isEqualTo(java.time.Duration.ofSeconds(30));
    }

    @Test
    @DisplayName("S5/D1: 라벨이 gps_point 에 소문자로 저장되고, raw_batch 는 받은 원본(snake_case)대로 적힌다")
    void labelStored() {
        List<PointDto> pts = new ArrayList<>(points(T0, 3, "BIKE"));
        pts.addAll(points(T0 + 3000, 2, "WALK"));
        send(0, false, pts);

        assertThat(jdbc.queryForList("SELECT label FROM gps_point ORDER BY idx", String.class))
                .containsExactly("bike", "bike", "bike", "walk", "walk");
        assertThat(jdbc.queryForObject("SELECT lat FROM gps_point WHERE idx = 1", Double.class))
                .isEqualTo(37.5 + 1e-5);

        String payload = jdbc.queryForObject("SELECT payload::text FROM raw_batch WHERE session_id = ?", String.class, sid);
        assertThat(payload).contains("\"device_id\"", "\"is_last_batch\"", "\"label\"", "\"BIKE\"")
                .doesNotContain("deviceId", "points_present_unless_last", "pointsPresentUnlessLast");
    }

    @Test
    @DisplayName("S3: 마지막 배치가 먼저 도착해도 순서대로 반영될 때 CLOSED 가 된다")
    void lastBatchClosesInOrder() {
        BatchResponse r1 = send(1, true, points(T0 + 30_000, 10, "BIKE"));
        assertThat(r1.sessionState()).isEqualTo(SessionState.ACTIVE);
        assertThat(r1.nextSeq()).isZero();

        BatchResponse r0 = send(0, false, points(T0, 30, "BIKE"));
        assertThat(r0.sessionState()).isEqualTo(SessionState.CLOSED);
        assertThat(r0.nextSeq()).isEqualTo(2);

        assertThat(segmentRows()).singleElement().satisfies(s -> {
            assertThat(s.get("point_count")).isEqualTo(40);
            assertThat(s.get("closed")).isEqualTo(true);
        });
    }

    @Test
    @DisplayName("S3: 좌표 없는 세션의 종료 신호(points: [], is_last_batch: true)")
    void emptyLastBatch() {
        BatchResponse r = send(0, true, List.of());
        assertThat(r.sessionState()).isEqualTo(SessionState.CLOSED);
        assertThat(r.nextSeq()).isEqualTo(1);
    }

    @Test
    @DisplayName("S2: ABANDONED 세션에 300초 안쪽 늦은 배치 -> 202 ABANDONED, 같은 구간에 이어 붙고 다시 닫힘")
    void lateBatchWithinGapExtendsSameSegment() {
        send(0, false, points(T0, 30, "BIKE"));
        forceAbandon();
        long segId = (Long) segmentRows().get(0).get("id");

        // 마지막 좌표(T0+29s) 뒤 60초 공백. 300초 안쪽이다.
        BatchResponse r = send(1, false, points(T0 + 90_000, 30, "BIKE"));

        assertThat(r.sessionState()).isEqualTo(SessionState.ABANDONED);
        assertThat(r.nextSeq()).isEqualTo(2);
        assertThat(segmentRows()).singleElement().satisfies(s -> {
            assertThat(s.get("id")).isEqualTo(segId);
            assertThat(s.get("point_count")).isEqualTo(60);
            assertThat(s.get("closed")).isEqualTo(true);   // 기다리지 않으므로 다시 닫힘
            assertThat(s.get("finalized")).isEqualTo(false);
        });
        assertThat(sessions.requireForUpdate(sid).state()).isEqualTo(SessionState.ABANDONED);
    }

    @Test
    @DisplayName("S2: 300초 넘게 벌어진 늦은 배치는 새 구간")
    void lateBatchBeyondGapOpensNewSegment() {
        send(0, false, points(T0, 30, "BIKE"));
        forceAbandon();

        send(1, false, points(T0 + 29_000 + 301_000, 30, "BIKE"));

        List<Map<String, Object>> rows = segmentRows();
        assertThat(rows).hasSize(2);
        assertThat(rows.get(0).get("point_count")).isEqualTo(30);
        assertThat(rows.get(1).get("point_count")).isEqualTo(30);
        assertThat(rows).allSatisfy(s -> assertThat(s.get("closed")).isEqualTo(true));
    }

    @Test
    @DisplayName("S2: 이미 마무리된 구간을 다시 열면 끝부분 확정분(track_point)을 무르고 flushed_through 를 되돌린다")
    void reopenRevokesTail() {
        send(0, false, points(T0, 250, "BIKE"));
        forceAbandon();
        long segId = (Long) segmentRows().get(0).get("id");

        // 워커가 묶음 1개로 마무리한 상태를 흉내: [0,100) 은 확정, [100,250) 은 끝부분 규칙으로 확정.
        jdbc.update("""
                INSERT INTO inference_window (segment_id, start_idx, label, probs, model_version)
                VALUES (?, 0, 'bike', '{"bike": 1.0}'::jsonb, 'test')
                """, segId);
        jdbc.update("UPDATE segment SET windows_done = 1, flushed_through = 250, finalized = TRUE WHERE id = ?", segId);
        jdbc.update("""
                INSERT INTO track_point (session_id, ts, geom, model_version)
                SELECT ?, ts, ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography, 'test'
                FROM gps_point WHERE segment_id = ?
                """, sid, segId);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM track_point", Integer.class)).isEqualTo(250);
        jdbc.update("UPDATE gps_point SET predicted_label = 'bike', predicted_prob_bike = 0.9, model_version = 'test' "
                + "WHERE segment_id = ?", segId);

        send(1, false, points(T0 + 260_000, 10, "BIKE"));

        assertThat(segmentRows()).singleElement().satisfies(s -> {
            assertThat(s.get("id")).isEqualTo(segId);
            assertThat(s.get("point_count")).isEqualTo(260);
            assertThat(s.get("flushed_through")).isEqualTo(100);
            assertThat(s.get("finalized")).isEqualTo(false);
            assertThat(s.get("closed")).isEqualTo(true);
        });
        assertThat(jdbc.queryForObject("SELECT count(*) FROM track_point", Integer.class)).isEqualTo(100);
        assertThat(jdbc.queryForObject("SELECT max(ts) FROM track_point", Long.class)).isEqualTo(T0 + 99_000);
        // 무른 끝부분의 판정도 지워지고, 확정분 [0,100) 은 남는다
        assertThat(jdbc.queryForObject("SELECT count(*) FROM gps_point WHERE predicted_label IS NOT NULL", Integer.class))
                .isEqualTo(100);
        assertThat(jdbc.queryForObject("SELECT max(idx) FROM gps_point WHERE predicted_label IS NOT NULL", Integer.class))
                .isEqualTo(99);
    }

    @Test
    @DisplayName("S2: 200점 미만이라 버린 구간도 다시 열리면 discarded 가 풀린다")
    void reopenDiscarded() {
        send(0, false, points(T0, 150, "BIKE"));
        forceAbandon();
        jdbc.update("UPDATE segment SET finalized = TRUE, discarded = TRUE WHERE session_id = ?", sid);

        send(1, false, points(T0 + 160_000, 100, "BIKE"));

        assertThat(segmentRows()).singleElement().satisfies(s -> {
            assertThat(s.get("point_count")).isEqualTo(250);
            assertThat(s.get("discarded")).isEqualTo(false);
            assertThat(s.get("finalized")).isEqualTo(false);
        });
    }

    @Test
    @DisplayName("마무리 가드: 읽은 뒤 좌표가 늘었으면 finalized 로 바꾸지 않는다")
    void finalizeGuard() {
        send(0, false, points(T0, 30, "BIKE"));
        long segId = (Long) segmentRows().get(0).get("id");

        assertThat(segments.markFinalized(segId, true, 29)).isFalse();
        assertThat(segments.markFinalized(segId, true, 30)).isTrue();
        assertThat(segments.markFinalized(segId, true, 30)).isFalse();
    }

    @Test
    @DisplayName("S6: 버린 점을 사유별로 센다. 동작(버리기)은 그대로")
    void dropCounts(CapturedOutput out) {
        List<PointDto> pts = new ArrayList<>();
        pts.add(new PointDto(T0, 37.5, 127.0, 5f, null, null, "BIKE"));          // 저장
        pts.add(new PointDto(T0 + 1000, 37.5, 127.0, null, null, null, "BIKE")); // acc 없음
        pts.add(new PointDto(T0 + 2000, 37.5, 127.0, 25f, null, null, "BIKE"));  // 20m 초과
        pts.add(new PointDto(T0 + 2000, 37.5, 127.0, 20f, null, null, "BIKE"));  // 20m 딱 -> 저장
        pts.add(new PointDto(T0 + 2000, 37.5, 127.0, 5f, null, null, "BIKE"));   // ts 같음
        pts.add(new PointDto(T0 + 1500, 37.5, 127.0, 5f, null, null, "BIKE"));   // ts 역행
        send(0, false, pts);

        assertThat(jdbc.queryForObject("SELECT count(*) FROM gps_point", Integer.class)).isEqualTo(2);
        assertThat(out.getOut()).contains(
                "seq=0 received=6 stored=2 dropped: no_acc=1 acc_over_limit=1 ts_non_increasing=2");
    }

    @Test
    @DisplayName("S4: next_seq 가 빠진 채 뒤 배치가 오래 기다리면 잡아낸다")
    void seqGapDetected() {
        send(0, false, points(T0, 30, "BIKE"));
        send(2, false, points(T0 + 60_000, 30, "BIKE"));
        send(3, false, points(T0 + 90_000, 30, "BIKE"));

        assertThat(sessions.findSeqGaps(java.time.Duration.ofMinutes(5))).isEmpty();

        jdbc.update("UPDATE raw_batch SET received_at = now() - interval '6 minutes' WHERE session_id = ? AND seq = 2", sid);
        assertThat(sessions.findSeqGaps(java.time.Duration.ofMinutes(5))).singleElement().satisfies(g -> {
            assertThat(g.sessionId()).isEqualTo(sid);
            assertThat(g.missingSeq()).isEqualTo(1);
            assertThat(g.waiting()).isEqualTo(2);
            assertThat(g.firstWaitingSeq()).isEqualTo(2);
        });

        // 빠진 배치가 오면 풀린다
        assertThat(send(1, false, points(T0 + 30_000, 30, "BIKE")).nextSeq()).isEqualTo(4);
        assertThat(sessions.findSeqGaps(java.time.Duration.ofMinutes(5))).isEmpty();
        assertThat(segmentRows()).singleElement().satisfies(s -> assertThat(s.get("point_count")).isEqualTo(120));
    }

    @Test
    /**
     * 동시 전송 smoke 테스트. 세션 행 잠금이 없어도 이 테스트는 통과했습니다(경합이 재현되지 않음).
     * 긴 트랜잭션이 커밋 직전에 먼저 커밋된 뒤 번호 배치까지 반영해 스스로 풀리기 때문입니다.
     * 잠금이 막는 경합(짧은 트랜잭션이 긴 트랜잭션의 커밋 순간을 걸치는 경우)은 여기서 증명하지 못합니다.
     */
    @DisplayName("동시 전송 3건이 서로 좌표를 잃거나 겹치지 않는다")
    void concurrentBatchesDoNotRegressNextSeq() throws Exception {
        int rounds = 10;
        int perBatch = 150;
        ExecutorService pool = Executors.newFixedThreadPool(3);
        try {
            for (int round = 0; round < rounds; round++) {
                int base = round * 3;
                List<Callable<BatchResponse>> jobs = new ArrayList<>();
                for (int k = 0; k < 3; k++) {
                    int seq = base + k;
                    jobs.add(() -> send(seq, false, points(T0 + seq * 150_000L, perBatch, "BIKE")));
                }
                for (Future<BatchResponse> f : pool.invokeAll(jobs)) {
                    f.get();
                }
            }
        } finally {
            pool.shutdown();
        }
        assertThat(sessions.requireForUpdate(sid).nextSeq()).isEqualTo(rounds * 3);
        assertThat(segmentRows()).singleElement()
                .satisfies(s -> assertThat(s.get("point_count")).isEqualTo(rounds * 3 * perBatch));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM raw_batch WHERE consumed = FALSE", Integer.class)).isZero();
    }
}
