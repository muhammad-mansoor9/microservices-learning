package com.example.order.command;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;

public record CreateOrderCommand(
        @NotBlank(message = "userId must not be blank")
        String userId,

        @NotNull(message = "amount must not be null")
        @DecimalMin(value = "0.01", message = "amount must be greater than 0")
        BigDecimal amount
) {}
