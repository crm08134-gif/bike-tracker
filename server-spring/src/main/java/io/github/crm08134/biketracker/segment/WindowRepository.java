package io.github.crm08134.biketracker.segment;

import java.util.List;
import java.util.Map;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import tools.jackson.core.JacksonException;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

@Repository
public class WindowRepository {

    private static final TypeReference<Map<String, Double>> PROBS = new TypeReference<>() {};

    private final JdbcTemplate jdbc;
    private final JsonMapper json;

    public WindowRepository(JdbcTemplate jdbc, JsonMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    public void save(long segmentId, WindowResult result, Integer elapsedMs) {
        jdbc.update("""
                INSERT INTO inference_window (segment_id, start_idx, label, probs, model_version, elapsed_ms)
                VALUES (?, ?, ?, ?::jsonb, ?, ?)
                ON CONFLICT (segment_id, start_idx) DO NOTHING
                """, segmentId, result.startIdx(), result.label(),
                write(result.probs()), result.modelVersion(), elapsedMs);
    }

    /** 구간의 묶음 결과를 번호 순으로. VerdictResolver 는 이 순서를 전제합니다. */
    public List<WindowResult> findAll(long segmentId) {
        return jdbc.query("""
                SELECT start_idx, label, probs::text, model_version
                FROM inference_window WHERE segment_id = ? ORDER BY start_idx
                """, (rs, i) -> new WindowResult(
                        rs.getInt("start_idx"),
                        rs.getString("label"),
                        read(rs.getString(3)),
                        rs.getString("model_version")),
                segmentId);
    }

    private String write(Map<String, Double> probs) {
        try {
            return json.writeValueAsString(probs);
        } catch (JacksonException e) {
            throw new IllegalStateException("확률을 직렬화하지 못했습니다", e);
        }
    }

    private Map<String, Double> read(String text) {
        try {
            return json.readValue(text, PROBS);
        } catch (JacksonException e) {
            throw new IllegalStateException("확률을 읽지 못했습니다", e);
        }
    }
}
