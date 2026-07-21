pipeline {
    agent any

    environment {
        AWS_REGION     = 'us-east-1'
        S3_BUCKET      = 'ms-learning-artifacts'
        ANSIBLE_DIR    = "${WORKSPACE}/ansible"
        // Resolved from Terraform output or a Jenkins parameter
        ALB_DNS        = "${params.ALB_DNS}"
        EUREKA_HOST    = "${params.EUREKA_HOST}"
        CONFIG_HOST    = "${params.CONFIG_HOST}"
    }

    parameters {
        string(name: 'ALB_DNS',     description: 'ALB DNS name (from terraform output alb_dns_name)')
        string(name: 'EUREKA_HOST', description: 'Eureka server private IP')
        string(name: 'CONFIG_HOST', description: 'Config server private IP')
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
                    steps {
                        sh 'mvn -f config-server/pom.xml clean package -DskipTests'
                    }
                }
                stage('eureka-server') {
                    steps {
                        sh 'mvn -f eureka-server/pom.xml clean package -DskipTests'
                    }
                }
                stage('user-service') {
                    steps {
                        sh 'mvn -f user-service/pom.xml clean package -DskipTests'
                    }
                }
                stage('payment-service') {
                    steps {
                        sh 'mvn -f payment-service/pom.xml clean package -DskipTests'
                    }
                }
                stage('order-service') {
                    steps {
                        sh 'mvn -f order-service/pom.xml clean package -DskipTests'
                    }
                }
                stage('api-gateway') {
                    steps {
                        sh 'mvn -f api-gateway/pom.xml clean package -DskipTests'
                    }
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
                        aws s3 cp config-server/target/config-server-*.jar  \
                            s3://${S3_BUCKET}/${BUILD_NUMBER}/config-server.jar  --region ${AWS_REGION}
                        aws s3 cp eureka-server/target/eureka-server-*.jar  \
                            s3://${S3_BUCKET}/${BUILD_NUMBER}/eureka-server.jar  --region ${AWS_REGION}
                        aws s3 cp user-service/target/user-service-*.jar    \
                            s3://${S3_BUCKET}/${BUILD_NUMBER}/user-service.jar   --region ${AWS_REGION}
                        aws s3 cp payment-service/target/payment-service-*.jar \
                            s3://${S3_BUCKET}/${BUILD_NUMBER}/payment-service.jar --region ${AWS_REGION}
                        aws s3 cp order-service/target/order-service-*.jar  \
                            s3://${S3_BUCKET}/${BUILD_NUMBER}/order-service.jar  --region ${AWS_REGION}
                        aws s3 cp api-gateway/target/api-gateway-*.jar      \
                            s3://${S3_BUCKET}/${BUILD_NUMBER}/api-gateway.jar    --region ${AWS_REGION}
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
                            -e eureka_host=${EUREKA_HOST} \
                            -e config_host=${CONFIG_HOST}
                    """
                }
            }
        }

        stage('Smoke Test') {
            steps {
                sh """
                    echo "Running smoke test against ALB: ${ALB_DNS}"
                    HTTP_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" \
                        http://${ALB_DNS}/api/orders/actuator/health)
                    echo "Health endpoint returned: \${HTTP_STATUS}"
                    if [ "\${HTTP_STATUS}" != "200" ]; then
                        echo "Smoke test FAILED — expected 200, got \${HTTP_STATUS}"
                        exit 1
                    fi
                    echo "Smoke test PASSED"
                """
            }
        }
    }

    post {
        success {
            echo "Deployment of build #${BUILD_NUMBER} to EC2 succeeded. ALB: http://${ALB_DNS}"
        }
        failure {
            echo "Deployment of build #${BUILD_NUMBER} FAILED. Check stage logs above for details."
        }
    }
}
