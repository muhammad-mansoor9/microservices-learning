package com.example.order.command;

import com.example.order.event.OrderCancelledEvent;
import com.example.order.event.OrderConfirmedEvent;
import com.example.order.event.OrderCreatedEvent;
import com.example.order.infrastructure.client.UserServiceClient;
import com.example.order.infrastructure.client.exception.UserNotFoundException;
import com.example.order.model.OrderEvent;
import com.example.order.model.OrderEventRepository;
import com.example.order.readmodel.Order;
import com.example.order.readmodel.OrderRepository;
import com.example.order.readmodel.OrderStatus;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;
import software.amazon.awssdk.services.sfn.SfnClient;
import software.amazon.awssdk.services.sfn.model.StartExecutionRequest;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class OrderCommandHandler {

    private final OrderEventRepository orderEventRepository;
    private final OrderRepository orderRepository;
    private final ObjectMapper objectMapper;
    private final UserServiceClient userServiceClient;
    private final SfnClient sfnClient;
    private final TransactionTemplate transactionTemplate;

    @Value("${services.saga-state-machine-arn}")
    private String stateMachineArn;

    public UUID handle(CreateOrderCommand command) {
        // Validate user synchronously for fast failure before queuing the SAGA
        userServiceClient.findById(command.userId())
                .orElseThrow(() -> new UserNotFoundException(command.userId()));

        UUID orderId = UUID.randomUUID();
        Instant now = Instant.now();

        // Persist OrderCreatedEvent + PENDING read model atomically, then release DB connection
        transactionTemplate.executeWithoutResult(tx -> {
            appendEvent(orderId, "OrderCreated",
                    new OrderCreatedEvent(orderId, command.userId(), command.amount(), now));
            Order order = new Order();
            order.setId(orderId);
            order.setUserId(command.userId());
            order.setAmount(command.amount());
            order.setStatus(OrderStatus.PENDING);
            order.setCreatedAt(now);
            orderRepository.save(order);
        });

        // Fire-and-forget: Step Functions drives the rest of the SAGA asynchronously
        String input = toJson(Map.of(
                "orderId", orderId.toString(),
                "userId",  command.userId().toString(),
                "amount",  command.amount()
        ));
        sfnClient.startExecution(StartExecutionRequest.builder()
                .stateMachineArn(stateMachineArn)
                .name(orderId.toString())  // idempotent: one execution per order ID
                .input(input)
                .build());

        return orderId;
    }

    /** Called by POST /api/orders/{id}/confirm (Step Functions ConfirmOrder state). */
    public void confirm(UUID orderId) {
        transactionTemplate.executeWithoutResult(tx -> {
            Order order = orderRepository.findById(orderId).orElseThrow();
            if (order.getStatus() == OrderStatus.CONFIRMED) return; // idempotent
            order.setStatus(OrderStatus.CONFIRMED);
            appendEvent(orderId, "OrderConfirmed", new OrderConfirmedEvent(orderId, Instant.now()));
        });
    }

    /** Called by POST /api/orders/{id}/cancel (Step Functions CancelOrder state). */
    public void cancel(UUID orderId) {
        transactionTemplate.executeWithoutResult(tx -> {
            Order order = orderRepository.findById(orderId).orElseThrow();
            if (order.getStatus() == OrderStatus.CANCELLED) return; // idempotent
            order.setStatus(OrderStatus.CANCELLED);
            appendEvent(orderId, "OrderCancelled",
                    new OrderCancelledEvent(orderId, "Cancelled by order SAGA", Instant.now()));
        });
    }

    private String toJson(Object obj) {
        try {
            return objectMapper.writeValueAsString(obj);
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize SFN input", e);
        }
    }

    private void appendEvent(UUID aggregateId, String eventType, Object payload) {
        int nextVersion = orderEventRepository.findMaxVersionByAggregateId(aggregateId).orElse(0) + 1;
        String json;
        try {
            json = objectMapper.writeValueAsString(payload);
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize event", e);
        }
        OrderEvent orderEvent = new OrderEvent();
        orderEvent.setId(UUID.randomUUID());
        orderEvent.setAggregateId(aggregateId);
        orderEvent.setEventType(eventType);
        orderEvent.setPayload(json);
        orderEvent.setVersion(nextVersion);
        orderEvent.setOccurredAt(Instant.now());
        orderEventRepository.save(orderEvent);
    }
}
