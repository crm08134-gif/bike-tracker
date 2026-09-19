package io.github.crm08134.biketracker.ingest;

import java.util.Locale;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

@Repository
public class PointRepository {

    private final JdbcTemplate jdbc;

    public PointRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** label 은 소문자로 정규화해 저장합니다. 앱은 BIKE, 모델은 bike 를 씁니다. */
    public void insert(long segmentId, int idx, long ts, double lat, double lng, Float acc, String label) {
        jdbc.update("""
                INSERT INTO gps_point (segment_id, idx, ts, lat, lng, acc, label)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (segment_id, idx) DO NOTHING
                """, segmentId, idx, ts, lat, lng, acc, label == null ? null : label.toLowerCase(Locale.ROOT));
    }
}
