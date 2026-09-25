# Sáu dòng CV, mở từng dòng

Người phỏng vấn đọc CV và hỏi theo **từng dòng**. Bộ đề thì xếp theo stage. Trang này là đường đi từ "dòng thứ
ba" sang "các câu sẽ bị hỏi".

Mỗi dòng: câu CV nguyên văn → nói lại bằng lời thường → khái niệm nén trong đó → số liệu kèm nguồn → câu hỏi,
bấm để xem đáp án mẫu. Điều kiện đo của mọi con số ở [`modes.md`](modes.md).

Nguồn của trang: `latex-CV/sections/projects/medical-rag-chatbot.tex`, `evidence/guide-measurements.md` (thủ
tục M0–M4), `evidence/drills.md:265–273` (kết quả).

---

## Dòng 1 — HA control plane

> **HA control plane.** Terraform provisions AWS; Ansible bootstraps kubeadm over SSM: 3 control planes across 3
> AZs, no SSH keys or public node IPs. Empty to Ready in 9 min 57 s, reruns make no changes, API stays available
> after losing one node.

**Nói bằng lời thường.** Terraform dựng phần AWS, Ansible biến ba máy EC2 trần thành một cụm kubeadm ba
control plane, mỗi máy một Availability Zone. Ansible đi vào máy **qua SSM**, không qua SSH — nên không có key
pair nào, và node không có địa chỉ public nào. Chạy lại playbook thì không đổi gì. Và dừng một node thì API vẫn
trả lời, vì 2 trong 3 thành viên etcd vẫn là quorum.

**Khái niệm trong câu này.**

| Khái niệm | Đủ mức nói ra miệng |
|---|---|
| **Stacked control plane** | etcd chạy *trên chính* node control plane, không phải cụm etcd riêng. Ba node = ba thành viên etcd. |
| **Quorum** | etcd cần quá nửa thành viên còn sống để ghi được. 3 thành viên → chịu mất 1. |
| **SSM thay SSH** | Session Manager nói chuyện qua agent trên máy, nên không cần cổng 22, không cần key, không cần địa chỉ public. |
| **IMDSv2** | Phiên bản metadata service đòi token, chặn kiểu tấn công SSRF đọc credential của máy. |
| **Idempotent** | Chạy lần hai không đổi gì — `changed=0`. Đó là phép kiểm rằng playbook mô tả *trạng thái*, không mô tả *hành động*. |

**Số liệu.**

| Đọc được | Giá trị | Nguồn |
|---|---|---|
| Node, mỗi AZ một cái | 3 × `m7i-flex.large`, `ap-southeast-1a/b/c`, không IP public, không key pair, IMDSv2 bắt buộc | `terraform.md:45–51` |
| Resource Terraform | **84** added trong **3 m 47 s** | `terraform.md:35` |
| Empty → 3 node `Ready` | **9 m 57 s** *thời gian chạy lệnh* (3 m 47 s + 6 m 10 s) | `ansible.md:93` |
| Chạy lại | `changed=0` trên mọi host, **2 m 56 s** | `ansible.md:79` |
| Mất một node | API vẫn trả lời qua internal NLB; node tự về `Ready` **không cần chạy lại playbook** | `ansible.md:99–107` |
| Không có access key nào | *"CloudShell uses the console session, the workstation and the nodes use instance roles"* | `terraform.md:81` |

**Sẽ bị hỏi gì.**

<details>
<summary>9 phút 57 giây là đo thế nào?</summary>

Đây là con số **dễ bị bắt nhất** của cả entry, nên nói trước phần yếu.

Nó là **tổng hai thời gian lệnh** — 3 m 47 s `make infra` cộng 6 m 10 s `make cluster` — không phải một số treo
tường. Khoảng chờ để SSM agent đăng ký, nằm giữa hai lệnh, **không được tính**. Và chính thủ tục đo của repo
cấm cách đó: `guide-measurements.md:229` viết *"T = end − t0, as one wall-clock figure. Do not sum the commands'
own times."* Hai lần chạy sau ra 10 m 13 s và 10 m 03 s, do tôi tự cộng thời gian lệnh.

> "It is the sum of two command times, not wall clock — the wait for the SSM agents to register sits between
> them and was not timed. My own procedure forbids that method for the rebuild figure, and I did not go back and
> re-measure this one. Nine fifty-seven is the measured one; for the two later runs no 'empty to Ready' figure was
> recorded at all, and adding the commands up myself gives ten thirteen and ten oh three — so those two are derived,
> not read. What I say now is 'about ten minutes of command time, and two of the three numbers are my own
> arithmetic'."

</details>

<details>
<summary>"API vẫn trả lời" — anh kiểm nó thế nào, và nó chứng minh tới đâu?</summary>

Dừng node 2 bằng `aws ec2 stop-instances` — **dừng êm**, không phải giết. Node đọc `NotReady`, `kubectl get pods
-A` vẫn trả lời qua internal NLB. Rồi bật lại, node tự về `Ready` mà không cần chạy playbook.

Chỗ nó **không** chứng minh: không đếm request nào bị mất, và chỉ mất **một** node. Mất hai là hết quorum, cụm
thành chỉ-đọc — đó là giới hạn của ba node, không phải điều tôi đo.

> "A graceful stop of one node, not a hard kill. The API kept answering through the internal load balancer —
> two of three etcd members is still a quorum — and the node rejoined on restart without re-running the
> playbook. What I did not measure is request loss, and I only lost one node: two is quorum gone."

</details>

<details>
<summary>Vì sao SSM thay vì SSH?</summary>

Vì nó bỏ được một thứ phải quản: không key pair, không cổng 22, không địa chỉ public trên node. Quyền đi vào máy
thành quyền IAM, nên nó thu hồi được và nó có log. Cái phải đánh đổi là phụ thuộc vào agent SSM đăng ký được —
và đúng chỗ đó là khoảng chờ không được tính vào 9 m 57 s.

> "It removes a thing to manage. No key pair, no port 22, no public address on a node — reaching a machine
> becomes an IAM permission, so it is revocable and audited. The cost is a dependency on the SSM agent
> registering, and that wait is exactly the gap my nine-fifty-seven excludes."

</details>

<details>
<summary>"Không có IP public" — chắc chứ?</summary>

Chắc **với node**. Có một máy thứ tư — gateway WireGuard, `t3.small` — và nó **có** Elastic IP public, vì phải
có chỗ để bắt tay VPN. Cổng vào internet của cả hệ là: TCP 80 trên public NLB, và UDP 51820 cho WireGuard.

