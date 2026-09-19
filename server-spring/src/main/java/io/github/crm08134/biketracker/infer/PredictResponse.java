package io.github.crm08134.biketracker.infer;

import java.util.Map;

public record PredictResponse(String modelVersion, String label, Map<String, Double> probs, Integer elapsedMs) {}
