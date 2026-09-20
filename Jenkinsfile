// Step 9 only: prove that a build pod gets the CI role and cannot reach the node's metadata service.
// Part 3 replaces this with the real pipeline.
pipeline {
  agent {
    kubernetes {
      // Named explicitly, so a cloud misconfigured in step 8 fails here instead of quietly starting the pod
      // in the wrong namespace.
      cloud 'kubernetes'
      namespace 'jenkins-agents'
      defaultContainer 'tools'
      yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-agent
  automountServiceAccountToken: false
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
  containers:
    - name: tools
      # The tag you verified in app guide step 7: `aws --version` on the workstation prints it.
      image: public.ecr.aws/aws-cli/aws-cli:<aws-cli version>
      # `cat` with a tty keeps the container alive for the whole build, however long it takes; `sleep 3600`
      # would end it after an hour.
      command: ["cat"]
      tty: true
      env:
        # The same four variables the app's pods use (app guide step 7), for the CI role.
        - name: AWS_ROLE_ARN
          value: arn:aws:iam::242834061265:role/medical-rag-ci
        - name: AWS_WEB_IDENTITY_TOKEN_FILE
          value: /var/run/secrets/aws/token
        - name: AWS_REGION
          value: ap-southeast-1
        - name: AWS_STS_REGIONAL_ENDPOINTS
          value: regional
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 512Mi
      volumeMounts:
        - name: aws-token
          mountPath: /var/run/secrets/aws
          readOnly: true
  volumes:
    - name: aws-token
      projected:
        sources:
          - serviceAccountToken:
              audience: sts.amazonaws.com
              expirationSeconds: 3600
              path: token
'''
    }
  }
  options { disableConcurrentBuilds() }
  stages {
    stage('Who am I') {
      steps {
        sh 'aws sts get-caller-identity'
        sh 'curl -sS -m 3 http://169.254.169.254/latest/meta-data/ || echo "IMDS unreachable, exit=$?"'
      }
    }
  }
}