Đừng để câu này nở thành "không có IP public nào cả".

> "For the nodes, yes. There is a fourth instance — the WireGuard gateway — and it does have a public Elastic
> IP, because a VPN handshake needs somewhere to land. Inbound from the internet is TCP 80 on the public load
> balancer and UDP 51820 for WireGuard, and nothing else."

</details>

---

## Dòng 2 — Backup and restore

> **Backup and restore.** etcd snapshots run every 6 hours and go to S3 after passing `etcdutl snapshot status`.
> Tested recovery by deleting a namespace and restoring all 3 etcd members: RTO 7 min until every Argo CD
> application was Synced and Healthy, RPO ≤ 6 h from the schedule.

**Nói bằng lời thường.** Một CronJob chụp snapshot etcd, và **thứ tự** là điều đáng nói: ba container, snapshot
→ kiểm toàn vẹn → upload, hai cái đầu là initContainer nên **upload chỉ chạy nếu cả hai thành công**. Không bao
giờ có file rác trên S3.

Rồi tôi thử khôi phục thật: tạo một namespace có ConfigMap mốc, chụp snapshot, **xoá namespace**, restore cả ba
thành viên etcd từ cùng một snapshot. Đo tới khi mọi Argo CD Application `Synced` **và** `Healthy`, Lease của
node đã gia hạn, và không pod nào ngoài `Running`/`Completed`.

**Khái niệm trong câu này.**

| Khái niệm | Đủ mức nói ra miệng |
|---|---|
| **etcd snapshot ≠ volume backup** | Snapshot là bản sao *nhất quán* của cây key-value ở một revision. Sao lưu đĩa của một etcd đang chạy có thể ra file không đọc được. |
| **RTO / RPO** | RTO: mất bao lâu để quay lại chạy được. RPO: mất bao nhiêu *dữ liệu*, tức khoảng cách tới bản sao gần nhất. |
| **`etcdutl snapshot status`** | Đọc file snapshot và fail nếu nó bị cắt hoặc hỏng — nên nó là cổng chặn trước khi upload. |
| **`--bump-revision` / `--mark-compacted`** | Khi restore, đẩy revision lên cao và đánh dấu đã nén, để client cũ không thấy revision tụt ngược. |
| **`reconciledAt > t1`** | Phép kiểm chống pass sai: một Application có thể đang đọc `Healthy` từ *trước* lúc xoá. Phải đòi nó reconcile **sau** mốc t1. |

**Số liệu.**

| Đọc được | Giá trị | Nguồn |
|---|---|---|
| Snapshot theo lịch | Job `etcd-snapshot-29834205`, `04:45:00Z → 04:45:08Z` (**8 s**), `ok=1`, `manual=` rỗng | `drills.md:106` |
| `etcdutl snapshot status` | hash `65062525`, revision **134191**, **2434** key, 62 MB, etcd 3.6.0 | `drills.md:108–110` |
| Upload | **62 402 592 bytes**, từ `medical-rag-node-3` | `drills.md:110` |
| **RTO** | **7 m 02 s** (t1 `04:51:04Z` → t2 `04:58:06Z`) | `drills.md:118–128` |
| Restore | Cả 3 node, cùng cluster-id `9ed3a0fb6a89e03e`, revision 134191 → 1000134191 | `drills.md:114–122` |
| Canary | ConfigMap về với `written-at=2026-09-22T04:14:20Z` — **đúng giá trị cũ** | `drills.md:125` |
| RPO lần chạy đó | **6 m 01 s**; theo lịch **≤ 6 h** | `drills.md:128` |

**Sẽ bị hỏi gì.**

<details>
<summary>Anh đã thấy lịch 6 giờ nổ chưa?</summary>

**Chưa** — và đây là chỗ phải nói chủ động.

Snapshot duy nhất từng quan sát được đến từ một cron **tạm** `*/15 * * * *`, commit lúc 04:38:40 UTC để thấy lần
chạy đầu trong vài phút thay vì chờ 06:00. Chuỗi `0 */6 * * *` có trong Git và tôi đã đọc lại trên cụm hai lần,
nhưng chưa lần nào thấy nó nổ. Repo còn ghi việc đó là **chưa giải quyết** ở `drills.md:325`.

Nên "mỗi 6 giờ" mô tả **cấu hình**. Phép đo là: một snapshot theo lịch, do scheduler tạo — `manual=` rỗng chứng
minh điều đó — kiểm toàn vẹn, upload, rồi restore được.

> "No, and I should say that plainly. The one snapshot I observed came from a temporary fifteen-minute schedule
> I committed so I could see the first run in minutes. The six-hourly string is in Git and I read it back on the
> cluster, but I never watched it fire. So 'every six hours' describes the configuration; what I measured is one
> scheduled snapshot — the empty `manual=` field proves the scheduler made it — integrity-checked, uploaded, and
> restored."

</details>

<details>
<summary>7 phút gồm những gì? Vì sao không đo tới lúc etcd lên?</summary>

Vì "etcd lên" là một pass sai. `guide-measurements.md:165–169` nói rõ: một vòng chờ trên các field trạng thái
sẽ pass **ngay khi API trả lời**, trong khi cụm còn chưa hội tụ.

Nên t2 là: mọi Application `Synced` **và** `Healthy` với `reconciledAt > t1`, Lease của node đã gia hạn, và
không pod nào ngoài `Running`/`Completed`. Vòng chờ trả lời lần đầu ở 04:56:35Z với 2 Application chưa
reconcile; tất cả xong ở 04:57:51Z; t2 = 04:58:06Z.

Hai điều kiện phải nói kèm: **có thời gian tôi gõ ở trong đó**, và **tới khoảng 3 phút của 7 phút có thể là một
chu kỳ reconcile của Argo CD** (`guide-measurements.md:181`). Và nó là **một** lần chạy.

> "Measuring to 'etcd is up' is a false pass — a wait on status fields returns the moment the API answers. So my
> t2 is every Application Synced and Healthy with a reconcile timestamp after t1, node Leases renewed, and no pod
> outside Running or Completed. Two conditions go with the number: my own typing is inside it, and up to about
> three of the seven minutes can be one Argo CD reconcile period. One run."

</details>

<details>
<summary>Cái gì không quay về?</summary>

Mọi thứ ghi sau 04:45:03Z — trong cửa sổ đó là đúng cái revert lịch cron, và Argo CD đặt nó lại từ Git. Pod tạo
sau snapshot thì kubelet của chúng dừng lại, và địa chỉ Calico của chúng còn giữ tới khi GC dọn.

