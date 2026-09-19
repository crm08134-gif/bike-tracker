package io.github.crm08134.biketracker.infer;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClientException;

import io.github.crm08134.biketracker.config.TrackerProperties;

/**
 * 기동 시 GET /v1/model 로 전처리 값을 대조합니다. 다르면 기동을 거부합니다.
 *
 * <p>window_size / stride / accuracy_limit 이 학습 때와 다르면 추론은 에러 없이 돌지만 판정이 조용히
 * 틀립니다. 그래서 하나라도 다르면 뜨지 않습니다. 모든 빈이 만들어진 직후, 웹 서버가 요청을 받기
 * 전에 돌므로 잘못된 설정으로는 배치를 한 건도 받지 않습니다.
 *
 * <p>대조가 끝나면 서버가 알려준 max_batch_size 를 들고 있다가 배치 분할에 씁니다.
 */
@Component
public class InferenceModelGuard implements SmartInitializingSingleton {

    private static final Logger log = LoggerFactory.getLogger(InferenceModelGuard.class);
    private static final Duration POLL = Duration.ofSeconds(2);

    private final InferenceClient client;
    private final TrackerProperties props;
    private volatile ModelInfo model;

    public InferenceModelGuard(InferenceClient client, TrackerProperties props) {
        this.client = client;
        this.props = props;
    }

    @Override
    public void afterSingletonsInstantiated() {
        TrackerProperties.Inference cfg = props.getInference();
        if (!cfg.isVerifyOnStartup()) {
            log.warn("추론 서버 모델 대조를 건너뜁니다 (tracker.inference.verify-on-startup=false). "
                    + "배치 분할은 max-batch-chunk={} 만 적용합니다", cfg.getMaxBatchChunk());
            return;
        }

        ModelInfo info = fetch(cfg.getStartupTimeout());
        List<String> mismatches = mismatches(info, props);
        if (!mismatches.isEmpty()) {
            for (String m : mismatches) {
                log.error("추론 서버 모델 설정 불일치: {}", m);
            }
            throw new IllegalStateException("추론 서버(" + cfg.getBaseUrl() + ")의 모델 설정이 application.yml 과 "
                    + "다릅니다. 기동을 거부합니다. " + String.join(" / ", mismatches));
        }
        this.model = info;
        log.info("추론 서버 모델 대조 통과 model_version={} window_size={} stride={} accuracy_limit={} "
                        + "seg_gap_sec={} max_batch_size={} -> 배치 분할 크기 {}",
                info.modelVersion(), info.windowSize(), info.stride(), info.accuracyLimit(),
                info.segGapSec(), info.maxBatchSize(), batchChunkSize());
    }

    /**
     * 한 번에 추론 서버로 보낼 묶음 수. {@code min(max_batch_size, tracker.inference.max-batch-chunk)}.
     * 대조를 건너뛰었으면 max-batch-chunk 만 씁니다.
     */
    public int batchChunkSize() {
        int configured = props.getInference().getMaxBatchChunk();
        ModelInfo m = model;
        Integer server = m == null ? null : m.maxBatchSize();
        int size = server == null ? configured : Math.min(server, configured);
        return Math.max(1, size);
    }

    /** 어느 항목이 어느 쪽에서 뭐라고 했는지. 모두 같으면 빈 목록. */
    static List<String> mismatches(ModelInfo info, TrackerProperties props) {
        List<String> out = new ArrayList<>();
        check(out, "window_size", "tracker.window-size", props.getWindowSize(), info.windowSize());
        check(out, "stride", "tracker.stride", props.getStride(), info.stride());
        if (info.accuracyLimit() == null || Double.compare(props.getAccuracyLimitM(), info.accuracyLimit()) != 0) {
            out.add(line("accuracy_limit", "tracker.accuracy-limit-m", props.getAccuracyLimitM(), info.accuracyLimit()));
        }
        // application.yml 주석이 "반드시 같아야 하는 네 값"으로 묶어 둔 값입니다. 서버는 초, 여기는 ms 입니다.
        Long serverGapMs = info.segGapSec() == null ? null : info.segGapSec() * 1000L;
        check(out, "seg_gap_sec(ms 환산)", "tracker.segment-gap-ms", props.getSegmentGapMs(), serverGapMs);
        // bike-label 이 모델 클래스에 없으면 어떤 좌표도 bike 로 판정되지 않습니다.
        if (info.classes() == null || !info.classes().contains(props.getBikeLabel())) {
            out.add(line("classes", "tracker.bike-label", props.getBikeLabel(), info.classes()));
        }
        return out;
    }

    private static void check(List<String> out, String field, String key, Object local, Object server) {
        if (server == null || !Objects.equals(String.valueOf(local), String.valueOf(server))) {
            out.add(line(field, key, local, server));
        }
    }

    private static String line(String field, String key, Object local, Object server) {
        return "항목=" + field + " application.yml(" + key + ")=" + local
                + " 추론서버(/v1/model)=" + (server == null ? "(없음)" : server);
    }

    /** 모델 로드 중(503 retryable)이거나 아직 안 떴으면 timeout 까지 기다립니다. */
    private ModelInfo fetch(Duration timeout) {
        Instant deadline = Instant.now().plus(timeout);
        while (true) {
            try {
                return client.modelInfo();
            } catch (InferenceUnavailableException | RestClientException e) {
                if (Instant.now().isAfter(deadline)) {
                    throw new IllegalStateException("추론 서버(" + props.getInference().getBaseUrl() + ")에서 "
                            + timeout.toSeconds() + "초 안에 /v1/model 을 받지 못했습니다. "
                            + "모델 설정을 대조할 수 없어 기동을 거부합니다", e);
                }
                log.warn("추론 서버 /v1/model 대기 중: {}", e.getMessage());
                try {
                    Thread.sleep(POLL.toMillis());
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException("추론 서버 대기 중 중단됐습니다", ie);
                }
            }
        }
    }
}
