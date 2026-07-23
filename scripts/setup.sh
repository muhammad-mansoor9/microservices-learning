#!/usr/bin/env bash
# Run this after every terraform apply.
# Reads Terraform outputs → runs setup-infra Ansible playbook.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/scenario-1"
ANSIBLE_DIR="$REPO_ROOT/ansible"

# ---------- 1. Read Terraform outputs ----------------------------------------
echo "Reading Terraform outputs..."
cd "$TF_DIR"

export JENKINS_IP=$(terraform output -raw jenkins_public_ip)
RDS_HOST=$(terraform output -raw rds_host)
EUREKA_HOST=$(terraform output -raw eureka_server_private_ip)
CONFIG_HOST=$(terraform output -raw config_server_private_ip)
RABBITMQ_HOST=$(terraform output -raw rabbitmq_private_ip)
KEYCLOAK_HOST=$(terraform output -raw keycloak_private_ip)
ALB_DNS=$(terraform output -raw alb_dns_name)

echo ""
echo "  Jenkins (public):  $JENKINS_IP"
echo "  Config Server:     $CONFIG_HOST"
echo "  Eureka Server:     $EUREKA_HOST"
echo "  RabbitMQ:          $RABBITMQ_HOST"
echo "  Keycloak:          $KEYCLOAK_HOST"
echo "  RDS:               $RDS_HOST"
echo "  ALB:               $ALB_DNS"
echo ""

# ---------- 2. Prompt for secrets --------------------------------------------
read -rsp "DB password (same as terraform apply): " DB_PASSWORD; echo
read -rsp "Keycloak admin password (choose one):  " KC_ADMIN_PASSWORD; echo
echo ""

# ---------- 3. Add SSH key to agent for ProxyCommand key forwarding ----------
echo "Adding SSH key to agent..."
eval "$(ssh-agent -s)"
ssh-add ~/ms-learning-key.pem
trap 'ssh-agent -k' EXIT   # kill agent when this script exits

# ---------- 4. Run Ansible setup-infra ---------------------------------------
echo "Running setup-infra playbook..."
cd "$REPO_ROOT"

AWS_PROFILE=work ansible-playbook \
  -i "$ANSIBLE_DIR/inventory.aws_ec2.yml" \
  "$ANSIBLE_DIR/playbooks/setup-infra.yml" \
  --private-key ~/ms-learning-key.pem \
  -e "rds_host=$RDS_HOST" \
  -e "db_password=$DB_PASSWORD" \
  -e "keycloak_admin_password=$KC_ADMIN_PASSWORD"

# ---------- 5. Print next steps ----------------------------------------------
echo ""
echo "Infrastructure setup complete!"
echo ""
echo "Next: Set up Jenkins"
echo "  SSH:  ssh -i ~/ms-learning-key.pem ec2-user@$JENKINS_IP"
echo "  URL:  http://$JENKINS_IP:8080  (after Jenkins is installed)"
echo ""
echo "Jenkins pipeline parameter values:"
echo "  ALB_DNS             = $ALB_DNS"
echo "  EUREKA_HOST         = $EUREKA_HOST"
echo "  CONFIG_HOST         = $CONFIG_HOST"
echo "  RABBITMQ_HOST       = $RABBITMQ_HOST"
echo "  KEYCLOAK_HOST       = $KEYCLOAK_HOST"
echo "  DB_HOST             = $RDS_HOST"
echo "  KEYCLOAK_ISSUER_URI = http://$KEYCLOAK_HOST:9090/realms/ms-learning"