Một chi tiết vui: snapshot chụp **chính Job của nó** đang chạy, nên sau restore `etcd-snapshot-29834205` đọc
`DURATION 10m` — từ 04:45 tới khi controller được restore đóng nó lại — trong khi lần chạy thật mất 8 giây.

> "Anything written after the snapshot — in that window, the schedule revert, which Argo CD put back from Git.
> Pods created after it are stopped by their kubelets and their Calico addresses stay allocated until garbage
> collection. One artefact worth knowing: the snapshot captured its own Job mid-run, so after the restore that
> Job reads ten minutes where the real run took eight seconds."

</details>

<details>
<summary>RPO ≤ 6 giờ là đo hay là thiết kế?</summary>

**Thiết kế.** Nó là chu kỳ CronJob, và evidence để mở việc xác nhận: `drills.md:23` vẫn ghi *"Confirm against
the first two snapshots' timestamps"* — mà chỉ có **một** snapshot từng tồn tại, nên khoảng cách giữa hai
snapshot liên tiếp chưa bao giờ được quan sát.

RPO **của lần chạy đó** thì đo được: **6 phút 01 giây**, vì tôi restore ngay sau một snapshot.

> "By design — it is the CronJob interval, and my own evidence still lists 'confirm against the first two
> snapshots' as open, because only one snapshot ever existed. The RPO of the drill itself I did measure: six
> minutes one second, because I restored shortly after a snapshot."

</details>

---

## Dòng 3 — GitOps rebuild

> **GitOps rebuild.** Rebuilt the platform from empty in 22 min, unattended: 17 Argo CD applications, 11 from Helm
> charts, 8 sync waves. Stopped needless TLS re-issuance on rebuilds by requiring Argo CD applications to be Healthy
> and Synced.

**Nói bằng lời thường.** Một script bấm giờ dựng lại cả nền tảng từ cụm trống: Terraform, rồi kubeadm, rồi
Argo CD, rồi Argo CD tự kéo 16 Application còn lại về theo 8 sync wave. **Không có prompt nào cho người** ở
trong khoảng bấm giờ.

Nửa sau của dòng này là một bản sửa thật. Lần rebuild 18/09 **tiêu một trong năm chứng chỉ Let's Encrypt mỗi
tuần**, vì health check cũ chỉ đọc `Healthy` — và Argo CD báo `Healthy` cho một Application *đang* sync, do nó
cố ý không tính resource chưa tồn tại vào tổng health. Nên wave sau chạy trước khi wave trước xong, chứng chỉ
chưa được restore từ backup, cert-manager thấy thiếu và đi xin bản mới. Sửa: đòi cả `Healthy` **và** `Synced`.

**Khái niệm trong câu này.**

| Khái niệm | Đủ mức nói ra miệng |
|---|---|
| **App-of-apps** | Một Application duy nhất (`root`) mà việc của nó là tạo ra các Application khác. |
| **Sync wave** | Số thứ tự Argo CD áp dụng; một wave chỉ bắt đầu khi mọi Application của wave trước đã `Healthy` **và** `Synced`. Ở đây chạy từ −3 tới 4. |
| **Vì sao `Synced` mới là cái làm việc** | `Healthy` bỏ resource chưa tồn tại ra khỏi tổng → một Application nửa đường vẫn `Healthy`. `status.sync` chỉ hết `OutOfSync` khi **mọi** resource đã tồn tại. |
| **PushSecret / backup chứng chỉ** | Chứng chỉ wildcard được đẩy lên Secrets Manager và restore lại ở wave −1, nên rebuild không tiêu quota cấp mới. |
| **Hai tầng wave** | Wave giữa các Application, và wave *bên trong* chart của từng app (0, 1, 2) — hai bộ số khác nhau. |

**Số liệu.**

| Đọc được | Giá trị | Nguồn |
|---|---|---|
| **T** | **21 m 47 s** treo tường (`05:11:28Z → 05:33:15Z`), `VERDICT PASS`, **unattended** | `drills.md:272` |
| Chia phần | Terraform 3 m 46 s (`Plan: 86 to add`) · SSM 7 s · `make cluster` 6 m 17 s · tunnel + bootstrap 57 s · **Argo CD waves 10 m 40 s** | `drills.md:272` |
| Application | **17**, mọi cái `Synced`+`Healthy`, không sync nào đang chạy, **và vẫn vậy một phút sau** | `drills.md:272` |
| CertificateRequest | **0** | `drills.md:272` |
| Độ mịn của vòng poll | ~35 s, nằm **trong** T | `drills.md:272` |
| Bản sửa health check | 19/09: Secret về **trước** Certificate 2–4 s, `status.revision` **rỗng**, `No resources found` | `gitops.md:128–147` |

**Sẽ bị hỏi gì.**

<details>
<summary>"8 sync waves" và "11 from Helm charts" — đo ở đâu?</summary>

**Không đo.** Cả hai là **thuộc tính của manifest**, không phải phép đo, và tôi nói thẳng như vậy.

8 wave = 8 giá trị `argocd.argoproj.io/sync-wave` khác nhau trong `deploy/argocd/apps/*.yaml`: −3, −2, −1, 0, 1,
2, 3, 4. Câu duy nhất trong evidence nói "eight waves" lại gắn với lần chạy **13** Application, không phải lần
17.

11 Helm = 9 chart ngoài (argo-cd, EBS CSI, cert-manager, external-secrets, ingress-nginx, jenkins,
kube-prometheus-stack, kyverno, rancher) cộng 2 Application render chart *local* `deploy/charts/medical-rag` cho
dev và prod. 5 cái còn lại là manifest thường. Cộng `root` = 17.

> "Neither is a measurement — both are properties of the manifests, and I would say so. Eight is the number of
> distinct sync-wave values in the apps directory; eleven is nine remote charts plus the two Applications that
> render the local chart for dev and prod. The five others are plain manifests, and with root that makes
> seventeen."

</details>

<details>
<summary>17 — hay 9, hay 13, hay 16?</summary>

Tất cả đều đúng, ở những thời điểm và cách đếm khác nhau, nên phải nói rõ **root có được tính không**.

17 = 16 file trong `deploy/argocd/apps/` **cộng `root`**. Trong repo còn: `gitops.md:21` "nine Applications"
(chỉ con, cụm cũ), `drills.md:77` "13 child Applications (14 with `root`)" (lần Part 0, chưa có Kyverno), `drills.md:62` "14
Applications" (cùng lần đó, tính cả root), `drills.md:189` "16 Applications".

