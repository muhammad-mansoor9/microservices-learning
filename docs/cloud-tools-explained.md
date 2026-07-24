# Terraform, Ansible, and Jenkins — A Developer's Guide

This document explains what each tool does, what every file in this project does,
and when each file is used. Written for someone who knows application code well but
is new to infrastructure.

---

## The Mental Model First

As an application developer you write code, compile it, and run it. The cloud
equivalent of that is:

| Application world | Cloud world |
|---|---|
| Code defines behaviour | **Terraform** defines what infrastructure exists |
| Compile / package | **Jenkins** builds and packages the application |
| Run / deploy | **Ansible** installs and starts the application on servers |

The three tools never overlap. Terraform creates the servers. Ansible configures them.
Jenkins orchestrates the whole thing by calling Ansible after a build.

---

## Part 1 — Terraform

### What Terraform is

Terraform is a tool that creates and manages cloud infrastructure by reading
configuration files you write. You describe what you want ("I want an EC2 instance
with this type, in this subnet, with this security group") and Terraform figures out
how to create it, what order to create it in, and what to do when you change or
delete it.

The key concept is **declarative infrastructure**: you describe the desired end state,
not the steps to get there. You don't write "log in to AWS, go to EC2, click Launch,
fill in this form". You write a resource block, run `terraform apply`, and Terraform
calls the AWS API for you.

**State file**: Terraform keeps a file called `terraform.tfstate` that records what it
has created. Every time you run `terraform apply`, it compares your config files
against the state file and only changes what is different. This is how it knows whether
to create a new EC2 instance or update an existing one.

**Providers**: Terraform doesn't know about AWS natively. It downloads a provider
plugin (in this case `hashicorp/aws`) that knows how to talk to the AWS API. That's
why you need `terraform init` before anything — it downloads the provider.

### The Terraform files in this project

All infrastructure files live in `infrastructure/scenario-1/`.

---

#### `provider.tf`

This is the entry point for Terraform. It does three things:

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    key = "scenario1/terraform.tfstate"
  }
}
```

**`required_version`** — Enforces that you're running Terraform 1.5 or newer.
If someone on your team has an older version, they get a hard error instead of silent
breakage.

**`required_providers`** — Tells Terraform to download the official AWS provider at
version 5.x. The `~> 5.0` means "5.x but not 6.0", so you get bug fixes but no
breaking upgrades.

**`backend "s3"`** — By default Terraform stores `terraform.tfstate` on your local
disk. That breaks as soon as two people work on the same infrastructure because each
person has a different local copy. The `backend "s3"` block tells Terraform to store
the state file in an S3 bucket instead. The bootstrap module (`infrastructure/bootstrap/`)
is what creates that S3 bucket and the DynamoDB table for state locking (so two people
can't run `terraform apply` at the same time).

```hcl
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null
  default_tags {
    tags = { Project = "ms-learning", Scenario = "ec2" }
  }
}
```

**`default_tags`** — Every resource Terraform creates automatically gets these tags.
That's why when Ansible queries AWS for "instances with tag Project=ms-learning" it
finds all the right servers.

**Variables** — `var.aws_region`, `var.my_ip`, `var.db_password` are declared in
this file. Terraform prompts you for `my_ip` and `db_password` at `terraform apply`
time because they have no default values. `aws_region` defaults to `us-east-1`.

---

#### `vpc.tf`

Defines the network. Think of a VPC as your private data centre inside AWS.
Everything lives inside it and can talk to each other. Nothing outside can get in
unless you explicitly open a door.

```
VPC: 10.0.0.0/16  (65,536 possible IP addresses)
│
├── public-a:  10.0.1.0/24  (256 IPs, AZ us-east-1a)
├── public-b:  10.0.2.0/24  (256 IPs, AZ us-east-1b)
├── private-a: 10.0.3.0/24  (256 IPs, AZ us-east-1a)
└── private-b: 10.0.4.0/24  (256 IPs, AZ us-east-1b)
```

**Public subnets** — Instances here get a public IP and can receive traffic from the
internet (via the Internet Gateway). Your service instances, Jenkins, and the
monitoring EC2 live here.

**Private subnets** — Instances here have NO public IP. They cannot be reached from
the internet. Eureka, Config Server, RabbitMQ, and Keycloak live here because they
should never be publicly accessible. They can still reach the internet outbound (to
download packages) via the NAT Gateway.

**Internet Gateway** — The door between your VPC and the internet. Without this,
nothing in your VPC can reach the outside world and nobody can reach it from outside.

**NAT Gateway** — Sits in public-a. Lets private-subnet instances send outbound
traffic to the internet (e.g., to download a Java package) without being reachable
inbound. Think of it as a one-way door for private instances.

**Route tables** — Rules that say "for traffic going to 0.0.0.0/0 (the internet), use
the Internet Gateway" (public route table) or "use the NAT Gateway" (private route
table). Without route tables, subnets can't talk to anything outside themselves.

---

#### `security_groups.tf`

Security groups are virtual firewalls attached to instances. Every connection to or
from an instance is checked against the rules in its security group.

This project has five security groups:

**`ms-learning-alb-sg`** — Applied to the Application Load Balancer.
- Allows inbound HTTP (port 80) and HTTPS (port 443) from anywhere (0.0.0.0/0).
- This is intentional — the ALB is the public entry point.

**`ms-learning-app-sg`** — Applied to all 6 service EC2 instances and the 2 private
infrastructure instances (Eureka, Config Server).
- Inbound ports 8080–8888 from the ALB SG — so the ALB can forward requests to
  api-gateway on port 8080.
- SSH on port 22 from the Jenkins SG — so Jenkins can run Ansible against them.
- SSH on port 22 from `var.my_ip` — so you can SSH in manually for debugging.
- Self-referencing rule (all traffic from itself) — this is the critical rule that lets
  services call each other. When order-service calls user-service, both have `app-sg`.
  The self-referencing rule allows any traffic between instances in the same group.
- Inbound 8080–8888 from the monitoring SG — so Prometheus can scrape `/actuator/prometheus`.

**`ms-learning-infra-sg`** — Applied to RabbitMQ and Keycloak.
- Inbound port 5672 (RabbitMQ AMQP) from `app-sg` — services can publish/consume messages.
- Inbound port 9090 (Keycloak HTTP) from `app-sg` — services can validate JWT tokens.
- Inbound port 8761 (Eureka) from `app-sg` — services can register and discover each other.
- SSH from Jenkins SG — Ansible can configure them.

**`ms-learning-jenkins-sg`** — Applied to Jenkins.
- Inbound port 8080 (Jenkins UI) from `var.my_ip` — only you can access the Jenkins web UI.
- SSH from `var.my_ip` — only you can SSH into Jenkins.

**`ms-learning-monitoring-sg`** — Applied to the Prometheus/Grafana instance.
- Inbound port 9090 (Prometheus) from `var.my_ip`.
- Inbound port 3000 (Grafana) from `var.my_ip`.
- SSH from Jenkins SG — Ansible can configure it.

---

#### `ec2.tf`

Creates the actual virtual machines. Each `aws_instance` block is one server.
This project creates:

| Resource name | AWS Name tag | Subnet | Purpose |
|---|---|---|---|
| `aws_instance.user_service` | ms-learning-user-service | public-a | Runs user-service JAR |
| `aws_instance.payment_service` | ms-learning-payment-service | public-b | Runs payment-service JAR |
| `aws_instance.order_service` | ms-learning-order-service | public-a | Runs order-service JAR |
| `aws_instance.api_gateway` | ms-learning-api-gateway | public-b | Runs api-gateway JAR |
| `aws_instance.eureka_server` | ms-learning-eureka-server | private-a | Service discovery |
| `aws_instance.config_server` | ms-learning-config-server | private-a | Centralised config |
| `aws_instance.rabbitmq` | ms-learning-rabbitmq | private-b | Message broker |
| `aws_instance.keycloak` | ms-learning-keycloak | private-b | OAuth2 / JWT |
| `aws_instance.jenkins` | ms-learning-jenkins | public-a | CI/CD |
| `aws_instance.monitoring` | ms-learning-monitoring | public-b | Prometheus + Grafana |

All instances use the latest Amazon Linux 2023 AMI. The `data "aws_ami"` block at
the top of the file queries AWS for the current AMI ID at apply time — you don't
hardcode an AMI ID that would go stale.

Each instance has `iam_instance_profile = aws_iam_instance_profile.ec2.name`. This
attaches an IAM role to the instance so it can call AWS services (read from S3,
write to DynamoDB) without any access keys hardcoded. The instance's identity IS its
permission.

---

#### `alb.tf`

The Application Load Balancer sits between the internet and api-gateway. Without the
ALB, external users would need to know the EC2 instance's IP address directly. The
ALB provides a stable DNS name and handles routing.

**`aws_lb`** — The load balancer itself, deployed across both public subnets.

**`aws_lb_target_group`** — Defines what the ALB routes traffic to. Configured to
send traffic to port 8080 and health check via `GET /actuator/health`. If the health
check fails, the ALB stops sending traffic to that instance.

**`aws_lb_target_group_attachment`** — Registers the api-gateway EC2 instance into
the target group. Only api-gateway is registered — not the other three services,
because external users only talk to the gateway.

**`aws_lb_listener`** — Listens on port 80 and forwards everything to the target group.

The flow is: user hits `http://alb-dns/orders` → ALB listener → target group →
api-gateway:8080 → api-gateway routes to order-service via Eureka.

