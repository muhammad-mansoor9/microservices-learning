package com.example.order.infrastructure.client;

import com.example.order.infrastructure.client.dto.PaymentRequest;
import com.example.order.infrastructure.client.dto.PaymentResponse;
import com.example.order.infrastructure.client.exception.PaymentServiceException;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

@Component
public class PaymentServiceClient {

    private final WebClient webClient;

    public PaymentServiceClient(@Qualifier("paymentServiceWebClient") WebClient webClient) {
        this.webClient = webClient;
    }

    public PaymentResponse processPayment(PaymentRequest request) {
        return webClient.post()
                .uri("/api/payments")
                .bodyValue(request)
                .exchangeToMono(response -> {
                    if (response.statusCode().isError()) {
                        return response.createException().flatMap(Mono::error);
                    }
                    return response.bodyToMono(PaymentResponse.class);
                })
                .onErrorMap(e -> !(e instanceof PaymentServiceException),
                        e -> new PaymentServiceException("Payment service error: " + e.getMessage(), e))
                .block();
    }
}