> "Seventeen including the root app-of-apps — sixteen files in the apps directory plus root. You will see nine,
> thirteen, fourteen and sixteen elsewhere in my own evidence: those are earlier clusters, and some count only
> the children."

</details>

<details>
<summary>Vì sao 22 phút, khi repo có chỗ ghi 14 phút 11 giây?</summary>

Vì đó là cụm khác, và evidence của tôi nói thẳng là **không so được**: lần 18/09 có 9 Application, không có
Jenkins, không có app, và vòng chờ **chỉ đọc health** nên nó trả về sớm. Số lớn hơn ở đây là *đúng*, không phải
tụt lùi.

Nếu ai đọc repo và thấy 14 trước 22 thì CV trông **tệ hơn**, không tốt hơn — nên tôi để câu "không so được"
ngay cạnh con số trong evidence.

> "Different cluster, and my evidence says so in the same line: that run had nine Applications, no Jenkins, no
> app, and a health-only wait that returned early. The larger number is the honest one — and it is why the
> not-comparable note sits next to it in the file."

</details>

<details>
<summary>Bản sửa health check đã được chứng minh tới đâu?</summary>

Bằng chứng nó *hoạt động*: lần 19/09, Secret về trước Certificate 2–4 giây, `kubectl get certificaterequests`
ra `No resources found`, và quan trọng nhất — `status.revision` của Certificate **rỗng**. Cái rỗng đó mới là
bằng chứng không có lần cấp nào; **fingerprint khớp thì không phải**, vì PushSecret copy Secret đang chạy về nên
nó khớp kiểu gì cũng khớp.

Giới hạn tôi tự ghi: *"That was one run; the `Degraded` and no-resources branches have not been exercised."*
(`gitops.md:104`). Và con số 48 giây từng giải thích lần cấp lại 18/09 là **suy ra**, không đọc từ đồng hồ nào.

> "The proof is the empty `status.revision` on the Certificate, not the fingerprint match — the PushSecret
> copies the live Secret back, so a match is expected either way. I read that field on **one** rebuild; two later
> rebuilds recorded no CertificateRequests, which is the weaker fact. What
> I have not exercised is the Degraded and the no-resources branches of the new check, and the forty-eight-second
> gap that explained the original re-issuance is derived, not read off a clock."

</details>

---

## Dòng 4 — Supply chain

> **Supply chain.** Jenkins with rootless BuildKit, a Trivy gate tested with a build made to fail, Cosign signing
> with AWS KMS and SBOM, and production updates via bot-opened pull requests with human review.

**Con số Debian 13 không có trong CV, và đó là chủ ý.** −41 % và CRITICAL 5 → 0 bị bỏ khỏi dòng, vì đổi hai dòng
`FROM` không phải một quyết định thiết kế; dòng `%%` trên bullet trong `medical-rag-chatbot.tex` vẫn ghi hai số đó làm
nguồn (`jenkins.md` step 13). Nó để dành cho phần **nói**, và để dành
đúng một việc: làm **lý do** vì sao gate và việc dọn base là hai control khác nhau — chứ không làm thành tích của
gate.

**Nói bằng lời thường.** Jenkins chạy **trong cụm**, pull-based, nên không có kubeconfig nào nằm ngoài. Build
pod build image **rootless** bằng BuildKit. Trivy quét, và gate chỉ đếm lỗ hổng **có bản vá** — vì một lỗ hổng
chưa có bản vá thì chặn build cũng không ai sửa được gì. cosign ký bằng **KMS**, nên private key không bao giờ
ra khỏi AWS. SBOM được ký kèm dưới dạng attestation. Và bản lên prod đi qua **pull request do bot mở**.

**Khái niệm trong câu này.**

| Khái niệm | Đủ mức nói ra miệng |
|---|---|
| **Rootless BuildKit** | Build engine chạy không cần daemon và không cần root; user root trong container là user thường trên node. |
| **Gate đếm "fixable"** | Chỉ lỗ hổng có `Fixed Version`. Chặn vì một CVE chưa có bản vá thì chỉ tạo ra việc bỏ qua gate. |
| **Positive control** | Một lần chạy **cố ý** làm gate đỏ. Gate xanh mãi không chứng minh nó biết đỏ. |
| **cosign + KMS** | Ký bằng khoá trong KMS (`SIGN_VERIFY`, ECC NIST P-256); KMS ký mà không bao giờ nhả private key. |
| **Attestation / SBOM** | Một tuyên bố có ký gắn vào digest của image — ở đây là bảng kê thành phần, `spdxjson`. |
| **Digest so với tag** | Tag di chuyển được, digest thì không. Chữ ký ký trên **digest**. |

**Số liệu.**

| Đọc được | Giá trị | Nguồn |
|---|---|---|
| Debian 12.15 → Debian 13, tổng finding | **269 → 158**, **−111 = −41 %** | `jenkins.md:570` |
| CRITICAL | **5 → 0** | `jenkins.md:565` |
| Fixable CRITICAL | **0 → 0** | `jenkins.md:571` |
| Positive control | Gate nới sang mọi severity, in `Fixable, any severity: 6`, **Build 2 `Finished: FAILURE`** | `drills.md:273` |
| Ký, và phép kiểm âm | digest đã ký → *"The signatures were verified against the specified public key"*; tag chưa ký → `Error: no signatures found` | `jenkins.md:694–697` |
| Pull request | `#2 prod: b79a4531d5cb` từ `bot/prod-…`, merge squash `bcd556a … (#2)` | `jenkins.md:934–937` |

**Sẽ bị hỏi gì.**

<details>
<summary>Gate Trivy của anh đã bắt được CRITICAL nào chưa?</summary>

**Chưa, và nó không thể.** Đây là chỗ tôi muốn nói chủ động vì nó dễ bị đọc sai thành nói quá.

Cái tôi chứng minh là gate **biết đỏ**: tôi nới nó từ chỉ-CRITICAL sang mọi severity trên một nhánh bỏ đi, báo
cáo build trước có 6 finding có bản vá, gate chạy `[ 6 -eq 0 ]` và build đỏ ở đúng stage Scan.

Còn 5 CRITICAL về 0 thì **không phải công của gate** — gate báo `0` cả trước lẫn sau, và báo *đúng*, vì cả năm
cái đó đều không có `Fixed Version` trong Debian 12. Cái làm chúng biến mất là **đổi base sang Debian 13**.
Đổi base là hành động duy nhất chạm được vào lỗ hổng dạng đó.

