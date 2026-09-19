package io.github.crm08134.biketracker.segment;

/**
 * 묶음 절단 규칙. 계획서 7절.
 *
 * <p>구간의 좌표 개수 n 에 대해 묶음은 0, stride, 2*stride ... 에서 시작하고
 * 시작점 + size 가 n 이하인 동안만 만들어집니다. n 이 size 보다 작으면 묶음은 0개이고,
 * 그 구간은 통째로 버립니다.
 *
 * <p>모든 인덱스는 구간 안에서의 0-based 순번입니다.
 */
public record WindowSpec(int size, int stride) {

    public WindowSpec {
        if (size <= 0 || stride <= 0) {
            throw new IllegalArgumentException("size 와 stride 는 양수여야 합니다");
        }
        if (stride > size) {
            throw new IllegalArgumentException("stride 가 size 보다 크면 좌표가 어느 묶음에도 안 들어갑니다");
        }
    }

    /** 좌표 n 개로 만들 수 있는 묶음 개수. */
    public int windowCount(int n) {
        return n < size ? 0 : (n - size) / stride + 1;
    }

    /** w 번째 묶음의 시작 인덱스. */
    public int startIdx(int w) {
        return w * stride;
    }

    /** w 번째 묶음의 끝 인덱스(exclusive). */
    public int endIdx(int w) {
        return w * stride + size;
    }

    /**
     * 묶음을 windowsDone 개까지 계산한 시점에, 판정이 더 바뀌지 않는 좌표의 개수(exclusive).
     *
     * <p>좌표 i 를 덮을 수 있는 마지막 묶음은 (i / stride) 번입니다. 그보다 뒤에서 시작하는
     * 묶음은 시작점이 i 보다 커서 i 를 포함하지 않습니다. 그래서 묶음 w 까지 끝났다면
     * i / stride <= w 인 좌표, 즉 i < (w + 1) * stride 인 좌표가 확정됩니다.
     */
    public int settledExclusive(int windowsDone) {
        return windowsDone * stride;
    }

    /** 좌표 i 를 덮는 첫 묶음 번호. */
    public int firstCoveringWindow(int idx) {
        return Math.max(0, Math.ceilDiv(idx - size + 1, stride));
    }

    /** 좌표 i 를 덮는 마지막 묶음 번호. 아직 안 만들어진 묶음은 제외합니다. */
    public int lastCoveringWindow(int idx, int windowsDone) {
        return Math.min(windowsDone - 1, idx / stride);
    }
}
