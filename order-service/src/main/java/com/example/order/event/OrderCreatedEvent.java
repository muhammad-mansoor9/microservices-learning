package com.example.order.event;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record OrderCreatedEvent(
        UUID orderId,
        String userId,
        BigDecimal amount,
        Instant occurredAt
) {}
