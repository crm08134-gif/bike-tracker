package io.github.crm08134.biketracker.ingest;

import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import io.github.crm08134.biketracker.ingest.dto.BatchRequest;
import io.github.crm08134.biketracker.ingest.dto.BatchResponse;

import jakarta.validation.Valid;

@RestController
@RequestMapping("/api/v1/sessions")
public class IngestController {

    private final IngestService ingest;

    public IngestController(IngestService ingest) {
        this.ingest = ingest;
    }

    /** 30초마다 오는 배치. 좌표만 받아 적고 바로 202 로 끊습니다. 추론은 뒤에서 돕니다. */
    @PostMapping("/{sessionId}/batches")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public BatchResponse receive(@PathVariable UUID sessionId, @Valid @RequestBody BatchRequest body) {
        return ingest.accept(sessionId, body);
    }

    /** 앱이 주행을 끝냈을 때. 열린 구간을 닫아 끝부분 규칙을 적용시킵니다. */
    @PostMapping("/{sessionId}/close")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public BatchResponse close(@PathVariable UUID sessionId) {
        return ingest.close(sessionId);
    }
}
