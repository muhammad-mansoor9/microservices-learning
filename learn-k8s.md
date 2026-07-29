# Learning the platform: a guided tour

> This document is a **learning companion**, not a runbook. Nothing in
> here tells you to run a command. You already have `scenario3.md` for
> the technical walkthrough and end-to-end steps. This file exists so
> that when you finish `terraform apply` and think *"wait, what did I
> just install and why?"*, you can sit down and read it.

You said you know the Kubernetes objects — Pods, Deployments,
Services, Namespaces, `kubectl apply` — so we'll go light on those.
What we'll cover is **the layer under and above them**: first what a
Kubernetes cluster actually *is* under the hood (chapters 1-2), then
the platform tools sitting between "plain Kubernetes" and "an
application that actually serves traffic in production"
(chapters 3-15). Once you know which job is whose, the whole thing
stops looking like a bag of acronyms.

---

## Contents

- [0. Why so many tools?](#0-why-so-many-tools)
- [1. Kubernetes — the control plane and the workers](#1-kubernetes--the-control-plane-and-the-workers)
- [2. Amazon EKS — Kubernetes on AWS](#2-amazon-eks--kubernetes-on-aws)
- [3. The layer cake](#3-the-layer-cake)
- [4. Helm — packaging YAML](#4-helm--packaging-yaml)
- [5. Terraform and the EKS module](#5-terraform-and-the-eks-module)
- [6. AWS Load Balancer Controller — how Ingress becomes an ALB](#6-aws-load-balancer-controller--how-ingress-becomes-an-alb)
- [7. IRSA — how pods get AWS permissions](#7-irsa--how-pods-get-aws-permissions)
- [8. ArgoCD — GitOps in one paragraph](#8-argocd--gitops-in-one-paragraph)
- [9. GitHub Actions' role in this world](#9-github-actions-role-in-this-world)
- [10. Istio — the service mesh](#10-istio--the-service-mesh)
- [11. KEDA — event-driven autoscaling](#11-keda--event-driven-autoscaling)
- [12. kube-prometheus-stack — metrics](#12-kube-prometheus-stack--metrics)
- [13. FluentBit + CloudWatch — logs](#13-fluentbit--cloudwatch--logs)
- [14. OpenTelemetry — traces (and the MDC trick)](#14-opentelemetry--traces-and-the-mdc-trick)
- [15. Bitnami Postgres — running a stateful app on Kubernetes](#15-bitnami-postgres--running-a-stateful-app-on-kubernetes)
- [16. How they cooperate: one request, end to end](#16-how-they-cooperate-one-request-end-to-end)
- [17. Common misconceptions](#17-common-misconceptions)
- [18. Dashboards and UIs — what you're actually looking at](#18-dashboards-and-uis)
- [19. Where to go deeper](#19-where-to-go-deeper)

---

<a id="0-why-so-many-tools"></a>

## 0. Why so many tools?

Kubernetes on its own does one thing well: **it schedules containers
onto Nodes and keeps them running**. That's it. It doesn't tell you
how to expose them to the internet, how to secure the traffic between
them, how to deploy new versions, how to autoscale on business
metrics, or how to see what's happening. Every one of those problems
has to be solved by something.

What you get with a barely-provisioned Kubernetes cluster:

- Pods can run, but there's no external load balancer.
- Pods can talk to each other, but everything is plaintext.
- New code doesn't deploy itself — someone has to `kubectl apply`.
- HPA can scale on CPU, but not on "SQS has 100 messages."
- There's no dashboard for anything.

Each tool in this repo plugs one of those holes. When people say
*"we're running on Kubernetes,"* what they usually mean is *"we're
running on Kubernetes plus this specific set of tools."* That set is
sometimes called a **distribution** (like EKS) or a **platform**
(like what we've built here).

---

<a id="1-kubernetes--the-control-plane-and-the-workers"></a>

## 1. Kubernetes — the control plane and the workers

Before you can understand any of the platform tools, you need a
clear mental model of what a Kubernetes cluster actually *is*
underneath. It's not one program. It's a small distributed system
made of half a dozen cooperating processes, split cleanly into two
halves.

### 1.1 The two halves

Every Kubernetes cluster has:

- **A control plane** — the brains. It stores the desired state of
  everything ("I want three replicas of order-service") and runs the
  controllers that reconcile reality toward it.
- **A pool of worker nodes** — the muscle. These are the machines
  (EC2 VMs in our case) where your actual pods run.

The control plane doesn't run your workloads. The nodes don't decide
what to run. They talk to each other through the API server.

```
                ┌────────────────────── Control plane ──────────────────────┐
                │                                                            │
                │   ┌────────────────┐    ┌──────────────┐    ┌──────────┐  │
                │   │  API server    │◀──▶│    etcd      │    │scheduler │  │
                │   │ (HTTP/REST)    │    │ (state store)│    └──────────┘  │
                │   └───────┬────────┘    └──────────────┘    ┌──────────┐  │
                │           │                                  │controller│  │
                │           │◀─────────────────────────────────│ manager  │  │
                │           │                                  └──────────┘  │
                └───────────┼────────────────────────────────────────────────┘
                            │
    ┌───────────────────────┼───────────────────────────────────────────┐
    │                       │                    Worker nodes            │
    │   ┌───────────────────▼──────────────────────┐   ┌──────────────┐ │
    │   │   Node A                                 │   │  Node B      │ │
    │   │   ┌──────────┐   ┌────────────┐          │   │              │ │
    │   │   │ kubelet  │   │ kube-proxy │          │   │  kubelet     │ │
    │   │   └──────────┘   └────────────┘          │   │  kube-proxy  │ │
    │   │   ┌──────────┐   ┌──────┐   ┌──────┐     │   │              │ │
    │   │   │ pod #1   │   │pod #2│   │pod #3│     │   │  (pods)      │ │
    │   │   └──────────┘   └──────┘   └──────┘     │   │              │ │
    │   └──────────────────────────────────────────┘   └──────────────┘ │
    └────────────────────────────────────────────────────────────────────┘
```

### 1.2 The control plane, component by component

**API server (`kube-apiserver`).** The one front door. Every read and
every write of cluster state — from `kubectl`, from any controller,
from any pod — goes through this HTTP/REST endpoint. It validates,
authenticates, authorizes, and stores. If the API server is down,
nothing changes anywhere else in the cluster; but existing pods keep
running.

**etcd.** A distributed key-value store. The API server is stateless
by itself — etcd is where cluster state actually lives. Every
Deployment spec, every Service definition, every ConfigMap value is
a row in etcd. It's the truth. If etcd is corrupted, your cluster is
gone. Which is why EKS runs etcd for you with automatic backups.

**Scheduler (`kube-scheduler`).** When a new pod appears without an
assigned node, the scheduler picks one. It scores each candidate node
based on resource requests vs. availability, node affinities,
tolerations, and constraints, then writes the assignment back through
the API server. That's its whole job — bin-packing pods onto nodes.

**Controller manager (`kube-controller-manager`).** A single process
that runs a couple dozen small **controllers**. Each controller
watches one type of object and reconciles reality to spec. Examples:

- The **Deployment controller** watches Deployment objects. If you
  say `replicas: 3` and only 2 pods exist, it creates a third.
- The **ReplicaSet controller** does the actual pod-count enforcement
  under the Deployment.
- The **Node controller** watches for unresponsive nodes and marks
  their pods for rescheduling.
- The **Service controller** wires up Service endpoints as pods come
  and go.

Every "self-healing" property Kubernetes has comes from these little
reconciliation loops.

**Cloud controller manager.** Optional. Runs cloud-provider-specific
controllers — routing traffic to cloud load balancers, mounting cloud
storage, tagging cloud VMs. On EKS this exists but you don't manage
it.

### 1.3 The worker nodes, component by component

Each worker node (VM) runs three programs:

**kubelet.** The agent on every node that talks to the API server.
It receives pod assignments, pulls container images, and asks the
local container runtime to start them. Then it keeps reporting the
pod's status back to the API server. If you kill kubelet, the node
becomes uncooperative — existing containers keep running but nothing
new starts.

**kube-proxy.** Implements the **Service** abstraction. When a pod
sends traffic to `payment-service.default.svc.cluster.local:8080`,
DNS resolves that to a virtual IP (the Service's ClusterIP), and
kube-proxy's iptables/IPVS rules on the node rewrite the destination
to the actual pod IP. It's what makes Services just work.

**Container runtime.** Runs the actual containers. Historically
Docker; today mostly **containerd** (which is what EKS uses). Talks
to kubelet via the Container Runtime Interface (CRI). The runtime is
what pulls images, sets up namespaces and cgroups, and starts
processes.

### 1.4 Everything is a reconciliation loop

Here's the pattern you'll see over and over:

1. Someone POSTs "desired state" to the API server (via `kubectl`,
   Terraform, Helm, or another controller).
2. The API server writes to etcd.
3. Controllers watch etcd (through the API server) for changes to
   objects they care about.
4. When a controller sees a diff between desired and actual state, it
   takes action: creates a pod, deletes one, updates a status field,
   etc.
5. GOTO 3 forever.

That's the whole system. There's no imperative "start pod" command
anywhere. You declare state; controllers reconcile.

Once you internalize this, every custom controller — Istio's
sidecar-injecting webhook, ArgoCD's Application reconciler, KEDA's
scaler, cert-manager's certificate renewer — is just the same
pattern applied to a different object type.

### 1.5 What you talk to, what you don't

You interact with **the API server** (via `kubectl`, or an SDK).
That's it. You never SSH into the control plane. You never touch
etcd. You rarely touch kubelet unless you're debugging node problems.

The API server is where every convention meets the wall: authentication,
authorization (RBAC), admission control, resource quotas, audit
logging. If you can't get an API server call through, nothing else
matters.

**Common misconceptions.**

- *"kubectl talks to the pods."* → No, it talks to the API server.
  The API server tells controllers which tell kubelets which tell
  containers.
- *"Kubernetes is one program."* → It's a distributed system with 5+
  cooperating components on the control plane plus 3 per node.
- *"etcd is optional."* → It's the beating heart. Losing etcd loses
  the cluster.
- *"The scheduler runs pods."* → No, it only *assigns* pods to nodes.
  kubelet on that node is what actually runs them.

**Deeper reading.** kubernetes.io/docs/concepts/overview/components.

---

<a id="2-amazon-eks--kubernetes-on-aws"></a>

## 2. Amazon EKS — Kubernetes on AWS

Kubernetes is the software. **EKS is Amazon's operational service
that runs it for you.** The distinction matters — most of what makes
running a production Kubernetes cluster hard is running the control
plane (etcd backups, API server HA, version upgrades, TLS certs,
security patches). EKS erases that half of the problem.

### 2.1 What AWS actually runs for you

When you create an EKS cluster, AWS provisions and manages:

- The **API server** — multi-AZ, load-balanced, patched by AWS.
- **etcd** — HA across three AZs, encrypted at rest, snapshotted.
- The **scheduler** and **controller manager**.
- The **cluster's internal DNS** (coredns runs on your nodes but is
  an AWS-managed add-on).
- Automatic **version upgrades** (with your approval).

You never see any of these processes. You get one HTTPS endpoint
(`https://<hash>.gr7.us-east-1.eks.amazonaws.com`), a CA certificate,
and IAM-based auth to talk to it. That's the whole surface area of
the control plane, from your point of view.

The trade: **~$0.10/hr per cluster** (a bit under $75/month for a
cluster that runs 24/7). That's the "you don't have to run etcd"
tax. For a learning cluster it's the biggest cost we take on.

### 2.2 What you still own: the nodes

AWS does not run your workloads. You need worker nodes for that.
EKS gives you three options:

- **Managed node groups.** EKS provisions and manages EC2 instances
  for you: it picks the AMI (an EKS-optimized Amazon Linux 2 or
  Bottlerocket image with kubelet already installed), joins them to
  the cluster, and handles rolling updates when the Kubernetes
  version changes. **This is what we use.** In `infrastructure/scenario-3/eks.tf`:
  ```hcl
  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size = 1
      max_size = 3
      desired_size = 2
      capacity_type  = "ON_DEMAND"
    }
  }
  ```
- **Self-managed nodes.** You provision EC2 instances yourself, run
  the EKS bootstrap script on each, and join them to the cluster.
  More control, more work.
- **Fargate.** Pods run on AWS-managed micro-VMs — no EC2 to think
  about at all. Simpler but more expensive per pod and with several
  limitations (no DaemonSets, no privileged containers). Not what we
  use.

Cost model for our setup: 2 × t3.medium × ~$0.04/hr = ~$60/month for
nodes, plus the ~$75/month for the control plane, plus small extras
(NAT gateway, EBS volumes, data transfer). Round it to ~$150/month
for the whole learning cluster.

### 2.3 Add-ons — the pieces AWS installs into the cluster for you

Some Kubernetes components (coredns, kube-proxy) and some AWS
integrations (VPC CNI, EBS CSI driver) can be installed as **EKS
add-ons**: AWS-managed installations that patch themselves alongside
the control plane. Cheaper to operate than helming them yourself.

Our cluster has four:

| Add-on | Purpose |
| --- | --- |
| `coredns` | Cluster-internal DNS: `payment-service.default.svc.cluster.local` |
| `kube-proxy` | Service-to-pod traffic routing (kube-proxy on each node) |
| `vpc-cni` | Assigns each pod a real VPC IP (not overlay networking) |
| `aws-ebs-csi-driver` | Provisions EBS volumes when pods claim persistent storage |

In `infrastructure/scenario-3/eks.tf`:

```hcl
cluster_addons = {
  coredns             = { most_recent = true }
  kube-proxy          = { most_recent = true }
  vpc-cni             = { most_recent = true }
  aws-ebs-csi-driver  = {
    most_recent              = true
    service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
  }
}
```

The `aws-ebs-csi-driver` needs its own IRSA role because it calls
`ec2:CreateVolume` on your behalf. This is the one that stalled us
for 20 minutes during cluster bring-up — see the "war stories" of
`scenario3.md`.

### 2.4 Two AWS-specific concepts you'll meet everywhere

**VPC CNI networking.** Most Kubernetes distributions use an overlay
network (Flannel, Calico), where each pod gets an IP in a private
range that only the cluster understands. VPC CNI is different — it
gives every pod a **real VPC IP** by attaching secondary IPs to the
worker node's ENI. That means:

- Your pod can be reached directly from anything in the VPC.
- ALBs can target pods directly (`target-type: ip`) without going
  through NodePorts.
- You're limited by the number of IPs the ENI supports (roughly
  15-30 pods per t3.medium).

**IRSA (IAM Roles for Service Accounts).** Covered in depth in
chapter 7. Short version: EKS lets a pod assume an IAM role by
annotating its ServiceAccount with the role's ARN. Every workload
that touches AWS APIs gets its own scoped role. No static keys, no
node-level credential sharing.

### 2.5 How the cluster gets created in this repo

We don't hand-write the ~30 AWS resources that make up an EKS
cluster. We use the **community EKS Terraform module**:

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"
  # …
}
```

This one module call produces: the EKS cluster resource, the OIDC
provider (for IRSA), the managed node group, the launch template,
the security groups, the IAM roles for the node group and control
plane, and the cluster addons. A hand-written version would be
hundreds of lines and easy to get wrong.

### 2.6 Where EKS ends and you begin

**AWS manages** the control plane, add-ons, node lifecycle (for
managed groups), and version upgrade orchestration.

**You manage** everything on top of that: which node types, how
many, which Helm charts to install, which apps to deploy, RBAC,
network policies, monitoring, backups of your data (not etcd — that
AWS backs up — but your PostgreSQL data on EBS).

**You cannot access** the control plane's underlying EC2 instances,
etcd, or the API server's OS. If AWS's version of Kubernetes is
missing a feature flag you want, EKS is the wrong choice — go
self-managed or use a different distribution.

### 2.7 The main things EKS gives you beyond vanilla Kubernetes

- Managed control plane (etcd, apiserver, HA).
- IRSA — pod-level AWS credentials without static keys.
- Cluster addons — AWS-managed installs of core components.
- Access entries — a way to grant IAM users cluster-admin without
  editing the `aws-auth` ConfigMap by hand. Enabled by
  `enable_cluster_creator_admin_permissions = true` in our module.
- Integration with AWS-native things: ECR (image registry), ALB
  (via the Load Balancer Controller), CloudWatch (logs), IAM
  (identity).

**Common misconceptions.**

- *"EKS is Kubernetes."* → EKS is a managed *implementation* of
  Kubernetes. The Kubernetes API you see is standard; the operational
  posture around it is AWS-specific.
- *"Anything on Kubernetes works on EKS."* → Almost always yes.
  Occasional gotchas around DaemonSets on Fargate, networking with
  overlay CNIs, or PodSecurity policies.
- *"EKS is expensive."* → The $75/mo control plane is real. But
  running your own multi-AZ etcd, patching apiservers, and doing
  version upgrades costs a full-time engineer. For most orgs, EKS is
  cheaper.

**Deeper reading.** docs.aws.amazon.com/eks/latest/userguide.
Start with "Getting Started" and the "IAM roles for service accounts"
page.

---

<a id="3-the-layer-cake"></a>

## 3. The layer cake

Here's a mental picture of the platform we've built. From bottom to
top, each layer depends on the ones below.

```
┌─────────────────────────────────────────────────────────────────┐
│  Your three services (order, payment, user)                     │
│  — pods running the Spring Boot JARs                            │
├─────────────────────────────────────────────────────────────────┤
│  ArgoCD (deploys the services from Git)                         │
│  GitHub Actions (builds images, bumps tags in Git)              │
│  Istio (mTLS between pods)                                      │
│  KEDA (scale from 0 based on SQS depth)                         │
│  kube-prometheus-stack (metrics: Prometheus + Grafana)          │
│  FluentBit (logs → CloudWatch)                                  │
│  Bitnami Postgres (in-cluster database)                         │
├─────────────────────────────────────────────────────────────────┤
│  aws-load-balancer-controller (turns Ingress into AWS ALB)      │
│  ebs-csi-driver (turns PVCs into AWS EBS volumes)               │
│  coredns, kube-proxy, vpc-cni (cluster fundamentals)            │
├─────────────────────────────────────────────────────────────────┤
│  EKS control plane (managed by AWS)                             │
│  EKS worker nodes (EC2, t3.medium)                              │
│  VPC, subnets, NAT (networking)                                 │
│  IAM (IRSA roles for each pod that touches AWS)                 │
│  ECR (image registry)                                           │
│  SQS, DynamoDB (managed services the apps use)                  │
└─────────────────────────────────────────────────────────────────┘
```

Two rules of thumb:

- **The bottom layers are AWS.** They're provisioned by **Terraform**.
- **The middle and upper layers are Kubernetes objects.** They're
  installed by **Helm charts**, and the Helm releases themselves are
  driven by Terraform (`infrastructure/scenario-3/helm_releases.tf`,
  `fluentbit.tf`).
- **Your apps at the top** are driven by **ArgoCD**, which watches Git
  and reconciles the cluster toward what it sees there.

The rest of this document walks each of those tools in the order that
makes them easiest to understand.

---

<a id="4-helm--packaging-yaml"></a>

## 4. Helm — packaging YAML

**In one sentence.** Helm is a template engine + package manager for
Kubernetes YAML. You write templates once and render them for many
environments.

**What problem it solves.** A production Deployment YAML in the wild
is 100+ lines of boilerplate: labels, selectors, probes, resources,
env vars, volumes, security context. And you have three services that
are 95% identical. Without Helm you'd copy-paste and diverge; with
Helm you write **one chart** and render it three times.

**How it works, in one paragraph.** A **chart** is a folder with a
`Chart.yaml` (metadata), a `values.yaml` (defaults), and a `templates/`
directory of YAML files with `{{ .Values.foo }}` placeholders. You
run `helm install <name> <chart> --set foo=bar` or `-f values.yaml`
and Helm renders concrete YAML by substituting values into templates,
then submits it to the Kubernetes API. A record of what was
installed — a **release** — is stored in the cluster as a Secret so
Helm can diff, upgrade, and roll back.

**In this repo.**

- `helm/order-service/`, `helm/payment-service/`, `helm/user-service/`
  are three charts with the same structure.
- `helm/order-service/values.yaml` is the knob panel.
- `helm/order-service/templates/deployment.yaml` is the Deployment
  template. Look at how `{{ .Values.replicaCount }}` gets substituted.
- `helm/values-prod.yaml` and `helm/values-local.yaml` at the top
  level are shared override files applied with `-f`.

**Where else Helm shows up.** We didn't just use it for our own
apps — we used it for **every third-party thing** on the cluster.
Prometheus, Istio, ArgoCD, KEDA, Postgres, FluentBit — all
installed as Helm charts by Terraform's Helm provider. Helm is *the*
package format for Kubernetes.

**Common misconceptions.**

- "Helm is a deployment tool." → No. It's a template + package
  manager. **ArgoCD** or **Terraform** is what actually deploys
  it in this repo.
- "You need a Helm repo hosted somewhere." → Not required. `helm
  install ./local-chart-path` works fine, and `helm/*/Chart.yaml`
  in this repo is exactly that.
- "Charts version everything atomically." → They version the *chart
  template*. Image tags, env vars, etc. are values plugged in at
  render time; those get their own versioning story (§9 GitHub
  Actions).

**Deeper reading.** helm.sh/docs, "Chart Template Guide."

---

<a id="5-terraform-and-the-eks-module"></a>

## 5. Terraform and the EKS module

**In one sentence.** Terraform is how we declare AWS infrastructure
(and Kubernetes objects) in code so `terraform apply` builds or
reconciles the whole thing every time.

**What problem it solves.** Clicking through the AWS console to set
up a VPC, EKS cluster, node group, IAM roles, and 15 other resources
is tedious, error-prone, and un-reviewable. Terraform gives you a
version-controlled, diffable description of *the entire environment*.
`terraform plan` shows you exactly what will change before it does.

**How it works.**

- You declare **resources** in `.tf` files (`resource
  "aws_sqs_queue" "order_events" { ... }`).
- Terraform reads the current state (stored in an S3 bucket for us),
  compares it to your code, and computes the diff.
- On `apply`, it calls the AWS APIs (or Kubernetes API, or Helm) to
  make reality match code.

**In this repo.** Everything under `infrastructure/scenario-3/`. Each
file is a topic:

- `providers.tf` — which providers to use (AWS, Kubernetes, Helm,
  kubectl) and the S3 backend for state.
- `vpc.tf`, `eks.tf` — the AWS side of the cluster.
- `irsa.tf` — the six IAM roles that pods assume.
- `ecr.tf`, `dynamodb.tf`, `sqs.tf` — managed AWS services the apps
  use.
- `helm_releases.tf`, `fluentbit.tf` — Helm releases installed *into*
  the cluster (yes, Terraform can also drive Helm).
- `argocd_apps.tf`, `istio_policies.tf` — a few raw Kubernetes
  manifests applied through the `kubectl` provider.

**The EKS module.** We don't hand-write the ~30 resources that make
up an EKS cluster (control plane, node group, security groups, addons,
launch templates, IAM roles). We use the **community EKS module**
(`terraform-aws-modules/eks/aws ~> 20.0`), which is basically a very
well-maintained blueprint. Same for the VPC module. Both are the
industry defaults — reading their READMEs is worth an afternoon.

**Common misconceptions.**

- "Terraform is only for cloud infra." → It manages any resource with
  a Terraform provider — including Kubernetes objects, Helm releases,
  GitHub repos, Grafana dashboards, and Cloudflare records.
- "State is a local file." → Only by default. Ours lives in S3
  (`infrastructure/bootstrap/` sets that up). Never commit
  `terraform.tfstate` to Git.
- "Terraform will fix any drift." → Only what it knows about. If
  someone `kubectl edits` a Deployment that Terraform manages,
  Terraform won't reconcile it. That's exactly why we let **ArgoCD**
  manage the app Deployments — ArgoCD does continuous reconciliation.

**Deeper reading.** developer.hashicorp.com/terraform,
"Configuration Language."

---

<a id="6-aws-load-balancer-controller--how-ingress-becomes-an-alb"></a>

## 6. AWS Load Balancer Controller — how Ingress becomes an ALB

**In one sentence.** It's a controller running in the cluster that
watches Kubernetes `Ingress` objects and creates AWS ALBs to match.

**What problem it solves.** Kubernetes gives you an `Ingress` object
(rules for external HTTP traffic). By itself, that object doesn't do
anything — you need a controller to *implement* it. On EKS, the
official one is the AWS Load Balancer Controller. It:

- Watches for Ingress objects with `ingressClassName: alb`.
- Provisions an actual **AWS ALB** in your VPC.
- Attaches target groups pointing at your pods.
- Wires up TLS, health checks, and Cognito auth if you asked for them
  via annotations.
- Deletes the ALB when you delete the Ingress.

**In this repo.**

- Installed as a Helm chart in `infrastructure/scenario-3/helm_releases.tf`
  (`helm_release.aws_lb_controller`).
- Given AWS permissions via IRSA in `irsa.tf`
  (`module.aws_lb_controller_irsa`) — with the built-in AWS-managed
  policy.
- Consumes the subnet tags in `vpc.tf` (`kubernetes.io/role/elb=1`)
  to know where public ALBs should live.
- One Ingress definition exists at `helm/order-service/templates/ingress.yaml`
  with the ALB + Cognito annotations. When you install order-service
  with `ingress.enabled=true`, the controller sees it and provisions
  the ALB.

**Common misconceptions.**

- "Kubernetes provisions ALBs." → No, this controller does. Without
  it, `kubectl apply` on an Ingress creates the object but nothing
  happens.
- "You configure the ALB directly in AWS." → You do it through
  Ingress annotations
  (`alb.ingress.kubernetes.io/scheme: internet-facing`, etc.). The
  controller translates those to ALB config. Any direct changes you
  make in the AWS console will be reverted the next time the
  controller reconciles.

**Deeper reading.** kubernetes-sigs.github.io/aws-load-balancer-controller.

---

<a id="7-irsa--how-pods-get-aws-permissions"></a>

## 7. IRSA — how pods get AWS permissions

**In one sentence.** IRSA (**I**AM **R**oles for **S**ervice
**A**ccounts) lets a pod assume an IAM role by being tied to a
Kubernetes ServiceAccount that's annotated with the role's ARN. No
static AWS keys.

**What problem it solves.** Your Spring app needs to call AWS APIs —
`sqs:SendMessage`, `dynamodb:PutItem`, etc. Traditionally you'd bake
an access key into an env var. That's a rotation nightmare and a
security hole. IRSA replaces it with **short-lived tokens delivered
through the AWS SDK's default credential chain** — invisible to your
app code.

**How it works, step by step.**

1. When you create the EKS cluster, EKS also creates an **OIDC
   provider** in IAM. This provider is what AWS trusts as an
   identity issuer for the cluster.
2. You create an **IAM role** whose trust policy says *"anyone
   presenting a valid token from that OIDC provider AND running as
   ServiceAccount `<namespace>:<sa-name>` can assume me."* (Ours
   are all built with the `iam-role-for-service-accounts-eks`
   community sub-module.)
3. You **annotate the Kubernetes ServiceAccount** with the role's
   ARN:

   ```yaml
   metadata:
     annotations:
       eks.amazonaws.com/role-arn: arn:aws:iam::…:role/…-order-service
   ```
4. When a pod runs as that ServiceAccount, EKS injects two things
   into the pod: a **projected token** (a JWT signed by the
   cluster) and env vars pointing at it (`AWS_ROLE_ARN`,
   `AWS_WEB_IDENTITY_TOKEN_FILE`).
5. Your AWS SDK sees those env vars, calls
   `sts:AssumeRoleWithWebIdentity` with the token, and gets back
   temporary AWS credentials good for ~1 hour. It refreshes them
   automatically.

Your Java code doesn't need to know any of this. In `SqsConfig.java`
you'll see:

```java
builder.credentialsProvider(DefaultCredentialsProvider.create());
```

That default chain finds the IRSA env vars and does the whole dance
for you.

**In this repo.**

- Six IRSA roles in `infrastructure/scenario-3/irsa.tf` — one per
  workload that touches AWS (order-service, payment-service,
  user-service, aws-lb-controller, ebs-csi-driver, fluentbit).
- Each service's Helm chart renders a ServiceAccount with the
  annotation: `helm/order-service/templates/serviceaccount.yaml`.
- The role ARN is passed in via the ArgoCD Application's
  `helm.valuesObject.irsa.roleArn` field
  (`argocd/order-service-app.yaml`).

**Common misconceptions.**

- "The pod needs to know its AWS credentials." → It doesn't. The SDK
  handles it via the default credential chain. If you find yourself
  setting `AWS_ACCESS_KEY_ID` in a pod, you're doing it wrong.
- "One IRSA role per cluster." → No, one IRSA role per **workload
  identity**. Different pods should get different roles with
  different scopes.
- "IRSA works everywhere." → Only in EKS (and other clusters with an
  OIDC provider). Local Docker Compose won't work — that's why our
  local dev falls back to `StaticCredentialsProvider("test","test")`
  when talking to LocalStack.

**Deeper reading.** docs.aws.amazon.com/eks → "IAM roles for service
accounts."

---

<a id="8-argocd--gitops-in-one-paragraph"></a>

## 8. ArgoCD — GitOps in one paragraph

**In one sentence.** ArgoCD is a controller that watches Git and
continuously makes the cluster look like what it sees there.

**What problem it solves.** In a "kubectl apply from my laptop" world,
Git and cluster state drift. Someone edits a live resource; nobody
knows. The rollback is a scramble to reproduce the last known-good
state. GitOps flips the model: **Git is the desired state, the
cluster is a reflection of it**. Every change is a commit; every
rollback is `git revert`. And a controller enforces it.

**How it works.**

- You define an ArgoCD **`Application`** resource: "watch this
  repo/branch/path, render it (with Helm if needed), and apply it
  to this cluster/namespace."
- ArgoCD polls Git every ~3 minutes (or immediately on webhook).
- It renders whatever's there (raw YAML, Helm, Kustomize) and diffs
  against live cluster state.
- If `syncPolicy.automated: true` is set, it applies the diff.
- If someone `kubectl edit`s a live resource, ArgoCD reverts it on
  the next reconcile (`selfHeal: true`).

**In this repo.**

- Installed as `helm_release.argocd` (Terraform).
- Three `Application` manifests at `argocd/order-service-app.yaml`,
  etc.
- Each one points at `helm/<service>/`, a **Helm chart path in this
  repo**, and passes per-service overrides through a
  `helm.valuesObject` block. Read one of the argocd/*.yaml files —
  it's very readable.
- Terraform applies the Applications themselves via
  `kubectl_manifest` resources in `argocd_apps.tf`. This means the
  Applications are managed by Terraform, but the resources *they*
  create (Deployments, Services, etc.) are managed by ArgoCD.

**The clean division of responsibility.**

| Manages... | ...via... |
| --- | --- |
| AWS infra + Helm platform installs + `Application` CRs | Terraform |
| The three service Deployments, Services, ServiceAccounts | ArgoCD |
| Docker image builds and image-tag bumps in Git | GitHub Actions |

**Common misconceptions.**

- "ArgoCD replaces CI." → No, ArgoCD is CD (continuous **deploy**).
  CI (build the image) is a separate job. GitHub Actions here does
  CI; ArgoCD does CD.
- "ArgoCD deploys straight from your Docker registry." → No, it
  deploys **whatever is in Git**. The workflow updates the image tag
  in Git; ArgoCD then notices and applies. Without a Git change,
  ArgoCD sees no drift.
- "ArgoCD is a UI." → It has a nice UI, but the useful part is the
  controller. The UI is a window into what the controller is doing.

**Deeper reading.** argo-cd.readthedocs.io. Read "Getting Started" and
then "Application Specification."

---

<a id="9-github-actions-role-in-this-world"></a>

## 9. GitHub Actions' role in this world

**In one sentence.** GitHub Actions is our CI: it builds Docker images
and pushes them, then tells ArgoCD (indirectly, via Git) what new tag
to deploy.

**What problem it solves.** ArgoCD doesn't build code. Something has
to turn `git push` into a Docker image that lives in a registry with a
predictable tag. That "something" is a CI system. We chose GitHub
Actions because the repo already lives on GitHub.

**How it works in this repo (`.github/workflows/eks-deploy.yml`).**

Two jobs run on push to `scenario-3`:

**Job 1: `build-and-push`.** For each service:
1. Checkout the repo.
2. Set up Java 21.
3. Log in to ECR.
4. `mvn package` to build the JAR.
5. `docker build` and `docker push` the image. Three tags per image:
   full SHA (auditable), short SHA (used by Helm), `latest` (fallback
   for the first sync).

**Job 2: `update-helm-values`.** After job 1 succeeds:
1. `yq` bumps `image.tag` in `helm/values-prod.yaml` to the short SHA.
2. `git commit --message "chore: update image tags to <sha> [skip ci]"`
   and push.

The `[skip ci]` marker in the commit message tells GitHub Actions **not**
to re-trigger the workflow on that push. Otherwise you'd have an
infinite loop.

**Why not one job?** Two reasons. First, splitting build from
values-bump means a failed build doesn't leave a bad tag in Git.
Second, giving `contents: write` permission only to the second job
follows least-privilege.

**The handoff to ArgoCD.**

```
git push --------> workflow builds ---> ECR has new image
                                    \
                                     -> workflow bumps values.yaml
                                                    \
                                                     -> ArgoCD sees Git changed
                                                                    \
                                                                     -> ArgoCD applies
```

Nothing in this chain is aware of anything else. GitHub Actions
doesn't know about ArgoCD (it just pushes Git). ArgoCD doesn't know
about GitHub Actions (it just watches Git). That decoupling is the
whole point of GitOps.

**Common misconceptions.**

- "GitHub Actions deploys to the cluster." → It doesn't. It builds
  images and updates Git. **ArgoCD** deploys.
- "You could skip the values-bump step and just push tags." → You
  could, but then ArgoCD wouldn't know something changed. ArgoCD
  reacts to **Git changes**, not registry changes.

---

<a id="10-istio--the-service-mesh"></a>

## 10. Istio — the service mesh

**In one sentence.** Istio injects a lightweight proxy next to every
pod, so traffic between services goes through a controlled data plane
where you can enforce mTLS, retries, routing, and observability
without touching application code.

**What problem it solves.** In Scenario 1, we authenticated
inter-service HTTP calls by requiring an `X-Internal-Api-Key` header
on every request. Every service had to remember to send it and
validate it, rotate it, and keep it out of logs. It was brittle.
Istio replaces that with **mutual TLS between every pair of pods**,
enforced by the mesh, with certs that rotate automatically. Your
Spring code keeps sending plain `http://payment-service:8080`. The
sidecar handles security.

**How it works.**

The mesh has two parts:

1. **istiod** — the control plane. One pod (or a few) in
   `istio-system`. Job: issue SPIFFE certificates to workloads,
   configure sidecars.
2. **Envoy sidecars** — a small proxy in every pod. Job: intercept
   all inbound and outbound traffic and enforce mesh policy.

When your Spring app calls `http://payment-service:8080`:

```
your Spring app  ─plain HTTP→  Envoy in same pod (loopback)
                                    │  mTLS with SPIFFE cert
                                    ▼
                                Envoy in payment-service pod
                                    │
                                    ▼  plain HTTP
                              payment-service app
```

Neither app sees TLS. Both Envoys negotiate it, verify each other's
SPIFFE identity, and forward plaintext to the local app.

**How sidecar injection happens.** You label a namespace:

```yaml
metadata:
  name: default
  labels:
    istio-injection: enabled
```

istiod's **mutating admission webhook** watches for new pods in that
namespace and rewrites them to add the sidecar container before they
schedule. Your Deployment YAML doesn't mention Envoy. It just
happens.

**How mTLS gets enforced.** Two policies:

- **`PeerAuthentication`** in `default` with `mode: STRICT` says
  "any pod in this namespace only accepts mTLS traffic."
- **`DestinationRule`** for each service host with
  `tls: { mode: ISTIO_MUTUAL }` says "when a client sidecar sends to
  this host, originate mTLS."

Together: everything in `default` is mTLS'd, and non-mTLS traffic is
rejected.

**In this repo.**

- Installed by two Helm releases in `infrastructure/scenario-3/helm_releases.tf`:
  `helm_release.istio_base` (installs the CRDs) and
  `helm_release.istiod` (installs the control plane).
- Policies in `k8s/istio/peer-authentication.yaml` and
  `k8s/istio/destination-rules.yaml`, applied by Terraform via
  `kubectl_manifest` in `istio_policies.tf`.
- The namespace label applied by Terraform's `kubernetes_labels`
  resource in `istio_policies.tf`.
- The Postgres pod opts *out* of the mesh with
  `sidecar.istio.io/inject: "false"` because Envoy can interfere with
  binary protocols.

**Common misconceptions.**

- "Istio needs an API gateway." → The ingress gateway is one of three
  components (control plane, sidecars, gateway). You can run any
  subset. We run only the first two.
- "Istio replaces your load balancer." → For east-west traffic, sort
  of. For north-south (external), we still use the AWS ALB.
- "Istio is heavy." → istiod is one pod. Each sidecar adds ~100MB and
  a small CPU tax. On a tiny cluster it's noticeable; at scale it
  disappears.

**Deeper reading.** istio.io → Concepts → Security → "Mutual TLS
authentication." Also istio.io/latest/docs/reference/config/networking/
for `DestinationRule` and `VirtualService`.

---

<a id="11-keda--event-driven-autoscaling"></a>

## 11. KEDA — event-driven autoscaling

**In one sentence.** KEDA lets you autoscale a Deployment based on
external metrics (SQS depth, Kafka lag, Redis list length, cron,
custom Prometheus query) — including scaling to zero.

**What problem it solves.** Kubernetes ships with an HPA
(HorizontalPodAutoscaler) that scales on CPU or memory. That's fine
for CPU-bound work. But for a queue worker that sits idle 90% of the
time and needs to burst when work arrives, CPU is a lagging
indicator — by the time your pods are CPU-saturated, your queue
already has a backlog. KEDA scales *on the queue*, not on the
symptom.

**How it works.**

- KEDA runs as a controller in the `keda` namespace.
- You define a **`ScaledObject`** custom resource pointing at a
  Deployment and describing the trigger (which metric, which target
  value).
- Under the hood, KEDA creates a **regular HPA** driven by KEDA's
  metrics-adapter, which polls the external metric on your behalf.
- KEDA also handles the special case of scaling from 0 to 1 (regular
  HPA can't observe metrics on a Deployment with 0 pods; KEDA does
  the polling itself).

**Our specific setup.** In `helm/payment-service/templates/scaledobject.yaml`:

```yaml
spec:
  scaleTargetRef: { name: payment-service }
  minReplicaCount: 0                # scale to zero when idle
  maxReplicaCount: 5
  cooldownPeriod: 30                # 30s idle → scale down
  triggers:
    - type: aws-sqs-queue
      authenticationRef: { name: payment-service-aws }
      metadata:
        queueURL:      https://sqs.us-east-1.amazonaws.com/…/order-events
        queueLength:   "5"           # target: 5 msgs per replica
        awsRegion:     us-east-1
        identityOwner: pod            # borrow the pod's IRSA
```

Semantics: "keep enough pods to process 5 msgs each. If the queue has
12 messages, ceil(12/5) = 3 pods."

**How it authenticates to SQS.** This is the pretty part. KEDA doesn't
hold AWS credentials. `podIdentity.provider: aws` +
`identityOwner: pod` mean **KEDA borrows the target pod's IRSA role**
(payment-service's role, which already has SQS read permissions).
Zero secrets.

**In this repo.**

- Installed as `helm_release.keda` in `infrastructure/scenario-3/helm_releases.tf`.
- Templates in `helm/payment-service/templates/scaledobject.yaml` and
  `triggerauthentication.yaml`, both gated on
  `.Values.autoscaling.keda.enabled` (off in local, on in prod).
- order-service publishes to the queue in
  `order-service/…/OrderEventPublisher.java` after the transaction
  commits.

**Common misconceptions.**

- "KEDA replaces HPA." → No, KEDA drives HPA. You still get all of
  HPA's scale-down protections (stabilization windows, behavior
  policies).
- "KEDA polls SQS constantly from every pod." → The KEDA operator
  polls, not the pods. You configure the poll interval globally.
- "Scale-to-zero is free." → Great when the workload is bursty. Bad
  if cold-start latency (JVM boot + Envoy sidecar + readiness) is
  worse than paying for one warm pod. Know your latency budget.

**Deeper reading.** keda.sh, especially the SQS scaler docs.

---

<a id="12-kube-prometheus-stack--metrics"></a>

## 12. kube-prometheus-stack — metrics

**In one sentence.** A Helm chart that bundles Prometheus, Grafana,
Alertmanager, kube-state-metrics, and node-exporter — the four things
you always end up installing together — plus sensible defaults.

**What each component does.**

- **Prometheus** — scrapes metric endpoints on a schedule, stores
  time-series in-cluster. Everything else queries it.
- **Grafana** — the dashboard UI. Talks to Prometheus (or other
  sources) and renders graphs.
- **Alertmanager** — receives alerts from Prometheus rules and
  routes them (Slack, PagerDuty, email, ...).
- **kube-state-metrics** — turns Kubernetes API state
  (pod status, deployment replicas, etc.) into Prometheus metrics.
- **node-exporter** — one pod per node, exposes node-level metrics
  (CPU, memory, disk, network).

**How our apps become scrape targets.** Two things:

1. **Micrometer + actuator** in the Spring app. `management.endpoints.web.exposure.include: prometheus`
   exposes `/actuator/prometheus` in OpenMetrics format. JVM,
   HTTP, JDBC, Hikari, and business metrics all appear there for
   free.
2. **Pod annotations** rendered by our Helm chart:
   ```yaml
   annotations:
     prometheus.io/scrape: "true"
     prometheus.io/port:   "8080"
     prometheus.io/path:   "/actuator/prometheus"
   ```

**In this repo.** Installed as
`helm_release.kube_prometheus_stack` in
`infrastructure/scenario-3/helm_releases.tf`. Two important values:

```hcl
set { name = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues",     value = "false" }
set { name = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues", value = "false" }
```

By default Prometheus only scrapes PodMonitor / ServiceMonitor
resources that carry a label naming the Helm release. This is fine
for multi-tenant clusters (avoids one Prometheus stealing another
team's targets) but annoying for a single-tenant one — you'd have to
remember the label. Setting these to `false` means any monitor in any
namespace is picked up.

**Common misconceptions.**

- "Grafana stores data." → It doesn't. Grafana queries Prometheus (or
  other data sources) live. If Grafana crashes, no data is lost.
  That's why we turned persistence off — restarting Grafana loses
  saved dashboards, but for a learning cluster that's fine.
- "Prometheus is a database." → Sort of. It's a *time-series*
  database, optimized for numeric metrics. Don't put logs or events
  in it.
- "Metrics are the whole story." → No. Metrics are aggregates; you
  lose per-request information. Logs and traces fill in what metrics
  can't.

**Deeper reading.** prometheus.io/docs, grafana.com/docs.

---

<a id="13-fluentbit--cloudwatch--logs"></a>

## 13. FluentBit + CloudWatch — logs

**In one sentence.** FluentBit runs one pod per node, reads every
container's stdout/stderr from the node's filesystem, enriches with
Kubernetes metadata, and ships to CloudWatch Logs.

**Why per-node (DaemonSet)?** Container stdout in Kubernetes is
written by kubelet to files under `/var/log/containers/` on each
node. To read them, you need a pod running on that node. A **DaemonSet**
guarantees exactly one pod per node — no matter how many nodes join or
leave. Perfect for host-level agents.

**Why FluentBit and not Fluentd or CloudWatch agent?** FluentBit is
the smaller, faster cousin of Fluentd, written in C. AWS ships a
prebuilt image (`public.ecr.aws/aws-observability/aws-for-fluent-bit`)
with the CloudWatch plugin built in. It's the recommended log shipper
for EKS.

**The pipeline.**

```
kubelet writes /var/log/containers/*.log
        │
        ▼
FluentBit
  input:  tail          reads log files
  filter: kubernetes    adds pod/namespace/label metadata
  filter: parser json   parses JSON log lines from our services
  output: cloudwatch_logs
        │
        ▼
CloudWatch Logs
  log group:   /eks/ms-learning
  log stream:  pod/<pod-name>
```

**In this repo.**

- Installed as `helm_release.fluentbit` in
  `infrastructure/scenario-3/fluentbit.tf` using the official
  `aws-for-fluent-bit` chart.
- IRSA role in `infrastructure/scenario-3/irsa.tf`
  (`module.fluentbit_irsa`) with `logs:CreateLogGroup`,
  `CreateLogStream`, `PutLogEvents`, `DescribeLogStreams` on `*`.
- The chart handles the DaemonSet, ConfigMap, and ServiceAccount
  boilerplate — we just supply the output config
  (`cloudWatchLogs.logGroupName = /eks/ms-learning`, etc.).

**Why the log group is auto-created.** `autoCreateGroup: true` in the
FluentBit config. On first log push, FluentBit calls
`logs:CreateLogGroup`. IRSA lets it.

**Common misconceptions.**

- "Kubernetes ships logs to CloudWatch." → It doesn't. Kubernetes
  writes to node-local files. Something *else* (FluentBit here) has
  to ship them.
- "Logging with FluentBit is complicated." → The config is dense but
  the model is simple: input → filter chain → output. Read the config
  block by block.

**Deeper reading.** docs.fluentbit.io. Also
docs.aws.amazon.com/AmazonCloudWatch/latest/logs/ContainerInsights.html.

---

<a id="14-opentelemetry--traces-and-the-mdc-trick"></a>

## 14. OpenTelemetry — traces (and the MDC trick)

**In one sentence.** The OpenTelemetry Java agent auto-instruments
your Spring app (Spring MVC, WebClient, JDBC, Hibernate, and dozens
more) to emit spans and metrics, without touching your code.

**What problem it solves.** A single API request touches all three of
your services (order → user, order → payment). Log lines from all
three are useful, but without a **trace id** that connects them, you
can't reconstruct what happened. Distributed tracing is that missing
context.

**How it works.**

- The agent is a JAR (~30 MB) attached to the JVM at startup with
  `-javaagent:opentelemetry-agent.jar`.
- On startup, it uses bytecode instrumentation to wrap common
  libraries. Any Spring MVC controller now creates a span. Any
  WebClient call now creates a client span and injects W3C
  `traceparent` headers. Any JDBC query creates a span.
- The agent propagates the trace context across HTTP calls
  automatically, so all three services share one trace id per
  request.
- The agent writes the current trace id and span id into **SLF4J
  MDC** as `trace_id` and `span_id`, which your `logback-spring.xml`
  pattern includes: `[%X{trace_id:-},%X{span_id:-}]`. Every log line
  now carries the trace id. Grep by it in CloudWatch and you see
  every log line from every service for that request.

**How the agent lands in the pod.** We use an **initContainer** in
the Helm chart:

```yaml
initContainers:
  - name: otel-agent-downloader
    image: curlimages/curl:8.10.1
    command:
      - sh
      - -c
      - |
        curl -fsSL -o /agents/opentelemetry-agent.jar \
          "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.10.0/opentelemetry-javaagent.jar"
    volumeMounts:
      - { name: otel-agent, mountPath: /agents }
```

The main container mounts the same `emptyDir` volume, and the JVM
starts with `JAVA_TOOL_OPTIONS=-javaagent:/agents/opentelemetry-agent.jar`.

**Traces need somewhere to go.** The agent exports spans to whatever
`OTEL_EXPORTER_OTLP_ENDPOINT` points at. Ours points at
`http://otel-collector.observability.svc.cluster.local:4318`, which
doesn't exist yet — spans are dropped. Metrics (via Prometheus) and
logs (via FluentBit) work today; adding an OTel Collector + Jaeger or
Tempo backend is the next observability step.

**In this repo.**

- Init container in every Helm chart's
  `templates/deployment.yaml`.
- `logback-spring.xml` in each service with the trace_id pattern.
- Env var in `values-prod.yaml`
  (`OTEL_EXPORTER_OTLP_ENDPOINT`) pointing where a collector *would*
  run.

**Common misconceptions.**

- "You have to add tracing code." → No. Auto-instrumentation covers
  99% of what you need. Manual spans are only for custom business
  logic you want to see in traces.
- "Traces replace logs." → Complementary. Logs give you free-text
  detail; traces give you the shape of the call graph.

**Deeper reading.** opentelemetry.io/docs/languages/java/automatic.

---

<a id="15-bitnami-postgres--running-a-stateful-app-on-kubernetes"></a>

## 15. Bitnami Postgres — running a stateful app on Kubernetes

**In one sentence.** We run Postgres in the cluster instead of paying
for RDS, backed by an EBS volume provisioned automatically.

**Why not RDS?** For a learning environment, RDS is $15+/mo per
instance and adds a whole other set of resources to manage. Running
Postgres in-cluster costs pennies (just the EBS volume) and demonstrates
the whole stateful-workload story: PVCs, PVs, CSI drivers, and
StatefulSets. For a real production workload, use RDS.

**The moving parts.**

- **StatefulSet** — like a Deployment, but each pod has a stable
  identity and stable storage. The Bitnami chart creates one.
- **PersistentVolumeClaim (PVC)** — the pod says "I need 8 Gi of
  storage."
- **PersistentVolume (PV)** — the actual storage. Not pre-created;
  the **EBS CSI driver** provisions one on demand.
- **StorageClass** — describes how PVs should be provisioned (which
  CSI driver, which parameters). EKS has a default StorageClass
  called `gp2`.

The flow when the Postgres pod starts:

```
StatefulSet -> creates PVC "data-postgres-0"
                                │
                                ▼
                     ebs-csi-driver sees the PVC
                                │
                                ▼
                     ec2:CreateVolume  (via its IRSA role)
                                │
                                ▼
                     PV bound, EBS volume attached to node
                                │
                                ▼
                     Pod mounts it at /bitnami/postgresql/data
                                │
                                ▼
                     Postgres init scripts run on first boot
                                │
                                ▼
                     CREATE DATABASE order_db;
                     CREATE DATABASE payment_db;
```

Every dependency in that chain is something we set up earlier. The
EBS CSI driver needed its own IRSA role (§7 + the "war stories"
chapter of `scenario3.md`).

**Why we opt out of the Istio mesh.** Postgres speaks a binary wire
protocol on port 5432. Envoy is happy to proxy TCP, but has known
issues with Postgres-specific negotiations (like `SSLRequest`). We
opt the Postgres pod out with:

```yaml
podAnnotations: { "sidecar.istio.io/inject": "false" }
```

The apps in `default` still have their sidecars and still enforce
mTLS between each other. Only the Postgres pod is excluded.

**In this repo.** `helm_release.postgres` in
`infrastructure/scenario-3/helm_releases.tf`. Look at the `values`
block — it's the entire configuration.

**Common misconceptions.**

- "Databases don't belong on Kubernetes." → Twenty years ago,
  probably true. Now with CSI drivers, operators like
  CloudNativePG/Zalando, and mature StatefulSet semantics, it's
  perfectly viable. For a *learning* cluster it's ideal — but for
  production, RDS or Aurora is still the safer default.
- "The Postgres pod loses data when it restarts." → No. The PVC and
  the EBS volume it binds outlive the pod. StatefulSet's stable
  identity means the same volume is remounted on the same pod name.

**Deeper reading.** kubernetes.io/docs → Concepts → Storage. Also
the Bitnami postgresql chart README.

---

<a id="16-how-they-cooperate-one-request-end-to-end"></a>

## 16. How they cooperate: one request, end to end

Let's trace a `POST /api/orders` through the whole stack. Every named
tool from earlier plays a role.

1. **User hits `orders.example.com`.** Route 53 resolves to the AWS
   ALB (once you enable Ingress + Cognito).
2. **The ALB** was provisioned by the **AWS Load Balancer Controller**
   because you created an `Ingress` in the order-service Helm chart.
3. **The ALB terminates TLS**, does Cognito authentication, then
   forwards to the order-service pod's IP directly (via `target-type:
   ip`).
4. **The request hits port 8080 of the pod.** Actually — iptables in
   the pod's netns redirects it through the **Envoy sidecar** (Istio).
   Envoy has no external TLS to terminate here (that was the ALB's
   job) so it hands plain HTTP to the app.
5. **`OrderController.createOrder()` runs.** Spring MVC creates a
   trace span (the **OpenTelemetry agent** instrumented it). MDC now
   has `trace_id`.
6. **The handler calls `userServiceClient.findById()`.** The
   WebClient call is intercepted by Envoy in the order-service pod,
   upgraded to **mTLS** (Istio DestinationRule), routed to the
   user-service pod's Envoy, decrypted, delivered to the user-service
   app.
7. **user-service reads DynamoDB.** The DynamoDB call goes through
   the AWS SDK, which finds **IRSA** env vars, exchanges them for
   temporary credentials via STS, and makes the DynamoDB API call as
   the `ms-learning-eks-user-service` role.
8. **user-service returns.** Response travels back through the mesh
   to order-service.
9. **order-service opens a Postgres transaction.** The JDBC call goes
   to `postgres.default.svc.cluster.local:5432`. Kubernetes DNS
   resolves that name to the Bitnami Postgres pod's ClusterIP.
   Postgres persists the row on the EBS volume mounted at
   `/bitnami/postgresql/data`.
10. **Transaction commits. Order-service publishes an
    `OrderCreatedEvent` to SQS.** `SqsAsyncClient` uses **IRSA** to
    call `sqs:SendMessage`.
11. **KEDA is polling SQS every 30 seconds.** It sees the queue depth
    tick to 1 and scales `payment-service` from 0 to 1.
12. **A payment-service pod boots.** OpenTelemetry initContainer
    downloads the agent, the JVM starts, probes pass. It'll dequeue
    the message (once a consumer exists in the code).
13. **Meanwhile order-service calls payment-service over mTLS** for
    the synchronous part of the SAGA.
14. **payment-service writes to `payment_db` in the same Postgres
    pod.**
15. **All log lines** from every pod are tailed by **FluentBit** on
    each node, enriched with pod metadata, shipped to CloudWatch
    Logs under `/eks/ms-learning`. Each line carries the `trace_id`
    from step 5, so a `filter @message like /<trace_id>/` in
    CloudWatch Logs Insights shows the whole request's story across
    all three services.
16. **Every pod's `/actuator/prometheus`** endpoint is scraped every
    15 seconds by **Prometheus**. Grafana renders those metrics in
    dashboards.

Zero application code cared about steps 3, 4, 6, 7, 10, 11, 15, or
16. That's what "platform" means.

---

<a id="17-common-misconceptions"></a>

## 17. Common misconceptions

A collected list of things people (including past me) get wrong when
learning this stack.

**"kubectl apply is how you deploy."** Only for one-off changes. In
GitOps, ArgoCD does the applying. Your job is `git commit`.

**"Helm and Kustomize are alternatives."** They solve overlapping
problems but different in style. Helm templates YAML with Go
templating; Kustomize layers patches over base YAML. Both work.
Pick one per project.

**"Terraform manages Kubernetes badly."** Terraform manages
Kubernetes *installation* well (Helm releases, CRDs, one-shot
manifests). It manages *application* Deployments poorly because it
doesn't do continuous reconciliation. That's what ArgoCD is for. Use
each for what it's good at.

**"The service mesh replaces Kubernetes networking."** No. Envoy
sidecars sit on top of Kubernetes networking. Traffic still uses
Kubernetes DNS + kube-proxy + iptables. The mesh just adds a layer of
encryption and observability.

**"IRSA is optional if you use IAM instance profiles."** Instance
profiles give *every pod on that node* the same permissions.
Blast radius is the whole node. IRSA scopes credentials to a
specific ServiceAccount, i.e., specific pods. Always use IRSA in
EKS.

**"kube-prometheus-stack scrapes everything by default."** It scrapes
its own operator-managed CRDs (`PodMonitor`, `ServiceMonitor`) that
carry the right labels. We deliberately turned off the label
requirement (`podMonitorSelectorNilUsesHelmValues: false`) so any
monitor in any namespace works.

**"CRDs are Kubernetes extending itself."** Yes exactly — a CRD
(CustomResourceDefinition) is a new API object type. Every tool
here (Istio, ArgoCD, KEDA, Prometheus Operator) ships CRDs and their
controllers. The controller is what makes the objects *do*
something.

**"Docker Compose ≈ Kubernetes."** Superficially, because both
describe multi-container systems. Fundamentally different: Compose
runs on one host, has no reconciliation, no service discovery beyond
Docker's DNS, no autoscaling, no health-based rescheduling. Kubernetes
is closer to a cloud in a box than to Docker in a box.

**"Envoy in the sidecar is your app's proxy — you can bypass it."**
Not easily. Istio uses iptables in the pod's netns to redirect
localhost traffic through Envoy. If you send to `localhost:5432`
inside the pod, Envoy sees it. Opt-out is per-pod with the
`sidecar.istio.io/inject: "false"` annotation (like Postgres).

---

<a id="18-dashboards-and-uis"></a>

## 18. Dashboards and UIs — what you're actually looking at

You've seen the platform tools. Each of them either ships a UI or has
a companion dashboard people install alongside it. When someone on
YouTube says *"this is how our cluster looks,"* they're almost always
in one of the four places below. All four are separate applications
— they don't replace each other, they complement each other, and
you'll flip between them depending on the question you're asking.

### 16.1 k9s — the terminal UI

**In one sentence.** k9s is a full-screen terminal application that
wraps `kubectl` with a keyboard-driven, live-updating interface.

**Why people love it.** `kubectl get pods -w` is fine once. Typing
`kubectl -n default logs -f my-pod-abc123 -c istio-proxy` fifty times
a day is not fine. k9s replaces all of that with a few keystrokes:
`:pods` to see pods, arrow keys to select one, `l` for logs, `s` for
shell, `d` for describe, `<esc>` to go back. It refreshes every two
seconds so you're always seeing live state.

**What it isn't.** Not a dashboard in the "graph and metric" sense.
It's a **navigation tool** — think Norton Commander for Kubernetes.
No pretty charts, no cross-cluster view, no history. Just fast
kubectl.

**Install.** It's a laptop tool, not a cluster tool. Nothing to
deploy: `brew install k9s` on macOS (`k9scli.io` has other installers).
It reads your existing `~/.kube/config` and shows whichever cluster
your current context points at.

**In this repo.** Nothing to install cluster-side. It's just a client.
The moment your kubeconfig points at `ms-learning-eks`, k9s works.

**When you'd use it.**

- "Which of my pods is CrashLoopBackOff?" — one screen, colored by
  status.
- "Tail logs from a pod while it's rolling out." — three keystrokes.
- "Exec into a pod." — one keystroke.
- "Kill a stuck pod." — `ctrl+d`, confirm.

**Common misconceptions.**

- *"k9s is another kubectl."* — Not exactly. It calls kubectl (well,
  the same client-go library) under the hood, but the workflow is
  different enough that muscle memory transfers slowly. Give it a
  week.
- *"It replaces Grafana."* — No. It shows you Kubernetes API state,
  not metrics or logs at scale.

**Deeper reading.** k9scli.io. The included tutorial is genuinely
good.

### 16.2 ArgoCD UI — the GitOps window

**In one sentence.** A web application, installed as part of the
ArgoCD Helm release, that visualizes each `Application` as a tree of
managed Kubernetes resources with sync + health status colored in.

**Why people show it off.** You get one screen that answers three
questions at a glance:

1. *Are all my apps in sync with Git?* (Big green/yellow/red tiles.)
2. *For app X, what does its deployment look like?* (A drill-down
   tree: Application → Deployment → ReplicaSet → Pod → Service →
   Ingress.)
3. *Why is app X unhealthy?* (Click the red node; get events, YAML,
   and logs inline.)

You can also **click "Sync" or "Rollback"** from the UI — same as
`kubectl` behind the scenes, but you can see what you're about to
do.

**How it works.** The UI is just a web app talking to the ArgoCD API
server, which is the same process that runs the reconciliation loop.
The UI is a window into the same controller that's actually doing the
work — nothing happens *because* of the UI; the UI shows what the
controller has been doing.

**In this repo.**

- Installed as part of `helm_release.argocd` in
  `infrastructure/scenario-3/helm_releases.tf`.
- The three cards you'll see (order-service, payment-service,
  user-service) come from the `Application` manifests in
  `argocd/*.yaml` that Terraform applies via `argocd_apps.tf`.

**Getting in.** Two things: port-forward the service (`argocd` ns,
`svc/argocd-server`, target port `443` → local `8080`) and read the
initial admin password out of the `argocd-initial-admin-secret`
Secret. Both commands live in `scenario3.md` §16 if you need to look
them up later.

**When you'd use it.**

- "Why is my deployment stuck?" — top of the list for GitOps
  troubleshooting.
- Showing someone else the deploy state without granting them
  kubectl access.
- Manually triggering a re-sync when the polling loop feels too slow.
- Viewing sync history for compliance / audit.

**Common misconceptions.**

- *"The UI is where you configure ArgoCD."* — Not really. All
  configuration lives in the `Application` YAML in Git (managed by
  Terraform for us). The UI is read-mostly plus a couple of buttons.
- *"If I click Sync in the UI, that's how deploys happen."* —
  Deploys happen *automatically* because
  `syncPolicy.automated: { prune: true, selfHeal: true }` is set on
  our Applications. The Sync button is manual override for edge
  cases.

**Deeper reading.** argo-cd.readthedocs.io → "User Interface." Also
Codefresh has a lot of ArgoCD content on YouTube.

### 16.3 Kiali — the service mesh dashboard

**In one sentence.** Kiali is a web UI that turns Istio's mesh
telemetry into a live topology graph: which service talks to which,
at what rate, with what error percent, over mTLS or not.

**Why people show it off.** It's the most visually striking dashboard
in this list. When traffic is flowing, the edges of the graph
literally *animate*. Errors show in red. mTLS connections have a
padlock. You can zoom into a service and see its inbound and outbound
neighbors, their latency percentiles, and their success rates.
Someone asked *"how does data flow in your system?"* — you show
them Kiali.

**How it works.** Kiali doesn't collect data itself. It reads:

1. **Istio proxy metrics from Prometheus** — the sidecars we already
   have publish `istio_requests_total`, `istio_request_duration_seconds`,
   etc. Kiali queries Prometheus for these.
2. **Trace data from Jaeger** — for click-through from a specific
   graph edge to the actual traces on that edge.
3. **Kubernetes API + Istio CRDs** — to know what services and
   `VirtualService`s / `DestinationRule`s exist.

Then it composes the topology and renders it in the UI.

**In this repo.** **Not installed.** It's an add-on. To add:

- One more `helm_release "kiali"` in Terraform, using the
  `kiali/kiali-server` chart from the `kiali.io` repo.
- Configure the chart to point at our Prometheus service
  (`kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`)
  and optionally at a Jaeger endpoint (which we don't have yet — see
  §18.4).
- Port-forward `kiali` service to reach the UI. Same pattern as
  ArgoCD.

**When you'd use it.**

- Answering "who calls who in my system." A single-glance
  architecture diagram.
- Investigating "which service is failing." Red edges point at the
  problem.
- Verifying mTLS is actually happening between services — Kiali
  shows a padlock icon on secured edges.
- Watching a canary rollout live (Kiali overlays traffic percentages
  per version).

**Common misconceptions.**

- *"Kiali replaces Grafana."* — Complementary. Kiali is
  **topology-shaped**: services and edges. Grafana is
  **metric-shaped**: time series and dashboards. They both read from
  Prometheus.
- *"Kiali works on any cluster."* — Only if you have Istio.
  Without a mesh there's no data for Kiali to render.
- *"Kiali stores traffic data."* — No, it queries live from
  Prometheus. Data retention is whatever your Prometheus retention
  is.

**Deeper reading.** kiali.io/docs. The "Traffic Graph" and
"Applications, Services and Workloads" sections are the ones to
start with.

### 16.4 Jaeger — the distributed trace viewer

**In one sentence.** Jaeger is a UI (plus a storage backend) that
displays a single request's journey across services as a waterfall
of timed spans.

**Why people show it off.** Metrics tell you *"P99 latency spiked at
2:14 PM."* Logs tell you *"there was an error message."* Traces tell
you *"for this specific slow request, order-service spent 30ms
calling user-service which spent 12ms calling DynamoDB which returned
in 8ms — the extra 200ms was in Hibernate's flush before commit."*
Traces show you the shape of one request, not aggregates.

**What you see.** For a chosen request:

- A flame graph / waterfall diagram — one horizontal bar per span,
  colored by service, laid out on a time axis.
- A tree view: parent → children spans, with tags (HTTP method, URI,
  DB statement, HTTP status).
- Search box: find traces by service, operation name, tags, duration
  range.

**How it works.**

1. Your app emits **spans** — small structured records saying "I did
   operation X, started at t=..., duration Y, tagged with Z." The
   **OpenTelemetry Java agent** we install produces these
   automatically.
2. Spans go to a **collector** (the OpenTelemetry Collector is the
   modern choice), which forwards them to Jaeger's backend.
3. **Jaeger backend** stores them (in-memory for dev, Cassandra or
   Elasticsearch for prod).
4. **Jaeger UI** queries the backend.

**In this repo.** **Not installed.** We have the OTel agent running
in every pod (§14), but the export destination it's configured with
(`http://otel-collector.observability.svc.cluster.local:4318`) points
at nothing. Spans are currently dropped. To actually see traces:

- Install an **OpenTelemetry Collector** (Helm chart:
  `open-telemetry/opentelemetry-collector`) in an `observability`
  namespace. Configure it to receive OTLP and export to Jaeger.
- Install **Jaeger** (Helm chart: `jaegertracing/jaeger`). For a
  learning cluster, its `allInOne` mode with in-memory storage is
  perfect.
- Point the OTel Collector at Jaeger's OTLP endpoint.
- Port-forward the Jaeger UI service.

Roughly a half-day of setup. The end result is that our
`OTEL_EXPORTER_OTLP_ENDPOINT` env var (already set in
`helm/values-prod.yaml`) starts having somewhere to send data.

**When you'd use it.**

- "This one request was slow. Why?" — the exact question traces
  answer.
- Understanding *unexpected* call paths. ("Wait, why did creating an
  order call the users table three times?")
- Debugging retries and timeouts across service boundaries.

**Common misconceptions.**

- *"Traces replace logs."* — Complementary. Traces are structured,
  cheap to search, but sampled (you keep 1-10% of them in
  production). Logs are unstructured, expensive to search, but
  complete. You want both.
- *"Jaeger is Kubernetes-specific."* — Not at all. Jaeger predates
  the OTel Collector; it works on VMs, bare metal, anywhere.
- *"OpenTelemetry means you must use Jaeger."* — No, OTel is the
  **protocol** and **instrumentation** layer. Any OTel-compatible
  backend works: Jaeger, Grafana Tempo, Honeycomb, Lightstep, Datadog
  APM, Dynatrace, AWS X-Ray. Jaeger is the classic open-source
  choice.

**Deeper reading.** jaegertracing.io/docs. The
"Architecture" page is the one to read to understand the
collector-to-backend split.

### 16.5 So which of these do I install next?

For a learning cluster, in this order:

1. **k9s on your laptop.** Zero cost, immediate payoff. Install today.
2. **ArgoCD UI is already there.** Just port-forward and log in. You
   don't need to install anything.
3. **Grafana dashboards from grafana.com.** Import a JVM Micrometer
   dashboard (ID `4701`) into the Grafana you already have. Five
   minutes of work, huge visual payoff.
4. **Kiali.** Add once your apps are actually running and generating
   inter-service traffic. Otherwise the topology graph will be
   empty and unimpressive.
5. **Jaeger + OTel Collector.** Add when metrics + logs stop being
   enough — usually when you need to answer "why was *this specific*
   request slow."

Each one is optional. None of them changes how your cluster runs.
They're all *observability into* what your cluster is doing, and the
value of adding one depends entirely on which questions you find
yourself asking most often.

---

<a id="19-where-to-go-deeper"></a>

## 19. Where to go deeper

You don't need to master any of these. But when you have a specific
question, know which doc site to search.

| Tool | Home | The best chapter to start with |
| --- | --- | --- |
| Kubernetes | kubernetes.io/docs | Concepts → Workloads → Pods, Deployments, Services |
| Helm | helm.sh/docs | Chart Template Guide |
| Terraform | developer.hashicorp.com/terraform | Configuration Language + AWS provider docs |
| EKS | docs.aws.amazon.com/eks | Getting Started, then "IAM roles for service accounts" |
| AWS Load Balancer Controller | kubernetes-sigs.github.io/aws-load-balancer-controller | Ingress specifications |
| Istio | istio.io/docs | Concepts → Security → Mutual TLS |
| ArgoCD | argo-cd.readthedocs.io | Getting Started + Application Specification |
| GitHub Actions | docs.github.com/actions | Workflow syntax + reusable workflows |
| KEDA | keda.sh | Scalers → AWS SQS Queue |
| Prometheus | prometheus.io/docs | Concepts + PromQL basics |
| Grafana | grafana.com/docs | Fundamentals |
| FluentBit | docs.fluentbit.io | Data Pipeline → Inputs / Filters / Outputs |
| OpenTelemetry | opentelemetry.io/docs | Languages → Java → Auto-instrumentation |
| Bitnami charts | charts.bitnami.com | Each chart's README |
| k9s | k9scli.io | The bundled tutorial |
| Kiali | kiali.io/docs | Traffic Graph + Applications, Services and Workloads |
| Jaeger | jaegertracing.io/docs | Architecture |

And two books that are genuinely worth the money if you want to go
deep:

- **"Kubernetes: Up and Running"** (Burns et al., O'Reilly) — the
  best 200-page introduction to the *concepts*.
- **"Cloud Native DevOps with Kubernetes"** (Arundel & Domingus,
  O'Reilly) — how these tools compose in production. Old-ish but the
  patterns still hold.

---

**One last thing.** You are not expected to have this memorized.
Nobody does. The way people work with this stack is: **learn the
shape, then look things up.** Being able to say "oh right, that's a
Helm thing, and Helm charts have templates and values" is 80% of the
skill. The rest is `helm --help` and doc-searching.

Ask me any section that isn't landing and I'll rewrite it.
