package com.example.order.api;

import com.example.order.command.CreateOrderCommand;
import com.example.order.command.EventReplayService;
import com.example.order.command.OrderCommandHandler;
import com.example.order.query.OrderQueryService;
import com.example.order.readmodel.Order;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/orders")
@RequiredArgsConstructor
public class OrderController {

    private final OrderCommandHandler commandHandler;
    private final OrderQueryService queryService;
    private final EventReplayService eventReplayService;

    @PostMapping
    public ResponseEntity<UUID> createOrder(@Valid @RequestBody CreateOrderCommand command) {
        UUID orderId = commandHandler.handle(command);
        return ResponseEntity
                .accepted()
                .body(orderId);
    }

    @GetMapping("/{id}")
    public ResponseEntity<Order> getOrder(@PathVariable UUID id) {
        return queryService.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    // Admin: rebuilds the entire read model from the event log
    @GetMapping("/admin/replay")
    public ResponseEntity<Map<String, Integer>> replayEvents() {
        int count = eventReplayService.replayAllEvents();
        return ResponseEntity.ok(Map.of("eventsReplayed", count));
    }
}
