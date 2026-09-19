package io.github.crm08134.biketracker.query;

import java.util.List;
import java.util.UUID;

import io.github.crm08134.biketracker.ingest.SessionState;

/**
 * 주행 하나의 좌표별 판정. 주행이 끝난 뒤 앱이 새로고침을 눌렀을 때만 부릅니다.
 *
 * <p>페이지를 나누지 않습니다. 앱은 좌표 전부를 캐시로 통째로 바꾸고, 나눠 받으면 그 사이
 * 워커가 판정을 적어 페이지끼리·진행 숫자와 어긋납니다. 크기는 gzip(server.compression)으로 줄입니다.
 *
 * @param waitingBatches 서버가 받았지만 앞 번호 배치를 기다리느라 아직 좌표로 반영하지 못한 배치 수.
 *                       0 이 아니면 {@link Progress#totalPoints()} 가 나중에 늘어납니다.
 */
public record PredictionsResponse(
        UUID sessionId,
        SessionState sessionState,
        Progress progress,
        int waitingBatches,
        List<PredictedPoint> points) {

    /**
     * 판정 진행 상황. 대기 중 = total - predicted - unpredictable.
     *
     * @param totalPoints         필터(정확도 20m, ts 역행)를 통과해 저장된 좌표 수. 폰 좌표 수보다 적을 수 있습니다.
     * @param predictedPoints     판정이 적힌 좌표 수
     * @param unpredictablePoints 200점 묶음이 안 만들어져 버린 구간(segment.discarded)의 좌표 수.
     *                            300초 안에 늦은 좌표가 와서 구간이 다시 열리면 대기 중으로 돌아갑니다.
     */
    public record Progress(int totalPoints, int predictedPoints, int unpredictablePoints) {}

    /**
     * 좌표 하나. 판정 전이거나 판정 불가인 좌표는 predictedLabel · predictedProbBike 가 null 입니다.
     */
    public record PredictedPoint(long ts, double lat, double lng, String predictedLabel, Double predictedProbBike) {}
}
