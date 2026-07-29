package com.example.saga;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.example.saga.common.CloudMapDiscovery;
import com.example.saga.common.InternalHttpClient;
import com.example.saga.common.SsmSecretProvider;

import java.util.LinkedHashMap;
import java.util.Map;

public class ConfirmOrderHandler implements RequestHandler<Map<String, Object>, Map<String, Object>> {

    private static final String KEY_PARAM = System.getenv("INTERNAL_API_KEY_PARAM");

    @Override
    public Map<String, Object> handleRequest(Map<String, Object> event, Context context) {
        String orderId = String.valueOf(event.get("orderId"));
        String ip = CloudMapDiscovery.discoverIp("order-service");
        String url = "http://" + ip + ":8080/api/orders/" + orderId + "/confirm";

        Map<String, String> headers = Map.of("X-Internal-Api-Key", SsmSecretProvider.get(KEY_PARAM));
        InternalHttpClient.postJson(url, new LinkedHashMap<>(), headers);

        Map<String, Object> result = new     LinkedHashMap<>();
        result.put("status", "confirmed");
        result.put("orderId", orderId);
        return result;
    }
}
