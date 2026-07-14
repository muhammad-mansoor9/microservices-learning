package com.example.order.command;

import com.example.order.event.OrderCancelledEvent;
import com.example.order.event.OrderConfirmedEvent;
import com.example.order.event.OrderCreatedEvent;
import com.example.order.event.OrderFailedEvent;
import com.example.order.model.OrderEvent;
import com.example.order.model.OrderEventRepository;
import com.example.order.readmodel.Order;
import com.example.order.readmodel.OrderRepository;
import com.example.order.readmodel.OrderStatus;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@Slf4j
@Service
@RequiredArgsConstructor
public class EventReplayService {

    private final OrderEventRepository eventRepository;
    private final OrderRepository orderRepository;
    private final ObjectMapper objectMapper;

    @Transactional
    public int replayAllEvents() {
        List<OrderEvent> events = eventRepository.findAllByOrderByOccurredAtAsc();

        Map<UUID, Order> readModel = new LinkedHashMap<>();

        for (OrderEvent event : events) {
            log.info("Replaying event: aggregateId={}, type={}", event.getAggregateId(), event.getEventType());
            try {
                switch (event.getEventType()) {
                    case "OrderCreated" -> {
                        OrderCreatedEvent e = objectMapper.readValue(event.getPayload(), OrderCreatedEvent.class);
                        Order order = new Order();
                        order.setId(e.orderId());
                        order.setUserId(e.userId());
                        order.setAmount(e.amount());
                        order.setStatus(OrderStatus.PENDING);
                        order.setCreatedAt(e.occurredAt());
                        readModel.put(e.orderId(), order);
                    }
                    case "OrderConfirmed" -> {
                        OrderConfirmedEvent e = objectMapper.readValue(event.getPayload(), OrderConfirmedEvent.class);
                        Order order = readModel.get(e.orderId());
                        if (order != null) order.setStatus(OrderStatus.CONFIRMED);
                    }
                    case "OrderFailed" -> {
                        OrderFailedEvent e = objectMapper.readValue(event.getPayload(), OrderFailedEvent.class);
                        Order order = readModel.get(e.orderId());
                        if (order != null) order.setStatus(OrderStatus.FAILED);
                    }
                    case "OrderCancelled" -> {
                        OrderCancelledEvent e = objectMapper.readValue(event.getPayload(), OrderCancelledEvent.class);
                        Order order = readModel.get(e.orderId());
                        if (order != null) order.setStatus(OrderStatus.CANCELLED);
                    }
                    default -> log.warn("Unknown event type '{}' on aggregate {}, skipping",
                            event.getEventType(), event.getAggregateId());
                }
            } catch (JsonProcessingException ex) {
                log.error("Failed to deserialize event {}: {}", event.getId(), ex.getMessage());
            }
        }

        orderRepository.deleteAllInBatch();
        orderRepository.saveAll(readModel.values());

        log.info("Event replay complete: {} events processed, {} orders rebuilt", events.size(), readModel.size());
        return events.size();
    }
}
