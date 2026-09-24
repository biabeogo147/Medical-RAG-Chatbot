# Thuật ngữ

Hai tầng. **Tầng chọn lọc** ở dưới đây: những từ người phỏng vấn thật sự hỏi, định nghĩa đủ mức nói ra miệng,
mỗi mục ghi chỗ tra lại. **Tầng đầy đủ** ở cuối trang: 91 mục nguyên văn từ ba bảng glossary trong repo, bấm mở.

Một định nghĩa lỏng là một lời mời đào sâu. Nếu chỉ thuộc được một tầng, thuộc tầng trên.

---

## Kubernetes tự dựng

| Từ | Nói thế này |
|---|---|
| **kubeadm** | Công cụ dựng cụm Kubernetes: nó tạo control plane, sinh chứng chỉ, và in ra lệnh để node khác join. Nó **không** quản lý cụm sau đó. |
| **Stacked control plane** | etcd chạy *trên chính* node control plane, không phải một cụm etcd riêng. Ba node ở đây = ba thành viên etcd. Gọn hơn, nhưng mất một node là mất cả một API server *và* một thành viên etcd. |
| **Quorum** | etcd cần quá nửa thành viên sống để **ghi** được. 3 thành viên chịu mất 1; mất 2 thì cụm **ngừng nhận ghi**. Đây là lý do số node control plane luôn là số lẻ. |
| **API server** | Process mà mọi lệnh `kubectl` đi tới. Ở đây nó còn **ký token ServiceAccount**, nên nó cũng là gốc của phần danh tính. |
| **kubelet** | Agent trên mỗi node, chạy pod và trả lời probe. Nó là thứ *dừng* pod khi snapshot được restore về quá khứ. |
| **Lease của node** | Bản ghi node dùng để nói "tôi còn sống", gia hạn liên tục. Sau restore, **Lease được gia hạn** là một trong các điều kiện của mốc t2 khi đo RTO. |
| **Taint / cordon / drain** | `cordon`: đừng xếp pod mới vào node này. `drain`: đuổi pod đang chạy đi (và nó **có** hỏi PodDisruptionBudget). `taint`: nhãn khiến pod không được xếp vào trừ khi có toleration. |
| **PodDisruptionBudget** | Giữ tối thiểu bao nhiêu pod sống qua một lần **eviction có kế hoạch** như drain. **Không** áp dụng cho `kubectl delete pod` — chỉ eviction mới hỏi nó. Chỗ này guide của tôi từng ghi sai. |
| **Pod Security `restricted`** | Nhãn trên namespace làm API server từ chối pod không an toàn. Đáng nhớ vì nó là thứ phải **loại trừ** khi chứng minh Kyverno mới là cái từ chối. |

## etcd, backup, khôi phục

| Từ | Nói thế này |
|---|---|
| **etcd** | Cơ sở dữ liệu key-value giữ *toàn bộ* trạng thái cụm. Mất etcd là mất cụm; giữ etcd là giữ mọi thứ trừ dữ liệu trong volume. |
| **Snapshot ≠ backup volume** | Snapshot là bản sao **nhất quán** của cây key-value ở một revision. Sao lưu đĩa của một etcd đang chạy có thể ra file không đọc nổi. |
| **`etcdutl snapshot status`** | Đọc file snapshot và **fail nếu nó bị cắt hoặc hỏng**. Ở đây nó là initContainer trước bước upload, nên S3 không bao giờ nhận file rác. |
| **RTO** | Recovery Time Objective: mất bao lâu để **quay lại chạy được**. Của tôi: 7 phút 02 giây, đo tới mọi Application `Synced`+`Healthy`. |
| **RPO** | Recovery Point Objective: mất bao nhiêu **dữ liệu**, tức khoảng cách tới bản sao gần nhất. Của tôi: ≤ 6 giờ **theo lịch** — đó là bound thiết kế, không phải phép đo. |
| **`--bump-revision` / `--mark-compacted`** | Khi restore, đẩy revision lên rất cao và đánh dấu đã nén, để client giữ revision cũ không thấy số tụt ngược. |
| **cluster-id** | Danh tính của một cụm etcd. Ba node restore xong **cùng một cluster-id** là bằng chứng chúng là một cụm, không phải ba cụm một thành viên. |

