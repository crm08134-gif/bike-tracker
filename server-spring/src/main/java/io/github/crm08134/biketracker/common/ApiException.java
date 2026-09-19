package io.github.crm08134.biketracker.common;

import org.springframework.http.HttpStatus;

public class ApiException extends RuntimeException {

    private final HttpStatus status;
    private final String error;
    private final boolean retryable;

    public ApiException(HttpStatus status, String error, String detail, boolean retryable) {
        super(detail);
        this.status = status;
        this.error = error;
        this.retryable = retryable;
    }

    public HttpStatus getStatus() { return status; }
    public String getError() { return error; }
    public boolean isRetryable() { return retryable; }

    public ApiError toBody() {
        return new ApiError(error, getMessage(), retryable);
    }
}
