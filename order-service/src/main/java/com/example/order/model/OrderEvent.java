package com.example.order.model;

import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.springframework.data.domain.Persistable;

import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "order_events", indexes = @Index(name = "idx_order_events_aggregate_id", columnList = "aggregate_id"))
@Getter
@Setter
@NoArgsConstructor
public class OrderEvent implements Persistable<UUID> {

    @Id
    @Column(nullable = false, updatable = false)
    private UUID id;

    @Column(name = "aggregate_id", nullable = false, updatable = false)
    private UUID aggregateId;

    @Column(name = "event_type", nullable = false, updatable = false)
    private String eventType;

    @Column(columnDefinition = "TEXT", nullable = false, updatable = false)
    private String payload;

    @Column(nullable = false, updatable = false)
    private int version;

    @Column(name = "occurred_at", nullable = false, updatable = false)
    private Instant occurredAt;

    @Override
    @Transient
    public boolean isNew() {
        return true;
    }
}
