package io.github.crm08134.biketracker.query;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import io.github.crm08134.biketracker.ingest.SessionState;
import io.github.crm08134.biketracker.query.PredictionsResponse.PredictedPoint;
import io.github.crm08134.biketracker.query.PredictionsResponse.Progress;

/** 판정 조회 전용. 쓰지 않습니다. */
@Repository
public class PredictionRepository {

    private final JdbcTemplate jdbc;

    public PredictionRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<SessionState> findSessionState(UUID sessionId) {
        return jdbc.query("SELECT state FROM session WHERE session_id = ?",
                (rs, i) -> SessionState.valueOf(rs.getString("state")), sessionId).stream().findFirst();
    }

    /**
     * predicted_label 이 NULL 인 좌표는 구간 상태로 가릅니다.
     * discarded 면 판정 불가, 아니면 아직 대기 중입니다. 마무리된(finalized) 버리지 않은 구간은
     * 마무리 직전에 끝부분까지 판정을 적으므로 NULL 이 남지 않습니다 (SegmentProcessor).
     */
    public Progress progress(UUID sessionId) {
        return jdbc.queryForObject("""
                SELECT count(*)                                                        AS total,
                       count(p.predicted_label)                                        AS predicted,
                       count(*) FILTER (WHERE s.discarded AND p.predicted_label IS NULL) AS unpredictable
                FROM gps_point p
                JOIN segment s ON s.id = p.segment_id
                WHERE s.session_id = ?
                """, (rs, i) -> new Progress(rs.getInt("total"), rs.getInt("predicted"), rs.getInt("unpredictable")),
                sessionId);
    }

    public int waitingBatches(UUID sessionId) {
        return jdbc.queryForObject(
                "SELECT count(*) FROM raw_batch WHERE session_id = ? AND consumed = FALSE",
                Integer.class, sessionId);
    }

    public List<PredictedPoint> findPoints(UUID sessionId) {
        return jdbc.query("""
                SELECT p.ts, p.lat, p.lng, p.predicted_label, p.predicted_prob_bike
                FROM gps_point p
                JOIN segment s ON s.id = p.segment_id
                WHERE s.session_id = ?
                ORDER BY s.idx, p.idx
                """, (rs, i) -> new PredictedPoint(
                        rs.getLong("ts"), rs.getDouble("lat"), rs.getDouble("lng"),
                        rs.getString("predicted_label"),
                        rs.getObject("predicted_prob_bike", Double.class)),
                sessionId);
    }
}
