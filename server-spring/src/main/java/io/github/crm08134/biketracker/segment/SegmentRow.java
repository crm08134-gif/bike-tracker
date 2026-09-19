package io.github.crm08134.biketracker.segment;

import java.util.UUID;

public record SegmentRow(
        long id,
        UUID sessionId,
        int idx,
        int pointCount,
        Long lastTs,
        int windowsDone,
        int flushedThrough,
        boolean closed) {

    /** 좌표 하나를 붙인 뒤의 상태. DB 반영은 배치 끝에 한 번만 합니다. */
    public SegmentRow withAppended(long ts) {
        return new SegmentRow(id, sessionId, idx, pointCount + 1, ts, windowsDone, flushedThrough, closed);
    }
}
