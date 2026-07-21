package com.example.order.event;

import java.time.Instant;
import java.util.UUID;

public record PaymentApprovedEvent(UUID orderId, UUID paymentId, Instant occurredAt) {}