---

#### `rds.tf`

Creates a managed PostgreSQL database via RDS (Relational Database Service). RDS is
not an EC2 instance — AWS manages the operating system, patches, backups, and
failover. You only deal with the database itself.

Key settings:
- **`db_subnet_group`** — RDS is placed in the private subnets. It has no public IP.
- **`vpc_security_group_ids = [aws_security_group.rds.id]`** — Only allows inbound
  port 5432 from the `app-sg`. Services (order, payment) can reach the database;
  nothing else can.
- **`db_name = "postgres"`** — Only the default `postgres` database is created by
  Terraform. The `order_db` and `payment_db` databases are created afterwards by
  the Ansible `create-databases.yml` playbook.
- **`skip_final_snapshot = true`** — When you destroy this with `terraform destroy`,
  it won't try to save a backup first. Fine for a learning project; never do this in
  production.

---

#### `iam.tf`

IAM (Identity and Access Management) is AWS's permission system. Instead of giving
every EC2 instance AWS access keys (which could be exposed), you give the instance an
IAM role. The instance automatically gets temporary credentials that rotate every few
hours.

**`aws_iam_role.ec2`** — The role itself. The `assume_role_policy` says "EC2 instances
are allowed to use this role."

**`aws_iam_role_policy.s3_artifacts`** — Grants permission to `s3:GetObject` and
`s3:ListBucket` on the `ms-learning-artifacts` bucket. This is why the service EC2
instances can download their own JARs from S3 during Ansible deployment without any
credentials.