## GitOps

| Từ | Nói thế này |
|---|---|
| **Application (Argo CD)** | Object nói "cài *cái này* từ Git hoặc từ chart, vào *namespace kia*". |
| **App-of-apps** | Một Application (`root`) mà việc duy nhất là tạo ra các Application khác. Nên bootstrap chỉ cần apply một file. |
| **Sync wave** | Thứ tự áp dụng. Wave sau chỉ chạy khi mọi Application của wave trước `Healthy` **và** `Synced`. Ở đây từ −3 tới 4. |
| **`Synced` so với `Healthy`** | `Synced` = cụm khớp cái Git render ra. `Healthy` = resource khoẻ — nhưng nó **bỏ resource chưa tồn tại** ra khỏi tổng, nên một Application nửa đường vẫn `Healthy`. Vì thế phép kiểm phải đòi cả hai. |
| **`Synced` chính xác là khớp với gì** | Khớp với revision Argo CD **đang có**. Một repo-server không tới được GitHub sẽ giữ `Synced` mãi mãi — nên phép kiểm thật là so `status.operationState.syncResult.revisions[1]` — hoặc `.revision` với ba Application một-source — với `git ls-remote origin main`, thứ thật sự hỏi GitHub. |
| **Drift / self-heal** | Sửa tay trên cụm là drift; self-heal xoá bản sửa tay đó. Đây là lý do "đường về" khi sự cố là **revert trong Git**, không phải `kubectl edit`. |
| **Prune** | Xoá khỏi cụm thứ không còn trong Git. |
| **Hook** | Một Job Argo CD chạy trong lúc sync; **không** tính vào health của Application. |
| **PushSecret** | Đẩy một Secret đang chạy lên Secrets Manager để lần rebuild sau restore lại — đây là cái giữ cho rebuild không tiêu quota cấp chứng chỉ. |

## Chuỗi cung ứng

| Từ | Nói thế này |
|---|---|
| **Tag so với digest** | Tag di chuyển được; digest là hash của manifest, không đổi. Chữ ký ký trên **digest**, và Git ghi digest — nên thứ verify được đúng là thứ cụm kéo về. |
| **Fixable** | Lỗ hổng **có** bản vá. Gate chỉ đếm loại này: chặn build vì một CVE chưa ai vá thì chỉ tạo ra thói quen bỏ qua gate. |
| **Positive control** | Một lần chạy **cố ý** làm gate đỏ. Gate xanh mãi cũng không chứng minh nó biết đỏ. Đây là từ quan trọng nhất trong bảng này. |
| **cosign** | Công cụ ký và verify image. Ở đây ký bằng khoá **KMS** (`SIGN_VERIFY`, ECC NIST P-256): KMS ký mà không bao giờ nhả private key. |
| **Attestation / SBOM** | SBOM là bảng kê thành phần của image. Attestation là một tuyên bố **có ký** gắn vào digest — ở đây SBOM được ký kèm dạng `spdxjson`. |
| **Rekor** | Log công khai của Sigstore. Ở đây **không dùng** cho việc ký — nhưng Kyverno vẫn đòi `ctlog.url` khi verify, và đó là chỗ phải biết khi trả lời "admission có phụ thuộc internet không". |
| **Rootless (BuildKit)** | Container mà user root trong nó là user thường trên node. Bỏ được root trên node — **không** đồng nghĩa được confine: nó cần `Unconfined` seccomp và AppArmor để chạy. |

## Danh tính AWS

