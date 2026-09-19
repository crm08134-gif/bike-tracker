package io.github.crm08134.biketracker.common;

import org.springframework.http.HttpStatus;

/**
 * 앱·추론 서버와 같은 오류 형식입니다. 계획서 5절.
 *
 * <p>모든 4xx/5xx 응답에 retryable 이 들어가야 합니다. 앱은 이 값만 보고 재시도 여부를 정하고,
 * 값이 없으면 4xx 를 재시도하지 않습니다(DEAD). 누락이 곧 데이터 손실입니다.
 */
public record ApiError(String error, String detail, boolean retryable) {

    /**
     * 우리가 직접 판단하지 않은 오류(프레임워크가 낸 오류)의 재시도 여부.
     * 5xx·408·429 는 시간이 지나면 풀릴 수 있어 true, 나머지 4xx 는 같은 요청을 다시 보내도
     * 똑같이 실패하므로 false 입니다.
     */
    public static boolean retryableFor(int status) {
        return status >= 500 || status == 408 || status == 429;
    }

    /** 프레임워크 오류의 error 코드. 400 은 우리 검증 오류와 같은 코드로 맞춥니다. */
    public static String codeFor(int status) {
        if (status == 400) {
            return "INVALID_REQUEST";
        }
        HttpStatus known = HttpStatus.resolve(status);
        return known != null ? known.name() : "HTTP_" + status;
    }
}
