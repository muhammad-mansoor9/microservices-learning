package com.example.payment.messaging;

import com.example.payment.event.PaymentApprovedEvent;
import com.example.payment.event.PaymentFailedEvent;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cloud.stream.function.StreamBridge;
import org.springframework.messaging.support.MessageBuilder;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class PaymentEventPublisher {

    private static final Logger log = LoggerFactory.getLogger(PaymentEventPublisher.class);
    private static final String BINDING = "payment-events-out-0";

    private final StreamBridge streamBridge;

    public void publishPaymentApproved(PaymentApprovedEvent event) {
        log.info("Publishing PaymentApprovedEvent orderId={} paymentId={}", event.orderId(), event.paymentId());
        streamBridge.send(BINDING,
                MessageBuilder.withPayload(event)
                        .setHeader("routingKey", "payment.approved")
                        .build());
    }

    public void publishPaymentFailed(PaymentFailedEvent event) {
        log.info("Publishing PaymentFailedEvent orderId={} reason={}", event.orderId(), event.reason());
        streamBridge.send(BINDING,
                MessageBuilder.withPayload(event)
                        .setHeader("routingKey", "payment.failed")
                        .build());
    }
}
