package io.github.crm08134.biketracker.query;

import static org.hamcrest.Matchers.hasKey;
import static org.hamcrest.Matchers.nullValue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

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
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;

import io.github.crm08134.biketracker.infer.InferenceClient;
import io.github.crm08134.biketracker.infer.PredictRequest;
import io.github.crm08134.biketracker.infer.PredictResponse;
import io.github.crm08134.biketracker.ingest.IngestService;
import io.github.crm08134.biketracker.ingest.dto.BatchRequest;
import io.github.crm08134.biketracker.ingest.dto.PointDto;
import io.github.crm08134.biketracker.segment.SegmentProcessor;
import io.github.crm08134.biketracker.segment.SegmentWorker;

/**
 * GET /predictions 의 진행 숫자 세 개가 구간 상태대로 갈리는지 실제 DB 에서 봅니다.
 * 워커는 끄고 SegmentProcessor 를 직접 돌립니다. 추론 서버는 가짜로 전부 bike 라고 답합니다.
 */
@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:postgresql://localhost:5433/biketracker_test",
        "tracker.inference.verify-on-startup=false",
})
@AutoConfigureMockMvc
@EnabledIf("dbAvailable")
class PredictionQueryDbTest {

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
    @Autowired MockMvc mvc;

    private final UUID sid = UUID.randomUUID();

    @BeforeEach
    void clean() {
        jdbc.execute("TRUNCATE track_point, inference_window, gps_point, segment, raw_batch, session CASCADE");
        PredictResponse bike = new PredictResponse("fake-v1", "bike", Map.of("bike", 0.8, "walk", 0.2), 1);
        when(inference.predict(any())).thenReturn(bike);
        when(inference.predictBatch(anyList())).thenAnswer(inv -> {
            List<PredictRequest> reqs = inv.getArgument(0);
            return reqs.stream().map(r -> bike).toList();
        });
    }

