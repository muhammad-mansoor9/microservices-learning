package com.example.order.event;

import java.time.Instant;
import java.util.UUID;

public record OrderFailedEvent(
        UUID orderId,
        String reason,
        Instant occurredAt
) {}
