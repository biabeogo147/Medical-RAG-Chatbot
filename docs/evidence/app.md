# App phase — 2026-09-19

The chatbot runs in the self-managed cluster, deployed by Argo CD from `deploy/charts/medical-rag` with
`deploy/envs/dev/values.yaml`. AWS account `<account-id>`, region `ap-southeast-1`. Every check was run
from the ops workstation; checks not listed below returned exactly their expected output in the guide.

## Inputs from Parts 1 and 2

| Item | Value |
|---|---|
| Pod identity proof (step 7) | Role `assumed-role/medical-rag-app-dev/…` through the projected token; IMDS from the pod: `exit=124` (timeout) |
| Image (step 11) | `medical-rag:1eaa43bf3512@sha256:c10cd57eb4b22d025f2daf772743e7a79f3285233921ef4236e532a75e166769` |
| ECR scan of that image | **CRITICAL 4, HIGH 14, MEDIUM 8**: the "before" of criterion #9 |
| Index version (step 12) | `cc759ae1a093` |
| Corpus in S3 (step 13) | `corpus/The_GALE…pdf`, 12 226 938 bytes; `faiss/` empty before step 16 |
| CPU requests already on the nodes | 1300m / 1355m / 1140m of 2000m each; no metrics-server |

## Step 14 — Public names

`dev.recruitai.io.vn` and `app.recruitai.io.vn` resolve to the public NLB's three addresses
(`18.136.29.208`, `18.139.34.101`, `54.254.114.68`), the same as the NLB's own name. `http://dev.recruitai.io.vn/`
answered `404` from ingress-nginx, as nothing was routed yet.

## Step 16 — The index, built once in the cluster

| Check | Result |
|---|---|
| ExternalSecret `app-secrets` | `Ready=True`; Secret keys `FLASK_SECRET_KEY`, `GOOGLE_API_KEY`, `HUGGINGFACEHUB_API_TOKEN` |
| Build log | `Built index cc759ae1a093: 759 pages, 7079 chunks in 149.1s` (14:02:39) |
| Job peak memory (Prometheus, `container_memory_working_set_bytes`, 30 s samples) | **336 347 136 bytes ≈ 321 MiB**; the true peak is at least this |
| Re-run after ten minutes | None: the Job's `creationTimestamp` stayed `2026-09-19T14:00:00Z` |

Order, from the cluster's own timestamps: Secret `app-secrets` `13:59:58Z`, Job and its pod `14:00:00Z`.
The Secret existed **2 s before** the pod that needs it: wave 0 before the wave 1 hook.

## Step 17 — Pods from the pinned index

| Check | Result |
|---|---|
| Second sync | `Index version cc759ae1a093 already exists, skipping build` (14:14:33) — **criterion #6: built once, skipped after** |
| Hook before Deployment | Job `completionTime` `14:14:35Z` = Deployment `creationTimestamp` `14:14:35Z` |
| Init container | `Pulled index cc759ae1a093 (7079 chunks) into /tmp/index` (14:14:38) |
| Pod created → Ready | `14:14:36Z` → `14:14:46Z`: **10 s — criterion #7** |
| IMDS from the app container | `TimeoutError: timed out` |
| AWS from the app container | `botocore.exceptions.NoCredentialsError: Unable to locate credentials` |
| `/readyz` through a port-forward | `{"status":"ready"}` |

The app container has no AWS identity at all: only the init container mounts the token.

### A failed build, on purpose

`index.version` pinned to a version that does not exist (commit `f8a9e6c`). The value was written without
quotes, so YAML read `000000000000` as the number `0`; the test failed as intended, with `0` in the message.

| Check | Result |
|---|---|
| Argo CD | `Failed Healthy`, message `one or more synchronization tasks completed unsuccessfully (retried 5 times).` |
| `root` | **`Degraded`**: the step 15 rule, proven on a real failure |
| Job log | `ValueError: The corpus builds version cc759ae1a093, but 0 was expected: …` |
| Serving pod | `medical-rag-76cc748d89-zjc7f` `1/1 Running`, restarts 0: wave 2 was never applied |

Argo CD retried the failed automated sync five times before marking it `Failed`: with no
`syncPolicy.retry`, it gives each automated sync `retry: {limit: 5}` itself. `root` read `Progressing`
during the retries and `Degraded` after them. The time from the push to `Failed` was not measured on
this run.

The fix (commit `6a7c8ac`, `version: "cc759ae1a093"` restored, now quoted) left the app `Synced` with its last sync `Failed`, so one sync
was started by hand (`kubectl patch … operation`). Result: `Succeeded Healthy`.

## Step 18 — The public name

`/` answered `200`, `/metrics` and `/healthz` answered `404`, and a question got an answer (`302`, one
assistant message).

## Step 19 — Prometheus scrapes the app

| Query | Result |
|---|---|
| `up{namespace="medical-rag-dev"}` | `medical-rag-76cc748d89-zjc7f 1` |
| `sum by (namespace) (http_requests_total{namespace="medical-rag-dev",route="/"})` | `medical-rag-dev 11` |

The step 19 commit was first pushed to the wrong temporary branch (`app/step-18`), so `main` and Argo CD
stayed on step 18 and both queries came back empty until `main` was moved.
