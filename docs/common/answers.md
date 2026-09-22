# Đáp án tổng quan về project

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Mỗi câu Phần A mở đầu bằng **Ý chính**: câu nói thành
tiếng, ngôi thứ nhất, thường là đủ. Phần *Nếu được hỏi thêm* chỉ dùng khi người phỏng vấn muốn đi sâu; bảng và sơ
đồ trong đó để bạn nắm, không đọc nguyên văn. Dòng **Mẹo** là lời nhắc cho bạn, không nói ra.

Đáp án mô tả **dự án khi đã hoàn thành** theo [thiết kế](../selfmanaged-k8s-ops-design.md), vì CV được nộp lúc đó.
Tham chiếu dạng `Terraform A1.1` trỏ tới [`../terraform/answers.md`](../terraform/answers.md).

## Trước khi dùng: điền số liệu thật và xác nhận

Con số nào chưa đo được viết dưới dạng `[điền: …]`. Không nói một con số chưa đo: khi xong mỗi phase, lấy số từ
`docs/evidence/` và điền vào đây. Nếu kết quả thật khác thiết kế, sửa câu trả lời cho khớp.

| Chỗ cần điền | Lấy từ | Dùng ở |
|---|---|---|
| Thời gian thực tế làm project | Lịch sử commit | A1.6 |
| Kiểm tra Rancher qua VPN: không có rule 443 public, timeout khi tắt VPN, chuỗi certificate, 308 từ public NLB | Evidence Rancher | A4.5 |
| NetworkPolicy chặn metadata: manifest và bằng chứng test | Evidence phase GitOps | A6.3, A6.4, B1.6, B5.3 |
| Các `[điền]` của Phần B | manifest, values | B2.4, B2.10, B4.1–B4.3, B5.1–B5.3, B6.1, B6.2, B6.4–B6.6 |

**Cần xác nhận khi xong dự án:**

- **Đã xác nhận (phase drills, 22/09):** Kyverno chặn image chưa ký ở prod; khôi phục etcd đã diễn tập (RTO 7 m 02 s);
  **nâng cấp Kubernetes không đo được** vì 1.36.4 đã là bản vá mới nhất của 1.36, nên mọi câu về nâng cấp phải nói
  "playbook có, chưa chạy". Bot mở PR prod đã chạy từ phase Jenkins. Chi tiết: [`../drills/answers.md`](../drills/answers.md).
- **Script boot chờ credential cho SSM agent chưa có.** Thay vào đó `infra/scripts/timed-rebuild.sh` phát hiện node mà SSM
  chưa từng thấy và reboot nó một lần (A10.1, chuyện dự phòng 2).
- Các alert rule ở A7.5 đã cấu hình chưa, và có receiver không.
- `max_retries=1` của client Gemini có nghĩa là tổng số lần gọi hay số lần thử lại (A3.4).
- Phần B dựa trên thiết kế và code hiện có; chỗ phụ thuộc file chưa viết (`deploy/`, `Jenkinsfile` mới) phải kiểm
  lại khi phase đó xong.

---

## Phần A — Phỏng vấn

### A1. Giới thiệu

**A1.1** **Ý chính:** "Đây là chatbot hỏi đáp y khoa dùng RAG. Phần AI tôi giữ đơn giản; trọng tâm là vận hành nó
như một công ty tự chạy Kubernetes: hạ tầng bằng Terraform, cluster HA bằng Ansible, deploy theo GitOps, image được
quét và ký, và có diễn tập khôi phục etcd có đo thời gian."

*Nếu được hỏi thêm*, kể theo ba lớp:

- **Hạ tầng:** Terraform dựng mọi thứ trên AWS, chia ba stack theo vòng đời. Stack cluster (84 resource) dựng lại từ
  đầu trong 3 phút 47 giây, và plan ngay sau đó `No changes`.
- **Cluster:** Ansible biến ba máy EC2 thành cluster kubeadm có ba control plane ở ba AZ, không dùng SSH: từ stack trống
  tới ba node Ready trong 9 phút 57 giây, chạy lần hai `changed=0`.
- **Deploy:** Jenkins test, build, quét và ký image; Argo CD sync từ Git vào cluster; dev tự cập nhật, prod đổi qua
  pull request; Kyverno chặn image chưa ký của app trên prod.
- **Chứng minh vận hành:** cả nền tảng, 17 Application, dựng lại từ stack cluster trống (stack `shared` được giữ) trong
  21 phút 47 giây, không cần ai gõ lệnh; khôi phục etcd có RTO 7 phút 02 giây.

**A1.2** **Ý chính:** "Người dùng hỏi một câu y khoa. App tìm ba đoạn liên quan nhất trong một tập bách khoa y khoa,
rồi để Gemini trả lời ngắn chỉ dựa trên ba đoạn đó; tài liệu không có thì trả lời không biết."

*Nếu được hỏi thêm:*

- **Tài liệu:** tập 2 của bộ bách khoa y khoa Gale, các mục C–F, 759 trang.
- **Chuẩn bị, làm một lần:** cắt PDF thành 7.079 chunk, biến mỗi chunk thành vector (một dãy số thể hiện ý nghĩa)
  qua Hugging Face API, lưu vào FAISS index.
- **Mỗi câu hỏi:** biến câu hỏi thành vector cũng qua Hugging Face, tìm 3 chunk gần nhất trong FAISS, gửi câu hỏi
  kèm 3 chunk cho Gemini với chỉ dẫn "chỉ dùng thông tin trong ngữ cảnh".

RAG giúp câu trả lời bám vào tài liệu và ít bịa hơn, vì model không cần "nhớ" kiến thức y khoa.

**A1.3** **Ý chính:** "Phần vận hành: đưa một app chạy trên máy cá nhân thành một hệ thống deploy, vận hành và kiểm
chứng được. Tôi sửa app cho chạy được ở production, dựng hạ tầng và cluster, dựng CI/CD theo GitOps, bảo mật chuỗi
cung cấp image, và làm các bài diễn tập vận hành, mỗi bước đều có bằng chứng."

*Nếu được hỏi thêm:* app có gunicorn, health check, metrics, index có version, retry và test; Terraform và Ansible;
Jenkins và Argo CD; Trivy, SBOM, ký bằng KMS và Kyverno; backup và khôi phục etcd. Playbook nâng cấp Kubernetes từng
node đã viết nhưng chưa chạy, vì không có bản vá nào mới hơn để nâng (A7.3).

**A1.4** **Ý chính:** "Tôi hướng tới vị trí DevOps, Platform hoặc SRE, nên muốn chứng minh bằng số liệu thật chứ
không bằng lời: hạ tầng xoá đi dựng lại được, Git quyết định cái gì đang chạy, image được quét và ký, và cluster
được backup và khôi phục được, có số đo. Tôi có một project thứ hai trên EKS; hai project cố ý chia vai: project này tự vận
hành control plane, project kia dùng managed và tập trung vào autoscaling, canary, observability."

**A1.5** **Ý chính:** "Năm phase, đi từ dưới lên và chỉ tính là xong khi có bằng chứng: app, Terraform, Ansible,
GitOps cùng CI, rồi vận hành ngày 2. Không có hạ tầng thì không có cluster, không có cluster thì không có gì để
deploy."

*Nếu được hỏi thêm:* app được kiểm chứng bằng Docker ở local; GitOps gồm Argo CD, addon, Helm chart, Jenkins, dev và
prod; vận hành ngày 2 gồm Kyverno, khôi phục etcd và playbook nâng cấp Kubernetes (viết xong, chưa đo được).

**A1.6** **Ý chính:** "Tôi làm một mình, trong khoảng `[điền: thời gian thực tế]`, song song với project EKS."

> **Mẹo:** thiết kế đặt timebox ba ngày; nếu thực tế lâu hơn thì nói thật và giải thích phần nào kéo dài (A10.3).
> Làm một mình cũng giải thích vì sao một số lựa chọn đơn giản hơn ở công ty (A8.2).

**A1.7** **Ý chính:** "Không. Phần RAG ban đầu dựa trên một ví dụ mã nguồn mở, README có ghi nguồn. Phần của tôi là
viết lại để app vận hành được, cùng toàn bộ hạ tầng, cluster, CI/CD và vận hành."

*Nếu được hỏi thêm*, những gì tôi đã làm trên app:

- thay server development bằng gunicorn
- tách `/healthz` và `/readyz`, thêm metrics Prometheus
- biến index thành artifact có version, build một lần
- embedding chia lô có retry, lỗi Gemini thành trang 502 thay vì làm sập worker
- Docker image nhiều stage, chạy non-root, chạy được với filesystem chỉ đọc
- unit test chạy ngay trong bước build

---

### A2. Kiến trúc tổng thể

**A2.1** **Ý chính:** "Người dùng vào qua load balancer công khai. Người vận hành vào qua VPN cho giao diện quản trị
và qua Session Manager cho dòng lệnh. Code đi từ GitHub qua Jenkins lên ECR, còn Argo CD kéo từ Git vào cluster. Tất
cả chạy trên ba node Kubernetes trong một VPC ba AZ."

*Nếu được hỏi thêm*, vẽ ba luồng lên bảng:

```
# Người dùng
Người dùng ──HTTP 80──> Public NLB ──> ingress-nginx ──> app dev (dev.recruitai.io.vn) hoặc prod (app.recruitai.io.vn)
                                                        ├─> Hugging Face API (vector câu hỏi)
                                                        └─> Gemini API (câu trả lời)

# Vận hành
Người vận hành ──WireGuard──> gateway ──> Internal NLB :443 ──> ingress-nginx ──> Rancher
Người vận hành ──SSM──> ops workstation ──SSM──> node (Ansible)
ops workstation ──SSM port-forward qua node 1──> Internal NLB :6443 (kubectl)

# CI/CD
GitHub ──> Jenkins (test, build, quét, ký) ──> ECR
Jenkins ──> ghi version mới vào GitHub ──> Argo CD kéo từ Git ──> cluster
```

Trong cluster: Argo CD, ingress-nginx, External Secrets, EBS CSI driver, Prometheus/Grafana, Jenkins, Rancher,
Kyverno, app ở dev và prod. Ba node đều là control plane và đều chạy workload.

**A2.2** **Ý chính:** "Trình duyệt tới public NLB, sang ingress-nginx, vào pod của app. App tìm ba đoạn liên quan
trong FAISS đã nạp sẵn trong bộ nhớ, gọi Gemini, rồi trả về trang HTML."

*Nếu được hỏi thêm:*

1. Trình duyệt gọi `dev.` hoặc `app.recruitai.io.vn`, trỏ vào public NLB, cổng 80; NLB chuyển tới NodePort 30080.
2. ingress-nginx xem host: `dev.recruitai.io.vn` sang app dev, `app.recruitai.io.vn` sang prod.
3. gunicorn nhận request; index đã được nạp lúc khởi động, không nạp lại mỗi request.
4. App gọi Hugging Face để có vector câu hỏi, tìm 3 chunk, gọi Gemini (A1.2).
5. Thời gian tìm kiếm và thời gian gọi LLM được đo riêng thành metric.

App đi qua HTTP thường: không có domain cho app nên tôi cố ý bỏ HTTPS ở đường này.

