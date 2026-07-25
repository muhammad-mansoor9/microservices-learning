# Scenario 2 — Setup, Deploy & Verify Runbook

**Purpose.** A step-by-step operational guide that takes you from a bare AWS account to a working end-to-end system, then walks you through testing the happy path, the SAGA rollback, and every observability surface. Companion to [`scenario-2.md`](scenario-2.md), which explains the *why* behind each file — this doc is the *how*.

**Time budget.** ~45 minutes the first time (mostly waiting for RDS / Fargate). Later runs after destroy are ~30 minutes.

**Approximate cost while running.** ~$120/month at idle if you leave it up (see `scenario-2.md` §14). `terraform destroy` between sessions to keep it near zero.

---

## Contents

1. [Prerequisites](#1-prerequisites)
2. [One-time manual pre-work](#2-one-time-manual-pre-work)
3. [Bootstrap: create the Terraform state backend](#3-bootstrap-create-the-terraform-state-backend)
4. [Configure `terraform.tfvars`](#4-configure-terraformtfvars)
5. [`terraform apply` — phase 1 (infrastructure)](#5-terraform-apply--phase-1-infrastructure)
6. [Seed ECR with initial images](#6-seed-ecr-with-initial-images)
7. [`terraform apply` — phase 2 (ECS services come healthy)](#7-terraform-apply--phase-2-ecs-services-come-healthy)
8. [Post-apply seeding: Cognito user + SNS confirm](#8-post-apply-seeding)
9. [Happy-path test: create an order end-to-end](#9-happy-path-test)
10. [Failure-path tests: SAGA compensations](#10-failure-path-tests)
11. [Observability verification](#11-observability-verification)
12. [CI/CD verification: push a change](#12-cicd-verification)
13. [Tear down](#13-tear-down)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Prerequisites

**On your machine:**
- **AWS CLI v2** — `aws --version` should print v2.x.
- **Terraform ≥ 1.5** — `terraform version`.
- **Docker** — required for the initial ECR push and any local build.
- **Maven ≥ 3.9** and **JDK 21** — for local builds. (CI does this for you afterwards.)
- **jq** — used in a few verification commands.
- **git** — you already have it.

**Configure AWS credentials.** The account you use must be able to create VPCs, IAM roles, ECS services, RDS, Lambda, Step Functions, CloudWatch resources, CodePipeline, etc. In practice this means an admin-ish user or an SSO role with `AdministratorAccess` while learning.

```bash
aws configure                            # or aws configure sso
aws sts get-caller-identity              # sanity check — should print your account id
export AWS_REGION=us-east-1              # this project is pinned to us-east-1
```

**Clone the repo and switch to the scenario branch:**

```bash
git clone git@github.com:muhammad-mansoor9/microservices-learning.git
cd microservices-learning
git checkout scenario-2-ecs
```

---

## 2. One-time manual pre-work

Two things Terraform cannot create for you, because they require human authorization in a browser.

### 2.1 Create a CodeStar Connection to GitHub

CodePipeline needs a signed connection to your GitHub account. You create this **once per account**, then reuse the ARN.

1. Open the AWS console → **Developer Tools → Settings → Connections**.
2. **Create connection** → *GitHub* → give it a name like `github-microservices-learning`.
3. Click **Connect to GitHub**, install the AWS Connector GitHub App on your account/org, grant it access to the `microservices-learning` repo.
4. On the connection detail page, the status flips to **Available**. Copy the **ARN** (looks like `arn:aws:codestar-connections:us-east-1:123456789012:connection/abcdef01-...`).

You'll paste this into `terraform.tfvars` in step 4.

### 2.2 Optional — decide on an alert email

Alarms fire to an SNS topic. If you set `alert_email_address` in `tfvars`, Terraform will create an email subscription. AWS then sends a confirmation email — you must click the link before you start receiving alerts. If you don't want email alerts yet, leave the variable empty; the topic still exists and you can subscribe later.

---

## 3. Bootstrap: create the Terraform state backend

The `scenario-2/` config uses an S3 backend for state and a DynamoDB table for locking (see `provider.tf`). Both are created by a separate one-shot Terraform module in `infrastructure/bootstrap/`.

If a colleague already ran this against the target account, skip to step 4 — the bucket and table exist. Otherwise:

```bash
cd infrastructure/bootstrap
cp terraform.tfvars.example terraform.tfvars
# open terraform.tfvars, confirm the bucket/table names and region

terraform init
terraform apply
```

Expected outputs:
- S3 bucket `microservices-learning-terraform-state-dev` (versioning + SSE enabled)
- DynamoDB table `microservices-learning-terraform-locks-dev` with a `LockID` hash key

**Verify:**

```bash
aws s3 ls | grep microservices-learning-terraform-state
aws dynamodb list-tables --output table | grep microservices-learning-terraform-locks
```

You will not touch this stack again unless you decide to change the state backend.

---

## 4. Configure `terraform.tfvars`

```bash
cd ../scenario-2
cat > terraform.tfvars <<'EOF'
db_password             = "ChangeMe_StrongPassword_123!"
codestar_connection_arn = "arn:aws:codestar-connections:us-east-1:123456789012:connection/abcdef01-2345-..."

# Optional — leave empty to skip the email subscription
alert_email_address     = "you@example.com"

# Optional — override defaults if you forked or renamed the repo
# github_repository_id  = "your-user/microservices-learning"
# github_branch         = "scenario-2-ecs"
EOF
```

**Do not commit `terraform.tfvars`.** It contains the DB password. The `.gitignore` at repo root already excludes it.

---

## 5. `terraform apply` — phase 1 (infrastructure)

Initial apply creates ~120 resources and takes 12–15 minutes (RDS is the long pole at ~8 minutes each).

```bash
terraform init          # downloads AWS + random + archive providers, wires the S3 backend
terraform validate      # syntax + type check, offline
terraform plan          # review — expect ~120 "will be created"
terraform apply         # type "yes" when prompted
```

**Expected behaviour:** ECS services will be created but **the tasks will fail to start** because the ECR repos are empty. That's fine — you'll seed the repos next, then re-apply to let the services come healthy. You'll see errors like *"CannotPullContainerError: ref pull has been retried 5 times"* in the ECS console. Ignore them for now.

**Capture the outputs:**

```bash
terraform output > /tmp/scenario-2-outputs.txt
cat /tmp/scenario-2-outputs.txt
```

You'll want these values handy:
- `alb_dns_name` (external endpoint)
- `ecr_order_service_url`, `ecr_payment_service_url`, `ecr_user_service_url`
- `cognito_user_pool_id`, `cognito_api_test_client_id`
- `codepipeline_url`, `cloudwatch_dashboard_url`
- `order_saga_state_machine_arn`

---

## 6. Seed ECR with initial images

CodePipeline will build and push images from GitHub going forward, but on first apply the repos are empty and ECS can't pull anything. Push a first image for each service from your workstation.

```bash
# From repo root
cd ../..                                             # back to microservices-learning/
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
REGISTRY=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# Login docker to ECR
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

# Build each image (multi-stage Dockerfiles handle the mvn package)
for svc in order-service payment-service user-service; do
  docker build -t $REGISTRY/$svc:latest -f $svc/Dockerfile .
  docker push $REGISTRY/$svc:latest
done
```

**Verify the pushes:**

```bash
for svc in order-service payment-service user-service; do
  aws ecr describe-images --repository-name $svc \
    --query 'imageDetails[0].{tag:imageTags[0],pushedAt:imagePushedAt}' --output table
done
```

Each row should show `latest` with a recent timestamp.

---

## 7. `terraform apply` — phase 2 (ECS services come healthy)

Force ECS to redeploy the services now that images exist:

```bash
CLUSTER=$(terraform -chdir=infrastructure/scenario-2 output -raw ecs_cluster_name 2>/dev/null || echo "ms-learning-cluster")

for svc in order-service payment-service user-service; do
  aws ecs update-service --cluster $CLUSTER --service $svc --force-new-deployment >/dev/null
  echo "Redeployed $svc"
done
```

**Watch tasks come up:**

```bash
# Repeat until desiredCount == runningCount for all three
aws ecs describe-services --cluster $CLUSTER --services order-service payment-service user-service \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount}' \
  --output table
```

**Verify ALB target health:**

```bash
for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[?contains(TargetGroupName, `ms-learning`) && contains(TargetGroupName, `blue`)].TargetGroupArn' --output text); do
  echo "=== $(basename $tg) ==="
  aws elbv2 describe-target-health --target-group-arn $tg \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text
done
```

Expect `healthy` for each blue TG. Health checks take ~60s after the task shows RUNNING (Spring Boot startup + `/actuator/health` warm-up).

---

## 8. Post-apply seeding

### 8.1 Confirm the SNS subscription

If you supplied `alert_email_address`, check your inbox for **"AWS Notification - Subscription Confirmation"**. Click the confirmation link. Verify:

```bash
TOPIC_ARN=$(terraform -chdir=infrastructure/scenario-2 output -raw alerts_sns_topic_arn)
aws sns list-subscriptions-by-topic --topic-arn $TOPIC_ARN \
  --query 'Subscriptions[].{endpoint:Endpoint,status:SubscriptionArn}' --output table
```

`status` should be a full ARN (confirmed), not the string `PendingConfirmation`.

### 8.2 Create a Cognito user for API testing

We use the `api_test` client (no secret) to authenticate against the API.

```bash
POOL_ID=$(terraform -chdir=infrastructure/scenario-2 output -raw cognito_user_pool_id)
CLIENT_ID=$(terraform -chdir=infrastructure/scenario-2 output -raw cognito_api_test_client_id)

# Create the user
aws cognito-idp admin-create-user \
  --user-pool-id $POOL_ID \
  --username test@example.com \
  --user-attributes Name=email,Value=test@example.com Name=email_verified,Value=true \
  --message-action SUPPRESS

# Set a permanent password (skip the forced-change flow)
aws cognito-idp admin-set-user-password \
  --user-pool-id $POOL_ID \
  --username test@example.com \
  --password 'TestUser_Password_123!' \
  --permanent
```

**Get a JWT to use for API calls:**

```bash
ID_TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --auth-parameters USERNAME=test@example.com,PASSWORD='TestUser_Password_123!' \
  --query 'AuthenticationResult.IdToken' --output text)

echo "ID token acquired: ${ID_TOKEN:0:40}..."     # first 40 chars for sanity
```

The `ID_TOKEN` variable is used in the tests below.

### 8.3 Seed a user in DynamoDB

The order-service validates that `userId` exists in DynamoDB before it starts a SAGA. Create one user record directly with the CLI so we don't need to test the user-service admin flow first.

```bash
TABLE=$(terraform -chdir=infrastructure/scenario-2 output -raw dynamodb_users_table)

aws dynamodb put-item --table-name $TABLE \
  --item '{"userId":{"S":"11111111-1111-1111-1111-111111111111"},"email":{"S":"test@example.com"},"name":{"S":"Test User"},"tier":{"S":"REGULAR"}}'
```

---

## 9. Happy-path test

The full flow:
```
POST /api/orders (via ALB)
   → order-service validates user (Service Connect → user-service → DynamoDB)
   → order-service persists PENDING order + OrderCreatedEvent
   → order-service calls SFN.StartExecution
   → returns 202 Accepted with the orderId

Step Functions runs:
   ValidateUser → ProcessPayment → CheckPaymentStatus(APPROVED) → ConfirmOrder → OrderComplete
```

### 9.1 Fire the request

```bash
ALB=$(terraform -chdir=infrastructure/scenario-2 output -raw alb_dns_name)

ORDER_ID=$(curl -sS -X POST "http://$ALB/api/orders" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"userId":"11111111-1111-1111-1111-111111111111","amount":50.00}')

echo "Order id: $ORDER_ID"
```

The response is the raw UUID (order-service returns it in the body of the 202). If you're on a shell that mangles the response, run `curl -i` to see headers — HTTP status should be `202 Accepted`.

### 9.2 Watch the SAGA execute

```bash
SFN_ARN=$(terraform -chdir=infrastructure/scenario-2 output -raw order_saga_state_machine_arn)

# Executions are named after the orderId (idempotency)
aws stepfunctions describe-execution \
  --execution-arn "$SFN_ARN:$ORDER_ID" \
  --query '{status:status,startDate:startDate,stopDate:stopDate,output:output}' \
  --output json
```

Or open the URL in the browser:

```bash
echo "https://us-east-1.console.aws.amazon.com/states/home?region=us-east-1#/executions/details/$SFN_ARN:$ORDER_ID"
```

You should see a green happy path through **ValidateUser → ProcessPayment → CheckPaymentStatus → ConfirmOrder → OrderComplete**. The whole thing typically finishes in 5–8 seconds (mostly Lambda cold starts).

### 9.3 Verify the read model

```bash
curl -sS "http://$ALB/api/orders/$ORDER_ID" \
  -H "Authorization: Bearer $ID_TOKEN" | jq
```

Expect `"status": "CONFIRMED"`. If it's still `PENDING`, the SAGA hasn't finished yet — wait a few seconds and retry.

### 9.4 Verify the custom CloudWatch metric

```bash
# Get metric data for the last 10 minutes
aws cloudwatch get-metric-statistics \
  --namespace MsLearning \
  --metric-name OrdersCreated \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Sum \
  --output table
```

You should see at least one non-zero datapoint. CloudWatch can lag 60–90 seconds — retry if the query returns empty.

---

## 10. Failure-path tests

The SAGA is only interesting if the compensations work. Two scenarios exercise them.

### 10.1 User not found → OrderFailed (no compensation)

Post an order for a user that isn't in DynamoDB. `order-service` validates synchronously and returns 4xx before starting the SAGA — but the SAGA also has a `Catch` on `ValidateUser` for the case where a Lambda error slips through. This exercises the pre-SAGA guard.

```bash
curl -i -X POST "http://$ALB/api/orders" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"userId":"00000000-0000-0000-0000-000000000000","amount":50.00}'
```

Expect **HTTP 404** with a body containing `User not found`. No SFN execution is started (verify via the executions list — no new entry).

### 10.2 Payment fails → RefundPayment → CancelOrder → OrderFailed

Payment-service's stub in `PaymentService.createPayment` fails any request with `amount >= 10000`. Firing such an order runs the SAGA all the way to compensation.

```bash
ORDER_ID=$(curl -sS -X POST "http://$ALB/api/orders" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"userId":"11111111-1111-1111-1111-111111111111","amount":15000}')

echo "Rollback order: $ORDER_ID"

# Watch the SFN execution
aws stepfunctions describe-execution \
  --execution-arn "$SFN_ARN:$ORDER_ID" \
  --query '{status:status,error:error,cause:cause}' --output json
```

Expected path in the Step Functions console:

```
ValidateUser (green) → ProcessPayment (green) → CheckPaymentStatus (green)
        └─ status ≠ APPROVED
           └─▶ RefundPayment (green) → CancelOrder (green) → OrderFailed (fail state)
```

**Verify the read model reflects the compensation:**

```bash
curl -sS "http://$ALB/api/orders/$ORDER_ID" -H "Authorization: Bearer $ID_TOKEN" | jq
```

`"status": "CANCELLED"`.

**Verify the event log** — the order-service uses event sourcing, so you should see three events for this order in the DB:

```bash
# Connect via a bastion or use RDS Query Editor. Or via psql from within the VPC / an SSM session.
# SELECT event_type, occurred_at FROM order_events WHERE aggregate_id = '<order_id>' ORDER BY version;
# Expect: OrderCreated, OrderCancelled  (and possibly PaymentFailed depending on wiring)
```

### 10.3 Verify auto-rollback: force a bad image

We'll simulate a bad deploy in [§12.2](#122-bad-deploy--auto-rollback). Skip for now.

---

## 11. Observability verification

### 11.1 CloudWatch dashboard

```bash
open "$(terraform -chdir=infrastructure/scenario-2 output -raw cloudwatch_dashboard_url)"
```

After running the tests above you should see:
- ECS CPU/Memory line graphs with data for all three services.
- SQS depth graphs (probably near zero — the SAGA drains fast).
- ALB traffic: your test requests appear as a spike.
- Step Functions ExecutionsSucceeded + ExecutionsFailed.
- `OrdersCreated` custom metric with a bar per happy-path order.

### 11.2 Structured JSON logs

```bash
aws logs tail /ms-learning/order-service --since 5m --format short
```

Every line is a JSON object. Grab one and inspect:

```bash
aws logs tail /ms-learning/order-service --since 5m --format json | tail -1 | jq
```

You should see fields `timestamp`, `level`, `logger`, `message`, `service`, `version`, and — for request-scoped log lines — `traceId`.

### 11.3 Logs Insights saved queries

Open **CloudWatch → Logs Insights**. In the *Queries* pane on the right you'll see three saved queries under `ms-learning/`:
- `RecentErrors` — run it, expect no matches unless you deliberately broke something.
- `OrdersByStatus` — needs actual `status=...` log messages; may return no rows depending on how much the services log.
- `TraceSearch` — replace `TRACE_ID_HERE` in the query with an actual trace id (see next section) and run.

### 11.4 X-Ray service map

```bash
open "https://us-east-1.console.aws.amazon.com/xray/home?region=us-east-1#/service-map"
```

Wait 60–90 seconds after firing requests. You should see nodes for each service and edges showing the request flow:

```
client → order-service ─▶ user-service
                       └─▶ payment-service (via SAGA/Lambda)
```

Click a node → view traces → pick one → you'll see the parent segment and the `user-service-call`, `saga-start`, and `payment-processing` subsegments with timing.

**Grab a trace id for TraceSearch:**

```bash
aws xray get-trace-summaries \
  --start-time $(date -u -v-10M +%s 2>/dev/null || date -u -d '10 minutes ago' +%s) \
  --end-time $(date -u +%s) \
  --query 'TraceSummaries[0].Id' --output text
```

Paste that id into the `TraceSearch` Logs Insights query to see every log line correlated to that request.

### 11.5 Alarm state

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix ms-learning \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table
```

Everything should be in `OK` or `INSUFFICIENT_DATA` (metric hasn't fired yet). Any `ALARM` state is a signal.

**Force an alarm to test SNS delivery:**

```bash
# Manually flip the CPU alarm for order-service to ALARM
aws cloudwatch set-alarm-state \
  --alarm-name ms-learning-order-service-cpu-high \
  --state-value ALARM \
  --state-reason 'manual test'
```

If you subscribed via email, you'll receive a message within ~30 seconds. Alarm will auto-return to `OK` on the next metric datapoint (or after ~5 minutes if the metric hadn't been reporting).

---

## 12. CI/CD verification

### 12.1 First pipeline run

```bash
open "$(terraform -chdir=infrastructure/scenario-2 output -raw codepipeline_url)"
```

**Kick off a run** by making any trivial change and pushing:

```bash
echo "# ci test $(date -u)" >> README.md
git add README.md
git commit -m "test: kick pipeline"
git push origin scenario-2-ecs
```

CodePipeline detects the push (via the CodeStar connection) within seconds. Watch the stages:
1. **Source** (~5s) — GitHub webhook fires, artifact copied to S3.
2. **Build** (~4–6 min) — CodeBuild runs `buildspec.yml`: mvn package, docker build ×3, docker push ×3, generate `taskdef-*.json` + `appspec-*.yaml`.
3. **Deploy-Order** (~5–8 min) — CodeDeploy blue/green: launches a new task set on the green TG, runs health checks, then swaps the ALB listener from blue to green in one go (AllAtOnce). Old task set stays around for 5 min before termination.
4. **Deploy-Payment** — same pattern on the internal ALB.
5. **Deploy-User** — same.

Total ~15–25 min end to end for the first run (cold Maven cache).

**Verify the new image is running:**

```bash
aws ecs describe-services --cluster $CLUSTER --services order-service \
  --query 'services[0].taskDefinition' --output text
```

The revision number should have incremented from `:1` to `:2`.

### 12.2 Bad-deploy → auto-rollback

Simulate a broken image by deliberately failing the app health check.

```bash
# Add a Dockerfile line that makes /actuator/health 500. E.g. inject an env:
git checkout -b test/bad-deploy
sed -i.bak '/ENTRYPOINT/i ENV SPRING_PROFILES_ACTIVE=fail-on-start' order-service/Dockerfile
git commit -am "test: break order-service health"
git push origin test/bad-deploy
```

Since the pipeline tracks `scenario-2-ecs`, it won't trigger from this branch. Temporarily point it:

```bash
# In infrastructure/scenario-2/terraform.tfvars, change:
#   github_branch = "test/bad-deploy"
terraform -chdir=infrastructure/scenario-2 apply
```

Push another commit to `test/bad-deploy` to fire the pipeline. Expected behaviour:
- Build succeeds (the image builds — it just fails at runtime).
- Deploy-Order starts, CodeDeploy launches the new task on the green TG, health checks fail, CodeDeploy waits for the deployment timeout, then **rolls back**: traffic never shifts, green tasks are terminated, blue remains serving. Pipeline stage shows **Failed**.

**Clean up:**

```bash
# Reset the branch in terraform.tfvars, push a fix, apply
git checkout scenario-2-ecs
terraform -chdir=infrastructure/scenario-2 apply
git branch -D test/bad-deploy
git push origin --delete test/bad-deploy
```

---

## 13. Tear down

```bash
cd infrastructure/scenario-2
terraform destroy
```

Roughly the reverse of apply. Two things to watch:

**Service Discovery namespace deletion often fails** because ECS Service Connect leaves orphan registrations. If `terraform destroy` hangs on the namespace, run this cleanup and retry:

```bash
NS_ID=$(aws servicediscovery list-namespaces --query 'Namespaces[?Name==`ms-learning.local`].Id' --output text)

# Delete all services in the namespace
for svc_id in $(aws servicediscovery list-services --filters "Name=NAMESPACE_ID,Values=$NS_ID" --query 'Services[].Id' --output text); do
  # Deregister every instance under the service
  for inst_id in $(aws servicediscovery list-instances --service-id $svc_id --query 'Instances[].Id' --output text); do
    aws servicediscovery deregister-instance --service-id $svc_id --instance-id $inst_id
  done
  aws servicediscovery delete-service --id $svc_id
done

# Retry destroy
terraform destroy
```

**RDS `final_snapshot`** — the RDS instances have `skip_final_snapshot = true` on this branch, so destroy is fast. Confirm you're OK with this before running in a real environment.

**Bootstrap stack** — leave it up unless you're wiping the account. Re-creating S3 backends is annoying.

---

## 14. Troubleshooting

### `terraform apply` errors

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: Missing required argument … codestar_connection_arn` | Forgot to set the var. | Add to `terraform.tfvars` (step 4). |
| `InvalidClientTokenId: The security token included in the request is invalid` | AWS credentials expired (SSO). | `aws sso login` (or refresh your creds) and retry. |
| `SubnetsIndexOutOfBounds` on ALB | Region has < 2 AZs available. | Change `var.aws_region` to a region with ≥ 2 AZs. |
| `CannotPullContainerError` on ECS tasks | ECR repos empty. | Run step 6 (seed ECR) then step 7 (force redeploy). |
| `Failed to describe task definition` in CodeBuild | The buildspec references `ms-learning-<svc>` but no revision exists yet. | Run `terraform apply` first — task definitions are Terraform-managed. |

### ECS tasks flapping

```bash
# Check the stopped task's reason
CLUSTER=ms-learning-cluster
aws ecs list-tasks --cluster $CLUSTER --service-name order-service --desired-status STOPPED --query 'taskArns[0]' --output text \
  | xargs -I{} aws ecs describe-tasks --cluster $CLUSTER --tasks {} --query 'tasks[0].{reason:stoppedReason,exit:containers[0].exitCode}'
```

Most common causes:
- `HealthCheckFailure` — `/actuator/health` returned 5xx (config issue, DB unreachable). Check the CloudWatch log group.
- `ResourceInitializationError: unable to pull secrets` — task-execution role can't read SSM parameter. Verify IAM.
- `Task failed to start … container exited with code 1` — Spring Boot startup failure. Check logs.

### SAGA execution stays `RUNNING`

Most often a Lambda proxy can't reach the target ECS service. Check the Lambda's CloudWatch log group (`/aws/lambda/ms-learning-saga-<step>`).

- **`No healthy instances for <svc>`** — the ECS task is not registered in Cloud Map yet (still coming up) or unhealthy. Fix the task, then either retry the execution or start a new one.
- **`urllib.error.HTTPError: HTTP Error 401`** — the internal-api-key SSM value isn't matching what order-service has cached. Force a redeploy of order-service to reload SSM.

### CloudWatch metrics missing

- **ECS metrics** need Container Insights enabled — verified on the cluster.
- **Custom `MsLearning/OrdersCreated`** — check the order-service log group for lines like *"Failed to publish OrdersCreated metric"*. Most likely the task role lacks `cloudwatch:PutMetricData` — confirm the `PublishCloudWatchMetrics` statement is present in `iam.tf`.
- Metrics can lag 60–90 seconds. Give it a minute before assuming it's broken.

### CodePipeline stuck on Source

The CodeStar Connection must be in **Available** state. Console → Developer Tools → Settings → Connections. If it says *Pending*, click through and complete the GitHub install.

### CodeDeploy stage fails

Open the failed deployment in the console. The **Events** tab shows which lifecycle hook failed:
- **BeforeInstall** — usually a permissions issue on the deployment role.
- **AfterAllowTestTraffic / AfterAllowTraffic** — health checks on the green TG never went healthy. Check the target-group health page and the ECS task log group.

---

## Quick reference — the commands you'll run most

```bash
# Grab all outputs
terraform -chdir=infrastructure/scenario-2 output

# Watch ECS
aws ecs describe-services --cluster ms-learning-cluster \
  --services order-service payment-service user-service \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount}'

# Tail logs
aws logs tail /ms-learning/order-service --follow --since 5m

# Get a fresh JWT
ID_TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --auth-parameters USERNAME=test@example.com,PASSWORD='TestUser_Password_123!' \
  --query 'AuthenticationResult.IdToken' --output text)

# Fire an order
curl -sS -X POST "http://$ALB/api/orders" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"userId":"11111111-1111-1111-1111-111111111111","amount":50}'
```
