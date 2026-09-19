package io.github.crm08134.biketracker.config;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

/** application.yml / application-local.yml 이 어느 주소를 보게 되는지. 빈은 하나도 안 띄웁니다. */
class ProfileConfigTest {

    @Configuration(proxyBeanMethods = false)
    static class Empty {}

    private static String[] resolve(String... profiles) {
        try (ConfigurableApplicationContext ctx = new SpringApplicationBuilder(Empty.class)
                .web(WebApplicationType.NONE)
                .profiles(profiles)
                .logStartupInfo(false)
                .run()) {
            Environment env = ctx.getEnvironment();
            return new String[] {
                    env.getProperty("spring.datasource.url"),
                    env.getProperty("tracker.inference.base-url"),
                    env.getProperty("tracker.inference.max-batch-chunk"),
            };
        }
    }

    @Test
    @DisplayName("기본(compose 네트워크): postgis:5432, inference:8000")
    void defaults() {
        // 환경 변수(DB_HOST, INFERENCE_URL 등)가 없는 상태를 전제로 합니다.
        String[] v = resolve();
        assertThat(v[0]).isEqualTo("jdbc:postgresql://postgis:5432/biketracker");
        assertThat(v[1]).isEqualTo("http://inference:8000");
        assertThat(v[2]).isEqualTo("120");
    }

    @Test
    @DisplayName("local 프로필: localhost:5433, localhost:8000")
    void local() {
        String[] v = resolve("local");
        assertThat(v[0]).isEqualTo("jdbc:postgresql://localhost:5433/biketracker");
        assertThat(v[1]).isEqualTo("http://localhost:8000");
    }
}