**A2.3** **Ý chính:** "Mỗi công cụ lo đúng một lớp. Terraform tạo tài nguyên AWS, Ansible cấu hình máy và dựng
cluster, Argo CD sở hữu mọi thứ trong cluster, Jenkins build và ký image rồi ghi version vào Git. Chia vậy thì lỗi ở
lớp nào tìm ở công cụ đó, và xoá cluster không đụng tới image, index hay secret."

*Nếu được hỏi thêm:*

| Công cụ | Lo phần | Không làm |
|---|---|---|
| Terraform | Mạng, máy, load balancer, IAM, bucket, DNS | Không cài gì lên máy |
| Ansible | Cấu hình bên trong máy, chạy `kubeadm` | Không tạo tài nguyên AWS, không cài addon ngoài Calico |
| Argo CD | Mọi thứ chạy trong cluster, sync từ Git | Không build image |
| Jenkins | Test, build, quét, ký image, ghi version vào Git | Không có RBAC để deploy vào namespace app |

**Giới hạn của ranh giới này:** Jenkins không `kubectl` được vào prod, và pod build dùng role IRSA riêng
`medical-rag-ci` chứ không dùng quyền của node (B5.2); nhưng token GitHub của nó push thẳng được lên `main`, về kỹ
thuật gồm cả values của prod (B5.2).

**A2.4** **Ý chính:** "Mục tiêu là tự vận hành control plane: etcd HA, backup, certificate, nâng cấp. EKS làm hộ
đúng những việc đó, nên dùng EKS thì không chứng minh được. Project thứ hai của tôi dùng EKS. Ở công ty tôi mặc định
chọn EKS."

*Nếu được hỏi thêm*, những gì tôi từ bỏ:

- nâng cấp tự động và SLA của AWS
- IRSA có sẵn: tôi phải tự host OIDC issuer trên S3 và tự quản key ký token service account (`App A2`)
- controller tự tạo load balancer, nên NLB phải tạo sẵn bằng Terraform
- nhiều việc bảo trì hơn

Không phải để tiết kiệm: ba node control plane tự dựng còn tốn hơn phí control plane của EKS (Terraform A1.3).

**A2.5** **Ý chính:** "Chỉ để phục vụ lưu lượng của app thì không cần. Nhưng project chạy cùng lúc app ở hai môi
trường, job build index, Jenkins, Argo CD, Prometheus, Rancher và Kyverno, và Kubernetes cho chúng một cách chung để
deploy, health check, tự restart, cô lập mạng và quản lý secret. Nếu chỉ có một app nhỏ ở công ty, tôi dùng ECS hoặc
một máy chạy container."

> **Mẹo:** thừa nhận trước khi bị hỏi vặn. Biện minh rằng app nhỏ cần Kubernetes sẽ làm mất điểm.

**A2.6** **Ý chính:** "Cùng một Helm chart, hai file values, hai Application của Argo CD, hai namespace. Dev tự cập
nhật và chỉ ghi log khi image chưa ký; prod có hai replica, đổi version qua pull request và chặn image chưa ký."

*Nếu được hỏi thêm:*

| | dev | prod |
|---|---|---|
| Values | `deploy/envs/dev/values.yaml` | `deploy/envs/prod/values.yaml` |
| Replica | 1 | 2, trên hai node khác nhau, có PodDisruptionBudget |
| Host | `dev.recruitai.io.vn` | `app.recruitai.io.vn` |
| Cách đổi version | Jenkins commit thẳng | Pull request, người duyệt merge |
| Kyverno | Audit | Deny |

Hai môi trường chia nhau một NLB theo host, nên app không phải xử lý tiền tố URL
(B1.5, chi tiết: `App A1.4`). Làm một mình thì người duyệt PR prod cũng là tôi; ở công ty cần branch protection và CODEOWNERS.

---

### A3. Ứng dụng và dữ liệu

**A3.1** **Ý chính:** "App chạy được nhưng không vận hành được. Mỗi lần khởi động nó dựng lại toàn bộ index, chậm
nhiều phút và tốn quota; nó chạy server development của Flask và nạp lại FAISS ở mỗi request; còn CI deploy bằng
kubeconfig admin, không quét, không ký."

*Nếu được hỏi thêm:* dựng lại index lúc khởi động còn khiến liveness probe có thể giết pod giữa chừng. Sau khi sửa,
container khoẻ sau khoảng 6 giây ở local, và pod dev trên cluster Ready sau 10 giây (chi tiết: `App A3.1`).
Resource đặt theo số đo của Prometheus chứ không đoán: app dùng khoảng 277 MiB, nên request 320 Mi và limit 640 Mi; ba
pod app giữ 960 Mi thay vì 2.304 Mi (`App A4.5`).

**A3.2** **Ý chính:** "Index là một artifact có version: build một lần, lưu trên S3, và pod tải đúng version ghi
trong Git. Muốn quay về index cũ thì sửa một dòng trong Git."

*Nếu được hỏi thêm:*

- **Version là hash** SHA-256 của tên và nội dung file PDF, kích thước chunk, overlap và tên model embedding, lấy 12
  ký tự đầu. Cùng đầu vào luôn ra cùng version: trong container và trên Windows đều ra `cc759ae1a093`.
- **Không build lại khi không cần:** job kiểm tra version đó đã có chưa; có rồi thì bỏ qua. Ở local, lần đầu mất
  150.7 giây cho 7.079 chunk, lần sau dưới 1 giây; trên cluster 149,1 giây, các lần sau `already exists, skipping build`.
- **Chống lỗi khi build:** embedding gửi theo lô; lỗi 408, 429, 500, 502–504 thì retry với thời gian chờ tăng dần.
- **Trên Kubernetes:** Argo CD chạy job build *trước* khi cập nhật app (Sync hook ở wave 1, Deployment ở wave 2); một
  initContainer tải đúng version ghi trong values (chi tiết: `App A3.2`).
- **Rollback:** đổi `index.version` về giá trị cũ trong Git.

**A3.3** **Ý chính:** "`/healthz` trả lời 'process còn sống không', `/readyz` trả lời 'đã sẵn sàng phục vụ chưa'.
Gộp làm một thì Kubernetes hoặc restart một pod chỉ đang khởi động, hoặc gửi request tới pod chưa sẵn sàng."

*Nếu được hỏi thêm:*

- **`/healthz`:** không kiểm tra gì bên ngoài; dùng cho liveness probe.
- **`/readyz`:** 200 khi index đã nạp và chain đã dựng xong, trước đó 503 kèm lỗi gần nhất; dùng cho readiness và
  startup probe (tối đa 5 phút).
- **Ví dụ, có unit test:** dựng chain lỗi tạm thời. App retry trong nền, thời gian chờ tăng tới tối đa 30 giây;
  `/readyz` trả 503 nên không nhận request, `/healthz` vẫn 200 nên container không bị giết vô ích.
- **Lỗi vĩnh viễn** như thiếu biến `GOOGLE_API_KEY` hay thiếu file index: startup probe restart container sau 5
  phút, để lỗi cấu hình lộ ra thành CrashLoop thay vì âm thầm chờ mãi.
- Mỗi worker gunicorn tự dựng chain; ở local mỗi worker xong trong khoảng 0.7 giây.

**A3.4** **Ý chính:** "Lúc build index thì retry có giới hạn, và nếu vẫn lỗi thì bản app cũ tiếp tục chạy với index
cũ. Lúc phục vụ thì trả lỗi thay vì làm sập worker. Điểm yếu thật là Hugging Face là phụ thuộc đơn, và retry khi đang
phục vụ request hiện quá dài."

*Nếu được hỏi thêm:*

| Tình huống | Cách xử lý |
|---|---|
| Hugging Face lỗi khi build index | Retry theo lô, tối đa 6 lần gọi; hết lượt thì job fail, sync fail, **bản cũ vẫn chạy** |
| Dựng chain lỗi lúc khởi động (thiếu index, thiếu biến môi trường) | Retry trong nền; `/readyz` trả 503 tới khi xong |
| Gemini lỗi khi đang trả lời | Client đặt `max_retries=1` và timeout 30 giây `[điền: kiểm chứng đó là 1 lần gọi hay 1 lần retry]`; lỗi thì trả trang 502, worker không sập, lỗi được đếm trong metric |
| Hugging Face lỗi khi đang trả lời | Embedding câu hỏi retry tới 6 lần gọi; hết lượt thì trả 502 |
| Version index chưa có trên S3 | initContainer fail, pod mới không Ready, pod cũ vẫn phục vụ (B3.5) |

**Trường hợp xấu nhất:** Hugging Face chập chờn làm một request chờ khoảng 30–40 giây cho các lần retry, cộng thêm
thời gian gọi Gemini, có thể vượt timeout đọc mặc định 60 giây của ingress-nginx. Khi đó người dùng thấy **504 từ
ingress-nginx**, không phải trang 502 của app, và retry dồn lại làm lỗi 429 tệ hơn. Cách sửa: giảm retry xuống 1–2
lần khi đang phục vụ request, hoặc embed câu hỏi bằng model nhỏ chạy ngay trong pod.

**A3.5** **Ý chính:** "Image nhỏ đi gần một nửa, từ 926 MB xuống 483 MB, chạy bằng user thường với filesystem chỉ
đọc, và test chạy ngay trong bước build."

*Nếu được hỏi thêm:*

- **Nhiều stage:** công cụ build ở stage riêng; image không mang theo PDF hay `.git`.
- **Bảo mật:** UID 10001; thử `touch` nhận `Read-only file system`; chỉ `/tmp` được ghi.
- **Server:** gunicorn 2 worker, mỗi worker 4 thread.
- **Test:** ruff và 22 test chạy trong stage `test` của Dockerfile, và chạy lại trong pipeline.
- **Phụ thuộc:** khoá bằng `uv.lock`, không kéo PyTorch vì embedding gọi qua API.

**A3.6** **Ý chính:** "Kiến thức nằm sẵn trong tài liệu, nên chỉ cần tìm đúng đoạn và đưa cho model, không cần dạy
lại model. Đổi tài liệu thì build lại index trong vài phút, câu trả lời bám vào nguồn, và không cần GPU."

*Nếu được hỏi thêm:* fine-tune hợp khi cần đổi *cách* model trả lời, như giọng văn hay định dạng, không phải khi cần
thêm *kiến thức*.

**A3.7** **Ý chính:** "Không có bộ đánh giá tự động; project tập trung vào vận hành. Tôi kiểm tra thủ công bằng câu
hỏi trong phạm vi tài liệu, như triệu chứng tiểu đường, và ngoài phạm vi, phải trả lời không biết."

*Nếu làm tiếp:* dựng bộ câu hỏi có đáp án chuẩn; đo retrieval (3 chunk có chứa đoạn đúng không) và đo câu trả lời
(có bám ngữ cảnh không); chạy trong CI mỗi khi đổi chunk, prompt hay model, để thay đổi làm tệ đi bị chặn.

> **Mẹo:** nói thật là không có. Hứa hẹn một bộ đánh giá không tồn tại rất dễ bị hỏi vặn.

