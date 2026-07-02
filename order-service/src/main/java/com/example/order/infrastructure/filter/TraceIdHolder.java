package com.example.order.infrastructure.filter;

public class TraceIdHolder {

    private static final ThreadLocal<String> HOLDER = new ThreadLocal<>();

    public static void set(String traceId) { HOLDER.set(traceId); }
    public static String get() { return HOLDER.get(); }
    public static void clear() { HOLDER.remove(); }
}