| Từ | Nói thế này |
|---|---|
| **IMDS** | `169.254.169.254`, nơi máy EC2 lấy credential của vai **node**. Pod nào tới được đó là pod mượn được vai node — nên chặn nó là việc phải làm. |
| **IMDSv2 / hop limit** | v2 đòi token trước khi trả credential, chặn kiểu SSRF. Hop limit quyết định câu trả lời có tới được pod (2) hay chỉ tới host (1). |
| **IRSA** | Pod đổi **token ServiceAccount của nó** lấy credential tạm của một vai IAM riêng, qua STS `AssumeRoleWithWebIdentity`. Kết quả: pod không cần mượn vai node. |
| **Trust policy** | Ai được phép assume một vai. Ở đây là điều kiện trên `aud` và `sub` của token — tức "đúng ServiceAccount đó, trong đúng namespace đó". |
| **`implicitDeny`** | IAM không có statement nào cho phép. Khác `explicitDeny` là có statement cấm hẳn. Simulator trả về `implicitDeny` là cách chứng minh một quyền **đã bị bỏ** khỏi vai. |
| **SSM Session Manager** | Vào máy qua agent chạy trên chính máy đó. Không cổng 22, không key pair, không IP public — và quyền vào máy thành quyền IAM nên thu hồi được và có log. |

## Terraform và Ansible

| Từ | Nói thế này |
|---|---|
| **Stack, và vì sao chia** | `destroy` luôn xoá **trọn một state file**. State chung nghĩa là vòng đời chung. Ở đây `shared` sống qua mọi lần teardown, `cluster` bị xoá mỗi phiên. |
| **State, remote backend, lock** | State là bản đồ giữa cấu hình và resource thật. Để trên S3 với lock để hai lần apply không ghi lên nhau. |
| **`plan` và cái nó không thấy** | `plan` so cấu hình với state **và** làm mới từ thực tế — trừ khi dùng `-refresh=false`, lúc đó drift thật vẫn vô hình. |
| **Playbook, role, inventory** | Playbook là việc cần làm; role là việc đó chia thành khối dùng lại được; inventory là danh sách máy và cách tới chúng. |
| **Idempotent** | Chạy lần hai không đổi gì — `changed=0`. Đó là phép kiểm rằng playbook mô tả **trạng thái**, không mô tả hành động. |
| **`serial: 1`** | Chạy lần lượt từng máy một. Trong playbook nâng cấp, đây là thứ ngăn việc drain cả ba node cùng lúc. |

## Đo lường

| Từ | Nói thế này |
|---|---|
| **Request so với limit** | Request là thứ scheduler **hứa**, và là thứ quyết định pod có chỗ hay không. Limit là chặn trên. Con số 960 Mi trên CV là **request**. |
| **Working set** | Phần bộ nhớ đang thật sự dùng, không tính cache bỏ được. Đây là metric đúng để đặt request. |
| **"Free room"** | Ở các bảng của tôi, nó là **request chưa hứa cho pod nào** — không phải công suất đang rảnh. Cụm này không có metrics-server. |
| **ServiceMonitor** | Nói cho Prometheus biết scrape Service nào, cổng nào, đường nào. |
| **Inferred** | Suy ra, không đọc từ đâu. Trong repo tôi gọi nó bằng đúng chữ đó, và phải nói ra khi dùng. Xem [`modes.md`](modes.md). |

---

## Bản đầy đủ — 91 mục, nguyên văn từ repo

Ba bảng glossary có thật trong repo, giữ nguyên tiếng Anh vì đây là bản để **tra**, không phải để học nói. Cột
*Section* trỏ về mục giải thích dài trong chính file đó.

<details>
<summary><strong>App guide — 50 mục</strong> (<code>app/guide/0-concepts.md</code> §Glossary)</summary>

