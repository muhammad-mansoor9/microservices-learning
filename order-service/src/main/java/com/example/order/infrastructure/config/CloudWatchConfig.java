package com.example.order.infrastructure.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.cloudwatch.CloudWatchAsyncClient;
import software.amazon.awssdk.services.cloudwatch.CloudWatchAsyncClientBuilder;

import java.net.URI;

@Configuration
public class CloudWatchConfig {

    @Value("${aws.region:us-east-1}")
    private String awsRegion;

    @Value("${aws.cloudwatch-endpoint:}")
    private String cloudWatchEndpointOverride;

    @Bean
    public CloudWatchAsyncClient cloudWatchAsyncClient() {
        CloudWatchAsyncClientBuilder builder = CloudWatchAsyncClient.builder().region(Region.of(awsRegion));
        if (!cloudWatchEndpointOverride.isBlank()) {
            builder.endpointOverride(URI.create(cloudWatchEndpointOverride));
        }
        return builder.build();
    }
}
