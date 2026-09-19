package io.github.crm08134.biketracker.infer;

import java.time.Duration;
import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpStatusCode;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import io.github.crm08134.biketracker.common.ApiError;
import io.github.crm08134.biketracker.config.TrackerProperties;

/**
 * Python 추론 서버 호출. 계획서 5절.
 *
 * <p>503 MODEL_NOT_READY 와 네트워크 오류는 재시도합니다. 422 는 우리 쪽 버그(200점이 아니거나
 * ts 가 어긋남)이므로 재시도하지 않고 터뜨립니다.
 */
@Component
public class InferenceClient {

    private static final Logger log = LoggerFactory.getLogger(InferenceClient.class);
    private static final ParameterizedTypeReference<List<PredictResponse>> LIST_OF_RESPONSES =
            new ParameterizedTypeReference<>() {};

    private final RestClient http;
    private final TrackerProperties.Inference cfg;

    /**
     * Boot 4 에서 RestTemplateBuilder 는 deprecated 이므로, 자동 설정된 RestClient.Builder 를 받습니다.
     * 타임아웃은 application.yml 의 spring.http.clients.* 에서 잡습니다. HTTP/1.1 고정은 HttpClientConfig.
     */
    public InferenceClient(RestClient.Builder builder, TrackerProperties props) {
        this.cfg = props.getInference();
        this.http = builder.clone().baseUrl(cfg.getBaseUrl()).build();
    }

    /** 모델 메타데이터. 여기서는 재시도하지 않습니다. 기동 대조가 직접 기다립니다. */
    public ModelInfo modelInfo() {
        return http.get()
                .uri("/v1/model")
                .exchange((req, res) -> handle(res, ModelInfo.class));
    }

    public PredictResponse predict(PredictRequest request) {
        return withRetry(() -> http.post()
                .uri("/v1/predict")
                .body(request)
                .exchange((req, res) -> handle(res, PredictResponse.class)));
    }

    /** 오프라인 백로그처럼 묶음이 한꺼번에 여러 개 밀렸을 때. 계획서 5절. */
    public List<PredictResponse> predictBatch(List<PredictRequest> requests) {
        return withRetry(() -> http.post()
                .uri("/v1/predict/batch")
                .body(requests)
                .exchange((req, res) -> handleList(res)));
    }

    private <T> T handle(RestClient.RequestHeadersSpec.ConvertibleClientHttpResponse res, Class<T> type) {
        try {
            HttpStatusCode status = res.getStatusCode();
            if (status.is2xxSuccessful()) {
                return res.bodyTo(type);
            }
            throw translate(status, res.bodyTo(ApiError.class));
        } catch (java.io.IOException e) {
            throw new InferenceUnavailableException("추론 응답을 읽지 못했습니다", e);
        }
    }

    private List<PredictResponse> handleList(RestClient.RequestHeadersSpec.ConvertibleClientHttpResponse res) {
        try {
            HttpStatusCode status = res.getStatusCode();
            if (status.is2xxSuccessful()) {
                return res.bodyTo(LIST_OF_RESPONSES);
            }
            throw translate(status, res.bodyTo(ApiError.class));
        } catch (java.io.IOException e) {
            throw new InferenceUnavailableException("추론 응답을 읽지 못했습니다", e);
        }
    }

    private RuntimeException translate(HttpStatusCode status, ApiError body) {
        String detail = body == null ? status.toString() : body.error() + " " + body.detail();
        boolean retryable = body != null ? body.retryable() : status.is5xxServerError();
        if (retryable) {
            return new InferenceUnavailableException("추론 서버 일시 오류: " + detail, null);
        }
        // 422 WINDOW_SIZE / NON_INCREASING_TS 는 우리가 보낸 묶음이 잘못된 것입니다.
        return new IllegalStateException("추론 요청이 거부됐습니다: " + detail);
    }

    private <T> T withRetry(java.util.function.Supplier<T> call) {
        RuntimeException last = null;
        for (int attempt = 1; attempt <= cfg.getMaxRetries(); attempt++) {
            try {
                return call.get();
            } catch (InferenceUnavailableException | RestClientException e) {
                last = e instanceof InferenceUnavailableException iue
                        ? iue
                        : new InferenceUnavailableException("추론 서버에 닿지 못했습니다", e);
                log.warn("추론 호출 실패 ({}/{}): {}", attempt, cfg.getMaxRetries(), e.getMessage());
                sleep(cfg.getRetryBackoff().multipliedBy(attempt));
            }
        }
        throw last;
    }

    private static void sleep(Duration d) {
        try {
            Thread.sleep(d.toMillis());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new InferenceUnavailableException("재시도 대기 중 중단됐습니다", e);
        }
    }
}
