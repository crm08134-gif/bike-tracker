package io.github.crm08134.biketracker.infer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.time.Duration;
import java.util.List;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;

import io.github.crm08134.biketracker.config.TrackerProperties;

@ExtendWith(OutputCaptureExtension.class)
class InferenceModelGuardTest {

    private static final List<String> CLASSES = List.of("bike", "bus", "car", "subway", "walk");

    private static ModelInfo server(int window, int stride, double acc, int maxBatch) {
        return new ModelInfo("v", CLASSES, window, stride, acc, 300, maxBatch);
    }

    @Test
    @DisplayName("값이 모두 같으면 통과하고, 분할 크기는 min(max_batch_size, max-batch-chunk)")
    void passAndChunk() {
        TrackerProperties props = new TrackerProperties();
        InferenceClient client = mock(InferenceClient.class);
        when(client.modelInfo()).thenReturn(server(200, 100, 20, 256));
        InferenceModelGuard guard = new InferenceModelGuard(client, props);

        // 대조 전에는 설정값만
        assertThat(guard.batchChunkSize()).isEqualTo(120);
        guard.afterSingletonsInstantiated();
        assertThat(guard.batchChunkSize()).isEqualTo(120);

        when(client.modelInfo()).thenReturn(server(200, 100, 20, 64));
        guard.afterSingletonsInstantiated();
        assertThat(guard.batchChunkSize()).isEqualTo(64);
    }

    @Test
    @DisplayName("다르면 기동을 거부하고, 로그에 항목명과 양쪽 값이 모두 찍힌다")
    void refuseOnMismatch(CapturedOutput out) {
        TrackerProperties props = new TrackerProperties();
        InferenceClient client = mock(InferenceClient.class);
        when(client.modelInfo()).thenReturn(server(180, 90, 25, 256));
        InferenceModelGuard guard = new InferenceModelGuard(client, props);

        assertThatThrownBy(guard::afterSingletonsInstantiated)
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("기동을 거부합니다");

        assertThat(out.getOut())
                .contains("항목=window_size application.yml(tracker.window-size)=200 추론서버(/v1/model)=180")
                .contains("항목=stride application.yml(tracker.stride)=100 추론서버(/v1/model)=90")
                .contains("항목=accuracy_limit application.yml(tracker.accuracy-limit-m)=20.0 추론서버(/v1/model)=25.0");
    }

    @Test
    @DisplayName("응답에 값이 빠졌거나 bike-label 이 클래스에 없어도 불일치")
    void missingValues() {
        TrackerProperties props = new TrackerProperties();
        List<String> m = InferenceModelGuard.mismatches(
                new ModelInfo("v", List.of("walk"), null, 100, 20.0, 300, 256), props);
        assertThat(m).hasSize(2);
        assertThat(m.get(0)).contains("window_size", "(없음)");
        assertThat(m.get(1)).contains("classes", "tracker.bike-label", "bike", "[walk]");
    }

    @Test
    @DisplayName("seg_gap_sec 는 ms 로 환산해 대조한다")
    void segGap() {
        TrackerProperties props = new TrackerProperties();
        assertThat(InferenceModelGuard.mismatches(new ModelInfo("v", CLASSES, 200, 100, 20.0, 300, 256), props)).isEmpty();
        assertThat(InferenceModelGuard.mismatches(new ModelInfo("v", CLASSES, 200, 100, 20.0, 600, 256), props))
                .singleElement().asString()
                .contains("seg_gap_sec(ms 환산) application.yml(tracker.segment-gap-ms)=300000 추론서버(/v1/model)=600000");
    }

    @Test
    @DisplayName("추론 서버에 닿지 않으면 timeout 뒤 기동 거부")
    void unreachable() {
        TrackerProperties props = new TrackerProperties();
        props.getInference().setStartupTimeout(Duration.ZERO);
        InferenceClient client = mock(InferenceClient.class);
        when(client.modelInfo()).thenThrow(new InferenceUnavailableException("연결 거부", null));

        assertThatThrownBy(() -> new InferenceModelGuard(client, props).afterSingletonsInstantiated())
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("/v1/model 을 받지 못했습니다");
    }
}