**`aws_iam_role_policy.dynamodb`** — Grants the user-service permission to read/write
DynamoDB on the `users` table. The user-service code doesn't have any AWS credentials
configured — it just calls DynamoDB and the EC2 instance's role handles authentication.

**`aws_iam_role_policy_attachment.ssm`** — Attaches the managed SSM policy. This lets
you shell into any instance via the AWS console (Session Manager) without opening an
SSH port or having a key file. Useful for emergency access.

**`aws_iam_instance_profile.ec2`** — The profile is the wrapper that actually attaches
the role to EC2 instances. You can't attach an IAM role to an EC2 instance directly;
you attach an instance profile that contains the role.

---

#### `s3.tf`

Creates the S3 bucket that Jenkins uses as an artifact store.

```
Jenkins builds JAR → uploads to s3://ms-learning-artifacts/<BUILD_NUMBER>/order-service.jar
                                                  ↓
Ansible (running on Jenkins) → tells EC2 instance → instance downloads JAR from S3
```

`force_destroy = true` means `terraform destroy` will delete the bucket even if it
still contains JARs. Without this, Terraform would refuse to delete a non-empty bucket.

**Versioning** is enabled so every upload of the same file name creates a new version.
Combined with the `BUILD_NUMBER` path prefix, you effectively have a history of every
build's artifacts.

---

#### `outputs.tf`

After `terraform apply` finishes, it prints every output value. These are not just
informational — `scripts/setup.sh` reads them programmatically:

```bash
EUREKA_HOST=$(terraform output -raw eureka_server_private_ip)
USER_SERVICE_HOST=$(terraform output -raw user_service_private_ip)
```

Without outputs you'd have to log into the AWS console to find each instance's IP
address after every deployment. The outputs make the handoff from Terraform to Ansible
(via setup.sh) fully automatic.

---

#### `infrastructure/bootstrap/` (separate Terraform module)

Before `scenario-1` Terraform can store state in S3, the S3 bucket itself has to exist.
That's the chicken-and-egg problem the bootstrap module solves. You run it once, ever,
before anything else:

```
cd infrastructure/bootstrap
terraform init   # state stored LOCALLY (no S3 yet)
terraform apply  # creates the S3 bucket and DynamoDB lock table
```

After that, `scenario-1/provider.tf` can reference the S3 bucket for its own remote
state.

---

### When Terraform is used

Terraform is used **once before anything else** and then **after every infrastructure
change**. It is NOT part of the Jenkins pipeline — Jenkins does not call Terraform.
You run Terraform manually from your laptop or from the Jenkins server:

```
Step 0 (one time):   terraform apply in infrastructure/bootstrap/
Step 1 (per deploy): terraform apply in infrastructure/scenario-1/
Step 2 (teardown):   terraform destroy in infrastructure/scenario-1/
```

---

## Part 2 — Ansible

### What Ansible is

Ansible is a tool that SSHes into servers and runs tasks on them. Where Terraform
answers "what infrastructure should exist", Ansible answers "what should be installed
and running on those servers".

You write **playbooks** — YAML files that describe tasks in order. Ansible connects to
each target server over SSH, runs the tasks one by one, and reports what changed. It's
**idempotent**: if you run the same playbook twice, the second run detects that
everything is already in the desired state and makes no changes.

The key advantage over shell scripts: Ansible has modules for everything (install a
package, write a file, manage a systemd service, wait for a port) that are idempotent
and cross-platform. A shell script that installs a package will fail on the second run
if the package is already installed. Ansible's `dnf` module checks first and skips if
already present.

**Inventory**: Ansible needs to know which servers to connect to. This project uses a
**dynamic inventory** — instead of a static list of IP addresses, Ansible queries AWS
in real time for all running EC2 instances tagged `Project=ms-learning` and groups them
by their `Name` tag. This means you never maintain a separate list of server IPs.

