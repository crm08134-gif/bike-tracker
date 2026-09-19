plugins {
    java
    id("org.springframework.boot") version "4.1.1"
    id("io.spring.dependency-management") version "1.1.7"
}

group = "io.github.crm08134"
version = "0.1.0"

java {
    toolchain { languageVersion = JavaLanguageVersion.of(21) }
}

repositories { mavenCentral() }

dependencies {
    // Boot 4 부터 모듈이 쪼개졌습니다. starter-web 은 starter-webmvc 로 이름이 바뀌었고,
    // RestClient 와 Flyway 는 각각 전용 starter 가 있어야 자동 설정이 붙습니다.
    implementation("org.springframework.boot:spring-boot-starter-webmvc")
    implementation("org.springframework.boot:spring-boot-starter-restclient")
    implementation("org.springframework.boot:spring-boot-starter-jdbc")
    implementation("org.springframework.boot:spring-boot-starter-flyway")
    implementation("org.springframework.boot:spring-boot-starter-validation")
    implementation("org.springframework.boot:spring-boot-starter-actuator")

    runtimeOnly("org.flywaydb:flyway-database-postgresql")
    runtimeOnly("org.postgresql:postgresql")
    runtimeOnly("io.micrometer:micrometer-registry-prometheus")

    testImplementation("org.springframework.boot:spring-boot-starter-test")
    // Boot 4 에서 @WebMvcTest / MockMvc 자동 설정이 별도 모듈로 빠졌습니다.
    testImplementation("org.springframework.boot:spring-boot-starter-webmvc-test")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")

    // 3.x 에서 이름이 바뀐 설정 값을 기동 때 알려줍니다. 정리되면 지우세요.
    runtimeOnly("org.springframework.boot:spring-boot-properties-migrator")
}

tasks.withType<Test> { useJUnitPlatform() }

// IntelliJ 에서 Gradle bootRun 으로 띄우면 local 프로필(localhost:5433 DB, localhost:8000 추론 서버)로 뜹니다.
// SPRING_PROFILES_ACTIVE 환경 변수나 -Dspring.profiles.active 를 주면 그쪽이 우선입니다.
// IntelliJ 의 "Spring Boot" 실행 구성(Gradle 이 아닌 것)에는 적용되지 않으니 거기서는 Active profiles 에 local 을 넣으세요.
tasks.named<org.springframework.boot.gradle.tasks.run.BootRun>("bootRun") {
    if (System.getenv("SPRING_PROFILES_ACTIVE") == null) {
        systemProperty("spring.profiles.active", System.getProperty("spring.profiles.active") ?: "local")
    }
}
