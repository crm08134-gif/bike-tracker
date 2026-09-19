package io.github.crm08134.biketracker.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

import io.github.crm08134.biketracker.segment.OverlapStrategy;
import io.github.crm08134.biketracker.segment.WindowSpec;

@ConfigurationProperties(prefix = "tracker")
public class TrackerProperties {

    /** 이 값을 넘는 정확도(m)의 좌표는 버립니다. null 인 좌표도 버립니다. */
    private double accuracyLimitM = 20;

    /** 이 시간 이상 좌표가 끊기면 새 구간으로 나눕니다. */
    private long segmentGapMs = 300_000;

    private int windowSize = 200;
    private int stride = 100;

    private OverlapStrategy overlapStrategy = OverlapStrategy.AVERAGE_PROBS;
    private String bikeLabel = "bike";

    private Inference inference = new Inference();
    private Session session = new Session();
    private Worker worker = new Worker();

    public WindowSpec windowSpec() {
        return new WindowSpec(windowSize, stride);
    }

    public static class Inference {
        private String baseUrl = "http://inference:8000";
        private Duration connectTimeout = Duration.ofSeconds(2);
        private Duration readTimeout = Duration.ofSeconds(30);
        private int maxRetries = 3;
        private Duration retryBackoff = Duration.ofSeconds(1);
        private int batchThreshold = 2;
        private int maxBatchChunk = 120;
        private boolean verifyOnStartup = true;
        private Duration startupTimeout = Duration.ofSeconds(90);

        public String getBaseUrl() { return baseUrl; }
        public void setBaseUrl(String v) { this.baseUrl = v; }
        public Duration getConnectTimeout() { return connectTimeout; }
        public void setConnectTimeout(Duration v) { this.connectTimeout = v; }
        public Duration getReadTimeout() { return readTimeout; }
        public void setReadTimeout(Duration v) { this.readTimeout = v; }
        public int getMaxRetries() { return maxRetries; }
        public void setMaxRetries(int v) { this.maxRetries = v; }
        public Duration getRetryBackoff() { return retryBackoff; }
        public void setRetryBackoff(Duration v) { this.retryBackoff = v; }
        public int getBatchThreshold() { return batchThreshold; }
        public void setBatchThreshold(int v) { this.batchThreshold = v; }
        public int getMaxBatchChunk() { return maxBatchChunk; }
        public void setMaxBatchChunk(int v) { this.maxBatchChunk = v; }
        public boolean isVerifyOnStartup() { return verifyOnStartup; }
        public void setVerifyOnStartup(boolean v) { this.verifyOnStartup = v; }
        public Duration getStartupTimeout() { return startupTimeout; }
        public void setStartupTimeout(Duration v) { this.startupTimeout = v; }
    }

    public static class Session {
        private Duration abandonAfter = Duration.ofMinutes(15);
        /** next_seq 배치 없이 뒤 배치가 이만큼 기다리면 ERROR 로그를 남깁니다. */
        private Duration seqGapAlertAfter = Duration.ofMinutes(5);
        public Duration getAbandonAfter() { return abandonAfter; }
        public void setAbandonAfter(Duration v) { this.abandonAfter = v; }
        public Duration getSeqGapAlertAfter() { return seqGapAlertAfter; }
        public void setSeqGapAlertAfter(Duration v) { this.seqGapAlertAfter = v; }
    }

    public static class Worker {
        private Duration fixedDelay = Duration.ofSeconds(3);
        private Duration abandonScanDelay = Duration.ofMinutes(5);
        private Duration seqGapScanDelay = Duration.ofMinutes(5);
        private int batchSize = 20;
        public Duration getFixedDelay() { return fixedDelay; }
        public void setFixedDelay(Duration v) { this.fixedDelay = v; }
        public Duration getAbandonScanDelay() { return abandonScanDelay; }
        public void setAbandonScanDelay(Duration v) { this.abandonScanDelay = v; }
        public Duration getSeqGapScanDelay() { return seqGapScanDelay; }
        public void setSeqGapScanDelay(Duration v) { this.seqGapScanDelay = v; }
        public int getBatchSize() { return batchSize; }
        public void setBatchSize(int v) { this.batchSize = v; }
    }

    public double getAccuracyLimitM() { return accuracyLimitM; }
    public void setAccuracyLimitM(double v) { this.accuracyLimitM = v; }
    public long getSegmentGapMs() { return segmentGapMs; }
    public void setSegmentGapMs(long v) { this.segmentGapMs = v; }
    public int getWindowSize() { return windowSize; }
    public void setWindowSize(int v) { this.windowSize = v; }
    public int getStride() { return stride; }
    public void setStride(int v) { this.stride = v; }
    public OverlapStrategy getOverlapStrategy() { return overlapStrategy; }
    public void setOverlapStrategy(OverlapStrategy v) { this.overlapStrategy = v; }
    public String getBikeLabel() { return bikeLabel; }
    public void setBikeLabel(String v) { this.bikeLabel = v; }
    public Inference getInference() { return inference; }
    public void setInference(Inference v) { this.inference = v; }
    public Session getSession() { return session; }
    public void setSession(Session v) { this.session = v; }
    public Worker getWorker() { return worker; }
    public void setWorker(Worker v) { this.worker = v; }
}
