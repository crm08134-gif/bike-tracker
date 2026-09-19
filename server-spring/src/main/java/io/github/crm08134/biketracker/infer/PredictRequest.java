package io.github.crm08134.biketracker.infer;

import java.util.List;
import java.util.UUID;

/** 계획서 5절의 요청 형식. 모델이 쓰는 건 ts·lat·lng 뿐입니다. */
public record PredictRequest(UUID sessionId, long windowStartTs, List<Point> points) {

    public record Point(long ts, double lat, double lng) {}
}
