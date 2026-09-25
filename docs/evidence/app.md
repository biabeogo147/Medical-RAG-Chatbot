# App phase — 2026-09-19

The chatbot runs in the self-managed cluster in two environments, dev and prod. Argo CD deploys both from
one Helm chart (`deploy/charts/medical-rag`), with one values file per environment. AWS account
`<account-id>`, region `ap-southeast-1`.

Every check was run from the ops workstation. Checks not listed here returned the output the guide expects.
Times come from the cluster's timestamps and logs, in UTC. Log lines are quoted as printed.

## Results

| Criterion | Measured |
|---|---|
| #6 The index is an artifact, built once | Dev's index Job built version `cc759ae1a093` in **149.1 s** (759 pages, 7,079 chunks). The two later runs recorded, dev's and prod's, logged `already exists, skipping build` |
| #7 Readiness | A dev pod went from created to Ready in **10 s**, index download included. Before this phase, each pod built the index when it started; that build takes 149.1 s here and 150.7 s locally ([local.md](local.md)) |
| Answer time | Ten questions in a row to dev: **1.41–2.91 s** each, median 1.74 s |
| #9 Supply chain, "before" | The image has **4 CRITICAL, 14 HIGH, 8 MEDIUM** findings. The four CRITICAL ones are in `openssl` (1) and `perl` (3). The "after" comes in the Jenkins phase |
| Least privilege (dev, step 17) | From the app container, IMDS times out and AWS calls fail with `NoCredentialsError`. Only the init container is given a token |
| A failed build is contained | A wrong index version failed the index Job. The parent Application `root` turned `Degraded`, and the running pod stayed Ready: the new Deployment is applied only after the Job succeeds, so it never was |
| Resources | Set from Prometheus measurements: app 320Mi request, 640Mi limit, 50m CPU. The three app pods reserve 960Mi of memory instead of 2,304Mi |

## Inputs from Parts 1 and 2

| Item | Value |
|---|---|
| Pod identity proof (step 7) | Role `assumed-role/medical-rag-app-dev/…` through the projected token. IMDS from the pod: `curl` timed out (exit 124) |
| Image (step 11) | `medical-rag:1eaa43bf3512@sha256:c10cd57eb4b22d025f2daf772743e7a79f3285233921ef4236e532a75e166769` |
| ECR scan of that image | 4 CRITICAL, 14 HIGH, 8 MEDIUM |
| Index version (step 12) | `cc759ae1a093` |
| Corpus in S3 (step 13) | `corpus/The_GALE…pdf`, 12,226,938 bytes. `faiss/` was empty before step 16 |
| CPU already requested on the three nodes | 1300m, 1355m and 1140m of 2000m (57–68%). That is why step 21 sized the requests from measurements. There is no metrics-server, so all usage figures come from Prometheus |

## Step 14 — Public names

`dev.recruitai.io.vn` and `app.recruitai.io.vn` resolve to the same three addresses as the public load
balancer's own name (`18.136.29.208`, `18.139.34.101`, `54.254.114.68`). `http://dev.recruitai.io.vn/`
answered `404` from ingress-nginx, since nothing was routed yet.

## Step 15 — `root` sees a failed app sync

This step changed the health check of `root`, the Application that owns all the others: a labelled child
Application whose last sync failed now turns `root` `Degraded`. Adding it changed no Application's status.
Step 17 tested it on a real failure.

## Step 16 — The index, built once in the cluster

| Check | Result |
|---|---|
| ExternalSecret `app-secrets` | `Ready=True`. Secret keys `FLASK_SECRET_KEY`, `GOOGLE_API_KEY`, `HUGGINGFACEHUB_API_TOKEN` |
| Order | Secret created `13:59:58`, the Job and its pod `14:00:00`: the Secret existed 2 s before the pod that reads it |
| Build log | `Built index cc759ae1a093: 759 pages, 7079 chunks in 149.1s` (14:02:39) |
| Job peak memory (Prometheus, `container_memory_working_set_bytes`) | 336,347,136 bytes, **320.8 MiB**. Prometheus samples at intervals, so a short spike can be missed: the real peak may be higher |
| Re-run after ten minutes | None: the Job's creation time stayed `14:00:00` |