### The Ansible files in this project

---

#### `ansible/ansible.cfg`

Global configuration for Ansible. Applies to every command run from the `ansible/`
directory.

```ini
remote_user       = ec2-user        # All EC2 Amazon Linux instances use this user
private_key_file  = ~/ms-learning-key.pem  # SSH key Terraform created in AWS
host_key_checking = False           # Don't prompt to verify server fingerprints
stdout_callback   = yaml            # Print output in YAML format (more readable)
pipelining        = True            # Combine SSH commands for speed
retries           = 3               # Retry failed SSH connections 3 times
```

Without this file, you'd have to pass `--user ec2-user --private-key ...` on every
`ansible-playbook` command.

---

#### `ansible/inventory.aws_ec2.yml`

This is the dynamic inventory configuration. Instead of a file that lists IP addresses,
this file tells Ansible "go ask AWS."

```yaml
plugin: amazon.aws.aws_ec2   # Use the AWS EC2 dynamic inventory plugin
filters:
  tag:Project: ms-learning   # Only fetch instances with this tag
  instance-state-name: running
```

The `groups:` section maps AWS Name tags to Ansible group names:

```yaml
groups:
  user_servers:    "tags.Name == 'ms-learning-user-service'"
  payment_servers: "tags.Name == 'ms-learning-payment-service'"
  order_servers:   "tags.Name == 'ms-learning-order-service'"
  gateway_servers: "tags.Name == 'ms-learning-api-gateway'"
  jenkins:         "tags.Name == 'ms-learning-jenkins'"
  monitoring:      "tags.Name == 'ms-learning-monitoring'"
  config_server:   "tags.Name == 'ms-learning-config-server'"
  eureka_server:   "tags.Name == 'ms-learning-eureka-server'"
  rabbitmq:        "tags.Name == 'ms-learning-rabbitmq'"
  keycloak:        "tags.Name == 'ms-learning-keycloak'"
```

When a playbook says `hosts: order_servers`, Ansible looks up this group and
connects to whichever EC2 instances have `Name=ms-learning-order-service`.

The `hostnames:` setting tries the public IP first, then private IP. The group_vars
override this for public-subnet service instances (see below).

The `private_hosts` group is a special subset — these instances have no public IP.
Ansible reaches them through Jenkins as a jump host (SSH ProxyCommand).

---

#### `ansible/group_vars/all.yml`

Variables that apply to **every** host in every group:

```yaml
java_version: 21
app_user:    ec2-user   # The OS user that owns the JAR files and runs the service
deploy_dir:  /opt/apps  # Where JARs are downloaded to on each instance
internal_api_key: "{{ lookup('env', 'INTERNAL_API_KEY') }}"  # Read from env var at runtime
```

These variables are automatically available in every playbook and task without
needing to declare them.

---

#### `ansible/group_vars/public_hosts.yml`

Applies to all instances in the `public_hosts` group (user, payment, order, gateway,
monitoring):

```yaml
ansible_host: "{{ private_ip_address }}"
ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
```

This overrides the hostname Ansible would use. Even though these instances have public
IPs, the `app-sg` only allows SSH from `jenkins-sg` — not from the internet. So when
Ansible (running on Jenkins) tries to reach them, it must use their **private IP** (which
is routable within the VPC). `private_ip_address` comes from the dynamic inventory plugin.

---

#### `ansible/group_vars/private_hosts.yml`

Applies to Eureka, Config Server, RabbitMQ, and Keycloak — the four private-subnet
instances that have no public IP at all:

```yaml
ansible_ssh_common_args: >-
  -o StrictHostKeyChecking=no
  -o "ProxyCommand=ssh -i ~/ms-learning-key.pem -W %h:%p
  ec2-user@{{ lookup('env', 'JENKINS_IP') }}"
```

The `ProxyCommand` tells SSH: "to reach this host, first SSH to Jenkins, then tunnel
through to the destination." Jenkins acts as a jump host. `JENKINS_IP` is exported as
an environment variable by `scripts/setup.sh`.

Without this, Ansible running on your laptop could never reach a private-subnet
instance because private IPs are not routable from the internet.

---

#### `ansible/group_vars/app_servers.yml`

Historical artifact — was used when all services shared one ASG group. Still present
but the `app_servers` group no longer exists in the inventory, so Ansible ignores this
file. It is kept to avoid a confusing git diff. The equivalent is now `public_hosts.yml`.

---

### The playbooks

Playbooks are the actual work. Each is a YAML file with a list of tasks. Ansible runs
them top to bottom on every matched host.

---

#### `setup-jenkins.yml` — Used by: `scripts/setup.sh`, once per fresh Jenkins instance

Target: `hosts: jenkins`

This runs on the Jenkins EC2 itself. It is the only playbook that your laptop runs
directly over the public internet (Jenkins has a public IP and allows SSH from `my_ip`).

