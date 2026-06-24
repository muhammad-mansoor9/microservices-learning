package com.example.payment.dto;

import java.util.UUID;

public record PaymentResponse(
        UUID paymentId,
        String status
) {
}
