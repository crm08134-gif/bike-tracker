package io.github.crm08134.biketracker.ingest;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.regex.Pattern;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;

import io.github.crm08134.biketracker.config.TrackerProperties;

@ExtendWith(OutputCaptureExtension.class)
class SeqGapMonitorTest {

    private final SessionRepository sessions = mock(SessionRepository.class);
    private final SeqGapMonitor monitor = new SeqGapMonitor(sessions, new TrackerProperties());
    private final UUID sid = UUID.randomUUID();

    private SessionRepository.SeqGap gap(int missing) {
        return new SessionRepository.SeqGap(sid, SessionState.ACTIVE, missing, 3, missing + 1, Instant.EPOCH);
    }

    private static int count(String text, String needle) {
        return (int) Pattern.compile(Pattern.quote(needle)).matcher(text).results().count();
    }

    @Test
    @DisplayName("멈춘 자리 하나당 ERROR 1회, 풀리면 INFO 1회, 다른 자리에서 다시 멈추면 새로 ERROR")
    void logsOncePerGap(CapturedOutput out) {
        when(sessions.findSeqGaps(any())).thenReturn(List.of(gap(5)));
        monitor.scan();
        monitor.scan();
        monitor.scan();
        assertThat(count(out.getOut(), "seq 빈 자리로 반영 멈춤 session=" + sid)).isEqualTo(1);

        when(sessions.findSeqGaps(any())).thenReturn(List.of());
        monitor.scan();
        monitor.scan();
        assertThat(count(out.getOut(), "seq 빈 자리 해소 session=" + sid + " 기다리던_seq=5")).isEqualTo(1);

        when(sessions.findSeqGaps(any())).thenReturn(List.of(gap(9)));
        monitor.scan();
        monitor.scan();
        assertThat(count(out.getOut(), "seq 빈 자리로 반영 멈춤 session=" + sid)).isEqualTo(2);
        assertThat(out.getOut()).contains("기다리는_seq=9");
    }

    @Test
    @DisplayName("앞 자리가 풀리자마자 뒤에서 다시 멈추면 해소 INFO 와 새 ERROR 가 같이 남는다")
    void movedGap(CapturedOutput out) {
        when(sessions.findSeqGaps(any())).thenReturn(List.of(gap(5)));
        monitor.scan();
        when(sessions.findSeqGaps(any())).thenReturn(List.of(gap(8)));
        monitor.scan();

        assertThat(count(out.getOut(), "seq 빈 자리 해소 session=" + sid + " 기다리던_seq=5")).isEqualTo(1);
        assertThat(count(out.getOut(), "seq 빈 자리로 반영 멈춤 session=" + sid)).isEqualTo(2);
    }
}
