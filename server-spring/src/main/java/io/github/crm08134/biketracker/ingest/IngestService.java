package io.github.crm08134.biketracker.ingest;

import java.util.List;
import java.util.UUID;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import io.github.crm08134.biketracker.common.ApiException;
import io.github.crm08134.biketracker.config.TrackerProperties;
import io.github.crm08134.biketracker.ingest.dto.BatchRequest;
import io.github.crm08134.biketracker.ingest.dto.BatchResponse;
import io.github.crm08134.biketracker.ingest.dto.PointDto;
import io.github.crm08134.biketracker.segment.SegmentRepository;
import io.github.crm08134.biketracker.segment.SegmentRow;
import io.github.crm08134.biketracker.segment.WindowSpec;
import io.github.crm08134.biketracker.store.TrackRepository;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.json.JsonMapper;

/**
 * 배치 수신, 중복 제거, 정확도 필터, 300초 공백 분리. 계획서 4절의 ingest 담당입니다.
 *
 * <p>배치는 seq 순서대로만 좌표 스트림에 반영합니다. 3번이 먼저 와도 2번이 도착할 때까지
 * raw_batch 에 눕혀만 둡니다. 순서를 지켜야 구간 안의 좌표 순번(idx)이 어긋나지 않습니다.
 *
 * <p>끝난 세션(CLOSED / ABANDONED)에 온 배치도 거부하지 않고 원래 세션에 이어 붙입니다.
 * ABANDONED 는 "더 기다리지 않는다"는 표시일 뿐입니다. 늦게 온 좌표가 같은 주행인지는
 * 300초 공백 규칙이 정합니다.
 */
@Service
public class IngestService {

    private static final Logger log = LoggerFactory.getLogger(IngestService.class);

    private final SessionRepository sessions;
    private final RawBatchRepository batches;
    private final SegmentRepository segments;
    private final PointRepository points;
    private final TrackRepository tracks;
    private final TrackerProperties props;
    private final WindowSpec spec;
    private final JsonMapper json;

    public IngestService(SessionRepository sessions, RawBatchRepository batches,
                         SegmentRepository segments, PointRepository points,
                         TrackRepository tracks, TrackerProperties props, JsonMapper json) {
        this.sessions = sessions;
        this.batches = batches;
        this.segments = segments;
        this.points = points;
        this.tracks = tracks;
        this.props = props;
        this.spec = props.windowSpec();
        this.json = json;
    }

    @Transactional
    public BatchResponse accept(UUID sessionId, BatchRequest body) {
        SessionRow session = sessions.findOrCreateForUpdate(sessionId, body.deviceId());

        if (session.state() != SessionState.ACTIVE) {
            log.info("끝난 세션에 배치 수신, 이어 붙입니다 session={} state={} seq={} points={}",
                    sessionId, session.state(), body.seq(), body.points().size());
        }

        boolean fresh = batches.insertIfAbsent(sessionId, body.seq(), toJson(body));
        if (!fresh) {
            log.debug("중복 배치 무시 session={} seq={}", sessionId, body.seq());
        }

        Drained d = drain(session);
        return new BatchResponse(d.state(), d.nextSeq());
    }

    @Transactional
    public BatchResponse close(UUID sessionId) {
        SessionRow session = sessions.requireForUpdate(sessionId);
        int nextSeq = drain(session).nextSeq();
        segments.closeOpen(sessionId);
        sessions.setState(sessionId, SessionState.CLOSED, nextSeq);
        return new BatchResponse(SessionState.CLOSED, nextSeq);
    }

    /** 마지막 배치 이후 오래 조용한 ACTIVE 세션을 ABANDONED 로 내리고 구간을 닫습니다. */
    @Transactional
    public int abandonStale() {
        List<UUID> stale = sessions.findStale(props.getSession().getAbandonAfter());
        int abandoned = 0;
        for (UUID id : stale) {
            // 세션을 먼저 내리고(잠금) 구간을 닫습니다. 조회 뒤에 배치가 들어왔으면 건너뜁니다.
            if (!sessions.abandonIfStale(id, props.getSession().getAbandonAfter())) {
                continue;
            }
            segments.closeOpen(id);
            abandoned++;
            log.info("세션 ABANDONED session={}", id);
        }
        return abandoned;
    }

    private record Drained(SessionState state, int nextSeq) {}

