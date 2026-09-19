package io.github.crm08134.biketracker.segment;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import io.github.crm08134.biketracker.config.TrackerProperties;

class VerdictResolverTest {

    private static final String MV = "korea_ft_fixed+sha256:test";

    private static WindowResult window(int startIdx, double bike, double walk) {
        return new WindowResult(startIdx, bike >= walk ? "bike" : "walk",
                Map.of("bike", bike, "walk", walk, "bus", 0.0, "car", 0.0, "subway", 0.0), MV);
    }

    private static VerdictResolver resolver(OverlapStrategy strategy) {
        TrackerProperties props = new TrackerProperties();
        props.setOverlapStrategy(strategy);
        return new VerdictResolver(props);
    }

    /** 450점 구간: 묶음 0(bike), 1(walk 우세), 2(bike). */
    private static final List<WindowResult> WINDOWS = List.of(
            window(0, 0.90, 0.10),
            window(100, 0.40, 0.60),
            window(200, 0.95, 0.05));

    @Test
    @DisplayName("겹치지 않는 앞쪽 좌표는 첫 묶음 판정을 그대로 받는다")
    void singleCoverage() {
        assertThat(resolver(OverlapStrategy.AVERAGE_PROBS).resolve(50, WINDOWS).label()).isEqualTo("bike");
    }

    @Test
    @DisplayName("겹친 좌표는 두 묶음 확률의 평균으로 정한다")
    void averagesOverlap() {
        // 좌표 150 은 묶음 0(bike 0.90) 과 1(bike 0.40) 에 겹칩니다. 평균 0.65 > walk 0.35.
        Verdict v = resolver(OverlapStrategy.AVERAGE_PROBS).resolve(150, WINDOWS);
        assertThat(v.label()).isEqualTo("bike");
        assertThat(v.probs().get("bike")).isEqualTo(0.65);
    }

    @Test
    @DisplayName("STRICT_BIKE 는 겹친 묶음이 전부 bike 여야 bike 로 둔다")
    void strictBikeDropsMixedOverlap() {
        assertThat(resolver(OverlapStrategy.STRICT_BIKE).resolve(150, WINDOWS).label()).isEqualTo("walk");
        // 좌표 250 은 묶음 1(walk) 과 2(bike) 겹침 → 역시 bike 가 아닙니다.
        assertThat(resolver(OverlapStrategy.STRICT_BIKE).resolve(250, WINDOWS).label()).isNotEqualTo("bike");
    }

    @Test
    @DisplayName("LATEST_WINDOW 는 나중 묶음을 그대로 쓴다")
    void latestWindowWins() {
        assertThat(resolver(OverlapStrategy.LATEST_WINDOW).resolve(150, WINDOWS).label()).isEqualTo("walk");
        assertThat(resolver(OverlapStrategy.LATEST_WINDOW).resolve(250, WINDOWS).label()).isEqualTo("bike");
    }

    @Test
    @DisplayName("끝부분 50점은 마지막 묶음의 판정을 그대로 받는다")
    void tailInheritsLastWindow() {
        for (int idx : new int[] {400, 425, 449}) {
            Verdict v = resolver(OverlapStrategy.AVERAGE_PROBS).resolve(idx, WINDOWS);
            assertThat(v.label()).isEqualTo("bike");
            assertThat(v.probs().get("bike")).isEqualTo(0.95);
        }
    }

    @Test
    @DisplayName("묶음이 하나도 없으면 판정이 없다 (짧은 구간)")
    void noWindowsMeansNoVerdict() {
        assertThat(resolver(OverlapStrategy.AVERAGE_PROBS).resolve(10, List.of())).isNull();
    }
}
