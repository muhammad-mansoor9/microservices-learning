package com.example.saga;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.example.saga.common.CloudMapDiscovery;
import com.example.saga.common.InternalHttpClient;

import java.util.LinkedHashMap;
import java.util.Map;

public class ProcessPaymentHandler implements RequestHandler<Map<String, Object>, Map<String, Object>> {

    @Override
    public Map<String, Object> handleRequest(Map<String, Object> event, Context context) {
        String ip = CloudMapDiscovery.discoverIp("payment-service");
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("orderId", event.get("orderId"));
        body.put("userId",  event.get("userId"));
        body.put("amount",  event.get("amount"));
        return InternalHttpClient.postJson("http://" + ip + ":8080/api/payments", body, null);
    }
}
