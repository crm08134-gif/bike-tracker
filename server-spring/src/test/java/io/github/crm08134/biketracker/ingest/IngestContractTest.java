package io.github.crm08134.biketracker.ingest;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.UUID;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import io.github.crm08134.biketracker.ingest.dto.BatchRequest;
import io.github.crm08134.biketracker.ingest.dto.BatchResponse;
import io.github.crm08134.biketracker.ingest.dto.PointDto;

/**
 * 앱이 실제로 보내는 JSON 이 Spring 에 어떻게 들어오는지, 오류 응답에 retryable 이 붙는지 검증합니다.
 * application.yml 의 spring.jackson.* 설정이 그대로 적용된 상태에서 돕니다.
 */
@WebMvcTest(IngestController.class)
class IngestContractTest {

    private static final UUID SID = UUID.fromString("0f8fad5b-d9cb-469f-a165-70867728950e");
    private static final String PATH = "/api/v1/sessions/" + SID + "/batches";

    @Autowired MockMvc mvc;
    @MockitoBean IngestService ingest;

    /** 수정된 앱의 ApiClient.postBatch 가 실제로 만든 본문을 뽑아 그대로 붙였습니다. */
    private static final String APP_BODY = """
            {
              "user_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
              "device_id": "16fd2706-8baf-433b-82eb-8c7fada847da",
              "seq": 0,
              "is_last_batch": false,
              "sent_at": 1789285484199,
              "points": [
                {"ts": 1757750400000, "lat": 37.56653512345679, "lng": 126.97796998765432,
                 "acc": 4.5, "spd": 5.25, "alt": 38.7, "label": "BIKE"},
                {"ts": 1757750401000, "lat": 37.5665361, "lng": 126.9779701, "label": "NONE"}
              ]
            }
            """;

    @Test
    @DisplayName("SNAKE_CASE 가 실행 시 적용된다: 앱 본문이 필드 손실 없이 DTO 로 들어온다")
    void snakeCaseBindsAppBody() throws Exception {
        when(ingest.accept(eq(SID), any())).thenReturn(new BatchResponse(SessionState.ACTIVE, 1));

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(APP_BODY))
                .andExpect(status().isAccepted())
                // 응답도 snake_case 로 나간다
                .andExpect(jsonPath("$.session_state").value("ACTIVE"))
                .andExpect(jsonPath("$.next_seq").value(1))
                .andExpect(jsonPath("$.sessionState").doesNotExist());

        ArgumentCaptor<BatchRequest> captor = ArgumentCaptor.forClass(BatchRequest.class);
        verify(ingest).accept(eq(SID), captor.capture());
        BatchRequest req = captor.getValue();

        assertThat(req.deviceId()).isEqualTo("16fd2706-8baf-433b-82eb-8c7fada847da");
        assertThat(req.seq()).isZero();
        assertThat(req.isLastBatch()).isFalse();
        assertThat(req.points()).hasSize(2);

        PointDto p = req.points().get(0);
        assertThat(p.ts()).isEqualTo(1757750400000L);
        // Dart double 이 찍은 최단 표현이 Java double 로 비트 그대로 돌아와야 한다
        assertThat(p.lat()).isEqualTo(37.56653512345679);
        assertThat(p.lng()).isEqualTo(126.97796998765432);
        assertThat(p.acc()).isEqualTo(4.5f);
        assertThat(p.label()).isEqualTo("BIKE");

        // null 필드를 뺀 점도 들어온다
        PointDto q = req.points().get(1);
        assertThat(q.acc()).isNull();
        assertThat(q.label()).isEqualTo("NONE");
    }

    @Test
    @DisplayName("device_id 가 없으면 400 + retryable:false")
    void missingDeviceId() throws Exception {
        String body = APP_BODY.replace("\"device_id\": \"16fd2706-8baf-433b-82eb-8c7fada847da\",", "");

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("INVALID_REQUEST"))
                .andExpect(jsonPath("$.retryable").value(false));
        verify(ingest, never()).accept(any(), any());
    }

    @Test
    @DisplayName("빈 points 는 is_last_batch:true 일 때만 허용")
    void emptyPointsOnlyOnLastBatch() throws Exception {
        String empty = """
                {"device_id": "d", "seq": 3, "is_last_batch": %s, "points": []}
                """;
        when(ingest.accept(eq(SID), any())).thenReturn(new BatchResponse(SessionState.CLOSED, 4));

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(empty.formatted("false")))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.retryable").value(false));

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(
                        "{\"device_id\": \"d\", \"seq\": 3, \"points\": []}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.retryable").value(false));

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(empty.formatted("true")))
                .andExpect(status().isAccepted())
                .andExpect(jsonPath("$.session_state").value("CLOSED"));
    }

    @Test
    @DisplayName("점 안의 필수 필드(lat)가 빠져도 400 + retryable:false (points 요소까지 검증된다)")
    void pointFieldValidated() throws Exception {
        String body = APP_BODY.replace("\"lat\": 37.5665361, ", "");

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("INVALID_REQUEST"))
                .andExpect(jsonPath("$.detail").value(org.hamcrest.Matchers.containsString("points[1].lat")))
                .andExpect(jsonPath("$.retryable").value(false));
        verify(ingest, never()).accept(any(), any());
    }

    @Test
    @DisplayName("옛 경로(/api/v1/batches)는 404 + retryable 포함")
    void unknownPath() throws Exception {
        mvc.perform(post("/api/v1/batches").contentType(MediaType.APPLICATION_JSON).content(APP_BODY))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("NOT_FOUND"))
                .andExpect(jsonPath("$.retryable").value(false));
    }

    @Test
    @DisplayName("본문 파싱 실패는 400 + retryable 포함")
    void malformedJson() throws Exception {
        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content("{\"device_id\": "))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("INVALID_REQUEST"))
                .andExpect(jsonPath("$.retryable").value(false));

        // 타입 불일치 (seq 가 문자열)
        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"device_id\": \"d\", \"seq\": \"zero\", \"points\": []}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.retryable").value(false));
    }

    @Test
    @DisplayName("경로의 session_id 가 UUID 가 아니면 400 + retryable 포함")
    void invalidSessionId() throws Exception {
        mvc.perform(post("/api/v1/sessions/not-a-uuid/batches")
                        .contentType(MediaType.APPLICATION_JSON).content(APP_BODY))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.retryable").value(false));
    }

    @Test
    @DisplayName("지원하지 않는 Content-Type / 메서드도 retryable 포함")
    void mediaTypeAndMethod() throws Exception {
        mvc.perform(post(PATH).contentType(MediaType.TEXT_PLAIN).content(APP_BODY))
                .andExpect(status().isUnsupportedMediaType())
                .andExpect(jsonPath("$.retryable").value(false));

        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get(PATH))
                .andExpect(status().isMethodNotAllowed())
                .andExpect(jsonPath("$.retryable").value(false));
    }

    @Test
    @DisplayName("예상 못 한 예외는 500 + retryable:true")
    void unexpectedIsRetryable() throws Exception {
        when(ingest.accept(eq(SID), any())).thenThrow(new IllegalStateException("db down"));

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(APP_BODY))
                .andExpect(status().isInternalServerError())
                .andExpect(jsonPath("$.error").value("INTERNAL_ERROR"))
                .andExpect(jsonPath("$.retryable").value(true));
    }
}
