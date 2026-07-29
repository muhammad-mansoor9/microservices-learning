package com.example.saga.common;

import com.fasterxml.jackson.databind.ObjectMapper;

public final class Json {
    public static final ObjectMapper MAPPER = new ObjectMapper();
    private Json() {}
}
