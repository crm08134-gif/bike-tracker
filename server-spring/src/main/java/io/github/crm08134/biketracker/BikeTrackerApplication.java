package io.github.crm08134.biketracker;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.scheduling.annotation.EnableScheduling;

import io.github.crm08134.biketracker.config.TrackerProperties;

@SpringBootApplication
@EnableScheduling
@EnableConfigurationProperties(TrackerProperties.class)
public class BikeTrackerApplication {
    public static void main(String[] args) {
        SpringApplication.run(BikeTrackerApplication.class, args);
    }
}
