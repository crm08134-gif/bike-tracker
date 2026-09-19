package io.github.crm08134.biketracker.segment;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;

import org.assertj.core.data.Offset;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

import io.github.crm08134.biketracker.ingest.IngestService;
import io.github.crm08134.biketracker.ingest.dto.BatchRequest;
import io.github.crm08134.biketracker.ingest.dto.PointDto;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * 실제 추론 서버와 골든셋으로 수신 -> 분할 -> 추론 -> 겹침 규칙 -> 좌표별 판정 저장까지 한 번에 봅니다.
 * 기동 대조(verify-on-startup)도 켠 채로 뜹니다.
 *
 * <p>E2E_INFERENCE_URL 이 있을 때만 돕니다. 끝나도 데이터를 지우지 않습니다(혼동행렬 쿼리를 직접 보려고).
 * <pre>E2E_INFERENCE_URL=http://localhost:18000 ./gradlew test --tests '*InferenceGoldenE2eTest'</pre>
 *
 * <p>골든셋 창 11개 중 10656_0 과 10656_100 은 같은 주행에서 100점 겹치는 창이라, 합쳐 300점 구간 하나로
 * 보내면 겹침 규칙(AVERAGE_PROBS)이 실제로 적용됩니다. 나머지는 200점 구간(묶음 1개)입니다.
 * 정답 라벨은 true_mode 를 대문자로 보내 소문자 정규화도 같이 봅니다.
 */
@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:postgresql://localhost:5433/biketracker_test",
        "tracker.inference.verify-on-startup=true",
})
@EnabledIfEnvironmentVariable(named = "E2E_INFERENCE_URL", matches = "https?://.+")
class InferenceGoldenE2eTest {

    private static final Path GOLDEN = Path.of("..", "inference-fastapi", "golden", "golden_requests.json");

    @DynamicPropertySource
    static void inferenceUrl(DynamicPropertyRegistry r) {
        r.add("tracker.inference.base-url", () -> System.getenv("E2E_INFERENCE_URL"));
        // 기본 1: 묶음 1개씩 끊어 /v1/predict 와 분할 경로를 탑니다. 2 이상이면 300점 구간이 /v1/predict/batch 로 갑니다.
        r.add("tracker.inference.max-batch-chunk", InferenceGoldenE2eTest::chunk);
    }

    private static int chunk() {
        String v = System.getenv("E2E_MAX_BATCH_CHUNK");
        return v == null ? 1 : Integer.parseInt(v);
    }

    @MockitoBean SegmentWorker worker;

    @Autowired IngestService ingest;
    @Autowired SegmentProcessor processor;
    @Autowired SegmentRepository segments;
    @Autowired JdbcTemplate jdbc;
    @Autowired JsonMapper json;

    record Golden(String id, String mode, List<JsonNode> points, Map<String, Double> expected) {}

