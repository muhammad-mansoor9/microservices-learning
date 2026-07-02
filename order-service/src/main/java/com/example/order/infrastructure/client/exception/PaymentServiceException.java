package com.example.order.infrastructure.client.exception;

public class PaymentServiceException extends RuntimeException {
    public PaymentServiceException(String message, Throwable cause) {
        super(message, cause);
    }
}