**A3.8** **Ý chính:** "Có. Câu hỏi được gửi ra ngoài cho Hugging Face và Google, và app đi qua HTTP thường. Với tài
liệu bách khoa công khai và câu hỏi thử nghiệm thì chấp nhận được; với dữ liệu bệnh nhân thật thì không."

*Nếu được hỏi thêm:*

- **Lưu trữ:** app không có database và không ghi câu hỏi vào log. Lịch sử chat nằm trong cookie session, được ký
  nhưng không mã hoá, và đi qua mạng dạng rõ vì không có HTTPS.
- **Với dữ liệu thật cần:** HTTPS; thoả thuận xử lý dữ liệu với nhà cung cấp hoặc model tự host; không giữ lịch sử
  trong cookie; nói rõ cho người dùng dữ liệu đi đâu.

---

### A4. Hạ tầng và cluster

Bộ câu hỏi chuyên sâu: [Terraform](../terraform/questions.md), [Ansible](../ansible/questions.md),
[Argo CD và GitOps](../gitops/questions.md), [AWS](../aws/questions.md).

**A4.1** **Ý chính:** "Một VPC ba AZ, ba node Kubernetes ở subnet private, hai load balancer, một VPN gateway nhỏ, và
các dịch vụ dùng chung như ECR, S3, KMS, Secrets Manager, Route 53, tất cả dựng bằng Terraform."

*Nếu được hỏi thêm:*

- **Mạng:** VPC `10.10.0.0/16`, subnet public và private ở ba AZ, một NAT gateway, S3 gateway endpoint.
- **Máy:** ba node `m7i-flex.large` (2 vCPU, 8 GB), không public IP, không key SSH; một WireGuard gateway; một ops
  workstation để chạy mọi lệnh.
- **Load balancer:** public NLB cổng 80 cho app; internal NLB cổng 6443 cho Kubernetes API và 443 cho Rancher.
- **Dùng chung:** ECR, S3 cho index, state và snapshot etcd, KMS key ký image, Secrets Manager, Route 53, budget.

**A4.2** **Ý chính:** "Cluster tốn khoảng 0.53 USD mỗi giờ, nên chỉ chạy khi cần. Xoá được vì mọi thứ cần giữ nằm ở
stack khác; dựng lại nhanh vì mọi thứ là code: `make up` dựng hạ tầng, cluster và Argo CD, rồi Argo CD tự cài phần
còn lại."

*Nếu được hỏi thêm:*

- **Chia theo vòng đời:** `bootstrap` (bucket state, workstation) và `shared` (image, index, KMS key, secret, DNS)
  được giữ; `cluster` (mạng, node, load balancer) xoá khi không dùng.
- **Đã đo:** xoá rồi dựng lại stack cluster không có bước thủ công và plan sau đó sạch; bản đủ 84 resource mất 2 phút
  15 giây để xoá và 3 phút 47 giây để dựng.
- **Cả chuỗi:** từ stack cluster trống tới cả 17 Application `Synced` và `Healthy` mất **21 phút 47 giây**, đo bằng
  `infra/scripts/timed-rebuild.sh` chạy một lần không cần người (Terraform 3:46, SSM 0:07, Ansible 6:17, tunnel và bootstrap 0:57,
  các wave của Argo CD 10:40). `make down` xoá các Application của Argo CD trước, rồi mới xoá stack cluster, để volume
  không bị bỏ lại (B6.1).
- **17 Application, 8 wave:** 16 file trong `deploy/argocd/apps` cộng `root`; 13 trong số đó là Helm chart, 3 là manifest
  thường; wave từ `-3` tới `4`.
- **Vì sao rebuild không tốn certificate:** ngày 18/09, health check chỉ đọc `Healthy` nên `root` thả mọi wave cùng lúc;
  cert-manager chạy trước khi bản backup của certificate được khôi phục, và xin một certificate Let's Encrypt mới (giới
  hạn 5 lần mỗi 7 ngày). Tôi viết lại health check bằng Lua: một Application con chỉ được tính là khoẻ khi vừa
  `Healthy` vừa `Synced`, và bị tính là lỗi nếu không có resource nào. Từ đó, ba lần dựng lại đều không có
  CertificateRequest nào (`GitOps A3.3`, `GitOps A5.5`).

**A4.3** **Ý chính:** "Qua AWS Systems Manager Session Manager. Không máy nào mở cổng SSH, không có key pair, không có
bastion. Ansible chạy qua SSM, còn kubectl đi qua một SSM port-forward tới load balancer nội bộ."

*Nếu được hỏi thêm:*

- **Vào máy:** session trong trình duyệt hoặc `aws ssm start-session`; IAM quyết định ai được vào.
- **kubectl:** `make tunnel` mở port-forward từ workstation, qua node 1, tới internal NLB; kubectl gọi
  `https://127.0.0.1:6443`, nên certificate của API server phải có `127.0.0.1` (B1.4).
- **Đánh đổi:** Ansible qua SSM chậm hơn SSH, và node cần NAT để tới SSM. Có một sự cố thật với SSM agent (A10.1).

**A4.4** **Ý chính:** "Ba node ở ba AZ, cả ba là control plane có etcd. Mất một node thì etcd còn 2/3, vẫn đủ quorum,
và API vẫn trả lời: tôi đã tắt thử một node để kiểm chứng. Nhưng hệ thống chưa chịu được mất AZ đầu tiên, vì NAT
gateway duy nhất nằm ở đó."

*Nếu được hỏi thêm:*

- **Internal NLB** đứng trước ba API server, kiểm tra `/readyz` và bỏ server hỏng. `[điền: kubelet của node control
  plane gọi API qua NLB hay qua API server local; xem server trong /etc/kubernetes/kubelet.conf]`.
- **Bài kiểm tra đã làm:** tắt node 2, không phải node 1, vì tunnel kubectl đi qua node 1. Node 2 `NotReady`, API vẫn
  trả lời; bật lại thì node tự về `Ready` mà không cần chạy lại playbook.
- **App prod** có 2 replica trên hai node và PodDisruptionBudget; phần này theo thiết kế, chưa kiểm chứng bằng drill
  riêng.
- **Mất AZ đầu tiên:** NAT gateway, WireGuard gateway và node 1 cùng nằm ở đó, nên cả ba node mất đường ra internet:
  app không gọi được Gemini, SSM ngắt, Rancher không vào được. Cách sửa: mỗi AZ một NAT gateway (thêm khoảng 0.12
  USD/giờ), và dời WireGuard gateway sang AZ khác.

**A4.5** **Ý chính:** "Rancher có toàn quyền cluster, nên chỉ vào được qua VPN WireGuard; cổng 443 chỉ có trên load
balancer nội bộ. Ai tra DNS cũng thấy địa chỉ, nhưng đó là IP private, không có VPN thì không tới được."

*Nếu được hỏi thêm:*

- **Đường đi:** laptop → WireGuard → gateway → internal NLB → ingress-nginx → Rancher.
- **Đã kiểm chứng:** `[điền: không có rule 443 public, URL timeout khi tắt VPN, chuỗi certificate hợp lệ khi bật VPN,
  public NLB chỉ trả 308 cho host Rancher]`.
- Gateway chỉ cho qua DNS và HTTPS; 6443 bị chặn dù cùng NLB.
- Certificate Sectigo; private key nằm trong Secrets Manager và được External Secrets đưa vào cluster.
- Không dùng AWS Client VPN vì nó tính tiền theo giờ cho mỗi subnet gắn vào và mỗi kết nối, đắt hơn nhiều lần một
  máy nhỏ.

**A4.6** **Ý chính:** "App stateless nên scale ngang bằng cách thêm replica. Nhưng nghẽn đầu tiên là giới hạn tốc độ
của Gemini và Hugging Face, không phải CPU. Project chưa có autoscaling và chưa load test, nên tôi không có con số
thật."

*Nếu được hỏi thêm:*

- **Mỗi pod:** 2 worker × 4 thread = 8 request đồng thời, phần lớn thời gian là chờ API bên ngoài.
- **Stateless:** index chỉ đọc; lịch sử chat nằm trong cookie, mọi pod dùng chung secret key.
- **Tăng gấp 10:** xin tăng quota hoặc cache câu hỏi lặp lại; thêm replica, rồi thêm node; giới hạn tốc độ ở ingress
  để quá tải thì trả lỗi nhanh.
- **Còn thiếu:** HorizontalPodAutoscaler và một lần load test.

---

### A5. Rancher và ranh giới giữa các công cụ

Câu về pipeline Jenkins đã chuyển sang bộ riêng: [Jenkins](../jenkins/answers.md).

**A5.1** **Ý chính:** "Mỗi công cụ một vai. Argo CD quyết định cái gì được deploy; Rancher là giao diện để xem và thao
tác với cluster khi xử lý sự cố; kubectl là dòng lệnh. Thay đổi lâu dài vẫn đi qua Git."

*Nếu được hỏi thêm:* Rancher có toàn quyền cluster nên chỉ vào qua VPN (A4.5), và chart của nó ràng buộc phiên bản
Kubernetes được phép nâng lên (A7.3).

---

### A6. Bảo mật

**A6.1** **Ý chính:** "Secret nằm trong AWS Secrets Manager. Terraform chỉ tạo secret rỗng, giá trị được nhập một lần
bằng CLI. External Secrets trong cluster đọc nó và tạo Kubernetes Secret. Git, state của Terraform và image không chứa
giá trị secret nào."

*Nếu được hỏi thêm:*

- **Nhập giá trị:** từ một file tạm, rồi `shred` file.
- **Đổi secret:** cập nhật trên Secrets Manager; External Secrets cập nhật Kubernetes Secret ở lần refresh sau. Thứ
  theo dõi Secret qua Kubernetes API, như ingress-nginx với certificate của Rancher, nhận giá trị mới mà không cần
  deploy lại. Biến môi trường của app chỉ đổi khi pod khởi động lại, nên phải restart Deployment (A9.2).
- **Private key không đi qua Terraform hay Git:** key của certificate Rancher và key server WireGuard sinh trên
  workstation, đưa vào Secrets Manager rồi `shred -u`; private key WireGuard của laptop không rời laptop.
- **Giới hạn:** trong cluster, Secret nằm trong etcd và trong snapshot etcd trên S3 (A6.4, B5.4).

**A6.2** **Ý chính:** "Chuỗi bốn bước: quét, sinh SBOM, ký digest bằng KMS, và Kyverno kiểm tra chữ ký trước khi pod
chạy. Image của app chưa ký thì không vào được prod."

*Nếu được hỏi thêm:*

- **Quét:** Trivy chặn khi có CRITICAL đã có bản sửa. Đổi base sang Debian 13 hạ CRITICAL từ 5 xuống 0, HIGH từ 55
  xuống 44, tổng số finding giảm 41% (269 → 158). Cổng đó được chứng minh biết chặn bằng một build **positive control**:
  trên một branch tạm, cổng được nới ra đếm finding có bản sửa ở mọi mức, và build 2 đỏ với
  `Fixable, any severity: 6` (`Jenkins A5.2`).
