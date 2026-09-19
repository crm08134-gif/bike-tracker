package io.github.crm08134.biketracker.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.context.request.WebRequest;
import org.springframework.web.servlet.mvc.method.annotation.ResponseEntityExceptionHandler;

/**
 * 컨트롤러까지 온 요청의 모든 오류를 {@link ApiError} 로 바꿉니다.
 *
 * <p>ResponseEntityExceptionHandler 를 상속해 404(경로 없음)·405·415·본문 파싱 실패·경로 변수
 * 형 변환 실패 같은 프레임워크 오류도 같은 형식으로 나가게 합니다. 컨트롤러 밖(필터, 컨테이너)에서
 * 난 오류는 {@link ApiErrorAttributes} 가 맡습니다.
 */
@RestControllerAdvice
public class GlobalExceptionHandler extends ResponseEntityExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);
    private static final int DETAIL_MAX = 300;

    @ExceptionHandler(ApiException.class)
    public ResponseEntity<ApiError> handleApi(ApiException e) {
        return ResponseEntity.status(e.getStatus()).body(e.toBody());
    }

    /** 어디서도 잡지 않은 예외. DB 연결 끊김 같은 일시 장애일 수 있어 재시도하게 둡니다. */
    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiError> handleUnexpected(Exception e) {
        log.error("처리하지 못한 예외", e);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body(new ApiError("INTERNAL_ERROR", "서버 내부 오류", true));
    }

    @Override
    protected ResponseEntity<Object> handleMethodArgumentNotValid(
            MethodArgumentNotValidException e, HttpHeaders headers, HttpStatusCode status, WebRequest request) {
        String detail = e.getBindingResult().getAllErrors().stream()
                .findFirst()
                .map(err -> err instanceof org.springframework.validation.FieldError f
                        ? snake(f.getField()) + ": " + f.getDefaultMessage()
                        : err.getDefaultMessage())
                .orElse("요청 형식이 올바르지 않습니다");
        log.warn("요청 검증 실패 {}", detail);
        return ResponseEntity.badRequest().body(new ApiError("INVALID_REQUEST", detail, false));
    }

    /** 나머지 프레임워크 오류 전부가 여기로 모입니다. 본문을 ApiError 로 갈아 끼웁니다. */
    @Override
    protected ResponseEntity<Object> handleExceptionInternal(
            Exception e, Object body, HttpHeaders headers, HttpStatusCode status, WebRequest request) {
        int code = status.value();
        String detail = code >= 500 ? "서버 내부 오류" : describe(e);
        if (code >= 500) {
            log.error("프레임워크 오류 status={}", code, e);
        } else {
            log.warn("요청 거부 status={} {}: {}", code, e.getClass().getSimpleName(), detail);
        }
        ApiError error = new ApiError(ApiError.codeFor(code), detail, ApiError.retryableFor(code));
        return ResponseEntity.status(status).headers(headers).body(error);
    }

    /** 앱이 보는 이름으로 알려 줍니다. points[0].acc 같은 경로는 그대로 둡니다. */
    private static String snake(String field) {
        return field.replaceAll("([a-z0-9])([A-Z])", "$1_$2").toLowerCase();
    }

    private static String describe(Exception e) {
        String message = e instanceof HttpMessageNotReadableException r && r.getMostSpecificCause() != null
                ? r.getMostSpecificCause().getMessage()
                : e.getMessage();
        if (message == null) {
            return e.getClass().getSimpleName();
        }
        return message.length() > DETAIL_MAX ? message.substring(0, DETAIL_MAX) + "..." : message;
    }
}
