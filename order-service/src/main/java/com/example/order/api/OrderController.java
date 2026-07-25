package com.example.order.api;

import com.example.order.command.CreateOrderCommand;
import com.example.order.command.EventReplayService;
import com.example.order.command.OrderCommandHandler;
import com.example.order.query.OrderQueryService;
import com.example.order.readmodel.Order;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
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

    @Value("${services.internal-api-key}")
    private String internalApiKey;

    @PostMapping
    public ResponseEntity<UUID> createOrder(@Valid @RequestBody CreateOrderCommand command) {
        UUID orderId = commandHandler.handle(command);
        // 202 Accepted — order is PENDING; SAGA runs asynchronously via Step Functions
        return ResponseEntity.accepted().body(orderId);
    }

    @GetMapping("/{id}")
    public ResponseEntity<Order> getOrder(@PathVariable UUID id) {
        return queryService.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    /**
     * Internal endpoint called by the Step Functions ConfirmOrder Lambda.
     * Protected by X-Internal-Api-Key; not exposed through Cognito-authenticated paths.
     */
    @PostMapping("/{id}/confirm")
    public ResponseEntity<Void> confirmOrder(
            @PathVariable UUID id,
            @RequestHeader(value = "X-Internal-Api-Key", required = false) String providedKey) {
        if (!internalApiKey.equals(providedKey)) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).build();
        }
        commandHandler.confirm(id);
        return ResponseEntity.ok().build();
    }

    /**
     * Internal endpoint called by the Step Functions CancelOrder Lambda.
     * Protected by X-Internal-Api-Key; not exposed through Cognito-authenticated paths.
     */
    @PostMapping("/{id}/cancel")
    public ResponseEntity<Void> cancelOrder(
            @PathVariable UUID id,
            @RequestHeader(value = "X-Internal-Api-Key", required = false) String providedKey) {
        if (!internalApiKey.equals(providedKey)) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).build();
        }
        commandHandler.cancel(id);
        return ResponseEntity.ok().build();
    }

    // Admin: rebuilds the entire read model from the event log
    @GetMapping("/admin/replay")
    public ResponseEntity<Map<String, Integer>> replayEvents() {
        int count = eventReplayService.replayAllEvents();
        return ResponseEntity.ok(Map.of("eventsReplayed", count));
    }
}
