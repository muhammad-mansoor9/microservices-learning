package com.example.order.command;

import com.example.order.event.OrderCancelledEvent;
import com.example.order.event.OrderConfirmedEvent;
import com.example.order.event.OrderCreatedEvent;
import com.example.order.event.OrderFailedEvent;
import com.example.order.infrastructure.client.UserServiceClient;
import com.example.order.infrastructure.client.exception.UserNotFoundException;
import com.example.order.infrastructure.security.UserContext;
import com.example.order.messaging.OrderEventPublisher;
import com.example.order.model.OrderEvent;
import com.example.order.model.OrderEventRepository;
import com.example.order.readmodel.Order;
import com.example.order.readmodel.OrderRepository;
import com.example.order.readmodel.OrderStatus;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Instant;
import java.util.UUID;

@Service
public class OrderCommandHandler {

    private static final Logger log = LoggerFactory.getLogger(OrderCommandHandler.class);

    private final OrderEventRepository orderEventRepository;
    private final OrderRepository orderRepository;
    private final ObjectMapper objectMapper;
    private final UserServiceClient userServiceClient;
    private final OrderEventPublisher orderEventPublisher;
    private final TransactionTemplate transactionTemplate;
    private final UserContext userContext;
    private final Counter ordersCreatedSuccess;
    private final Counter ordersCreatedFailure;

    public OrderCommandHandler(OrderEventRepository orderEventRepository,
                               OrderRepository orderRepository,
                               ObjectMapper objectMapper,
                               UserServiceClient userServiceClient,
                               OrderEventPublisher orderEventPublisher,
                               TransactionTemplate transactionTemplate,
                               UserContext userContext,
                               MeterRegistry meterRegistry) {
        this.orderEventRepository = orderEventRepository;
        this.orderRepository = orderRepository;
        this.objectMapper = objectMapper;
        this.userServiceClient = userServiceClient;
        this.orderEventPublisher = orderEventPublisher;
        this.transactionTemplate = transactionTemplate;
        this.userContext = userContext;
        this.ordersCreatedSuccess = Counter.builder("orders_created_total")
                .tag("status", "success")
                .description("Total orders created successfully")
                .register(meterRegistry);
        this.ordersCreatedFailure = Counter.builder("orders_created_total")
                .tag("status", "failure")
                .description("Total orders that failed to create")
                .register(meterRegistry);
    }

    public UUID handle(CreateOrderCommand command) {
        String actor = userContext.getUsername() != null ? userContext.getUsername() : "internal";
        log.info("Creating order username={} traceId={}", actor, MDC.get("traceId"));

        try {
            // Phase 1: validate user — synchronous, no DB connection held
            userServiceClient.findById(command.userId())
                    .orElseThrow(() -> new UserNotFoundException(command.userId()));

            UUID orderId = UUID.randomUUID();
            Instant now = Instant.now();
            OrderCreatedEvent event = new OrderCreatedEvent(orderId, command.userId(), command.amount(), now);

            // Phase 2: write event + PENDING read model, then commit — DB connection released
            transactionTemplate.executeWithoutResult(tx -> {
                appendEvent(orderId, "OrderCreated", event);
                Order order = new Order();
                order.setId(orderId);
                order.setUserId(command.userId());
                order.setAmount(command.amount());
                order.setStatus(OrderStatus.PENDING);
                order.setCreatedAt(now);
                orderRepository.save(order);
            });

            // Phase 3: publish to RabbitMQ — SAGA choreography continues asynchronously
            orderEventPublisher.publishOrderCreated(event);

            ordersCreatedSuccess.increment();
            return orderId;
        } catch (Exception e) {
            ordersCreatedFailure.increment();
            throw e;
        }
    }

    @Transactional
    public void handlePaymentApproved(UUID orderId) {
        log.info("Handling PaymentApproved for orderId={}", orderId);
        finaliseOrder(orderId, OrderStatus.CONFIRMED, null);
    }

    @Transactional
    public void handlePaymentFailed(UUID orderId, String reason) {
        log.info("Handling PaymentFailed for orderId={} reason={}", orderId, reason);
        finaliseOrder(orderId, OrderStatus.CANCELLED, reason);
    }

    private void finaliseOrder(UUID orderId, OrderStatus status, String reason) {
        Order order = orderRepository.findById(orderId).orElseThrow();
        order.setStatus(status);
        Instant now = Instant.now();
        switch (status) {
            case CONFIRMED -> appendEvent(orderId, "OrderConfirmed", new OrderConfirmedEvent(orderId, now));
            case FAILED    -> appendEvent(orderId, "OrderFailed",    new OrderFailedEvent(orderId, reason, now));
            case CANCELLED -> appendEvent(orderId, "OrderCancelled", new OrderCancelledEvent(orderId, reason, now));
            default -> { /* PENDING is set on creation; no terminal event needed */ }
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
