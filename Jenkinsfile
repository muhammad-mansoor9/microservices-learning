pipeline {
    agent any

    environment {
        AWS_REGION  = 'us-east-1'
        S3_BUCKET   = 'ms-learning-artifacts'
        ANSIBLE_DIR = "${WORKSPACE}/ansible"
        JAVA_HOME   = '/usr/lib/jvm/java-21-amazon-corretto'
    }

    parameters {
        string(name: 'ALB_DNS',              defaultValue: 'ms-learning-alb-287042979.us-east-1.elb.amazonaws.com', description: 'ALB DNS name')
        string(name: 'EUREKA_HOST',          defaultValue: '10.0.3.25',    description: 'Eureka private IP')
        string(name: 'CONFIG_HOST',          defaultValue: '10.0.3.136',   description: 'Config-server private IP')
        string(name: 'RABBITMQ_HOST',        defaultValue: '10.0.4.158',   description: 'RabbitMQ private IP')
        string(name: 'KEYCLOAK_HOST',        defaultValue: '10.0.4.199',   description: 'Keycloak private IP')
        string(name: 'DB_HOST',              defaultValue: 'ms-learning-postgres.c8xm6w2gsz3i.us-east-1.rds.amazonaws.com', description: 'PostgreSQL RDS host')
        string(name: 'KEYCLOAK_ISSUER_URI',  defaultValue: 'http://10.0.4.199:9090/realms/ms-learning', description: 'Keycloak issuer URI')
        string(name: 'CONFIG_REPO_URI',      defaultValue: 'https://github.com/muhammad-mansoor9/ms-learning-config-repo', description: 'Spring Cloud Config git repo')
        string(name: 'USER_SERVICE_HOST',    defaultValue: '',             description: 'Private IP of user-service EC2 (from terraform output user_service_private_ip)')
        string(name: 'PAYMENT_SERVICE_HOST', defaultValue: '',             description: 'Private IP of payment-service EC2 (from terraform output payment_service_private_ip)')
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
                            -e config_repo_uri=${params.CONFIG_REPO_URI} \
                            -e user_service_host=${params.USER_SERVICE_HOST} \
                            -e payment_service_host=${params.PAYMENT_SERVICE_HOST} \
                            -e "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
                    """
                }
            }
        }

        stage('Smoke Test') {
            steps {
                sh """
                    echo "Waiting 60s for Eureka registration to propagate..."
                    sleep 60
                    echo "Smoke test → http://${params.ALB_DNS}/actuator/health"
                    HTTP_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" \
                        http://${params.ALB_DNS}/actuator/health)
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
