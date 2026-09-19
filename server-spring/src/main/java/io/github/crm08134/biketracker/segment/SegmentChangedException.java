package io.github.crm08134.biketracker.segment;

/**
 * 구간을 처리하는 도중 늦은 배치가 좌표를 붙였습니다. 트랜잭션을 되돌리고 다음 주기에 다시 처리합니다.
 * 오류가 아니라 정상적인 경합입니다.
 */
public class SegmentChangedException extends RuntimeException {
    public SegmentChangedException(long segmentId) {
        super("처리 중 구간이 바뀌었습니다 segment=" + segmentId);
    }
}
