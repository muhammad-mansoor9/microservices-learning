package com.example.order.infrastructure.config;

import com.example.order.infrastructure.filter.TraceIdHolder;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.reactive.function.client.ClientRequest;
import org.springframework.web.reactive.function.client.ExchangeFilterFunction;
import org.springframework.web.reactive.function.client.WebClient;

@Configuration
public class WebClientConfig {

    @Bean("userServiceWebClient")
    WebClient userServiceWebClient(@Value("${services.user-service-url}") String baseUrl) {
        return WebClient.builder()
                .baseUrl(baseUrl)
                .filter(traceIdFilter())
                .build();
    }

    @Bean("paymentServiceWebClient")
    WebClient paymentServiceWebClient(@Value("${services.payment-service-url}") String baseUrl) {
        return WebClient.builder()
                .baseUrl(baseUrl)
                .filter(traceIdFilter())
                .build();
    }

    private ExchangeFilterFunction traceIdFilter() {
        return (request, next) -> {
            String traceId = TraceIdHolder.get();
            if (traceId == null) return next.exchange(request);
            return next.exchange(ClientRequest.from(request)
                    .header("X-Trace-Id", traceId)
                    .build());
        };
    }
}
