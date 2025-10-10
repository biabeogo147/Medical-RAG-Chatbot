pipeline {
    agent any

    environment {
        DOCKERHUB_CREDENTIALS = credentials('dockerhub')
        IMAGE_NAME = "biabeogo147/medical-rag-chatbot-app"
        VERSION = "v1.0.${env.BUILD_NUMBER}"
        K8S_NAMESPACE = "medical-rag-chatbot"
        DEPLOY_FILE = "k8s.yaml"
    }

    stages {
        stage('Checkout') {
            steps {
                git branch: 'main', credentialsId: 'github', url: 'https://github.com/biabeogo147/Medical-RAG-Chatbot.git'
            }
        }

        stage('Docker Login') {
            steps {
                script {
                    echo "🔐 Logging into Docker Hub..."
                    withCredentials([usernamePassword(credentialsId: 'dockerhub', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                        #!/bin/bash
                        set -eux

                        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                        '''
                    }
                }
            }
        }

        stage('Build Docker image') {
            steps {
                sh '''
                echo "🧱 Building Docker image $IMAGE_NAME:$VERSION ..."
                docker build -t $IMAGE_NAME:$VERSION .
                docker tag $IMAGE_NAME:$VERSION $IMAGE_NAME:latest
                '''
            }
        }

        stage('Push to DockerHub') {
            steps {
                script {
                    echo "🚀 Pushing $IMAGE_NAME:$VERSION to Docker Hub..."
                    withCredentials([usernamePassword(credentialsId: 'dockerhub', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                        echo "🚀 Pushing $IMAGE_NAME:$VERSION..."
                        docker push $IMAGE_NAME:$VERSION

                        echo "🚀 Pushing $IMAGE_NAME:latest..."
                        docker push $IMAGE_NAME:latest

                        echo "🔒 Logging out..."
                        docker logout
                        '''
                    }
                }
            }
        }

        stage('Cleanup') {
            steps {
                sh '''
                echo "🧹 Cleaning up local Docker images..."
                docker rmi -f $IMAGE_NAME:$VERSION || true
                docker rmi -f $IMAGE_NAME:latest || true

                echo "🧹 Cleaning up dangling data..."
                docker system prune -af || true
                '''
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                sh '''
                echo "📦 Deploying to Kubernetes cluster..."
                # Create a temp file instead of editing in-place
                sed "s|biabeogo147/medical-rag-chatbot-app:.*|$IMAGE_NAME:$VERSION|g" $DEPLOY_FILE > deploy-temp.yaml

                # Debug check
                kubectl config current-context || true
                kubectl get ns | grep $K8S_NAMESPACE || kubectl create ns $K8S_NAMESPACE

                kubectl apply -f deploy-temp.yaml -n $K8S_NAMESPACE
                '''
            }
        }
    }

    post {
        success {
            echo "✅ Successfully deployed version $VERSION to $K8S_NAMESPACE!"
        }
        failure {
            echo "❌ Deployment failed at some stage. Check logs for details."
        }
    }
}
