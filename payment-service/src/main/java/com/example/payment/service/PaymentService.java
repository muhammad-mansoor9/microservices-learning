package com.example.payment.service;

import com.example.payment.dto.CreatePaymentRequest;
import com.example.payment.dto.PaymentResponse;
import com.example.payment.model.Payment;
import com.example.payment.model.PaymentStatus;
import com.example.payment.repository.PaymentRepository;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.UUID;

@Service
public class PaymentService {

    private final PaymentRepository paymentRepository;
    private final Counter paymentsApproved;
    private final Counter paymentsFailed;

    public PaymentService(PaymentRepository paymentRepository, MeterRegistry meterRegistry) {
        this.paymentRepository = paymentRepository;
        this.paymentsApproved = Counter.builder("payments_processed_total")
                .tag("status", "approved")
                .description("Total payments processed with approved status")
                .register(meterRegistry);
        this.paymentsFailed = Counter.builder("payments_processed_total")
                .tag("status", "failed")
                .description("Total payments processed with failed status")
                .register(meterRegistry);
    }

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
            paymentsApproved.increment();
        } else {
            payment.setStatus(PaymentStatus.FAILED.name());
            paymentsFailed.increment();
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
