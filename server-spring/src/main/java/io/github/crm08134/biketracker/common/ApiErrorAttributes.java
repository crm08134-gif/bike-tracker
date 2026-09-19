package io.github.crm08134.biketracker.common;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.boot.web.error.ErrorAttributeOptions;
import org.springframework.boot.webmvc.error.DefaultErrorAttributes;
import org.springframework.stereotype.Component;
import org.springframework.web.context.request.WebRequest;

/**
 * 컨트롤러 밖에서 난 오류(필터, 컨테이너, /error 로 넘어간 요청)의 기본 응답 본문을 {@link ApiError}
 * 형식으로 바꿉니다. Boot 기본 본문은 {timestamp, status, error: "Not Found", path} 라 retryable 이
 * 없고, error 에 코드가 아닌 사유 문구가 들어갑니다.
 *
 * <p>이 빈이 있으면 Boot 는 DefaultErrorAttributes 를 따로 만들지 않습니다.
 */
@Component
public class ApiErrorAttributes extends DefaultErrorAttributes {

    @Override
    public Map<String, Object> getErrorAttributes(WebRequest request, ErrorAttributeOptions options) {
        Map<String, Object> base = super.getErrorAttributes(request,
                options.including(ErrorAttributeOptions.Include.MESSAGE));
        int status = base.get("status") instanceof Integer s ? s : 500;

        Object message = base.get("message");
        String detail = status >= 500 || message == null || "".equals(message) || "No message available".equals(message)
                ? String.valueOf(base.getOrDefault("error", "HTTP " + status))
                : String.valueOf(message);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("error", ApiError.codeFor(status));
        body.put("detail", detail);
        body.put("retryable", ApiError.retryableFor(status));
        body.put("path", base.get("path"));
        return body;
    }
}
