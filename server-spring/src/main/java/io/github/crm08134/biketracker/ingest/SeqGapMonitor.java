package io.github.crm08134.biketracker.ingest;

import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import io.github.crm08134.biketracker.config.TrackerProperties;

/**
 * seq 빈 자리 감시. 앱이 어떤 배치를 영영 안 보내면(앱에서 DEAD 처리 등) 그 뒤 배치는 raw_batch 에
 * 쌓이기만 하고 반영되지 않습니다. 자동으로 건너뛰지는 않고 멈췄다는 사실만 알립니다.
 *
 * <p>멈춘 자리 하나당 ERROR 는 한 번만 남깁니다. 풀리면 INFO 한 줄을 남기고 기록을 지웁니다.
 * 같은 세션이 풀린 뒤 다른 번호에서 다시 멈추면 새로 ERROR 를 남깁니다.
 *
 * <p>기록은 메모리에만 둡니다. 서버를 다시 띄우면 아직 멈춰 있는 자리를 한 번 더 알립니다.
 */
@Component
public class SeqGapMonitor {

    private static final Logger log = LoggerFactory.getLogger(SeqGapMonitor.class);

    private final SessionRepository sessions;
    private final TrackerProperties props;

    /** 이미 알린 세션 -> 알렸을 때 기다리던 seq. */
    private final Map<UUID, Integer> reported = new ConcurrentHashMap<>();

    public SeqGapMonitor(SessionRepository sessions, TrackerProperties props) {
        this.sessions = sessions;
        this.props = props;
    }

    public void scan() {
        List<SessionRepository.SeqGap> gaps = sessions.findSeqGaps(props.getSession().getSeqGapAlertAfter());
        Set<UUID> stillBlocked = new HashSet<>();

        for (SessionRepository.SeqGap g : gaps) {
            Integer before = reported.get(g.sessionId());
            if (before != null && before == g.missingSeq()) {
                stillBlocked.add(g.sessionId());
                continue;
            }
            if (before != null) {
                // 앞 자리는 풀렸고, 뒤에서 다시 멈췄습니다.
                logResolved(g.sessionId(), before);
            }
            log.error("seq 빈 자리로 반영 멈춤 session={} state={} 기다리는_seq={} 뒤에_대기={}건(seq {}부터) 멈춘_시각={}",
                    g.sessionId(), g.state(), g.missingSeq(), g.waiting(), g.firstWaitingSeq(), g.blockedSince());
            reported.put(g.sessionId(), g.missingSeq());
            stillBlocked.add(g.sessionId());
        }

        for (Iterator<Map.Entry<UUID, Integer>> it = reported.entrySet().iterator(); it.hasNext(); ) {
            Map.Entry<UUID, Integer> e = it.next();
            if (!stillBlocked.contains(e.getKey())) {
                logResolved(e.getKey(), e.getValue());
                it.remove();
            }
        }
    }

    private static void logResolved(UUID sessionId, int seq) {
        log.info("seq 빈 자리 해소 session={} 기다리던_seq={}", sessionId, seq);
    }
}
