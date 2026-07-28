# Scenario 3 — From EC2 to EKS: a first-time Kubernetes walkthrough

> **Who this is for.** You've shipped the same three services (order,
> payment, user) once already on plain AWS (Scenario 1 on `main`:
> EC2 + ALB + RDS + Eureka + Config Server + API Gateway). Now we're
> re-hosting the same business logic on **Amazon EKS** — a managed
> Kubernetes cluster — plus the platform tooling that makes running
> apps on Kubernetes practical (Istio, ArgoCD, KEDA, Prometheus,
> FluentBit). This document is the tour of every moving part.

---

## Contents

- [1. The elevator pitch: what changed vs Scenario 1](#1-elevator-pitch)
- [2. Kubernetes vocabulary you actually need](#2-vocabulary)
- [3. High-level architecture](#3-architecture)
- [4. Repository tour: what got added on scenario-3](#4-repo-tour)
- [5. Part 1 — Making Spring Boot lean](#5-part-1-lean-spring-boot)
- [6. Part 2 — Docker images](#6-part-2-docker)
- [7. Part 3 — Helm charts](#7-part-3-helm-charts)
- [8. Part 4 — Terraform: the EKS platform](#8-part-4-terraform)
- [9. Part 5 — Istio: automatic mTLS between pods](#9-part-5-istio)
- [10. Part 6 — GitOps with ArgoCD](#10-part-6-argocd)
- [11. Part 7 — CI/CD with GitHub Actions](#11-part-7-github-actions)
- [12. Part 8 — KEDA autoscaling from SQS depth](#12-part-8-keda)
- [13. Part 9 — Observability (Prometheus / Grafana / FluentBit)](#13-part-9-observability)
- [14. Part 10 — The `setup-cluster.sh` bootstrap](#14-part-10-setup-script)
- [15. End-to-end request flow](#15-end-to-end)
- [16. Command cheat sheet](#16-cheat-sheet)
- [17. Scenario 1 vs Scenario 3 — side-by-side](#17-side-by-side)
- [18. Troubleshooting: the pitfalls we hit](#18-troubleshooting)

---

<a id="1-elevator-pitch"></a>

## 1. The elevator pitch: what changed vs Scenario 1

On `main` (Scenario 1) each Spring Boot service runs on a dedicated
EC2 host. Service discovery is done by **Eureka**, config is served
by **Spring Cloud Config Server**, and traffic enters through an
**API Gateway** (Spring Cloud Gateway) sitting behind an **ALB**.
Services trust each other with an `X-Internal-Api-Key` header.

On `scenario-3` we throw all of that away and let Kubernetes handle
it:

| Concern                    | Scenario 1                              | Scenario 3                                                   |
| -------------------------- | --------------------------------------- | ------------------------------------------------------------ |
| Compute                    | One EC2 per service                     | One EKS cluster, pods packed onto shared nodes               |
| Service discovery          | Eureka                                  | Kubernetes DNS (`payment-service.default.svc.cluster.local`) |
| Config distribution        | Spring Cloud Config Server              | Env vars from a Helm-rendered Deployment                     |
| API entry point            | Spring Cloud Gateway + ALB              | AWS ALB directly, provisioned by AWS Load Balancer Controller |
| Inter-service auth         | `X-Internal-Api-Key` header             | Istio mTLS (Envoy sidecar, zero app code)                    |
| Deploy pipeline            | Bake AMI or `scp` a JAR                 | Docker image → ECR → Helm chart → ArgoCD                     |
| Autoscaling                | EC2 ASG on CPU                          | HPA on CPU **and** KEDA on SQS queue depth                   |
| Metrics                    | CloudWatch agent per host               | Prometheus scrapes every pod, Grafana dashboards             |
| Logs                       | CloudWatch agent per host               | FluentBit DaemonSet → CloudWatch Logs                        |

The pitch: **Kubernetes gives you one abstraction (the cluster) for
scheduling, networking, config, secrets, health checks, and rollout.
The trade is that you now have a lot of new nouns to learn.**

---

<a id="2-vocabulary"></a>

## 2. Kubernetes vocabulary you actually need

Learn these ten and you can read every file in this repo.

| Term                    | What it is                                                                                                                                        |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Cluster**             | One control plane + a pool of worker **Nodes** (EC2 VMs in EKS).                                                                                  |
| **Node**                | A VM (or bare metal) that runs pods.                                                                                                              |
| **Pod**                 | The smallest deployable unit. One or more containers sharing a network namespace. In our services: one pod = one Java app.                        |
| **Deployment**          | A controller that keeps N identical Pods running. You *describe* desired state; it makes it so.                                                   |
| **ReplicaSet**          | Owned by a Deployment. You rarely touch this directly.                                                                                            |
| **Service**             | A stable virtual IP + DNS name in front of a set of pods. `payment-service:8080` resolves to whichever pods currently match its label selector.   |
| **Ingress**             | Routing rules for HTTP traffic entering the cluster from outside. Backed by a controller (we use AWS Load Balancer Controller → ALB).             |
| **Namespace**           | A logical partition of the cluster. Used for scoping (RBAC, quotas, network policy). Our apps live in `default`; platform tools live in others.   |
| **ConfigMap / Secret**  | Key–value config baked into a resource. We inject env vars from Helm values rather than ConfigMaps for now, but the pattern is the same.          |
| **ServiceAccount (SA)** | The identity a pod runs as. In EKS you annotate an SA with an IAM role ARN and the pod magically gets AWS permissions. This is called **IRSA**.   |
| **DaemonSet**           | Runs exactly one pod per Node. Used for host-level agents (FluentBit).                                                                            |
| **HPA**                 | Horizontal Pod Autoscaler. Scales a Deployment based on CPU/memory.                                                                               |
| **ScaledObject (KEDA)** | Like an HPA, but the trigger can be an external metric — SQS queue depth, Kafka lag, cron, etc.                                                   |
| **Helm chart**          | A folder of templated YAML files. Renders concrete Kubernetes manifests with values you plug in. Like a package manager for Kubernetes.           |

### The one mental model that helps

Kubernetes objects are **desired state**, not commands. You tell the
API server "I want 3 replicas of order-service" and controllers
reconcile toward that state forever. A pod dying doesn't require
you to react — the ReplicaSet controller notices and creates a
replacement.

---

<a id="3-architecture"></a>

## 3. High-level architecture

```
                           ┌──────────────────────────┐
User (Cognito-authed) ────▶│   AWS ALB (public)       │
                           │  Ingress class = alb     │
                           └──────────────┬───────────┘
                                          │
   ┌──────────────────────────────────────┼──────────────────────────────────────┐
   │ EKS Cluster (ms-learning-eks)        │                                       │
   │                                      ▼                                       │
   │   default namespace (istio-injection=enabled)                                 │
   │   ┌──────────────────────┐   ┌───────────────────┐   ┌──────────────────┐    │
   │   │ order-service Pod    │   │ payment-service   │   │ user-service     │    │
   │   │ ┌──────────┐ ┌─────┐ │   │ ┌────────┐ ┌────┐ │   │ ┌───────┐ ┌────┐ │    │
   │   │ │ Spring   │ │Envoy│ │◀─▶│ │Spring  │ │Envoy│ │◀─▶│ │Spring │ │Envoy│    │
   │   │ │  App     │ │(sc) │ │mTLS │  App   │ │(sc) │ │mTLS │ App   │ │(sc)│    │
   │   │ └──────────┘ └─────┘ │   │ └────────┘ └────┘ │   │ └───────┘ └────┘ │    │
   │   └──────────┬───────────┘   └────────┬──────────┘   └────────┬─────────┘    │
   │              │                        │                       │              │
   │   ┌──────────┼────────────────────────┼───────────────────────┼───────┐      │
   │   │          │                        │                       │       │      │
   │   │      istio-system (istiod issues SPIFFE certs to sidecars)        │      │
   │   │          │                        │                       │       │      │
   │   │      monitoring (Prometheus scrapes /actuator/prometheus of each pod)    │
   │   │          │                        │                       │       │      │
   │   │      keda   (watches SQS depth, scales payment-service 0..5)      │      │
   │   │          │                        │                       │       │      │
   │   │      argocd (pulls Helm charts from Git → applies them)           │      │
   │   │          │                        │                       │       │      │
   │   │      amazon-cloudwatch (FluentBit DaemonSet on every node)        │      │
   │   │          │                        │                       │       │      │
   │   │      kube-system (aws-lb-controller, coredns, ebs-csi, kube-proxy)│      │
   │   └──────────┼────────────────────────┼───────────────────────┼───────┘      │
   └──────────────┼────────────────────────┼───────────────────────┼──────────────┘
                  │                        │                       │
                  ▼                        ▼                       ▼
        ┌─────────────────┐      ┌──────────────────┐    ┌──────────────────┐
        │ SQS order-events│      │ RDS payment_db   │    │ DynamoDB users   │
        │ (queue depth =  │      │ (or self-hosted  │    │ table            │
        │  KEDA metric)   │      │  Postgres pod)   │    │                  │
        └─────────────────┘      └──────────────────┘    └──────────────────┘
                                             ▲
        FluentBit ─▶ CloudWatch Logs        │
                                             │
        Prometheus + Grafana in-cluster ────┘
```

If you squint, each **namespace** is a "software product" running in
its own logical zone. Application code lives in `default`; every
platform capability lives in its own namespace. That's a very
different shape from Scenario 1 where "the platform" was really just
some AWS services (ALB, RDS, CloudWatch) and everything else was
your app.

---

<a id="4-repo-tour"></a>

## 4. Repository tour: what got added on scenario-3

Files and directories you didn't have on `main`:

| Path                                     | Purpose                                                                 |
| ---------------------------------------- | ----------------------------------------------------------------------- |
| `helm/{order,payment,user}-service/`     | One Helm chart per service (Chart.yaml, values.yaml, templates)         |
| `helm/values-local.yaml`                 | Shared overrides for local dev                                          |
| `helm/values-prod.yaml`                  | Shared overrides for prod deploys (image tag, KEDA on, ingress on, ...) |
| `infrastructure/scenario-3/`             | Terraform for the whole EKS platform                                    |
| `k8s/namespace.yaml`                     | Adds the `istio-injection=enabled` label to `default`                   |
| `k8s/istio/`                             | mTLS policy + destination rules                                         |
| `k8s/fluentbit/`                         | FluentBit namespace + SA + ConfigMap + DaemonSet                        |
| `argocd/`                                | Three ArgoCD Application manifests, one per service                     |
| `scripts/setup-cluster.sh`               | Idempotent post-`terraform apply` bootstrap                             |
| `.github/workflows/eks-deploy.yml`       | CI: build → push → bump image tag in Git                                |

Files that got **removed or slimmed down** vs `main`:

| Path                                              | What happened                                                                       |
| ------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `api-gateway/`, `eureka-server/`, `config-server/` | Untouched on this branch, but **unused at runtime.** K8s replaces all three roles. |
| `application-{local,prod,docker}.yml` per service | Merged into a single env-var-driven `application.yml`.                              |
| `InternalApiKeyFilter` (never existed here)       | Would have been deleted — Istio does mTLS at the sidecar.                           |
| Spring Cloud dependencies                          | Not present. Poms are pure Boot + JPA + actuator + Micrometer + Lombok.             |

---

<a id="5-part-1-lean-spring-boot"></a>

## 5. Part 1 — Making Spring Boot lean

Kubernetes wants stateless processes that read config from env vars
and expose HTTP health checks. Everything else the platform does for
you. So we stripped the apps down.

### 5.1 One `application.yml` per service, everything env-driven

Before (Scenario 1): three files per service (`application-local.yml`,
`application-prod.yml`, `application-docker.yml`) plus `SPRING_PROFILES_ACTIVE`
switching between them.

After:

```yaml
# order-service/src/main/resources/application.yml
spring:
  application: { name: order-service }
  datasource:
    url: ${DB_URL:jdbc:postgresql://localhost:5432/order_db}
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
services:
  user-service-url:    ${USER_SERVICE_URL:http://user-service:8080}
  payment-service-url: ${PAYMENT_SERVICE_URL:http://payment-service:8080}
management:
  endpoints: { web: { exposure: { include: health,info,prometheus } } }
  endpoint:
    health:
      probes: { enabled: true }   # /actuator/health/liveness + /readiness
      group:
        readiness: { include: readinessState,db }
        liveness:  { include: livenessState }
```

**Why `${VAR:default}`?** The default makes the file work when you
just `mvn spring-boot:run` on your laptop. In Kubernetes we override
every value via the Helm-rendered `env:` block.

### 5.2 Actuator probes for Kubernetes

`management.endpoint.health.probes.enabled: true` exposes two extra
endpoints:

- `/actuator/health/liveness` — is the JVM alive? If this fails,
  kubelet **restarts** the pod.
- `/actuator/health/readiness` — is the JVM ready to receive
  traffic? If this fails, kubelet **removes** the pod from the
  Service endpoints (but doesn't restart it).

The distinction matters. A DB blip should fail readiness (stop
routing new requests to me) but not liveness (I'm fine, I'll recover).
That's why we grouped `db` under readiness only:

```yaml
group:
  readiness: { include: readinessState,db }   # DB failures block traffic
  liveness:  { include: livenessState }       # but don't restart the pod
```

### 5.3 Logs with `%X{trace_id}` for distributed tracing

We added a `logback-spring.xml` to every service:

```xml
<property name="LOG_PATTERN"
    value="%d{...} %5p [${spring.application.name:-},%X{trace_id:-},%X{span_id:-}] %-40.40logger{39} : %m%n"/>
```

`%X{trace_id}` reads the `trace_id` key from **Mapped Diagnostic Context (MDC)**
— a thread-local key-value store logback consults for every log
line. **We don't populate MDC ourselves.** We attach the OpenTelemetry
Java agent at runtime via `JAVA_TOOL_OPTIONS=-javaagent:...` and the
agent (a) propagates W3C `traceparent` headers across HTTP calls
between services, and (b) writes the current trace/span id into MDC
for every log line.

That means one request touching all three services produces log
lines *in three different pods* that share the same `trace_id` —
you can grep for it in CloudWatch and see the whole flow.

The agent JAR is downloaded at pod startup by an `initContainer` in
the Helm chart (see §7.3).

### 5.4 What we removed

- `spring-cloud-starter-netflix-eureka-client` — Kubernetes DNS
  replaces service registry lookups.
- `spring-cloud-starter-config` — Helm/env vars replace remote
  config.
- `spring-boot-starter-oauth2-resource-server` — auth moves up to
  the Ingress (Cognito on the ALB) and mTLS handles east-west.

Result: `order-service/pom.xml` fits on your screen and the Docker
image builds in ~30 seconds.

---

<a id="6-part-2-docker"></a>

## 6. Part 2 — Docker images

Every service has a `Dockerfile` at its root. The pattern:

```dockerfile
# order-service/Dockerfile
FROM maven:3.9-eclipse-temurin-21-alpine AS builder
WORKDIR /build
COPY pom.xml .
RUN mvn install -N -q                        # install parent pom into local repo
COPY order-service/pom.xml order-service/pom.xml
COPY payment-service/pom.xml payment-service/pom.xml
COPY user-service/pom.xml user-service/pom.xml
RUN mvn -pl order-service dependency:go-offline -q   # cache deps
COPY order-service/src order-service/src
RUN mvn -pl order-service package -DskipTests -q

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /build/order-service/target/order-service-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","app.jar"]
```

Two stages:

1. **builder** — full Maven + JDK. Downloads deps, compiles, packages.
2. **runtime** — JRE only. Ships just `app.jar`.

The `EXPOSE 8080` is documentation only, but it matches what our
Spring app listens on (`SERVER_PORT` defaults to `8080`) and what
Kubernetes/Helm assume. Every service is `8080` in scenario 3 for
uniformity — host-port mapping in `docker-compose.yml` gives you
distinct dev-machine ports (`8081/8082/8083`) that all route to the
container's `8080`.

**Why not distroless?** Alpine is small (~80MB image) and gives
you `curl` for the docker-compose healthcheck. Distroless is
smaller/safer but harder to debug on your first Kubernetes project.
Trade you can revisit later.

---

<a id="7-part-3-helm-charts"></a>

## 7. Part 3 — Helm charts

Helm is a template engine + package manager. Instead of writing a
`Deployment` YAML by hand for each service, you write **one template
per resource type** and Helm renders concrete YAML with your
`values.yaml` plugged in.

### 7.1 Anatomy of a chart

```
helm/order-service/
├── Chart.yaml                 ← name, version=0.1.0, appVersion
├── values.yaml                ← defaults for every knob
└── templates/
    ├── _helpers.tpl           ← reusable helpers (fullname, labels, …)
    ├── serviceaccount.yaml    ← ServiceAccount with IRSA annotation
    ├── deployment.yaml        ← the Deployment
    ├── service.yaml           ← ClusterIP on port 8080
    ├── hpa.yaml               ← HorizontalPodAutoscaler (optional)
    └── ingress.yaml           ← order-service only: ALB + Cognito
```

### 7.2 `values.yaml` — the knobs

```yaml
image: { repository: "", tag: latest, pullPolicy: IfNotPresent }
replicaCount: 1
resources:
  requests: { cpu: 256m, memory: 512Mi }   # what the pod is guaranteed
  limits:   { cpu: 500m, memory: 1Gi   }   # what it can't exceed
env: {}                                    # extra env vars merged in
irsa: { roleArn: "" }                      # IAM role for the pod's SA
service: { port: 8080 }
autoscaling:
  enabled: false                           # HPA (CPU)
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70
otel:
  agentVersion: "2.10.0"                   # OpenTelemetry Java agent
  agentUrl: ""                             # empty = derive from version
```

### 7.3 `deployment.yaml` — the money template

The interesting bits:

```yaml
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    metadata:
      labels: {{- include "order-service.selectorLabels" . | nindent 8 }}
      annotations:
        prometheus.io/scrape: "true"                       # Prometheus finds you
        prometheus.io/port:   {{ .Values.service.port | quote }}
        prometheus.io/path:   "/actuator/prometheus"
    spec:
      serviceAccountName: {{ include "order-service.serviceAccountName" . }}
      volumes:
        - name: otel-agent
          emptyDir: {}                                     # ephemeral scratch
      initContainers:
        - name: otel-agent-downloader                      # runs BEFORE app
          image: curlimages/curl:8.10.1
          command:
            - sh
            - -c
            - |
              curl -fsSL -o /agents/opentelemetry-agent.jar \
                "{{ include "order-service.otelAgentUrl" . }}"
          volumeMounts:
            - { name: otel-agent, mountPath: /agents }
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/agents/opentelemetry-agent.jar"
            - name: OTEL_SERVICE_NAME
              value: {{ include "order-service.name" . | quote }}
            {{- range $key, $value := .Values.env }}       # merge in overrides
            - { name: {{ $key }}, value: {{ $value | quote }} }
            {{- end }}
          volumeMounts:
            - { name: otel-agent, mountPath: /agents, readOnly: true }
          livenessProbe:  { httpGet: { path: /actuator/health/liveness,  port: http }, initialDelaySeconds: 60, periodSeconds: 10 }
          readinessProbe: { httpGet: { path: /actuator/health/readiness, port: http }, initialDelaySeconds: 30, periodSeconds: 10 }
          resources: {{- toYaml .Values.resources | nindent 12 }}
```

Every non-obvious piece explained:

- **initContainer**: a container that runs to completion *before* the
  main container starts. We use it to download the OpenTelemetry
  Java agent JAR into a shared `emptyDir` volume (`/agents`). The
  main container then mounts that volume read-only and starts the
  JVM with `-javaagent:/agents/opentelemetry-agent.jar`.
- **`emptyDir`**: a scratch volume that exists for the lifetime of
  the pod (not the container). Both containers see the same files.
- **Probes**: Kubernetes calls the endpoints on a schedule. The
  first probe is delayed (`initialDelaySeconds`) to give the JVM
  time to boot.
- **`toYaml .Values.resources | nindent 12`**: expand the
  `resources:` block from values.yaml, indented by 12 spaces to
  match this template's context.

### 7.4 `values-local.yaml` vs `values-prod.yaml`

Both live at `helm/`, one level above the per-service charts. You
apply them with `-f`:

```bash
helm upgrade --install order-service ./helm/order-service \
    -f ./helm/values-prod.yaml \
    --set image.repository=<ecr>/order-service --set image.tag=<sha> \
    --set irsa.roleArn=<order-role-arn> \
    --set ingress.enabled=true ...
```

Prod turns on: `replicaCount=2`, `autoscaling.enabled=true`, OTLP
export to the collector, KEDA on payment-service. Local turns
everything off, uses a fake `image.tag=local`.

---

<a id="8-part-4-terraform"></a>

## 8. Part 4 — Terraform: the EKS platform

Everything AWS-side lives in `infrastructure/scenario-3/`. Nine
files, each with one job.

### 8.1 `providers.tf` — three providers, one backend

```hcl
required_providers {
  aws        = { source = "hashicorp/aws",        version = "~> 5.0"  }
  kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
  helm       = { source = "hashicorp/helm",       version = "~> 2.13" }
}

backend "s3" {
  bucket         = "microservices-learning-terraform-state-dev"
  key            = "scenario3/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "microservices-learning-terraform-locks-dev"
  encrypt        = true
}

provider "aws" {
  region       = var.aws_region
  default_tags { tags = { Project = "ms-learning", Scenario = "eks" } }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks","get-token","--cluster-name",module.eks.cluster_name,"--region",var.aws_region]
  }
}
```

**Why the `exec` block?** EKS tokens are short-lived. Using the
`exec` plugin lets Terraform ask `aws eks get-token` for a fresh
one on each call, instead of caching a token that will expire mid-apply.

**`default_tags`** on the AWS provider means every taggable resource
(VPC, subnets, node group, IAM roles, SQS queue, etc.) automatically
gets `Project=ms-learning, Scenario=eks`. Great for cost allocation
and cleanup.

### 8.2 `vpc.tf` — one VPC with K8s-aware subnet tags

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  name    = "${var.cluster_name}-vpc"
  cidr    = "10.0.0.0/16"
  azs             = ["us-east-1a","us-east-1b"]
  public_subnets  = ["10.0.101.0/24","10.0.102.0/24"]
  private_subnets = ["10.0.1.0/24","10.0.2.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"    # public ALBs land here
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"    # internal ELBs
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
```

The `kubernetes.io/role/elb=1` tag on public subnets is how the AWS
Load Balancer Controller **discovers where to put ALBs** when an
`Ingress` is created. Without it, the controller has no idea which
subnets are for public traffic.

### 8.3 `eks.tf` — the cluster and node group

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "ms-learning-eks"
  cluster_version = "1.30"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  cluster_endpoint_public_access           = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns            = { most_recent = true }
    kube-proxy         = { most_recent = true }
    vpc-cni            = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn   # § 8.4
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size = 1, max_size = 3, desired_size = 2
      capacity_type  = "ON_DEMAND"
    }
  }
}
```

Concepts:

- **Cluster addons** are AWS-managed installations of core cluster
  components. Cheaper than helming them yourself.
- **`enable_irsa = true`** provisions the OIDC provider that lets
  pods assume IAM roles (§8.5).
- **`enable_cluster_creator_admin_permissions`** uses EKS's newer
  **access entries** system to give the caller admin — no more
  editing the `aws-auth` ConfigMap by hand.

### 8.4 The EBS CSI driver gotcha

The `aws-ebs-csi-driver` addon is what lets Kubernetes PersistentVolumeClaims
allocate EBS volumes. The controller pods need to call `ec2:CreateVolume`,
`ec2:AttachVolume`, etc. If they can't, the addon **hangs in `CREATING`
forever** — Terraform times out at 20 minutes with `waiting for EKS Add-On
… to become 'ACTIVE'`. We hit this and fixed it by giving the addon its
own IRSA role:

```hcl
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"
  role_name = "${var.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true                              # AWS-managed policy
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
```

`attach_ebs_csi_policy = true` attaches the built-in
`AmazonEBSCSIDriverPolicy` from AWS. The role's trust policy is
scoped so **only** the `ebs-csi-controller-sa` ServiceAccount in
`kube-system` can assume it.

### 8.5 `irsa.tf` — IAM Roles for Service Accounts, explained

**IRSA** is EKS's mechanism for giving pods AWS API permissions
without static keys. The chain:

```
Pod → uses ServiceAccount (annotated with role ARN)
     → gets AWS Web Identity Token from projected volume
     → exchanges token via STS AssumeRoleWithWebIdentity
     → receives short-lived AWS credentials
     → makes AWS API calls
```

Setup in Terraform (using the same sub-module for every role):

```hcl
module "user_service_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"
  role_name = "${var.cluster_name}-user-service"
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["default:user-service"]   # who can assume this role
    }
  }
}

resource "aws_iam_role_policy" "user_service" {
  role   = module.user_service_irsa.iam_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem","dynamodb:GetItem","dynamodb:Query"]
      Resource = "arn:aws:dynamodb:us-east-1:${data.aws_caller_identity.current.account_id}:table/users"
    }]
  })
}
```

Six IRSA roles total on scenario-3:

| Role                              | Trust                                        | Permissions                        |
| --------------------------------- | -------------------------------------------- | ---------------------------------- |
| `…-aws-load-balancer-controller` | `kube-system:aws-load-balancer-controller`   | Built-in ALB controller policy     |
| `…-order-service`                 | `default:order-service`                      | SQS on order-events, SSM read      |
| `…-payment-service`               | `default:payment-service`                    | SQS consume on order-events        |
| `…-user-service`                  | `default:user-service`                       | DynamoDB on users                  |
| `…-ebs-csi-driver`                | `kube-system:ebs-csi-controller-sa`          | Built-in EBS CSI policy            |
| `…-fluentbit`                     | `amazon-cloudwatch:fluentbit`                | CloudWatch Logs write              |

The Helm chart wires it up on the app side:

```yaml
# helm/order-service/templates/serviceaccount.yaml
metadata:
  name: {{ include "order-service.serviceAccountName" . }}
  annotations:
    eks.amazonaws.com/role-arn: {{ .Values.irsa.roleArn | quote }}
```

At `helm install` time you pass `--set irsa.roleArn=$(terraform output -raw order_service_role_arn)`
and the annotation gets baked into the pod's ServiceAccount.

### 8.6 `sqs.tf` — one queue

```hcl
resource "aws_sqs_queue" "order_events" {
  name                       = "order-events"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600   # 4 days
  receive_wait_time_seconds  = 20       # long polling
}
```

`receive_wait_time_seconds=20` enables **long polling** — consumers
block up to 20s waiting for a message instead of hot-looping. Cheaper
and lower latency.

### 8.7 `helm_releases.tf` — everything else on the cluster

Terraform installs seven Helm charts:

| Release                    | Namespace          | Chart                                          | Why                              |
| -------------------------- | ------------------ | ---------------------------------------------- | -------------------------------- |
| `aws-load-balancer-controller` | `kube-system`  | `aws/aws-load-balancer-controller`             | Provisions ALBs from Ingress     |
| `argocd`                   | `argocd`           | `argo/argo-cd`                                 | GitOps deploy engine             |
| `keda`                     | `keda`             | `kedacore/keda`                                | Event-driven autoscaling         |
| `istio-base`               | `istio-system`     | `istio/base`                                   | Istio CRDs                       |
| `istiod`                   | `istio-system`     | `istio/istiod`                                 | Istio control plane              |
| `istio-ingress` **(disabled)** | `istio-system` | `istio/gateway`                                | See §18 — pod stalls on Ready    |
| `kube-prometheus-stack`    | `monitoring`       | `prometheus-community/kube-prometheus-stack`   | Prometheus + Alertmanager + Grafana |

Every release has `timeout = 900` (15 min) and `atomic = true`. The
`atomic` flag means "if the install fails, roll it back cleanly." We
learned this the hard way — see §18.

---

<a id="9-part-5-istio"></a>

## 9. Part 5 — Istio: automatic mTLS between pods

Scenario 1 authenticated inter-service calls by adding an
`X-Internal-Api-Key` header. Every service had to remember to check
it, rotate it, and keep it out of logs.

Istio replaces this entirely at the **sidecar** layer.

### 9.1 The mental model

Every pod in the mesh gets a second container injected next to your
app: an **Envoy proxy**. Envoy owns port 80 of your pod's iptables
rules — all traffic in and out of the pod is intercepted. When your
Spring app makes an HTTP call to `http://payment-service:8080`, it
never actually leaves your pod's `lo` interface plain-HTTP:

```
                        │
       your Spring app  │ ─── plaintext HTTP to 127.0.0.1:8080
                        │        (loopback, iptables redirect)
              Envoy     │ <── captures traffic, upgrades to mTLS
                        │        using SPIFFE cert issued by istiod
                        │
       [encrypted mTLS to Envoy on the destination pod]
                        │
              Envoy     │ <── decrypts, forwards plaintext to
                        │        127.0.0.1:8080 on that pod
              Spring    │ ── receives plaintext HTTP
```

Application code is **completely unaware**. You keep writing plain
`WebClient` code.

### 9.2 What we deployed

Three tiny objects in `k8s/istio/` and `k8s/namespace.yaml`:

```yaml
# k8s/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: default
  labels:
    istio-injection: enabled          # ← every pod here gets a sidecar
```

```yaml
# k8s/istio/peer-authentication.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata: { name: default, namespace: default }
spec:
  mtls: { mode: STRICT }              # reject any plaintext connection
```

```yaml
# k8s/istio/destination-rules.yaml (three of these, one per service)
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata: { name: order-service-mtls, namespace: default }
spec:
  host: order-service.default.svc.cluster.local
  trafficPolicy:
    tls: { mode: ISTIO_MUTUAL }       # client-side: originate mTLS
```

- `PeerAuthentication` is the **receiving** rule: "in this namespace,
  only accept mTLS."
- `DestinationRule` is the **sending** rule: "when you connect to
  this hostname, encrypt with an Istio-issued cert."

Together: every pod in `default` refuses plain traffic and initiates
mTLS on outbound calls. That's the whole security story — no code,
no headers, no shared secrets, and certs rotate automatically.

### 9.3 What Istio does NOT do here

- **North-south (external) traffic**: we still terminate at the AWS
  ALB (Cognito auth on `order-service` Ingress). The Istio ingress
  gateway is *disabled* right now (§18) because its pod kept
  stalling on Ready.
- **Authorization**: we only turned on authentication. If you want
  "only order-service can call payment-service", add
  `AuthorizationPolicy` next.

---

<a id="10-part-6-argocd"></a>

## 10. Part 6 — GitOps with ArgoCD

### 10.1 What GitOps means

Traditional deploy: `kubectl apply -f deployment.yaml` from a laptop
or a CI job. Git might not match cluster state — if someone
`kubectl edits` a resource, that change lives only on the cluster.

GitOps flips it. **A branch in Git is the desired state; a controller
in the cluster continuously reconciles toward it.**

ArgoCD is that controller. It watches an `Application` resource
that says "this directory in this repo, on this branch, should be
rendered and applied." Every ~3 minutes it renders, diffs, and
either reports drift or auto-syncs.

### 10.2 The Application manifests

```yaml
# argocd/order-service-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: order-service, namespace: argocd }
spec:
  project: default
  source:
    repoURL: YOUR_REPO_URL              # ← replace before applying
    targetRevision: scenario-3-eks      # branch/tag/sha
    path: helm/order-service            # chart location
    helm:
      valueFiles: ["../../helm/values-prod.yaml"]
  destination:
    server: https://kubernetes.default.svc   # this cluster
    namespace: default
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

Fields:

- **`prune: true`** — if you delete a resource from Git, ArgoCD
  deletes it from the cluster.
- **`selfHeal: true`** — if someone `kubectl edits` a resource,
  ArgoCD reverts it back to Git.
- **`CreateNamespace=true`** — auto-create the target namespace if
  it doesn't exist.

Three of these Applications get installed by `setup-cluster.sh`.

### 10.3 The flow

```
developer merges to scenario-3-eks
        │
        ▼
GitHub Actions builds & pushes Docker images
        │
        ▼
GitHub Actions bumps image.tag in helm/values-prod.yaml
        │  (commits back to the branch with [skip ci])
        ▼
ArgoCD detects the Git commit
        │
        ▼
ArgoCD renders `helm template` with values-prod.yaml
        │
        ▼
ArgoCD applies the diff to the cluster
        │
        ▼
Kubernetes rolls out new pods
```

You never `kubectl apply` again.

---

<a id="11-part-7-github-actions"></a>

## 11. Part 7 — CI/CD with GitHub Actions

`.github/workflows/eks-deploy.yml` fires on push to `scenario-3-eks`.
Two jobs.

### 11.1 Job 1: build-and-push

```yaml
- Checkout
- Setup Java 21 Temurin (with Maven cache)
- Configure AWS credentials (secrets)
- Login to Amazon ECR
- Compute short SHA
- For each service:
    - mvn -pl <svc> -am -DskipTests package
    - docker build -t $ECR/ms-learning/<svc>:<full-sha>
                   -t $ECR/ms-learning/<svc>:<short-sha> .
    - docker push --all-tags
```

**Why two tags?** The spec asked for full-SHA in the Docker tag and
short SHA in Helm values. Different tags on the same image are
free in ECR (just a second ref to the same layers) so we push both.

**`concurrency: eks-deploy, cancel-in-progress: true`** ensures that
if two commits land back-to-back, the first workflow is cancelled and
only the second one runs to completion. No image-tag races.

### 11.2 Job 2: update-helm-values

```yaml
- Checkout with contents:write permission
- Install yq
- yq -i ".image.tag = strenv(SHORT_SHA)" helm/values-prod.yaml
- git commit -m "chore: update image tags to $SHORT_SHA [skip ci]"
- git push origin HEAD:${GITHUB_REF_NAME}
```

The `[skip ci]` tag prevents the push from re-triggering the same
workflow (Actions ignores commits with that marker in the subject).

After this job, `values-prod.yaml` on Git points at the new image
tag. ArgoCD picks it up on the next sync.

---

<a id="12-part-8-keda"></a>

## 12. Part 8 — KEDA autoscaling from SQS depth

The HPA that ships with Kubernetes scales on CPU/memory. That's
fine for CPU-bound workloads but useless for a queue-worker that
sits idle 90% of the time and needs to burst when work arrives.

**KEDA** (Kubernetes Event-Driven Autoscaler) fills the gap.
It watches an *external* metric — SQS depth, Kafka lag, Redis list
length, a cron schedule, custom Prometheus query — and drives a
regular HPA under the hood. Special power: **it can scale to zero.**
When the queue is empty, the pod count drops to 0.

### 12.1 The two custom resources

```yaml
# helm/payment-service/templates/scaledobject.yaml (rendered)
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: payment-service-scaler, namespace: default }
spec:
  scaleTargetRef:  { name: payment-service }   # the Deployment to scale
  minReplicaCount: 0                           # scale-to-zero
  maxReplicaCount: 5
  cooldownPeriod:  30                          # wait 30s after last event before scaling down
  triggers:
    - type: aws-sqs-queue
      authenticationRef: { name: payment-service-aws }
      metadata:
        queueURL:    "https://sqs.us-east-1.amazonaws.com/…/order-events"
        queueLength: "5"                       # target: 5 msgs per replica
        awsRegion:   "us-east-1"
        identityOwner: pod                     # use the pod's IRSA
```

```yaml
# helm/payment-service/templates/triggerauthentication.yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata: { name: payment-service-aws, namespace: default }
spec:
  podIdentity: { provider: aws }              # ← borrows the pod's IRSA role
```

`identityOwner: pod` + `podIdentity.provider: aws` means KEDA does
NOT hold static AWS credentials. It reads the SQS queue depth using
the same IRSA role that payment-service pods already use.

### 12.2 Who feeds the queue

`order-service` publishes an `OrderCreatedEvent` to the queue *after*
the DB transaction commits:

```java
// OrderCommandHandler.java (simplified)
transactionTemplate.executeWithoutResult(tx -> {
    appendEvent(...); orderRepository.save(...);       // Postgres
});
orderEventPublisher.publishOrderCreated(event);        // SQS
```

Publish *after* commit so a rolled-back transaction can't emit a
phantom event. The publisher itself is fire-and-forget async:

```java
// OrderEventPublisher.java (simplified)
sqsClient.sendMessage(SendMessageRequest.builder()
        .queueUrl(queueUrl).messageBody(json).build())
   .whenComplete((resp, err) -> { /* log */ });
```

If the queue URL is blank (local dev), the publisher no-ops silently.

### 12.3 What actually happens at runtime

1. User posts an order → `order-service` saves and publishes.
2. KEDA polls SQS depth every 30s. Sees 1 message.
3. `1 msg / 5 msgs-per-replica = 0.2 → ceil = 1`. Scale from 0 → 1.
4. A `payment-service` pod boots (~15s: JVM startup + probes).
5. The pod dequeues and processes the message.
6. Queue empties. After `cooldownPeriod: 30s`, scale back to 0.

**Note.** We haven't wired a payment-service *consumer* yet — the
current codebase still calls payment-service via HTTP from
order-service. The KEDA scaler is ready and correct; adding the
consumer is a small follow-up.

---

<a id="13-part-9-observability"></a>

## 13. Part 9 — Observability

Three pillars: **metrics** (Prometheus), **logs** (FluentBit →
CloudWatch), **traces** (OpenTelemetry Java agent — no collector
in-cluster yet, but the agent runs and MDC is populated).

### 13.1 Metrics: kube-prometheus-stack

Helm-installed by Terraform. Bundles four things:

| Component            | Role                                                                      |
| -------------------- | ------------------------------------------------------------------------- |
| **Prometheus**       | Scrapes metric endpoints, stores time-series in-cluster                   |
| **Alertmanager**     | Delivers alerts (Slack, PagerDuty, ...)                                   |
| **Grafana**          | Web UI, dashboards, ad-hoc queries                                        |
| **kube-state-metrics** + node-exporter | Kubernetes and node-level metrics themselves                    |

We turned two important knobs:

```hcl
set { name = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues",     value = "false" }
set { name = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues", value = "false" }
```

By default, Prometheus only scrapes ServiceMonitor/PodMonitor CRs
that are labelled with the release name (a Helm convention to avoid
one Prometheus in your cluster grabbing another team's targets).
For a single-tenant learning cluster that's annoying — we turn it
off so any monitor in any namespace gets scraped.

### 13.2 How our apps get scraped

Two ways:

1. **Pod annotations.** Our Deployment template adds:
   ```yaml
   annotations:
     prometheus.io/scrape: "true"
     prometheus.io/port:   "8080"
     prometheus.io/path:   "/actuator/prometheus"
   ```
   This is the legacy "Prometheus with kubernetes_sd" method — some
   configurations pick it up automatically. It's also self-documenting.
2. **Actuator + Micrometer.** Every service has:
   - `spring-boot-starter-actuator`
   - `micrometer-registry-prometheus`
   - `management.endpoints.web.exposure.include: health,info,prometheus`
   That combo exposes `/actuator/prometheus` in the OpenMetrics
   format with JVM, HTTP, JDBC, and business metrics out of the box.

### 13.3 Logs: FluentBit DaemonSet → CloudWatch Logs

```
┌────────────────────────── Node ──────────────────────────┐
│  /var/log/containers/*.log   ← kubelet writes here       │
│           ▲                                              │
│           │ tail                                         │
│  ┌─────────────────┐                                     │
│  │  FluentBit pod  │ (one per node, DaemonSet)           │
│  │  ┌───────────┐  │                                     │
│  │  │ input:tail│  │                                     │
│  │  │ filter:k8s│  ← enriches with pod/namespace/labels  │
│  │  │ filter:json  ← parses our JSON log lines           │
│  │  │ output:CWL│──┼────────► CloudWatch Logs            │
│  │  └───────────┘  │   /eks/ms-learning                  │
│  └─────────────────┘   stream = pod/<pod-name>           │
└──────────────────────────────────────────────────────────┘
```

The four YAMLs in `k8s/fluentbit/`:

- **`namespace.yaml`** — creates `amazon-cloudwatch`.
- **`serviceaccount.yaml`** — SA `fluentbit` with a placeholder
  `FLUENTBIT_ROLE_ARN` annotation. `setup-cluster.sh` substitutes
  the real ARN from `terraform output -raw fluentbit_role_arn`
  before applying.
- **`configmap.yaml`** — the FluentBit config: `[INPUT] tail`,
  `[FILTER] kubernetes` (enriches with pod/namespace metadata),
  `[FILTER] parser Parser=json` (parses our JSON log lines),
  `[OUTPUT] cloudwatch_logs`.
- **`daemonset.yaml`** — one FluentBit pod per node, mounts host
  `/var/log`, `hostNetwork: true`, tolerates every taint so it lands
  everywhere.

Result: every log line from every pod, enriched with Kubernetes
metadata, structured as JSON, in CloudWatch under
`/eks/ms-learning`.

### 13.4 Traces: the OpenTelemetry Java agent

The agent is downloaded per pod at boot (§7.3). It auto-instruments
Spring MVC, WebClient, JDBC, Hibernate, and more — without a single
line of app code. Trace and span IDs land in MDC so log lines carry
them, and if you set `OTEL_EXPORTER_OTLP_ENDPOINT` (we do in
`values-prod.yaml`) the agent exports spans to a collector.

There is no collector *in-cluster* yet on scenario-3. `values-prod.yaml`
points at
`http://otel-collector.observability.svc.cluster.local:4318` which
doesn't exist — the agent simply drops spans until you install a
collector. Metrics and logs work today; distributed tracing gets a
collector as a follow-up.

---

<a id="14-part-10-setup-script"></a>

## 14. Part 10 — The `setup-cluster.sh` bootstrap

Terraform handles anything with a clean provider (AWS resources +
Helm releases). But three things are simpler as `kubectl apply`:

1. Labelling the pre-existing `default` namespace with
   `istio-injection=enabled`.
2. Applying the Istio `PeerAuthentication` + `DestinationRules` CRs.
3. Applying the ArgoCD `Application` manifests.
4. Applying the FluentBit manifests (with the IRSA ARN interpolated
   at apply time from `terraform output`).

`scripts/setup-cluster.sh` does exactly that, in that order,
idempotently (every step is `kubectl apply` or `helm upgrade
--install`). Run it once after `terraform apply` and re-run whenever
you change any file under `k8s/` or `argocd/`.

---

<a id="15-end-to-end"></a>

## 15. End-to-end request flow

A user creates an order. Trace the request:

1. **Browser** → HTTPS to `https://orders.example.com/api/orders`.
2. **Route 53** → the ALB's public DNS name.
3. **ALB** (provisioned by AWS Load Balancer Controller because of
   the order-service Helm chart's `Ingress` object with class `alb`).
4. **ALB Cognito authenticator** — checks the JWT / redirects to
   the Cognito hosted UI. On success, forwards the request.
5. **ALB target group** → the `order-service` ClusterIP Service via
   the `target-type: ip` and the pod's IP.
6. Traffic hits the **order-service pod on port 8080**.
   Actually — iptables rules redirect it to the **Envoy sidecar** in
   the same pod. Envoy has no incoming TLS to peel off (this is
   external traffic), so it hands the plaintext HTTP to the app on
   `localhost:8080`.
7. **`OrderCommandHandler.handle()`** runs.
   - a. Calls `userServiceClient.findById()` — an HTTP request to
     `http://user-service:8080`. Kubernetes DNS resolves that name
     to the user-service ClusterIP. The **Envoy sidecar** in
     order-service intercepts the outbound connection, upgrades to
     **mTLS** using its SPIFFE certificate, and forwards to the
     Envoy sidecar in user-service, which decrypts and hands
     plaintext to the user-service app on `localhost:8080`.
   - b. Writes `OrderCreatedEvent` + `PENDING` Order in a Postgres
     transaction.
   - c. After commit, publishes `OrderCreatedEvent` to the SQS
     `order-events` queue via `SqsAsyncClient`. The pod uses its
     IRSA role — no static AWS keys.
   - d. Calls `paymentServiceClient.processPayment()` (same mTLS
     dance as (a)).
   - e. Finalises the order in a second Postgres transaction.
8. Meanwhile: **KEDA** sees the SQS depth tick above zero and
   scales the `payment-service` deployment from 0 → 1 (§12). If a
   future consumer processes the message, KEDA scales back to 0
   after 30s of idle.
9. Every log line emitted during this journey carries the same
   `trace_id` (populated by the OpenTelemetry agent into MDC).
   **FluentBit** on each node tails `/var/log/containers/*.log`,
   enriches with pod metadata, and ships to CloudWatch
   `/eks/ms-learning`. Grep by `trace_id` to see the full flow.
10. **Prometheus** in `monitoring` scrapes `/actuator/prometheus`
    on each pod every ~15s. **Grafana** renders JVM + HTTP + JDBC
    dashboards from that data.

---

<a id="16-cheat-sheet"></a>

## 16. Command cheat sheet

### Cluster access

```bash
aws eks update-kubeconfig --name ms-learning-eks --region us-east-1
kubectl config current-context               # confirm you're on the right cluster
kubectl get nodes                            # workers exist
kubectl get pods -A                          # everything running
```

### Poking at a pod

```bash
kubectl -n default get pods -l app.kubernetes.io/name=order-service
kubectl -n default logs -f <pod-name>
kubectl -n default logs -f <pod-name> -c istio-proxy    # sidecar logs
kubectl -n default exec -it <pod-name> -- sh            # shell inside
kubectl -n default describe pod <pod-name>              # events, status, spec
kubectl -n default port-forward <pod-name> 8080:8080    # local access
```

### Helm

```bash
helm ls -A                                              # every release
helm ls -n monitoring
helm history kube-prometheus-stack -n monitoring        # revision list
helm rollback kube-prometheus-stack 1 -n monitoring
helm template payment-service ./helm/payment-service \
    -f ./helm/values-prod.yaml --set image.repository=payment-service
    # renders YAML locally without applying — great for debugging
```

### Terraform

```bash
cd infrastructure/scenario-3
terraform init
terraform plan
terraform apply -parallelism=2                          # slower but stabler
terraform output -raw order_events_queue_url
terraform state list | grep helm_release
```

### Debugging KEDA

```bash
kubectl -n keda get scaledobjects.keda.sh -A
kubectl -n keda logs deploy/keda-operator
kubectl -n default describe scaledobject payment-service-scaler
```

### Debugging Istio

```bash
kubectl -n istio-system get pods
kubectl -n istio-system logs deploy/istiod
kubectl exec <pod> -c istio-proxy -- pilot-agent request GET stats \
    | grep upstream_rq_total
istioctl proxy-status                       # if you install istioctl
```

---

<a id="17-side-by-side"></a>

## 17. Scenario 1 vs Scenario 3 — side-by-side

| Concern            | Scenario 1 file(s)                                          | Scenario 3 file(s)                                                              |
| ------------------ | ----------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Compute            | `infrastructure/scenario-1/ec2.tf`                          | `infrastructure/scenario-3/eks.tf` (managed node group)                         |
| Ingress            | `alb.tf` (raw ALB + listener) + `api-gateway/`              | `helm/order-service/templates/ingress.yaml` (Ingress → ALB via controller)      |
| Service discovery  | `eureka-server/` running as a Spring Boot app               | (nothing) — Kubernetes DNS                                                      |
| Config             | `config-server/config-repo/*.yml`                           | `helm/values-{local,prod}.yaml` → env vars                                      |
| Inter-service auth | `X-Internal-Api-Key` header check                           | `k8s/istio/peer-authentication.yaml` (STRICT mTLS)                              |
| Autoscaling        | EC2 Auto Scaling Group on CPU                               | `helm/*/templates/hpa.yaml` + `scaledobject.yaml` (KEDA)                        |
| Deploy pipeline    | Manual or `scp` to EC2                                      | `.github/workflows/eks-deploy.yml` + `argocd/*.yaml`                            |
| Metrics collection | CloudWatch Agent on each EC2                                | `helm_release.kube_prometheus_stack` in `monitoring` ns                         |
| Log collection     | CloudWatch Agent on each EC2                                | `k8s/fluentbit/*` DaemonSet                                                     |
| Secrets            | (per-EC2 env vars or SSM Parameter Store)                   | ServiceAccount + IRSA + AWS API access; app secrets via K8s Secret (not shown)  |
| IAM identity       | One instance profile per EC2                                | One IRSA role per Deployment                                                    |

The right column has more moving parts, but each one is single-purpose
and reusable. On EC2 you owned the whole stack per host; on EKS the
cluster is the stack, and every app is just a Deployment.

---

<a id="18-troubleshooting"></a>

## 18. Troubleshooting: the pitfalls we actually hit

Three problems came up during scenario-3 bring-up. Each one taught
us something.

### 18.1 `aws-ebs-csi-driver` addon hangs in `CREATING` for 20 minutes

**Symptom**
```
module.eks.aws_eks_addon.this["aws-ebs-csi-driver"]: Still creating... [20m00s elapsed]
Error: waiting for EKS Add-On (…) create: timeout while waiting for state to become 'ACTIVE'
```

**Cause.** The addon's controller pods (`ebs-csi-controller-sa` in
`kube-system`) had no IAM permission to call `ec2:CreateVolume` etc.
Without a working control plane, the addon's health check never
flips to `ACTIVE`.

**Fix.** Give the addon its own IRSA role and wire the ARN into the
addon config:

```hcl
module "ebs_csi_irsa" { … attach_ebs_csi_policy = true … }

aws-ebs-csi-driver = {
  most_recent              = true
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
}
```

**Recovery.** The stuck addon must be deleted in AWS before
re-apply:

```bash
aws eks delete-addon --cluster-name ms-learning-eks \
    --addon-name aws-ebs-csi-driver --region us-east-1
aws eks wait addon-deleted --cluster-name ms-learning-eks \
    --addon-name aws-ebs-csi-driver --region us-east-1
terraform apply
```

**Lesson.** Every EKS addon that talks to AWS APIs needs its own
IRSA role. Don't rely on node instance profiles for this.

### 18.2 Helm releases fail with "connection reset by peer"

**Symptom**
```
Error: 5 errors occurred:
  * Post "https://….eks.amazonaws.com/apis/rbac.authorization.k8s.io/v1/clusterrolebindings…":
      read tcp 192.168.1.2:61122->100.59.99.22:443: read: connection reset by peer
```

**Cause.** The Terraform Helm provider talks to the EKS API from
your laptop. Parallel resource creations (default `-parallelism=10`)
made concurrent connections that occasionally got RST'd by the
control-plane load balancer. Some Helm releases were left in
`failed` state with revision 1.

**Fix (permanent).** Every `helm_release` now has:
```hcl
timeout = 900         # 15 min instead of default 5
atomic  = true        # roll back cleanly on failure
```

**Fix (recovery).** For any release already in `failed`:
```bash
helm uninstall <release> -n <ns>
terraform state rm helm_release.<name>
terraform apply -parallelism=2   # slow down to reduce API load
```

**Lesson.** Managing lots of Helm releases from Terraform is
possible but noisy. Isolating platform installs into their own
Terraform stack (or moving them to ArgoCD `App-of-Apps`) is a real
option for larger clusters.

### 18.3 `istio-ingress` gateway pod never reaches `Ready`

**Symptom.** `helm_release.istio_ingress` hits its 15-minute timeout;
gateway pod is stuck at `0/1 Ready` even though the pod is running.

**Cause (suspected).** istiod webhook stall or a readiness probe
race on this particular cluster.

**Fix (interim).** Commented out `helm_release.istio_ingress` in
Terraform and its counterpart in `setup-cluster.sh`. **External
traffic still works** because it enters through the AWS Load
Balancer Controller (ALB Ingress on `order-service`), not through
the Istio ingress gateway. mTLS between pods still works because
that's handled by istiod + the sidecars + PeerAuthentication,
none of which depend on the ingress gateway.

**Lesson.** Istio has three big pieces — control plane (istiod),
sidecars (data plane), and gateway (ingress). You can run any
subset. Don't let a stuck gateway block your cluster if you're
not routing external traffic through it.

---

## Appendix — Run book to bring the cluster up from scratch

```bash
# 1. Bootstrap the Terraform state bucket (once ever)
cd infrastructure/bootstrap
terraform init && terraform apply

# 2. Bring up the platform
cd ../scenario-3
cp terraform.tfvars.example terraform.tfvars    # tweak if needed
terraform init
terraform apply -parallelism=2

# 3. Bootstrap the in-cluster manifests (Istio policies, FluentBit,
#    ArgoCD Applications). Reads Terraform outputs.
cd ../..
./scripts/setup-cluster.sh

# 4. Sanity checks
kubectl get nodes
kubectl get pods -A
helm ls -A
kubectl -n argocd get applications
```

Push to `scenario-3-eks` after that and ArgoCD does the rest.

---

*Any of these sections that don't click, ask and I'll expand.*
