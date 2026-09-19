package io.github.crm08134.biketracker.segment;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/** 계획서 7절 그림(좌표 450개 구간)을 그대로 검증합니다. */
class WindowSpecTest {

    private final WindowSpec spec = new WindowSpec(200, 100);

    @Test
    @DisplayName("450점이면 묶음 3개, 끝부분 50점")
    void figureFromSection7() {
        assertThat(spec.windowCount(450)).isEqualTo(3);
        assertThat(spec.startIdx(0)).isZero();
        assertThat(spec.startIdx(1)).isEqualTo(100);
        assertThat(spec.startIdx(2)).isEqualTo(200);
        assertThat(spec.endIdx(2)).isEqualTo(400);

        int tail = 450 - spec.endIdx(spec.windowCount(450) - 1);
        assertThat(tail).isEqualTo(50);
    }

    @Test
    @DisplayName("200점 미만 구간은 묶음이 0개라 통째로 버려진다")
    void shortSegmentHasNoWindows() {
        assertThat(spec.windowCount(0)).isZero();
        assertThat(spec.windowCount(199)).isZero();
        assertThat(spec.windowCount(200)).isEqualTo(1);
    }

    @Test
    @DisplayName("묶음이 하나 늘 때마다 좌표 100개가 확정된다")
    void settledAdvancesByStride() {
        assertThat(spec.settledExclusive(0)).isZero();
        assertThat(spec.settledExclusive(1)).isEqualTo(100);
        assertThat(spec.settledExclusive(3)).isEqualTo(300);
    }

    @Test
    @DisplayName("가운데 좌표는 두 묶음에, 앞뒤 좌표는 한 묶음에만 들어간다")
    void coveringWindows() {
        // 좌표 50: 묶음 0 만
        assertThat(spec.firstCoveringWindow(50)).isZero();
        assertThat(spec.lastCoveringWindow(50, 3)).isZero();

        // 좌표 150: 묶음 0 과 1
        assertThat(spec.firstCoveringWindow(150)).isZero();
        assertThat(spec.lastCoveringWindow(150, 3)).isEqualTo(1);

        // 좌표 250: 묶음 1 과 2
        assertThat(spec.firstCoveringWindow(250)).isEqualTo(1);
        assertThat(spec.lastCoveringWindow(250, 3)).isEqualTo(2);

        // 좌표 420 (끝부분): 덮는 묶음이 없습니다. first > last.
        assertThat(spec.firstCoveringWindow(420)).isEqualTo(3);
        assertThat(spec.lastCoveringWindow(420, 3)).isEqualTo(2);
    }

    @Test
    @DisplayName("stride 가 size 보다 크면 좌표가 새어나가므로 막는다")
    void rejectsStrideLargerThanSize() {
        org.junit.jupiter.api.Assertions.assertThrows(
                IllegalArgumentException.class, () -> new WindowSpec(200, 300));
    }
}