## Step 17 — Pods from the pinned index

| Check | Result |
|---|---|
| Second sync | `Index version cc759ae1a093 already exists, skipping build` (14:14:33) |
| Job, then Deployment | Job finished `14:14:35`, Deployment created `14:14:35`. Timestamps have one-second precision, so this shows no overlap rather than the order; the order comes from Argo CD, which waits for the hook before the next wave |
| Init container | `Pulled index cc759ae1a093 (7079 chunks) into /tmp/index` (14:14:38) |
| Pod created → Ready | `14:14:36` → `14:14:46`: **10 s** |
| IMDS from the app container | `TimeoutError: timed out` |
| AWS from the app container | `botocore.exceptions.NoCredentialsError: Unable to locate credentials` |
| `/readyz` through a port-forward | `{"status":"ready"}` |

### A failed build, on purpose

Commit `f8a9e6c` pinned a version that does not exist. The value was written without quotes, so YAML read
`000000000000` as the number `0`. The test still failed as intended, but the message names `0`.

| When | Check | Result |
|---|---|---|
| During the retries | `medical-rag-dev`, `root` | `Running Healthy`, `root` `Progressing`. Message `… Retrying attempt #5 at 2:28PM`. The operation showed `initiatedBy: {"automated":true}`, `retry: {"limit":5}`, `retryCount` 5 |
| After them | `medical-rag-dev` | `Failed Healthy`: the sync failed, the running pods are healthy. Message `one or more synchronization tasks completed unsuccessfully (retried 5 times).` |
| | `root` | **`Degraded`**: the step 15 rule |
| | Job log | `ValueError: The corpus builds version cc759ae1a093, but 0 was expected: …` |
| | Serving pod | `medical-rag-76cc748d89-zjc7f`: still `1/1 Running`, 0 restarts, age 23m |

The fifth retry was scheduled for 14:28, seven minutes after the test commit was made. The push time was
not recorded, so the full time to `Failed` is not known.

Commit `6a7c8ac` restored `version: "cc759ae1a093"`, now quoted. That made the rendered objects equal the
live ones again, so the app read `Synced` and automated sync had nothing to start, as the guide expects.
After a refresh, one sync was started by hand (`kubectl patch … operation`).
Result: `Succeeded Healthy`.

## Step 18 — The public name

`/` answered `200`, and `/metrics` and `/healthz` answered `404`. A question got an answer: `302` (the form
redirects after a POST), then one assistant message on the page.

## Step 19 — Prometheus scrapes the app

| Query | Result |
|---|---|
| `up{namespace="medical-rag-dev"}` | `medical-rag-76cc748d89-zjc7f 1`: the pod is scraped |
| `sum by (namespace) (http_requests_total{namespace="medical-rag-dev",route="/"})` | `medical-rag-dev 11`: the requests from step 18 are counted |

## Step 20 — Prod

| Check | Result |
|---|---|
| Prod's Job | `Index version cc759ae1a093 already exists, skipping build` (15:22:32): prod reuses dev's index |
| Prod's init container | `Found 2 pods, using pod/medical-rag-6f784b489d-v4qbp`, then `Pulled index cc759ae1a093 (7079 chunks) into /tmp/index` (15:22:38). The log is from one of the two pods |
| Nodes under the two prod pods | **2** different nodes |
| PodDisruptionBudget `medical-rag` | `disruptionsAllowed` **1**: a node drain can evict one prod pod, never both |
| `http://app.recruitai.io.vn/` | `/` `200`, `/metrics` `404` |
| `root` | `Synced Healthy`, including both app Applications |

## Step 21 — Resources from measurements

Memory is the `app` container's working set. CPU is `rate(container_cpu_usage_seconds_total[5m])`: the
highest 5-minute average in the window.

