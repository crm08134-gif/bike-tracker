package io.github.crm08134.biketracker.infer;

/** 지금은 실패했지만 다시 걸면 될 오류. 워커가 이 구간을 다음 주기로 미룹니다. */
public class InferenceUnavailableException extends RuntimeException {
    public InferenceUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
