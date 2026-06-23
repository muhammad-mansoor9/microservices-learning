package com.example.order.model;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface OrderEventRepository extends JpaRepository<OrderEvent, UUID> {

    List<OrderEvent> findByAggregateIdOrderByVersionAsc(UUID aggregateId);

    @Query("SELECT MAX(e.version) FROM OrderEvent e WHERE e.aggregateId = :aggregateId")
    Optional<Integer> findMaxVersionByAggregateId(@Param("aggregateId") UUID aggregateId);
}
