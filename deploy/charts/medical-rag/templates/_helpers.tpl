{{/*
Values and snippets shared by several templates.
*/}}

{{/* The image: registry and repository from the account, tag and digest from the values file. */}}
{{- define "medical-rag.image" -}}
{{ required "aws.accountId is required" .Values.aws.accountId }}.dkr.ecr.{{ .Values.aws.region }}.amazonaws.com/medical-rag:{{ required "image.tag is required" .Values.image.tag }}
{{- end }}

{{/* Where the corpus and the index versions live (infra/terraform/shared/storage.tf). */}}
{{- define "medical-rag.bucket" -}}
s3://medical-rag-artifacts-{{ .Values.aws.accountId }}
{{- end }}

{{- define "medical-rag.labels" -}}
app.kubernetes.io/name: medical-rag
app.kubernetes.io/instance: {{ .Release.Name }}
medical-rag/environment: {{ required "environment is required" .Values.environment }}
{{- end }}

{{/*
The pod side of the app's AWS identity: the same four variables and token volume as the proof pod of
app guide step 7. Call it with a dict: (dict "role" "<role name>" "Values" .Values).
*/}}
{{- define "medical-rag.awsEnv" -}}
- name: AWS_ROLE_ARN
  value: arn:aws:iam::{{ .Values.aws.accountId }}:role/{{ .role }}
- name: AWS_WEB_IDENTITY_TOKEN_FILE
  value: /var/run/secrets/aws/token
- name: AWS_REGION
  value: {{ .Values.aws.region }}
- name: AWS_STS_REGIONAL_ENDPOINTS
  value: regional
{{- end }}

{{- define "medical-rag.awsTokenVolume" -}}
- name: aws-token
  projected:
    sources:
      - serviceAccountToken:
          audience: sts.amazonaws.com
          expirationSeconds: 3600
          path: token
{{- end }}

{{/* Pod and container security settings that pass the Pod Security level "restricted". */}}
{{- define "medical-rag.podSecurity" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "medical-rag.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
