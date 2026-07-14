# Local Observability Guide

How to inspect logs and databases while running the stack locally via Docker Compose.

---

## Container Logs

### Stream live logs (follow mode)

```bash
docker logs -f order-service
docker logs -f payment-service
docker logs -f user-service
```

### Tail the last N lines

```bash
docker logs --tail 50 order-service
docker logs --tail 50 payment-service
docker logs --tail 50 user-service
```

### Show logs since a time or duration

```bash
# Last 10 minutes
docker logs --since 10m order-service

# Since a specific timestamp
docker logs --since "2026-07-14T05:00:00" order-service
```

### Filter for errors only

```bash
docker logs order-service   2>&1 | grep -E "ERROR|Exception|WARN"
docker logs payment-service 2>&1 | grep -E "ERROR|Exception|WARN"
docker logs user-service    2>&1 | grep -E "ERROR|Exception|WARN"
```

### Filter for a specific order ID

```bash
docker logs order-service 2>&1 | grep "{orderId}"
```

### Check infrastructure containers

```bash
docker logs postgres    2>&1 | tail -20
docker logs localstack  2>&1 | tail -20
```

### View all container statuses at a glance

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

---

## PostgreSQL — order_db

Connect to the database:

```bash
docker exec -it postgres psql -U postgres -d order_db
```

Or run a single query without opening an interactive session:

```bash
docker exec postgres psql -U postgres -d order_db -c "<SQL here>"
```

### orders table

```bash
# All orders (newest first)
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT id, user_id, amount, status, created_at FROM orders ORDER BY created_at DESC;"

# Orders by status
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT id, amount, status, created_at FROM orders WHERE status = 'CONFIRMED' ORDER BY created_at DESC;"

docker exec postgres psql -U postgres -d order_db -c \
  "SELECT id, amount, status, created_at FROM orders WHERE status = 'FAILED' ORDER BY created_at DESC;"

docker exec postgres psql -U postgres -d order_db -c \
  "SELECT id, amount, status, created_at FROM orders WHERE status = 'PENDING' ORDER BY created_at DESC;"

# Orders for a specific user
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT id, amount, status, created_at FROM orders WHERE user_id = '{userId}' ORDER BY created_at DESC;"

# Single order by ID
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT * FROM orders WHERE id = '{orderId}';"

# Order counts by status
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT status, COUNT(*) FROM orders GROUP BY status;"
```

### order_events table (event log)

Each order writes at least one event (`OrderCreated`) and one terminal event (`OrderConfirmed`, `OrderFailed`, or `OrderCancelled`).

```bash
# All events (newest first)
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT aggregate_id, event_type, version, occurred_at FROM order_events ORDER BY occurred_at DESC LIMIT 20;"

# Full event history for a specific order (chronological)
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT event_type, version, payload, occurred_at FROM order_events WHERE aggregate_id = '{orderId}' ORDER BY version ASC;"

# Event counts by type
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT event_type, COUNT(*) FROM order_events GROUP BY event_type ORDER BY count DESC;"

# Orders with only an OrderCreated event (stuck in PENDING / no terminal event)
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT aggregate_id FROM order_events GROUP BY aggregate_id HAVING COUNT(*) = 1;"
```

---

## PostgreSQL — payment_db

Connect to the database:

```bash
docker exec -it postgres psql -U postgres -d payment_db
```

### payments table

```bash
# All payments (newest first)
docker exec postgres psql -U postgres -d payment_db -c \
  "SELECT id, order_id, user_id, amount, status, created_at FROM payments ORDER BY created_at DESC;"

# Payments by status
docker exec postgres psql -U postgres -d payment_db -c \
  "SELECT id, order_id, amount, status FROM payments WHERE status = 'APPROVED' ORDER BY created_at DESC;"

docker exec postgres psql -U postgres -d payment_db -c \
  "SELECT id, order_id, amount, status FROM payments WHERE status = 'FAILED' ORDER BY created_at DESC;"

# Payment for a specific order
docker exec postgres psql -U postgres -d payment_db -c \
  "SELECT * FROM payments WHERE order_id = '{orderId}';"

# Payment counts by status
docker exec postgres psql -U postgres -d payment_db -c \
  "SELECT status, COUNT(*) FROM payments GROUP BY status;"
```

---

## DynamoDB (LocalStack) — users table

The user-service stores users in DynamoDB, running locally via LocalStack on port `4566`.

> Requires AWS CLI. Credentials and region are hardcoded for LocalStack — the values below are correct.

### List all users

```bash
aws dynamodb scan \
  --endpoint-url http://localhost:4566 \
  --region us-east-1 \
  --table-name users \
  --output json | python3 -m json.tool
```

### Get a specific user by ID

```bash
aws dynamodb get-item \
  --endpoint-url http://localhost:4566 \
  --region us-east-1 \
  --table-name users \
  --key '{"userId": {"S": "{userId}"}}' \
  | python3 -m json.tool
```

### Count total users

```bash
aws dynamodb scan \
  --endpoint-url http://localhost:4566 \
  --region us-east-1 \
  --table-name users \
  --select COUNT \
  --output json
```

### List all DynamoDB tables (confirm table exists)

```bash
aws dynamodb list-tables \
  --endpoint-url http://localhost:4566 \
  --region us-east-1
```

---

## Tracing an Order End-to-End

Given an `{orderId}`, use these queries in sequence to trace the full lifecycle:

**Step 1 — Read model (what the API returns):**
```bash
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT id, user_id, amount, status, created_at FROM orders WHERE id = '{orderId}';"
```

**Step 2 — Event log (what actually happened):**
```bash
docker exec postgres psql -U postgres -d order_db -c \
  "SELECT event_type, version, payload, occurred_at FROM order_events WHERE aggregate_id = '{orderId}' ORDER BY version ASC;"
```

**Step 3 — Payment record (what payment-service recorded):**
```bash
docker exec postgres psql -U postgres -d payment_db -c \
  "SELECT id, amount, status, created_at FROM payments WHERE order_id = '{orderId}';"
```

**Step 4 — Application logs:**
```bash
docker logs order-service   2>&1 | grep "{orderId}"
docker logs payment-service 2>&1 | grep "{orderId}"
```

---

## Useful Shortcuts

### Open an interactive psql session

```bash
# order database
docker exec -it postgres psql -U postgres -d order_db

# payment database
docker exec -it postgres psql -U postgres -d payment_db
```

Useful psql meta-commands once inside:

| Command      | Description                     |
|--------------|---------------------------------|
| `\dt`        | List all tables                 |
| `\d orders`  | Describe the orders table       |
| `\q`         | Quit                            |

### Reset all data (destructive)

```bash
docker exec postgres psql -U postgres -d order_db   -c "TRUNCATE orders, order_events RESTART IDENTITY CASCADE;"
docker exec postgres psql -U postgres -d payment_db -c "TRUNCATE payments RESTART IDENTITY CASCADE;"
```

### Rebuild the read model from the event log

If the `orders` table gets out of sync with `order_events`, trigger a replay via the admin endpoint:

```bash
curl -s http://localhost:8081/api/orders/admin/replay | python3 -m json.tool
```