    @Test
    @DisplayName("골든셋 주행을 끝까지 흘리면 모든 좌표에 판정이 남고, 확률이 골든 기대값과 같다")
    void goldenThroughPipeline() throws Exception {
        jdbc.execute("TRUNCATE track_point, inference_window, gps_point, segment, raw_batch, session CASCADE");

        List<Golden> golden = new ArrayList<>();
        for (JsonNode g : json.readTree(Files.readString(GOLDEN))) {
            Map<String, Double> probs = new TreeMap<>();
            g.get("expected").get("probs").properties().forEach(e -> probs.put(e.getKey(), e.getValue().asDouble()));
            List<JsonNode> pts = new ArrayList<>();
            g.get("request").get("points").forEach(pts::add);
            golden.add(new Golden(g.get("golden_id").asString(), g.get("true_mode").asString(), pts, probs));
        }
        assertThat(golden).hasSize(11);

        // 주행 번호(golden_id 의 _ 앞)로 묶고 ts 로 합칩니다.
        Map<String, List<Golden>> trips = new LinkedHashMap<>();
        for (Golden g : golden) {
            trips.computeIfAbsent(g.id().substring(0, g.id().indexOf('_')), k -> new ArrayList<>()).add(g);
        }

        Map<String, UUID> sessionOf = new LinkedHashMap<>();
        for (Map.Entry<String, List<Golden>> trip : trips.entrySet()) {
            TreeMap<Long, JsonNode> byTs = new TreeMap<>();
            String mode = trip.getValue().get(0).mode();
            trip.getValue().forEach(g -> g.points().forEach(p -> byTs.putIfAbsent(p.get("ts").asLong(), p)));
            List<PointDto> pts = byTs.values().stream()
                    .map(p -> new PointDto(p.get("ts").asLong(), p.get("lat").asDouble(), p.get("lng").asDouble(),
                            5f, null, null, mode.toUpperCase()))
                    .toList();
            UUID sid = UUID.randomUUID();
            sessionOf.put(trip.getKey(), sid);
            ingest.accept(sid, new BatchRequest("golden-e2e", 0, true, pts));
        }

        // 워커 대신 직접 돌립니다. 분할 크기가 1이면 300점 구간(묶음 2개)은 두 번에 나눠 끝납니다.
        int rounds = 0;
        List<SegmentRow> pending;
        while (!(pending = segments.findPending(100)).isEmpty()) {
            for (SegmentRow s : pending) {
                processor.process(s.id());
            }
            assertThat(++rounds).as("처리가 끝나지 않습니다").isLessThan(10);
        }
        assertThat(rounds).isEqualTo(chunk() == 1 ? 2 : 1);

        assertThat(jdbc.queryForObject("SELECT count(*) FROM gps_point", Integer.class)).isEqualTo(9 * 200 + 300);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM gps_point WHERE predicted_label IS NULL", Integer.class))
                .isZero();
        assertThat(jdbc.queryForList("SELECT DISTINCT label FROM gps_point ORDER BY 1", String.class))
                .containsExactly("bike", "bus", "car", "subway", "walk");

        // 200점 구간: 모든 좌표의 bike 확률 = 그 창의 골든 기대값
        for (Golden g : golden) {
            if (g.id().startsWith("10656_")) {
                continue;
            }
            assertTrip(sessionOf.get(g.id().substring(0, g.id().indexOf('_'))), 0, 200,
                    g.expected().get("bike"), argmax(g.expected()));
        }

        // 300점 구간: [0,100) 창0, [100,200) 두 창 평균, [200,300) 창1
        Map<String, Double> w0 = golden.stream().filter(g -> g.id().equals("10656_0")).findFirst().orElseThrow().expected();
        Map<String, Double> w1 = golden.stream().filter(g -> g.id().equals("10656_100")).findFirst().orElseThrow().expected();
        Map<String, Double> avg = new TreeMap<>();
        w0.forEach((k, v) -> avg.put(k, (v + w1.get(k)) / 2));
        UUID trip10656 = sessionOf.get("10656");
        assertTrip(trip10656, 0, 100, w0.get("bike"), argmax(w0));
        assertTrip(trip10656, 100, 200, avg.get("bike"), argmax(avg));
        assertTrip(trip10656, 200, 300, w1.get("bike"), argmax(w1));

        assertThat(jdbc.queryForObject("SELECT count(DISTINCT model_version) FROM gps_point", Integer.class)).isEqualTo(1);
    }

    private void assertTrip(UUID sid, int from, int to, double probBike, String label) {
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT p.idx, p.predicted_label, p.predicted_prob_bike
                FROM gps_point p JOIN segment s ON s.id = p.segment_id
                WHERE s.session_id = ? AND p.idx >= ? AND p.idx < ? ORDER BY p.idx
                """, sid, from, to);
        assertThat(rows).hasSize(to - from);
        for (Map<String, Object> r : rows) {
            assertThat(r.get("predicted_label")).as("session %s idx %s", sid, r.get("idx")).isEqualTo(label);
            assertThat((Double) r.get("predicted_prob_bike")).as("session %s idx %s", sid, r.get("idx"))
                    .isCloseTo(probBike, Offset.offset(1e-4));
        }
    }

    private static String argmax(Map<String, Double> probs) {
        return probs.entrySet().stream().max(Map.Entry.comparingByValue()).orElseThrow().getKey();
    }
}