What it does, in order:
1. Installs Java 21 (Corretto), Git, Maven via `dnf`
2. Installs Python pip
3. Installs Ansible, boto3, botocore via pip — so Jenkins can itself run Ansible later
4. Installs AWS CLI
5. Installs the `amazon.aws` Ansible collection — needed for the dynamic inventory
6. Adds the Jenkins yum repository and imports its GPG key
7. Installs Jenkins from the repo
8. Creates a systemd override file that sets `JAVA_HOME` for Jenkins
9. Starts Jenkins and waits for port 8080 to be ready
10. Prints the initial admin password so you can unlock the UI

After this playbook runs, Jenkins is installed and running. All subsequent Ansible runs
happen FROM Jenkins, not from your laptop.

---

#### `setup-infra.yml` — Used by: `scripts/setup.sh`, once after Terraform

Target: orchestration only — imports four other playbooks in sequence

```yaml
- import_playbook: install-java.yml
- import_playbook: setup-rabbitmq.yml
- import_playbook: setup-keycloak.yml
- import_playbook: create-databases.yml
```

This is the master playbook for one-time infrastructure setup. It does NOT deploy the
application services — it prepares the infrastructure they depend on.

---

#### `install-java.yml` — Used by: `setup-infra.yml`

Target: `hosts: all:!monitoring:!user_servers:!payment_servers:!order_servers:!gateway_servers`

Installs Java 21 on every host except monitoring (doesn't need Java — Prometheus is a
Go binary) and the four service instances (they get Java installed per-deploy by
`deploy-service.yml`). In practice this means Eureka, Config Server, RabbitMQ, and
Keycloak all get Java.

---

#### `setup-rabbitmq.yml` — Used by: `setup-infra.yml`

Target: `hosts: rabbitmq`

Installs Docker on the RabbitMQ instance, then runs RabbitMQ as a Docker container
with ports 5672 (AMQP for application messages) and 15672 (management UI for debugging).
Uses a shell task with an idempotency check: only runs `docker run` if the container
doesn't already exist.

The container has `--restart always` so RabbitMQ restarts automatically if the EC2
instance reboots.

---

#### `setup-keycloak.yml` — Used by: `setup-infra.yml`

Target: `hosts: keycloak`

Same Docker pattern as RabbitMQ. Also copies the realm JSON file from the repo
(`infrastructure/keycloak/ms-learning-realm.json`) onto the EC2 instance, then mounts
it into the Keycloak container so the `ms-learning` realm is imported on first startup.
The realm file contains pre-configured clients, roles, and scopes — you don't have to
set them up manually in the Keycloak UI.

---

#### `create-databases.yml` — Used by: `setup-infra.yml`

Target: `hosts: config_server`

Installs the PostgreSQL client on the config-server EC2 instance, then uses `psql` to
create `order_db` and `payment_db` on the RDS instance. It runs on config-server (not
locally) because only instances with `app-sg` can reach the RDS security group on port
5432.

The `failed_when` / `changed_when` logic handles idempotency: if the database already
exists, `psql` returns an error containing "already exists" which is treated as success
(not a real error) and reported as "not changed."

---

#### `deploy-service.yml` — Used by: `deploy-all.yml` (called once per service)

This is the core deployment template. It is not called directly — `deploy-all.yml`
calls it six times with different variables each time.

Target: `hosts: "{{ target_hosts }}"` — accepts whichever group is passed in

What it does for each service:
1. Installs Java 21 (idempotent — skipped if already installed)
2. Installs AWS CLI
3. Creates the deploy directory (`/opt/apps/<service-name>/`)
4. Runs `aws s3 cp s3://ms-learning-artifacts/<BUILD_NUMBER>/<service>.jar /opt/apps/<service>/app.jar`
5. Writes a systemd unit file to `/etc/systemd/system/<service-name>.service` with:
   - The `java -jar app.jar` command
   - All environment variables (passed in as `env_vars` dict)
6. Reloads the systemd daemon (so it sees the new unit file)
7. Enables and restarts the service
8. Waits up to 60 seconds for `GET http://localhost:<port>/actuator/health` to return 200

If the health check never returns 200, the playbook fails here and the next service is
never deployed (because `deploy-all.yml` uses `import_playbook` which is sequential).

The environment variables in the systemd unit file are how configuration reaches the
Spring Boot app in production. When Spring Boot reads `${DB_URL}`, the JVM looks at
the system environment, finds `DB_URL` from the unit file, and uses it. No
`application-prod.yml` needs to hard-code anything.

---

#### `deploy-all.yml` — Used by: Jenkins `Deploy via Ansible` stage

This is the playbook Jenkins runs on every build. It calls `deploy-service.yml` six
times in a fixed order, passing different variables each time:

```
config-server  (port 8888)  → must be up before anyone can fetch config
eureka-server  (port 8761)  → must be up before services can register
user-service   (port 8081)  → must be up before order-service calls it
payment-service (port 8082) → must be up before order-service calls it
order-service  (port 8083)  → starts after its two dependencies
api-gateway    (port 8080)  → starts last, routes external traffic to everything
```

