package com.example.order.infrastructure.config;

import com.example.order.infrastructure.client.AwsSigV4RequestInterceptor;
import com.example.order.infrastructure.filter.TraceIdFilter;
import com.example.order.infrastructure.filter.TraceIdHolder;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.reactive.function.client.ClientRequest;
import org.springframework.web.reactive.function.client.ExchangeFilterFunction;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.Optional;

@Configuration
public class WebClientConfig {

    @Bean("userServiceWebClient")
    WebClient userServiceWebClient(
            @Value("${services.user-service-url}") String baseUrl,
            @Value("${services.internal-api-key:}") String internalApiKey,
            Optional<AwsSigV4RequestInterceptor> sigV4) {

        WebClient.Builder builder = WebClient.builder()
                .baseUrl(baseUrl)
                .filter(traceIdFilter());

        sigV4.ifPresentOrElse(
                interceptor -> builder.filter(interceptor),
                () -> builder.filter(internalApiKeyFilter(internalApiKey)));

        return builder.build();
    }

    @Bean("paymentServiceWebClient")
    WebClient paymentServiceWebClient(
            @Value("${services.payment-service-url}") String baseUrl,
            @Value("${services.internal-api-key:}") String internalApiKey,
            Optional<AwsSigV4RequestInterceptor> sigV4) {

        WebClient.Builder builder = WebClient.builder()
                .baseUrl(baseUrl)
                .filter(traceIdFilter());

        sigV4.ifPresentOrElse(
                interceptor -> builder.filter(interceptor),
                () -> builder.filter(internalApiKeyFilter(internalApiKey)));

        return builder.build();
    }

    private ExchangeFilterFunction traceIdFilter() {
        return (request, next) -> {
            String traceId = TraceIdHolder.get();
            if (traceId == null) return next.exchange(request);
            return next.exchange(ClientRequest.from(request)
                    .header(TraceIdFilter.TRACE_HEADER, traceId)
                    .build());
        };
    }

    private ExchangeFilterFunction internalApiKeyFilter(String apiKey) {
        return (request, next) -> next.exchange(
                ClientRequest.from(request)
                        .header("X-Internal-Api-Key", apiKey)
                        .build());
    }
}