> "No, and structurally it could not have. What I proved is that the gate can go red: I widened it to any
> severity on a throwaway branch, it counted six fixable findings from the previous build, and the build failed
> at the Scan stage. The five-to-zero on CRITICAL is not the gate's work — it reported zero before and after,
> correctly, because none of the five had a fixed version in Debian 12. Moving the base image is the only action
> that reaches findings of that shape."

</details>

<details>
<summary>"Rootless" — hoàn toàn cô lập chứ?</summary>

Không, và nói "rootless" mà để người ta hiểu là "được confine hoàn toàn" thì sai. Nó cần `Unconfined` seccomp
**và** `Unconfined` AppArmor để chạy, dù Ubuntu vẫn bật hạn chế user namespace. Cái nó bỏ được là **root trên
node**; cái nó không cho là một sandbox kín.

> "No. Rootless means the build's root user is an ordinary user on the node — it does not mean confined. It
> needs Unconfined seccomp and Unconfined AppArmor to run at all, with Ubuntu's user-namespace restriction still
> on. What it removes is root on the node, not the need for a sandbox."

</details>

<details>
<summary>Chữ ký nào là của pipeline?</summary>

Câu này phải trả lời chính xác, vì có **hai** chữ ký trên cùng digest. Cái đầu tôi ký **bằng tay từ
workstation** trong lúc dò đường; evidence của tôi ghi thẳng: *"This signature was made from the workstation by
the operator, not by the pipeline … the pipeline's own signature is still owed."* Chỉ hai entry sau là việc của
pipeline.

Một chi tiết kỹ thuật vui: cờ `--tlog-upload=false` trong guide đã chết ở cosign v3, phải thay bằng một
`signing-config.json` sinh ra tại chỗ.

> "There are two signatures on that digest, and only the later ones are the pipeline's. The first I made by hand
> from the workstation while working the route out, and my evidence says so in those words. Worth knowing: the
> flag the guide used to skip the transparency log is gone in cosign v3, and a generated signing-config file
> replaced it."

</details>

<details>
<summary>Cái gì chặn một merge vào prod không đúng?</summary>

Không phải phép kiểm tác giả — và đây là chỗ tôi tìm ra khi chạy. Một **squash merge** được ghi tác giả là
người bấm nút, nên phép kiểm "tác giả có phải bot" **không bao giờ nổ** trên một merge. Cái thật sự chặn là
`onlyDocs`: build sau merge chỉ thấy file deploy đổi nên kết thúc `NOT_BUILT`.

> "Not the bot-author test, which is what I expected. A squash merge is authored by whoever pressed the button,
> so that test never fires on a merge. What caught it was the docs-only guard: the post-merge build saw only
> deploy files change and ended NOT_BUILT."

</details>

---

## Dòng 5 — Admission and IAM

> **Admission and IAM.** A Kyverno policy rejects unsigned images in prod and admits signed ones. IRSA gives pods
> their own IAM roles, removing ECR push and KMS sign from the node role — verified by IAM simulation and a pod
> whose KMS request was denied as expected.

**Nói bằng lời thường.** Hai lớp, và chúng bù cho nhau. Kyverno ngồi ở **admission**: prod ở chế độ `Deny`, nên
một image chưa ký không vào được cụm, còn dev ở `Audit` để thấy trước mà không chặn. Và IRSA cho mỗi pod **vai
IAM riêng**, nên tôi bỏ được `ecr:PutImage` và `kms:Sign` khỏi vai của **node** — trước đó mọi process trên node
đều mượn được hai quyền đó.

Kiểm hai chiều: simulator IAM nói vai node giờ bị `implicitDeny` trên `kms:Sign`, và một pod thật trong namespace
`default` mượn vai node qua IMDS thì nhận đúng `AccessDeniedException`.

**Khái niệm trong câu này.**

| Khái niệm | Đủ mức nói ra miệng |
|---|---|
| **Admission controller** | Chặng cuối trước khi object được ghi vào etcd. Kyverno ngồi ở đó, nên nó chặn *lúc tạo*, không phải sau khi pod đã chạy. |
| **`Audit` so với `Deny`** | Cùng một policy: `Audit` ghi report, `Deny` từ chối. Dev `Audit`, prod `Deny`. |
| **`failurePolicy: Fail`** | Webhook không trả lời thì **từ chối** request. An toàn hơn, nhưng biến webhook thành phụ thuộc của việc tạo pod. |
| **IRSA** | Pod dùng token ServiceAccount của nó đổi lấy credential tạm của một vai IAM riêng — không mượn vai node. |
| **IMDS và hop limit** | `169.254.169.254` là nơi máy lấy credential của vai node. Hop limit 1 thì pod không tới được; ở đây chặn bằng NetworkPolicy. |
| **`implicitDeny`** | IAM không có statement nào cho phép — khác `explicitDeny` là có statement cấm hẳn. |

**Số liệu.**

| Đọc được | Giá trị | Nguồn |
|---|---|---|
| Từ chối, nguyên văn | `admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-images-prod" denied the request: Policy verify-images-prod failed: the image is not signed with the medical-rag cosign key` | `drills.md:218` |
| Image đã ký vẫn vào được | 2 pod prod bị xoá, ReplicaSet ghi `SuccessfulCreate` sau 11 s và 22 s, Deployment `2/2` — **được nhận dưới `Deny`** | `drills.md:221–223` |
| Simulator, vai node | `ecr:PutImage` → `implicitDeny` · `kms:Sign` → `implicitDeny` · ba quyền pull → `allowed` | `jenkins.md:1001–1010` |
| Pod thật | `assumed-role/medical-rag-nodes/i-080eaea8…` rồi `AccessDeniedException … not authorized to perform: kms:Sign` | `jenkins.md:1046–1058` |
| Vai node, trước → sau | `EcrPullPush` (5 read + 4 write) → `EcrPull` (5 read); statement KMS **biến mất** | `jenkins.md:990–999` |

**Sẽ bị hỏi gì.**

<details>
<summary>Làm sao biết Kyverno từ chối, chứ không phải Pod Security?</summary>

Bằng cách loại nó ra từ đầu: pod thử nghiệm được viết để **đạt** Pod Security `restricted`, nên PSA không thể là
cái từ chối. Và tên webhook trong thông báo mang `svc-fail` — tức lời từ chối đến từ Kyverno, qua webhook
fail-closed.

