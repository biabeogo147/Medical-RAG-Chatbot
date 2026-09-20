// The pipeline for this repository (Jenkins guide, Part 3). Every tool version is pinned here, so a change
// of tool is a commit like any other.
//
// Stages that write anything outside the build pod run only on main: signing, the dev bump and the prod pull
// request. Branch builds test, build and scan, and stop there.
//
// The pod's identity was proved separately in step 9: a build pod reaches AWS as medical-rag-ci and the
// metadata service does not answer it. See docs/evidence/jenkins.md.

// Values that appear in more than one place. No `def`: that would make them local to one method, and the
// closures below (the pod definition, every sh line) would not see them.
ACCOUNT   = '242834061265'
REGION    = 'ap-southeast-1'
REGISTRY  = "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE     = "${REGISTRY}/medical-rag"
BUILDKIT  = 'moby/buildkit:v0.33.0-rootless'
CI_TOOLS  = "${REGISTRY}/medical-rag-ci:2ed703f3a494@sha256:106f85c5a76dcd1847e1c8e20ece5933f7b733cabbe4e9d93f64b2f431e6b38f"   // printed by `make ci-image`

pipeline {
  agent {
    kubernetes {
      defaultContainer 'buildkit'
      yaml """
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
    - name: buildkit
      image: ${BUILDKIT}
      command: ["sleep"]
      args: ["3600"]
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
        - name: DOCKER_CONFIG
          value: /home/jenkins/agent/.docker
      securityContext:
        seccompProfile:
          type: Unconfined
        appArmorProfile:
          type: Unconfined
      resources:
        requests:
          cpu: 300m
          memory: 1Gi
        limits:
          memory: 3Gi
      volumeMounts:
        - name: buildkitd
          mountPath: /home/user/.local/share/buildkit
    - name: tools
      image: ${CI_TOOLS}
      command: ["sleep"]
      args: ["3600"]
      env:
        - name: AWS_ROLE_ARN
          value: arn:aws:iam::${ACCOUNT}:role/medical-rag-ci
        - name: AWS_WEB_IDENTITY_TOKEN_FILE
          value: /var/run/secrets/aws/token
        - name: AWS_REGION
          value: ${REGION}
        - name: AWS_ACCOUNT
          value: "${ACCOUNT}"
        - name: AWS_STS_REGIONAL_ENDPOINTS
          value: regional
        # Both containers read the login from the same place in the workspace.
        - name: DOCKER_CONFIG
          value: /home/jenkins/agent/.docker
      resources:
        requests:
          cpu: 50m
          memory: 192Mi
        limits:
          memory: 512Mi
      volumeMounts:
        - name: aws-token
          mountPath: /var/run/secrets/aws
          readOnly: true
    - name: trivy
      image: aquasec/trivy:0.74.0
      command: ["sleep"]
      args: ["3600"]
      env:
        # Trivy reads the registry login the tools container wrote.
        - name: DOCKER_CONFIG
          value: /home/jenkins/agent/.docker
        - name: TRIVY_CACHE_DIR
          value: /home/jenkins/agent/.trivy
      resources:
        requests:
          cpu: 50m
          memory: 384Mi
        limits:
          memory: 1Gi
  volumes:
    - name: buildkitd
      # BuildKit's local cache. Bounded, so a runaway build cannot fill the node's disk.
      emptyDir:
        sizeLimit: 8Gi
    - name: aws-token
      projected:
        sources:
          - serviceAccountToken:
              audience: sts.amazonaws.com
              expirationSeconds: 3600
              path: token
"""
    }
  }

  options {
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  stages {
    stage('Skip guard') {
      steps {
        script {
          // The author of the newest commit, and the files it changed.
          def author = sh(returnStdout: true, script: 'git log -1 --format=%an').trim()
          def files  = sh(returnStdout: true, script: 'git show --pretty= --name-only HEAD').trim()
          def onlyDocs = files && files.split('\\n').every { f ->
            f.startsWith('deploy/') || f.startsWith('docs/') || f.endsWith('.md')
          }
          // An empty list means "unknown", and unknown counts as a build: skipping on doubt hides changes.
          if (author == 'jenkins-bot' || onlyDocs) {
            currentBuild.result = 'NOT_BUILT'
            error("Nothing to build: author=${author}, only docs or deploy files changed")
          }
        }
      }
    }

    stage('Test') {
      steps {
        // The Dockerfile's test target runs ruff and pytest. No registry login exists yet, so the
        // repository's own code runs with no credential of any kind.
        sh """
          buildctl-daemonless.sh build \
            --frontend dockerfile.v0 \
            --local context=. \
            --local dockerfile=. \
            --opt target=test \
            --import-cache type=registry,ref=${IMAGE}:buildcache
        """
      }
    }

    stage('Log in to ECR') {
      steps {
        container('tools') {
          // The token in the pod is exchanged for the CI role here; the login lands in the shared workspace,
          // so BuildKit can push with it. The tests above ran before this existed.
          sh """
            # Jenkins runs every sh step as `/bin/sh -xe`, which echoes each command with its variables
            # already expanded. Without this line the ECR password and the base64 auth string are both
            # printed into the build log in full, where they stay valid for 12 hours. stdout is not
            # affected, so the caller identity below still prints.
            set +x
            aws sts get-caller-identity --query Arn --output text
            mkdir -p "\${DOCKER_CONFIG}"
            PASS=\$(aws ecr get-login-password --region "\${AWS_REGION}")
            # openssl, not base64: busybox's base64 wraps long lines, which would break the JSON.
            AUTH=\$(printf 'AWS:%s' "\${PASS}" | openssl base64 -A)
            printf '{"auths":{"%s":{"auth":"%s"}}}' "${REGISTRY}" "\${AUTH}" > "\${DOCKER_CONFIG}/config.json"
          """
        }
      }
    }

    stage('Build and push') {
      steps {
        script {
          env.GIT_TAG = sh(returnStdout: true, script: 'git rev-parse --short=12 HEAD').trim()
        }
        // The cache lives in the registry, under the mutable tag buildcache. Branch builds only read it:
        // only main writes it, so a branch cannot poison what main builds from (README §3).
        sh """
          CACHE_EXPORT=""
          if [ "\${BRANCH_NAME}" = "main" ]; then
            CACHE_EXPORT="--export-cache type=registry,ref=${IMAGE}:buildcache,mode=max"
          fi
          buildctl-daemonless.sh build \
            --frontend dockerfile.v0 \
            --local context=. \
            --local dockerfile=. \
            --opt target=runtime \
            --import-cache type=registry,ref=${IMAGE}:buildcache \
            \${CACHE_EXPORT} \
            --output type=image,name=${IMAGE}:\${GIT_TAG},push=true \
            --metadata-file build-metadata.json
        """
        script {
          env.IMAGE_DIGEST = sh(returnStdout: true,
            script: 'grep -o \'"containerimage.digest": *"[^"]*"\' build-metadata.json | cut -d\\" -f4').trim()
          echo "Image ${IMAGE}:${env.GIT_TAG}@${env.IMAGE_DIGEST}"
        }
      }
    }

    stage('Scan') {
      steps {
        container('trivy') {
          // Scan once, into a report. The gate then reads that report, so the record exists even when the
          // gate fails; scanning first and failing second is the only order that keeps both.
          sh "trivy image --scanners vuln --format json --output trivy-report.json ${IMAGE}@${env.IMAGE_DIGEST}"
          sh "trivy convert --format table trivy-report.json"
        }
        // The gate, in the tools container because it is the one with jq. `trivy convert` has no
        // --ignore-unfixed: that flag belongs to the scan commands, and convert only offers --severity
        // and --exit-code, which together would fail every build on findings nobody can act on. So the
        // gate counts them here instead: CRITICAL findings that carry a fixed version. Unfixed ones are
        // ignored on purpose — a gate that can never pass is a gate people switch off (concepts §2).
        container('tools') {
          sh """
            N=\$(jq '[.Results[]?.Vulnerabilities[]?
                        | select(.Severity == "CRITICAL")
                        | select(.FixedVersion != null and .FixedVersion != "")] | length' trivy-report.json)
            echo "CRITICAL with a fix available: \$N"
            [ "\$N" -eq 0 ]
          """
        }
      }
      post {
        always { archiveArtifacts artifacts: 'trivy-report.json', fingerprint: true, allowEmptyArchive: true }
      }
    }

    stage('SBOM and signature') {
      when { branch 'main' }
      steps {
        container('trivy') {
          sh "trivy image --format spdx-json --output sbom.spdx.json ${IMAGE}@${env.IMAGE_DIGEST}"
        }
        container('tools') {
          // The key never leaves KMS; the pipeline may only ask it to sign (Jenkins guide step 3).
          // The public Rekor log is not used: these images are private, so their digests, repository
          // name and account id have no business in a public log, and verification here uses the key.
          //
          // cosign v3 removed the flags that used to say so. `--tlog-upload=false` is deprecated on
          // `sign` and refuses to run alongside the signing config v3 enables by default; on `attest` the
          // flag is gone entirely, and so are --rekor-url and --offline. What replaces them is a signing
          // config listing the services to use. Created with no services at all, it names no transparency
          // log, which is exactly the intent. It is generated here rather than baked into the tools image
          // so that it always matches the cosign that reads it, and building it needs no network.
          sh """
            cosign signing-config create --out signing-config.json
            cosign sign --yes --signing-config signing-config.json \
              --key awskms:///alias/medical-rag-cosign ${IMAGE}@${env.IMAGE_DIGEST}
            cosign attest --yes --signing-config signing-config.json \
              --type spdxjson --predicate sbom.spdx.json \
              --key awskms:///alias/medical-rag-cosign ${IMAGE}@${env.IMAGE_DIGEST}
          """
        }
      }
      post {
        always { archiveArtifacts artifacts: 'sbom.spdx.json', fingerprint: true }
      }
    }

    stage('Index version') {
      steps {
        // The version comes from the image's own code and the corpus in Git, exported to a local file.
        sh '''
          buildctl-daemonless.sh build \
            --frontend dockerfile.v0 \
            --local context=. \
            --local dockerfile=. \
            --opt target=indexversion-out \
            --output type=local,dest=version-out
        '''
        container('tools') {
          // `readYaml` would be shorter, but it comes from pipeline-utility-steps and this controller
          // installs only the plugins listed in deploy/argocd/values/jenkins.yaml. The tools image already
          // carries yq, so nothing new has to be installed to read two fields.
          script {
            env.INDEX_VERSION = readFile('version-out/version.txt').trim()
            env.DEV_VERSION   = sh(returnStdout: true,
              script: "yq -r '.index.version' deploy/envs/dev/values.yaml").trim()
            env.PROD_VERSION  = sh(returnStdout: true,
              script: "yq -r '.index.version' deploy/envs/prod/values.yaml").trim()
            env.INDEX_CHANGED_DEV  = (env.INDEX_VERSION == env.DEV_VERSION) ? 'no' : 'yes'
            env.INDEX_CHANGED_PROD = (env.INDEX_VERSION == env.PROD_VERSION) ? 'no' : 'yes'
            echo "index version: built=${env.INDEX_VERSION} dev=${env.DEV_VERSION} prod=${env.PROD_VERSION}"
          }
        }
        script {
          if (env.INDEX_CHANGED_DEV == 'yes' || env.INDEX_CHANGED_PROD == 'yes') {
            container('tools') {
              // The Job in the cluster reads the corpus from S3, so the new version may only be deployed if
              // S3 already holds exactly the PDF in Git. The CI role may read corpus/ and nothing else.
              sh '''
                set -e
                PDF=$(ls data/*.pdf | head -1)
                LOCAL=$(openssl dgst -sha256 -binary "$PDF" | base64)
                REMOTE=$(aws s3api head-object --bucket "medical-rag-artifacts-${AWS_ACCOUNT}" \
                  --key "corpus/$(basename "$PDF")" --checksum-mode ENABLED \
                  --query ChecksumSHA256 --output text 2>/dev/null || echo "missing")
                echo "corpus local=$LOCAL s3=$REMOTE"
                test "$LOCAL" = "$REMOTE" || {
                  echo "The corpus in S3 is not the PDF in Git. Upload it first (app guide step 13), then rerun."
                  exit 1
                }
              '''
            }
          }
        }
      }
    }

  }
}
