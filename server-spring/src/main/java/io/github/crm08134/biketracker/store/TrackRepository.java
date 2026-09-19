package io.github.crm08134.biketracker.store;

import java.util.List;
import java.util.UUID;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

/**
 * 최종 판정이 bike 인 좌표만 PostGIS 에 적재합니다. 계획서 7절.
 * 판정과 적재가 같은 서버 안에 있으므로 한 트랜잭션으로 묶입니다.
 */
@Repository
public class TrackRepository {

    private final JdbcTemplate jdbc;

    public TrackRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 구간의 [fromIdx, toIdx) 좌표로 적재된 행을 지웁니다. 다시 열린 구간의 끝부분 판정을 무를 때 씁니다. */
    public int deleteBySegmentRange(UUID sessionId, long segmentId, int fromIdx, int toIdx) {
        return jdbc.update("""
                DELETE FROM track_point
                WHERE session_id = ?
                  AND ts IN (SELECT ts FROM gps_point WHERE segment_id = ? AND idx >= ? AND idx < ?)
                """, sessionId, segmentId, fromIdx, toIdx);
    }

    public void insertBikePoints(UUID sessionId, List<BikePoint> points) {
        if (points.isEmpty()) {
            return;
        }
        jdbc.batchUpdate("""
                INSERT INTO track_point (session_id, ts, geom, model_version)
                VALUES (?, ?, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)
                ON CONFLICT (session_id, ts) DO NOTHING
                """, points, points.size(), (ps, p) -> {
                    ps.setObject(1, sessionId);
                    ps.setLong(2, p.ts());
                    ps.setDouble(3, p.lng());   // ST_MakePoint 는 (경도, 위도) 순서입니다
                    ps.setDouble(4, p.lat());
                    ps.setString(5, p.modelVersion());
                });
    }
}
