package io.github.crm08134.biketracker.query;

import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import io.github.crm08134.biketracker.common.ApiException;
import io.github.crm08134.biketracker.ingest.SessionState;

@Service
public class PredictionService {

    private final PredictionRepository repo;

    public PredictionService(PredictionRepository repo) {
        this.repo = repo;
    }

    /**
     * 쿼리 네 개를 한 스냅숏에서 읽습니다. READ COMMITTED 면 쿼리 사이에 워커가 판정을 적어
     * 진행 숫자와 좌표 목록이 서로 다른 시점을 보여줄 수 있습니다.
     */
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public PredictionsResponse find(UUID sessionId) {
        SessionState state = repo.findSessionState(sessionId).orElseThrow(
                () -> new ApiException(HttpStatus.NOT_FOUND, "SESSION_NOT_FOUND", "없는 세션입니다", false));
        return new PredictionsResponse(
                sessionId,
                state,
                repo.progress(sessionId),
                repo.waitingBatches(sessionId),
                repo.findPoints(sessionId));
    }
}
