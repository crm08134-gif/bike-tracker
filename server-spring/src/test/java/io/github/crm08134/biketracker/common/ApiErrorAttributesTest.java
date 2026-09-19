package io.github.crm08134.biketracker.common;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Map;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.web.error.ErrorAttributeOptions;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.ServletWebRequest;

import jakarta.servlet.RequestDispatcher;

/** 컨트롤러 밖에서 난 오류가 /error 로 넘어갔을 때의 본문. */
class ApiErrorAttributesTest {

    private final ApiErrorAttributes attributes = new ApiErrorAttributes();

    private Map<String, Object> render(int status) {
        MockHttpServletRequest req = new MockHttpServletRequest();
        req.setAttribute(RequestDispatcher.ERROR_STATUS_CODE, status);
        req.setAttribute(RequestDispatcher.ERROR_REQUEST_URI, "/api/v1/whatever");
        return attributes.getErrorAttributes(new ServletWebRequest(req), ErrorAttributeOptions.defaults());
    }

    @Test
    @DisplayName("4xx 는 retryable:false, error 는 코드")
    void clientError() {
        Map<String, Object> body = render(404);
        assertThat(body).containsEntry("error", "NOT_FOUND")
                .containsEntry("retryable", false)
                .containsEntry("path", "/api/v1/whatever")
                .containsKey("detail")
                .doesNotContainKey("timestamp");
    }

    @Test
    @DisplayName("5xx / 429 는 retryable:true")
    void retryableErrors() {
        assertThat(render(503)).containsEntry("retryable", true).containsEntry("error", "SERVICE_UNAVAILABLE");
        assertThat(render(500)).containsEntry("retryable", true);
        assertThat(render(429)).containsEntry("retryable", true);
        assertThat(render(413)).containsEntry("retryable", false);
    }
}
