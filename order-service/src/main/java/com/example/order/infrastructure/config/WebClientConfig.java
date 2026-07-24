package com.example.order.infrastructure.config;

import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.reactive.function.client.ClientRequest;
import org.springframework.web.reactive.function.client.ExchangeFilterFunction;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.UUID;

@Configuration
public class WebClientConfig {

    @Bean("userServiceWebClient")
    WebClient userServiceWebClient(
            @Value("${services.user-service-url}") String baseUrl,
            @Value("${internal.api.key}") String internalApiKey) {
        return WebClient.builder()
                .baseUrl(baseUrl)
                .defaultHeader("X-Internal-Api-Key", internalApiKey)
                .filter(traceIdFilter())
                .build();
    }

    @Bean("paymentServiceWebClient")
    WebClient paymentServiceWebClient(
            @Value("${services.payment-service-url}") String baseUrl,
            @Value("${internal.api.key}") String internalApiKey) {
        return WebClient.builder()
                .baseUrl(baseUrl)
                .defaultHeader("X-Internal-Api-Key", internalApiKey)
                .filter(traceIdFilter())
                .build();
    }

    // Reads traceId from MDC (set by LoggingFilter on every incoming request).
    // Falls back to a fresh UUID when the call originates outside a request context.
    private ExchangeFilterFunction traceIdFilter() {
        return (request, next) -> {
            String traceId = MDC.get("traceId");
            if (traceId == null) traceId = UUID.randomUUID().toString();
            return next.exchange(ClientRequest.from(request)
                    .header("X-Trace-Id", traceId)
                    .build());
        };
    }
}
