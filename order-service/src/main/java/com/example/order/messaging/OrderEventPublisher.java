package com.example.order.messaging;

import com.example.order.event.OrderCreatedEvent;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cloud.stream.function.StreamBridge;
import org.springframework.messaging.support.MessageBuilder;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class OrderEventPublisher {

    private static final Logger log = LoggerFactory.getLogger(OrderEventPublisher.class);
    private static final String BINDING = "order-events-out-0";

    private final StreamBridge streamBridge;

    public void publishOrderCreated(OrderCreatedEvent event) {
        log.info("Publishing OrderCreatedEvent orderId={}", event.orderId());
        streamBridge.send(BINDING,
                MessageBuilder.withPayload(event)
                        .setHeader("routingKey", "order.created")
                        .build());
    }
}
