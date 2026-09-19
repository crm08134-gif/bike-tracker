package io.github.crm08134.biketracker.segment;

import java.util.Map;

/** 묶음 하나의 추론 결과. */
public record WindowResult(int startIdx, String label, Map<String, Double> probs, String modelVersion) {}
