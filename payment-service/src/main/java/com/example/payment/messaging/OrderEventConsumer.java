package com.example.payment.messaging;

import com.example.payment.dto.CreatePaymentRequest;
import com.example.payment.dto.PaymentResponse;
import com.example.payment.event.OrderCreatedEvent;
import com.example.payment.event.PaymentApprovedEvent;
import com.example.payment.event.PaymentFailedEvent;
import com.example.payment.service.PaymentService;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Instant;
import java.util.function.Consumer;

@Configuration
@RequiredArgsConstructor
public class OrderEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(OrderEventConsumer.class);

    private final PaymentService paymentService;
    private final PaymentEventPublisher paymentEventPublisher;

    @Bean
    public Consumer<OrderCreatedEvent> orderCreated() {
        return event -> {
            log.info("Received OrderCreatedEvent orderId={} amount={}", event.orderId(), event.amount());

            PaymentResponse response = paymentService.createPayment(
                    new CreatePaymentRequest(event.orderId(), event.userId(), event.amount()));

            Instant now = Instant.now();
            if ("APPROVED".equals(response.status())) {
                paymentEventPublisher.publishPaymentApproved(
                        new PaymentApprovedEvent(event.orderId(), response.paymentId(), now));
            } else {
                paymentEventPublisher.publishPaymentFailed(
                        new PaymentFailedEvent(event.orderId(), "Payment rejected by processor", now));
            }
        };
    }
}