| Pod | Window | Memory | CPU |
|---|---|---|---|
| dev `…-zjc7f` | last hour, before the questions | 276.2 MiB | 1.5m |
| prod `…-v4qbp` | last hour | 262.7 MiB | 30.0m |
| prod `…-wffhz` | last hour | 268.3 MiB | 29.3m |
| dev `…-zjc7f` | last 30 minutes, including the ten questions | **276.9 MiB** | **1.1m** |

The ten questions to `http://dev.recruitai.io.vn/`, one after another, all answered `302`: 1.41, 1.66,
1.72, 1.46, 1.76, 1.68, 1.88, 2.91, 2.35 and 1.78 s (median 1.74 s, 18.6 s in total).

What the numbers suggest:
- **Memory is most likely the loaded index and libraries.** The peak rose by 0.67 MiB with the ten
  questions.
- **The app mostly waits on Hugging Face and Gemini.** Ten questions in 18.6 s barely move a 5-minute
  average; the 30-minute peak (1.1m) is even below the hour's (1.5m). A 5-minute average hides short
  bursts, which can be higher; they were not measured. There is no CPU limit, so a burst can use idle CPU.
- **Prod's 30m is probably start-up.** The two prod pods come from the ReplicaSet the step 20 sync created
  at about 15:22, and the queries ran after that and before 15:34, so their start is inside the hour.
  Loading the index and libraries costs more CPU than serving. Dev's pod started at 14:14, more than an
  hour before.

Resources set in `deploy/charts/medical-rag/values.yaml` (commit `9f52bf3`), with the guide's rules:

| Container | Setting | Value | From |
|---|---|---|---|
| app | requests.memory | `320Mi` | 276.9 MiB after ten questions in a row, rounded up to the next 64Mi |
| app | limits.memory | `640Mi` | twice the request |
| app | requests.cpu | `50m` | the guide's 50m floor (1.1m measured) |
| index build | requests.memory | `384Mi` | Job peak 320.8 MiB, rounded up to the next 64Mi |
| index build | limits.memory | `1024Mi` | 1.5 × peak is 481 MiB, raised to the 1Gi floor |

The request leaves about 43 MiB above what was measured. The limit is the protection against a real
load, which ten questions in a row are not. Before, the guesses were 768Mi to 1,536Mi for the app and
512Mi to 2Gi for the Job. The three app pods now reserve 960Mi of memory instead of 2,304Mi, and 150m of
CPU instead of 300m.

## Supply chain baseline (criterion #9)

CRITICAL findings in `medical-rag:1eaa43bf3512`:

| CVE | Package |
|---|---|
| CVE-2026-75803 | `openssl` |
| CVE-2026-57433 | `perl` |
| CVE-2026-12087 | `perl` |
| CVE-2026-13221 | `perl` |

The Jenkins phase hardens the base image and measures again. **Done:** Debian 13, CRITICAL 5 → 0, total
269 → 158 ([`jenkins.md`](jenkins.md) step 13).

## Problems found and fixed during this phase

| Problem | Root cause | Fix |
|---|---|---|
| The failure test left `root` `Progressing` for minutes. The guide expected `Degraded` at once | With no `syncPolicy.retry` in the Application, Argo CD gives each automated sync `retry: {limit: 5}` itself (`controller/appcontroller.go`, confirmed by the operation's status above). The phase stays `Running` until the last retry fails | Steps 15 and 17 explain the retries; the test now waits for `Failed` |
| The test's Job said `but 0 was expected` | YAML read the unquoted `000000000000` as the number `0` | Index versions are quoted in the values files |
| Both Prometheus queries of step 19 came back empty | Commit `822d377` was pushed to `app/step-18` instead of `app/step-19`, so `main` stayed at `d031ee0`. Found by comparing the Application's revision with `git ls-remote` | Step 19 now checks the commit on `main` before it waits for the sync |

## Still to check

- The `rag_index_info` line from `/metrics` in step 17: the `grep` printed nothing, and it was not checked
  again. Expected: `rag_index_info{version="cc759ae1a093"} 1.0`.
- The dev line of the 21.1 queries rerun with `[15m]` after the questions was not recorded. The 30-minute
  queries above were used instead.
