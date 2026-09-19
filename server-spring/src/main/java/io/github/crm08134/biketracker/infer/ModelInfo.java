package io.github.crm08134.biketracker.infer;

import java.util.List;

/**
 * GET /v1/model 응답 중 Spring 이 쓰는 값만. 나머지 필드는 무시합니다.
 * 값이 빠진 채로 오면 null 이고, 대조 검사에서 불일치로 봅니다.
 */
public record ModelInfo(
        String modelVersion,
        List<String> classes,
        Integer windowSize,
        Integer stride,
        Double accuracyLimit,
        Integer segGapSec,
        Integer maxBatchSize) {}
