package com.example.order.api;

import com.example.order.command.CreateOrderCommand;
import com.example.order.command.OrderCommandHandler;
import com.example.order.query.OrderQueryService;
import com.example.order.readmodel.Order;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.UUID;

@RestController
@RequestMapping("/api/orders")
@RequiredArgsConstructor
public class OrderController {

    private final OrderCommandHandler commandHandler;
    private final OrderQueryService queryService;

    @PostMapping
    public ResponseEntity<UUID> createOrder(@Valid @RequestBody CreateOrderCommand command) {
        UUID orderId = commandHandler.handle(command);
        return ResponseEntity
                .created(URI.create("/api/orders/" + orderId))
                .body(orderId);
    }

    @GetMapping("/{id}")
    public ResponseEntity<Order> getOrder(@PathVariable UUID id) {
        return queryService.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }
}