- **Ký:** private key không rời KMS; chỉ role `medical-rag-ci` của pod build có `kms:Sign`. Node role đã bị gỡ quyền đó
  ở phase Jenkins, và một pod thường mượn role của node bị KMS từ chối (`Jenkins A3.5`).
- **Kiểm tra:** Kyverno `ImageValidatingPolicy` dùng public key; prod `Deny`, dev `Audit`. Deploy thử image chưa ký
  lên prod bị từ chối nguyên văn:
  `admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-images-prod" denied the request: Policy verify-images-prod failed: the image is not signed with the medical-rag cosign key`.
  Pod mới dùng image đã ký vẫn được tạo ngay sau đó.
- **Giới hạn cần nói rõ:** chữ ký chứng minh "được ký bằng key này", không chứng minh "đã qua pipeline của `main`":
  ai chiếm được pod build là ký được. Kyverno cũng chỉ kiểm tra image của app trong hai namespace `medical-rag-dev` và
  `medical-rag-prod`, không kiểm tra image của addon (B4.2).

**A6.3** **Ý chính:** "Chỉ hai cổng mở ra internet: HTTP 80 của app và UDP 51820 của WireGuard. Không có SSH, node
không có public IP, Kubernetes API và Rancher chỉ có trên load balancer nội bộ."

*Nếu được hỏi thêm:*

- **Least privilege:** policy tự viết ghi đúng tài nguyên; riêng hai managed policy của AWS trên role của node rộng
  toàn account.
- **Mã hoá:** EBS mã hoá; bucket S3 chặn truy cập public và chỉ nhận HTTPS.
- **Metadata:** bắt buộc IMDSv2. Nhưng hop limit để 2 cho pod, nên thứ thật sự chặn pod app lấy credential là
  NetworkPolicy, không phải IMDSv2: từ container app, IMDS timeout và AWS SDK báo `NoCredentialsError` (`App A2.8`).
- **Pod:** non-root, filesystem chỉ đọc; NetworkPolicy chỉ cho traffic vào namespace app từ ingress-nginx và
  monitoring.

**A6.4** **Ý chính:** "Nặng nhất là các pod nền tảng vẫn dùng chung quyền IAM của node qua metadata service. Pod app,
Job build index và pod build của Jenkins đã có role riêng qua IRSA tôi tự dựng, nhưng External Secrets, cert-manager,
EBS CSI, CronJob snapshot etcd và cả Kyverno (nó kéo chữ ký từ ECR bằng role của node) thì chưa. Thứ hai là Secret trong etcd chưa được mã hoá at-rest, mà
snapshot etcd lại nằm trên S3. Các điểm còn lại đều có cách sửa cụ thể."

*Nếu được hỏi thêm:*

1. **Quyền IAM dùng chung:** pod lấy được credential của node đọc được tám secret, ghi được bản ghi TXT của ACME, đọc,
   ghi và xoá được object trong bucket `etcd-backups` và bucket chuyển file của Ansible, cộng managed policy
   `AmazonEBSCSIDriverPolicy` rộng toàn account. Quyền ký image và push ECR đã bị gỡ khỏi node role (`Jenkins A3.5`).
   Cách sửa là cho từng addon một role IRSA riêng.
2. **Secret trong etcd và snapshot:** cần `EncryptionConfiguration` cho API server, và mã hoá bucket backup bằng KMS
   key riêng mà role của node không decrypt được (B5.4).
3. **File pickle của index:** app nạp `index.pkl` với `allow_dangerous_deserialization=True`, nên ai ghi được vào bucket
   artifacts là chạy được code trong pod app. Cách sửa: chỉ Job build được ghi, app chỉ đọc, và kiểm tra hash trong
   manifest trước khi nạp.
4. **Token GitHub của bot** push thẳng được lên `main`, nên "prod chỉ đổi qua PR" hiện là quy ước (B5.2).
5. **Workstation có `AdministratorAccess`:** ai mở được session trên nó là admin.
6. **App không có HTTPS**, và **một NAT gateway** là điểm lỗi đơn.

> **Mẹo:** kể ba điểm đầu kèm cách sửa, ngắn gọn, không xin lỗi. Người phỏng vấn tìm người biết giới hạn của hệ thống
> mình dựng.

---

### A7. Vận hành ngày 2 và quan sát

**A7.1** **Ý chính:** "App xuất metric Prometheus, đo riêng thời gian tìm kiếm và thời gian gọi LLM để biết chậm ở đâu.
kube-prometheus-stack thu metric của app và cluster, Grafana hiển thị."

*Nếu được hỏi thêm:*

- `http_requests_total` theo route, method và mã trạng thái: tỉ lệ lỗi.
- `http_request_duration_seconds`: độ trễ.
- `rag_retrieval_duration_seconds` và `llm_request_duration_seconds` (có nhãn `outcome`): chậm hay lỗi ở tìm kiếm hay
  ở Gemini.
- `rag_index_info{version}`: pod đang dùng index nào.
- gunicorn có 2 worker; app dùng multiprocess mode của thư viện Prometheus để cộng dồn (B2.7). Prometheus giữ dữ liệu
  24 giờ; Grafana chỉ vào qua port-forward.

**A7.2** **Ý chính:** "Snapshot etcd 6 giờ một lần lên S3, kiểm tra bằng `etcdutl snapshot status` trước khi upload,
và tôi đã diễn tập khôi phục có đo thời gian: xoá một namespace, khôi phục cả ba member, RTO 7 phút 02 giây tới khi mọi
Application khoẻ, tính cả thời gian gõ lệnh. RPO tối đa 6 giờ theo lịch; lần diễn tập đó mất 6 phút dữ liệu."

*Nếu được hỏi thêm:*

- **Diễn tập:** một namespace thử *không* do Argo CD quản lý (nếu không Argo CD tự tạo lại, chẳng chứng minh được gì),
  có một ConfigMap ghi giờ tạo, được tạo **trước** snapshot. Sau khi khôi phục, ConfigMap quay lại đúng giá trị đó,
  nên dữ liệu thật sự trở về, không chỉ cluster sống lại.
- **Khôi phục trên cả ba member** nghĩa là control plane ngừng hoàn toàn trong lúc đó; mỗi node chạy
  `etcdutl snapshot restore` từ cùng một file với cùng `--initial-cluster` và `--initial-cluster-token`, kèm
  `--bump-revision` và `--mark-compacted`. Cả ba ra cùng một cluster-id.
- **Cái bẫy khi đo RTO:** snapshot khôi phục cả *status* cũ của lúc chụp, khi mọi Application đang `Healthy`, nên một
  vòng chờ chỉ đọc health có thể dừng ngay khi API trả lời. Tôi chỉ bấm giờ dừng khi `reconciledAt` của từng
  Application và Lease của từng node mới hơn lúc bắt đầu; lúc API trả lời lần đầu, 2 trong 17 Application còn chưa
  reconcile.
- Chi tiết từng bước: [`../drills/answers.md`](../drills/answers.md).
- **Giới hạn:** chỉ backup etcd, không backup `/etc/kubernetes/pki`. Mất cluster thì dựng lại từ code và Git, không
  khôi phục từ snapshot.

**A7.3** **Ý chính:** "Playbook nâng từng node một đã viết: drain, nâng kubeadm và kubelet, đưa node trở lại, chờ node
Ready và mọi Application khoẻ rồi mới sang node tiếp. Nhưng tôi chưa chạy nó, và nói thật lý do: cluster đang ở 1.36.4,
cũng là bản vá mới nhất của 1.36, nên không có gì để nâng. Lên 1.37 thì bị chặn bởi Rancher."

*Nếu được hỏi thêm:*

- **Cổng kiểm tra:** chart Rancher 2.15.1 chỉ chấp nhận Kubernetes dưới 1.37; phải nâng Rancher trước.
- **Playbook:** `upgrade.yml`, bốn play: kiểm tra trước khi đụng node (bản đích phải là patch của cùng minor, ba node
  Ready, đếm số Application), `kubeadm upgrade apply` ở node 1, kubelet của node 1, rồi hai node còn lại với
  `serial: 1`. Đã qua `--syntax-check` và `--list-hosts`.
- **Cách đo được nếu cần:** dựng cluster ở 1.36.3 rồi nâng lên 1.36.4 trong lúc một vòng `curl` đếm request lỗi.

> **Mẹo:** đừng nói "đã nâng cấp không downtime". Nói "đã viết và kiểm cú pháp; chưa có bản đích để chạy".

**A7.4** **Ý chính:** "Mỗi phase chỉ tính là xong khi có lệnh kiểm tra và kết quả ghi vào `docs/evidence`. Ba ví dụ:
dựng lại cả nền tảng từ stack cluster trống trong 21 phút 47 giây; khôi phục etcd với RTO 7 phút 02 giây; image chưa ký bị từ chối
trên prod. Anh chị muốn xem phần nào thì tôi mở evidence."

*Nếu được hỏi thêm:*

- **App:** 22 test pass; image 926 → 483 MB; build index 150.7 giây ở local, lần hai dưới 1 giây.
- **Terraform:** bootstrap 18, shared 38, cluster 84 resource (86 sau phase drills); request HTTP tới bucket state bị từ chối; mô phỏng IAM
  đúng như thiết kế.
- **Ansible:** `make cluster` trên node mới 6 phút 10 giây; chạy lần hai `changed=0`; tắt node 2, API vẫn trả lời.
- **GitOps và CI:** 17 Application `Synced` và `Healthy`; commit tới dev chạy 19 phút 08 giây (con số mềm: có một lần
  refresh bằng tay); `cosign verify` nhận image đã ký và từ chối image chưa ký; cổng Trivy đỏ ở positive control.
- **Vận hành ngày 2:** Kyverno từ chối image chưa ký với lỗi admission nguyên văn; RTO 7 m 02 s; nâng cấp **không đo
  được** (A7.3).

**A7.5** **Ý chính:** "Nói thật: lab không chạy 24/7 nên không có on-call. Alertmanager trong kube-prometheus-stack có
`[điền: số]` rule cho lỗi 5xx, pod không Ready, etcd mất member và CPU node. Ở công ty tôi sẽ thêm một probe chạy từ
bên ngoài cluster, vì cluster chết thì Alertmanager trong cluster cũng chết theo."

*Nếu được hỏi thêm:* cảnh báo CPU cho `m7i-flex` dựa trên mức dùng CPU kéo dài, vì loại máy này không có metric CPU
credit (B6.4).

> **Mẹo:** xác nhận các rule và receiver đã thật sự được cấu hình trước khi nói (checklist đầu file).

---

### A8. Chi phí và ràng buộc

**A8.1** **Ý chính:** "Cluster khoảng 0.53 USD mỗi giờ và chỉ chạy khi cần; phần luôn giữ khoảng 7 USD mỗi tháng. Tôi
kiểm soát chi phí bằng thiết kế, xoá cluster khi không dùng, và bằng budget cảnh báo lọc theo tag của project."

*Nếu được hỏi thêm:*

| Hạng mục | Chi phí |
|---|---|
| Cluster khi đang chạy (3 node, NAT, 2 NLB, WireGuard, ổ đĩa, IPv4) | ≈ 0.53 USD/giờ |
| Workstation khi đang chạy | ≈ 0.03 USD/giờ |
| Luôn giữ (KMS key, 5 secret, Route 53, bucket, image, ổ đĩa workstation) | ≈ 7 USD/tháng |

