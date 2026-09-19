package io.github.crm08134.biketracker.segment;

import java.util.Map;

/** 좌표 하나에 대한 최종 판정. */
public record Verdict(String label, Map<String, Double> probs, String modelVersion) {}
