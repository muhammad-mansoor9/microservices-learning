package com.example.saga;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.example.saga.common.CloudMapDiscovery;
import com.example.saga.common.InternalHttpClient;

import java.util.Map;

public class ValidateUserHandler implements RequestHandler<Map<String, Object>, Map<String, Object>> {

    @Override
    public Map<String, Object> handleRequest(Map<String, Object> event, Context context) {
        String userId = String.valueOf(event.get("userId"));
        String ip = CloudMapDiscovery.discoverIp("user-service");
        String url = "http://" + ip + ":8080/api/users/" + userId;
        try {
            return InternalHttpClient.getJson(url);
        } catch (InternalHttpClient.NotFoundException e) {
            throw new RuntimeException("UserNotFoundException");
        }
    }
}
