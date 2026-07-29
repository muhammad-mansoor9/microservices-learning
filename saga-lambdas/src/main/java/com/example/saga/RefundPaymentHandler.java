package com.example.saga;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.example.saga.common.CloudMapDiscovery;
import com.example.saga.common.InternalHttpClient;

import java.util.LinkedHashMap;
import java.util.Map;

public class RefundPaymentHandler implements RequestHandler<Map<String, Object>, Map<String, Object>> {

    @Override
    @SuppressWarnings("unchecked")
    public Map<String, Object> handleRequest(Map<String, Object> event, Context context) {
        Map<String, Object> payment = (Map<String, Object>) event.getOrDefault("payment", Map.of());
        Object paymentIdObj = payment.get("paymentId");
        if (paymentIdObj == null) {
            Map<String, Object> skipped = new LinkedHashMap<>();
            skipped.put("status", "no_payment_to_refund");
            return skipped;
        }
        String ip = CloudMapDiscovery.discoverIp("payment-service");
        String url = "http://" + ip + ":8080/api/payments/" + paymentIdObj + "/refund";
        return InternalHttpClient.postJson(url, new LinkedHashMap<>(), null);
    }
}