    /** 1초 간격 좌표 n개. startTs 부터. */
    private static List<PointDto> points(long startTs, int n) {
        List<PointDto> pts = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            pts.add(new PointDto(startTs + i * 1000L, 37.5 + i * 1e-5, 127.0, 5f, null, null, "NONE"));
        }
        return pts;
    }

    private void processAll() {
        for (Long id : jdbc.queryForList("SELECT id FROM segment WHERE session_id = ? ORDER BY idx", Long.class, sid)) {
            processor.process(id);
        }
    }

    private ResultActions getPredictions() throws Exception {
        return mvc.perform(get("/api/v1/sessions/" + sid + "/predictions")).andExpect(status().isOk());
    }

    private void expectProgress(ResultActions r, int total, int predicted, int unpredictable) throws Exception {
        r.andExpect(jsonPath("$.progress.total_points").value(total))
                .andExpect(jsonPath("$.progress.predicted_points").value(predicted))
                .andExpect(jsonPath("$.progress.unpredictable_points").value(unpredictable));
    }

    @Test
    @DisplayName("마무리된 구간: 전부 판정됨. 응답은 snake_case, 좌표는 ts 순")
    void finalizedSegment() throws Exception {
        ingest.accept(sid, new BatchRequest("dev", 0, true, points(T0, 300)));
        processAll();

        ResultActions r = getPredictions()
                .andExpect(jsonPath("$.session_id").value(sid.toString()))
                .andExpect(jsonPath("$.session_state").value("CLOSED"))
                .andExpect(jsonPath("$.waiting_batches").value(0))
                .andExpect(jsonPath("$.points.length()").value(300))
                .andExpect(jsonPath("$.points[0].ts").value(T0))
                .andExpect(jsonPath("$.points[299].ts").value(T0 + 299_000))
                .andExpect(jsonPath("$.points[0].lat").value(37.5))
                .andExpect(jsonPath("$.points[0].lng").value(127.0))
                .andExpect(jsonPath("$.points[0].predicted_label").value("bike"))
                .andExpect(jsonPath("$.points[0].predicted_prob_bike").value(0.8))
                .andExpect(jsonPath("$.progress.totalPoints").doesNotExist());
        expectProgress(r, 300, 300, 0);
    }

    @Test
    @DisplayName("200점 미만 구간: 닫혀도 워커가 돌기 전까지는 대기 중, 버려지면 판정 불가")
    void discardedSegment() throws Exception {
        ingest.accept(sid, new BatchRequest("dev", 0, true, points(T0, 150)));

        // 닫혔지만 아직 마무리 전: 판정 불가로 세지 않는다 (워커 한 주기 동안)
        expectProgress(getPredictions(), 150, 0, 0);

        processAll();
        ResultActions r = getPredictions()
                // 판정이 없는 좌표도 키는 null 로 내려간다
                .andExpect(jsonPath("$.points[0]", hasKey("predicted_label")))
                .andExpect(jsonPath("$.points[0].predicted_label").value(nullValue()))
                .andExpect(jsonPath("$.points[0].predicted_prob_bike").value(nullValue()));
        expectProgress(r, 150, 0, 150);
    }

    @Test
    @DisplayName("열린 구간: 확정된 좌표만 판정됨, 나머지는 대기 중 (판정 불가 아님)")
    void openSegmentIsPending() throws Exception {
        ingest.accept(sid, new BatchRequest("dev", 0, false, points(T0, 300)));
        getPredictions().andExpect(jsonPath("$.session_state").value("ACTIVE"));
        expectProgress(getPredictions(), 300, 0, 0);

        processAll();
        // 묶음 2개 -> [0, 200) 확정, [200, 300) 은 다음 묶음을 기다린다
        ResultActions r = getPredictions()
                .andExpect(jsonPath("$.points[199].predicted_label").value("bike"))
                .andExpect(jsonPath("$.points[200].predicted_label").value(nullValue()));
        expectProgress(r, 300, 200, 0);
    }

    @Test
    @DisplayName("구간이 섞인 세션: 판정된 구간과 버려진 구간을 따로 센다")
    void mixedSegments() throws Exception {
        // 300점 뒤 400초 공백, 다시 150점 -> 구간 2개
        List<PointDto> pts = new ArrayList<>(points(T0, 300));
        pts.addAll(points(T0 + 299_000 + 400_000, 150));
        ingest.accept(sid, new BatchRequest("dev", 0, true, pts));
        processAll();

        ResultActions r = getPredictions()
                .andExpect(jsonPath("$.points.length()").value(450))
                .andExpect(jsonPath("$.points[299].predicted_label").value("bike"))
                .andExpect(jsonPath("$.points[300].ts").value(T0 + 699_000))
                .andExpect(jsonPath("$.points[300].predicted_label").value(nullValue()));
        expectProgress(r, 450, 300, 150);
    }

    @Test
    @DisplayName("seq 빈 자리: 받은 배치가 반영 전이면 waiting_batches 로 드러난다")
    void waitingBatches() throws Exception {
        ingest.accept(sid, new BatchRequest("dev", 1, false, points(T0 + 30_000, 30)));

        ResultActions r = getPredictions()
                .andExpect(jsonPath("$.waiting_batches").value(1))
                .andExpect(jsonPath("$.points.length()").value(0));
        expectProgress(r, 0, 0, 0);

        ingest.accept(sid, new BatchRequest("dev", 0, false, points(T0, 30)));
        expectProgress(getPredictions().andExpect(jsonPath("$.waiting_batches").value(0)), 60, 0, 0);
    }

    @Test
    @DisplayName("없는 세션은 404 SESSION_NOT_FOUND, retryable=false")
    void unknownSession() throws Exception {
        mvc.perform(get("/api/v1/sessions/" + UUID.randomUUID() + "/predictions"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("SESSION_NOT_FOUND"))
                .andExpect(jsonPath("$.retryable").value(false));
    }
}
