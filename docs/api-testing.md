# API Testing Guide

This guide covers all available endpoints across the three microservices with ready-to-run curl commands for each scenario.

## Prerequisites

All services must be running locally via Docker Compose:

```bash
docker compose up -d
```

| Service         | Base URL                  |
|-----------------|---------------------------|
| order-service   | http://localhost:8081     |
| payment-service | http://localhost:8082     |
| user-service    | http://localhost:8083     |

---

## Quick Start (Full Flow)

Run these three commands in order to go from zero to a confirmed order:

```bash
# 1. Create a user
USER_ID=$(curl -s -X POST http://localhost:8083/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","email":"alice@example.com"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['userId'])")
echo "User ID: $USER_ID"

# 2. Place an order
ORDER_ID=$(curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d "{\"userId\":\"$USER_ID\",\"amount\":500}" | tr -d '"')
echo "Order ID: $ORDER_ID"

# 3. Check the order status
curl -s http://localhost:8081/api/orders/$ORDER_ID | python3 -m json.tool
```

Expected result: `"status": "CONFIRMED"`

---

## User Service

**Base URL:** `http://localhost:8083/api/users`

### Create a user

```bash
curl -s -X POST http://localhost:8083/api/users \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Alice",
    "email": "alice@example.com"
  }' | python3 -m json.tool
```

**Response (201):**
```json
{
    "userId": "c97c9a76-aac0-43e7-b411-92dbc822eec9",
    "email": "alice@example.com",
    "name": "Alice",
    "createdAt": "2026-07-14T04:55:47.910989752Z"
}
```

---

### Get user by ID

```bash
curl -s http://localhost:8083/api/users/{userId} | python3 -m json.tool
```

**Response (200):**
```json
{
    "userId": "c97c9a76-aac0-43e7-b411-92dbc822eec9",
    "email": "alice@example.com",
    "name": "Alice",
    "createdAt": "2026-07-14T04:55:47.910989752Z"
}
```

---

### Get non-existent user → 404

```bash
curl -s http://localhost:8083/api/users/00000000-0000-0000-0000-000000000000 \
  | python3 -m json.tool
```

**Response (404):**
```json
{
    "type": "about:blank",
    "title": "User not found",
    "status": 404,
    "detail": "User not found: 00000000-0000-0000-0000-000000000000",
    "instance": "/api/users/00000000-0000-0000-0000-000000000000"
}
```

---

## Order Service

**Base URL:** `http://localhost:8081/api/orders`

> **Payment rule:** amount **< 10,000** → payment APPROVED → order `CONFIRMED`.
> Amount **>= 10,000** → payment FAILED → order `FAILED`.

### Create order → CONFIRMED

Amount is below the 10,000 threshold so payment is approved.

```bash
curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "{userId}",
    "amount": 500
  }' | python3 -m json.tool
```

**Response (201):** Returns the new order UUID.

Then fetch the order to confirm the status:

```bash
curl -s http://localhost:8081/api/orders/{orderId} | python3 -m json.tool
```

```json
{
    "id": "b23f8f50-ff78-4cc6-ad11-09f46f8fc391",
    "userId": "c97c9a76-aac0-43e7-b411-92dbc822eec9",
    "amount": 500.0,
    "status": "CONFIRMED",
    "createdAt": "2026-07-14T04:55:56.845062Z"
}
```

---

### Create order → FAILED (payment rejected)

Amount meets or exceeds the 10,000 threshold so payment is rejected.

```bash
curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "{userId}",
    "amount": 10000
  }' | python3 -m json.tool
```

Fetch the order:

```bash
curl -s http://localhost:8081/api/orders/{orderId} | python3 -m json.tool
```

```json
{
    "id": "fd6e0906-6189-44e8-9812-6ae5faaaa4bb",
    "userId": "c97c9a76-aac0-43e7-b411-92dbc822eec9",
    "amount": 10000.0,
    "status": "FAILED",
    "createdAt": "2026-07-14T04:56:05.247552Z"
}
```

