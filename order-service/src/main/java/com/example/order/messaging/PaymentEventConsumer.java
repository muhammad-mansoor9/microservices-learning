package com.example.order.messaging;

import com.example.order.command.OrderCommandHandler;
import com.example.order.event.PaymentApprovedEvent;
import com.example.order.event.PaymentFailedEvent;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.function.Consumer;

@Configuration
@RequiredArgsConstructor
public class PaymentEventConsumer {

    private static final Logger log = LoggerFactory.getLogger(PaymentEventConsumer.class);

    private final OrderCommandHandler orderCommandHandler;

    @Bean
    public Consumer<PaymentApprovedEvent> paymentApproved() {
        return event -> {
            log.info("Received PaymentApprovedEvent orderId={} paymentId={}", event.orderId(), event.paymentId());
            orderCommandHandler.handlePaymentApproved(event.orderId());
        };
    }

    @Bean
    public Consumer<PaymentFailedEvent> paymentFailed() {
        return event -> {
            log.info("Received PaymentFailedEvent orderId={} reason={}", event.orderId(), event.reason());
            orderCommandHandler.handlePaymentFailed(event.orderId(), event.reason());
        };
    }
}