Cộng thêm: lần chạy `Audit` **đầu tiên thất bại** với 5 dòng `fail`, lý do là *"rekor URL must be provided"* —
phải thêm `ctlog.url` mới chạy. Điều kiện hợp lệ ghi sẵn ở `drills.md:144`: *"a report with zero rows is a failure, not a
pass"*, và nó không xảy ra.

> "By construction: the test pod meets Pod Security restricted, so PSA could not be the one refusing it. And the
> webhook name in the message carries `svc-fail`, so the refusal came from Kyverno through the fail-closed
> webhook. The Audit run before it failed first with 'rekor URL must be provided', which is how I know the policy
> was actually evaluating rather than matching nothing."

</details>

<details>
<summary>Admission giờ có phụ thuộc vào Sigstore công khai không?</summary>

**Chưa đo — nên đây là bán kính ảnh hưởng và cách đóng nó.** Lỗi ban đầu nói "getting Rekor public keys", nên
Kyverno **có thể** gọi ra ngoài lúc admission. Với prod ở `failurePolicy: Fail`, một sự cố ở Sigstore hoặc một lần
cắt egress NAT sẽ **chặn mọi pod prod mới**: pod đang chạy thì sống, nhưng restart và rollout thì không. Log ở mức
đó không thấy call HTTP nào — mà *không thấy* thì không phải *không có*.

Cách đóng: ghim public key của Rekor thẳng trong policy để lúc admission không phải lấy gì, rồi chứng minh bằng
cách cắt egress và thử tạo pod. Đó là việc tiếp theo tôi làm.

> "Not measured — so here is the blast radius and the fix. The error I saw mentioned fetching Rekor public keys,
> so Kyverno may reach out at admission time. With prod fail-closed, a Sigstore outage or a cut in NAT egress
> would block every new prod pod — running pods survive, restarts and rollouts do not. The fix is to pin the Rekor
> public key in the policy so nothing is fetched at admission, and prove it by cutting egress and creating a pod.
> That is the next thing I would do."

</details>

<details>
<summary>Bước bỏ quyền khỏi vai node chứng minh được gì?</summary>

Ít hơn vẻ ngoài của nó, và tôi tự ghi chỗ đó. Vai node **đã** ngoài tầm pod Jenkins từ trước, vì NetworkPolicy
ở bước 6 chặn `169.254.169.254/32` ở cả hai namespace Jenkins. Nên một build xanh sau khi bỏ quyền chỉ cho thấy
đường IRSA còn chạy — nó **không thể đỏ** chỉ vì bước đó.

Cái bước đó thật sự đổi là **mọi pod khác** trong cụm, và đó đúng là thứ phép kiểm ở namespace `default` đo.

> "Less than it looks, and I wrote that down. The node role was already out of the Jenkins pods' reach, because
> a NetworkPolicy blocks the metadata address in both Jenkins namespaces. A green build after the change only
> shows the IRSA path still works — it could not have gone red from that change alone. What it actually changes is
> every other pod in the cluster, and that is what the check in the default namespace measures."

</details>

<details>
<summary>Kyverno ở đây làm được nửa nào của tiêu chí?</summary>

Nửa chữ ký. Thiết kế §4.6 còn đòi baseline Pod Security **dưới Kyverno**, và phase này không làm — hai namespace
Jenkins đã có nhãn Pod Security và một `ValidatingAdmissionPolicy`, còn namespace app thì enforce `restricted`.
Nên tiêu chí #13 được ghi là **Measured, nửa chữ ký** — chữ *partially measured* trong repo thuộc về #14, bài
nâng cấp. Và tôi không để "một policy Kyverno" nở thành "Kyverno enforce Pod
Security".

> "The signature half. The design also asks for baseline Pod Security policies under Kyverno, and this phase
> does not add them — the Jenkins namespaces already carry Pod Security labels and a ValidatingAdmissionPolicy,
> and the app namespaces enforce restricted. So I record the criterion as met on the signature half only."

</details>

---

## Dòng 6 — Startup and sizing

> **Startup and sizing.** The FAISS index is built once and stored as a versioned S3 artifact, so pods are Ready in
> 10 s instead of 149 s rebuilding it. Set requests from peak memory measured in Prometheus, with headroom, and
> limits at twice that, not from guesses.

CV bản hiện tại không ghi 960 Mi / 2 304 Mi; hai số đó để dành cho phần nói, khi được hỏi "request đặt từ đâu".

**Nói bằng lời thường.** Trước đó **mỗi pod tự build index khi khởi động** — 149 giây, và mỗi pod làm lại đúng
việc đó. Giờ index là một **artifact có version** trên S3: một Job build nó một lần, tên version là hash của
corpus cộng cấu hình, và pod chỉ tải về. Ready trong 10 giây.

Nửa sau: resource request không phải đoán. Tôi đọc Prometheus — `container_memory_working_set_bytes` của
container app — thấy đỉnh 276.9 MiB sau mười câu hỏi liên tiếp, làm tròn lên bậc 64 Mi thành 320 Mi. Ba pod ×
320 = 960 Mi, thay cho 3 × 768 = 2 304 Mi.

**Khái niệm trong câu này.**

| Khái niệm | Đủ mức nói ra miệng |
|---|---|
| **Index là artifact** | Build một lần, đặt tên bằng hash, dùng lại. Pod trở thành thứ chỉ *đọc* artifact, nên pod thay được mà không tốn lại công build. |
| **Index version** | Hash của corpus và cấu hình. Đổi một trong hai là ra version khác — nên "dùng lại" không bao giờ dùng lại sai bản. |
| **Sync hook / Job ở wave 1** | Job build index chạy ở wave trước app, nên app không lên trước khi index có. Job thất bại thì wave sau không chạy. |
| **request so với limit** | Request là thứ scheduler hứa, và là thứ quyết định pod có chỗ hay không. Limit là chặn trên. Con số 960 Mi là **request**. |
| **working set** | Phần bộ nhớ đang thật sự dùng, không tính cache có thể bỏ. Đây là metric đúng để đặt request. |

**Số liệu.**

