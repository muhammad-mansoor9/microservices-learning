# Scenario 1 — EC2 Deployment Guide

Full end-to-end setup from zero to a running pipeline.

**What is automated vs manual:**
- `terraform apply` + `setup.sh` → fully automated (provisions infra, installs all software, sets up monitoring)
- Jenkins UI → one-time manual steps (unlock, add credentials, create job)
- First build → click Build with Parameters

---

## Prerequisites

- AWS CLI configured with a `work` profile (`~/.aws/credentials`)
- SSH key at `~/ms-learning-key.pem` (must exist in AWS as `ms-learning-key`)
- Terraform >= 1.5 installed
- Ansible + `amazon.aws` collection (`pip3 install ansible boto3 botocore && ansible-galaxy collection install amazon.aws`)

---

## Step 1 — Terraform Apply

```bash
cd infrastructure/scenario-1
terraform init
terraform apply
```

When prompted:
- `db_password` — choose a strong password (you'll reuse it in Step 2 and as a Jenkins credential)
- `my_ip` — your current public IP in CIDR form e.g. `203.0.113.5/32` (controls who can access Prometheus/Grafana and SSH to Jenkins)

> **Re-deploying after a destroy?** If the S3 artifacts bucket already exists:
> ```bash
> terraform import aws_s3_bucket.artifacts ms-learning-artifacts
> terraform apply
> ```

Terraform provisions: VPC, subnets, ALB, dedicated EC2 per service (user, payment, order, api-gateway), Eureka EC2, Config EC2, RabbitMQ EC2, Keycloak EC2, Jenkins EC2, Monitoring EC2, RDS PostgreSQL, S3 artifacts bucket, IAM roles, DynamoDB `users` table.

---

## Step 2 — Ansible Infrastructure Setup

```bash
bash scripts/setup.sh
```

The script reads all Terraform outputs, then runs four Ansible playbooks in order:

| Playbook | What it does |
|----------|-------------|
| `setup-jenkins.yml` | Installs Java 21, Maven, Git, Ansible, AWS CLI, Jenkins; auto-installs all required plugins via Jenkins CLI |
| `setup-infra.yml` | Starts RabbitMQ + Keycloak (Docker), imports Keycloak realm, creates RDS schemas, deploys Config Server + Eureka |
| `install-monitoring.yml` | Installs Prometheus and Grafana on the monitoring EC2 |

Finally it updates the `Jenkinsfile` parameter defaults with the fresh IPs and commits+pushes.

**SSH access model:** Jenkins is reached directly from your laptop (public IP). All other instances are reached via Jenkins as a jump host — their SSH is restricted to the Jenkins security group.

Wait ~5 minutes after the script finishes for all services to start.

---

## Step 3 — Jenkins Manual Setup (one-time per fresh Jenkins)

### 3.1 Unlock Jenkins

```bash
ssh -i ~/ms-learning-key.pem ec2-user@<jenkins_public_ip>
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `http://<jenkins_public_ip>:8080`, paste the password, create your admin user.

All required plugins (Pipeline, Git, GitHub, Pipeline: AWS Steps, SSH Agent, Credentials Binding) were already installed by the Ansible playbook.

### 3.2 Add Credentials

Go to **Manage Jenkins → Credentials → System → Global → Add Credential**:

| ID | Kind | Value |
|----|------|-------|
| `aws-ms-learning` | AWS Credentials | Your AWS Access Key ID + Secret Key |
| `ms-learning-ec2-key` | SSH Username with private key | Username: `ec2-user`, paste contents of `~/ms-learning-key.pem` |
| `ms-learning-internal-api-key` | **Secret text** | Any string e.g. `my-internal-key` |
| `ms-learning-db-password` | **Secret text** | Same DB password from Step 1 |

> **Important:** `ms-learning-internal-api-key` and `ms-learning-db-password` must be **Secret text** kind, not Username/Password. A wrong kind causes "Could not find credentials entry" at build time.

### 3.3 Create the Pipeline Job

1. **New Item** → name it `build-pipeline` (no spaces — workspace path inherits job name) → select **Pipeline** → OK
2. Under **Pipeline**:
   - Definition: `Pipeline script from SCM`
   - SCM: `Git`
   - Repository URL: `https://github.com/muhammad-mansoor9/microservices-learning`
   - Branch: `*/main`
   - Script Path: `Jenkinsfile`
3. Click **Save**

### 3.4 First Build

Click **Build with Parameters**. All parameter defaults are pre-filled by `setup.sh`. Verify the IPs look correct, then click **Build**.

The pipeline:
1. Builds all 6 services in parallel (Maven)
2. Uploads JARs to S3
3. Deploys via Ansible to EC2 (config-server → eureka → user-service → payment-service → order-service → api-gateway)
4. Waits 60s for Eureka registration
5. Smoke tests `GET http://<ALB>/actuator/health`

---

## Step 4 — Verify Monitoring

After a successful build, Prometheus and Grafana are available at:

- **Prometheus:** `http://<monitoring_public_ip>:9090` — check targets at `/targets`
- **Grafana:** `http://<monitoring_public_ip>:3000` — default login `admin` / `admin`

Access is restricted to the `my_ip` you provided in Step 1. If your IP changed since `terraform apply`, re-run `terraform apply` with the new IP.

Prometheus scrapes `/actuator/prometheus` from user-service, payment-service, and order-service every 15 seconds.

---

## Teardown

```bash
cd infrastructure/scenario-1
terraform destroy
```

S3 bucket has `force_destroy = true` so all stored JARs are deleted with it.

On next redeployment, start from Step 1. The setup script handles everything — only the Jenkins UI steps (3.1–3.3) need repeating per fresh Jenkins instance.

---

## Architecture

```
Internet
   │
  ALB (public, port 80)
   │
  api-gateway EC2     (public subnet B) :8080
   │  (Eureka-discovered routing)
   ├── order-service EC2   (public subnet A) :8083
   ├── payment-service EC2 (public subnet B) :8082
   └── user-service EC2    (public subnet A) :8081

  All services connect to:
   ├── Eureka Server    (private subnet A) :8761
   ├── Config Server    (private subnet A) :8888  ← reads from ms-learning-config-repo on GitHub
   ├── RabbitMQ         (private subnet B) :5672
   ├── Keycloak         (private subnet B) :9090
   ├── RDS PostgreSQL   (private subnets)  :5432
   └── DynamoDB         (AWS managed)      — users table

  Jenkins EC2    (public subnet A) — CI/CD + Ansible control node
  Monitoring EC2 (public subnet B) — Prometheus :9090, Grafana :3000
```

**Network access rules:**
- ALB → api-gateway: public internet
- Services → each other: private IPs within VPC
- Your laptop → Jenkins (SSH :22, UI :8080): restricted to `my_ip`
- Your laptop → Monitoring (Prometheus :9090, Grafana :3000): restricted to `my_ip`
- Jenkins → all other instances (SSH :22): Jenkins security group to app/infra security groups
- Monitoring → services (scrape :8080–:8888): monitoring security group to app security group

---

## Known Issues / Gotchas

**Config repo overrides local management settings**
The Spring Cloud Config repo (`ms-learning-config-repo`) `application.yml` controls which actuator endpoints are exposed for all services. Ensure it contains:
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
```
Without this, Prometheus scraping returns 404 on services that rely on config server.

**Jenkinsfile IPs go stale after terraform destroy+apply**
Private IPs change on every fresh apply. `setup.sh` updates `Jenkinsfile` defaults automatically via `sed`. If you skip `setup.sh` or it fails early, run it again or manually trigger **Build with Parameters** with the correct IPs from `terraform output`.

**My IP changes**
If your public IP changes after `terraform apply`, re-run `terraform apply -var="my_ip=<new_ip>/32"` to update the security group rules — otherwise you lose access to Jenkins and the monitoring UIs.
