package com.example.order.infrastructure.client.dto;

import java.math.BigDecimal;
import java.util.UUID;

public record PaymentRequest(UUID orderId, String userId, BigDecimal amount) {}