| Đọc được | Giá trị | Nguồn |
|---|---|---|
| Index | **759 trang, 7 079 chunk**, version `cc759ae1a093`, build **149.1 s** | `app.md:14` |
| Cùng build, chạy local | **150.7 s** — hai bên được phép so ở project này | `app.md:15`, `local.md` |
| Pod created → Ready | `14:14:36 → 14:14:46`: **10 s**, đã gồm tải index | `app.md:62` |
| Hai lần chạy sau | `already exists, skipping build` | `app.md:14` |
| Đỉnh memory đo được | **276.9 MiB** (pod dev, 30 phút gồm mười câu hỏi) | `app.md:121` |
| Request đặt ra | app **320 Mi** / limit 640 Mi / CPU 50m → ba pod **960 Mi** thay cho **2 304 Mi** | `app.md:20`, `:148–150` |

**Sẽ bị hỏi gì.**

<details>
<summary>10 giây đo chính xác tới đâu?</summary>

Nó là hiệu hai mốc thời gian của cụm, **độ chính xác một giây**, nên 10 giây thật ra là 9–11 giây. Và là **một**
pod, **một** lần quan sát.

Còn 149 giây là một **phản chứng** — nó là việc một pod *sẽ* làm nếu không có artifact, và trạng thái trước
phase này đúng là như vậy. Cả hai số phụ thuộc vào độ trễ của Hugging Face Inference API hôm đó.

> "It is the difference between two cluster timestamps with one-second precision, so it is nine to eleven
> seconds — one pod, one observation. And the 149 seconds is the counterfactual: it is what a pod would do
> without the artifact, which is what every pod did before this phase. Both depend on the Hugging Face inference
> API's latency that day."

</details>

<details>
<summary>2 304 Mi là đo hay là đoán?</summary>

**Đoán** — và nói rõ chỗ đó làm con số mạnh hơn, không yếu hơn. Evidence của tôi viết thẳng: *"Before, the
guesses were 768Mi to 1,536Mi for the app and 512Mi to 2Gi for the Job."* Nên câu chuyện không phải "tôi giảm
được 58% mức dùng", mà là **"tôi thay một phỏng đoán bằng một phép đo"**.

Và phải nói **request**, không nói usage.

> "A guess, and saying so makes the number stronger. My own note says the previous values were guesses. So the
> claim is not that I cut usage by half — it is that I replaced a guess with a measurement, and the numbers are
> requests, not usage."

</details>

<details>
<summary>Phép đo bằng Prometheus có chỗ nào yếu?</summary>

Ba chỗ, và cả ba nằm trong evidence của tôi. Prometheus lấy mẫu theo chu kỳ nên **một đỉnh ngắn có thể bị bỏ
qua**. CPU đọc từ trung bình 5 phút nên nó **che burst**. Và "mười câu hỏi liên tiếp" **không phải một tải
thật** — `app.md:147` ghi: *"The limit is the protection against a real load, which ten questions in a row are
not."*

Request để lại khoảng 43 MiB trên mức đo được. Đó là chỗ đệm, không phải chỗ chính xác.

> "Three, and all three are in my notes. Prometheus samples at intervals, so a short spike can be missed; the
> CPU figure is a five-minute average, which hides bursts; and ten questions in a row is not a real load — the
> limit, not the request, is the protection against that. The request leaves about forty-three mebibytes of head
> room above what I measured."

</details>

<details>
<summary>Không có metrics-server thì <code>kubectl top</code> lấy số ở đâu?</summary>

Không lấy được — và đó là lý do mọi con số sử dụng trong project này đến từ **Prometheus**, không từ
`kubectl top`. Chỗ này quan trọng khi đọc bảng "free room" của node: những số đó là **request chưa được hứa cho
pod nào**, không phải công suất đang rảnh.

> "It cannot — there is no metrics-server, which is why every usage figure in this project comes from Prometheus
> instead. It also changes how to read my node capacity tables: those numbers are requests not yet promised to a
> pod, not idle capacity."

</details>

---

## Bảy câu xuyên suốt, không thuộc dòng nào

Những câu này không hỏi về một dòng CV cụ thể, nên không dòng nào ở trên sở hữu chúng — nhưng chúng là phần rất dễ
bị hỏi.

<details>
<summary>Project này tốn bao nhiêu, và anh cắt gì trước?</summary>

Khoảng **0.53 USD mỗi giờ** khi cụm đang chạy, cộng khoảng **9 USD mỗi tháng** cho phần luôn giữ — KMS key, 10
secret, Route 53, bucket, image, ổ đĩa workstation. Budget 100 USD/tháng gửi email ở 50% và 100%, lọc theo tag
`project` vì account dùng chung.

Cắt đầu tiên là `make down` — và đó **chính là lý do** Terraform chia ba stack theo vòng đời, không phải một quyết
định gọn gàng. Rồi một NAT gateway thay vì ba (đổi lại: mất AZ đầu tiên là mất egress của cả ba node). Rồi S3
gateway endpoint, vốn miễn phí.

> "About fifty-three cents an hour running, about nine dollars a month retained, with budget alarms at fifty and
> a hundred per cent. The first cut is tearing the cluster down, and that is why Terraform is split into three
> stacks by lifetime rather than by function — the split exists to make the teardown safe."

</details>

<details>
<summary>Điểm yếu lớn nhất của project là gì? Anh sửa cái nào trước?</summary>

Xếp theo mức tôi thấy nghiêm trọng, và cái đầu là cái tôi sửa trước:

1. **Các pod nền tảng vẫn mượn vai IAM của node** qua metadata service — External Secrets, cert-manager, EBS CSI,
   CronJob snapshot, Kyverno. Vai đó đọc được tám secret và ghi, xoá được bucket `etcd-backups`. Bốn namespace có
   NetworkPolicy chặn metadata — dev, prod và hai namespace Jenkins — nên **pod ở các namespace nền tảng còn lại vẫn
   khai thác được hôm nay**. Sửa: một role IRSA cho từng addon.
2. **Secret trong etcd không mã hoá at-rest**, và snapshot etcd nằm trên S3 mà vai node giải mã được.
3. **`index.pkl` nạp với `allow_dangerous_deserialization=True`** — xem câu dưới.
4. **Token của bot push thẳng được `main`**, nên "prod chỉ đổi qua PR" là quy ước.
5. **Một NAT gateway**, và **app không có HTTPS**.

> "The node role, because the platform pods still borrow it. The app and the Jenkins namespaces block the metadata
> service, and the app and build pods have roles of their own, but a pod in any platform namespace can still reach
> it. Per-addon IRSA roles
> are the fix, and it is the first thing I would do."

</details>

<details>
<summary>App nạp <code>index.pkl</code> từ S3 với <code>allow_dangerous_deserialization=True</code>. Ai ghi được bucket đó?</summary>