Cách giảm: xoá cluster khi không dùng; một NAT gateway thay vì ba; S3 gateway endpoint miễn phí; WireGuard thay vì VPN
managed. Budget 100 USD/tháng gửi email ở 50% và 100% chi phí thực.

**A8.2** **Ý chính:** "Năm ràng buộc: account ở AWS Free plan, credit có hạn, account dùng chung với project khác, một
người vận hành, và không cài công cụ nào lên laptop."

*Nếu được hỏi thêm:*

| Ràng buộc | Ảnh hưởng tới thiết kế |
|---|---|
| **Free plan** chỉ cho chạy loại máy đủ điều kiện | Node `m7i-flex.large`, workstation `t3.small` kèm swap; delegate DNS thay vì chuyển domain sang Route 53 |
| **Credit có hạn** | Chia stack để xoá cluster khi không dùng; một NAT gateway |
| **Account dùng chung** | Tag `project` cho budget; tên theo `medical-rag-*`; VPC riêng vì VPC mặc định đã mất subnet |
| **Một người vận hành** | Terraform chạy từ workstation thay vì CI; mỗi bước có hướng dẫn và lệnh kiểm tra |
| **Không cài gì lên laptop** | Mọi công cụ nằm trên ops workstation với phiên bản được ghim, nên ai cũng tái tạo được môi trường |

---

### A9. Tình huống

**A9.1** **Ý chính:** "Tôi khoanh vùng từ ngoài vào trong, thu bằng chứng trước khi can thiệp. Trước hết xem ai vừa đổi
gì: Argo CD vừa sync bản mới thì revert trong Git. Nếu không có thay đổi nào, xem lỗi đến từ đâu: load balancer, ingress,
pod, hay API bên ngoài. Lỗi ở Gemini hay Hugging Face thì restart hay rollback đều vô ích."

*Nếu được hỏi thêm*, từng bước:

1. **Thay đổi gần nhất:** lịch sử sync của Argo CD, `git log deploy/envs/prod`.
2. **502 hay 504:** 504 thường là ingress-nginx hết 60 giây chờ app, tức app treo vì retry API bên ngoài (A3.4); 502
   là trang lỗi của app hoặc không có pod nào sẵn sàng.
3. **Target của NLB** còn healthy không; pod có `Ready` không; trường `error` của `/readyz`.
4. **Metric:** `http_requests_total{status="502"}` và `llm_request_duration_seconds{outcome="error"}` cho biết lỗi do
   Gemini; log của app cho biết lỗi embedding.
5. **Xử lý:** bản mới gây lỗi thì `git revert`; API bên ngoài lỗi thì báo trạng thái, chờ, và cân nhắc giảm retry để
   trả lỗi nhanh.

**A9.2** **Ý chính:** "Không sửa thẳng trên cluster. Hotfix vẫn đi qua Git bằng một PR khẩn, vì Argo CD sẽ ghi đè bản
sửa tay. Đổi secret thì không có commit nào, và app chỉ nhận giá trị mới khi pod restart."

*Nếu được hỏi thêm:*

- **Nếu buộc phải sửa tay** để cầm máu: tạm tắt auto-sync của Application đó, ghi lại, rồi đưa bản sửa vào Git và bật
  lại.
- **`kubectl edit` trên prod:** Argo CD báo `OutOfSync`; nếu bật `selfHeal` thì tự đưa về Git.
- **Đổi secret:** External Secrets cập nhật Kubernetes Secret, nhưng biến môi trường chỉ đổi khi pod khởi động lại.
  Cách làm tự động: annotation checksum của Secret trên Deployment, hoặc một controller như Reloader.
- **Jenkins push lên `main`** có thể đụng commit của người; bước push cần rebase và thử lại.

**A9.3** **Ý chính:** "Bộ nhớ trước tiên: ba node 8 GB vừa chạy control plane vừa chạy Jenkins, Prometheus và Rancher.
Tiếp theo là các điểm lỗi đơn: một NAT gateway, Hugging Face cho mọi câu hỏi, và tunnel kubectl chỉ qua node 1."

*Nếu được hỏi thêm:* certificate Sectigo gia hạn tay; credit AWS hết hạn 2027-02-13; retry khi đang phục vụ request
làm quá tải dồn lại (A3.4); chưa có autoscaling.

**A9.4** **Ý chính:** "Pod của app bị NetworkPolicy chặn gọi metadata service, nên không lấy được quyền IAM của node.
Nhưng egress TCP 443 mở ra mọi nơi, nên kẻ tấn công vẫn gửi dữ liệu ra ngoài được, và đọc được biến môi trường của
chính pod, tức key Gemini và Hugging Face."

*Nếu được hỏi thêm:*

- **Nếu leo sang được một pod có quyền IAM:** pod build của Jenkins (role `medical-rag-ci`) ký được image và push ECR,
  nhưng không đọc được secret nào hay bucket `etcd-backups` (B5.2). Pod dùng role của node, như External Secrets, đọc
  được tám secret và đọc, ghi, xoá được snapshot etcd chứa mọi Kubernetes Secret (B5.4).
- **Chiều ngược lại:** ai ghi được vào bucket artifacts thì chạy được code trong pod app qua file pickle (A6.4).
- **Hạn chế thiệt hại:** container non-root, filesystem chỉ đọc, drop mọi capability.
- **Cách siết:** egress chỉ tới đúng domain cần thiết qua proxy. IRSA tự host đã làm cho app (`App A2`); pod nền tảng
  vẫn dùng role của node (`App A10.5`).

**A9.5** **Ý chính:** "Prompt nằm trong code nên đi qua pipeline image như mọi thay đổi code. Model Gemini là biến môi
trường nên đổi trong values. Đổi model embedding thì version index đổi theo, nên image và `index.version` phải đổi trong
cùng một commit, nếu không vector câu hỏi và index sẽ lệch nhau. Rollback là revert commit đó."

*Nếu được hỏi thêm:*

- **Độ trễ:** thời gian retrieval và thời gian gọi LLM đã được đo riêng; ngưỡng p95 mong muốn `[điền]`.
- **Token:** client trả về số token trong mỗi câu trả lời, nhưng app chưa xuất thành metric; tôi nói thẳng là chưa có.
- **Chất lượng:** không có bộ đánh giá chặn thay đổi làm tệ đi (A3.7); đó là việc cần làm trước khi đổi model thật.

**A9.6** **Ý chính:** "Hai SLO cho đường trả lời câu hỏi: tỉ lệ request thành công và độ trễ p95, tách phần thời gian
chờ API bên ngoài. Nhưng tôi nói rõ: lab xoá cluster khi không dùng nên SLO chỉ có nghĩa lúc cluster chạy, và cảnh báo
theo burn rate là phần của project EKS."

*Nếu được hỏi thêm:* dữ liệu lấy từ `http_requests_total` và `http_request_duration_seconds` của route `/`;
`[điền: mục tiêu cụ thể nếu có]`.

**A9.7** **Ý chính:** "Mỗi lớp có kiểm tra riêng: unit test và lint cho app chạy ngay trong bước build, `validate` và
chu trình xoá dựng lại cho Terraform, lần chạy thứ hai `changed=0` cho Ansible, và Trivy, chữ ký cho image. Còn thiếu
smoke test sau khi Argo CD sync, test cho policy Kyverno, và lint cho Helm chart."

*Nếu được hỏi thêm:* 22 test gồm hash của index, retry embedding, `/healthz` và `/readyz`, XSS; `kubeconform` và
`kyverno test` là hai thứ tôi sẽ thêm vào CI đầu tiên.

**A9.8** **Ý chính:** "README trỏ tới mọi thứ: hai guide từng bước cho Terraform và Ansible, tài liệu thiết kế, và
evidence của từng phase. Việc hằng ngày chỉ là `make up` và `make down`; mỗi guide có bảng xử lý sự cố."

*Nếu được hỏi thêm:* các bước thủ công một lần (apply bootstrap, delegate DNS, nhập secret) đều có lệnh kiểm tra đi kèm.

**A9.9** **Ý chính:** "Không ít: nâng minor Kubernetes kèm cổng kiểm tra Rancher, cập nhật plugin Jenkins, Calico,
ecr-credential-provider, gia hạn certificate, và theo dõi ma trận phiên bản của từng addon. Với một app nhỏ ở công ty
thì không đáng; đó là lý do ở công ty tôi chọn EKS hoặc ECS."

---

### A10. Khó khăn và bài học

> **Mẹo:** với mọi chuyện ở nhóm này, kể một chuyện mà nguyên nhân được chứng minh bằng log hoặc số đo, và nói rõ đâu
> là nguyên nhân đã chứng minh, đâu là giả thuyết.

**A10.1** **Ý chính:** "Build Docker cứ treo ở bước tải package từ PyPI. Tôi đo thay vì đoán: cùng một file, qua IPv4
mất 11 đến 20 giây, qua IPv6 chỉ 0.45 giây. Container của Docker Desktop không có IPv6 global, và hệ thống vẫn ưu tiên
IPv4, nên nó luôn đi đường chậm. Tôi cấu hình Docker Engine dùng một dải IPv6 dạng global; cùng lượt tải trong bước
build còn 0.41 giây."

*Nếu được hỏi thêm:*

- Chi tiết: sau khi bật IPv6, container chỉ nhận địa chỉ ULA nội bộ, nên glibc vẫn chọn IPv4. Dải `2001:db8:1::/64` là
  dải dành cho tài liệu, không định tuyến ra internet, nhưng glibc coi nó là global nên ưu tiên IPv6. Lỗi chỉ nằm ở máy
  local; cluster trên AWS không bị.
- **Chuyện dự phòng 1, Free plan chặn loại máy:** lần launch EC2 đầu tiên lỗi `not eligible for Free Tier` dù còn
  credit. Đọc kỹ thì lỗi nói về *loại máy*. Tôi kiểm tra trạng thái gói của account, liệt kê loại máy hợp lệ, chọn
  `m7i-flex.large`, và ghi lại rủi ro mới: loại máy này không có metric CPU credit.
- **Chuyện dự phòng 2, một node không vào được Session Manager:** node 1 và 3 bình thường, node 2 báo
  `TargetNotConnected`. Máy vẫn chạy, nên tôi tìm bằng chứng trước: SSM không có bản ghi nào của node 2, log boot báo
  agent không lấy được credential dù instance profile đã gắn. Giả thuyết là agent chạy trước khi credential sẵn sàng;
  chưa chứng minh được vì hai node còn lại tạo cùng lúc vẫn bình thường. Reboot để khôi phục. Script lúc boot chờ
  credential chưa làm; thay vào đó script rebuild tự động (`timed-rebuild.sh`) hỏi SSM xem có bản ghi của node đó
  không, và chỉ reboot một lần khi SSM chưa từng thấy nó. Lần gặp lại ngày 22/09 có vẻ chỉ là agent đăng ký chậm:
  ping lại là được, không cần reboot; lần đó tôi không đọc log của SSM nên không kết luận chắc.

