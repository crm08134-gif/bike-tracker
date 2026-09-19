package io.github.crm08134.biketracker.config;

import java.net.http.HttpClient;

import org.springframework.boot.http.client.JdkClientHttpRequestFactoryBuilder;
import org.springframework.boot.http.client.autoconfigure.ClientHttpRequestFactoryBuilderCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * 추론 서버 호출용 HTTP 클라이언트.
 *
 * <p>JDK HttpClient 는 기본이 HTTP/2 라서 http:// 주소에 {@code Upgrade: h2c} 헤더를 붙여 보냅니다.
 * 추론 서버(uvicorn)는 이 업그레이드를 지원하지 않아 "Unsupported upgrade request" 를 남기고 POST 본문을
 * 읽지 못합니다. 그러면 /v1/predict 가 422 (body: Field required) 로 거부되고, GET 인 /v1/model 만
 * 멀쩡해서 기동 대조는 통과해 버립니다. HTTP/1.1 로 고정합니다.
 *
 * <p>타임아웃은 application.yml 의 spring.http.clients.* 가 그대로 적용됩니다.
 */
@Configuration(proxyBeanMethods = false)
public class HttpClientConfig {

    @Bean
    ClientHttpRequestFactoryBuilderCustomizer<JdkClientHttpRequestFactoryBuilder> http11Only() {
        return builder -> builder.withHttpClientCustomizer(b -> b.version(HttpClient.Version.HTTP_1_1));
    }
}
