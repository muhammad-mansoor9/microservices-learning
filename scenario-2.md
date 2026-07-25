# Scenario 2 — AWS-Native Microservices on ECS

**Audience.** An application engineer who already writes Spring Boot / Java services and wants a concrete tour of the cloud infrastructure that runs them in production. This document walks through every file in `infrastructure/scenario-2/`, explains *what* it creates, *why* that piece exists, and how it differs from the Spring-Cloud-based Scenario 1.

**How to read this.** Sections roughly follow the order infrastructure is layered on top of AWS. Skim the "Contrast with Scenario 1" boxes for the fastest architectural picture. "Deeper dive" boxes go under the hood — skip on first read if you're just orienting.

---

## Table of Contents

1. [Introduction & mental model](#1-introduction--mental-model)
2. [Scenario 1 vs Scenario 2 — architectural diff](#2-scenario-1-vs-scenario-2--architectural-diff)
3. [Terraform basics used throughout](#3-terraform-basics-used-throughout)
4. [Networking foundation — `vpc.tf`, `sg.tf`](#4-networking-foundation)
5. [Compute — `ecs_cluster.tf`, `ecs_services.tf`, `ecr.tf`](#5-compute-ecs-fargate)
6. [Data layer — `rds.tf`, `dynamodb.tf`](#6-data-layer)
7. [Messaging & orchestration — `sqs.tf`, `step_functions.tf`, `step_functions/order_saga.json`](#7-messaging--orchestration)
8. [Load balancing — `alb.tf`](#8-load-balancing)
9. [Identity & authorization — `cognito.tf`, `iam.tf`](#9-identity--authorization)
10. [Configuration — `ssm.tf`](#10-configuration)
11. [Observability — `monitoring.tf` and app-side logback/X-Ray/CloudWatch](#11-observability)
12. [CI/CD — `cicd.tf` and `buildspec.yml`](#12-cicd)
13. [Outputs and provider — `outputs.tf`, `provider.tf`, `variables.tf`, `locals.tf`](#13-outputs-and-provider)
14. [Cost, safety and clean-up notes](#14-cost-safety-and-clean-up)
15. [What is deliberately not here (and why)](#15-what-is-deliberately-not-here)

---

## 1. Introduction & mental model

Scenario 1 (on `main` / `scenario-1` branches) runs the three services on **EC2 virtual machines**, wired together with **Spring Cloud** (Eureka discovery, Config Server, Netflix components), messaging on **RabbitMQ**, deployment by **Ansible playbooks** driven from **Jenkins**. It looks like a "self-managed data centre on EC2" — everything is a JVM concern.

Scenario 2 replaces every one of those decisions with an **AWS-managed equivalent**:

| Concern | Scenario 1 (VM-era) | Scenario 2 (cloud-native) |
|---|---|---|
| Compute | EC2 + Auto Scaling Groups | **ECS Fargate** (serverless containers) |
| Service discovery | **Eureka** (JVM registry) | **ECS Service Connect** + **AWS Cloud Map** (DNS-based) |
| Configuration | **Spring Cloud Config Server** (Git-backed) | **AWS Systems Manager Parameter Store** |
| Messaging | **RabbitMQ** (self-hosted broker) | **Amazon SQS** (managed queues) |
| Auth | **Keycloak** (self-hosted IdP) | **Amazon Cognito** (managed IdP) |
| Distributed transactions | Choreography over RabbitMQ events | **AWS Step Functions** SAGA orchestration |
| Load balancing | Nginx on EC2 | **Application Load Balancer** (managed) |
| Metrics | **Prometheus** scraping /actuator/prometheus | **CloudWatch** (metrics, logs, dashboards) |
| Tracing | (none) | **AWS X-Ray** (SDK-instrumented) |
| CI/CD | **Jenkins** on EC2 → Ansible → EC2 | **CodePipeline** → **CodeBuild** → **CodeDeploy** blue/green |
| Deployment target | EC2 instances | ECS task definitions, blue/green traffic shift |
| Cost profile | Fixed EC2 hours + Jenkins/Keycloak/Rabbit hosts | Pay-per-second Fargate + per-request managed services |

The mental shift: **you stop running infrastructure, you stop pinning versions, you stop patching OSes.** In return you're wiring together AWS primitives with IAM policies and Terraform.

### The three questions that drive every cloud decision

Before you look at any specific file, internalise these three axes — every architectural choice in this scenario ultimately answers one of them:

1. **What is my blast radius on failure?** If this component dies at 3am, which other components go down with it? Managed services shrink your blast radius by making AWS responsible for the "boring" failures (disk full, kernel panic, network partition inside the datacentre). You still own logical failures (bad code, wrong IAM policy, exhausted DB connections).

2. **Where does state live, and who owns it?** In Scenario 1, state lives on EC2 disks, in RabbitMQ queues, in the Config Server's Git repo, in the local Jenkins workspace. Loss of any host = potential data loss. In Scenario 2, state is externalised: databases (RDS/DynamoDB), queues (SQS), config (SSM), artifacts (S3), state machine executions (Step Functions history). Compute becomes disposable, and that unlocks blue/green + autoscaling.

3. **What is the "unit of scale"?** In Scenario 1 it's an EC2 instance — you scale by adding VMs and reshuffling load. In Scenario 2 it's a Fargate task (or a Lambda invocation, or a DynamoDB partition) — the unit is smaller and cheaper to add. Cost tracks usage more tightly.

Every managed service AWS provides is essentially a trade: **you give up flexibility, you get operational leverage.** Understanding when that trade is worth it is the actual skill.

### The AWS shared-responsibility model in one paragraph

For every managed service you use, AWS operates "up to a line" and you operate "above the line." For ECS Fargate, AWS runs the host OS, kernel, container runtime, patching, hardware; you supply the image and the task definition. For RDS, AWS runs the DB engine, storage, backups, minor-version patching; you supply the schema, queries, and user credentials. For Lambda, AWS runs literally everything except the handler function. This line moves as you go up the stack — more managed = smaller "your line" but higher unit cost.

---

## 2. Scenario 1 vs Scenario 2 — architectural diff

**Scenario 1 request flow (simplified):**

```
client → Nginx → api-gateway (Spring Cloud Gateway on EC2)
                       │ (routes via Eureka lookup)
                       ▼
                  order-service ──RabbitMQ──▶ payment-service
                       │                          │
                       └──Eureka HTTP──▶ user-service
                       │
                       ▼
                  PostgreSQL (RDS or EC2)
```

**Scenario 2 request flow:**

```
client → external ALB (port 80, Cognito auth optional)
                │
                ▼
         order-service (ECS Fargate task)
                │
                ├─ Service Connect DNS ──▶ user-service (ECS Fargate)
                │                              │
                │                              ▼
                │                         DynamoDB (users table)
                │
                ├─ StartExecution ──▶ Step Functions state machine (SAGA)
                │                              │
                │                              ▼
                │                       Lambda proxies (validate/process/confirm/refund/cancel)
                │                              │
                │                              ▼
                │                     order-service or payment-service (via Service Connect)
                │                              │
                │                              ▼
                │                        RDS PostgreSQL
                │
                └─ CloudWatchAsyncClient.putMetricData(OrdersCreated)
```

Two structural things to notice up front:

1. **There is no api-gateway service in Scenario 2.** The ALB terminates client traffic and Cognito handles auth at the edge. Cross-service traffic goes through Service Connect (Envoy sidecar injected by ECS) — no gateway JVM in the hot path.
2. **The order SAGA is orchestrated by Step Functions, not by chained RabbitMQ events.** In Scenario 1 each service listens for the previous step's event; in Scenario 2 a state machine explicitly moves through states and knows how to run compensations.

### Why the api-gateway went away

In Scenario 1 the Spring Cloud Gateway did three things: TLS termination, request routing to backend services, and JWT validation. In Scenario 2 each of those is a managed AWS primitive:
- **TLS termination** → the ALB does this natively (attach an ACM cert to an HTTPS listener).
- **Routing** → also the ALB (path-based rules, host-based rules).
- **JWT validation** → the ALB's Cognito integration authenticates users before requests hit your app. If Cognito integration isn't enough you can add API Gateway v2 or a Lambda@Edge, but you rarely need a Spring gateway anymore.

Removing a service is a big deal — it's one fewer JVM to patch, one fewer failure mode, one fewer deploy target. Scenario 2's cheapest win is exactly this: **AWS-managed edges replace hand-rolled JVMs.**

### Why choreography → orchestration for the SAGA

Choreography (Scenario 1): each service subscribes to the previous step's event, publishes the next event on completion. Great for loose coupling — services only know about events, not about each other.

Cost: **no single place tells you "what state is this order in right now?"** You reconstruct it from log lines and queue traces. Compensations are hand-rolled in each service. Retries multiply — if payment-service processes an `OrderCreated` event twice, you can double-charge unless idempotency is baked in everywhere.

Orchestration (Scenario 2): one state machine explicitly moves through the transaction. You get an execution history in the AWS console showing exactly which step is running, what input it received, what it returned. Compensations are declared as edges in the state graph. Idempotency comes for free (use the orderId as the execution name — same ID always maps to the same execution, second `StartExecution` becomes a no-op).

Trade-off: your state machine is now the source of truth. Change it carelessly and you break in-flight executions. Version state machines the same way you version APIs.

---

## 3. Terraform basics used throughout

If you've never touched Terraform, the patterns you'll see over and over. This section is denser than the others because everything downstream assumes you can read a `.tf` file.

### The core object model

**`resource "TYPE" "NAME" { ARGUMENTS }`** — declares an AWS object. `TYPE` maps to the AWS API (e.g. `aws_ecs_service`), `NAME` is a local Terraform-only identifier. When you write `aws_ecs_service.order_service.arn` somewhere else, Terraform resolves that by looking up the `order_service` resource of type `aws_ecs_service` and giving you its ARN attribute.

**`data "TYPE" "NAME"`** — reads something that already exists. Doesn't create anything. Two used in this codebase:
```hcl
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }
```
These give you the current account ID and the list of AZs, respectively.

**`variable "x" { type description default sensitive }`** — an input the operator supplies. Passed via `terraform.tfvars`, `TF_VAR_x` env vars, or `-var` CLI flags. `sensitive = true` hides the value from plan output. Every non-defaulted variable is required.

**`output "x" { value description }`** — surfaces a value after `apply`. Consumers can read with `terraform output x` or reference from another module.

**`locals { x = expr }`** — computed values reused within one module. No cost, no state, just DRY substitution.

**Provider blocks** — configure AWS SDK behaviour (region, default tags). See `provider.tf`.

### The plan/apply lifecycle

Terraform runs in two conceptual phases:

1. **Plan.** Read the config, read the state file, read live AWS resources, compute the diff. Print "will create X, will modify Y, will destroy Z." Never touches AWS beyond read operations.
2. **Apply.** Execute the plan. Terraform builds a dependency graph from resource references and runs operations in parallel where possible. Failures partially-succeed — the state file records what actually happened, so a re-apply picks up where you failed.

The magic is the **state file**. It's Terraform's picture of what "should exist." When you run apply, Terraform compares state → live → config and reconciles the diffs.

### State: the most important thing to understand

State is stored in a **backend**. This codebase uses S3 + DynamoDB:

```hcl
backend "s3" {
  bucket         = "microservices-learning-terraform-state-dev"
  key            = "scenario2/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "microservices-learning-terraform-locks-dev"
  encrypt        = true
}
```

- **The S3 bucket** stores the state file itself (JSON, versioned, encrypted at rest).
- **The DynamoDB table** is a **distributed lock**. When you run `apply`, Terraform writes a row with `LockID = "…/terraform.tfstate-md5"`. Anyone else trying to apply the same state sees the row and aborts with "state is locked."

Without state locking, two engineers running `apply` simultaneously will race — one wins, one corrupts. The DynamoDB table is cheap insurance ($0.30/month).

**Common gotcha:** if you delete a resource in AWS console but Terraform still thinks it exists, next apply will fail. Fix with `terraform state rm` (remove from state, don't touch AWS). Reverse case: if you `terraform destroy` and the state file is lost, the AWS resources become orphans that Terraform no longer manages.

### `for_each` — the DRY multiplier

Most-used loop construct. Turns one resource block into N resources indexed by a map key:

```hcl
resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)   # {"order-service","payment-service","user-service"}
  name     = each.key
}
```

References use bracket syntax: `aws_ecr_repository.services["order-service"].repository_url`. If you later want a fourth service, adding it to the list creates the resource; removing it destroys the resource.

Alternative is `count = N`. Difference: `for_each` gives stable identities (removing "payment-service" only touches that one resource); `count` uses integer indexing (removing index 1 shuffles all higher indices).

### `lifecycle` — telling Terraform to stop meddling

Two flavours used in this codebase:

```hcl
lifecycle {
  ignore_changes = [task_definition, load_balancer, desired_count]
}
```
Says: "Once created, don't reset these attributes back to the config values, even if they drift." Critical on ECS services because CodeDeploy edits `task_definition` and `load_balancer` during blue/green deploys, and autoscaling edits `desired_count`. Without this, next `terraform apply` would undo their work.

```hcl
lifecycle {
  ignore_changes = [value]
}
```
Applied on `random_password.internal_api_key`'s SSM parameter — value is generated once and never regenerated on subsequent applies (so services don't see the API key change under them).

There's also `create_before_destroy = true` (used for zero-downtime replacements — Terraform creates the new resource before destroying the old), and `prevent_destroy = true` (a safety valve — apply will fail if it wants to destroy this resource). None of those are used here but you'll meet them soon.

### `templatefile()` — interpolating text files

Used in `step_functions.tf` to render the state-machine JSON with Lambda ARNs substituted:

```hcl
definition = templatefile("${path.module}/step_functions/order_saga.json", {
  validate_user_lambda_arn   = aws_lambda_function.validate_user.arn
  process_payment_lambda_arn = aws_lambda_function.process_payment.arn
  # ...
})
```

The JSON contains `${validate_user_lambda_arn}` placeholders that get substituted at plan time. Same tool works for any file (Kubernetes manifests, config templates, cloud-init).

### Expressions, functions, and interpolation

Terraform's config language (HCL) has real expressions: arithmetic (`1 + 2`), string interpolation (`"hello ${var.name}"`), conditionals (`x > 0 ? "yes" : "no"`), list/map operations (`[for s in list : s.field]`), and dozens of built-in functions (`jsonencode`, `file`, `templatefile`, `merge`, `toset`, `join`, `format`, ...).

Common patterns from this codebase:
- `[for r in aws_ecr_repository.services : r.arn]` — take the map of ECR repos, return a list of their ARNs.
- `var.alert_email_address == "" ? 0 : 1` used as `count` — conditionally create a resource.
- `merge(local.lambda_common_env, { INTERNAL_API_KEY_PARAM = local.internal_key_param })` — combine two maps.

### Modules (used lightly)

A module is a folder of `.tf` files that can be `source`'d from elsewhere. `infrastructure/scenario-2/` is a **root module**. `infrastructure/bootstrap/` is another root module. Neither module publishes reusable sub-modules; everything is in the root. In larger codebases you'd extract common patterns (a "web-service" module that creates ECR + ECS task def + ECS service + ALB target group in one call) but for a learning codebase inline is clearer.

### The apply feedback loop

When you break something, the debug loop is:
1. `terraform validate` — offline syntax + type check. Catches typos and reference errors instantly.
2. `terraform fmt -check` — style check.
3. `terraform plan` — the diff. Read it carefully. `~` = update in place, `+/-` = destroy then recreate (destructive!), `-/+` = recreate then destroy (create-before-destroy). If you see `-/+` on a stateful resource (RDS, S3 with data), abort and figure out why.
4. `terraform apply` — do it. Errors halt at the failing resource; state file records what completed.
5. `terraform state list` — show every resource currently tracked.
6. `terraform state show TYPE.NAME` — deep-dive one resource.

---

## 4. Networking foundation

### `vpc.tf` — the private network everything sits in

A **VPC** (Virtual Private Cloud) is your own IP address space inside AWS. Every VM, container, database, or Lambda gets an IP inside it. Nothing in a VPC is reachable from the internet unless you explicitly wire up a path (Internet Gateway + public subnet + route + security-group ingress).

**Understanding CIDR blocks.** The VPC is `10.0.0.0/16`. That means the first 16 bits (10.0) are fixed, the remaining 16 bits are host addresses — 65,536 IPs total. Subnets carve out smaller ranges from this by using longer prefixes: `10.0.1.0/24` = the first 24 bits are fixed (10.0.1), the last 8 are host addresses → 256 IPs (usable ~251 after AWS reserves 5 per subnet). The `cidrsubnet()` function in `vpc.tf` computes these ranges arithmetically so you don't hand-count bits.

Why /16 for the VPC and /24 for subnets? /16 is the largest VPC size AWS allows, so you have plenty of room to add subnets later. /24 per subnet gives 251 usable IPs — plenty for the ~5-20 ENIs a small microservices deployment needs, but not so many that you can't fit 8 subnets in one VPC.

What this file builds:

| Resource | Purpose |
|---|---|
| `aws_vpc.main` | The `10.0.0.0/16` block, DNS resolution + DNS hostnames on. |
| `aws_subnet.public` × 2 | `10.0.1.0/24`, `10.0.2.0/24`. Have a route to the Internet Gateway. Used by the external ALB. |
| `aws_subnet.private` × 2 | `10.0.3.0/24`, `10.0.4.0/24`. No public IPs. Where ECS tasks, RDS, Lambdas, and the internal ALB live. |
| `aws_internet_gateway.main` | The door that lets public subnets talk to the Internet. |
| `aws_eip.nat` + `aws_nat_gateway` | Lets private-subnet resources initiate outbound calls (pull ECR images, hit AWS APIs) without being reachable from outside. |
| `aws_route_table.*` + `aws_route_table_association.*` | Attaches "traffic to 0.0.0.0/0 goes via IGW / NAT" rules to each subnet. |

**Public subnet vs private subnet: it's just the routing table.**

The distinction between "public" and "private" is not a VPC-level attribute — it's the presence or absence of a route to the internet gateway. Two subnets with identical CIDRs and settings are "public" or "private" purely because of what their associated route table says. This is a common source of confusion for engineers coming from on-premise thinking. Concretely:

- **Public subnet route table:** `10.0.0.0/16 → local` (default, VPC-internal traffic) + `0.0.0.0/0 → igw-abc123` (everything else → Internet Gateway).
- **Private subnet route table:** `10.0.0.0/16 → local` + `0.0.0.0/0 → nat-xyz789` (everything else → NAT Gateway in a public subnet).

The Internet Gateway is symmetric: it lets internet packets in AND out. A public subnet resource with a public IP is reachable from the world. The NAT Gateway is asymmetric: outbound only. A private subnet resource can *initiate* a connection to the internet (to pull an ECR image, say) but nothing external can initiate a connection to it.

**Two AZs by design.** Every subnet is created twice, one per availability zone (`us-east-1a`, `us-east-1b`). This is a hard AWS requirement for ALB (requires ≥ 2 subnets in different AZs) and RDS multi-AZ (spare in the other AZ), and it's the entry cost of any high-availability setup — a single-AZ deployment survives no rack, cooling, or power failure. If you deploy to a single AZ you're not really "on the cloud" — you're on one datacentre with an AWS logo.

> **Deeper dive — NAT Gateway is the surprise cost.** NAT Gateway data-processing is $0.045/GB. For a busy service that pulls large images on autoscale, this adds up fast. Alternatives: (a) VPC endpoints for AWS services (S3, ECR, DynamoDB — free for S3/DynamoDB, cheap for the rest), (b) EC2-based NAT instances (cheaper but you own the OS), (c) IPv6-only outbound (free egress from AWS but limits your reachability).

### `sg.tf` — security groups (stateful firewalls)

A **security group** is a whitelist attached to an ENI (Elastic Network Interface — the virtual NIC every EC2/ECS-task/RDS-instance/Lambda-in-VPC gets). Rules say "allow port X from source Y". Everything else is dropped.

**"Stateful" means** if you allow ingress on port 8080, the return traffic (whatever ephemeral port the client picked) is automatically allowed — you never need matching egress rules for return packets. This is different from IPTables or NACLs which are stateless.

**Source can be a CIDR block or another security group.** Referencing an SG is safer than referencing a CIDR because the source set updates automatically as instances come and go. Example: `source_security_group_id = aws_security_group.alb.id` on the ECS-tasks SG means "any ENI attached to the ALB's SG can reach me on 8080." When the ALB scales out and adds ENIs in different subnets, the rule keeps working with no changes.

We define four security groups:

- **`aws_security_group.alb`** — public-facing. Ingress from `0.0.0.0/0` on 80/443. This is the only SG exposed to the internet.
- **`aws_security_group.internal_alb`** — introduced when we added CodeDeploy blue/green for payment/user (see [§8](#8-load-balancing)). Ingress from within the VPC CIDR on 80/81 (prod listeners) and 8080/8081 (test listeners).
- **`aws_security_group.ecs_tasks`** — the ECS tasks themselves. Three ingress rules:
  1. From `alb` SG on 8080 (external ALB reaches order-service).
  2. From `internal_alb` SG on 8080 (internal ALB reaches payment/user).
  3. From itself on all ports (Service Connect Envoy-to-Envoy traffic between services in the same SG).
- **`aws_security_group.rds`** — PostgreSQL port 5432 open only to `ecs_tasks` SG. RDS is otherwise unreachable from anywhere.

> **Deeper dive — SG vs NACL.** AWS gives you two firewall layers. Security groups are per-ENI, stateful, allow-list only. Network ACLs are per-subnet, stateless, and support both allow and deny rules. In 99% of cases you use SGs alone; NACLs come out for regulated environments where you need explicit deny rules ("no traffic to 10.0.0.0/8 leaves the VPC") or as a defence-in-depth against SG misconfiguration.

**Contrast with Scenario 1.** Scenario 1 mixes SG rules with EC2 instance user-data scripts and Ansible-managed iptables. Scenario 2 is entirely declarative — the SG *is* the firewall. Also, iptables is stateful too but managed per-host; SGs are managed by AWS at the hypervisor level, which means the enforcement happens *before* the packet reaches your container, saving CPU.

---

## 5. Compute — ECS Fargate

### `ecr.tf` — private container image registries

ECR (Elastic Container Registry) is the private Docker registry that only your account (and CI, via IAM) can push/pull.

`aws_ecr_repository.services` uses `for_each = toset(local.services)` to create three repos in one block. Each has:
- **`image_tag_mutability = "MUTABLE"`** — so `:latest` can be re-tagged. In stricter shops you'd set `IMMUTABLE` and always tag by SHA to make deployments auditable ("what code was running at 3pm yesterday?" becomes trivial).
- **`image_scanning_configuration.scan_on_push = true`** — free CVE scan on every push. Results appear in the ECR console under the image tag. Great for catching known vulnerabilities in your base image before deploy.
- **`force_delete = true`** — lets `terraform destroy` clean up even if the repo has images. Removes friction for learning; you'd set this `false` in prod so someone can't wipe your image history with a stray `destroy`.

**How ECR authentication actually works.** Docker doesn't natively speak IAM. `aws ecr get-login-password` returns a short-lived (12-hour) bearer token that you pass to `docker login`. The token embeds your IAM identity, and ECR uses that to authorize pushes/pulls. When ECS pulls an image, the task execution role's ECR permissions authorize the pull automatically — you never see the token.

**Contrast with Scenario 1.** No ECR — Scenario 1 runs JARs baked into Ansible-provisioned EC2s. Container images are a Scenario 2 concept only. Docker + ECR trades "one big JAR + JVM install" for "an image that includes both, with an explicit dependency graph."

### `ecs_cluster.tf` — the ECS cluster and Cloud Map namespace

A **cluster** is a logical group; it does not create any compute by itself (Fargate does not need pre-provisioned nodes). The cluster is more like a bookkeeping construct — it holds capacity providers (Fargate, Fargate Spot, EC2), default networking configuration, and log destinations. Tasks and services must be attached to a cluster.

Two resources:
- `aws_ecs_cluster.main` — enables Container Insights (extra CloudWatch metrics on task-level CPU/memory). Container Insights costs about $2/task/month; skip it in cost-sensitive envs, keep it in learning envs so you can see what's happening.
- `aws_service_discovery_private_dns_namespace.ms_learning` — creates a private DNS zone `ms-learning.local` inside the VPC. Service Connect writes service records into it, and Lambdas / other consumers resolve `order-service.ms-learning.local` to reach tasks.

The cluster also has `service_connect_defaults` pointing at the namespace, so services don't need to repeat it.

**Cloud Map is the underlying service-discovery primitive.** ECS Service Connect is really just "ECS wires up Cloud Map for you and injects an Envoy sidecar." You can use Cloud Map directly (with EC2, Lambda, on-prem, whatever) — but Service Connect is the ergonomic version if you're on ECS.

### `ecs_services.tf` — task definitions and services

This is the heart of the compute stack. For each service (order, payment, user) we declare a task definition and a service. It helps to think of them as separate concerns:

- **Task definition** = "a container spec." Immutable once registered. New revisions are additions, never edits. Family names group revisions.
- **Service** = "keep N of task-definition-revision-X running, load-balanced, in these subnets, with this security group." Long-lived; the desired-count is what you scale.
- **Task** = one running instance of a task definition. Ephemeral. Dies when the service replaces it.

**A task definition** (`aws_ecs_task_definition.*`):
- `family = "ms-learning-<svc>"` — the task-definition name; new revisions increment on every change. A family is like a git branch — revisions are like commits.
- `requires_compatibilities = ["FARGATE"]` — no EC2 backing store; AWS runs the container. You could also say `["EC2"]` or `["FARGATE","EC2"]`.
- `network_mode = "awsvpc"` — each task gets its own ENI in the VPC with its own IP. This is the only mode Fargate supports. It's also the mode you want for security-group-based network isolation. Older modes (`bridge`, `host`) share the host's networking and were designed for EC2 launch type.
- `cpu = 512`, `memory = 1024` — Fargate has a discrete size table; not every CPU/memory combo is valid. `512 CPU / 1024 MB` = 0.5 vCPU + 1 GB RAM. See [Fargate task sizing](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#task_size).
- **Two IAM roles** — the crucial distinction:
  - `execution_role_arn` = "role the ECS *agent* uses to pull the image and write logs." Same role for all services. Think of this as the "outside-the-container" identity — what AWS itself uses to bootstrap your task.
  - `task_role_arn` = "role the *container process* uses when it calls AWS APIs (SQS, SSM, DynamoDB, X-Ray, ...)." One per service, principle of least privilege. Inside the container, the AWS SDK resolves this role automatically via the ECS credentials endpoint (`http://169.254.170.2/creds`) — you never handle keys.
- `container_definitions` is a JSON block declaring the container: image (pointed at ECR `:latest`), ports (8080 named `http` so Service Connect can route to it), env vars (`SPRING_PROFILES_ACTIVE=prod`, `AWS_REGION`), and log config (see below).

> **Deeper dive — why two roles?** Because they run at different points in the task lifecycle with different threat models. The execution role runs *before* your code exists — if your image itself is malicious, this role's scope shouldn't matter (it's just "pull my image"). The task role runs *inside* your code — if your image is malicious, this role is what the attacker gets. Splitting them means a broadly-scoped execution role (needed to pull from any of your ECR repos) doesn't leak into your service's runtime permissions.

**A CloudWatch log group** (`aws_cloudwatch_log_group.services`) is created via `for_each` at the top of the file — `/ms-learning/order-service`, `/ms-learning/payment-service`, `/ms-learning/user-service`, 7-day retention. The `logConfiguration` inside each container definition points at these groups with the `awslogs` driver, region, and `ecs` stream prefix — this is how Spring Boot's stdout ends up in CloudWatch.

**How ECS log routing works.** The container's stdout/stderr goes to the `awslogs` Docker log driver, which the ECS agent ships to CloudWatch Logs. There's a one-log-stream-per-task convention: stream name = `<prefix>/<container-name>/<task-id>`. If a task dies and a replacement starts, the old task's log stream is preserved forever (or until log-group retention deletes it). This is why "which task logged this?" is a valid CloudWatch Logs query.

**An ECS service** (`aws_ecs_service.*`):
- `desired_count = 1` for cost. In prod you'd run ≥ 2 for HA (ideally spread across AZs — ECS's placement strategies do this automatically).
- `launch_type = "FARGATE"` — serverless. No EC2 to size, patch, or drain.
- `deployment_controller { type = "CODE_DEPLOY" }` — hands deployment control to CodeDeploy for blue/green (see [§12](#12-cicd)). Without this, ECS does a "rolling" deploy (kill 25% of old tasks, start 25% new, repeat).
- `health_check_grace_period_seconds = 120` — how long the ALB waits before considering the target unhealthy. Spring Boot cold-start can take 60–90s; without a grace period, tasks are killed mid-boot and the service loop-crashes.
- `network_configuration` — the private subnets and the `ecs_tasks` SG. `assign_public_ip = false`.
- `load_balancer { … }` block wires the service to its **blue** target group only; CodeDeploy manages the green side at runtime.
- `service_connect_configuration` — turns on the Envoy sidecar and registers a Cloud Map service named after the discovery_name. Peers reach it as `http://<discovery-name>/` on port 80 (Envoy sidecar listens on 80 inside the client task and forwards to 8080 on the server task).
- `lifecycle { ignore_changes = [task_definition, load_balancer, desired_count] }` — CodeDeploy rewrites these during blue/green swaps, and desired_count may change via autoscaling. Terraform must not undo those changes on the next apply.

> **Deeper dive — what is the Envoy sidecar?** When you enable Service Connect on a service, ECS launches a second container in every task: `aws-service-connect-envoy`. It listens on the client-alias port (80 in our config) inside the task. When your app code calls `http://order-service/api/…`, DNS resolves `order-service` to the sidecar's local IP (127.0.0.1 range), the sidecar looks up healthy backends in Cloud Map, and proxies the request. Benefits: client-side load balancing, automatic retries, per-connection metrics, mTLS-ready (though we don't turn it on here). Cost: ~50 MB extra memory per task and a proxy hop.

**Contrast with Scenario 1.** Scenario 1's equivalent is an Ansible playbook that SSHes into an EC2 instance, drops a systemd unit for `order-service.jar`, and calls `systemctl restart`. There is no notion of a "task definition revision" or "desired count" — you just have processes. ECS gives you resource limits, restart policy, log routing, IAM identity, and rolling deployment all in one declarative object.

---

## 6. Data layer

### `rds.tf` — PostgreSQL for order and payment services

Two `aws_db_instance` resources — one per service. Both are `db.t3.micro` on `postgres 15` with:
- `db_subnet_group_name` pointing at the **private** subnets — the DB is unreachable from the internet.
- `vpc_security_group_ids = [aws_security_group.rds.id]` — only ECS tasks can connect.
- `publicly_accessible = false`, `storage_encrypted = true`.
- `skip_final_snapshot = true` — learning-mode; you'd never do this in prod.
- Credentials sourced from `var.db_username` and `var.db_password` — the latter is `sensitive = true`.

**Two separate instances rather than one shared** because each service owns its own schema. This is the database-per-service pattern of microservices: no cross-service joins, no shared migrations, blast radius contained. If order-service deploys a bad migration, payment-service's data is safe. The cost is doubled infrastructure — worth it for isolation, painful at very small scales.

### RDS parameters worth understanding

- **`instance_class = "db.t3.micro"`** — the smallest useful class. Bursts on t3 (throughput exceeds sustained capacity for short periods). Fine for learning; move to `db.t3.medium` or `db.m6i.large` for prod.
- **`allocated_storage`** — starts at some GB; you can grow but not shrink. Storage autoscaling exists but is off by default.
- **`storage_type = "gp3"`** — general-purpose SSD, more predictable performance than gp2 at the same price.
- **`multi_az = false`** — we run a single instance. Multi-AZ means AWS keeps a synchronous standby in another AZ and fails over automatically; costs ~2× and roughly halves RPO/RTO. Turn it on in prod.
- **`backup_retention_period`** — automated daily snapshots retained for N days. Setting to 0 disables backups entirely (never do this).
- **`storage_encrypted = true`** — encryption at rest with a KMS key. Free, always on.
- **`deletion_protection`** — prevents accidental `terraform destroy` deleting the DB. Not set here (learning); set to `true` in prod.
- **`skip_final_snapshot`** — if true, `destroy` doesn't take a snapshot on the way out. Combined with no `deletion_protection`, one bad `terraform destroy` and your DB is gone.

### Migrations

Terraform doesn't own the schema. Spring Boot with `spring.jpa.hibernate.ddl-auto=validate` fails-fast if the schema doesn't match entities. Production teams use **Flyway** or **Liquibase** to run versioned migrations at boot. This codebase doesn't ship migrations yet — see [§15](#15-what-is-deliberately-not-here).

**Contrast with Scenario 1.** Same PostgreSQL-per-service pattern, but Scenario 1's Jenkins pipeline typically provisions the DB via a Docker container on the same EC2 host, or a manually-created RDS instance without Terraform ownership.

### `dynamodb.tf` — a NoSQL table for the user service

The user service does not fit RDS well — its access pattern is "get user by ID" and item structure varies by user type (regular / premium / admin). This is a textbook DynamoDB fit:

- `aws_dynamodb_table.users` with `hash_key = "userId"`.
- `billing_mode = "PAY_PER_REQUEST"` — no capacity planning; pay per read/write. Perfect for a learning scenario.
- `point_in_time_recovery.enabled = true`.
- Server-side encryption on by default.

### DynamoDB modeling essentials

DynamoDB is **not a relational database with knobs off** — it's an entirely different beast. Two concepts that make or break your design:

1. **Partition key + sort key.** Every item has a partition key (`userId` here). DynamoDB hashes it and stores the item on a physical partition. A **sort key** would let multiple items share a partition and be range-scanned (useful for time-series data). We don't use one here — a user has one row.

2. **You design the table around your queries.** If you need "get user by email" *and* "get user by ID", you either (a) add a Global Secondary Index (GSI) on email, or (b) accept that email lookups do a table scan. You cannot query on arbitrary fields.

**Why DynamoDB and not just another PostgreSQL?** To demonstrate polyglot persistence. Real teams pick DynamoDB when they need single-digit-millisecond reads at any scale and don't need joins. The trade-off is you must design the table around your queries, not the other way around.

**Billing modes:**
- `PAY_PER_REQUEST` — pay per read/write unit consumed. Great for spiky/unknown traffic, wasteful at sustained high load.
- `PROVISIONED` — you pre-allocate RCU/WCU (read/write capacity units). Cheaper at sustained high load, requires capacity planning.

For learning, always use `PAY_PER_REQUEST` — you never think about it and it costs pennies.

**Contrast with Scenario 1.** Scenario 1 also uses DynamoDB for the user service (post-refactor), but wired via `awslocal` / LocalStack for development and no Terraform provisioning of the real cloud table.

---

## 7. Messaging & orchestration

### `sqs.tf` — durable event queues

Each service that publishes domain events has a **primary queue** and a **dead-letter queue (DLQ)**:

- `aws_sqs_queue.order_events` + `aws_sqs_queue.order_events_dlq`
- `aws_sqs_queue.payment_events` + `aws_sqs_queue.payment_events_dlq`

### SQS mental model

SQS is a **pull queue**, not push. Consumers poll the queue (`ReceiveMessage`), process the message, and delete it (`DeleteMessage`). While a message is in-flight (delivered to a consumer, not yet deleted), it's invisible to other consumers — this is the **visibility timeout**. If the consumer crashes before deleting, the visibility timeout expires and the message becomes visible again, another consumer picks it up.

Key attributes:
- **`visibility_timeout_seconds`** — how long a message hides after being read. Default 30s. Should be > your worst-case processing time or you'll process the same message twice.
- **`message_retention_seconds`** — how long an undelivered message survives (default 4 days, max 14).
- **`redrive_policy`** — the DLQ pointer + `max_receive_count`. After this many failed processing attempts, the message moves to the DLQ.

The primary queue's `redrive_policy` says "after `max_receive_count = 5` failed processing attempts, move the message to the DLQ." This is the standard poison-message pattern — bad events don't block the queue forever, and you can inspect the DLQ to see what broke.

**Delivery semantics: at-least-once, not exactly-once.** SQS standard queues (which we use) deliver each message at least once but occasionally twice. Your consumer must be idempotent. Common tactic: dedupe by message ID at the DB level (unique index on `event_id`). SQS FIFO queues do exactly-once but at ~300 messages/second per queue — too slow for most workloads.

**Contrast with Scenario 1.** RabbitMQ dead-lettering exists but takes more setup (exchange/queue configuration, DLX). SQS gives it to you with two Terraform arguments. RabbitMQ has richer routing (topic exchanges, header exchanges) — SQS is deliberately dumb. You bolt on SNS in front for pub/sub semantics when you need fan-out.

### `step_functions.tf` + `step_functions/order_saga.json` — the SAGA orchestrator

The scenario-2 order-creation flow is a **distributed transaction**: user must be valid, payment must succeed, order must be confirmed. If payment fails after we've already reserved the order, we must run compensations (refund, cancel).

**Why "SAGA" is the right pattern here.** ACID transactions across services are impractical (two-phase commit doesn't compose, distributed locks are a scaling nightmare). SAGA replaces ACID with "run forward transactions; if any fails, run compensating transactions to undo the earlier ones." It sacrifices atomicity (there's a window where you've charged the customer but haven't confirmed the order) for availability and simplicity.

Two implementation styles:

**Choreography** (Scenario 1) — services react to events. order-service emits `OrderCreated`, payment-service listens and processes, publishes `PaymentApproved` or `PaymentFailed`, order-service listens and updates state. This works but has three costs: state is smeared across queues, retries are per-service, and observability is stitched together from logs.

**Orchestration** (Scenario 2) — a state machine explicitly runs each step. Where choreography spreads intelligence across every service, orchestration centralises it in the state machine.

| Aspect | Choreography (S1) | Orchestration (S2) |
|---|---|---|
| Where "what's next" lives | In each service's event handler | In the state machine |
| Adding a new step | Change producer + consumer + event schema | Change state machine JSON |
| Observability | Grep logs across services | Step Functions console shows execution history |
| Retries | Per service (each rolls its own) | Built into ASL |
| Idempotency | Bolted on per service | Free via execution name = business key |
| Failure recovery | Manual, service-by-service | Compensating transitions declared |

### The state machine in detail

**`step_functions/order_saga.json`** defines the state machine in ASL (Amazon States Language):

```
StartAt: ValidateUser
  ValidateUser (Task) → ProcessPayment | on error → OrderFailed
  ProcessPayment (Task) → CheckPaymentStatus | on error → RefundPayment
  CheckPaymentStatus (Choice):
      status == APPROVED → ConfirmOrder
      else → RefundPayment
  ConfirmOrder (Task, retries 3×2s×2) → OrderComplete (Succeed)
  RefundPayment (Task) → CancelOrder
  CancelOrder (Task, retries 3×2s×2) → OrderFailed (Fail)
```

**ASL state types you meet here:**
- `Task` — invokes something (Lambda, ECS, SNS, another SFN, etc.).
- `Choice` — branch on input.
- `Succeed` / `Fail` — terminal states.

Not used here but worth knowing: `Wait` (pause N seconds or until timestamp), `Parallel` (fan-out N branches and join), `Map` (iterate a list applying a sub-workflow), `Pass` (identity transform).

**Retry vs Catch semantics:**
- `Retry` = "same task, try again with backoff." Applied on `ConfirmOrder` and `CancelOrder` (`IntervalSeconds: 2, MaxAttempts: 3, BackoffRate: 2.0` = 2s, 4s, 8s waits between attempts).
- `Catch` = "task failed after all retries; go to a different state." Applied on `ValidateUser` (→ `OrderFailed`) and `ProcessPayment` (→ `RefundPayment`).

Each `Task` state's `Resource` is a placeholder like `${validate_user_lambda_arn}` — the `aws_sfn_state_machine.order_saga` resource in Terraform renders the JSON through `templatefile()` and substitutes the real Lambda ARNs.

### Why five Lambda "proxies"?

Step Functions cannot directly call an ECS service on a private VPC IP — the integrations available are AWS SDK calls (Lambda, SNS, SQS, DynamoDB, ...). So the pattern is: each task invokes a Lambda that runs *inside the VPC*, uses Cloud Map to discover the target service's healthy tasks, and issues the HTTP call.

Each Lambda's source is inlined in the Terraform file via `data "archive_file"`. The Python code is short (~20 lines each) and does three things:
1. Cloud Map `discover_instances` to get a healthy task IP.
2. `urllib.request` to POST/GET the target endpoint.
3. Return the JSON result (Step Functions passes it into the next state's input).

The two Lambdas that call **internal** order-service endpoints (`confirm_order`, `cancel_order`) additionally read the internal API key from SSM and set `X-Internal-Api-Key` — the same secret order-service checks in `OrderController.confirmOrder / cancelOrder`.

> **Deeper dive — could you skip the Lambda proxies?** Yes, in three ways: (a) HTTPS integration in Step Functions (announced 2023) — calls a public HTTP endpoint directly, but requires the target to be internet-reachable, which our services aren't. (b) EventBridge Pipes with an API Destination — similar issue. (c) Put the target service behind an internal ALB and use Step Functions' AWS SDK integration to call it — cleaner but adds more networking. The Lambda-proxy pattern is the default for calling private VPC services from Step Functions and it's cheap (~$0.20 per 100k invocations).

**Supporting resources in `step_functions.tf`:**
- `aws_iam_role.saga_lambda` — assumed by all five Lambdas. Attached: `AWSLambdaVPCAccessExecutionRole` (managed policy for VPC ENIs), plus inline permissions for `servicediscovery:DiscoverInstances` and `ssm:GetParameter` on the internal-api-key path.
- `aws_security_group.saga_lambdas` — empty ingress, open egress; then an ingress rule on `ecs_tasks` accepting traffic from this SG on port 8080.
- Five `aws_lambda_function` resources, each in the private subnets with `vpc_config`, `SERVICE_NAMESPACE` env var, 30s timeout, 256 MB.
- `aws_iam_role.order_saga_sfn` + inline policy allowing `lambda:InvokeFunction` on the five Lambda ARNs plus CloudWatch Logs actions.
- `aws_cloudwatch_log_group.order_saga` — `/ms-learning/order-saga`, 7-day retention, wired via `logging_configuration.level = "ERROR"`.
- `aws_sfn_state_machine.order_saga` — the state machine itself.
- Two SSM parameters — the internal API key (`SecureString`, `random_password`, `lifecycle.ignore_changes = [value]` so it never rotates on apply) and the state-machine ARN (so order-service reads it at boot).

**Idempotency via execution name.** In `OrderCommandHandler.handle`, we start the SFN execution with `.name(orderId.toString())`. Step Functions rejects a second `StartExecution` for the same name with an `ExecutionAlreadyExists` exception — so if the client retries a POST /api/orders, the SAGA doesn't re-run. This is the cleanest form of idempotency: you don't need a "processed-events" table; the state machine's own execution history is the dedupe.

**Contrast with Scenario 1.** There is no Step Functions in Scenario 1. Order creation there is a linear chain of RabbitMQ events with the compensation logic (`OrderCancelled` on `PaymentFailed`) hand-rolled inside each service. Step Functions gives you: a **visual execution history in the console** (see exactly which state failed, with input/output), **built-in retry semantics** (no exponential-backoff library needed), and **atomic idempotency** — using `name = orderId` on `StartExecution` guarantees the same order never triggers two SAGA runs.

---

## 8. Load balancing

### The ALB in one paragraph

An **Application Load Balancer** is AWS's layer-7 (HTTP-aware) load balancer. It has three moving parts:
1. **Load balancer** — the DNS-fronted entity your clients hit. Lives in ≥ 2 subnets across ≥ 2 AZs.
2. **Listeners** — protocol + port bindings (e.g. HTTP:80, HTTPS:443). Each has a default action and optional rules.
3. **Target groups** — the pool of endpoints (task IPs, EC2 instance IDs, Lambda ARNs) that receive traffic. Health-checked continuously. Listeners point at target groups.

The listener rule chain works like: "if request matches `path = /api/orders/*`, forward to target group X; else default action."

### `alb.tf` — external ALB + internal ALB

**External ALB** (`aws_lb.main`, `internal = false`, public subnets):
- `aws_lb_target_group.order_service` — the **blue** TG (port 8080, health-check `/actuator/health`).
- `aws_lb_target_group.order_service_green` — the **green** TG. Empty at rest; populated by CodeDeploy during a deploy.
- `aws_lb_listener.http` on port 80 → default action = forward to blue TG. `lifecycle.ignore_changes = [default_action]` because CodeDeploy flips this pointer.
- `aws_lb_listener.http_test` on port 8080 → forwards to green TG. Used by CodeDeploy to run a smoke test on the new version *before* shifting production traffic.

**Internal ALB** (`aws_lb.internal`, `internal = true`, private subnets):

Introduced when we added CodeDeploy blue/green for the two internal services. Blue/green on ECS **requires** a load balancer per service — CodeDeploy needs a listener to swap between blue and green. Payment and user services were previously reachable only via Service Connect (peer-to-peer inside the VPC); to give CodeDeploy something to flip, we added this internal-only ALB.

- 4 TGs total (`payment_service`, `payment_service_green`, `user_service`, `user_service_green`).
- 4 listeners: payment prod (80), payment test (8080), user prod (81), user test (8081) — different ports so both services share one ALB.
- All listener default actions have `lifecycle.ignore_changes = [default_action]` for the same reason as the external one.

### Target group health checks

Every TG runs its own health-check probe against every registered target. In our config:
- `path = /actuator/health` — Spring Boot's default health endpoint.
- `interval = 30` — probe every 30 seconds.
- `timeout = 5` — the probe must respond within 5 seconds.
- `healthy_threshold = 2` — 2 consecutive successes to become healthy.
- `unhealthy_threshold = 3` — 3 consecutive failures to become unhealthy.
- `matcher = "200"` — HTTP 200 counts as healthy; anything else fails.

**A newly-registered target is `initial` until the first healthy_threshold successes.** Combined with `health_check_grace_period_seconds = 120` on the ECS service, this gives Spring Boot ~2 minutes to start before failed checks kill the task.

### Blue/green mechanics

Sequence when CodeDeploy runs a deployment:
1. Register a new task-definition revision (with the new image).
2. Launch tasks running that revision, attach them to the **green** target group.
3. Wait until green TG has enough healthy targets.
4. Optional: run smoke tests via the test listener (which points at green).
5. **Traffic shift.** The prod listener's default action is edited to forward to the green TG instead of blue.
6. Wait a configurable "bake time" (5 minutes default) — traffic is flowing to green.
7. Deregister old tasks from the blue TG and terminate them.
8. Rename: what was green is now blue (for the next deployment).

If step 3 or step 4 fails, CodeDeploy runs **auto-rollback**: the prod listener never gets edited; green tasks are terminated; blue keeps serving. Zero user-visible impact.

The traffic-shift step happens in one of three ways depending on `deployment_config_name`:
- `ECSAllAtOnce` (we use this) — one instant flip.
- `ECSLinear10PercentEvery1Minute` — 10% every minute over 9 minutes.
- `ECSCanary10Percent5Minutes` — 10% for 5 min, then 100%.

For prod you'd pick linear or canary.

**Note on traffic direction.** Service-to-service traffic still flows through **Service Connect** (via the Envoy sidecar) — the internal ALB is not on the hot path. It exists solely so CodeDeploy has a swap point. That's a deliberate architectural choice; the alternative (routing east-west via the ALB) doubles the network hops and abandons the Envoy telemetry.

> **Deeper dive — ALB vs NLB vs CLB.** ALB is layer 7 (HTTP-aware, path/host routing, header inspection, WebSocket, HTTP/2). NLB is layer 4 (TCP/UDP, faster, static IPs available, preserves client IP without XFF). CLB is the legacy "Classic Load Balancer" — don't use it. Rule of thumb: ALB for HTTP APIs, NLB for extreme throughput or non-HTTP protocols or when clients need a static IP whitelist.

**Contrast with Scenario 1.** Scenario 1 uses Nginx on the api-gateway EC2 for TLS termination and routing. It doesn't have TGs, health-check groups, or blue/green support — deploys are rolling `systemctl restart` on each EC2 in sequence.

---

## 9. Identity & authorization

### `cognito.tf` — the managed identity provider

Cognito replaces Keycloak. It gives you:

- `aws_cognito_user_pool.main` — the user directory (password policy, MFA optional, email-based).
- `aws_cognito_user_pool_domain.main` — a hosted UI at `https://ms-learning-<account>.auth.us-east-1.amazoncognito.com` (login form, forgot-password, sign-up — you don't write any of it).
- Two app clients:
  - `alb` — has a client secret, used by the ALB's Cognito authenticate action when you enable it.
  - `api_test` — no secret, used by developers for `USER_PASSWORD_AUTH` calls (see `docs/api-testing.md`).
- `aws_cognito_user_pool_client.alb` sets callback URLs from `var.alb_callback_domain` — placeholder until you attach a real domain + HTTPS listener.

### Cognito flows that matter for this codebase

Cognito supports many OAuth flows. Two are relevant here:

- **Authorization Code + PKCE** (used by the ALB Cognito integration): browser is redirected to the Cognito hosted UI, user logs in, Cognito redirects back to the ALB with a code, ALB exchanges code for tokens. The `alb` client has a secret because the exchange happens server-side.
- **USER_PASSWORD_AUTH** (used by API tests): send username+password directly to Cognito, get tokens back. Only appropriate for trusted first-party clients (your own CLI/test scripts) or during development. `api_test` client has no secret because it's for public/dev use.

**Tokens issued.** After a successful login you get three JWTs:
- **ID token** — identity claims (email, name, `sub` = user ID). This is what you send to the ALB or your API to prove who you are.
- **Access token** — scopes/permissions. Useful when you want to authorize to specific resources.
- **Refresh token** — long-lived; exchange for new ID/access tokens without re-logging-in.

**Why the separation into two clients.** ALB integration and programmatic testing have different security profiles (server-side redirect with a secret vs client-side password grant). Splitting into two clients keeps the "public" and "confidential" flows independent. You can also revoke or rotate one without impacting the other.

**JWKS and token validation.** Cognito publishes public JWKS at `https://cognito-idp.<region>.amazonaws.com/<pool_id>/.well-known/jwks.json`. The Spring services validate JWTs against this URL via `spring-boot-starter-oauth2-resource-server`. Configuration is in each service's `application-prod.yml` under `spring.security.oauth2.resourceserver.jwt.issuer-uri` (deployment adds this).

### `iam.tf` — task roles and the execution role

Two categories of role. Understanding IAM policy anatomy first:

**A policy is a JSON document with a list of statements.** Each statement has:
- **Effect** — `Allow` or `Deny` (deny beats allow).
- **Action** — the API calls covered, like `s3:GetObject` or `sqs:SendMessage`. Wildcards allowed (`s3:*`).
- **Resource** — the ARNs the actions apply to. Wildcards allowed (`*` = everything).
- **Condition** — optional: only apply if a runtime attribute matches. See the `cloudwatch:namespace` example below.
- **Principal** — only in trust policies (who can assume the role).

**Roles have two policies attached:**
1. **Trust policy** (via `assume_role_policy` argument) — *who* can assume this role. Example: "the ECS service principal on tasks in my account."
2. **Identity policy** (via `aws_iam_role_policy` resource or inline) — *what* the role can do once assumed.

Terraform models both:

**`aws_iam_role.task_execution`** — used by the ECS agent, not by your code. Attached `AmazonECSTaskExecutionRolePolicy` (pulls from ECR, writes CloudWatch logs) plus a custom policy giving `ssm:GetParameter` on `/ms-learning/*` (so the agent can inject SSM values as env vars into the container at start-up).

**Per-service task roles** (`aws_iam_role.order_service`, `.payment_service`, `.user_service`) — assumed by the container process. Each has a scoped inline policy:

- **Order service**:
  - SQS actions on `order_events` and its DLQ.
  - SSM read on `/ms-learning/*`.
  - `states:StartExecution` on the SAGA state machine ARN.
  - `cloudwatch:PutMetricData` with condition `cloudwatch:namespace == "MsLearning"` (only this namespace, added when we implemented the OrdersCreated metric).
  - X-Ray write actions (`xray:PutTraceSegments`, `xray:PutTelemetryRecords`, sampling APIs).
- **Payment service**: SQS on `payment_events`, SSM read, X-Ray write.
- **User service**: DynamoDB actions on the users table, SSM read, X-Ray write.

### Three lessons here

1. **`sts:AssumeRole` with the `ecs-tasks.amazonaws.com` service principal** is the AWS pattern for handing a role to an ECS task. It's the same trust-relationship template repeated three times — that's why we hoist it into a `data "aws_iam_policy_document" "ecs_task_assume_role"` block and reference it from each `assume_role_policy`.

2. **The condition on `PutMetricData`** is a good example of *scoping*. Without it, order-service could publish to any namespace, including AWS-reserved ones. With it, IAM allows the action only if the request specifies namespace `MsLearning`.

3. **Actions with resource-level ARNs vs `*`.** Ideal is to constrain both actions AND resources — `sqs:SendMessage` on `arn:aws:sqs:...:order-events` is the tightest scoping. Some actions don't support resource-level constraints (e.g. `ecr:GetAuthorizationToken` — you can only allow it on `*`). Read the [AWS Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/reference_policies_actions-resources-contextkeys.html) if you're not sure whether an action is resource-scopeable.

> **Deeper dive — how does the container get credentials?** ECS agents inject two env vars into every task container: `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` and (optionally) `AWS_CONTAINER_CREDENTIALS_FULL_URI`. When the AWS SDK bootstraps in your app, its default credential provider chain checks these before any file-based creds and hits the ECS credentials endpoint on `169.254.170.2` (the ECS agent's link-local address). The agent returns short-lived (~6 hour) STS credentials for the task role. No long-lived access keys ever exist inside your container.

**Contrast with Scenario 1.** Scenario 1's EC2 instances have a single broad instance profile — same permissions across every service on the host. Scenario 2 is one role per service, and the process actually assumes it via ECS's task-role plumbing (no `~/.aws/credentials` on disk, no long-lived keys). This is the foundation of least-privilege in AWS.

---

## 10. Configuration

### `ssm.tf` — Parameter Store entries

Every value the services read at boot lives here:
- `/ms-learning/order/db-url`, `/db-username`, `/db-password` (SecureString)
- `/ms-learning/payment/db-url`, `/db-username`, `/db-password`
- `/ms-learning/user/dynamodb-table-name`
- `/ms-learning/order/internal-api-key` (created in `step_functions.tf`)
- `/ms-learning/order/saga-state-machine-arn` (created in `step_functions.tf`)
- `/ms-learning/user/url`, `/ms-learning/payment/url` — the service URLs for the order-service to reach peers.

Spring Boot reads these via `spring-cloud-aws-starter-parameter-store` — see `order-service/src/main/resources/application-prod.yml`:

```yaml
spring:
  config:
    import: "aws-parameterstore:/ms-learning/"
  datasource:
    url: ${/ms-learning/order/db-url}
```

Each service's task role has `ssm:GetParameter{,s,ByPath}` on `arn:aws:ssm:REGION:ACCOUNT:parameter/ms-learning/*`.

### Parameter types and tiers

SSM Parameter Store has three parameter types:
- **`String`** — plaintext value.
- **`StringList`** — comma-separated values.
- **`SecureString`** — encrypted at rest using a KMS key. Callers need `kms:Decrypt` on the key in addition to `ssm:GetParameter`. AWS uses your account's default `alias/aws/ssm` key unless you specify another.

Two tiers:
- **Standard** — 4 KB max, 10 000 parameters per account, free storage.
- **Advanced** — 8 KB max, 100 000 parameters, supports parameter policies (expiration, notifications), $0.05 per parameter per month.

All our parameters are Standard tier. If you need to store, say, a 6 KB JWT signing key, you'd bump to Advanced.

### When to use SSM vs Secrets Manager

Both encrypt at rest, both integrate with Terraform, both readable via IAM. Differences:
- **Secrets Manager** — built-in rotation (rotate DB passwords automatically via Lambda), higher cost ($0.40/secret/month + API calls), first-class integration with RDS for auto-rotation.
- **SSM** — free (Standard), no rotation built-in, general-purpose.

Rule of thumb: use Secrets Manager for anything you'd want to rotate on a schedule (DB passwords, API keys to third parties). Use SSM for everything else (URLs, feature flags, non-rotating config).

**Contrast with Scenario 1.** Scenario 1 uses **Spring Cloud Config Server** — a separate Spring Boot service that reads config from Git and serves it over HTTP. That works but you now have a) another JVM to run, b) another failure mode (config server down = boot failures), c) a Git repo to secure. SSM Parameter Store has none of those: managed availability, encrypted at rest with KMS, no extra process.

---

## 11. Observability

Broken into two pieces: the app-side instrumentation (added earlier in this branch) and the infrastructure-side dashboarding (`monitoring.tf`).

**The three-legged stool.** Observability is metrics + logs + traces:
- **Metrics** — numeric time-series (CPU %, request count, custom domain metrics). Cheap to store, easy to aggregate, poor at debugging one specific request. CloudWatch Metrics.
- **Logs** — structured text events. Expensive to store at scale, great at debugging one request, poor at aggregation. CloudWatch Logs (via `awslogs` driver).
- **Traces** — a linked graph of "spans" across services showing where time was spent for a single request. Great at "why is this endpoint slow?" AWS X-Ray.

Each answers different questions; you need all three.

### App-side changes

- **Structured JSON logging.** `logstash-logback-encoder:7.4` in each service's pom; `logback-spring.xml` defines a `prod` profile that uses `LogstashEncoder` with `customFields = {"service":"…","version":"…"}` and a `!prod` profile that uses a readable pattern layout with `[%X{traceId}]`. The `TraceIdFilter` puts the incoming `X-Amzn-Trace-Id` into MDC so every log line is correlateable.
- **X-Ray tracing.** `aws-xray-recorder-sdk-spring` + `-apache-http` on the classpath. Each service has an `@EnableXRay` annotation on its main class that `@Import`s `XRayConfig` — which registers `com.amazonaws.xray.jakarta.servlet.AWSXRayServletFilter` at the highest servlet-filter precedence. Every HTTP request becomes a segment; the filter auto-populates HTTP method / URL / status. Subsegments are added around specific hot spots — `user-service-call` and `saga-start` in order-service, `payment-processing` in payment-service.
- **Custom CloudWatch metric.** `OrderCommandHandler.publishOrdersCreatedMetric()` uses `CloudWatchAsyncClient.putMetricData` with namespace `MsLearning`, metric `OrdersCreated`, unit `COUNT`, value `1`, fire-and-forget. Failures log a warning and never break the request path.

### Why structured JSON logs matter

Plaintext logs are a debugging nightmare at scale. You can grep, but you can't aggregate. JSON logs turn every log line into a queryable record — CloudWatch Logs Insights can `stats count() by service, level` in seconds across millions of lines. The `customFields` we add (`service`, `version`) let you slice by "which service and which deploy is producing these errors?"

The `traceId` MDC field is the linchpin: paste it into Logs Insights across all service log groups and you see the full lifecycle of one request across all services it touched.

### X-Ray sampling

X-Ray is not free — every trace is a small write, and at scale it adds up. The SDK samples requests before recording them:
- The default `LocalizedSamplingStrategy` samples 1 request per second per rule + 5% of the remainder. This is more than enough to spot patterns without capturing everything.
- Sampled requests get an `X-Amzn-Trace-Id` header with `Sampled=1`. Downstream services see this and respect it (they don't re-decide).

**Trace vs segment vs subsegment:**
- **Trace** = the whole distributed request. Identified by trace ID.
- **Segment** = one service's contribution to the trace. Auto-created by the servlet filter for each HTTP request.
- **Subsegment** = a slice inside a segment (like "the DB call took 200ms" or "the SFN call took 40ms"). We add these manually around interesting boundaries.

### `monitoring.tf` — dashboards, alarms, saved queries

**Dashboard `ms-learning-ecs`** — six widgets:
1. ECS CPU utilisation across all three services (line graph).
2. ECS Memory utilisation across all three services.
3. SQS depth: visible + in-flight for both `order-events` and `payment-events`.
4. ALB traffic: RequestCount, HTTPCode_ELB_5XX_Count, TargetResponseTime.
5. Step Functions: ExecutionsSucceeded + ExecutionsFailed for the order SAGA.
6. `MsLearning/OrdersCreated` custom metric.

**Alarms — 8 total, all firing to the SNS topic below:**

| Alarm | Threshold | Notes |
|---|---|---|
| `ecs_cpu_high` (× 3, one per service via `for_each`) | CPU > 80% for 2 minutes | AWS/ECS CPUUtilization |
| `sqs_order_events_backlog` | ApproximateNumberOfMessagesNotVisible > 50 | In-flight messages piling up = consumers stalled |
| `sfn_executions_failed` | ExecutionsFailed > 5 in 5 min | Order SAGA has a bad hour |
| `alb_5xx_rate` | `100 * (elb_5xx + tg_5xx) / requests > 5%` for 2 min | **Metric-math alarm** — divides two sums, guarded with `IF(requests>0, …, 0)` |
| `rds_free_storage_low` (× 2, one per instance via `for_each`) | FreeStorageSpace < 1 GiB | Byte-value threshold `1073741824` |

Every alarm has `alarm_actions` **and** `ok_actions` on the SNS topic, so you get "back to normal" mail too.

### Alarm design principles hidden in these choices

- **Every alarm has both `alarm_actions` and `ok_actions`.** On-call getting a fire notification is only useful if they also get the "all clear" — otherwise they don't know if their fix worked or if the storm passed.
- **CPU alarm evaluates 2 periods.** One-period alarms flap on every brief spike. Two periods = "sustained pressure," which is what you want to page on.
- **The 5xx rate uses metric math, not raw counts.** 100 errors on 1000 requests is a crisis. 100 errors on 10 million requests is nothing. Absolute-count alarms fire in high-traffic environments and miss issues in low-traffic ones. Rate alarms work at any scale.
- **The metric-math expression has a divide-by-zero guard.** `IF(requests > 0, 100 * … / requests, 0)`. Without it, quiet periods (zero requests) produce `NaN` and the alarm goes into INSUFFICIENT_DATA — which behaves differently from "OK".
- **Different periods for different metrics.** SFN failures over 5 minutes (slow enough to accumulate signal). ECS CPU over 1 minute × 2 (quick response to a runaway process). RDS storage over 5 minutes × 1 (this is a very slow-moving metric).

### Metric math syntax quickly

CloudWatch metric math is a mini expression language. In `alb_5xx_rate` we use:
- `metric_query { id = "requests", metric { ... } }` — declares a raw metric with an alias.
- `metric_query { id = "e1", expression = "IF(requests > 0, 100 * (elb_5xx + tg_5xx) / requests, 0)", return_data = true }` — declares an expression built from those aliases. `return_data = true` on exactly one query tells CloudWatch which value the alarm evaluates.

Full function list: `SUM`, `AVG`, `MAX`, `MIN`, `IF`, `FILL`, `RATE`, `DIFF`, `ANOMALY_DETECTION_BAND`, etc.

**`aws_sns_topic.alerts`** — the fan-out point. `aws_sns_topic_subscription.alerts_email` is guarded by `count = var.alert_email_address == "" ? 0 : 1` so an empty variable creates the topic without a subscription. Setting `alert_email_address = "you@example.com"` in `terraform.tfvars` auto-subscribes on next apply (you still have to confirm the AWS email).

**Saved Logs Insights queries** (`aws_cloudwatch_query_definition`):
- `RecentErrors` — filters `level = "ERROR"` across all three service log groups, sorted desc, limit 200.
- `OrdersByStatus` — order-service log group only; regex-parses `status=…` out of messages and counts by status.
- `TraceSearch` — template with a `TRACE_ID_HERE` placeholder for chasing a specific request across services.

**Contrast with Scenario 1.** Scenario 1 runs **Prometheus + Grafana** on a monitoring EC2, scraping each service's `/actuator/prometheus`. Same conceptual outcome (metrics, dashboards, alerts) but three costs: (a) you run the monitoring stack yourself, (b) logs and metrics are in separate systems (Loki? ELK? often nothing), (c) there is no distributed tracing. Scenario 2 collapses all three (metrics, logs, traces) into CloudWatch + X-Ray. The trade-off is CloudWatch is more expensive per data point and less flexible than Prometheus/PromQL — you'll adopt this in prod when the operational cost of self-hosting Prometheus exceeds the extra $ CloudWatch charges.

---

## 12. CI/CD

### The pipeline mental model

CodePipeline is a **workflow orchestrator**. It doesn't build or deploy anything — it triggers *other* services to do that work and passes artifacts between them. Each stage's action is a call to a service (CodeBuild, CodeDeploy, Lambda, ECS, etc.). Between stages, artifacts flow through an S3 bucket that CodePipeline manages.

Conceptual dataflow:
```
GitHub (source)
   ↓ [CodeStar connection webhooks CodePipeline]
   ↓ [CodePipeline zips repo → S3 artifact bucket → source_output]
CodeBuild (build)
   ↓ [runs buildspec.yml, produces docker images + JSON files → S3 → build_output]
CodeDeploy (deploy × 3 stages)
   ↓ [reads taskdef+appspec from build_output; drives ECS blue/green]
ECS services updated
```

### `cicd.tf` — the pipeline

**Artifact bucket.** `aws_s3_bucket.codepipeline_artifacts` (suffixed with the account ID for uniqueness), versioned, SSE-AES256, public access blocked, `force_destroy = true` so `terraform destroy` cleans up.

Versioning matters because artifacts are keyed by pipeline execution ID — CodePipeline needs to fetch specific object versions for auditing. Also: `force_destroy = true` is dangerous in prod (it lets Terraform wipe a bucket with content); we accept it for learning cleanup.

**Three IAM roles:**
- `codepipeline` — assumed by CodePipeline. Can read/write the artifact bucket, `codestar-connections:UseConnection` on the GitHub connection, start CodeBuild, create CodeDeploy deployments, describe/update ECS, PassRole.
- `codebuild` — assumed by CodeBuild. Logs, artifact bucket, `ecr:GetAuthorizationToken` (unscoped, required for docker login), ECR push actions scoped to the three service repos, SSM read on `/ms-learning/*`, `ecs:DescribeTaskDefinition` (so the buildspec can fetch the current task-def revision).
- `codedeploy` — assumed by CodeDeploy. Attached `AWSCodeDeployRoleForECS` managed policy.

**`iam:PassRole` deserves special mention.** This is the "role that can hand another role to a service" permission. Without it, CodePipeline couldn't tell CodeBuild "run as `codebuild-role`" — because passing a role to another service is itself a privileged action. Terraform apply fails silently unless PassRole is granted; you'll see errors like *"Role cannot be assumed by pipeline"* on the first run without it.

**CodeBuild project `ms-learning-build`:**
- Image `aws/codebuild/standard:7.0`, `BUILD_GENERAL1_MEDIUM` (7 GB RAM, 4 vCPU), `privileged_mode = true` (needed for `docker build`).
- Env vars: `AWS_DEFAULT_REGION`, `ACCOUNT_ID`, `ECR_REGISTRY` (the account's ECR host).
- Buildspec loaded via `file("${path.module}/../../buildspec.yml")` — a single source of truth for the build steps (see next section).
- Logs into its own `/ms-learning/codebuild` log group.

**Why `privileged_mode = true`?** CodeBuild runs your build inside a Docker container. `docker build` inside that container needs `docker in docker` (DinD) — starting new containers from within one. That requires the outer container to be privileged (broad kernel capabilities). It's the standard pattern for "build a Docker image inside CI" and only carries a real risk if untrusted code runs on the CodeBuild host.

**One CodeDeploy application + deployment group per service.** All three are created with `for_each` over `local.codedeploy_services`, a map that captures each service's prod-listener ARN, test-listener ARN, blue TG name, green TG name, and ECS service name. This keeps the three declarations DRY (one resource block, three iterations).

Each deployment group is configured for:
- `deployment_type = "BLUE_GREEN"`, `deployment_option = "WITH_TRAFFIC_CONTROL"`.
- `deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"` — pragmatic for learning (instant swap). Swap to `ECSLinear10PercentEvery1Minute` for a real prod deploy.
- `blue_green_deployment_config.terminate_blue_instances_on_deployment_success` after 5 minutes.
- `auto_rollback_configuration.events = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]`.

**`DEPLOYMENT_STOP_ON_ALARM`** ties CodeDeploy to CloudWatch alarms. If you associate an alarm with the deployment group (not done in this codebase — good next step), CodeDeploy monitors it during the bake period and rolls back if it fires. This is how you build safe deploys: if your new version starts throwing 5xx, the alarm fires, CodeDeploy rolls back automatically, incident averted.

**The pipeline** (`aws_codepipeline.main`) has five stages:
1. **Source** — CodeStar Source Connection provider polling GitHub (`var.codestar_connection_arn`, `var.github_repository_id`, `var.github_branch`).
2. **Build** — CodeBuild action, input `source_output`, output `build_output`.
3. **Deploy-Order** — CodeDeployToECS provider consuming `taskdef-order-service.json` + `appspec-order-service.yaml` from `build_output`.
4. **Deploy-Payment** — same, for payment-service.
5. **Deploy-User** — same, for user-service.

The deploys run **sequentially** — user-service only starts after payment-service finishes. If you wanted them parallel you'd put all three actions inside a single "Deploy" stage.

**Why sequential? Two reasons:** (1) a failed deploy in one service should stop the pipeline before you touch the others — you get a chance to fix. (2) In a real system there's often ordering (deploy the database migration service before the app services). Parallel is faster but louder on failure.

### CodeStar Connection: the manual bit

CodePipeline reads from GitHub via a **CodeStar Connection**. You create the connection in the AWS console once, authenticate it with GitHub (grant the AWS Connector GitHub app access to your repos), and paste the ARN into `var.codestar_connection_arn`. Terraform cannot create this because the GitHub authentication step needs an interactive browser flow.

### `buildspec.yml` — what CodeBuild actually runs

Four phases:

1. **install** — pins `java: corretto21` runtime.
2. **pre_build** — computes `IMAGE_TAG = ${CODEBUILD_RESOLVED_SOURCE_VERSION:0:7}` (the first 7 chars of the git SHA), does `aws ecr get-login-password | docker login`.
3. **build** — `mvn -B -DskipTests package`, then loops over the three services running `docker build`, `docker tag`, `docker push $ECR_URL:$IMAGE_TAG`, `docker push $ECR_URL:latest`.
4. **post_build** — for each service, generates three artifacts:
   - `imagedefinitions-<svc>.json` — the `[{"name":"<svc>","imageUri":"…"}]` format (retained for reference / rolling-deploy compat).
   - `taskdef-<svc>.json` — fetched via `aws ecs describe-task-definition`, `jq` rewrites `containerDefinitions[0].image` to the new SHA-tagged URI and strips read-only fields (`taskDefinitionArn`, `revision`, ...). CodeDeploy will register this as a new task-def revision on deploy.
   - `appspec-<svc>.yaml` — the CodeDeploy AppSpec pointing at the container by name/port; the `<TASK_DEFINITION>` placeholder is substituted by CodeDeploy with the ARN of the newly-registered task definition.

**Why do we regenerate the task-def in the build?** Because Terraform-managed task definitions have the current-known image (`:latest`) baked in. When we build a new image with SHA `abc1234`, we need a new revision that references `:abc1234` — that's what CodeDeploy will actually run. The buildspec's `describe-task-definition + jq + rewrite image` dance is doing exactly that.

**Why keep the `:latest` tag alongside the SHA?** So Terraform re-applies (which recreate task defs from code) still produce a working task def if run without a build. Belt-and-braces.

**Contrast with Scenario 1.** Scenario 1's Jenkinsfile does the same conceptual steps — checkout, mvn package, docker build (or just JAR-and-scp), Ansible-driven restart. Differences: Jenkins is a server you run (with plugins to patch); CodePipeline is fully managed. Jenkins has more flexibility (any script, any plugin); CodePipeline is more constrained but you didn't have to install anything. On the deploy side, Jenkins rolls JARs onto EC2 via SSH; CodePipeline hands off to CodeDeploy which speaks the ECS blue/green protocol.

---

## 13. Outputs and provider

### `provider.tf`
- The AWS provider pinned by version constraint (`~> 5.0` = "any 5.x, not 6.x"). Locking major versions protects you from breaking-change updates.
- Two utility data sources: `aws_caller_identity` (for account ID) and `aws_availability_zones` (list of AZs in the region).
- `default_tags` block — every resource this provider creates gets `Project = "ms-learning"` and `Scenario = "ecs"` tags for free. This is how you write cross-cutting tags without repeating them in every resource block. Great for cost allocation reports.
- Terraform backend config: **S3 for state, DynamoDB for locking** — the standard team-safe setup. Multiple engineers `apply`-ing at the same time can't race because the DynamoDB row acts as a mutex.

### `variables.tf`
Every input the operator supplies:
- `aws_region` (default `us-east-1`).
- `db_username` (default `mslearning`) and `db_password` (sensitive, no default — you must supply).
- `alb_callback_domain` — Cognito redirect URL host, placeholder until you have HTTPS.
- `codestar_connection_arn` — the pre-created CodeStar Connection ARN for CodePipeline. No default; you must create it in the console once and paste the ARN.
- `github_repository_id` (default `muhammad-mansoor9/microservices-learning`) and `github_branch` (default `scenario-2-ecs`).
- `alert_email_address` (default `""`) — controls whether the SNS subscription is created.

**Sensitive variables.** `db_password` has `sensitive = true` so `terraform plan` prints `(sensitive value)` instead of the actual password. This is a display-only guard — state files still contain the value in plaintext, which is why the S3 backend has encryption enabled.

### `locals.tf`
```hcl
locals {
  name_prefix = "ms-learning"
  services    = ["order-service", "payment-service", "user-service"]
}
```
Two aliases used everywhere. `name_prefix` prepends every resource name so multiple environments never collide. `services` is the list you iterate over for the log groups, ECR repos, etc.

**Why not just use variables?** Variables are for things operators change; locals are for things developers change. `name_prefix` might become `ms-learning-staging` in a fork of this codebase, but that's a code change (locals), not a per-environment tweak (vars). Blurring the line is fine at small scales; the discipline matters when you have five environments and 20 modules.

### `outputs.tf`
The values you probably want after apply: ALB DNS, ECR repo URLs, RDS endpoints, SQS URLs, Cognito user-pool + client IDs, hosted-UI URL, DynamoDB table name, SAGA state-machine ARN, CodePipeline URL, artifact bucket, internal ALB DNS, dashboard URL, SNS topic ARN.

Read them with `terraform output NAME` after apply.

---

## 14. Cost, safety and clean-up

**What costs money when idle:**
- Fargate tasks (`desired_count = 1` × 3 services) — about $10–15/mo at t3.micro-equivalent sizing.
- RDS `db.t3.micro` × 2 — ~$25/mo each.
- Two ALBs (external + internal) — ~$16/mo each.
- NAT Gateway — ~$32/mo + data transfer (this is often the biggest surprise).
- CloudWatch Logs, metrics, dashboards — small ($1–3/mo at learning-scale traffic).

**Total idle burn is meaningful — approaching $130/mo just for the network + compute + DB baseline.** For a learning environment, run `terraform destroy` between sessions. Two things to watch:
1. `random_password.internal_api_key` regenerates on the next apply unless you keep state. Losing state without cleaning up leaks resources.
2. Service Discovery namespaces sometimes fail to delete because of orphan service registrations — the observation history for this branch mentions the exact AWS CLI cleanup needed (S324, S325).

### Cost-cutting tricks for learning environments

- **Use Fargate Spot** — `capacity_provider_strategy = [{ capacity_provider = "FARGATE_SPOT", weight = 1 }]` on the ECS service. Up to 70% cheaper, at the cost of AWS being able to reclaim tasks with 2 minutes' warning.
- **Replace NAT Gateway with VPC endpoints** for AWS services. S3 and DynamoDB endpoints are free; interface endpoints for ECR, SSM, CloudWatch are $0.01/hour each — still cheaper than NAT for low-traffic environments.
- **Set log retention aggressively** — 7 days for scenario-2. If you don't need long retention, halve it.
- **Terraform destroy between sessions** — the fastest way to zero the bill.

**Safety flags used for learning-mode that you would flip in prod:**
- `aws_ecr_repository.force_delete = true` — allows destroy with images present.
- `aws_db_instance.skip_final_snapshot = true` — no snapshot before destroy.
- `aws_s3_bucket.force_destroy = true` on the artifact bucket.
- `deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"` — instant traffic shift; use linear in prod.

### The destroy-order problem

`terraform destroy` walks the dependency graph in reverse. Most of the time this works. Two known issues:

**Service Discovery namespaces.** Cloud Map services registered by ECS Service Connect sometimes fail to deregister when the ECS service is destroyed. The namespace destroy then fails with *"cannot delete namespace with registered services."* Fix: `aws servicediscovery deregister-instance` on every orphan, then `aws servicediscovery delete-service`, then retry destroy.

**RDS deletion protection.** If you flip `deletion_protection = true` for safety, then remember to flip it back before `destroy`. Otherwise: *"cannot delete protected database."*

---

## 15. What is deliberately not here

Some things you would add before calling this production-ready but that are out of scope for the current learning branch:

- **HTTPS.** External ALB is HTTP-only. Real prod needs an ACM certificate, an HTTPS listener, and Cognito redirect URLs bound to a real domain.
- **WAF.** No AWS WAF in front of the ALB. Add `aws_wafv2_web_acl` + association for public-facing services.
- **Autoscaling.** ECS services all run `desired_count = 1`. In prod you'd wire `aws_appautoscaling_target` and CPU/memory-based `aws_appautoscaling_policy` per service.
- **Secrets rotation.** DB passwords come from `var.db_password`. In prod you'd use AWS Secrets Manager with rotation.
- **Backup policies.** RDS `backup_retention_period` is set for automated snapshots but no cross-region copy, no DB Cluster Snapshot lifecycle policies.
- **Multi-region.** Everything is in one region. Multi-region adds Route 53 latency routing, cross-region replication for S3/DynamoDB, and DR runbooks.
- **Manual approval gate** in the pipeline before deploys. `aws_codepipeline_stage` supports it; you'd add it between Build and Deploy-Order for change-review environments.
- **Database migrations.** No Flyway/Liquibase. Schema changes are ad-hoc.
- **Alarm-driven auto-rollback** in CodeDeploy. Wire alarms to deployment groups so a spike in 5xx during the bake period rolls back the deployment automatically.
- **VPC Flow Logs** for network audit trails.
- **CloudTrail** for API audit logs.
- **AWS Config** for compliance rules ("all S3 buckets must have versioning," etc.).
- **Cost anomaly detection** — alerts if daily spend suddenly doubles.

Each of these is a good next-step exercise once the base scenario is comfortable.

---

## Appendix — File index

| File | Section | Purpose |
|---|---|---|
| `provider.tf` | §13 | AWS provider + backend + shared data sources |
| `variables.tf` | §13 | All operator inputs |
| `locals.tf` | §13 | `name_prefix`, service list |
| `outputs.tf` | §13 | Post-apply values |
| `vpc.tf` | §4 | VPC, subnets, IGW, NAT, route tables |
| `sg.tf` | §4 | Four security groups |
| `ecr.tf` | §5 | Three ECR repos |
| `ecs_cluster.tf` | §5 | ECS cluster + Cloud Map namespace |
| `ecs_services.tf` | §5 | Log groups, task definitions, ECS services |
| `rds.tf` | §6 | Order + payment PostgreSQL instances |
| `dynamodb.tf` | §6 | Users table |
| `sqs.tf` | §7 | Order + payment queues, each with DLQ |
| `step_functions.tf` | §7 | Lambda proxies, SFN role, state machine, SSM parameters |
| `step_functions/order_saga.json` | §7 | ASL definition of the SAGA |
| `alb.tf` | §8 | External + internal ALBs, blue/green TGs, listeners |
| `cognito.tf` | §9 | User pool, domain, app clients |
| `iam.tf` | §9 | Task-execution role + three task roles |
| `ssm.tf` | §10 | Application parameters |
| `monitoring.tf` | §11 | Dashboard, alarms, SNS topic, saved queries |
| `cicd.tf` | §12 | S3, IAM, CodeBuild, CodeDeploy × 3, CodePipeline |
| `../../buildspec.yml` | §12 | CodeBuild build/push/artifact steps |

---

## Appendix — Cloud vocabulary quick reference

Words you'll hear a lot; not always obvious what they mean.

| Term | What it means |
|---|---|
| **ENI** | Elastic Network Interface. The virtual NIC every VPC resource attaches to. Has an IP, an SG, MAC address, and can be moved between resources. |
| **AZ** | Availability Zone. A physically-isolated datacentre inside a region. `us-east-1` has 6 AZs (`us-east-1a` through `us-east-1f`). Cross-AZ traffic has latency (single-digit ms) and data-transfer cost ($0.01/GB in each direction). |
| **Region** | A geographic area with ≥ 2 AZs. Latency between regions is 60–200ms. Most AWS services are region-scoped. |
| **IAM Principal** | Anything IAM can identify: an IAM user, an IAM role, an AWS service, a federated user. |
| **Trust policy** | The policy that says who can *assume* a role. Attached via `assume_role_policy`. |
| **Identity policy** | The policy that says what a role *can do* once assumed. Attached separately. |
| **STS** | Security Token Service. The service that vends short-lived credentials when you assume a role. `sts:AssumeRole` is *the* IAM action. |
| **Managed policy** | An AWS-authored policy attached to roles/users by ARN. Reused across accounts. Contrast with "inline policy" which is embedded in one role and unique to it. |
| **Fargate** | ECS launch type with no EC2 backing. Pay per second of task run. |
| **Task** | A running unit of a task definition. Ephemeral. |
| **Service** | A specification of "keep N tasks of this task def running." Long-lived. |
| **Cluster** | A logical group of tasks/services + capacity providers. |
| **Cloud Map** | AWS's service discovery primitive. Underlies ECS Service Connect. |
| **CIDR** | Classless Inter-Domain Routing notation. `10.0.0.0/16` = "starting IP + prefix length." |
| **Ingress / Egress** | Traffic *into* the resource / *out of* the resource. |
| **AppSpec** | The YAML file CodeDeploy reads to know what to deploy (task def + container + port). |
| **ASL** | Amazon States Language. The JSON dialect for Step Functions state machines. |
| **JWKS** | JSON Web Key Set. The public keys an OIDC provider (like Cognito) publishes for JWT signature verification. |
| **KMS** | Key Management Service. Where the actual encryption keys for SSE-KMS, SecureString, RDS encryption, etc. live. |
