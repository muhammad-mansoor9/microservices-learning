package com.example.payment.service;

import com.example.payment.dto.CreatePaymentRequest;
import com.example.payment.dto.PaymentResponse;
import com.example.payment.model.Payment;
import com.example.payment.model.PaymentStatus;
import com.example.payment.repository.PaymentRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class PaymentService {

    private final PaymentRepository paymentRepository;

    @Transactional
    public PaymentResponse createPayment(CreatePaymentRequest request) {
        Payment payment = Payment.builder()
                .orderId(request.orderId())
                .userId(request.userId())
                .amount(request.amount())
                .status(PaymentStatus.PENDING.name())
                .build();

        payment = paymentRepository.save(payment);

        // Mock approval logic
        if (request.amount().compareTo(new BigDecimal("10000")) < 0) {
            payment.setStatus(PaymentStatus.APPROVED.name());
        } else {
            payment.setStatus(PaymentStatus.FAILED.name());
        }

        payment = paymentRepository.save(payment);

        return new PaymentResponse(payment.getId(), payment.getStatus());
    }

    @Transactional
    public PaymentResponse refundPayment(UUID id) {
        Payment payment = paymentRepository.findById(id)
                .orElseThrow(() -> new RuntimeException("Payment not found with id: " + id));

        payment.setStatus(PaymentStatus.REFUNDED.name());
        payment = paymentRepository.save(payment);

        return new PaymentResponse(payment.getId(), payment.getStatus());
    }
}
