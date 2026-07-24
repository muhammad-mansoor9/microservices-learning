package com.example.payment.event;

import java.time.Instant;
import java.util.UUID;

public record PaymentFailedEvent(UUID orderId, String reason, Instant occurredAt) {}
