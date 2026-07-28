package com.example.order.infrastructure.messaging;

import com.example.order.event.OrderCreatedEvent;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;
import software.amazon.awssdk.services.sqs.model.SendMessageRequest;

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventPublisher {

    private final SqsAsyncClient sqsClient;
    private final ObjectMapper objectMapper;

    @Value("${sqs.order-events-queue-url:}")
    private String queueUrl;

    public void publishOrderCreated(OrderCreatedEvent event) {
        if (queueUrl == null || queueUrl.isBlank()) {
            log.debug("sqs.order-events-queue-url not set; skipping publish for order {}", event.orderId());
            return;
        }

        String body;
        try {
            body = objectMapper.writeValueAsString(event);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Failed to serialize OrderCreatedEvent", e);
        }

        sqsClient.sendMessage(SendMessageRequest.builder()
                        .queueUrl(queueUrl)
                        .messageBody(body)
                        .build())
                .whenComplete((resp, err) -> {
                    if (err != null) {
                        log.error("Failed to publish OrderCreatedEvent for order {}", event.orderId(), err);
                    } else {
                        log.debug("Published OrderCreatedEvent for order {} (messageId={})", event.orderId(), resp.messageId());
                    }
                });
    }
}
