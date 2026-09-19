package io.github.crm08134.biketracker.ingest.dto;

import java.util.List;

import com.fasterxml.jackson.annotation.JsonIgnore;

import jakarta.validation.Valid;
import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;

/**
 * 앱이 30초마다 보내는 배치. session_id 는 경로로 받습니다.
 *
 * @param isLastBatch 앱이 주행을 끝냈다는 표시. 이 배치가 순서대로 반영되는 시점에 세션을 닫습니다.
 *                    없으면 false 로 봅니다.
 */
public record BatchRequest(
        @NotNull String deviceId,
        @NotNull @Min(0) Integer seq,
        Boolean isLastBatch,
        @NotNull List<@Valid PointDto> points) {

    public boolean lastBatch() {
        return Boolean.TRUE.equals(isLastBatch);
    }

    /**
     * 빈 points 는 마지막 배치일 때만 허용합니다. 좌표를 하나도 못 받고 끝난 주행의 종료 신호가
     * 이 모양으로 옵니다.
     *
     * <p>JsonIgnore 가 없으면 Jackson 이 이 메서드를 속성으로 보고 raw_batch payload 에 적습니다.
     */
    @JsonIgnore
    @AssertTrue(message = "is_last_batch 가 true 가 아니면 points 가 비어 있을 수 없습니다")
    public boolean isPointsPresentUnlessLast() {
        return points == null || !points.isEmpty() || lastBatch();
    }
}
