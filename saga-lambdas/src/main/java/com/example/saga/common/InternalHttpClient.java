package com.example.saga.common;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

public final class InternalHttpClient {

    private static final HttpClient CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    private InternalHttpClient() {}

    public static Map<String, Object> getJson(String url) {
        return send(HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofSeconds(15))
                .GET()
                .build());
    }

    public static Map<String, Object> postJson(String url, Object body, Map<String, String> headers) {
        HttpRequest.Builder builder = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofSeconds(15))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(toJson(body)));
        if (headers != null) headers.forEach(builder::header);
        return send(builder.build());
    }

    private static Map<String, Object> send(HttpRequest req) {
        try {
            HttpResponse<String> resp = CLIENT.send(req, HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() == 404) {
                throw new NotFoundException("HTTP 404 from " + req.uri());
            }
            if (resp.statusCode() >= 400) {
                throw new RuntimeException("HTTP " + resp.statusCode() + " from " + req.uri() + ": " + resp.body());
            }
            String body = resp.body();
            if (body == null || body.isBlank()) return new LinkedHashMap<>();
            return Json.MAPPER.readValue(body, new com.fasterxml.jackson.core.type.TypeReference<Map<String, Object>>() {});
        } catch (IOException | InterruptedException e) {
            if (e instanceof InterruptedException) Thread.currentThread().interrupt();
            throw new RuntimeException("HTTP call to " + req.uri() + " failed", e);
        }
    }

    private static String toJson(Object body) {
        try {
            return Json.MAPPER.writeValueAsString(body);
        } catch (Exception e) {
            throw new RuntimeException("Failed to serialize request body", e);
        }
    }

    public static class NotFoundException extends RuntimeException {
        public NotFoundException(String msg) { super(msg); }
    }
}