    /**
     * next_seq 부터 연속으로 도착해 있는 배치를 순서대로 좌표 스트림에 붙입니다.
     * 세션 행은 호출하는 쪽이 잠가 둡니다.
     */
    private Drained drain(SessionRow session) {
        UUID sessionId = session.sessionId();
        SessionState state = session.state();
        int seq = session.nextSeq();
        while (true) {
            String payload = batches.findPayload(sessionId, seq);
            if (payload == null) {
                break;
            }
            BatchRequest batch = readBatch(payload);
            append(sessionId, seq, batch.points());
            batches.markConsumed(sessionId, seq);

            if (batch.lastBatch()) {
                // 순서대로 반영되는 시점에 닫습니다. 받은 시점에 닫으면 동시 전송으로 먼저 도착한
                // 마지막 배치가 앞 번호 배치보다 먼저 세션을 닫아 버립니다.
                // ACTIVE 에서만 CLOSED 로 갑니다. ABANDONED 는 이미 종착 상태라 그대로 둡니다.
                if (state == SessionState.ACTIVE) {
                    state = SessionState.CLOSED;
                    sessions.setState(sessionId, SessionState.CLOSED, null);
                    log.info("마지막 배치로 세션 CLOSED session={} seq={}", sessionId, seq);
                }
            }
            seq++;
        }

        if (state != SessionState.ACTIVE) {
            // 끝난 세션은 다음 배치를 기다리지 않습니다. 이번에 붙인 좌표까지 포함해 구간을 닫아
            // 끝부분 규칙이 적용되게 합니다. 또 늦은 배치가 오면 300초 규칙으로 다시 열립니다.
            segments.closeOpen(sessionId);
        }
        sessions.touch(sessionId, seq);
        return new Drained(state, seq);
    }

    /** 필터를 통과한 좌표를 열린 구간 뒤에 붙입니다. 300초가 비면 새 구간을 엽니다. */
    private void append(UUID sessionId, int seq, List<PointDto> incoming) {
        SegmentRow open = segments.findOpen(sessionId).orElse(null);
        // 열린 구간이 없으면(끝난 세션에 늦게 온 배치) 마지막으로 닫힌 구간과 비교합니다.
        SegmentRow closedTail = open == null ? segments.findLastForUpdate(sessionId).orElse(null) : null;

        int noAcc = 0;
        int inaccurate = 0;
        int nonIncreasing = 0;
        int stored = 0;

        for (PointDto p : incoming) {
            // 계획서 7절 전처리: 정확도가 없거나 20m 를 넘으면 버립니다.
            if (p.acc() == null) {
                noAcc++;
                continue;
            }
            if (p.acc() > props.getAccuracyLimitM()) {
                inaccurate++;
                continue;
            }
            Long lastTs = open != null ? open.lastTs() : closedTail != null ? closedTail.lastTs() : null;
            // ts 가 직전보다 크지 않으면 버립니다. 속도가 inf 가 되는 걸 막는 방어입니다.
            if (lastTs != null && p.ts() <= lastTs) {
                nonIncreasing++;
                continue;
            }
            boolean gap = lastTs != null && p.ts() - lastTs > props.getSegmentGapMs();
            // 300초 넘게 끊겼으면 구간을 끊습니다.
            if (open != null && gap) {
                // 닫기 전에 지금까지 쌓인 개수를 반드시 반영합니다.
                segments.updateTail(open.id(), open.pointCount(), open.lastTs());
                segments.close(open.id());
                open = null;
            }
            if (open == null) {
                open = closedTail != null && closedTail.lastTs() != null && !gap
                        ? reopen(closedTail)
                        : segments.open(sessionId);
                closedTail = null;
            }
            points.insert(open.id(), open.pointCount(), p.ts(), p.lat(), p.lng(), p.acc(), p.label());
            open = open.withAppended(p.ts());
            stored++;
        }

        if (open != null) {
            segments.updateTail(open.id(), open.pointCount(), open.lastTs());
        }

        int dropped = noAcc + inaccurate + nonIncreasing;
        if (dropped > 0) {
            log.info("배치 반영 session={} seq={} received={} stored={} dropped: no_acc={} acc_over_limit={} ts_non_increasing={}",
                    sessionId, seq, incoming.size(), stored, noAcc, inaccurate, nonIncreasing);
        } else {
            log.debug("배치 반영 session={} seq={} received={} stored={}", sessionId, seq, incoming.size(), stored);
        }
    }

    /** 닫힌 구간을 300초 안의 늦은 좌표로 다시 엽니다. 끝부분 확정분은 무릅니다. */
    private SegmentRow reopen(SegmentRow seg) {
        int settled = Math.min(seg.flushedThrough(), spec.settledExclusive(seg.windowsDone()));
        int revoked = 0;
        if (seg.flushedThrough() > settled) {
            revoked = tracks.deleteBySegmentRange(seg.sessionId(), seg.id(), settled, seg.flushedThrough());
            segments.clearPredictions(seg.id(), settled, seg.flushedThrough());
        }
        log.info("늦은 좌표로 구간 재개 session={} segment={} points={} flushed {}->{} track_point 회수={}",
                seg.sessionId(), seg.id(), seg.pointCount(), seg.flushedThrough(), settled, revoked);
        return segments.reopen(seg, settled);
    }

    private BatchRequest readBatch(String payload) {
        // Jackson 3 의 예외는 unchecked 입니다. 여기서 터지면 우리가 저장한 payload 가 깨진 것입니다.
        try {
            return json.readValue(payload, BatchRequest.class);
        } catch (JacksonException e) {
            throw new IllegalStateException("raw_batch payload 를 읽지 못했습니다", e);
        }
    }

    private String toJson(BatchRequest body) {
        try {
            return json.writeValueAsString(body);
        } catch (JacksonException e) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_REQUEST", "배치를 직렬화하지 못했습니다", false);
        }
    }
}
