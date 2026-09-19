package io.github.crm08134.biketracker.ingest;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

import io.github.crm08134.biketracker.common.ApiException;

@Repository
public class SessionRepository {

    private static final RowMapper<SessionRow> MAPPER = (rs, i) -> new SessionRow(
            rs.getObject("session_id", UUID.class),
            rs.getString("device_id"),
            SessionState.valueOf(rs.getString("state")),
            rs.getInt("next_seq"));

    private final JdbcTemplate jdbc;

    public SessionRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * 세션이 없으면 만들고, 행을 잠근 채로 돌려줍니다.
     *
     * <p>앱은 배치를 동시에 3건까지 보냅니다. 잠그지 않으면 두 요청이 같은 next_seq 를 읽고,
     * 늦게 끝난 쪽이 앞선 쪽이 올려 둔 next_seq 를 되돌려 씁니다. 되돌아간 번호의 배치는 이미
     * consumed 라 다시 읽히지 않으므로 그 세션은 영원히 멈춥니다.
     */
    public SessionRow findOrCreateForUpdate(UUID sessionId, String deviceId) {
        jdbc.update("""
                INSERT INTO session (session_id, device_id)
                VALUES (?, ?)
                ON CONFLICT (session_id) DO NOTHING
                """, sessionId, deviceId);
        return requireForUpdate(sessionId);
    }

    public SessionRow requireForUpdate(UUID sessionId) {
        List<SessionRow> rows = jdbc.query("""
                SELECT session_id, device_id, state, next_seq
                FROM session WHERE session_id = ?
                FOR UPDATE
                """, MAPPER, sessionId);
        if (rows.isEmpty()) {
            throw new ApiException(HttpStatus.NOT_FOUND, "SESSION_NOT_FOUND", "없는 세션입니다", false);
        }
        return rows.get(0);
    }

    public void touch(UUID sessionId, int nextSeq) {
        jdbc.update("UPDATE session SET next_seq = ?, last_seen_at = now() WHERE session_id = ?",
                nextSeq, sessionId);
    }

    public void setState(UUID sessionId, SessionState state, Integer nextSeq) {
        if (nextSeq == null) {
            jdbc.update("UPDATE session SET state = ? WHERE session_id = ?", state.name(), sessionId);
        } else {
            jdbc.update("UPDATE session SET state = ?, next_seq = ? WHERE session_id = ?",
                    state.name(), nextSeq, sessionId);
        }
    }

    public List<UUID> findStale(Duration abandonAfter) {
        Instant cutoff = Instant.now().minus(abandonAfter);
        return jdbc.query("""
                SELECT session_id FROM session
                WHERE state = 'ACTIVE' AND last_seen_at < ?
                """, (rs, i) -> rs.getObject("session_id", UUID.class),
                java.sql.Timestamp.from(cutoff));
    }

    /**
     * 아직 조용하면 ABANDONED 로 내립니다. 조회 뒤에 배치가 들어왔으면 아무것도 안 하고 false.
     *
     * <p>세션 행을 구간보다 먼저 잠급니다. 배치 수신과 잠금 순서를 같게 해야 교착이 안 납니다.
     */
    public boolean abandonIfStale(UUID sessionId, Duration abandonAfter) {
        Instant cutoff = Instant.now().minus(abandonAfter);
        return jdbc.update("""
                UPDATE session SET state = 'ABANDONED'
                WHERE session_id = ? AND state = 'ACTIVE' AND last_seen_at < ?
                """, sessionId, java.sql.Timestamp.from(cutoff)) > 0;
    }

    /**
     * next_seq 번 배치가 없어서 뒤 배치가 반영되지 못하고 기다리는 세션.
     * 기다리는 배치 중 가장 먼저 도착한 것이 {@code blockedFor} 보다 오래됐을 때만 돌려줍니다.
     */
    public List<SeqGap> findSeqGaps(Duration blockedFor) {
        Instant cutoff = Instant.now().minus(blockedFor);
        return jdbc.query("""
                SELECT s.session_id, s.state, s.next_seq,
                       COUNT(*)           AS waiting,
                       MIN(r.seq)         AS first_waiting_seq,
                       MIN(r.received_at) AS blocked_since
                FROM session s
                JOIN raw_batch r
                  ON r.session_id = s.session_id AND r.consumed = FALSE AND r.seq > s.next_seq
                WHERE NOT EXISTS (SELECT 1 FROM raw_batch x
                                  WHERE x.session_id = s.session_id AND x.seq = s.next_seq
                                    AND x.consumed = FALSE)
                GROUP BY s.session_id, s.state, s.next_seq
                HAVING MIN(r.received_at) < ?
                """, (rs, i) -> new SeqGap(
                        rs.getObject("session_id", UUID.class),
                        SessionState.valueOf(rs.getString("state")),
                        rs.getInt("next_seq"),
                        rs.getInt("waiting"),
                        rs.getInt("first_waiting_seq"),
                        rs.getTimestamp("blocked_since").toInstant()),
                java.sql.Timestamp.from(cutoff));
    }

    public record SeqGap(UUID sessionId, SessionState state, int missingSeq, int waiting,
                         int firstWaitingSeq, Instant blockedSince) {}
}