Trong cụm, **chỉ** role IRSA `medical-rag-index-builder` ghi được `faiss/*`, và chỉ ServiceAccount
`medical-rag-index-builder` ở dev và ở prod assume được nó; role của app chỉ đọc, và vai của node không có bucket này (`infra/terraform/shared/irsa.tf`,
`infra/terraform/cluster/iam.tf`). Rủi ro còn lại là Job đó hoặc token của nó bị chiếm: khi đó ghi một `index.pkl`
độc là **chạy được code trong pod app**. Câu này biến chính điểm mạnh nhất của tôi, "index là artifact có version",
thành một đường thực thi mã, nên tôi nói ra trước.

Sửa còn thiếu: một phép kiểm hash đối chiếu manifest trước khi nạp. Cách sạch hơn nữa là bỏ pickle: lưu index ở định
dạng không thực thi.

> "Only the index-builder role can write it, and only the index-builder service account in each environment can
> assume that role; the app's role
> only reads, and the node role has no access to the bucket. The remaining risk is that Job or its token being
> compromised, which would mean code execution inside the app pod — so I say it before being asked. What is
> missing is a hash check against the manifest before load, or dropping pickle altogether."

</details>

<details>
<summary>etcd giữ Secret của anh. Nó có mã hoá at-rest không, và ai đọc được snapshot?</summary>

**Không.** Cấu hình kubeadm không có `EncryptionConfiguration`, nên Secret nằm dạng rõ trong etcd **và** trong
snapshot trên S3 — mà bucket backup mã hoá bằng SSE-S3, nên ai có `s3:GetObject` là đọc được bản rõ, và vai node có
quyền đó. Cộng hai chuyện lại: một pod tới được IMDS đọc được mọi Kubernetes Secret của cụm, qua đường snapshot.

Sửa: `--encryption-provider-config` với provider KMS v2 qua `apiServer.extraArgs`, và mã hoá bucket bằng một
customer-managed key chỉ cấp cho một role riêng của CronJob, để vai node **không** giải mã được.

> "It is not. There is no EncryptionConfiguration, so Secrets sit in plaintext in etcd and in the S3 snapshot.
> The bucket uses S3-managed encryption, so anything with GetObject reads it in the clear, and the node role has
> GetObject — which means a pod that reaches the metadata service can read every Secret in the cluster by way of
> the backup. The fix is a KMS v2 encryption provider, and a customer-managed key on the bucket that only the
> snapshot job's own role can use."

</details>

<details>
<summary>Prod trả 503 lúc ba giờ sáng. Dẫn tôi qua mười phút đầu.</summary>

Thu bằng chứng trước khi đổi gì, và đi từ ngoài vào trong.

1. **Vừa có ai đổi gì không** — health và `status.sync` của Application trên Argo CD, `git log deploy/envs/prod`.
   Có bản mới thì **revert trong Git**, không `kubectl edit`: self-heal sẽ xoá bản sửa tay.
2. **502 hay 504** — 504 thường là ingress-nginx hết 60 giây chờ app, tức app đang treo vì retry API ngoài. 502 là
   trang lỗi của app, hoặc không pod nào sẵn sàng.
3. **Pod** — event và readiness probe, trường `error` của `/readyz`, `logs --previous`.
4. **Ngoài cụm** — target health của NLB, log ingress-nginx, Lease của node.
5. **Metric tách được nguyên nhân**: `llm_request_duration_seconds{outcome="error"}` chỉ vào Gemini,
   `rag_retrieval_duration_seconds` chỉ vào embedding hoặc index. Nếu lỗi ở API bên ngoài thì restart và rollback
   đều vô ích.

Cái tôi **không** có: ca trực, và một probe chạy ngoài cụm — cụm chết thì Alertmanager trong cụm chết theo.

> "Collect before changing. First, did anything change — Argo CD's sync status and the Git log for prod's values;
> if a release did this, the way back is a revert in Git, not a `kubectl edit`, because self-heal undoes a manual
> fix. Then whether it is 502 or 504, which separates 'app is slow retrying an upstream' from 'no pod is ready'.
> Then pod events and `/readyz`'s error field, then NLB target health. The metrics split the cause: one histogram
> for the model call, one for retrieval."

</details>

<details>
<summary>Anh dựng hệ này hai lần — EKS và kubeadm. Chọn cái nào, và cái khó dạy anh gì?</summary>

Chia vai có chủ ý. **kubeadm** để tự sở hữu control plane: etcd, chứng chỉ, backup, nâng cấp. **EKS** để dồn sức
vào phần phía trên: SLO burn-rate, canary tự rollback, autoscaling theo in-flight, tracing.

Chọn gì: ở chỗ làm có team thì **EKS**, gần như luôn luôn. Tự quản chỉ khi cần kiểm soát thứ EKS không mở ra.

Cái bên khó dạy được mà bên dễ không dạy: một *phép kiểm* có thể pass sai. Bản health check đầu tiên của tôi chỉ
đọc `Healthy`, và nó pass trong khi nền tảng chưa lên — tốn một chứng chỉ Let's Encrypt để phát hiện. Ở EKS tôi
sẽ không bao giờ gặp chỗ đó, và cũng sẽ không bao giờ học được nó.

> "The split was deliberate: kubeadm to own the control plane — etcd, certificates, backup, upgrade — and EKS to
> spend the time above it, on SLOs, canaries, autoscaling and tracing. For a team I would choose EKS almost every
> time. What the hard one taught me is that a check can pass falsely: my first health check read only Healthy, and
> it passed while the platform was still coming up. It cost a Let's Encrypt issuance to find."

</details>

<details>
<summary>Anh có câu nào hỏi lại chúng tôi không?</summary>

Bốn câu, chọn hai hoặc ba tuỳ thời gian còn lại:

- Ca trực vận hành thế nào, và trung vị một tuần bị gọi bao nhiêu lần?
- Từ lúc merge tới lúc lên production, bước nào chậm nhất hôm nay?
- Cụm nào đang tự quản, và vì sao chọn tự quản chỗ đó?
- Lần gần nhất có sự cố là gì, và sau đó đổi gì?

Mỗi câu đều có một chỗ trong project của tôi để đỡ nếu bị hỏi lại "sao anh quan tâm cái đó".

</details>

---

[Điều kiện đo](modes.md) · [Kiến trúc](architecture.md) · [Thuật ngữ](glossary.md) ·
[Bộ đề](../common/questions.md) · [Evidence](../evidence/)
