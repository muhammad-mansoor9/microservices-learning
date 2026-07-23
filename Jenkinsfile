pipeline {
    agent any

    environment {
        AWS_REGION  = 'us-east-1'
        S3_BUCKET   = 'ms-learning-artifacts'
        ANSIBLE_DIR = "${WORKSPACE}/ansible"
    }

    parameters {
        // --- Infrastructure IPs (copy from: terraform output) ---
        string(name: 'ALB_DNS',             description: 'ALB DNS name          → terraform output alb_dns_name')
        string(name: 'EUREKA_HOST',         description: 'Eureka private IP      → terraform output eureka_server_private_ip')
        string(name: 'CONFIG_HOST',         description: 'Config-server priv IP  → terraform output config_server_private_ip')
        string(name: 'RABBITMQ_HOST',       description: 'RabbitMQ private IP    → terraform output rabbitmq_private_ip')
        string(name: 'KEYCLOAK_HOST',       description: 'Keycloak private IP    → terraform output keycloak_private_ip')
        string(name: 'DB_HOST',             description: 'PostgreSQL host IP     (same instance as app, or a dedicated server)')
        string(name: 'KEYCLOAK_ISSUER_URI', description: 'Keycloak issuer URI    e.g. http://<keycloak-ip>:9090/realms/ms-learning')
        string(name: 'CONFIG_REPO_URI',     description: 'Git URI for Spring Cloud Config prod files (e.g. https://github.com/you/config-repo)')
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build All') {
            parallel {
                stage('config-server') {
                    steps { sh 'mvn -f config-server/pom.xml  clean package -DskipTests' }
                }
                stage('eureka-server') {
                    steps { sh 'mvn -f eureka-server/pom.xml  clean package -DskipTests' }
                }
                stage('user-service') {
                    steps { sh 'mvn -f user-service/pom.xml   clean package -DskipTests' }
                }
                stage('payment-service') {
                    steps { sh 'mvn -f payment-service/pom.xml clean package -DskipTests' }
                }
                stage('order-service') {
                    steps { sh 'mvn -f order-service/pom.xml  clean package -DskipTests' }
                }
                stage('api-gateway') {
                    steps { sh 'mvn -f api-gateway/pom.xml    clean package -DskipTests' }
                }
            }
        }

        stage('Upload to S3') {
            steps {
                withCredentials([[
                    $class:            'AmazonWebServicesCredentialsBinding',
                    credentialsId:     'aws-ms-learning',
                    accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                    secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                ]]) {
                    sh """
                        aws s3 cp config-server/target/config-server-*.jar   s3://${S3_BUCKET}/${BUILD_NUMBER}/config-server.jar   --region ${AWS_REGION}
                        aws s3 cp eureka-server/target/eureka-server-*.jar   s3://${S3_BUCKET}/${BUILD_NUMBER}/eureka-server.jar   --region ${AWS_REGION}
                        aws s3 cp user-service/target/user-service-*.jar     s3://${S3_BUCKET}/${BUILD_NUMBER}/user-service.jar     --region ${AWS_REGION}
                        aws s3 cp payment-service/target/payment-service-*.jar s3://${S3_BUCKET}/${BUILD_NUMBER}/payment-service.jar --region ${AWS_REGION}
                        aws s3 cp order-service/target/order-service-*.jar   s3://${S3_BUCKET}/${BUILD_NUMBER}/order-service.jar   --region ${AWS_REGION}
                        aws s3 cp api-gateway/target/api-gateway-*.jar       s3://${S3_BUCKET}/${BUILD_NUMBER}/api-gateway.jar     --region ${AWS_REGION}
                    """
                }
            }
        }

        stage('Deploy via Ansible') {
            steps {
                withCredentials([
                    sshUserPrivateKey(
                        credentialsId: 'ms-learning-ec2-key',
                        keyFileVariable: 'SSH_KEY_FILE'
                    ),
                    string(credentialsId: 'ms-learning-internal-api-key', variable: 'INTERNAL_API_KEY'),
                    string(credentialsId: 'ms-learning-db-password',      variable: 'DB_PASSWORD'),
                    [
                        $class:            'AmazonWebServicesCredentialsBinding',
                        credentialsId:     'aws-ms-learning',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                    ]
                ]) {
                    sh """
                        ansible-playbook \
                            -i ${ANSIBLE_DIR}/inventory.aws_ec2.yml \
                            ${ANSIBLE_DIR}/playbooks/deploy-all.yml \
                            --private-key ${SSH_KEY_FILE} \
                            -e build_number=${BUILD_NUMBER} \
                            -e s3_bucket=${S3_BUCKET} \
                            -e eureka_host=${params.EUREKA_HOST} \
                            -e config_host=${params.CONFIG_HOST} \
                            -e rabbitmq_host=${params.RABBITMQ_HOST} \
                            -e keycloak_host=${params.KEYCLOAK_HOST} \
                            -e db_host=${params.DB_HOST} \
                            -e db_password=\$DB_PASSWORD \
                            -e keycloak_issuer_uri=${params.KEYCLOAK_ISSUER_URI} \
                            -e config_repo_uri=${params.CONFIG_REPO_URI}
                    """
                }
            }
        }

        stage('Smoke Test') {
            steps {
                sh """
                    echo "Smoke test → http://${params.ALB_DNS}/api/orders/actuator/health"
                    HTTP_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" \
                        http://${params.ALB_DNS}/api/orders/actuator/health)
                    echo "Response: \${HTTP_STATUS}"
                    if [ "\${HTTP_STATUS}" != "200" ]; then
                        echo "FAILED — expected 200, got \${HTTP_STATUS}"
                        exit 1
                    fi
                    echo "PASSED"
                """
            }
        }
    }

    post {
        success {
            echo "Build #${BUILD_NUMBER} deployed successfully. ALB: http://${params.ALB_DNS}"
        }
        failure {
            echo "Build #${BUILD_NUMBER} FAILED. Check the stage logs above."
        }
    }
}
