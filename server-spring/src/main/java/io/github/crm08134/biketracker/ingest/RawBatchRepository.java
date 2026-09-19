package io.github.crm08134.biketracker.ingest;

import java.util.List;
import java.util.UUID;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

@Repository
public class RawBatchRepository {

    private final JdbcTemplate jdbc;

    public RawBatchRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** (session_id, seq) 중복을 DB 제약으로 막습니다. 이미 있으면 false. */
    public boolean insertIfAbsent(UUID sessionId, int seq, String payload) {
        int changed = jdbc.update("""
                INSERT INTO raw_batch (session_id, seq, payload)
                VALUES (?, ?, ?::jsonb)
                ON CONFLICT (session_id, seq) DO NOTHING
                """, sessionId, seq, payload);
        return changed > 0;
    }

    /** 아직 반영 안 한 배치의 payload. 없으면 null. */
    public String findPayload(UUID sessionId, int seq) {
        List<String> rows = jdbc.query("""
                SELECT payload::text FROM raw_batch
                WHERE session_id = ? AND seq = ? AND consumed = FALSE
                """, (rs, i) -> rs.getString(1), sessionId, seq);
        return rows.isEmpty() ? null : rows.get(0);
    }

    public void markConsumed(UUID sessionId, int seq) {
        jdbc.update("UPDATE raw_batch SET consumed = TRUE WHERE session_id = ? AND seq = ?",
                sessionId, seq);
    }
}
