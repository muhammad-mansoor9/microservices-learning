package com.example.saga.common;

import software.amazon.awssdk.services.ssm.SsmClient;
import software.amazon.awssdk.services.ssm.model.GetParameterRequest;

import java.util.concurrent.ConcurrentHashMap;

public final class SsmSecretProvider {

    private static final SsmClient CLIENT = SsmClient.create();
    private static final ConcurrentHashMap<String, String> CACHE = new ConcurrentHashMap<>();

    private SsmSecretProvider() {}

    public static String get(String parameterName) {
        return CACHE.computeIfAbsent(parameterName, name ->
                CLIENT.getParameter(GetParameterRequest.builder()
                        .name(name)
                        .withDecryption(true)
                        .build()
                ).parameter().value()
        );
    }
}
