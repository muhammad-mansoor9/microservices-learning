package com.example.order.command;

import com.example.order.event.OrderCancelledEvent;
import com.example.order.event.OrderCreatedEvent;
import com.example.order.infrastructure.client.PaymentServiceClient;
import com.example.order.infrastructure.client.UserServiceClient;
import com.example.order.infrastructure.client.dto.PaymentRequest;
import com.example.order.infrastructure.client.dto.PaymentResponse;
import com.example.order.infrastructure.client.exception.PaymentServiceException;
import com.example.order.infrastructure.client.exception.UserNotFoundException;
import com.example.order.model.OrderEvent;
import com.example.order.model.OrderEventRepository;
import com.example.order.readmodel.Order;
import com.example.order.readmodel.OrderRepository;
import com.example.order.readmodel.OrderStatus;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Instant;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class OrderCommandHandler {

    private final OrderEventRepository orderEventRepository;
    private final OrderRepository orderRepository;
    private final ObjectMapper objectMapper;
    private final UserServiceClient userServiceClient;
    private final PaymentServiceClient paymentServiceClient;
    private final TransactionTemplate transactionTemplate;

    public UUID handle(CreateOrderCommand command) {
        // Phase 1: validate user — no DB connection held
        userServiceClient.findById(command.userId())
                .orElseThrow(() -> new UserNotFoundException(command.userId()));

        UUID orderId = UUID.randomUUID();
        Instant now = Instant.now();

        // Phase 2: write event + PENDING order, then commit — DB connection released
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

        // Phase 3: call payment — no DB connection held
        try {
            PaymentResponse response = paymentServiceClient.processPayment(
                    new PaymentRequest(orderId, command.userId(), command.amount()));

            if ("APPROVED".equals(response.status())) {
                transactionTemplate.executeWithoutResult(tx -> finaliseOrder(orderId, OrderStatus.CONFIRMED, null));
            } else {
                transactionTemplate.executeWithoutResult(tx -> finaliseOrder(orderId, OrderStatus.FAILED, "Payment rejected"));
            }
        } catch (PaymentServiceException e) {
            transactionTemplate.executeWithoutResult(tx -> finaliseOrder(orderId, OrderStatus.CANCELLED, "Payment service unavailable"));
        }

        return orderId;
    }

    private void finaliseOrder(UUID orderId, OrderStatus status, String cancelReason) {
        Order order = orderRepository.findById(orderId).orElseThrow();
        order.setStatus(status);
        if (cancelReason != null) {
            appendEvent(orderId, "OrderCancelled",
                    new OrderCancelledEvent(orderId, cancelReason, Instant.now()));
        }
        // no explicit save() — dirty checking flushes the status change at commit
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
