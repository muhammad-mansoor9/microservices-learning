package com.example.saga.common;

import software.amazon.awssdk.services.servicediscovery.ServiceDiscoveryClient;
import software.amazon.awssdk.services.servicediscovery.model.DiscoverInstancesRequest;
import software.amazon.awssdk.services.servicediscovery.model.HealthStatusFilter;
import software.amazon.awssdk.services.servicediscovery.model.HttpInstanceSummary;

import java.util.List;
import java.util.concurrent.ThreadLocalRandom;

public final class CloudMapDiscovery {

    private static final ServiceDiscoveryClient CLIENT = ServiceDiscoveryClient.create();
    private static final String NAMESPACE = System.getenv("SERVICE_NAMESPACE");

    private CloudMapDiscovery() {}

    public static String discoverIp(String serviceName) {
        List<HttpInstanceSummary> instances = CLIENT.discoverInstances(
                DiscoverInstancesRequest.builder()
                        .namespaceName(NAMESPACE)
                        .serviceName(serviceName)
                        .maxResults(10)
                        .healthStatus(HealthStatusFilter.HEALTHY)
                        .build()
        ).instances();

        if (instances.isEmpty()) {
            throw new RuntimeException("No healthy instances for " + serviceName);
        }
        HttpInstanceSummary pick = instances.get(ThreadLocalRandom.current().nextInt(instances.size()));
        return pick.attributes().get("AWS_INSTANCE_IPV4");
    }
}
