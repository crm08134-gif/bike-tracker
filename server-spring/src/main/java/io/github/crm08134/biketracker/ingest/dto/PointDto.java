package io.github.crm08134.biketracker.ingest.dto;

import jakarta.validation.constraints.NotNull;

/**
 * 앱이 보내는 좌표 하나. 모델이 쓰는 건 ts·lat·lng 뿐이고 acc 는 필터에만 씁니다.
 * spd·alt 는 받되 무시합니다.
 *
 * <p>label 은 사용자가 직접 고른 정답 라벨(NONE / BIKE / WALK / OTHER)입니다. 판정에는 쓰지 않고
 * gps_point 에 그대로 적어, 나중에 모델 판정과 비교하는 데 씁니다.
 */
public record PointDto(
        @NotNull Long ts,
        @NotNull Double lat,
        @NotNull Double lng,
        Float acc,
        Float spd,
        Float alt,
        String label) {}
