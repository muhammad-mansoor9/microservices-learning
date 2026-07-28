# Scenario 3 — from EC2 to EKS

> A first-time-Kubernetes walkthrough for someone who's already built the
> same three services (order / payment / user) once on plain AWS. Read
> top-to-bottom the first time — every section builds on the last.

---

## Table of contents

1. [Where we're coming from](#1-where-were-coming-from)
2. [The idea in one paragraph](#2-the-idea-in-one-paragraph)
3. [Kubernetes vocabulary, as it becomes useful](#3-kubernetes-vocabulary-as-it-becomes-useful)
4. [Rewriting the apps for Kubernetes](#4-rewriting-the-apps-for-kubernetes)
5. [Packaging: Docker images](#5-packaging-docker-images)
6. [Helm charts: the shape of a deployment](#6-helm-charts-the-shape-of-a-deployment)
7. [The cluster itself: Terraform + EKS](#7-the-cluster-itself-terraform--eks)
8. [The platform tools, all installed by Terraform](#8-the-platform-tools-all-installed-by-terraform)
9. [Making pods talk to each other securely (Istio)](#9-making-pods-talk-to-each-other-securely-istio)
10. [GitOps: telling the cluster what to run (ArgoCD)](#10-gitops-telling-the-cluster-what-to-run-argocd)
11. [The CI half: GitHub Actions](#11-the-ci-half-github-actions)
12. [Event-driven autoscaling (KEDA + SQS)](#12-event-driven-autoscaling-keda--sqs)
13. [Observability: metrics, logs, traces](#13-observability-metrics-logs-traces)
14. [The three battles we fought](#14-the-three-battles-we-fought)
15. [Where we're standing right now](#15-where-were-standing-right-now)
16. [Verifying and testing](#16-verifying-and-testing)
17. [Command cheat sheet](#17-command-cheat-sheet)
18. [Scenario 1 vs Scenario 3, side by side](#18-scenario-1-vs-scenario-3-side-by-side)

---

<a id="1-where-were-coming-from"></a>

## 1. Where we're coming from

On the `main` branch (Scenario 1) each of your three services runs on
its own EC2 instance. There's a lot of Spring Cloud glue holding it
together — a **Eureka server** so services find each other, a **Config
Server** so they read shared config from Git, and an **API Gateway** to
route external traffic. Between services there's an `X-Internal-Api-Key`
header check to say "I'm one of us." Postgres is on RDS. DynamoDB
tables live in AWS. It works, and every piece has a name you already
know.

Now we do it again on Kubernetes. Same three services, same business
logic, but the platform underneath is completely different — and once
you learn it, so much of that Spring Cloud glue disappears that the
services become boring in a good way.

<a id="2-the-idea-in-one-paragraph"></a>

## 2. The idea in one paragraph

Kubernetes runs a **cluster** of worker VMs. You hand it container
images and small YAML descriptions ("I want two of these, listening on
port 8080, restart them if they crash") and it schedules the work.
That's it. Everything you're about to read — service discovery,
config, load-balancing, service-to-service auth, autoscaling,
metrics — is a knob on that primitive. In Scenario 1 you rented an
EC2 per service; in Scenario 3 you rent one cluster and pack pods on it.

<a id="3-kubernetes-vocabulary-as-it-becomes-useful"></a>

## 3. Kubernetes vocabulary, as it becomes useful

You don't need all of these on day one. But every one of them appears
somewhere in this repo, so let's define them together and refer back.

- **Cluster** — one control plane + a pool of worker Nodes. AWS
  manages the control plane; we own the Nodes.
- **Node** — a VM (EC2 in our case) that runs Pods.
- **Pod** — one or more containers that share a network namespace.
  For us, one Pod == one Java process. You almost never launch a Pod
  directly — you tell a **Deployment** you want N of them and it
  makes it so.
- **Deployment** — a controller that keeps N identical Pods alive
  (rolling them, restarting them, re-creating them if a Node dies).
- **Service** — a stable virtual IP and DNS name in front of the
  Pods that match a label selector. `http://payment-service:8080`
  works forever, even as the actual Pods behind it come and go.
- **Ingress** — HTTP routing rules for traffic entering the cluster
  from outside. We install a controller (**AWS Load Balancer
  Controller**) that watches Ingress objects and provisions ALBs
  for them.
- **Namespace** — a logical partition. Our apps live in `default`;
  each platform tool has its own (`istio-system`, `argocd`, `keda`,
  `monitoring`, `amazon-cloudwatch`, `kube-system`).
- **ServiceAccount (SA)** — the identity a Pod runs as. In EKS, if
  you annotate an SA with an IAM role ARN, the Pod magically gets
  AWS API credentials. This is called **IRSA** — IAM Roles for
  Service Accounts — and it's how we skip static AWS keys.
- **DaemonSet** — one Pod per Node. Perfect for host-level agents
  like our log shipper.
- **HPA (HorizontalPodAutoscaler)** — scales a Deployment based on
  CPU or memory. We layer **KEDA** on top for external metrics
  (SQS queue depth).
- **Helm chart** — a folder of templated YAML plus a `values.yaml`.
  It's the package manager for Kubernetes.
- **CRD (CustomResourceDefinition)** — how tools extend the
  Kubernetes API. Every one of Istio, ArgoCD, and KEDA adds new
  object types (`ScaledObject`, `Application`, `PeerAuthentication`)
  that behave like built-in ones once their CRD is installed.

One idea to internalize before anything else: **Kubernetes objects
are desired state, not commands.** You never `kubectl start pod`. You
declare that a Deployment wants three replicas. Controllers loop
forever reconciling reality toward that. A Node dies? A controller
notices and creates replacement Pods elsewhere. This is why the whole
system feels "self-healing" — because nothing is imperative.

<a id="4-rewriting-the-apps-for-kubernetes"></a>

## 4. Rewriting the apps for Kubernetes

Kubernetes expects processes that read config from environment
variables and expose two HTTP health endpoints. Everything else the
platform does for you. So we simplified the apps.

**Before**, each service had four YAML files
(`application.yml` + `-local.yml` + `-prod.yml` + `-docker.yml`) and
picked one via `SPRING_PROFILES_ACTIVE`.

**Now** each service has one `application.yml` driven by env vars:

```yaml
spring:
  application: { name: order-service }
  datasource:
    url:      ${DB_URL:jdbc:postgresql://localhost:5432/order_db}
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
services:
  user-service-url:    ${USER_SERVICE_URL:http://user-service:8080}
  payment-service-url: ${PAYMENT_SERVICE_URL:http://payment-service:8080}
management:
  endpoints: { web: { exposure: { include: health,info,prometheus } } }
  endpoint:
    health:
      probes: { enabled: true }         # /actuator/health/liveness + /readiness
      group:
        readiness: { include: readinessState,db }
        liveness:  { include: livenessState }
```

The `${VAR:default}` pattern is the trick — defaults keep the file
runnable on your laptop; in Kubernetes we override every value from a
Helm-rendered `env:` block.

Two probes matter to Kubernetes:

- **`/actuator/health/liveness`** — if this fails, kubelet **restarts**
  the pod (the JVM is toast).
- **`/actuator/health/readiness`** — if this fails, kubelet **removes**
  the pod from the Service endpoints but leaves it alive (a DB blip
  should not kill the JVM).

Grouping `db` under readiness only says "if the database is down,
stop routing me traffic, but I'll recover once it comes back." That
distinction is why Kubernetes can gracefully drain unhealthy pods
without hard-restarting them.

We also removed three Spring Cloud dependencies:

- `spring-cloud-starter-netflix-eureka-client` — Kubernetes DNS
  replaces the service registry.
- `spring-cloud-starter-config` — Helm and env vars replace remote
  config.
- `spring-boot-starter-oauth2-resource-server` — external auth moves
  to the ALB Ingress (Cognito), east-west auth moves to Istio mTLS.

And one thing was **added**: a `logback-spring.xml` per service that
reads two extra MDC keys:

```xml
<property name="LOG_PATTERN"
    value="%d{...} %5p [${spring.application.name:-},%X{trace_id:-},%X{span_id:-}] ..."/>
```

We don't populate `trace_id` and `span_id` ourselves. The
OpenTelemetry Java agent, attached at container startup via
`JAVA_TOOL_OPTIONS=-javaagent:...`, propagates W3C `traceparent`
headers between services *and* writes the current trace/span id into
MDC. One request touching all three services produces log lines
across three pods that share the same `trace_id` — you can grep for
it in CloudWatch and see the full journey.

<a id="5-packaging-docker-images"></a>

## 5. Packaging: Docker images

Every service has a two-stage `Dockerfile` at its root.

```dockerfile
FROM maven:3.9-eclipse-temurin-21-alpine AS builder
WORKDIR /build
COPY pom.xml .
RUN mvn install -N -q
COPY order-service/pom.xml order-service/pom.xml
COPY payment-service/pom.xml payment-service/pom.xml
COPY user-service/pom.xml user-service/pom.xml
RUN mvn -pl order-service dependency:go-offline -q
COPY order-service/src order-service/src
RUN mvn -pl order-service package -DskipTests -q

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /build/order-service/target/order-service-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","app.jar"]
```

Stage 1 has the full JDK and Maven; stage 2 keeps only the JRE and
the JAR. Result: an ~80 MB image that starts in a couple of seconds.
Every service listens on 8080 — one port to remember. On your laptop
`docker-compose` maps them to distinct host ports (8081/8082/8083),
but inside the cluster they're all `<name>-service:8080`.

<a id="6-helm-charts-the-shape-of-a-deployment"></a>

## 6. Helm charts: the shape of a deployment

Instead of hand-writing one `Deployment` YAML per service (and
duplicating 95% of it), we wrote one **Helm chart** per service.

```
helm/order-service/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl         reusable name/label helpers
    ├── serviceaccount.yaml  ServiceAccount with IRSA annotation
    ├── deployment.yaml      the Deployment (with OTel init container)
    ├── service.yaml         ClusterIP on port 8080
    ├── hpa.yaml             HPA (CPU-based, optional)
    └── ingress.yaml         ALB + Cognito (order-service only)
```

The `values.yaml` is the knob panel:

```yaml
image:        { repository: "", tag: latest }
replicaCount: 1
resources:
  requests: { cpu: 256m, memory: 512Mi }
  limits:   { cpu: 500m, memory: 1Gi }
env: {}                        # extra env vars merged in
irsa: { roleArn: "" }
service: { port: 8080 }
autoscaling:
  enabled: false               # CPU-based HPA
  keda:
    enabled: false             # SQS-based (payment-service only)
otel:
  agentVersion: "2.10.0"
```

The deployment template does two clever things:

1. **An `initContainer` downloads the OpenTelemetry Java agent** into
   a scratch `emptyDir` volume that's shared with the main container.
   The main container then boots the JVM with
   `-javaagent:/agents/opentelemetry-agent.jar`. Zero application code.
2. **Probe endpoints are hard-wired** to `/actuator/health/liveness`
   and `/readiness` with sane initial delays.

We keep two environment-flavored value files at `helm/`:

- `helm/values-local.yaml` — small resources, no autoscaling, no
  OTLP export.
- `helm/values-prod.yaml` — 2 replicas, autoscaling on, OTLP
  destination set, KEDA on for payment-service, real SQS URL.

You apply a chart like this:

```bash
helm upgrade --install order-service ./helm/order-service \
  -f helm/values-prod.yaml \
  --set image.repository=<ecr>/ms-learning/order-service \
  --set image.tag=<git-sha> \
  --set irsa.roleArn=<order-role-arn>
```

But you won't ever type that in Scenario 3 — ArgoCD will (see §10).

<a id="7-the-cluster-itself-terraform--eks"></a>

## 7. The cluster itself: Terraform + EKS

Everything AWS-side and everything that runs on the cluster lives in
`infrastructure/scenario-3/`. Twelve `.tf` files. **All of it is
Terraform-managed** — there's no post-apply "run this script" step
anymore. Let's walk through it in the order the pieces come alive.

### 7.1 A private VPC with the right subnet tags

`vpc.tf` uses the community VPC module: `10.0.0.0/16`, two AZs, two
public subnets, two private subnets, one NAT gateway. The magic is
the subnet tags:

```hcl
public_subnet_tags = {
  "kubernetes.io/role/elb"                    = "1"        # ALBs go here
  "kubernetes.io/cluster/${var.cluster_name}" = "shared"
}
private_subnet_tags = {
  "kubernetes.io/role/internal-elb"           = "1"
  "kubernetes.io/cluster/${var.cluster_name}" = "shared"
}
```

The AWS Load Balancer Controller reads these tags to decide where to
put ALBs when you create an `Ingress`. Without them it has no idea
which subnets are internet-facing.

### 7.2 The EKS cluster and node group

`eks.tf` calls the community EKS module (`~> 20.0`):

```hcl
module "eks" {
  cluster_name    = "ms-learning-eks"
  cluster_version = "1.30"
  cluster_endpoint_public_access           = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns             = { most_recent = true }
    kube-proxy          = { most_recent = true }
    vpc-cni             = { most_recent = true }
    aws-ebs-csi-driver  = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    default = { instance_types = ["t3.medium"], min_size = 1, max_size = 3, desired_size = 2 }
  }
}
```

Three things worth remembering:

- **`enable_irsa = true`** provisions the OIDC provider that turns
  ServiceAccount annotations into IAM permissions.
- **`enable_cluster_creator_admin_permissions = true`** uses EKS's
  newer *access entries* mechanism to give the caller cluster-admin.
  No more editing the `aws-auth` ConfigMap by hand.
- **`aws-ebs-csi-driver` needs its own IRSA role**. If you skip
  `service_account_role_arn`, the driver's controller pods can't
  call `ec2:CreateVolume`, the addon never becomes healthy, and
  `terraform apply` times out at 20 minutes. We hit this once — see
  §14 for the war story.

### 7.3 ECR, DynamoDB, and SQS — the AWS side

Three small files:

- `ecr.tf` — one repository per service, `scan_on_push = true`,
  `force_delete = true` (so `terraform destroy` doesn't refuse when
  images are present).
- `dynamodb.tf` — one table named `users`, hash key `userId`,
  PAY_PER_REQUEST billing. user-service reads and writes here.
- `sqs.tf` — one queue named `order-events` with long-polling
  (`receive_wait_time_seconds = 20`) and a four-day retention. This
  is what order-service publishes to and what KEDA watches.

### 7.4 IRSA roles: six of them

`irsa.tf` builds six IAM roles, all from the same community
sub-module (`iam-role-for-service-accounts-eks`). Each role's trust
policy scopes to exactly one Kubernetes ServiceAccount:

| Role                    | Kubernetes SA                                 | Permissions                                            |
| ----------------------- | --------------------------------------------- | ------------------------------------------------------ |
| `…-aws-lb-controller`   | `kube-system:aws-load-balancer-controller`    | Built-in ALB controller policy                         |
| `…-ebs-csi-driver`      | `kube-system:ebs-csi-controller-sa`           | Built-in `AmazonEBSCSIDriverPolicy`                    |
| `…-order-service`       | `default:order-service`                       | SQS send/receive on order-events + SSM read            |
| `…-payment-service`     | `default:payment-service`                     | SQS receive/delete on order-events                     |
| `…-user-service`        | `default:user-service`                        | DynamoDB PutItem/GetItem/Query on `users`              |
| `…-fluentbit`           | `amazon-cloudwatch:fluentbit`                 | CloudWatch Logs write                                  |

The chain when a pod calls AWS:

```
Pod -> uses ServiceAccount (annotated with role ARN)
     -> projected volume mounts a Web Identity Token
     -> AWS SDK exchanges it via STS AssumeRoleWithWebIdentity
     -> gets short-lived credentials
     -> makes the actual API call
```

No static keys anywhere.

<a id="8-the-platform-tools-all-installed-by-terraform"></a>

## 8. The platform tools, all installed by Terraform

This is where Scenario 3 gets really different from Scenario 1. On
`main` your infrastructure Terraform ended at "here are some EC2
instances and an RDS." On scenario-3, Terraform *also* installs every
platform tool that runs inside the cluster, using the Helm provider.
Eight Helm releases and eleven Kubernetes objects come out of it.

`helm_releases.tf`:

| Release                    | Namespace          | What it does                                                    |
| -------------------------- | ------------------ | ---------------------------------------------------------------- |
| `aws-load-balancer-controller` | `kube-system`  | Provisions AWS ALBs when you create an Ingress                   |
| `argocd`                   | `argocd`           | GitOps engine (see §10)                                         |
| `keda`                     | `keda`             | Event-driven autoscaling operator (see §12)                     |
| `istio-base`               | `istio-system`     | Installs the Istio CRDs                                          |
| `istiod`                   | `istio-system`     | Istio control plane (issues mTLS certs, sidecar injection)       |
| `kube-prometheus-stack`    | `monitoring`       | Prometheus + Alertmanager + Grafana + kube-state-metrics         |
| `postgres`                 | `default`          | Bitnami Postgres (order_db + payment_db, EBS-backed volume)      |

`fluentbit.tf`:

| Release      | Namespace           | What it does                                             |
| ------------ | ------------------- | -------------------------------------------------------- |
| `fluent-bit` | `amazon-cloudwatch` | DaemonSet shipping every container's stdout to CloudWatch |

Each `helm_release` has `timeout = 900` and `atomic = true` — we
learned the hard way that flaky EKS API connections can leave releases
in `failed` state (§14). `atomic = true` rolls back cleanly on failure
so re-`apply`ing is safe.

A few of these deserve a longer look.

### 8.1 Postgres, in-cluster

Instead of paying for RDS on a learning cluster, we run Postgres as a
Helm release inside `default`:

```hcl
resource "helm_release" "postgres" {
  name       = "postgres"
  namespace  = "default"
  chart      = "postgresql"
  repository = "https://charts.bitnami.com/bitnami"

  values = [yamlencode({
    fullnameOverride = "postgres"          # DNS becomes just `postgres.default...`
    auth = {
      postgresPassword = var.postgres_admin_password
      database         = "postgres"
    }
    primary = {
      # Postgres speaks a binary wire protocol; the Envoy sidecar can garble it.
      podAnnotations = { "sidecar.istio.io/inject" = "false" }
      initdb = {
        scripts = {
          "00-init-databases.sql" = "CREATE DATABASE order_db;\nCREATE DATABASE payment_db;\n"
        }
      }
      persistence = { enabled = true, size = "8Gi" }
    }
  })]
}
```

Three things happen automatically because we wired the platform right
earlier:

1. The 8 Gi `PersistentVolumeClaim` provisions an EBS volume through
   the CSI driver we fixed in §7.2.
2. The pod is opted out of the Istio mesh (`sidecar.istio.io/inject:
   false`) so Envoy doesn't intercept the binary Postgres protocol.
3. An init script creates both databases on first boot.

The apps reach it at `postgres.default.svc.cluster.local:5432`.

### 8.2 kube-prometheus-stack

Grafana on, persistence off (a learning cluster with two `t3.medium`
nodes doesn't need to survive a Grafana restart with its dashboards),
plus two important selector knobs turned off:

```hcl
set { name = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues",     value = "false" }
set { name = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues", value = "false" }
```

By default Prometheus only scrapes PodMonitor / ServiceMonitor CRs
that carry a specific label naming the Helm release. This is fine
for multi-tenant clusters but frustrating for a single-tenant one.
Turning it off means any monitor in any namespace gets picked up.

### 8.3 FluentBit as an official Helm chart

`fluentbit.tf` uses AWS's `aws-for-fluent-bit` chart, passing just
enough config to point it at CloudWatch:

```hcl
values = [yamlencode({
  serviceAccount = {
    create = true
    name   = "fluentbit"
    annotations = { "eks.amazonaws.com/role-arn" = module.fluentbit_irsa.iam_role_arn }
  }
  cloudWatchLogs = {
    enabled         = true
    region          = var.aws_region
    logGroupName    = "/eks/ms-learning"
    autoCreateGroup = true
    logStreamPrefix = "pod/"
  }
})]
```

That's the whole log pipeline. The chart handles the DaemonSet,
ConfigMap, tolerations, and volume mounts.

<a id="9-making-pods-talk-to-each-other-securely-istio"></a>

## 9. Making pods talk to each other securely (Istio)

On Scenario 1 you had an `X-Internal-Api-Key` header. Every service
had to remember to check it, rotate it, and keep it out of logs. On
Scenario 3 we throw that away and let a service mesh handle
authentication.

**Istio** injects a second container next to your app: an **Envoy
proxy**. iptables rules redirect all traffic through Envoy. When your
Spring app calls `http://payment-service:8080`, the flow looks like:

```
your Spring app --plaintext--> Envoy sidecar (same pod)
                             --mTLS (SPIFFE cert)--> Envoy sidecar (dest pod)
                                                  --plaintext--> Spring app there
```

Your app code is completely unaware. We turned this on with three
tiny objects:

1. A label on the `default` namespace so every pod gets a sidecar:
   ```yaml
   metadata: { name: default, labels: { istio-injection: enabled } }
   ```
   Applied by Terraform via a `kubernetes_labels` resource in
   `istio_policies.tf`.
2. A `PeerAuthentication` in `default` saying **"only accept mTLS"**:
   ```yaml
   spec: { mtls: { mode: STRICT } }
   ```
3. Three `DestinationRule`s (one per service) saying **"originate
   mTLS when you talk to that service"**:
   ```yaml
   host: order-service.default.svc.cluster.local
   trafficPolicy: { tls: { mode: ISTIO_MUTUAL } }
   ```

The YAML source for #2 and #3 lives at `k8s/istio/*.yaml`. Terraform
applies them via the `kubectl_manifest` resource
(`istio_policies.tf`). We use the `gavinbunney/kubectl` provider
because these CRs reference Istio CRDs installed by
`helm_release.istio_base` in the same plan — Terraform's built-in
`kubernetes_manifest` insists the CRD exists at *plan* time and
would refuse; `kubectl_manifest` is CRD-lazy and works.

**What Istio does NOT do here.** External north-south traffic still
enters through the AWS Load Balancer Controller (ALB Ingress on
order-service with Cognito auth). The Istio ingress gateway is
intentionally not installed — it kept stalling on its readiness probe
during initial bring-up (§14) and it's not on the request path.

<a id="10-gitops-telling-the-cluster-what-to-run-argocd"></a>

## 10. GitOps: telling the cluster what to run (ArgoCD)

There's a rhythm to running production Kubernetes: you don't
`kubectl apply` things from your laptop. Instead you commit YAML to
Git, and a controller in the cluster continuously reconciles cluster
state toward what's in Git. That controller is ArgoCD.

We have three ArgoCD **Applications**, one per service. They live at
`argocd/{order,payment,user}-service-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: order-service, namespace: argocd }
spec:
  project: default
  source:
    repoURL: https://github.com/muhammad-mansoor9/microservices-learning.git
    targetRevision: scenario-3
    path: helm/order-service
    helm:
      valueFiles: [ ../../helm/values-prod.yaml ]
      valuesObject:
        image:      { repository: <acct>.dkr.ecr.us-east-1.amazonaws.com/ms-learning/order-service }
        irsa:       { roleArn: arn:aws:iam::<acct>:role/ms-learning-eks-order-service }
        env:
          DB_URL:                       jdbc:postgresql://postgres.default.svc.cluster.local:5432/order_db
          DB_USERNAME:                  postgres
          DB_PASSWORD:                  postgres
          USER_SERVICE_URL:             http://user-service.default.svc.cluster.local:8080
          PAYMENT_SERVICE_URL:          http://payment-service.default.svc.cluster.local:8080
          AWS_REGION:                   us-east-1
          SQS_ORDER_EVENTS_QUEUE_URL:   https://sqs.us-east-1.amazonaws.com/<acct>/order-events
  destination: { server: https://kubernetes.default.svc, namespace: default }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true ]
```

Two design points here:

- **Shared knobs stay in `helm/values-prod.yaml`** (replica count,
  resource requests, KEDA config). **Per-service knobs live in the
  Application's `valuesObject` block** (image URL, IRSA role, env
  vars). No copy-paste between service value files.
- **`automated: { prune: true, selfHeal: true }`** means: if
  someone deletes a manifest from Git, ArgoCD removes it from the
  cluster; if someone `kubectl edit`s a resource, ArgoCD reverts it.
  Git is source of truth, always.

Terraform applies these Application manifests too — see
`argocd_apps.tf`:

```hcl
resource "kubectl_manifest" "argocd_app" {
  for_each          = { for f in local.argocd_app_files : basename(f) => f }
  yaml_body         = file(each.value)
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [helm_release.argocd]
}
```

So a fresh `terraform apply` on an empty cluster brings up: the
cluster → the ArgoCD helm release → the ArgoCD Applications → and
then ArgoCD itself starts pulling the service Helm charts from this
same repo and deploying pods.

<a id="11-the-ci-half-github-actions"></a>

## 11. The CI half: GitHub Actions

ArgoCD deploys whatever's in Git, but *something* still needs to
build container images and put them in ECR. That's
`.github/workflows/eks-deploy.yml`. It fires on push to `scenario-3`
and has two jobs:

**Job 1 — build & push.** For each service:

```yaml
- mvn -pl <svc> -am -DskipTests package
- docker build -f <svc>/Dockerfile \
    -t $ECR/ms-learning/<svc>:<full-sha> \
    -t $ECR/ms-learning/<svc>:<short-sha> \
    -t $ECR/ms-learning/<svc>:latest .
- docker push --all-tags  (well, three separate pushes, same idea)
```

Three tags: full SHA (auditable), short SHA (for Helm), and `latest`
(so first-time ArgoCD syncs don't race the values-file update).

**Job 2 — bump the image tag in Git.**

```bash
yq -i ".image.tag = strenv(SHORT_SHA)" helm/values-prod.yaml
git commit -m "chore: update image tags to $SHORT_SHA [skip ci]"
git push origin HEAD:${GITHUB_REF_NAME}
```

The `[skip ci]` marker prevents this push from re-triggering the
workflow. After it lands, ArgoCD notices `values-prod.yaml` has a
new `image.tag`, re-renders the chart, sees a diff, and rolls the
Deployments.

<a id="12-event-driven-autoscaling-keda--sqs"></a>

## 12. Event-driven autoscaling (KEDA + SQS)

CPU-based HPA is fine for CPU-bound workloads but useless for a
queue worker that sits idle most of the time. **KEDA** watches an
*external* metric (SQS depth, Kafka lag, cron, custom Prometheus
query) and drives an HPA under the hood. It can even scale to
zero.

We turned this on for payment-service. The chart renders two custom
resources when `autoscaling.keda.enabled: true`:

```yaml
# ScaledObject
spec:
  scaleTargetRef:  { name: payment-service }
  minReplicaCount: 0
  maxReplicaCount: 5
  cooldownPeriod:  30
  triggers:
    - type: aws-sqs-queue
      authenticationRef: { name: payment-service-aws }
      metadata:
        queueURL:      https://sqs.us-east-1.amazonaws.com/<acct>/order-events
        queueLength:   "5"                   # target: 5 msgs per replica
        awsRegion:     us-east-1
        identityOwner: pod                    # use payment-service's IRSA role

# TriggerAuthentication
spec:
  podIdentity: { provider: aws }              # no static creds
```

`identityOwner: pod` + `podIdentity.provider: aws` is the pretty
part: KEDA doesn't hold AWS credentials at all — it borrows the
payment-service pod's IRSA role, which already has read access to
that queue.

**Who feeds the queue.** order-service now publishes an
`OrderCreatedEvent` to the SQS `order-events` queue *after* the
Postgres transaction commits:

```java
transactionTemplate.executeWithoutResult(tx -> {
    appendEvent(...); orderRepository.save(...);      // commits here
});
// Publish after commit so a rolled-back tx cannot emit a phantom event.
orderEventPublisher.publishOrderCreated(createdEvent);
```

The publisher itself is fire-and-forget via `SqsAsyncClient` from
AWS SDK v2. If the queue URL is unset (local dev), it no-ops
silently.

The runtime story:

1. User creates an order. order-service saves it and publishes.
2. KEDA polls SQS every 30 s and sees one message.
3. `1 msg / 5 target = ceil(0.2) = 1`. Scale payment-service from
   0 → 1.
4. Pod boots (JVM startup ~15 s, then probes pass).
5. (Once a consumer exists) the pod dequeues and processes.
6. Queue empties. After `cooldownPeriod: 30 s`, scale back to 0.

Right now step 5 has no consumer — the current codebase still calls
payment-service via HTTP from order-service. The KEDA scaler and
the publisher are ready and correct; adding the SQS consumer to
payment-service is a small follow-up.

<a id="13-observability-metrics-logs-traces"></a>

## 13. Observability: metrics, logs, traces

Three pillars, three tools.

### Metrics — Prometheus + Grafana

`kube-prometheus-stack` gives us:

- **Prometheus**, which scrapes metric endpoints and stores
  time-series.
- **Grafana**, with 20+ pre-built dashboards for Kubernetes
  internals (kubelet, node-exporter, kube-state-metrics, apiserver,
  etcd, coredns).
- **Alertmanager**, ready to route alerts if you wire it up.

Our services expose metrics through Spring Boot Actuator + the
`micrometer-registry-prometheus` bridge, at
`/actuator/prometheus` in OpenMetrics format. The Helm chart
renders pod-template annotations so Prometheus finds them:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port:   "8080"
  prometheus.io/path:   "/actuator/prometheus"
```

### Logs — FluentBit → CloudWatch

FluentBit runs as a DaemonSet in `amazon-cloudwatch`. On each Node:

```
/var/log/containers/*.log   (written by kubelet)
        │
        ▼
FluentBit pod
  input:  tail          reads the files
  filter: kubernetes    enriches with pod/namespace/label metadata
  filter: parser (json) parses our structured log lines
  output: cloudwatch_logs
        │
        ▼
CloudWatch Logs
  log group:  /eks/ms-learning
  stream:     pod/<pod-name>
```

Because the OTel agent puts the trace id into MDC, and our logback
pattern includes `%X{trace_id}`, every log line has a trace id
you can grep for in CloudWatch to reconstruct a whole request.

### Traces — the OpenTelemetry Java agent

The agent is downloaded into an `emptyDir` volume by an
`initContainer` in each pod (see §6). It auto-instruments Spring
MVC, WebClient, JDBC, Hibernate, and dozens more libraries without
a line of application code. It also propagates W3C `traceparent`
headers across HTTP calls, so a request touching all three
services is one distributed trace.

`values-prod.yaml` sets `OTEL_EXPORTER_OTLP_ENDPOINT` to
`http://otel-collector.observability.svc.cluster.local:4318` — but
we haven't installed a collector yet, so spans are dropped for
now. Metrics and logs work today; adding an OTel Collector Helm
release is a small follow-up.

<a id="14-the-three-battles-we-fought"></a>

## 14. The three battles we fought

Bringing this cluster up was not smooth. Three specific things went
wrong and each taught us a rule.

### 14.1 The EBS CSI addon stuck for 20 minutes

**Symptom.** `terraform apply` sat at
`module.eks.aws_eks_addon.this["aws-ebs-csi-driver"]: Still
creating... [20m00s elapsed]` and then failed with `timeout while
waiting for state to become 'ACTIVE'`.

**Cause.** The EBS CSI controller pods need AWS permissions to call
`ec2:CreateVolume`, `AttachVolume`, etc. Without them the addon's
health check never turns green.

**Fix.** Give the addon its own IRSA role and wire it in:

```hcl
module "ebs_csi_irsa" {
  role_name             = "${var.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

aws-ebs-csi-driver = {
  most_recent              = true
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
}
```

Then delete the stuck addon in AWS (`aws eks delete-addon`) and
re-apply.

**Lesson.** *Every* EKS addon that touches AWS APIs needs its own
IRSA role. Don't rely on node instance profiles for this.

### 14.2 Helm releases dying to "connection reset by peer"

**Symptom.** During `terraform apply` two of the Helm releases
(KEDA and Istio ingress) failed with a burst of
`read: connection reset by peer` on POSTs to the EKS API. Others
looked green in `helm ls` but showed status `failed`.

**Cause.** Terraform's Helm provider makes many concurrent API
calls from your laptop to the EKS control plane. If your network
path is flaky (home ISP, VPN, proxy), the connections get RST'd
under load and Helm has no chance to recover.

**Fix.** Two knobs on every `helm_release`:

```hcl
timeout = 900        # 15 min instead of the default 5
atomic  = true       # roll back cleanly on failure
```

Plus running `terraform apply -parallelism=2` to reduce the
concurrent load on the EKS API from ten resources at once to two.

**Recovery.** For any releases already stuck in `failed`:

```bash
helm uninstall <name> -n <ns>
terraform state rm helm_release.<name>
terraform apply -parallelism=2
```

**Lesson.** Managing many Helm releases from Terraform is possible
but noisy. Use `atomic` so failures don't leave junk to clean up.

### 14.3 Istio ingress gateway stalled on readiness

**Symptom.** `helm_release.istio_ingress` hit its 15-minute timeout;
the gateway pod was running but stuck at `0/1 Ready`.

**Cause (best guess).** Some interaction with istiod's mutating
webhook or the readiness probe timing.

**Fix.** Removed the release from Terraform. Our external traffic
enters through the AWS Load Balancer Controller (ALB Ingress on
order-service, with Cognito auth), so the Istio ingress gateway
was never on the request path. mTLS between pods still works
because that's driven by istiod + PeerAuthentication + sidecars,
none of which need the gateway.

**Lesson.** Istio is three big pieces (control plane, sidecars,
gateway). You can run any subset. Don't let a stuck gateway block
your cluster when you're not routing external traffic through it.

<a id="15-where-were-standing-right-now"></a>

## 15. Where we're standing right now

After `terraform apply` completes on the current branch you'll
have all of this running:

- **In AWS**: VPC + subnets + NAT, EKS cluster, one t3.medium
  managed node group of size 2, six IRSA roles, three ECR
  repositories, one DynamoDB table (`users`), one SQS queue
  (`order-events`).
- **In `kube-system`**: coredns, kube-proxy, vpc-cni, ebs-csi
  controller, aws-load-balancer-controller.
- **In `istio-system`**: istiod (control plane, no gateway).
- **In `argocd`**: ArgoCD server + repo-server +
  application-controller + three declared `Application` CRs.
- **In `keda`**: the KEDA operator and its metrics apiserver.
- **In `monitoring`**: Prometheus, Alertmanager, Grafana,
  kube-state-metrics, node-exporter.
- **In `amazon-cloudwatch`**: a FluentBit DaemonSet shipping logs
  to `/eks/ms-learning`.
- **In `default`**: a Postgres StatefulSet (with `order_db` and
  `payment_db` databases) plus — after ArgoCD syncs — the three
  service Deployments.

**The last unknowns** before end-to-end works:

1. **AWS credentials for GitHub Actions.** Set
   `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in your repo's
   Settings → Secrets and variables → Actions. Without them the
   workflow can't push to ECR.
2. **The first image push.** ECR repos exist but are empty. Either
   push once to the `scenario-3` branch (workflow builds and
   pushes) or `docker build && push` by hand.
3. **payment-service SQS consumer.** The KEDA scaler polls the
   queue and scales pods up, but no code inside payment-service
   dequeues messages yet. Adding a listener is a small follow-up.

<a id="16-verifying-and-testing"></a>

## 16. Verifying and testing

### Check what's up

```bash
# Cluster + Nodes
kubectl get nodes

# Every pod, everywhere. Filter to anything not Running or Completed.
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Every Helm release Terraform installed
helm ls -A

# ArgoCD sees your three Applications
kubectl -n argocd get applications

# Istio label + policies applied
kubectl get namespace default -o jsonpath='{.metadata.labels}'
kubectl -n default get peerauthentication,destinationrule

# Postgres is reachable from inside the cluster
kubectl -n default exec -it deploy/postgres -- psql -U postgres -c '\l'
```

### Open the in-cluster UIs

Nothing has a public URL — everything is `ClusterIP`. Use
`kubectl port-forward` from your laptop.

**ArgoCD** (see the sync status of your three apps):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d && echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  (accept the self-signed cert)
# user: admin
```

**Grafana** (built-in dashboards, plus our services once they're up):

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
    -o jsonpath='{.data.admin-password}' | base64 -d && echo
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000
# user: admin
```

**Prometheus** (see who's being scraped):

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090  → Status → Targets
```

### End-to-end request

Once ArgoCD has synced the three service Deployments and their
pods are `Ready`, port-forward order-service and hit it:

```bash
kubectl -n default port-forward svc/order-service 8080:8080

# Create a user
curl -X POST http://localhost:8080/api/users \
     -H 'Content-Type: application/json' \
     -d '{"userId":"u1","email":"a@example.com","name":"A"}'

# Create an order
curl -X POST http://localhost:8080/api/orders \
     -H 'Content-Type: application/json' \
     -d '{"userId":"u1","amount":42.00}'

# Watch it happen
kubectl -n default logs -f deploy/order-service
kubectl -n default logs -f deploy/payment-service
kubectl -n default logs -f deploy/user-service
```

<a id="17-command-cheat-sheet"></a>

## 17. Command cheat sheet

**Cluster access**

```bash
aws eks update-kubeconfig --name ms-learning-eks --region us-east-1
kubectl config current-context
kubectl get nodes
```

**Poking at a pod**

```bash
kubectl -n default get pods -l app.kubernetes.io/name=order-service
kubectl -n default logs -f <pod>
kubectl -n default logs -f <pod> -c istio-proxy   # the sidecar
kubectl -n default exec -it <pod> -- sh
kubectl -n default port-forward <pod> 8080:8080
```

**Helm**

```bash
helm ls -A
helm history <release> -n <ns>
helm rollback <release> <rev> -n <ns>
helm template order-service ./helm/order-service \
   -f helm/values-prod.yaml --set image.repository=order-service
```

**Terraform**

```bash
cd infrastructure/scenario-3
terraform init
terraform plan
terraform apply -parallelism=2
terraform output -raw order_events_queue_url
terraform output -raw ecr_registry
```

**Debugging KEDA**

```bash
kubectl -n default get scaledobjects
kubectl -n keda logs deploy/keda-operator
```

**Debugging Istio**

```bash
kubectl -n istio-system get pods
kubectl -n istio-system logs deploy/istiod
kubectl exec <pod> -c istio-proxy -- pilot-agent request GET stats | grep upstream_rq_total
```

<a id="18-scenario-1-vs-scenario-3-side-by-side"></a>

## 18. Scenario 1 vs Scenario 3, side by side

| Concern             | Scenario 1 (`main`)                             | Scenario 3 (`scenario-3`)                                               |
| ------------------- | ----------------------------------------------- | ----------------------------------------------------------------------- |
| Compute             | `infrastructure/scenario-1/ec2.tf`              | `infrastructure/scenario-3/eks.tf` (managed node group)                 |
| Ingress             | `alb.tf` + `api-gateway/`                       | `helm/order-service/templates/ingress.yaml` (ALB via controller)        |
| Service discovery   | Eureka Spring Boot app                          | Kubernetes DNS (no code)                                                |
| Config              | Config Server + `config-repo/*.yml`             | `helm/values-{local,prod}.yaml` → env vars                              |
| Inter-service auth  | `X-Internal-Api-Key` header check               | `k8s/istio/peer-authentication.yaml` STRICT mTLS                        |
| Autoscaling         | EC2 ASG on CPU                                  | `templates/hpa.yaml` + `scaledobject.yaml` (KEDA, SQS)                  |
| Deploy pipeline     | `scp` a JAR onto EC2                            | GitHub Actions → ECR → ArgoCD                                           |
| Metrics collection  | CloudWatch agent per EC2                        | kube-prometheus-stack in `monitoring`                                   |
| Log collection      | CloudWatch agent per EC2                        | FluentBit DaemonSet in `amazon-cloudwatch`                              |
| AWS API access      | Instance profile per EC2                        | IRSA per pod                                                            |
| Database            | RDS Postgres                                    | Bitnami Postgres helm release in-cluster (EBS-backed PVC)               |

The right column has more moving parts, but each piece is small and
reusable. On EC2 you owned the whole stack per host; on EKS the
cluster **is** the stack and every app is just a Deployment.

---

## Appendix — bringing up a fresh cluster

```bash
# 1. Bootstrap the S3 backend bucket for Terraform state (once ever).
cd infrastructure/bootstrap
terraform init && terraform apply

# 2. Bring up the whole platform.
cd ../scenario-3
cp terraform.tfvars.example terraform.tfvars    # tweak if needed
terraform init
terraform apply -parallelism=2

# 3. Point kubectl at the new cluster.
./scripts/setup-cluster.sh

# 4. Sanity checks.
kubectl get nodes
kubectl get pods -A
helm ls -A
kubectl -n argocd get applications
```

Push to `scenario-3` after that. GitHub Actions builds, pushes to
ECR, and updates `values-prod.yaml`. ArgoCD picks up the commit and
rolls the Deployments. Done.

---

*Any section that doesn't click, ask — I'll expand.*
