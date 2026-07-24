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
USER_SERVICE_HOST=$(terraform output -raw user_service_private_ip)
PAYMENT_SERVICE_HOST=$(terraform output -raw payment_service_private_ip)

echo ""
echo "  Jenkins (public):     $JENKINS_IP"
echo "  Config Server:        $CONFIG_HOST"
echo "  Eureka Server:        $EUREKA_HOST"
echo "  RabbitMQ:             $RABBITMQ_HOST"
echo "  Keycloak:             $KEYCLOAK_HOST"
echo "  RDS:                  $RDS_HOST"
echo "  ALB:                  $ALB_DNS"
echo "  User Service:         $USER_SERVICE_HOST"
echo "  Payment Service:      $PAYMENT_SERVICE_HOST"
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

# ---------- 4. Run Ansible playbooks -----------------------------------------
cd "$REPO_ROOT"

echo "Running setup-jenkins playbook..."
AWS_PROFILE=work ansible-playbook \
  -i "$ANSIBLE_DIR/inventory.aws_ec2.yml" \
  "$ANSIBLE_DIR/playbooks/setup-jenkins.yml" \
  --private-key ~/ms-learning-key.pem

echo "Running setup-infra playbook..."
AWS_PROFILE=work ansible-playbook \
  -i "$ANSIBLE_DIR/inventory.aws_ec2.yml" \
  "$ANSIBLE_DIR/playbooks/setup-infra.yml" \
  --private-key ~/ms-learning-key.pem \
  -e "rds_host=$RDS_HOST" \
  -e "db_password=$DB_PASSWORD" \
  -e "keycloak_admin_password=$KC_ADMIN_PASSWORD"

echo "Running install-monitoring playbook..."
AWS_PROFILE=work ansible-playbook \
  -i "$ANSIBLE_DIR/inventory.aws_ec2.yml" \
  "$ANSIBLE_DIR/playbooks/install-monitoring.yml" \
  --private-key ~/ms-learning-key.pem

# ---------- 5. Update Jenkinsfile default parameter values -------------------
echo "Updating Jenkinsfile parameter defaults..."
JENKINSFILE="$REPO_ROOT/Jenkinsfile"
KEYCLOAK_ISSUER_URI="http://$KEYCLOAK_HOST:9090/realms/ms-learning"

sed -i.bak -E \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'ALB DNS name'|defaultValue: '$ALB_DNS', description: 'ALB DNS name'|" \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'Eureka private IP'|defaultValue: '$EUREKA_HOST', description: 'Eureka private IP'|" \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'Config-server private IP'|defaultValue: '$CONFIG_HOST', description: 'Config-server private IP'|" \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'RabbitMQ private IP'|defaultValue: '$RABBITMQ_HOST', description: 'RabbitMQ private IP'|" \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'Keycloak private IP'|defaultValue: '$KEYCLOAK_HOST', description: 'Keycloak private IP'|" \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'PostgreSQL RDS host'|defaultValue: '$RDS_HOST', description: 'PostgreSQL RDS host'|" \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'Keycloak issuer URI'|defaultValue: '$KEYCLOAK_ISSUER_URI', description: 'Keycloak issuer URI'|" \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'Private IP of user-service EC2[^']*'|defaultValue: '$USER_SERVICE_HOST', description: 'Private IP of user-service EC2 (from terraform output user_service_private_ip)'|" \
  -e "s|defaultValue: '[^']*'[[:space:]]*,[[:space:]]*description: 'Private IP of payment-service EC2[^']*'|defaultValue: '$PAYMENT_SERVICE_HOST', description: 'Private IP of payment-service EC2 (from terraform output payment_service_private_ip)'|" \
  "$JENKINSFILE"
rm -f "$JENKINSFILE.bak"

cd "$REPO_ROOT"
git add Jenkinsfile
git diff --cached --quiet || git commit -m "chore(jenkins): update parameter defaults from terraform output"
git push

# ---------- 6. Print next steps ----------------------------------------------
echo ""
echo "Infrastructure setup complete!"
echo ""
echo "Next: Set up Jenkins"
echo "  SSH:  ssh -i ~/ms-learning-key.pem ec2-user@$JENKINS_IP"
echo "  URL:  http://$JENKINS_IP:8080  (after Jenkins is installed)"
