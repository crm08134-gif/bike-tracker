package io.github.crm08134.biketracker.segment;

import java.util.ArrayList;
import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import io.github.crm08134.biketracker.config.TrackerProperties;
import io.github.crm08134.biketracker.infer.InferenceClient;
import io.github.crm08134.biketracker.infer.InferenceModelGuard;
import io.github.crm08134.biketracker.infer.InferenceUnavailableException;
import io.github.crm08134.biketracker.infer.PredictRequest;
import io.github.crm08134.biketracker.infer.PredictResponse;
import io.github.crm08134.biketracker.store.BikePoint;
import io.github.crm08134.biketracker.store.TrackRepository;

/**
 * 구간 하나를 진행시킵니다. 계획서 6~7절.
 *
 * <ol>
 *   <li>새로 찬 묶음을 추론에 보냅니다.</li>
 *   <li>판정이 더 바뀌지 않는 좌표를 확정해 bike 만 PostGIS 로 넘깁니다.</li>
 *   <li>구간이 닫혔으면 남은 끝부분을 마지막 묶음 판정으로 확정하고 마무리합니다.</li>
 * </ol>
 */
@Service
public class SegmentProcessor {

    private static final Logger log = LoggerFactory.getLogger(SegmentProcessor.class);

    private final SegmentRepository segments;
    private final WindowRepository windows;
    private final TrackRepository tracks;
    private final InferenceClient inference;
    private final VerdictResolver resolver;
    private final InferenceModelGuard model;
    private final TrackerProperties props;
    private final WindowSpec spec;

    public SegmentProcessor(SegmentRepository segments, WindowRepository windows,
                            TrackRepository tracks, InferenceClient inference,
                            VerdictResolver resolver, InferenceModelGuard model, TrackerProperties props) {
        this.segments = segments;
        this.windows = windows;
        this.tracks = tracks;
        this.inference = inference;
        this.resolver = resolver;
        this.model = model;
        this.props = props;
        this.spec = props.windowSpec();
    }

    @Transactional
    public void process(long segmentId) {
        SegmentRow seg = segments.findById(segmentId).orElse(null);
        if (seg == null) {
            return;
        }

        int available = spec.windowCount(seg.pointCount());

        // 1. 아직 안 보낸 묶음을 추론에 보냅니다. 한 번에 batchChunkSize 개까지만 보내고 나머지는
        //    다음 주기로 넘깁니다. 오프라인 백로그로 묶음이 수백 개 밀려도 요청 하나가 read timeout 을
        //    넘지 않고, 트랜잭션도 짧게 끊겨 진행분이 주기마다 커밋됩니다.
        int target = Math.min(available, seg.windowsDone() + model.batchChunkSize());
        if (target > seg.windowsDone()) {
            runInference(seg, seg.windowsDone(), target);
        }

        List<WindowResult> results = windows.findAll(segmentId);

        // 2. 확정된 좌표를 내보냅니다.
        int settled = spec.settledExclusive(results.size());
        int flushed = flush(seg, results, seg.flushedThrough(), settled);

        // 닫힌 구간이라도 묶음이 덜 끝났으면 끝부분 규칙을 적용하면 안 됩니다. 다음 주기에 이어갑니다.
        if (!seg.closed() || results.size() < available) {
            segments.markProgress(segmentId, results.size(), flushed);
            return;
        }

        // 3. 구간이 닫혔습니다. 200점 미만이면 통째로 버립니다. 계획서 7절.
        if (results.isEmpty()) {
            finalizeUnlessChanged(seg, true);
            log.info("짧은 구간 폐기 segment={} points={}", segmentId, seg.pointCount());
            return;
        }

        // 마지막 묶음 뒤에 남은 1~99점은 마지막 묶음의 판정을 그대로 받습니다.
        flushed = flush(seg, results, flushed, seg.pointCount());
        segments.markProgress(segmentId, results.size(), flushed);
        finalizeUnlessChanged(seg, false);
        log.info("구간 마무리 segment={} points={} windows={}", segmentId, seg.pointCount(), results.size());
    }

    /**
     * 읽었을 때의 좌표 개수로만 마무리합니다. 그 사이 늦은 배치가 구간을 다시 열었으면 예외로
     * 이번 트랜잭션(끝부분 적재 포함)을 통째로 되돌립니다.
     */
    private void finalizeUnlessChanged(SegmentRow seg, boolean discarded) {
        if (!segments.markFinalized(seg.id(), discarded, seg.pointCount())) {
            throw new SegmentChangedException(seg.id());
        }
    }

    private void runInference(SegmentRow seg, int from, int to) {
        List<PredictRequest> requests = new ArrayList<>(to - from);
        for (int w = from; w < to; w++) {
            requests.add(buildRequest(seg, w));
        }

        List<PredictResponse> responses;
        if (requests.size() >= props.getInference().getBatchThreshold()) {
            responses = inference.predictBatch(requests);
            if (responses.size() != requests.size()) {
                throw new InferenceUnavailableException(
                        "배치 응답 개수가 요청과 다릅니다: " + responses.size() + " != " + requests.size(), null);
            }
        } else {
            responses = new ArrayList<>(requests.size());
            for (PredictRequest r : requests) {
                responses.add(inference.predict(r));
            }
        }

        for (int i = 0; i < responses.size(); i++) {
            PredictResponse r = responses.get(i);
            int startIdx = spec.startIdx(from + i);
            windows.save(seg.id(),
                    new WindowResult(startIdx, r.label(), r.probs(), r.modelVersion()),
                    r.elapsedMs());
        }
    }

    private PredictRequest buildRequest(SegmentRow seg, int windowIndex) {
        int start = spec.startIdx(windowIndex);
        List<SegmentPoint> pts = segments.findPoints(seg.id(), start, spec.endIdx(windowIndex));
        if (pts.size() != spec.size()) {
            throw new IllegalStateException(
                    "묶음 크기가 맞지 않습니다 segment=" + seg.id() + " window=" + windowIndex + " size=" + pts.size());
        }
        List<PredictRequest.Point> body = pts.stream()
                .map(p -> new PredictRequest.Point(p.ts(), p.lat(), p.lng()))
                .toList();
        return new PredictRequest(seg.sessionId(), pts.get(0).ts(), body);
    }

    /**
     * [from, to) 좌표의 판정을 정합니다. 판정은 bike 여부와 무관하게 전부 gps_point 에 적고,
     * bike 만 track_point 로 적재합니다. 새 flushedThrough 를 돌려줍니다.
     */
    private int flush(SegmentRow seg, List<WindowResult> results, int from, int to) {
        if (to <= from || results.isEmpty()) {
            return from;
        }
        List<SegmentPoint> pts = segments.findPoints(seg.id(), from, to);
        List<BikePoint> bike = new ArrayList<>();
        List<SegmentRepository.PointPrediction> predictions = new ArrayList<>(pts.size());
        for (SegmentPoint p : pts) {
            Verdict v = resolver.resolve(p.idx(), results);
            if (v == null) {
                continue;
            }
            predictions.add(new SegmentRepository.PointPrediction(
                    p.idx(), v.label(), v.probs().get(props.getBikeLabel()), v.modelVersion()));
            if (props.getBikeLabel().equals(v.label())) {
                bike.add(new BikePoint(p.ts(), p.lat(), p.lng(), v.modelVersion()));
            }
        }
        segments.savePredictions(seg.id(), predictions);
        tracks.insertBikePoints(seg.sessionId(), bike);
        log.debug("확정 segment={} [{}, {}) bike={}/{}", seg.id(), from, to, bike.size(), pts.size());
        return to;
    }
}
