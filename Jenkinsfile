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
  volumes:
    - name: buildkitd
      # BuildKit's local cache. Bounded, so a runaway build cannot fill the node's disk.
      emptyDir:
        sizeLimit: 8Gi
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
  }
}
