package com.example.order.event;

import java.time.Instant;
import java.util.UUID;

public record OrderConfirmedEvent(
        UUID orderId,
        Instant occurredAt
) {}
