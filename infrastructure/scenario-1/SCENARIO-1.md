# Scenario 1 — EC2 Deployment Guide

Full end-to-end setup from zero to a running pipeline. After `terraform apply` + `setup.sh`, only the Jenkins UI steps are manual.

---

## Prerequisites

- AWS CLI configured with a `work` profile (`~/.aws/credentials`)
- SSH key at `~/ms-learning-key.pem` (must exist in AWS as `ms-learning-key`)
- Terraform >= 1.5 installed
- Ansible + `amazon.aws` collection installed (`pip3 install ansible boto3 botocore && ansible-galaxy collection install amazon.aws`)

---

## Step 1 — Terraform Apply

```bash
cd infrastructure/scenario-1
terraform init
terraform apply
```

When prompted, enter:
- `db_password` — choose a strong password (you'll need it again in Step 2)
- `my_ip` — your current public IP in CIDR form e.g. `203.0.113.5/32`

Terraform provisions: VPC, subnets, ALB, four dedicated EC2 instances (user-service, payment-service, order-service, api-gateway), Eureka EC2, Config EC2, RabbitMQ EC2, Keycloak EC2, Jenkins EC2, Monitoring EC2 (Prometheus + Grafana), RDS PostgreSQL, S3 artifacts bucket, IAM roles.

> If S3 bucket already exists from a previous run:
> ```bash
> terraform import aws_s3_bucket.artifacts ms-learning-artifacts
> terraform apply
> ```

---

## Step 2 — Ansible Infrastructure Setup

Run the setup script from the repo root:

```bash
bash scripts/setup.sh
```

The script will:
1. Read all IPs and DNS names from Terraform outputs
2. Prompt for DB password and Keycloak admin password
3. Add your SSH key to the agent
4. Run `setup-jenkins.yml` — installs Java 21, Maven, Git, Ansible, AWS CLI, Jenkins on the Jenkins EC2
5. Run `setup-infra.yml` — installs and starts RabbitMQ (Docker), Keycloak (Docker) with realm import, creates RDS databases, deploys Config Server and Eureka Server
6. Update `Jenkinsfile` parameter defaults with the fresh IPs and commit+push

Wait ~5 minutes for all services to start, then verify:

```bash
# Eureka UI
http://<jenkins_public_ip>  # browse from setup output

# RabbitMQ management
ssh -i ~/ms-learning-key.pem -L 15672:10.0.4.X:15672 ec2-user@<jenkins_ip>
# then open http://localhost:15672  (guest/guest)
```

---

## Step 3 — Jenkins Manual Setup (one-time)

### 3.1 Unlock Jenkins

```bash
ssh -i ~/ms-learning-key.pem ec2-user@<jenkins_public_ip>
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `http://<jenkins_public_ip>:8080`, paste the password, click **Install suggested plugins**.

Create your admin user when prompted.

### 3.2 Install Required Plugins

Go to **Manage Jenkins → Plugins → Available** and install:

- Pipeline
- Git
- GitHub
- Amazon Web Services SDK (or Pipeline: AWS Steps)
- SSH Agent
- Credentials Binding

Restart Jenkins after installing.

### 3.3 Add Credentials

Go to **Manage Jenkins → Credentials → System → Global → Add Credential**:

| ID | Kind | Value |
|----|------|-------|
| `aws-ms-learning` | AWS Credentials | Your AWS Access Key ID + Secret Key |
| `ms-learning-ec2-key` | SSH Username with private key | Username: `ec2-user`, paste contents of `~/ms-learning-key.pem` |
| `ms-learning-internal-api-key` | Secret text | Any string e.g. `my-internal-key` |
| `ms-learning-db-password` | Secret text | Same DB password used in Step 1 & 2 |

### 3.4 Create the Pipeline Job

1. **New Item** → name it `microservices-deploy` → select **Pipeline** → OK
2. Under **Pipeline**:
   - Definition: `Pipeline script from SCM`
   - SCM: `Git`
   - Repository URL: `https://github.com/muhammad-mansoor9/microservices-learning`
   - Branch: `*/main`
   - Script Path: `Jenkinsfile`
3. Click **Save**

### 3.5 First Build

Click **Build with Parameters**. All parameter defaults are pre-filled by the setup script. Click **Build**.

> **Note:** `USER_SERVICE_HOST` and `PAYMENT_SERVICE_HOST` are also pre-filled by the setup script from `terraform output`. Verify them before building — order-service uses these to reach the other two services by private IP.

The pipeline will:
1. Build all 6 services (parallel Maven build)
2. Upload JARs to S3
3. Deploy via Ansible to EC2 (config-server → eureka → user-service → payment-service → order-service → api-gateway)
4. Wait 60s for Eureka registration
5. Smoke test: `GET http://<ALB>/actuator/health` must return 200

---

## Teardown

To destroy all infrastructure and stop billing:

```bash
cd infrastructure/scenario-1
terraform destroy
```

When prompted, confirm with `yes`.

> S3 bucket has `force_destroy = true` so it will be deleted along with any stored JARs.

On next redeployment, start from Step 1. The setup script handles everything automatically — only the Jenkins UI steps (3.1–3.4) need to be done once per fresh Jenkins instance.

---

## Architecture Overview

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
         │
         ├── Eureka Server    (private subnet A) :8761
         ├── Config Server    (private subnet A) :8888
         ├── RabbitMQ         (private subnet B) :5672
         ├── Keycloak         (private subnet B) :9090
         └── RDS PostgreSQL   (private subnets)  :5432

  Jenkins EC2    (public subnet A) — Ansible control node
  Monitoring EC2 (public subnet B) — Prometheus :9090, Grafana :3000
```

Each microservice runs on its own EC2 instance. Jenkins SSHs to all instances over private IPs within the VPC. The monitoring instance scrapes each service's `/actuator/prometheus` endpoint directly.
