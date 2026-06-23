package com.example.order.command;

import com.example.order.event.OrderCreatedEvent;
import com.example.order.model.OrderEvent;
import com.example.order.model.OrderEventRepository;
import com.example.order.readmodel.Order;
import com.example.order.readmodel.OrderRepository;
import com.example.order.readmodel.OrderStatus;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class OrderCommandHandler {

    private final OrderEventRepository orderEventRepository;
    private final OrderRepository orderRepository;
    private final ObjectMapper objectMapper;

    @Transactional
    public UUID handle(CreateOrderCommand command) {
        UUID orderId = UUID.randomUUID();
        Instant now = Instant.now();

        OrderCreatedEvent event = new OrderCreatedEvent(orderId, command.userId(), command.amount(), now);

        String payload;
        try {
            payload = objectMapper.writeValueAsString(event);
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize OrderCreatedEvent", e);
        }

        int nextVersion = orderEventRepository.findMaxVersionByAggregateId(orderId).orElse(0) + 1;

        OrderEvent orderEvent = new OrderEvent();
        orderEvent.setId(UUID.randomUUID());
        orderEvent.setAggregateId(orderId);
        orderEvent.setEventType("OrderCreated");
        orderEvent.setPayload(payload);
        orderEvent.setVersion(nextVersion);
        orderEvent.setOccurredAt(now);
        orderEventRepository.save(orderEvent);

        Order order = new Order();
        order.setId(orderId);
        order.setUserId(command.userId());
        order.setAmount(command.amount());
        order.setStatus(OrderStatus.PENDING);
        order.setCreatedAt(now);
        orderRepository.save(order);

        return orderId;
    }
}
