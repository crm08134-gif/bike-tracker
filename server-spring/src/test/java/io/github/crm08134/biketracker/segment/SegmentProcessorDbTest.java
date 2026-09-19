package io.github.crm08134.biketracker.segment;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

import io.github.crm08134.biketracker.infer.InferenceClient;
import io.github.crm08134.biketracker.infer.PredictRequest;
import io.github.crm08134.biketracker.infer.PredictResponse;
import io.github.crm08134.biketracker.ingest.IngestService;
import io.github.crm08134.biketracker.ingest.dto.BatchRequest;
import io.github.crm08134.biketracker.ingest.dto.PointDto;

/**
 * D1(좌표별 판정 저장)과 D4-2(배치 분할)를 실제 DB 에서 봅니다. 추론 서버는 가짜로 둡니다:
 * 묶음 시작 idx 가 200 이상이면 walk, 아니면 bike 로 답합니다.
 */
@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:postgresql://localhost:5433/biketracker_test",
        "tracker.inference.verify-on-startup=false",
        "tracker.inference.max-batch-chunk=2",
})
@EnabledIf("dbAvailable")
class SegmentProcessorDbTest {

    private static final String URL = "jdbc:postgresql://localhost:5433/biketracker_test";
    private static final long T0 = 1_757_750_400_000L;

    static boolean dbAvailable() {
        try (var c = DriverManager.getConnection(URL, "biketracker", "biketracker")) {
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    @MockitoBean SegmentWorker worker;
    @MockitoBean InferenceClient inference;

    @Autowired IngestService ingest;
    @Autowired SegmentProcessor processor;
    @Autowired JdbcTemplate jdbc;

    private final UUID sid = UUID.randomUUID();

    @BeforeEach
    void clean() {
        jdbc.execute("TRUNCATE track_point, inference_window, gps_point, segment, raw_batch, session CASCADE");
        when(inference.predictBatch(anyList())).thenAnswer(inv -> {
            List<PredictRequest> reqs = inv.getArgument(0);
            List<PredictResponse> out = new ArrayList<>();
            for (PredictRequest r : reqs) {
                int startIdx = (int) ((r.windowStartTs() - T0) / 1000);
                boolean bike = startIdx < 200;
                out.add(new PredictResponse("fake-v1", bike ? "bike" : "walk",
                        bike ? Map.of("bike", 0.8, "walk", 0.2) : Map.of("bike", 0.3, "walk", 0.7), 1));
            }
            return out;
        });
    }

    private void sendOneSession(int n, boolean last) {
        List<PointDto> pts = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            pts.add(new PointDto(T0 + i * 1000L, 37.5 + i * 1e-5, 127.0, 5f, null, null, i < 250 ? "BIKE" : "WALK"));
        }
        ingest.accept(sid, new BatchRequest("dev", 0, last, pts));
    }

    private long segmentId() {
        return jdbc.queryForObject("SELECT id FROM segment WHERE session_id = ?", Long.class, sid);
    }

    private Map<String, Object> segment() {
        return jdbc.queryForMap("SELECT windows_done, flushed_through, finalized FROM segment WHERE id = ?", segmentId());
    }

    @Test
    @DisplayName("D1+D4-2: 묶음을 2개씩 끊어 보내고, 마무리되면 모든 좌표에 판정이 남는다 (bike 아닌 판정 포함)")
    void allPointsGetPredictionsAcrossChunks() {
        // 500점 -> 묶음 4개 (0,100,200,300). 끝부분 [500) 까지 마지막 묶음 판정.
        sendOneSession(500, true);
        long seg = segmentId();

        processor.process(seg);
        assertThat(segment()).containsEntry("windows_done", 2).containsEntry("finalized", false);
        // 묶음 2개면 [0,200) 이 확정됐다
        assertThat(segment()).containsEntry("flushed_through", 200);

        processor.process(seg);
        assertThat(segment()).containsEntry("windows_done", 4).containsEntry("finalized", true)
                .containsEntry("flushed_through", 500);
        verify(inference, times(2)).predictBatch(anyList());

        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM gps_point WHERE segment_id = ? AND predicted_label IS NULL", Integer.class, seg))
                .isZero();

        // 좌표 150: 묶음 0,1 이 덮고 둘 다 bike -> 평균 0.8
        assertPoint(seg, 150, "bike", 0.8);
        // 좌표 250: 묶음 1(bike 0.8) + 2(walk, bike 0.3) 평균 0.55 -> bike
        assertPoint(seg, 250, "bike", 0.55);
        // 좌표 350: 묶음 2,3 모두 walk -> bike 0.3
        assertPoint(seg, 350, "walk", 0.3);
        // 끝부분 좌표 499: 마지막 묶음(3) 판정
        assertPoint(seg, 499, "walk", 0.3);

        // track_point 에는 bike 만, gps_point 에는 전부
        int bikePoints = jdbc.queryForObject(
                "SELECT count(*) FROM gps_point WHERE segment_id = ? AND predicted_label = 'bike'", Integer.class, seg);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM track_point", Integer.class)).isEqualTo(bikePoints);
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM gps_point WHERE segment_id = ? AND predicted_label = 'walk'", Integer.class, seg))
                .isPositive();

        // M6 혼동행렬 쿼리가 돈다
        List<Map<String, Object>> matrix = jdbc.queryForList("""
                SELECT label, predicted_label, count(*) AS n, avg(predicted_prob_bike) AS p
                FROM gps_point
                WHERE label IS NOT NULL AND predicted_label IS NOT NULL
                GROUP BY 1, 2 ORDER BY 1, 2
                """);
        assertThat(matrix).extracting(r -> r.get("label") + "->" + r.get("predicted_label"))
                .contains("bike->bike", "walk->walk");
    }

    @Test
    @DisplayName("열린 구간은 확정된 좌표까지만 판정을 적는다")
    void openSegmentWritesSettledOnly() {
        sendOneSession(300, false);   // 묶음 2개, 열린 구간
        long seg = segmentId();
        processor.process(seg);

        assertThat(segment()).containsEntry("windows_done", 2).containsEntry("flushed_through", 200)
                .containsEntry("finalized", false);
        assertThat(jdbc.queryForObject(
                "SELECT count(*) FROM gps_point WHERE segment_id = ? AND predicted_label IS NOT NULL", Integer.class, seg))
                .isEqualTo(200);
    }

    private void assertPoint(long seg, int idx, String label, double probBike) {
        Map<String, Object> row = jdbc.queryForMap(
                "SELECT predicted_label, predicted_prob_bike, model_version FROM gps_point WHERE segment_id = ? AND idx = ?",
                seg, idx);
        assertThat(row.get("predicted_label")).as("idx %d", idx).isEqualTo(label);
        assertThat((Double) row.get("predicted_prob_bike")).as("idx %d", idx)
                .isCloseTo(probBike, org.assertj.core.data.Offset.offset(1e-9));
        assertThat(row.get("model_version")).isEqualTo("fake-v1");
    }
}