| Term | In one line | Section |
|---|---|---|
| API server | The Kubernetes process every `kubectl` call goes to; it also signs ServiceAccount tokens | 4 |
| ARN | Amazon Resource Name: the unique name of an AWS resource | 1 |
| Assume a role | Ask AWS for temporary credentials that act as the role | 1 |
| Bucket policy | A JSON rule on an S3 bucket saying who may do what with it | 12 |
| Calico | The network plugin that gives pods addresses and enforces NetworkPolicies | 11 |
| CLI / SDK | The `aws` command / the library (boto3) programs use to call AWS | 3 |
| CloudFront | AWS's content delivery network; it can serve a private bucket to the public | – |
| Credential chain | The order in which the SDK looks for credentials; IMDS comes last | 3 |
| Discovery document | `/.well-known/openid-configuration`: says where the key set is | 6 |
| ECR | AWS's container image registry | 14 |
| EKS / EKS Pod Identity | AWS's managed Kubernetes / a separate, agent-based EKS feature | 10 |
| External Secrets | Copies Secrets Manager values into Kubernetes Secrets | 13 |
| Helm chart | Templated manifests plus default settings | 16 |
| Hook, Sync hook | An object Argo CD creates during a sync, usually a Job; left out of health | 17 |
| Hop limit | Whether IMDS answers reach ordinary pods (2) or only the host (1) | 2 |
| IAM role | Permissions that something assumes to get temporary credentials | 1 |
| IMDS | `169.254.169.254`, where an EC2 machine gets its role's credentials | 2 |
| Index version | A hash of the corpus and settings that names one index | 15 |
| Ingress | Routes requests by host name and path to a Service | 19 |
| Init container | A container that runs once, before the pod's main container | 11 |
| IRSA | IAM Roles for ServiceAccounts: sections 4–9 working together | 10 |
| Issuer | The web address in `iss`, under which the issuer documents are published | 6 |
| `iss`, `sub`, `aud`, `exp`, `kid` | Issuer, subject, audience, expiry, key ID | 4 |
| Job | A Kubernetes object that runs a task to completion, then stops | 12 |
| JWT | A signed token: header, readable claims, signature | 4 |
| JWKS / key set | `/openid/v1/jwks`: the public keys that check token signatures | 6 |
| kubeadm init | The command that creates a new Kubernetes cluster | 5 |
| kubelet | The agent on each node that starts pods | 7 |
| Mutating webhook | A component that edits objects as they are created; not used here | 10 |
| NetworkPolicy | A firewall rule for pods, enforced by Calico | 11 |
| Node role | `medical-rag-nodes`, the role every process on a node can use | 1 |
| OIDC | A standard for checking tokens through a public issuer address | 6 |
| Pod Security (`restricted`) | A namespace label that makes the API server refuse unsafe pods | 18 |
| OIDC provider | IAM's record that tokens from one issuer may be trusted | 8 |
| PodDisruptionBudget (PDB) | Keeps a minimum of pods running through planned evictions such as a drain | 20 |
| Principal, Federated | Who a policy allows / an outside identity system | 8 |
| Probes (startup, readiness, liveness) | The kubelet's checks: started yet? ready for traffic? still alive? | 20 |
| PromQL | Prometheus's query language | 21 |
| Projected token / token for AWS | An extra token with its own audience, written into the pod as a file | 7 |
| `--api-audiences` | The audiences the API server itself accepts | 7 |
| `s3:prefix` | The condition that limits `ListBucket` to part of a bucket | 12 |
| ServiceMonitor | Tells Prometheus which Service to scrape, on which port and path | 21 |
| S3 Block Public Access | An account or bucket switch that forbids public bucket policies | – |
| Shared stack / cluster stack | `infra/terraform/shared` (kept) / `infra/terraform/cluster` (destroyed by `make down`) | – |
| Signing key pair | `sa.key` signs tokens, `sa.pub` checks them | 5 |
| STS `AssumeRoleWithWebIdentity` | Exchanges a token for temporary credentials | 9 |
| Sync wave | The order in which Argo CD applies objects; each wave waits for the previous one | 17 |
| Tag / digest | A movable name / a content hash for an image | 14 |
| Trust policy | Who may assume a role; here the `aud` and `sub` conditions | 8 |
| Values file | The settings file the Helm chart reads for one environment | 16 |

</details>

