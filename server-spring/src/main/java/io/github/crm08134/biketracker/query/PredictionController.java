package io.github.crm08134.biketracker.query;

import java.util.UUID;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/sessions")
public class PredictionController {

    private final PredictionService predictions;

    public PredictionController(PredictionService predictions) {
        this.predictions = predictions;
    }

    /** 주행이 끝난 뒤 보는 판정 결과. 앱은 새로고침 때만 부릅니다. */
    @GetMapping("/{sessionId}/predictions")
    public PredictionsResponse find(@PathVariable UUID sessionId) {
        return predictions.find(sessionId);
    }
}
