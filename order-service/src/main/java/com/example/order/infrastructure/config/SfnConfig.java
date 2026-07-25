package com.example.order.infrastructure.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sfn.SfnClient;
import software.amazon.awssdk.services.sfn.SfnClientBuilder;

import java.net.URI;

@Configuration
public class SfnConfig {

    @Value("${aws.region:us-east-1}")
    private String awsRegion;

    @Value("${aws.sfn-endpoint:}")
    private String sfnEndpointOverride;

    @Bean
    public SfnClient sfnClient() {
        SfnClientBuilder builder = SfnClient.builder().region(Region.of(awsRegion));
        if (!sfnEndpointOverride.isBlank()) {
            builder.endpointOverride(URI.create(sfnEndpointOverride));
        }
        return builder.build();
    }
}
