package io.github.crm08134.biketracker.segment;

import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import io.github.crm08134.biketracker.config.TrackerProperties;
import io.github.crm08134.biketracker.infer.InferenceUnavailableException;
import io.github.crm08134.biketracker.ingest.IngestService;
import io.github.crm08134.biketracker.ingest.SeqGapMonitor;

/**
 * 주기적으로 밀린 구간을 처리합니다. 앱 응답(202)과 추론을 떼어 놓기 위한 장치입니다.
 *
 * <p>구간 하나가 실패해도 다른 구간은 계속 돕니다. 추론 서버가 죽어 있으면 그 주기는 그냥
 * 넘어가고, 살아나면 밀린 묶음을 batch 로 한꺼번에 처리합니다.
 */
@Component
public class SegmentWorker {

    private static final Logger log = LoggerFactory.getLogger(SegmentWorker.class);

    private final SegmentRepository segments;
    private final SegmentProcessor processor;
    private final IngestService ingest;
    private final SeqGapMonitor seqGaps;
    private final TrackerProperties props;

    public SegmentWorker(SegmentRepository segments, SegmentProcessor processor,
                         IngestService ingest, SeqGapMonitor seqGaps, TrackerProperties props) {
        this.segments = segments;
        this.processor = processor;
        this.ingest = ingest;
        this.seqGaps = seqGaps;
        this.props = props;
    }

    @Scheduled(fixedDelayString = "${tracker.worker.fixed-delay}")
    public void tick() {
        List<SegmentRow> pending = segments.findPending(props.getWorker().getBatchSize());
        for (SegmentRow seg : pending) {
            try {
                processor.process(seg.id());
            } catch (SegmentChangedException e) {
                log.info("{}, 다음 주기에 다시 처리합니다", e.getMessage());
            } catch (InferenceUnavailableException e) {
                log.warn("추론 서버 대기 중, 다음 주기에 재시도 segment={}", seg.id());
            } catch (RuntimeException e) {
                log.error("구간 처리 실패 segment={}", seg.id(), e);
            }
        }
    }

    /** seq 빈 자리 감시. 멈춘 자리 하나당 ERROR 한 번, 풀리면 INFO 한 번 (SeqGapMonitor). */
    @Scheduled(fixedDelayString = "${tracker.worker.seq-gap-scan-delay}")
    public void reportSeqGaps() {
        try {
            seqGaps.scan();
        } catch (RuntimeException e) {
            log.error("seq 빈 자리 검사 실패", e);
        }
    }

    @Scheduled(fixedDelayString = "${tracker.worker.abandon-scan-delay}")
    public void abandonStale() {
        try {
            int n = ingest.abandonStale();
            if (n > 0) {
                log.info("ABANDONED 처리 {}건", n);
            }
        } catch (RuntimeException e) {
            log.error("ABANDONED 처리 실패", e);
        }
    }
}
