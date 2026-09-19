package io.github.crm08134.biketracker.segment;

import java.sql.Types;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

@Repository
public class SegmentRepository {

    private static final RowMapper<SegmentRow> MAPPER = (rs, i) -> new SegmentRow(
            rs.getLong("id"),
            rs.getObject("session_id", UUID.class),
            rs.getInt("idx"),
            rs.getInt("point_count"),
            rs.getObject("last_ts") == null ? null : rs.getLong("last_ts"),
            rs.getInt("windows_done"),
            rs.getInt("flushed_through"),
            rs.getBoolean("closed"));

    private static final String COLUMNS =
            "id, session_id, idx, point_count, last_ts, windows_done, flushed_through, closed";

    private final JdbcTemplate jdbc;

    public SegmentRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<SegmentRow> findOpen(UUID sessionId) {
        return jdbc.query("SELECT " + COLUMNS + " FROM segment "
                + "WHERE session_id = ? AND closed = FALSE ORDER BY idx DESC LIMIT 1",
                MAPPER, sessionId).stream().findFirst();
    }

    public SegmentRow open(UUID sessionId) {
        Long id = jdbc.queryForObject("""
                INSERT INTO segment (session_id, idx)
                VALUES (?, COALESCE((SELECT MAX(idx) + 1 FROM segment WHERE session_id = ?), 0))
                RETURNING id
                """, Long.class, sessionId, sessionId);
        return findById(id).orElseThrow();
    }

    /**
     * 세션의 마지막 구간을 잠근 채로. 열린 구간이 없을 때(끝난 세션에 늦게 온 배치) 이 구간과
     * 300초 공백 규칙으로 이어 붙일지 정합니다.
     */
    public Optional<SegmentRow> findLastForUpdate(UUID sessionId) {
        return jdbc.query("SELECT " + COLUMNS + " FROM segment "
                + "WHERE session_id = ? ORDER BY idx DESC LIMIT 1 FOR UPDATE",
                MAPPER, sessionId).stream().findFirst();
    }

    /**
     * 닫힌 구간을 다시 엽니다. 이미 마무리됐으면 마무리 전 상태로 돌립니다.
     *
     * <p>flushed_through 는 확정 지점(windowsDone * stride)까지만 되돌립니다. 그 뒤의 끝부분은
     * 마무리 때 "마지막 묶음 판정"으로 확정된 것이라, 좌표가 더 붙으면 판정이 달라집니다.
     * 호출하는 쪽이 그 구간의 track_point 와 gps_point 판정도 지워야 합니다.
     * 200점 미만이라 버렸던 구간은 discarded 를 풀어 다시 기회를 줍니다.
     *
     * @return 되돌린 뒤의 구간
     */
    public SegmentRow reopen(SegmentRow seg, int flushedThrough) {
        jdbc.update("""
                UPDATE segment
                SET closed = FALSE, finalized = FALSE, discarded = FALSE, flushed_through = ?
                WHERE id = ?
                """, flushedThrough, seg.id());
        return findById(seg.id()).orElseThrow();
    }

    public Optional<SegmentRow> findById(long id) {
        return jdbc.query("SELECT " + COLUMNS + " FROM segment WHERE id = ?", MAPPER, id)
                .stream().findFirst();
    }

    public void updateTail(long id, int pointCount, Long lastTs) {
        jdbc.update("UPDATE segment SET point_count = ?, last_ts = ? WHERE id = ?",
                pointCount, lastTs, id);
    }

    public void close(long id) {
        jdbc.update("UPDATE segment SET closed = TRUE WHERE id = ?", id);
    }

    public void closeOpen(UUID sessionId) {
        jdbc.update("UPDATE segment SET closed = TRUE WHERE session_id = ? AND closed = FALSE", sessionId);
    }

    public void markProgress(long id, int windowsDone, int flushedThrough) {
        jdbc.update("UPDATE segment SET windows_done = ?, flushed_through = ? WHERE id = ?",
                windowsDone, flushedThrough, id);
    }

    /**
     * 읽었을 때와 좌표 개수가 같을 때만 마무리합니다. 처리 도중 늦은 배치가 구간을 다시 열어
     * 좌표를 붙였으면 false 입니다. 그대로 마무리하면 새로 붙은 좌표가 영영 처리되지 않습니다.
     */
    public boolean markFinalized(long id, boolean discarded, int expectedPointCount) {
        return jdbc.update("""
                UPDATE segment SET finalized = TRUE, discarded = ?
                WHERE id = ? AND point_count = ? AND finalized = FALSE
                """, discarded, id, expectedPointCount) > 0;
    }

    /**
     * 처리할 게 남은 구간. 묶음이 새로 찼거나, 닫혔는데 아직 마무리 안 된 것들입니다.
     * windowSize / stride 는 SQL 에서 그대로 쓰지 않고 후보만 넓게 뽑은 뒤 코드에서 거릅니다.
     */
    public List<SegmentRow> findPending(int limit) {
        return jdbc.query("SELECT " + COLUMNS + " FROM segment "
                + "WHERE finalized = FALSE ORDER BY id LIMIT ?", MAPPER, limit);
    }

    /** 좌표 하나의 최종 판정. bike 가 아니어도 전부 적습니다. */
    public record PointPrediction(int idx, String label, Double probBike, String modelVersion) {}

    /** 확정된 좌표의 판정을 gps_point 에 적습니다. 라벨은 소문자로 정규화합니다. */
    public void savePredictions(long segmentId, List<PointPrediction> predictions) {
        if (predictions.isEmpty()) {
            return;
        }
        jdbc.batchUpdate("""
                UPDATE gps_point SET predicted_label = ?, predicted_prob_bike = ?, model_version = ?
                WHERE segment_id = ? AND idx = ?
                """, predictions, predictions.size(), (ps, p) -> {
                    ps.setString(1, p.label() == null ? null : p.label().toLowerCase(Locale.ROOT));
                    if (p.probBike() == null) {
                        ps.setNull(2, Types.DOUBLE);
                    } else {
                        ps.setDouble(2, p.probBike());
                    }
                    ps.setString(3, p.modelVersion());
                    ps.setLong(4, segmentId);
                    ps.setInt(5, p.idx());
                });
    }

    /** [fromIdx, toIdx) 좌표의 판정을 지웁니다. 다시 열린 구간의 끝부분 판정을 무를 때 씁니다. */
    public int clearPredictions(long segmentId, int fromIdx, int toIdx) {
        return jdbc.update("""
                UPDATE gps_point SET predicted_label = NULL, predicted_prob_bike = NULL, model_version = NULL
                WHERE segment_id = ? AND idx >= ? AND idx < ?
                """, segmentId, fromIdx, toIdx);
    }

    public List<SegmentPoint> findPoints(long segmentId, int fromIdx, int toIdxExclusive) {
        return jdbc.query("""
                SELECT idx, ts, lat, lng FROM gps_point
                WHERE segment_id = ? AND idx >= ? AND idx < ?
                ORDER BY idx
                """, (rs, i) -> new SegmentPoint(
                        rs.getInt("idx"), rs.getLong("ts"),
                        rs.getDouble("lat"), rs.getDouble("lng")),
                segmentId, fromIdx, toIdxExclusive);
    }
}