**A10.2** **Ý chính:** "WireGuard gateway đầu tiên boot lỗi, và tôi dựng lại máy ngay mà không giữ log. Máy mới chạy
được, nhưng tôi mất nguyên nhân gốc: khả năng cao là secret còn rỗng lúc boot, nhưng không chứng minh được. Từ đó bước
đầu tiên của tôi khi xử lý sự cố là thu log trước khi thay bất cứ thứ gì."

*Nếu được hỏi thêm*, hai sai sót khác:

- Guide Ansible giả định `crictl` đi kèm `kubeadm`; lệnh kiểm tra báo `not found`. Tôi xác nhận package `kubeadm` không
  còn phụ thuộc `cri-tools`, rồi cài nó tường minh.
- Giá trị mặc định của dải WireGuard nằm trong dải Service của Kubernetes; tôi tự phát hiện khi rà lại code, chưa gây
  hỏng.

**A10.3** **Ý chính:** "Thiết kế đã ghi sẵn thứ tự cắt trước khi bắt đầu: các hạng mục P1 trước, rồi tự động mở PR
prod, rồi SBOM attestation. Không bao giờ cắt quét, ký và GitOps, vì đó là thứ project muốn chứng minh. Tiêu chí là giữ
lại những gì chứng minh được bằng evidence."

*Nếu được hỏi thêm:* `[điền: thực tế đã cắt gì, và phase nào kéo dài hơn timebox, vì sao]`.

**A10.4** **Ý chính:** "Các quyết định vận hành là của tôi, và tôi chứng minh bằng những chỗ không hiển nhiên, như vì
sao lifecycle policy của ECR chỉ đếm image có tag, hay vì sao certificate của API server phải có `127.0.0.1`. Tôi có dùng
AI để soạn tài liệu và rà soát; mọi thứ đều được kiểm chứng bằng lệnh chạy thật và ghi vào evidence."

> **Mẹo:** nói thật về AI và nói cách bạn kiểm chứng. Chuẩn bị giải thích được bất kỳ dòng code nào người phỏng vấn
> chỉ vào; các bộ câu hỏi chi tiết Terraform, Ansible và AWS dùng để luyện đúng việc này.

**A10.5** **Ý chính:** "Sửa ba điểm yếu lớn nhất: quyền IAM dùng chung của node cho các pod nền tảng, bằng
cùng issuer mà app đã dùng, mã hoá Secret trong
etcd và snapshot, và NAT gateway đơn. Sau đó là bộ đánh giá chất lượng câu trả lời và một lần load test."

*Nếu được hỏi thêm:* tách `AdministratorAccess` của workstation; đưa Terraform vào CI với OIDC; giảm retry khi đang
phục vụ request; smoke test sau mỗi lần sync.

**A10.6** **Ý chính:** "Kiến trúc tương tự, nhưng quy mô, quyền hạn và quy trình đơn giản hơn nhiều: một account, một
người vận hành, cluster tự dựng và xoá khi không dùng."

*Nếu được hỏi thêm:*

| Ở project này | Ở công ty |
|---|---|
| Một account AWS, dùng chung | Nhiều account theo môi trường, chính sách chung toàn tổ chức |
| Một người, apply từ workstation | Apply qua CI, có review, credential tạm thời |
| Tự dựng Kubernetes | Nhiều khả năng dùng EKS |
| Cluster xoá khi không dùng | Chạy liên tục, có SLO và on-call |
| Một NAT gateway | Mỗi AZ một NAT gateway |
| App qua HTTP | HTTPS, WAF |
| VPN bằng key quản lý tay | Truy cập qua hệ thống định danh có MFA |

**A10.7** **Ý chính:** "Ba bài học. Thiết kế theo vòng đời và theo ranh giới trách nhiệm, thì hệ thống dễ dựng lại và
dễ sửa. Thiết kế cho cả lúc xoá, không chỉ lúc dựng: `make down` phải xoá Application trước, nếu không volume bị bỏ lại
và vẫn tính tiền. Và thu bằng chứng trước khi sửa, kể cả khi reboot có vẻ nhanh hơn."

---

## Phần B — Chi tiết

Đáp án ngắn, để tự kiểm tra. Căn cứ chính: thiết kế, code trong `src/app` và `infra/`, và evidence.

### B1. Mạng và luồng request

**B1.1** Pod CIDR `192.168.0.0/16` và Service CIDR `10.96.0.0/12` được chọn nằm ngoài VPC cluster `10.10.0.0/16` và
VPC workstation `10.20.0.0/24`. Trùng dải thì định tuyến mơ hồ: gói tin tới một IP trùng đi sai mạng mà không báo lỗi.

**Có một cặp trùng:** dải WireGuard `10.99.0.0/24` nằm trong `10.96.0.0/12`. Chưa gây hỏng, vì gateway NAT mọi traffic
từ tunnel về địa chỉ VPC của nó (Terraform B9.7).

*Ở đâu:* `infra/ansible/inventory/group_vars/all.yml`; Terraform B4.1.

**B1.2** `Trình duyệt → public NLB TCP 80 → NodePort 30080 → ingress-nginx → pod app, gunicorn cổng 8000`.
ingress-nginx gửi thẳng tới IP pod lấy từ EndpointSlice; nếu pod ở node khác thì đi qua VXLAN (UDP 4789).

**IP thật:** public NLB giữ IP client khi tới node, nhưng Service NodePort của ingress-nginx dùng
`externalTrafficPolicy: Local`. Với `Cluster`, kube-proxy SNAT mọi traffic vào NodePort, nên ingress-nginx chỉ thấy
IP node. `Local` giữ IP thật; health check của NLB loại node không có pod ingress, nên ingress-nginx chạy dạng DaemonSet.
Cách khác là Proxy Protocol v2.

**B1.3** TLS đi xuyên qua internal NLB (listener TCP 443) và **terminate ở ingress-nginx** bằng certificate Sectigo
trong Secret `tls-rancher-ingress`. Load balancer không bao giờ giữ private key; certificate mua ngoài nên không dùng
ACM, và API Kubernetes cùng NLB cũng cần TCP passthrough. Từng chặng mạng: Terraform B9.8.

**B1.4** `make tunnel` mở SSM port-forward (`AWS-StartPortForwardingSessionToRemoteHost`) từ workstation, qua node 1, tới
internal NLB cổng 6443; kubectl gọi `https://127.0.0.1:6443`.

Certificate chỉ hợp lệ cho các tên trong SAN; client nối tới `127.0.0.1` nên thiếu tên này thì TLS báo sai tên. kubeadm
không tự thêm, nên `certSANs` liệt kê `127.0.0.1` và `localhost` cạnh DNS name của NLB. Vì tunnel đi qua node 1, bài
drill HA tắt node 2.

*Ở đâu:* `infra/ansible/roles/kubeadm_init/templates/kubeadm-config.yaml.j2`; `Makefile` target `tunnel`.

**B1.5** ingress-nginx định tuyến theo **host** trên cùng public NLB: `dev.recruitai.io.vn` sang dev,
`app.recruitai.io.vn` sang prod. Thiết kế ban đầu dùng path `/dev` vì lúc đó chưa có domain; có domain rồi thì mỗi môi
trường một host, nên app không phải biết tiền tố URL nào. Probe (`/readyz`, `/healthz`) và ServiceMonitor (`/metrics`) dùng
đúng một path ở cả hai môi trường, và gọi thẳng pod, không qua Ingress. Chi tiết: `App A1.4`.

**B1.6**

- **Ingress:** chỉ từ namespace `ingress-nginx` và `monitoring`.
- **Egress:** chỉ DNS và TCP 443. Metadata service là `http://169.254.169.254`, cổng 80, nên pod app vốn không tới
  được nó; thiết kế vẫn chặn `169.254.169.254/32` tường minh.

**Mâu thuẫn trong thiết kế ban đầu:** initContainer tải index và Job build index cần đọc, ghi S3, mà với instance role
thì phải gọi metadata service. Đã giải quyết bằng IRSA tự host: chúng nhận role riêng qua token, nên cả namespace chặn được
IMDS (`App A2`).

### B2. App và index

**B2.1** SHA-256 của **tên** và nội dung từng file PDF (sắp theo tên), cộng chuỗi `chunk_size:chunk_overlap:model`,
lấy 12 ký tự hex đầu. Đổi tên file thì **version đổi**, dù vector sinh ra giống hệt. Đổi `CHUNK_SIZE` (500),
`CHUNK_OVERLAP` (50) hay model (`sentence-transformers/all-MiniLM-L6-v2`) cũng vậy.

*Ở đâu:* `src/app/index.py` (`compute_version`), `src/app/config/config.py`.

**B2.2** Job là **Sync hook ở wave 1**: chạy sau wave 0 (ServiceAccount, ExternalSecret, NetworkPolicy) và trước
Deployment ở wave 2; Job lỗi thì sync lỗi và bản cũ vẫn chạy. Không dùng PreSync vì PreSync chạy trước cả ServiceAccount và
Secret mà Job cần (`App A3.2`). `python -m app.index build` tính version, thấy `faiss/<version>/manifest.json` đã có thì log
`already exists, skipping build` và thoát. Trong cluster nó không bao giờ ghi `faiss/LATEST` (`INDEX_UPDATE_LATEST=false`, và
role builder bị `Deny`). Ở local lần đầu 150.7 giây; trên cluster 149,1 giây, các lần sau chỉ vài giây.

**Cần biết thêm:**

- Hook chạy ở **mọi** lần sync, kể cả sync do selfHeal, nên bước "bỏ qua nếu đã có" là bắt buộc.
- Job cần `hook-delete-policy: BeforeHookCreation`, nếu không lần sync sau lỗi vì Job cùng tên đã tồn tại.
- Job của dev và prod cùng ghi `faiss/LATEST`; đó là một lý do nữa để không dùng con trỏ này (B2.3).

**B2.3** Một **initContainer** tải `faiss/<index.version>/` từ bucket artifacts vào `emptyDir` mount tại
`INDEX_DIR=/tmp/index`; container app không tự tải (`INDEX_PULL_ON_START` tắt) và chỉ đọc index lúc khởi động.

**Vì sao không dùng `LATEST`:** Git phải là nơi quyết định index nào chạy, rollback là revert một dòng; `LATEST` đổi bất
cứ lúc nào và bị cả dev lẫn prod ghi, nên hai pod khởi động cách nhau vài phút có thể nạp hai index khác nhau.

**Ghi chú:** initContainer dùng image aws-cli công khai nên không qua kiểm tra chữ ký của Kyverno; dùng chính image app
chạy `python -m app.index pull` thì có.

**B2.4**

- **Theo lô:** 64 chunk mỗi request.
- **Retry:** tối đa **6 lần gọi**, chờ 1, 2, 4, 8, 16 giây cộng jitter tới 25%.
- **Mã HTTP được retry:** 408, 429, 500, 502, 503, 504.
- **Lỗi không có response:** chỉ retry nếu exception là `ConnectionError`, `TimeoutError`, `OSError`, hoặc tên lớp chứa
  `Timeout`. Thư viện Hugging Face dùng httpx; `httpx.ConnectError` (mất kết nối, lỗi DNS) không thuộc các lớp đó nên
  **có thể không được retry**. Unit test dùng `ConnectionError` có sẵn của Python nên không bắt được trường hợp này
  `[điền: đã kiểm chứng với lỗi httpx thật, hoặc đã sửa code]`.