The deployment is strictly sequential because each `import_playbook` blocks until the
health check passes. If user-service fails its health check, the pipeline stops and
api-gateway never starts.

For order-service, the env vars include:
```yaml
USER_SERVICE_URL:    "http://{{ user_service_host }}:8081"
PAYMENT_SERVICE_URL: "http://{{ payment_service_host }}:8082"
```
These use Ansible variables passed from Jenkins as `-e user_service_host=<private IP>`.

---

#### `install-monitoring.yml` — Used manually, once per environment

Target: `hosts: monitoring`

Installs Prometheus and Grafana on the dedicated monitoring EC2 instance.

Prometheus installation:
1. Creates a `prometheus` system user (security: the process doesn't run as root)
2. Downloads the Prometheus binary tarball from GitHub releases
3. Copies `prometheus` and `promtool` to `/usr/local/bin/`
4. Uses the `template:` module to render `monitoring/prometheus.yml.j2` and write
   it to `/etc/prometheus/prometheus.yml` — this is where EC2 private IPs are
   substituted in at deploy time
5. Writes a systemd unit file for Prometheus
6. Starts Prometheus

Grafana installation:
1. Adds the official Grafana RPM repository
2. Installs Grafana via `dnf`
3. Writes a Grafana datasource provisioning file to
   `/etc/grafana/provisioning/datasources/prometheus.yml`
4. Starts Grafana

The datasource provisioning is how Grafana auto-configures the Prometheus connection:
on startup Grafana reads files in `/etc/grafana/provisioning/datasources/` and creates
datasources from them. You never have to manually add a datasource in the Grafana UI.

---

### Ansible variable files referenced by playbooks

**`monitoring/prometheus.yml.j2`** — Jinja2 template rendered by `install-monitoring.yml`

```yaml
- job_name: 'order-service'
  static_configs:
    - targets:
{% for host in groups['order_servers'] %}
        - '{{ hostvars[host]["private_ip_address"] }}:8083'
{% endfor %}
```

The `{% for %}` loop iterates over every host in the `order_servers` Ansible group
and inserts their private IP. If you scale to two order-service instances, both IPs
appear automatically. `hostvars` is a built-in Ansible variable — a dictionary of all
variables for all hosts in the inventory.

**`monitoring/prometheus.yml`** — Static version for local docker-compose. Uses Docker
container names instead of IPs (`order-service:8083`) because Docker's internal DNS
resolves container names to their private IP automatically.

---

### When Ansible is used

```
Phase 1 — one time setup (from your laptop via scripts/setup.sh):
  setup-jenkins.yml     → installs Jenkins on the Jenkins EC2
  setup-infra.yml       → installs Java, RabbitMQ, Keycloak, creates databases

Phase 2 — every build (from Jenkins via Jenkinsfile):
  deploy-all.yml        → deploys all 6 services in order

Phase 3 — one time monitoring setup (manually from Jenkins):
  install-monitoring.yml → installs Prometheus + Grafana on monitoring EC2
```

---

## Part 3 — Jenkins

### What Jenkins is

Jenkins is a CI/CD server — an automation server that runs pipelines. A pipeline is a
series of steps that happen automatically when something triggers it (typically a git
push or a manual click).

As an application developer, you've probably run `mvn package` or `npm build` manually.
Jenkins does that for you automatically, then does everything after it too: upload
artifacts, run tests, deploy to servers. You define the steps in a `Jenkinsfile`.

Jenkins is a Java application running on the Jenkins EC2 instance. It has a web UI
at `http://<jenkins-ip>:8080`. You configure jobs, credentials, and plugins through
that UI. The actual pipeline logic lives in the `Jenkinsfile` in your git repo — that's
what makes Jenkins "as code".

**Credentials store**: Jenkins has a built-in secrets manager. You store AWS keys,
SSH keys, and passwords in it, then reference them by ID in the Jenkinsfile. This
means no secrets ever appear in your git repository.

### The Jenkinsfile in this project

The Jenkinsfile uses **declarative pipeline** syntax. Every section is explained below.

---

#### `environment` block

```groovy
environment {
    AWS_REGION  = 'us-east-1'
    S3_BUCKET   = 'ms-learning-artifacts'
    ANSIBLE_DIR = "${WORKSPACE}/ansible"
    JAVA_HOME   = '/usr/lib/jvm/java-21-amazon-corretto'
}
```

Variables set here are available as environment variables in every stage. `WORKSPACE`
is a Jenkins built-in — the directory where Jenkins checked out your git repo. So
`ANSIBLE_DIR` always points to the right place even if you move the job.

---

#### `parameters` block

```groovy
parameters {
    string(name: 'EUREKA_HOST',          defaultValue: '10.0.3.25', ...)
    string(name: 'USER_SERVICE_HOST',    defaultValue: '',          ...)
    string(name: 'PAYMENT_SERVICE_HOST', defaultValue: '',          ...)
    ...
}
```

These appear in the Jenkins UI as a form when you click "Build with Parameters". They
allow the same pipeline to work with different infrastructure without changing the
Jenkinsfile. The `scripts/setup.sh` script automatically updates the `defaultValue`
fields after every `terraform apply` so you usually just click Build without changing
anything.

`params.EUREKA_HOST` is how you access a parameter value in the pipeline.

---

#### `stage('Checkout')`

```groovy
checkout scm
```

`scm` is a Jenkins built-in that refers to the source control configuration of the job.
This stage clones your git repository into the `WORKSPACE` directory. All subsequent
stages read files from this directory.

---

#### `stage('Build All')` with `parallel`

```groovy
parallel {
    stage('config-server') { steps { sh 'mvn -f config-server/pom.xml clean package -DskipTests' } }
    stage('eureka-server')  { ... }
    stage('user-service')   { ... }
    ...
}
```

The `parallel` block runs all six Maven builds simultaneously. Without this, six
sequential Maven builds would take 6x as long. With parallel, total time is roughly
the time of the slowest single build.

`-DskipTests` skips unit tests. In a production pipeline you'd have a separate test
stage; this project optimizes for deployment speed.

`sh 'command'` runs a shell command on the Jenkins server. Maven is installed there by
`setup-jenkins.yml`.

After this stage, six JAR files exist on the Jenkins server's disk:
- `config-server/target/config-server-0.0.1-SNAPSHOT.jar`
- `eureka-server/target/eureka-server-0.0.1-SNAPSHOT.jar`
- etc.

---

#### `stage('Upload to S3')`

```groovy
withCredentials([[
    $class: 'AmazonWebServicesCredentialsBinding',
    credentialsId: 'aws-ms-learning',
    ...
]]) {
    sh "aws s3 cp config-server/target/config-server-*.jar s3://${S3_BUCKET}/${BUILD_NUMBER}/config-server.jar"
}
```

`withCredentials` is how Jenkins injects secrets safely. It reads the `aws-ms-learning`
credential from the credentials store and sets `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` as environment variables inside the block. The shell process
sees them but they never appear in logs.

`BUILD_NUMBER` is a Jenkins built-in — an integer that increments for every build of
this job. Uploading to `s3://bucket/42/service.jar` means build 42's JARs are always
at that path. The EC2 instances then download from that exact path during deployment.

The wildcard `config-server-*.jar` handles the version number in the filename without
hardcoding it.

---

#### `stage('Deploy via Ansible')`

```groovy
withCredentials([
    sshUserPrivateKey(credentialsId: 'ms-learning-ec2-key', keyFileVariable: 'SSH_KEY_FILE'),
    string(credentialsId: 'ms-learning-internal-api-key',   variable: 'INTERNAL_API_KEY'),
    string(credentialsId: 'ms-learning-db-password',        variable: 'DB_PASSWORD'),
    [AmazonWebServicesCredentialsBinding ...]
]) {
    sh """
        ansible-playbook \
            -i ${ANSIBLE_DIR}/inventory.aws_ec2.yml \
            ${ANSIBLE_DIR}/playbooks/deploy-all.yml \
            --private-key ${SSH_KEY_FILE} \
            -e build_number=${BUILD_NUMBER} \
            -e user_service_host=${params.USER_SERVICE_HOST} \
            -e payment_service_host=${params.PAYMENT_SERVICE_HOST} \
            ...
    """
}
```

This runs `ansible-playbook` on the Jenkins server itself. Jenkins IS the Ansible
control node — it SSHes into all other EC2 instances from here.

**`-i inventory.aws_ec2.yml`** — Uses the dynamic inventory. Ansible calls the AWS
API to discover which EC2 instances exist right now.

**`--private-key ${SSH_KEY_FILE}`** — `withCredentials` writes the SSH private key
to a temporary file and puts the path in `SSH_KEY_FILE`. Ansible uses this file to
authenticate to all EC2 instances.

**`-e build_number=${BUILD_NUMBER}`** — Passes the current build number to Ansible
as an extra variable. `deploy-service.yml` uses it to construct the S3 path
`s3://ms-learning-artifacts/<build_number>/service.jar`.

**`-e user_service_host`** and **`-e payment_service_host`** — Pass the EC2 private
IPs so order-service knows how to call the other two services.

**`INTERNAL_API_KEY`** and **`DB_PASSWORD`** are read from Jenkins credentials store
and injected as environment variables. Inside `deploy-service.yml`, these become
`{{ lookup('env', 'INTERNAL_API_KEY') }}` and are written into the systemd unit file.

---

#### `stage('Smoke Test')`

```groovy
sh """
    sleep 60
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://${params.ALB_DNS}/actuator/health)
    if [ "$HTTP_STATUS" != "200" ]; then exit 1; fi
"""
```

After Ansible finishes deploying all services, this stage waits 60 seconds for Eureka
service registration to propagate (services register themselves in Eureka on startup,
and api-gateway needs to read those registrations before it can route). Then it makes
a single HTTP request to the ALB and checks the response code.

This is the simplest possible end-to-end test: if the ALB responds 200 to
`/actuator/health`, it means:
1. api-gateway is running and responding
2. The ALB health check is passing
3. At least the infrastructure layer is working

---

#### `post` block

```groovy
post {
    success { echo "Build #${BUILD_NUMBER} deployed successfully." }
    failure { echo "Build #${BUILD_NUMBER} FAILED." }
}
```

`post` runs after all stages regardless of outcome. `success` only runs when
everything passed; `failure` only runs when something failed. In a real project you
would send Slack/email notifications here.

---

### When Jenkins is used

Jenkins is the only tool that runs **automatically** on every code change. Terraform
and Ansible are both invoked manually or by Jenkins — Jenkins itself is triggered by
a git push (via a webhook) or manually via the UI.

```
Git push to main
    └── Jenkins detects push (webhook)
        ├── Checkout
        ├── Build All (parallel Maven)
        ├── Upload to S3
        ├── Deploy via Ansible (calls deploy-all.yml which calls deploy-service.yml × 6)
        └── Smoke Test
```

---

## Part 4 — How the Three Tools Work Together (Full Sequence)

```
Step 0 — Bootstrap (one time, ever)
  You (laptop) → terraform apply infrastructure/bootstrap/
  Creates: S3 bucket for Terraform state, DynamoDB table for state locking

Step 1 — Create Infrastructure (one time per environment)
  You (laptop) → terraform apply infrastructure/scenario-1/
  Creates: VPC, subnets, 10 EC2 instances, ALB, RDS, S3 artifacts bucket, IAM roles

Step 2 — Setup Infrastructure Software (one time per environment)
  You (laptop) → bash scripts/setup.sh
    → reads terraform outputs for all IPs
    → runs setup-jenkins.yml  (installs Jenkins on Jenkins EC2)
    → runs setup-infra.yml    (installs Java, RabbitMQ, Keycloak, creates databases)
    → patches Jenkinsfile with fresh IPs and pushes to git

Step 3 — Jenkins Manual Setup (one time per Jenkins instance)
  You (browser) → unlock Jenkins, install plugins, add credentials, create pipeline job

Step 4 — Every Deployment (triggered by git push or manual click)
  Jenkins → checks out code
          → mvn package × 6 services (parallel)
          → aws s3 cp × 6 JARs to s3://ms-learning-artifacts/<BUILD_NUMBER>/
          → ansible-playbook deploy-all.yml
              → config-server:  downloads JAR, writes systemd unit, starts, health checks
              → eureka-server:  same
              → user-service:   same, waits for health
              → payment-service: same
              → order-service:  same (now can call user and payment by private IP)
              → api-gateway:    same, now routes external traffic
          → curl ALB/actuator/health → must return 200

Step 5 — Monitoring Setup (one time, run manually from Jenkins)
  You (Jenkins console) → ansible-playbook install-monitoring.yml
    → installs Prometheus on monitoring EC2, renders prometheus.yml.j2 with real IPs
    → installs Grafana, provisions Prometheus datasource automatically

Step 6 — Teardown
  You (laptop) → terraform destroy infrastructure/scenario-1/
  Destroys: all 10 EC2 instances, ALB, RDS, security groups, subnets, VPC
  (S3 artifacts bucket also destroyed due to force_destroy=true)
  (Bootstrap S3/DynamoDB NOT destroyed — they have prevent_destroy=true)
```

---

## Part 5 — Key Concepts Summary

**Why S3 for JARs?** You could have Ansible build the JAR on the EC2 instance, but
that would require Maven and the source code on every EC2 instance. By building once
on Jenkins and uploading to S3, every EC2 instance just downloads a finished artifact.

**Why systemd for services?** When you deploy a Spring Boot JAR manually you run
`java -jar app.jar`. If the server reboots, your app is gone. systemd is the Linux
process manager — it starts your service on boot, restarts it if it crashes, and
collects its logs in journald. `journalctl -u order-service -f` tails the logs.

**Why Eureka?** When order-service calls payment-service, it doesn't hardcode the IP.
It asks Eureka "where is payment-service?" and gets back the current IP and port. If
payment-service moves to a new instance, Eureka updates and order-service finds it
automatically. The api-gateway uses the same mechanism to route incoming requests.

**Why Config Server?** All services fetch their configuration from Config Server on
startup, which reads from a git repository. When you change a config value, you push
to git and restart the service — no code deployment needed. In this project, the
Config Server stores the internal API key and service URL overrides.

**Why not Docker on EC2?** This scenario deliberately uses JARs + systemd instead of
Docker containers. The goal is to understand the fundamentals before adding container
abstraction. A future scenario would replace this with ECS (managed containers) or
Kubernetes.

**Why `sensitive = true` on `db_password`?** This Terraform variable is marked
sensitive. Terraform will not print its value in `terraform plan` or `terraform apply`
output. Without this, your database password would appear in CI/CD logs.