<details>
<summary><strong>Jenkins guide — 33 mục</strong> (<code>jenkins/guide/0-concepts.md</code> §Glossary)</summary>

| Word | Meaning | Section |
|---|---|---|
| Agent / build pod | Where a build runs; here a pod created for one build | 9, 12 |
| Attestation | A signed statement about an image, such as its SBOM | 16, 17 |
| BuildKit | Docker's build engine, which can run without a daemon and without root | 6 |
| CEL | The small expression language of admission policies | 8 |
| Controller | The Jenkins server: UI, jobs, history | 9 |
| cosign | The tool that signs and verifies images | 17 |
| CVE | A published, numbered vulnerability | 2 |
| Declarative pipeline | The `pipeline { stages { ... } }` form of a Jenkinsfile | 10 |
| Digest | The hash of an image's manifest; it never changes | 3 |
| ECR | AWS's container registry; here the repository `medical-rag` | 3, 4 |
| Executor | One build slot | 9 |
| Fixed / unfixed | A patched package exists / does not exist yet | 2 |
| Free room | CPU or memory a node can still promise to new pods: its capacity minus the requests already made | 21 |
| Gate | A pipeline check that stops the build when it fails | 2 |
| IMDS | The node's credential service at `169.254.169.254` | 5 |
| IRSA | A pod's own AWS role, obtained with its ServiceAccount token | 5 |
| JCasC | Jenkins Configuration as Code: Jenkins configured from YAML | 13 |
| KMS | AWS's key service; it signs without ever releasing the private key | 17 |
| Lifecycle policy | ECR rules that delete old images | 4 |
| Localhost profile | A seccomp or AppArmor profile installed on the node, used by name | 8 |
| Multibranch | One pipeline per branch, found by scanning the repository | 11 |
| `NOT_BUILT` | The result of a build that deliberately did nothing | 10, 18 |
| OCI referrer | An artifact, such as a signature, attached to an image without a tag | 4 |
| Pod template | The pod definition Jenkins uses for each build | 12 |
| Rekor | Sigstore's public log of signatures, not used here | 17 |
| Rootless | A container whose root user is an ordinary user on the node | 7 |
| SBOM | Software bill of materials: the list of packages in an image | 16 |
| setuid | A program that runs with its owner's rights, whoever starts it | 7 |
| Skip guard | The first stage, which ends bot and docs-only builds | 18 |
| Trivy | The vulnerability scanner used by the pipeline | 2 |
| Unconfined | With no seccomp filter or no AppArmor profile | 7 |
| User namespace | A process's own list of users, mapped to ordinary users on the node | 7 |
| ValidatingAdmissionPolicy | A built-in API server rule, written in CEL | 8 |

</details>

<details>
<summary><strong>Argo CD explained — 8 mục</strong> (<code>gitops/argocd-explained.md</code>)</summary>

| Word | Meaning |
|---|---|
| Application | An Argo CD object that says "install *this* from Git or a chart into *that* namespace" |
| render | Turn a chart and its values files into plain Kubernetes YAML |
| `Synced` / `OutOfSync` | The cluster matches what Git renders / it does not |
| sync | Apply the rendered YAML to the cluster |
| hook | A Job that Argo CD runs during a sync. It is not counted in the Application's health |
| prune | Delete from the cluster what is no longer in Git |
| `$values` | A second source in an Application, used only to read values files from this repository |
| health check | A small Lua script in `deploy/argocd/values/argocd.yaml` that decides how healthy a child Application looks to `root` |

</details>

**Bốn phase không có glossary trong repo** — Terraform, Ansible, drills và aws. Các mục của chúng ở tầng chọn
lọc bên trên được viết mới từ `drills/concepts.md` (8 mục nội dung) và từ README của hai stage Terraform và
Ansible, vốn đang gánh vai file concepts.

---

[Điều kiện đo](modes.md) · [Dòng CV](cv-lines.md) · [Kiến trúc](architecture.md) ·
[Bộ đề](../common/questions.md)