- **Không retry:** mọi mã khác, như 401 khi token sai, để lỗi cấu hình lộ ra ngay.

Cùng cơ chế áp cho `embed_query` lúc trả lời (A3.4).

*Ở đâu:* `src/app/components/embeddings.py`.

**B2.5** Mỗi worker tạo app, và `ChainHolder` dựng chain trong **một thread nền**: nạp FAISS từ đĩa, tạo client
embedding và client Gemini. Dựng lỗi thì retry, thời gian chờ gấp đôi, tối đa 30 giây.

- **Pod `Ready`** nghĩa là worker nhận probe đã dựng xong chain. Worker kia có thể vẫn đang dựng và trả "still starting
  up" với mã 503 cho request rơi vào nó.
- **Không có nghĩa là** key Gemini hay token Hugging Face còn hợp lệ: dựng chain không gọi mạng, nên key sai chỉ lộ ra
  lúc trả lời, thành 502.

**B2.6**

| Probe | Endpoint | Ý nghĩa |
|---|---|---|
| startupProbe | `/readyz` | `failureThreshold × periodSeconds` = 5 phút; trong lúc đó liveness chưa chạy |
| readinessProbe | `/readyz` | Không Ready thì không nhận traffic |
| livenessProbe | `/healthz` | Chỉ kiểm tra process; lỗi thì restart container |

**Đánh đổi:** app được viết để retry trong nền mà không bị restart, nhưng startup probe vẫn giết container sau 5 phút
nếu chain chưa dựng được. Lỗi cấu hình vì vậy lộ ra thành CrashLoop, nhưng lỗi tạm thời kéo dài hơn 5 phút cũng bị
restart. Chart đặt startup `periodSeconds: 10`, `failureThreshold: 30` (5 phút); readiness 10 s × 3; liveness 20 s × 3,
timeout 5 s (`App B1.4`).

**B2.7** gunicorn có 2 worker, mỗi worker là một process với bộ đếm riêng. Không có multiprocess mode thì mỗi lần scrape
chỉ thấy số của worker nhận request đó.

- **`PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus`:** mỗi process ghi metric ra file; `/metrics` gộp tất cả.
- **Xoá lúc khởi động:** `/tmp` là `emptyDir`, sống qua các lần container restart trong cùng pod. Không xoá thì file của
  process đã chết bị cộng vào, và PID trong container bắt đầu lại từ đầu nên file cũ có thể trùng PID mới.
- **`child_exit`:** gọi `mark_process_dead`, chỉ xoá file của gauge ở chế độ `live*` của worker đã thoát. App hiện không
  có gauge `live*` (`rag_index_info` dùng `max`), nên đây là phòng xa; counter và histogram của worker chết được giữ có
  chủ đích để tổng không bị giảm.

**B2.8** Trong **cookie session của Flask**, giữ tối đa 20 tin. Cookie được ký bằng `FLASK_SECRET_KEY` nên không sửa được,
nhưng chỉ là base64, ai có cookie cũng đọc được, và app chạy HTTP nên nó đi qua mạng dạng rõ. Mọi worker và pod cùng
môi trường dùng chung key nên pod nào cũng đọc được cookie.

**Dev và prod:** mỗi môi trường một host, và cookie gắn theo host, nên hai cookie `session` không đụng nhau.
`FLASK_SECRET_KEY` lấy từ `medical-rag/app-<env>` qua ExternalSecret; key của prod đã được thay riêng ở bước 20 của guide
App, trước khi prod tồn tại (`App A6.5`).

**Giới hạn 4 KB:** trình duyệt bỏ cookie lớn hơn khoảng 4 KB, và 20 tin có thể vượt; server chỉ ghi một warning.

**B2.9** Filter `nl2br` **escape trước** rồi mới nối các dòng bằng `<br>` và trả về `Markup`, nên mọi ký tự HTML trong câu
hỏi hay câu trả lời thành chữ thường. Đã thử `<img src=x onerror=alert(1)>`: trang hiện chuỗi đã escape.

*Ở đâu:* `src/app/application.py`; `docs/evidence/local.md`.

**B2.10** Phải có PDF mới tính được version (B2.1). Image cố ý không chứa thư mục `data/`, còn code build đọc PDF từ
`DATA_PATH` trên đĩa, không tải từ S3. Vì vậy phải có một bước đưa PDF vào Job (ví dụ initContainer tải từ bucket), và
Jenkins cũng cần PDF để biết version có đổi không trước khi ghi `index.version`. `[điền: cơ chế thật]`.

### B3. Container và manifest

**B3.1** Stage `builder` dùng image `uv` cài dependency theo `uv.lock` vào `.venv`; stage `test` chạy ruff và pytest;
stage runtime là `python:3.12-slim-bookworm`, chỉ chép `.venv`, `src`, `gunicorn.conf.py` và `start.sh`.

- **User:** UID/GID 10001 tên `app`, không có home, shell `nologin`.
- **Không có trong image:** công cụ build, dependency dev, test, thư mục `data/`, `.git`, `docs/`, `Jenkinsfile`.
- **Kết quả:** 926 MB → 483 MB.

**B3.2** Mọi chỗ ghi đều dưới `/tmp`, là `emptyDir`:

| Biến / cài đặt | Giá trị | Dùng cho |
|---|---|---|
| `INDEX_DIR` | `/tmp/index` | Index do initContainer tải về |
| `PROMETHEUS_MULTIPROC_DIR` | `/tmp/prometheus` | File metric của các worker |
| `HF_HOME` | `/tmp/hf` | Cache của thư viện Hugging Face |
| `worker_tmp_dir` (gunicorn) | `/tmp` | File heartbeat của worker |

Thêm hai cài đặt để không cần ghi ở chỗ khác: `PYTHONDONTWRITEBYTECODE=1` nên Python không tạo `__pycache__`, và
`control_socket_disable = True` vì gunicorn ≥ 25.1 mở socket quản lý trong `$HOME`, mà user không có home.

Container chạy non-root, `readOnlyRootFilesystem: true`, drop mọi capability, `seccompProfile: RuntimeDefault`.

**B3.3** `kubectl drain` tôn trọng PodDisruptionBudget: với 1 replica và `minAvailable: 1`, không pod nào được phép bị
evict, nên drain **treo vô hạn** và `upgrade.yml` dừng ở node đang chạy pod dev. Thiết kế chỉ đặt PDB cho prod; chart nên
chỉ render PDB khi số replica lớn hơn 1: `gt (int .Values.replicas) 1` trong `pdb.yaml` (`App B1.8`).

**B3.4**

- **Drain** (nâng cấp, thay node) là disruption tự nguyện: PDB `minAvailable: 1` giữ ít nhất một pod prod; rolling update
  với `maxUnavailable: 0` bắt pod mới Ready trước khi pod cũ bị xoá.
- **Node chết đột ngột:** PDB và `maxUnavailable` không liên quan. Pod trên node chết vẫn nằm trong danh sách endpoint
  cho tới khi node bị đánh dấu `NotReady` (khoảng 40–50 giây), và chỉ bị evict sau 300 giây. Trong khoảng đó
  ingress-nginx có thể vẫn gửi tới pod chết, rồi retry sang pod còn sống. Thứ thật sự cứu prod là pod thứ hai nằm ở node
  khác, nhờ `topologySpreadConstraints` theo hostname với `whenUnsatisfiable: DoNotSchedule` (`App A4.3`).

**B3.5** Tuỳ trường hợp. **Version mới hợp lệ** (corpus hoặc thiết lập chunk đã đổi, và version trong values đúng là version
corpus băm ra): Job ở wave 1 build nó, khoảng 149 giây, rồi wave 2 rollout bình thường. **Version gõ sai:** rolling update
không bắt đầu. Job được báo trước version phải build: corpus băm ra version khác nên nó dừng ngay với
`The corpus builds version …, but … was expected`, trước lời gọi embedding nào.

1. Sync lỗi ở wave 1, nên wave 2 (Deployment) không được apply; pod cũ vẫn chạy và phục vụ.
2. Argo CD tự retry sync 5 lần, trong lúc đó `root` hiện `Progressing`.
3. Sau đó sync `Failed`, và `root` chuyển `Degraded` với message của lần sync (luật `report-failed-sync`).
4. Sửa bằng cách revert dòng `index.version`. Nếu app trở về `Synced` mà sync cuối vẫn `Failed`, chạy một lần sync tay.

Đã test có chủ đích trên cluster: pod cũ vẫn `1/1 Running`, 0 restart (`App A7.1`, `A7.2`, `A7.5`). Trường hợp initContainer
không tìm thấy version, kẹt ở `Init:CrashLoopBackOff`, chỉ còn xảy ra nếu version bị xoá khỏi S3 sau khi Job đã thấy nó.

**B3.6** Role Ansible `ecr_credential_provider` cài binary `ecr-credential-provider` v1.37.0 (kiểm tra SHA256), ghi
file cấu hình khớp các image `*.dkr.ecr.*.amazonaws.com` với thời gian cache mặc định 12 giờ, và thêm hai cờ
`--image-credential-provider-*` vào `/etc/default/kubelet`. Khi cần pull image ECR, kubelet gọi plugin; plugin dùng
instance profile của node để lấy token ECR.

### B4. Kyverno, Rancher và chính sách từng môi trường

Câu về `Jenkinsfile`, cổng chặn Trivy, cosign và skip guard nằm ở
[Jenkins](../jenkins/answers.md) phần B.

**B4.1**

| | dev | prod |
|---|---|---|
| Argo CD | Tự sync, `prune` và `selfHeal` | Tự sync; values chỉ đổi qua PR |
| Kyverno | `Audit`, `failurePolicy: Ignore` | `Deny`, `failurePolicy: Fail` |

Hai `ImageValidatingPolicy`, mỗi môi trường một cái, vì `validationActions` đặt theo policy; chúng chỉ khác nhau ở tên,
`namespaceSelector` và `failurePolicy`. Không dùng `ClusterPolicy` với `verifyImages`: cosign v3 lưu chữ ký dưới dạng
OCI referrer, không có tag `.sig`, và đó là trường hợp `ImageValidatingPolicy` kiểm được. `mutateDigest: false`, nên
Kyverno không sửa image và Argo CD không thấy lệch.

**B4.2** Hai glob `*.dkr.ecr.*.amazonaws.com/medical-rag:*` và `…/medical-rag@*`, tức image của app theo tag hoặc theo
digest trần. Không dùng `medical-rag*`, vì glob đó khớp cả `medical-rag-ci`, image tools chưa ký mà pod build và CronJob
etcd chạy.

**Được kiểm tra:** mọi container của pod app ở `medical-rag-dev` và `medical-rag-prod`: container web, initContainer
`index-pull` và Job build index đều chạy cùng một image app.