---

### Create order → 404 (unknown user)

Order-service validates the user with user-service before creating the order.

```bash
curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "00000000-0000-0000-0000-000000000000",
    "amount": 100
  }' | python3 -m json.tool
```

**Response (404):**
```json
{
    "type": "about:blank",
    "title": "User not found",
    "status": 404,
    "detail": "User not found: 00000000-0000-0000-0000-000000000000",
    "instance": "/api/orders"
}
```

---

### Create order → 400 (missing amount)

```bash
curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "{userId}"
  }' | python3 -m json.tool
```

**Response (400):**
```json
{
    "type": "about:blank",
    "title": "Bad Request",
    "status": 400,
    "detail": "amount must not be null"
}
```

---

### Create order → 400 (zero amount)

```bash
curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "{userId}",
    "amount": 0
  }' | python3 -m json.tool
```

**Response (400):**
```json
{
    "type": "about:blank",
    "title": "Bad Request",
    "status": 400,
    "detail": "amount must be greater than 0"
}
```

---

### Create order → 400 (missing userId)

```bash
curl -s -X POST http://localhost:8081/api/orders \
  -H "Content-Type: application/json" \
  -d '{
    "amount": 100
  }' | python3 -m json.tool
```

**Response (400):**
```json
{
    "type": "about:blank",
    "title": "Bad Request",
    "status": 400,
    "detail": "userId must not be blank"
}
```

---

### Get order by ID

```bash
curl -s http://localhost:8081/api/orders/{orderId} | python3 -m json.tool
```

---

### Get non-existent order → 404

```bash
curl -s http://localhost:8081/api/orders/00000000-0000-0000-0000-000000000000 \
  | python3 -m json.tool
```

**Response (404):** Empty body with HTTP 404 status.

---

### Trigger event replay (admin)

Rebuilds the entire orders read model from the event log. Useful after data corruption or a schema migration.

```bash
curl -s http://localhost:8081/api/orders/admin/replay | python3 -m json.tool
```

**Response (200):**
```json
{
    "eventsReplayed": 9
}
```

---

## Payment Service

**Base URL:** `http://localhost:8082/api/payments`

> Payment is called internally by order-service during order creation. These endpoints are available for direct testing.

### Create payment → APPROVED

```bash
curl -s -X POST http://localhost:8082/api/payments \
  -H "Content-Type: application/json" \
  -d '{
    "orderId": "11111111-1111-1111-1111-111111111111",
    "userId": "{userId}",
    "amount": 500
  }' | python3 -m json.tool
```

**Response (200):**
```json
{
    "id": "...",
    "orderId": "11111111-1111-1111-1111-111111111111",
    "userId": "...",
    "amount": 500.0,
    "status": "APPROVED"
}
```

---

### Create payment → FAILED (amount >= 10,000)

```bash
curl -s -X POST http://localhost:8082/api/payments \
  -H "Content-Type: application/json" \
  -d '{
    "orderId": "22222222-2222-2222-2222-222222222222",
    "userId": "{userId}",
    "amount": 10000
  }' | python3 -m json.tool
```

**Response (200):**
```json
{
    "id": "...",
    "orderId": "22222222-2222-2222-2222-222222222222",
    "userId": "...",
    "amount": 10000.0,
    "status": "FAILED"
}
```

---

### Refund a payment

```bash
curl -s -X POST http://localhost:8082/api/payments/{paymentId}/refund \
  | python3 -m json.tool
```

**Response (200):**
```json
{
    "id": "...",
    "status": "REFUNDED"
}
```

---

## Health Checks

```bash
curl -s http://localhost:8081/actuator/health | python3 -m json.tool   # order-service
curl -s http://localhost:8082/actuator/health | python3 -m json.tool   # payment-service
curl -s http://localhost:8083/actuator/health | python3 -m json.tool   # user-service
```

All three should return `"status": "UP"` with database connectivity confirmed.