**Không được kiểm tra chữ ký:** image của mọi addon từ registry công khai (ingress-nginx, Prometheus, Rancher…), và image
app nếu nó chạy ở namespace khác, vì policy chỉ chọn hai namespace đó. Policy Pod Security baseline dưới Kyverno mà
thiết kế đòi thì **chưa làm**: namespace app đã enforce
`restricted` qua nhãn Pod Security, hai namespace Jenkins có nhãn và một `ValidatingAdmissionPolicy`.

**B4.3**

- **Wave `-2`:** External Secrets.
- **Wave `-1`:** hai `ExternalSecret`: `tls-rancher-ingress` và `bootstrap-secret`.
- **Wave `0`:** chart Rancher 2.15.1, lấy mật khẩu qua `extraEnv` từ `bootstrap-secret`.

Theo thiết kế, đặt `bootstrapPassword` làm chart tự render `bootstrap-secret` riêng và một biến
`CATTLE_BOOTSTRAP_PASSWORD` thứ hai, giành nhau với Secret do External Secrets tạo. `[điền: output helm template của
2.15.1 có và không có giá trị này]`.

Để wave giữa các Application thật sự chờ nhau, Argo CD phải bật health check cho chính resource `Application`, và
ExternalSecret cần `SkipDryRunOnMissingResource` vì CRD của nó chưa có lúc dry-run.

### B5. Secret và quyền

**B5.1**

| Secret | Chứa | Ai đọc được |
|---|---|---|
| `medical-rag/llm` | Key Gemini, token Hugging Face | Node (External Secrets) |
| `medical-rag/github` | Token của bot GitHub | Node |
| `medical-rag/rancher` | Mật khẩu bootstrap của Rancher | Node |
| `medical-rag/rancher-tls` | Certificate và private key Sectigo | Node |
| `medical-rag/wireguard` | `serverPrivateKey`, `operatorPublicKey` | Chỉ WireGuard gateway, trong số các máy |

Identity admin, gồm role của workstation, đọc được cả năm.

**Mật khẩu admin Jenkins không nằm trong Secrets Manager.** **External Secrets** sinh nó **trong cluster**,
bằng generator `Password` với `refreshInterval: "0"` — sinh một lần rồi thôi, nên nó không đổi dưới chân
controller đang chạy. Chart chỉ *mount* secret đó (`controller.admin.existingSecret: jenkins-admin`), chứ
không sinh. Nằm ở secret `jenkins-admin` namespace `jenkins`, key `jenkins-admin-password`. Hệ quả cần nói
được: nó **khác sau mỗi lần dựng lại cluster**, và không có bản sao nào ngoài cluster để khôi phục. Đọc bằng:

```bash
kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
```

**Chưa có chỗ trong thiết kế:** `FLASK_SECRET_KEY` của app và mật khẩu admin Grafana `[điền: nằm ở secret nào]`.

**B5.2**

- **AWS**, qua vai trò **riêng** `medical-rag-ci` — token service account đổi lấy, không phải instance role của
  node. Vai trò đó có: `ecr:GetAuthorizationToken` trên `*` (action duy nhất AWS không scope theo repository
  được), tám action push và pull trên **riêng repository `medical-rag`**, `kms:Sign` / `GetPublicKey` /
  `DescribeKey` trên key cosign, và `s3:GetObject` trên `corpus/*`. Hết: không secret nào, không `etcd-backups`,
  không quyền ghi vào bucket artifacts. Image `medical-rag-ci` chứa container `tools` do **kubelet** kéo bằng vai
  trò node, không phải vai trò này.
- **Kubernetes:** RBAC chỉ trong namespace của nó, đủ để tạo pod agent.
- **GitHub:** token fine-grained trong repo này, đủ để push lên `main` và mở PR `[điền: quyền thật của token]`.

**Điểm cần nói rõ:** token push thẳng lên `main` cho dev về kỹ thuật cũng sửa được values của prod. Bắt buộc PR cho
`main` sẽ chặn luôn bot push bản dev, nên phải tách: values prod ở branch hoặc repo cần review, hoặc ruleset giới hạn
đường dẫn bot được push (tuỳ gói GitHub). `[điền: đã cấu hình gì]`.

**B5.3** Theo thiết kế: **external-secrets** (gọi Secrets Manager), **ebs-csi** (gọi EC2 API cho volume) và **Jenkins
agent** (push ECR, ký KMS). initContainer tải index và Job build index dùng role IRSA riêng (`App A2`); CronJob
backup etcd dùng role của node, được cấp đúng bucket `etcd-backups` (`infra/terraform/cluster/iam.tf`).

**NetworkPolicy không chặn được mọi pod khác:**

- Policy chỉ có tác dụng ở namespace có policy; namespace như `argocd`, `cattle-system`, `monitoring` không có policy
  thì vẫn gọi được metadata service, vì hop limit là 2.
- Pod `hostNetwork` không chịu NetworkPolicy.

Chặn thật cần default-deny egress ở mọi namespace hoặc một `GlobalNetworkPolicy` của Calico, cộng Kyverno cấm
`hostNetwork` với pod thường.

**B5.4** Snapshot etcd chứa **toàn bộ** trạng thái cluster, gồm mọi Kubernetes Secret. kubeadm không bật mã hoá Secret
at-rest mặc định, nên key Gemini, token GitHub và private key Sectigo nằm trong snapshot dạng đọc được.

**Ai đọc được:** role của node có `s3:GetObject`, `PutObject` và `DeleteObject` trên bucket `etcd-backups` (CronJob
snapshot cần quyền ghi), nên mọi pod lấy được credential của node đều tải được snapshot, và **xoá được** nó: bucket
không bật versioning. Cách sửa: `EncryptionConfiguration` cho API server; mã hoá bucket backup bằng KMS key riêng mà
role của node không decrypt được; một role IRSA riêng cho CronJob chỉ có `PutObject`; và versioning hoặc Object Lock
để một pod không xoá được backup.

*Ở đâu:* `infra/terraform/cluster/iam.tf`.

### B6. Vận hành

**B6.1**

- **`make up`:** `make infra` → `make cluster` (ghi kubeconfig) → `make bootstrap` (cài Argo CD, apply
  `deploy/argocd/root.yaml`); Argo CD cài phần còn lại. Điều kiện trước: DNS đã delegate, certificate và secret
  WireGuard đã có.
- **`make down`:** xoá các Application của Argo CD → `make infra-destroy`; stack shared và bootstrap giữ nguyên.

**Volume có bị bỏ lại không:** PVC là EBS volume do CSI driver tạo, nằm ngoài state Terraform.

- Xoá Application có finalizer `resources-finalizer.argocd.argoproj.io` thì PVC do chart tạo trực tiếp (Jenkins) bị xoá
  và driver xoá volume.
- PVC sinh từ `volumeClaimTemplates` của StatefulSet (Prometheus) không nằm trong resource Argo CD theo dõi, nên phải
  xoá riêng.
- ebs-csi phải còn chạy tới khi mọi PV đã xoá.

`[điền: make down xử lý thế nào; bằng chứng describe-volumes không còn volume available]`.

**B6.2**

- **Ở đâu:** trên node control plane, nhờ `nodeSelector` và `toleration`.
- **Nói chuyện với etcd:** `hostNetwork: true` để gọi `127.0.0.1:2379`, và ba file `hostPath` chỉ đọc: `ca.crt`,
  `healthcheck-client.crt`, `healthcheck-client.key`. Không mount cả thư mục, vì nó chứa `ca.key` của etcd.
- **Ba container theo thứ tự:** `etcdctl snapshot save`, rồi `etcdutl snapshot status` (image etcd là distroless nên
  phải tách hai initContainer), rồi upload bằng image tools có AWS CLI.
- **Bao lâu:** 6 giờ một lần. Lần chạy đầu được chứng minh dưới một lịch tạm 15 phút, đặt qua Git rồi trả lại, vì chờ
  06:00 thì chậm; job vẫn do scheduler tạo ra, không phải bằng tay. Lần đó: revision 134191, 2434 key, 62 MB, 8 giây.
- **Giữ:** bucket `etcd-backups` có lifecycle 14 ngày, và đã được **chuyển sang stack `shared`**, không có
  `force_destroy`. Trước đó nó nằm trong stack cluster, nên mỗi lần `make down` là mất sạch backup.

**Khôi phục cần thêm gì:** `/etc/kubernetes/pki` (CA, key của service account) không được backup. Mất cluster thì các
certificate này mất theo, nên snapshot chỉ dùng được trên cluster còn giữ PKI cũ.

**B6.3**

1. Chart Rancher ứng viên phải chấp nhận minor đích (`kubeVersion`); 2.15.1 khai báo `< 1.37.0-0`.
2. Minor đích nằm trong support matrix chính thức của bản Rancher ứng viên.
3. Kiểm tra cả các addon khác (B6.6).
4. Nâng Rancher trước; chờ mọi Application `Synced` và `Healthy`.
5. Đổi pin **và repository** package: pkgs.k8s.io tách repository theo minor, nên phải đổi cả `kubernetes_minor`, không
   chỉ số phiên bản.
6. Chạy `upgrade.yml` với `serial: 1`, trong lúc một vòng `curl` đếm request lỗi.

Một bước không đạt thì giữ `1.36.4`. Tới 22/09 bước 6 chưa chạy: không có bản 1.36 nào mới hơn 1.36.4.

**B6.4** Cảnh báo dùng `node_cpu_seconds_total`, ví dụ
`1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.8` kéo dài 15 phút, vì `m7i-flex` không có
metric CPU credit như dòng T.

**Vì sao 80% chưa đủ:** baseline của `m7i-flex.large` khoảng 40% của 2 vCPU. Máy có thể bị giới hạn từ lâu trước khi chạm
80%. Nên cảnh báo theo mức dùng kéo dài trên baseline, và theo dõi thêm `mode="steal"`. `[điền: ngưỡng thật và
receiver]`.

Prometheus giữ dữ liệu 24 giờ, chủ yếu để nhẹ đĩa và thời gian compaction; Grafana chỉ vào qua port-forward.

**B6.5**

- Resource request cho mọi addon, để scheduler không nhồi quá tải một node.
- Prometheus giữ dữ liệu 24 giờ.
- Tối đa một build Jenkins cùng lúc; agent là pod tạm.
- Rancher 1 replica thay vì 3.
- App dev 1 replica, prod 2.

**Còn thiếu:** request không giới hạn mức dùng thật, nên cần memory limit cho addon, và `systemReserved`,
`kubeReserved`, ngưỡng eviction trên node để pod không lấy hết bộ nhớ của etcd và kubelet. `[điền]`.

**B6.6** Mỗi addon hỗ trợ một dải phiên bản Kubernetes riêng: Calico, ingress-nginx, Kyverno, kube-prometheus-stack,
ecr-credential-provider, EBS CSI driver. Nâng minor mà chỉ xét Rancher thì một addon khác có thể hỏng sau khi control
plane đã nâng, và không có đường lùi dễ dàng. Cổng kiểm tra nên đi qua ma trận của từng addon, và theo dõi tình trạng bảo
trì của chúng: một addon ngừng được bảo trì cần kế hoạch thay thế trước lần nâng tiếp theo `[điền: tình trạng hiện tại
của ingress-nginx]`.
