# Đáp án tổng quan về project

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Mỗi câu mở đầu bằng **Ý chính**, là phần nói trước và
thường là đủ. Phần *Nếu được hỏi thêm* chỉ dùng khi người phỏng vấn muốn đi sâu. Dòng **Mẹo** là lời nhắc cho bạn,
không đọc ra khi phỏng vấn.

Đáp án mô tả **dự án khi đã hoàn thành** theo [thiết kế](../selfmanaged-k8s-ops-design.md), vì CV được nộp lúc đó.

## Trước khi dùng: điền số liệu thật

Con số nào chưa đo được viết dưới dạng `[điền: …]`. Không nói một con số chưa đo: khi xong mỗi phase, lấy số từ
`docs/evidence/` và điền vào đây. Nếu kết quả thật khác thiết kế, sửa câu trả lời cho khớp.

| Chỗ cần điền | Lấy từ | Dùng ở |
|---|---|---|
| Thời gian `make cluster` trên node mới, kết quả chạy lần hai | `evidence/ansible.md` | 1.1, 4.2, 7.4 |
| Thời gian `make up` từ đầu tới app chạy | Evidence phase GitOps | 1.1, 4.2 |
| Thời gian build index trên cluster, lần sync thứ hai có bỏ qua không | Log của Job | 3.2, 7.4 |
| Thời gian pod app Ready trên cluster | Evidence phase app | 3.1, 7.4 |
| Thời gian từ commit tới dev chạy bản mới | Evidence pipeline | 5.1, 7.4 |
| Số lỗ hổng CRITICAL / HIGH trước và sau khi làm gọn image | Báo cáo Trivy | 6.2, 7.4 |
| Lỗi Kyverno khi deploy image chưa ký lên prod | Evidence Kyverno | 6.2 |
| RTO khi khôi phục etcd | Evidence restore drill | 7.2 |
| Số request lỗi trong lúc nâng cấp Kubernetes, phiên bản đích | Evidence upgrade drill | 7.3 |

**Cũng cần xác nhận khi xong dự án**, vì các ý này nằm ngoài thiết kế ban đầu:

- Script boot chờ credential cho SSM agent (9.1 chuyện 3) đã được thêm chưa.
- Các alert rule ở 7.5 đã được cấu hình chưa.
- App đã chạy được dưới đường dẫn `/dev` chưa (2.6).

---

## 1. Giới thiệu

**1.1** **Ý chính:** "Đây là chatbot hỏi đáp y khoa dùng RAG. Phần AI tôi giữ đơn giản; trọng tâm là phần vận
hành, làm theo cách một công ty tự chạy Kubernetes."

Nếu có thêm thời gian, kể theo ba lớp:

- **Hạ tầng:** Terraform dựng mọi thứ trên AWS, chia ba stack theo vòng đời. Phần hạ tầng của cluster xoá trong 1
  phút 27 giây, dựng lại từ đầu trong 3 phút 19 giây, và plan sau đó không còn thay đổi.
- **Cluster:** Ansible biến ba máy EC2 thành cluster kubeadm có ba control plane ở ba AZ, không dùng SSH, trong
  `[điền: thời gian make cluster]`.
- **Deploy:** Jenkins test, build, quét và ký image; Argo CD sync từ Git vào cluster; dev tự cập nhật, prod chỉ đổi
  qua pull request có review; Kyverno chặn image chưa ký trên prod.

**1.2** **Ý chính:** người dùng hỏi một câu về y khoa; app tìm các đoạn liên quan trong tài liệu rồi để Gemini trả
lời ngắn gọn **chỉ dựa trên các đoạn đó**. Tài liệu không có thì trả lời "không biết".

Tài liệu là một tập của bộ bách khoa y khoa Gale (tập 2, các mục C–F, 759 trang). Câu hỏi ngoài phạm vi đó thì app
trả lời "không biết".

Bên trong có hai giai đoạn:

1. **Chuẩn bị, làm một lần:** cắt PDF thành 7.079 chunk (đoạn văn ngắn), biến mỗi chunk thành vector (một dãy số
   thể hiện ý nghĩa, để so độ giống nhau) qua Hugging Face API, rồi lưu vào FAISS index.
2. **Trả lời, mỗi câu hỏi:** biến câu hỏi thành vector cũng qua Hugging Face, tìm 3 chunk gần nghĩa nhất trong
   FAISS, rồi gửi câu hỏi kèm 3 chunk đó cho Gemini với chỉ dẫn "chỉ dùng thông tin trong ngữ cảnh".

Cách này gọi là RAG (Retrieval Augmented Generation): model không cần "nhớ" kiến thức y khoa, nên câu trả lời bám
vào tài liệu và ít bịa hơn.

**1.3** **Ý chính:** phần vận hành. Việc của tôi là đưa một app chạy trên máy cá nhân thành một hệ thống deploy,
vận hành và kiểm chứng được.

- Sửa app để chạy được trong môi trường thật: server production, health check, metrics, index có version, retry,
  test.
- Thiết kế và dựng hạ tầng AWS bằng Terraform, cluster Kubernetes bằng Ansible.
- Dựng CI/CD theo GitOps với Jenkins và Argo CD.
- Bảo mật image: quét, SBOM, ký bằng KMS, Kyverno kiểm tra chữ ký.
- Vận hành ngày 2: backup và khôi phục etcd, nâng cấp Kubernetes từng node.
- Đo và ghi lại bằng chứng cho từng bước.

**1.4** **Ý chính:** tôi hướng tới vị trí DevOps / Platform / SRE, nên muốn một project chứng minh bốn năng lực
bằng số liệu thật, không chỉ bằng lời:

1. **Hạ tầng tái tạo được:** xoá đi dựng lại mà không cần thao tác tay.
2. **GitOps:** Git quyết định cái gì đang chạy; prod chỉ đổi qua review.
3. **Bảo mật image:** quét lỗ hổng, SBOM, ký bằng KMS, chặn image chưa ký.
4. **Vận hành ngày 2:** backup/khôi phục etcd, nâng cấp cluster.

Tôi có một project thứ hai chạy trên EKS. Hai project cố ý chia vai: project này tự vận hành control plane, project
kia dùng dịch vụ managed và tập trung vào autoscaling, canary và observability.

**1.5** **Ý chính:** năm phase, mỗi phase xây trên phase trước và chỉ tính là xong khi có bằng chứng.

1. **App:** sửa để vận hành được, kiểm chứng bằng Docker ở local.
2. **Terraform:** hạ tầng AWS.
3. **Ansible:** cluster Kubernetes HA.
4. **GitOps và CI:** Argo CD, addon, Helm chart, Jenkins pipeline, dev và prod.
5. **Vận hành ngày 2:** Kyverno, backup/khôi phục etcd, nâng cấp Kubernetes.

Thứ tự này đi từ dưới lên: không có hạ tầng thì không có cluster, không có cluster thì không có gì để deploy.

**1.6** **Ý chính:** tôi làm một mình, trong khoảng `[điền: thời gian thực tế]`, song song với project EKS.

> **Mẹo:** làm một mình giải thích vì sao một số lựa chọn đơn giản hơn công ty (xem 8.2).

**1.7** **Ý chính:** "Không. Phần RAG ban đầu dựa trên một ví dụ mã nguồn mở, README có ghi nguồn. Phần của tôi là
viết lại để app vận hành được, cùng toàn bộ hạ tầng, cluster, CI/CD và vận hành."

*Nếu được hỏi thêm*, những gì tôi đã làm trên app:

- thay server development bằng gunicorn
- tách `/healthz` và `/readyz`, thêm metrics Prometheus
- biến index thành artifact có version, build một lần
- embedding chia lô có retry, xử lý lỗi Gemini thành trang 502
- Docker image nhiều stage, chạy non-root, filesystem chỉ đọc
- unit test chạy ngay trong bước build

---

## 2. Kiến trúc tổng thể

**2.1** **Ý chính:** "Người dùng vào qua load balancer công khai. Người vận hành vào qua VPN và Session Manager.
Code đi từ GitHub qua Jenkins lên ECR, còn Argo CD kéo từ Git vào cluster. Tất cả chạy trên ba node Kubernetes
trong một VPC ba AZ."

*Nếu được hỏi thêm*, vẽ ba luồng:

```
# Luồng người dùng
Người dùng ──HTTP 80──> Public NLB ──> ingress-nginx ──> app dev (/dev) hoặc prod (/)
                                                          ├─> Hugging Face API (vector câu hỏi)
                                                          ├─> Gemini API (sinh câu trả lời)
                                                          └─> S3 (tải FAISS index theo version)

# Luồng vận hành
Người vận hành ──WireGuard──> WireGuard gateway ──> Internal NLB :443 ──> ingress-nginx ──> Rancher
Người vận hành ──SSM──────> node (Ansible; kubectl qua tunnel tới Internal NLB :6443)

# Luồng CI/CD
GitHub ──> Jenkins (test, build, quét, ký) ──> ECR
Jenkins ──> ghi version mới vào GitHub ──> Argo CD kéo từ Git ──> cluster
```

- **AWS:** xem 4.1.
- **Cluster:** ba node đều là control plane và đều chạy workload.
- **Trong cluster:** Argo CD, ingress-nginx, External Secrets, EBS CSI driver, Prometheus/Grafana, Jenkins,
  Rancher, Kyverno, app ở dev và prod.

**2.2** **Ý chính:** trình duyệt → public NLB → ingress-nginx → pod của app → tìm trong FAISS → gọi Gemini → trả về
trang HTML.

1. Trình duyệt gọi DNS name của public NLB, cổng 80.
2. ingress-nginx xem đường dẫn: `/dev` sang app dev, còn lại sang prod.
3. gunicorn trong pod nhận request. Index đã được load sẵn lúc khởi động, không load lại mỗi request.
4. App biến câu hỏi thành vector, tìm 3 chunk gần nhất, gọi Gemini (chi tiết ở 1.2).
5. Thời gian tìm kiếm và thời gian gọi LLM được đo riêng thành metric.

Hạn chế đã biết: app đi qua HTTP thường vì không có domain cho app; điều này được ghi là ngoài phạm vi.

**2.3** **Ý chính:** mỗi công cụ lo đúng một lớp, không đụng sang lớp khác.

| Công cụ | Lo phần | Không làm |
|---|---|---|
| Terraform | Tài nguyên AWS: mạng, máy, load balancer, IAM, bucket, DNS | Không cài gì lên máy |
| Ansible | Cấu hình bên trong máy và chạy `kubeadm` để dựng cluster | Không tạo tài nguyên AWS, không cài addon |
| Argo CD | Mọi thứ chạy trong cluster, sync từ Git | Không build image |
| Jenkins | Test, build, quét, ký image, rồi ghi version mới vào Git | Không có quyền deploy vào cluster |

**Vì sao chia rõ:**

- **Biết ngay sửa ở đâu:** lỗi ở lớp nào thì tìm ở công cụ của lớp đó.
- **Dựng lại độc lập:** xoá cluster không đụng tới image, index hay secret.
- **Giới hạn thiệt hại:** Jenkins không có RBAC để deploy, nên lộ Jenkins không cho kẻ tấn công `kubectl` vào
  prod. Nhưng agent của Jenkins vẫn dùng chung quyền IAM của node (xem 6.4), và nó sửa được dev qua Git; đó là
  giới hạn đã ghi lại.

**2.4** **Ý chính:** mục tiêu là tự vận hành control plane: etcd HA, backup, certificate, nâng cấp. EKS làm hộ đúng
những việc đó, nên dùng EKS thì không chứng minh được. Project thứ hai của tôi dùng EKS.

- **Được:** hiểu và chứng minh cách Kubernetes vận hành từ bên trong; không mất phí control plane của EKS (0.10
  USD/giờ).
- **Mất:**
  - không có nâng cấp tự động và SLA của AWS
  - không có IRSA (cơ chế cấp quyền IAM riêng cho từng pod), nên mọi pod dùng chung quyền của node
  - không có controller tự tạo load balancer, nên NLB phải tạo sẵn bằng Terraform
  - nhiều việc bảo trì hơn
- **Ở công ty:** tôi chọn EKS làm mặc định, trừ khi có lý do cụ thể như cần giống môi trường on-premise.

**2.5** **Ý chính:** chỉ để phục vụ lưu lượng của app thì không cần. Nhưng project chạy cùng lúc nhiều thành phần,
và Kubernetes cho chúng một cách chung để deploy, kiểm tra sức khoẻ, tự restart, cô lập mạng và quản lý secret.

Những thứ chạy cùng nhau: app ở hai môi trường, job build index, Jenkins với agent tạm thời, Argo CD,
Prometheus/Grafana, Rancher, Kyverno.

Nếu chỉ có một app nhỏ ở công ty, tôi sẽ dùng thứ đơn giản hơn như ECS, hoặc một máy chạy container.

> **Mẹo:** thừa nhận điều này trước khi bị hỏi vặn. Biện minh rằng app nhỏ cần Kubernetes sẽ làm mất điểm.

**2.6** **Ý chính:** cùng một Helm chart, hai file values, hai Argo CD Application, hai namespace.

| | dev | prod |
|---|---|---|
| Values | `deploy/envs/dev/values.yaml` | `deploy/envs/prod/values.yaml` |
| Replica | 1 | 2, trải trên các node khác nhau, có PodDisruptionBudget |
| Đường dẫn | `/dev` | `/` |
| Cách đổi version | Jenkins commit thẳng | Pull request, người duyệt merge |
| Kyverno | Chỉ ghi log (Audit) | Chặn image chưa ký (Enforce) |

Không có domain cho app, nên hai môi trường chia nhau một NLB theo đường dẫn, và app chạy được dưới đường dẫn
`/dev`.

---

## 3. Ứng dụng và dữ liệu

**3.1** **Ý chính:** app chạy được nhưng không vận hành được.

1. **Dựng lại toàn bộ index mỗi lần khởi động:** chậm nhiều phút, tốn quota Hugging Face, và liveness probe có thể
   giết pod giữa chừng. Sau khi sửa, container khoẻ sau khoảng 6 giây ở local và pod Ready sau `[điền: thời gian
   trên cluster]`.
2. **Chạy bằng server development của Flask,** không có health check thật, và mỗi request lại load lại FAISS.
3. **CI deploy bằng kubeconfig admin,** không quét, không ký image.

**3.2** **Ý chính:** index là một artifact có version: build một lần, lưu trên S3, pod tải đúng version ghi trong
Git. Muốn quay về index cũ thì sửa một dòng trong Git.

- **Version là mã băm của nội dung:** SHA-256 của file PDF, kích thước chunk, overlap và tên model embedding, lấy
  12 ký tự đầu. Cùng đầu vào luôn ra cùng version; build trong container và trên máy Windows đều ra `cc759ae1a093`.
- **Không build lại khi không cần:** job build kiểm tra version đó đã có trên S3 chưa; có rồi thì bỏ qua. Lần đầu
  mất 150.7 giây cho 7.079 chunk; lần sau dưới 1 giây.
- **Chống lỗi khi build:** embedding gửi theo lô; lỗi tạm thời (408, 429, 5xx, mất kết nối) thì thử lại với thời
  gian chờ tăng dần.
- **Trên Kubernetes:** Argo CD chạy job build index *trước* khi cập nhật app (PreSync hook). Version được ghi trong
  `values.yaml` của từng môi trường, một initContainer tải đúng version đó.
- **Rollback:** đổi `index.version` về giá trị cũ trong Git, Argo CD sync lại.

**3.3** **Ý chính:** `/healthz` trả lời "process còn sống không", `/readyz` trả lời "đã sẵn sàng phục vụ chưa". Gộp
làm một thì Kubernetes sẽ restart một pod chỉ đang chờ, hoặc gửi request tới pod chưa sẵn sàng.

- **`/healthz`:** không kiểm tra gì bên ngoài. Dùng cho liveness probe: fail thì Kubernetes restart container.
- **`/readyz`:** chỉ trả 200 khi index đã load và chain đã dựng xong; trước đó trả 503 kèm lỗi gần nhất. Dùng cho
  readiness probe (có nhận traffic không) và startup probe (cho tối đa 5 phút để khởi động).
- **Ví dụ, có unit test:** Hugging Face tạm lỗi lúc khởi động. App thử lại trong nền; `/readyz` trả 503 nên không
  nhận request, còn `/healthz` vẫn 200 nên pod không bị giết vô ích.

*Nếu được hỏi thêm:*

- **Mỗi worker gunicorn tự dựng chain,** nên `/readyz` phản ánh worker nhận probe. Mỗi worker xong trong khoảng 0.7
  giây nên khoảng lệch rất nhỏ.
- **Lỗi vĩnh viễn** như token sai: startup probe restart pod sau 5 phút. Đó là đúng ý, vì lỗi cấu hình phải lộ ra
  thành CrashLoop thay vì âm thầm chờ mãi.

**3.4** **Ý chính:** lỗi tạm thời thì thử lại có giới hạn; hết lượt thì trả lỗi rõ ràng, và không phá bản đang chạy
tốt. Điểm yếu còn lại: mỗi câu hỏi đều cần Hugging Face.

| Tình huống | Cách xử lý |
|---|---|
| Hugging Face lỗi khi build index | Thử lại theo lô, chờ tăng dần, tối đa 6 lần; hết lượt thì job fail, Argo CD sync fail, và **bản app cũ vẫn chạy với index cũ** |
| API lỗi lúc app khởi động | Thử lại trong nền; `/readyz` trả 503 tới khi xong |
| Gemini lỗi khi đang trả lời | Client thử lại 1 lần, timeout 30 giây; hết lượt thì trả trang lỗi 502, worker không sập; lỗi được đếm trong metric |
| Hugging Face lỗi khi đang trả lời | Embedding câu hỏi thử lại tới 6 lần; hết lượt thì trả 502 |
| Version index chưa có trên S3 | initContainer fail, pod mới không Ready, rolling update dừng lại và pod cũ vẫn phục vụ |

**Điểm yếu đã biết:** Hugging Face là phụ thuộc đơn. Nó sập thì app không trả lời được câu nào, và với 6 lần thử,
người dùng phải chờ khoảng nửa phút mới thấy lỗi. Cách sửa: embed câu hỏi bằng model nhỏ chạy ngay trong pod, hoặc
giảm số lần thử khi đang phục vụ request.

**3.5** **Ý chính:** image nhỏ đi gần một nửa, chạy bằng user thường với filesystem chỉ đọc, và test chạy ngay trong
bước build.

- **Kích thước:** 926 MB → 483 MB (giảm 48%), nhờ build nhiều stage: công cụ build ở stage riêng, không mang theo
  PDF hay `.git`.
- **Bảo mật:** chạy bằng UID 10001, root filesystem chỉ đọc (thử `touch` nhận `Read-only file system`), chỉ `/tmp`
  được ghi.
- **Server:** gunicorn 2 worker, mỗi worker 4 thread, thay server development của Flask.
- **Test:** ruff và 22 unit test chạy trong stage `test` của Dockerfile, và chạy lại trong pipeline Jenkins.
- **Phụ thuộc:** pin version bằng `uv.lock`, không kéo PyTorch vì embedding gọi qua API.

**3.6** **Ý chính:** kiến thức nằm sẵn trong tài liệu, nên chỉ cần tìm đúng đoạn và đưa cho model, không cần dạy lại
model.

- **Cập nhật dễ:** đổi tài liệu thì build lại index trong vài phút, không phải train lại.
- **Kiểm soát được nguồn:** câu trả lời bám vào đoạn văn tìm được, và app nói "không biết" khi tài liệu không có.
- **Chi phí gần như bằng không:** không cần GPU, không cần dữ liệu huấn luyện.

Fine-tune hợp hơn khi cần đổi *cách* model trả lời (giọng văn, định dạng), không phải khi cần thêm *kiến thức*.

**3.7** **Ý chính:** không có bộ đánh giá tự động; project tập trung vào vận hành. Chất lượng được kiểm tra thủ công
bằng câu hỏi trong phạm vi tài liệu (ví dụ triệu chứng tiểu đường, nguyên nhân đục thuỷ tinh thể) và ngoài phạm vi
(phải trả lời "không biết").

**Nếu làm tiếp:**

1. Dựng một bộ câu hỏi có đáp án chuẩn.
2. Đo retrieval: 3 chunk tìm được có chứa đoạn đúng không.
3. Đo câu trả lời: có bám vào ngữ cảnh không, có bịa không.
4. Chạy bộ này trong CI mỗi khi đổi kích thước chunk, số chunk hay model, để thay đổi làm tệ đi thì bị chặn.

> **Mẹo:** trả lời thật là không có. Hứa hẹn một bộ đánh giá không tồn tại rất dễ bị hỏi vặn.

**3.8** **Ý chính:** có. Câu hỏi được gửi ra ngoài cho Hugging Face và Google, và app đi qua HTTP thường. Với tài
liệu bách khoa công khai và câu hỏi thử nghiệm thì chấp nhận được; với dữ liệu bệnh nhân thật thì không.

- **Gửi ra ngoài:** câu hỏi đi tới Hugging Face (tạo vector) và Gemini (sinh câu trả lời).
- **Lưu trữ:** app không có database và không ghi câu hỏi vào log. Lịch sử chat nằm trong cookie session: cookie
  được ký nên không sửa được, nhưng không mã hoá.
- **Truyền tải:** HTTP thường, không có HTTPS.

**Với dữ liệu thật cần:** HTTPS; thoả thuận xử lý dữ liệu với nhà cung cấp, hoặc model tự host; không giữ lịch sử
trong cookie; ghi rõ cho người dùng biết dữ liệu đi đâu.

---

## 4. Hạ tầng và cluster

Phần này có bộ câu hỏi chi tiết riêng: [`../terraform/questions.md`](../terraform/questions.md).

**4.1** **Ý chính:** một VPC ba AZ, ba node Kubernetes ở subnet private, hai load balancer, và các dịch vụ dùng
chung, tất cả dựng bằng Terraform.

- **Mạng:** VPC `10.10.0.0/16`, subnet public và private ở ba AZ, một NAT gateway, S3 gateway endpoint.
- **Máy:** ba node `m7i-flex.large` (2 vCPU, 8 GB), không public IP, không key SSH; một WireGuard gateway nhỏ; một
  ops workstation để chạy mọi lệnh.
- **Load balancer:** public NLB cổng 80 cho app; internal NLB cổng 6443 cho Kubernetes API và 443 cho Rancher.
- **Dịch vụ dùng chung:** ECR chứa image, S3 chứa index, Terraform state và snapshot etcd, KMS key để ký image,
  Secrets Manager chứa secret, Route 53 cho domain, và budget cảnh báo chi phí.

**4.2** **Ý chính:** cluster tốn khoảng 0.53 USD mỗi giờ, nên chỉ chạy khi cần. Xoá được vì mọi thứ cần giữ nằm ở
chỗ khác; dựng lại nhanh vì mọi thứ là code.

- **Chia theo vòng đời:** ba stack Terraform. `bootstrap` (bucket state, workstation) và `shared` (image, index, KMS
  key, secret, DNS) được giữ; `cluster` (mạng, node, load balancer) xoá khi không dùng.
- **Đã đo:** phần hạ tầng AWS của cluster xoá mất 1 phút 27 giây, dựng lại từ đầu mất 3 phút 19 giây, không có bước
  thủ công, và `terraform plan` sau đó không còn thay đổi.
- **Cả chuỗi:** `make up` chạy Terraform, Ansible rồi cài Argo CD, và Argo CD tự cài phần còn lại; tổng cộng
  `[điền: thời gian make up]`. `make down` xoá các ứng dụng của Argo CD trước (để giải phóng volume), rồi xoá stack
  cluster.

**4.3** **Ý chính:** qua AWS Systems Manager Session Manager (SSM). Không máy nào mở cổng SSH, không có key pair,
không có bastion.

- **Vào máy:** mở session trong trình duyệt hoặc bằng `aws ssm start-session`. IAM quyết định ai được vào.
- **Ansible:** dùng connection plugin `aws_ssm` thay cho SSH.
- **kubectl:** Kubernetes API chỉ có trên internal NLB. `make tunnel` mở một SSM port-forward từ workstation, qua
  một node, tới NLB, và kubectl gọi `https://127.0.0.1:6443`. Vì vậy certificate của API server phải thêm
  `127.0.0.1` vào danh sách tên hợp lệ (SAN).

**Đánh đổi:** Ansible qua SSM chậm hơn SSH, và node cần NAT để tới được SSM. Có một sự cố thật với SSM agent, kể ở
9.1.

**4.4** **Ý chính:** ba node ở ba AZ, cả ba đều là control plane có etcd. Mất một node thì etcd vẫn đủ đa số (2/3)
và API vẫn trả lời.

- **etcd** cần đa số member sống để ghi dữ liệu; ba member chịu được mất một.
- **Internal NLB** đứng trước ba API server, kiểm tra `/readyz` và bỏ server hỏng. kubectl, `kubeadm join` và các
  công cụ vận hành gọi API qua NLB; kubelet trên node control plane gọi API server ngay trên node đó; pod gọi qua
  Service `kubernetes`.
- **App prod:** 2 replica trên các node khác nhau, PodDisruptionBudget giữ ít nhất 1.
- **Đã kiểm chứng:** tắt một node, `kubectl get nodes` vẫn trả lời qua NLB.

*Nếu được hỏi thêm:*

- **Chi tiết bài kiểm tra:** tunnel của kubectl đi qua một node, nên phải mở tunnel qua node còn sống, không qua
  node vừa tắt.
- **Điểm yếu đã biết:** chỉ có một NAT gateway, nằm cùng AZ với node 1 và WireGuard gateway. Mất AZ đó thì cả ba
  node mất đường ra internet: app không gọi được Gemini, SSM ngắt, Rancher không vào được. Đây là đánh đổi chi phí
  có ghi lại; cách sửa là mỗi AZ một NAT gateway.

**4.5** **Ý chính:** Rancher là giao diện quản trị toàn quyền cluster, nên chỉ vào được qua VPN WireGuard; cổng 443
chỉ có trên internal NLB.

- **Đường đi:** laptop → WireGuard → gateway → internal NLB → ingress-nginx → Rancher.
- **Đã kiểm chứng:** không có rule 443 public; không bật VPN thì URL timeout; bật VPN thì chuỗi certificate hợp lệ và
  giao diện mở được.

*Nếu được hỏi thêm:*

- `rancher.recruitai.io.vn` trỏ tới IP **private** của NLB: ai tra DNS cũng thấy, nhưng không có VPN thì không tới
  được.
- Gateway chỉ cho qua DNS và HTTPS; cổng 6443 của Kubernetes API bị chặn dù nằm cùng NLB.
- Certificate Sectigo, private key nằm trong Secrets Manager và được External Secrets đưa vào cluster.
- Không dùng AWS Client VPN vì tốn vài chục đô mỗi tháng kể cả khi không dùng; WireGuard chỉ cần một máy nhỏ, xoá
  cùng cluster.

**4.6** **Ý chính:** app không giữ trạng thái nên scale ngang bằng cách thêm replica. Nhưng nghẽn trước tiên là giới
hạn tốc độ của Gemini và Hugging Face, không phải CPU. Project chưa có autoscaling và chưa load test.

- **Sức chứa mỗi pod:** 2 worker × 4 thread = 8 request đồng thời. Phần lớn thời gian là chờ API bên ngoài.
- **Không giữ trạng thái:** index chỉ đọc; lịch sử chat nằm trong cookie, các worker dùng chung secret key nên pod
  nào trả lời cũng được.
- **Tăng gấp 10:**
  1. Quota Gemini và Hugging Face: cần xin tăng, hoặc thêm cache cho câu hỏi lặp lại.
  2. Thêm replica, sau đó thêm node; ba node 8 GB còn phải chạy Jenkins và Prometheus.
  3. Giới hạn tốc độ ở ingress, để quá tải thì trả lỗi nhanh thay vì treo.
- **Còn thiếu:** HorizontalPodAutoscaler và một lần load test để có con số thật.

---

## 5. CI/CD và GitOps

**5.1** **Ý chính:** push code → Jenkins test, build, quét, ký image → Jenkins ghi version mới vào Git → Argo CD thấy
Git đổi và cập nhật dev → Jenkins mở pull request cho prod → người duyệt merge → Argo CD cập nhật prod. Từ commit
tới dev chạy bản mới mất `[điền: số phút]`.

*Nếu được hỏi thêm*, các bước của Jenkins:

1. **Test:** ruff, pytest, hadolint cho Dockerfile.
2. **Build và push:** BuildKit build image, đẩy lên ECR với tag là git SHA.
3. **Quét:** Trivy; có lỗ hổng CRITICAL đã có bản sửa thì dừng pipeline.
4. **SBOM:** Syft liệt kê mọi thành phần trong image.
5. **Ký:** Cosign ký image và SBOM bằng KMS key.
6. **Lên dev:** sửa `deploy/envs/dev/values.yaml` và commit; Argo CD sync.
7. **Lên prod:** mở pull request sửa `deploy/envs/prod/values.yaml`, kèm tóm tắt kết quả quét và digest của image.

**5.2** **Ý chính:** CI tạo ra image đáng tin; CD đưa trạng thái trong Git vào cluster. Tách ra thì Jenkins không cần
quyền vào cluster, và Git là nơi duy nhất quyết định cái gì đang chạy.

| | Push: Jenkins `kubectl apply` | Pull: Argo CD |
|---|---|---|
| Credential cluster | Jenkins phải giữ credential mạnh | Argo CD chạy trong cluster, không ai bên ngoài cần |
| Ai đó sửa tay trên cluster | Không ai biết | Argo CD báo lệch và tự sửa về đúng Git |
| Muốn biết đang chạy gì | Phải hỏi cluster | Đọc Git |
| Jenkins sập | Không deploy được | Thứ đang chạy không bị ảnh hưởng; chỉ tạm dừng bản mới |

**5.3** **Ý chính:** rollback là `git revert` commit đổi version; Argo CD sync về image cũ.

- **Image cũ vẫn còn:** ECR giữ 20 bản gần nhất.
- **Index cũ:** đổi `index.version` về giá trị cũ, cách làm tương tự.
- **Ưu điểm:** mọi lần đổi prod đều có người duyệt, có lịch sử, và quay lại bằng thao tác Git quen thuộc, không cần
  quyền vào cluster.

**5.4** **Ý chính:** tag có thể bị trỏ sang image khác, còn digest là mã băm của chính nội dung image. Ghi digest thì
thứ đã được quét và ký chính xác là thứ đang chạy.

- Values ghi dạng `tag@sha256:...`: tag để người đọc hiểu, digest để máy dùng.
- Chữ ký Cosign gắn với digest, nên Kyverno kiểm tra đúng image sẽ chạy.
- ECR đặt tag immutable: tag đã dùng thì không ghi đè được.

**5.5** **Ý chính:** dùng BuildKit ở chế độ rootless trong một pod agent, không mount Docker socket của node.

- **Không mount Docker socket:** ai điều khiển Docker daemon của node thì gần như có quyền root trên node đó.
- **Không dùng Kaniko:** dự án Kaniko đã bị archive, không còn được phát triển.
- **Agent tạm thời:** mỗi build chạy trong pod riêng, xong thì xoá; cache build lưu trên ECR để build sau vẫn nhanh.

**5.6** **Ý chính:** bước đầu tiên của pipeline kiểm tra commit: tác giả là `jenkins-bot`, hoặc commit chỉ đổi thư
mục `deploy/`, thì dừng ngay mà không build.

Không có bước này: Jenkins commit version mới → Jenkins thấy commit mới → build lại → commit version mới → vòng lặp
vô hạn.

**5.7** **Ý chính:** để thể hiện việc tự vận hành một hệ thống CI trong cluster, đúng tinh thần tự quản lý của
project này. Project EKS dùng GitHub Actions, nên hai project cho thấy cả hai cách.

- **Jenkins được gì:** chạy trong cluster, agent là pod, dùng quyền IAM của node để push ECR và ký bằng KMS mà không
  cần credential dài hạn nào.
- **Jenkins mất gì:** phải tự vận hành, tự nâng cấp plugin; không có webhook công khai nên phải poll Git mỗi 2 phút.
- **Ở công ty:** nếu code nằm trên GitHub và không có yêu cầu đặc biệt, GitHub Actions với OIDC tới AWS đơn giản hơn.

**5.8** **Ý chính:** mỗi công cụ một vai. Argo CD quyết định *cái gì được deploy*; Rancher là giao diện để *xem và
thao tác* với cluster; kubectl là công cụ dòng lệnh.

- **Rancher giúp:** xem nhanh trạng thái node, workload, log, event trên giao diện, hữu ích khi xử lý sự cố hoặc khi
  người khác cần xem mà không quen kubectl.
- **Quy tắc:** thay đổi lâu dài vẫn đi qua Git. Sửa tay trên Rancher sẽ bị Argo CD phát hiện là lệch và sửa về.
- **Cái giá:** Rancher có toàn quyền cluster, nên chỉ vào được qua VPN (xem 4.5), và nó ràng buộc phiên bản
  Kubernetes được phép nâng lên (xem 7.3).

---

## 6. Bảo mật

**6.1** **Ý chính:** secret nằm trong AWS Secrets Manager. External Secrets trong cluster đọc nó và tạo Kubernetes
Secret. Git, Terraform state và image không chứa giá trị secret nào.

1. **Terraform** chỉ tạo secret rỗng: tên và quyền.
2. **Người vận hành** nhập giá trị một lần bằng AWS CLI từ một file tạm, rồi xoá file bằng `shred`.
3. **External Secrets** sync vào Kubernetes Secret; pod dùng như biến môi trường.
4. **Đổi secret:** chỉ cập nhật trên Secrets Manager, External Secrets tự đẩy xuống mà không cần deploy lại.

Key riêng tư cũng được sinh ngay nơi dùng: private key của certificate sinh trên workstation, private key WireGuard
của laptop không rời laptop.

**6.2** **Ý chính:** chuỗi bốn bước: quét → SBOM → ký bằng KMS → kiểm tra chữ ký trước khi pod chạy. Image chưa ký
thì không vào được prod.

- **Quét:** Trivy chặn pipeline khi có lỗ hổng CRITICAL đã có bản sửa. Sau khi làm gọn image: `[điền: số CRITICAL /
  HIGH trước và sau]`.
- **Ký:** Cosign ký digest của image bằng KMS key. Private key không bao giờ rời KMS; Jenkins chỉ được gọi lệnh ký.
- **Kiểm tra:** Kyverno kiểm tra chữ ký bằng public key trước khi cho pod chạy; prod chặn, dev chỉ ghi log.
- **Đã kiểm chứng:** deploy thử một image chưa ký lên prod bị từ chối với lỗi `[điền: thông báo của Kyverno]`.

**6.3** **Ý chính:** chỉ hai cổng mở ra internet: HTTP 80 của app và UDP 51820 của WireGuard. Mọi thứ khác là
private.

- **Không SSH:** vào máy bằng SSM.
- **Private:** node không có public IP; Kubernetes API và Rancher chỉ có trên internal NLB.
- **Least privilege:** policy tự viết chỉ cấp quyền trên đúng tài nguyên cần dùng; riêng hai managed policy của AWS
  trên role của node còn rộng toàn account (xem 6.4).
- **Mã hoá:** ổ EBS mã hoá; bucket S3 chặn truy cập public và chỉ nhận HTTPS.
- **Metadata:** bắt buộc IMDSv2, để lỗi SSRF trong app không lấy trộm được credential của máy.
- **Pod:** chạy non-root, filesystem chỉ đọc; NetworkPolicy mặc định chặn traffic vào namespace của app, chỉ mở cho
  ingress-nginx và monitoring.

**6.4** **Ý chính:** có năm điểm yếu chính, đều đã ghi lại kèm cách sửa.

1. **Mọi pod dùng chung quyền IAM của node.** Nếu một pod bị chiếm, kẻ tấn công có thể ký image và đọc secret; hai
   managed policy còn cho quyền rộng trên cả account. Cách giảm hiện có: NetworkPolicy chặn pod gọi metadata service,
   trừ vài namespace cần dùng. Cách sửa lâu dài: dựng IRSA.
2. **Workstation có `AdministratorAccess`.** Ai mở được session trên nó là admin. Cách sửa: tách role chỉ plan và role
   apply.
3. **App không có HTTPS,** vì không có domain cho app.
4. **Một NAT gateway** là điểm lỗi đơn cho traffic đi ra (xem 4.4).
5. **Internal NLB tin cả dải IP của VPC;** hiện chỉ firewall trên WireGuard gateway chặn laptop gọi tới API. Cách
   sửa: chỉ cho phép security group của node.

> **Mẹo:** kể điểm yếu kèm cách sửa, ngắn gọn, không xin lỗi. Người phỏng vấn tìm người biết giới hạn của hệ thống
> mình dựng.

---

## 7. Vận hành ngày 2 và quan sát

**7.1** **Ý chính:** app xuất metric Prometheus ở `/metrics`, đo riêng thời gian tìm kiếm và thời gian gọi LLM để biết
chậm ở đâu. kube-prometheus-stack thu thập metric của app và cluster, Grafana hiển thị.

- `http_requests_total` theo route và mã trạng thái: tỉ lệ lỗi.
- `http_request_duration_seconds`: độ trễ.
- `rag_retrieval_duration_seconds` và `llm_request_duration_seconds`: chậm do tìm kiếm hay do Gemini.
- `rag_index_info{version}`: pod đang dùng index version nào.

*Nếu được hỏi thêm:*

- gunicorn có 2 worker, mỗi worker giữ bộ đếm riêng. App dùng chế độ multiprocess của thư viện Prometheus để cộng
  dồn; nếu không, mỗi lần scrape chỉ thấy số của một worker ngẫu nhiên.
- Prometheus tự tìm app qua ServiceMonitor, giữ dữ liệu 24 giờ cho nhẹ; Grafana chỉ vào qua port-forward.

**7.2** **Ý chính:** snapshot etcd định kỳ lên S3, và đã diễn tập khôi phục có đo thời gian: RTO là `[điền: RTO]`.

- **Backup:** CronJob trên node control plane, 6 giờ một lần `etcdctl snapshot save`, kiểm tra snapshot hợp lệ rồi
  mới đẩy lên S3.
- **Diễn tập:** xoá một namespace thử, khôi phục snapshot trên cả ba member, xác nhận namespace quay lại, và ghi RTO
  (thời gian từ lúc bắt đầu khôi phục tới khi mọi ứng dụng của Argo CD khoẻ lại).
- **Giới hạn:** snapshot chỉ khôi phục đúng cluster đã tạo ra nó. Khi xoá cả cluster thì dựng lại từ code và Git.

**7.3** **Ý chính:** nâng từng node một: drain → nâng kubeadm, kubelet → đưa node trở lại → chờ mọi thứ khoẻ rồi mới
sang node tiếp. Trong lúc nâng lên `[điền: phiên bản đích]`, số request lỗi là `[điền: số request lỗi]`.

- **Điều kiện trước khi nâng:** chart Rancher có ràng buộc phiên bản Kubernetes (bản 2.15.1 chỉ chấp nhận dưới 1.37).
  Phải nâng Rancher trước và xác nhận chart mới chấp nhận phiên bản đích; không đạt thì giữ phiên bản cũ.
- **Playbook:** `upgrade.yml` với `serial: 1`, chờ node Ready và mọi Argo CD Application khoẻ.
- **Đo:** chạy `curl` liên tục trong lúc nâng cấp và đếm số request lỗi.

**7.4** **Ý chính:** mỗi bước có lệnh kiểm tra, và kết quả được ghi vào `docs/evidence/`. Tôi chỉ nói những con số đã
đo.

- **App:** 22 test pass; image 926 → 483 MB; build index 150.7 giây, lần hai dưới 1 giây; container khoẻ sau khoảng 6
  giây.
- **Terraform:** ba stack gồm bootstrap 18, shared 17, cluster 84 resource; phần cluster dựng lại trong 3 phút 19
  giây và plan sau đó không còn thay đổi; request HTTP tới bucket state bị từ chối; mô phỏng IAM cho thấy quyền đúng
  như thiết kế.
- **Ansible:** `make cluster` mất `[điền]`; chạy lần hai `changed=0`; tắt một node API vẫn trả lời.
- **GitOps và CI:** mọi ứng dụng của Argo CD `Synced` và `Healthy`; commit tới dev mất `[điền]`; `cosign verify`
  thành công; pull request prod do bot mở và được merge.
- **Vận hành ngày 2:** image chưa ký bị từ chối trên prod; RTO khôi phục etcd `[điền]`; nâng cấp Kubernetes với
  `[điền]` request lỗi.

**7.5** **Ý chính:** Alertmanager đi kèm kube-prometheus-stack gửi cảnh báo khi app hoặc cluster có dấu hiệu lỗi.

**Các alert chính:**

1. Pod của app không Ready kéo dài, hoặc restart liên tục.
2. Tỉ lệ lỗi 5xx vượt ngưỡng trong 5 phút.
3. Độ trễ gọi Gemini tăng mạnh (thấy qua `llm_request_duration_seconds`).
4. Node NotReady, etcd mất member, CPU node cao kéo dài (`m7i-flex` không có metric CPU credit, nên cảnh báo theo
   mức dùng CPU).

Với một lab một người thì không có on-call; ở công ty, alert nghiêm trọng mới gọi người trực.

> **Mẹo:** xác nhận các alert này đã thật sự được cấu hình trước khi nói (xem checklist đầu file).

---

## 8. Chi phí và ràng buộc

**8.1** **Ý chính:** cluster khoảng 0.53 USD/giờ và chỉ chạy khi cần; phần luôn giữ khoảng 7 USD/tháng. Chi phí được
kiểm soát bằng thiết kế (xoá khi không dùng) và bằng cảnh báo (budget).

| Hạng mục | Chi phí |
|---|---|
| Cluster khi đang chạy (3 node, NAT, 2 NLB, WireGuard, ổ đĩa, IPv4) | ≈ 0.53 USD/giờ |
| Workstation khi đang chạy | ≈ 0.03 USD/giờ |
| Luôn giữ (KMS key, 5 secret, Route 53, bucket, image, ổ đĩa workstation) | ≈ 7 USD/tháng |

**Cách giảm:**

- xoá cluster khi không dùng (tiết kiệm lớn nhất)
- một NAT gateway thay vì ba
- S3 gateway endpoint (miễn phí) để traffic S3 không đi qua NAT
- WireGuard thay vì dịch vụ VPN managed

**Cảnh báo:** budget 100 USD/tháng gửi email ở mức 50% và 100%, lọc theo tag `project` để không lẫn với project khác
trong cùng account.

**8.2** **Ý chính:** năm ràng buộc: account AWS Free plan, credit có hạn, account dùng chung với project khác, một
người vận hành, và không được cài gì lên laptop.

| Ràng buộc | Ảnh hưởng tới thiết kế |
|---|---|
| **Free plan** chỉ cho chạy loại máy đủ điều kiện | Node `m7i-flex.large`, workstation `t3.small` kèm swap; không chuyển được domain sang Route 53 nên delegate DNS |
| **Credit có hạn** | Chia stack để xoá cluster khi không dùng; một NAT gateway |
| **Account dùng chung** | Tag `project` cho budget; đặt tên mọi thứ theo `medical-rag-*`; tự tạo VPC riêng vì VPC mặc định đã bị xoá subnet |
| **Một người vận hành** | Chạy Terraform từ workstation thay vì CI; mỗi bước có hướng dẫn và lệnh kiểm tra |
| **Không cài gì lên laptop** | Mọi công cụ nằm trên ops workstation trong AWS, vào bằng SSM |

---

## 9. Khó khăn và bài học

**9.1** **Ý chính:** kể một chuyện mà nguyên nhân được chứng minh bằng log hoặc số đo. Chuyện 1 là lựa chọn chính;
chuyện 2 và 3 để dành khi được hỏi thêm.

**Chuyện 1: Free plan chặn loại máy.**
"Lần launch EC2 đầu tiên lỗi `not eligible for Free Tier` dù account còn credit. Đọc kỹ thì lỗi nói về *loại máy*
chứ không phải credit. Account đang ở AWS Free plan, gói này chặn mọi loại máy không đủ điều kiện, bất kể credit.
Tôi liệt kê các loại hợp lệ, chọn `m7i-flex.large` đủ 2 vCPU và 8 GB cho node, và ghi lại rủi ro mới: loại máy này
không có metric CPU credit, nên phải cảnh báo theo mức dùng CPU."

**Chuyện 2: build Docker bị treo khi tải package.**
"Build image cứ đứng ở bước tải từ PyPI. Tôi đo thử: cùng một file, tải qua IPv4 mất 11 đến 20 giây, qua IPv6 chỉ
0.45 giây. Tuyến IPv4 tới CDN của PyPI trên mạng đó bị nghẽn. Container của Docker Desktop lại không có IPv6, và khi
có địa chỉ IPv6 nội bộ thì hệ thống vẫn ưu tiên IPv4. Tôi cấu hình Docker Engine dùng một dải IPv6 chuẩn; sau đó
cùng lượt tải trong bước build chỉ còn 0.41 giây."

**Chuyện 3: một node không vào được Session Manager.**
"Ping của Ansible thành công trên node 1 và 3, nhưng node 2 báo `TargetNotConnected`. Máy vẫn chạy, nên tôi không
restart ngay mà tìm bằng chứng. SSM không có bản ghi nào của node 2, tức agent chưa từng đăng ký. Log boot báo agent
không lấy được credential từ instance profile, dù profile đã gắn. Giả thuyết của tôi là agent chạy trước khi
credential sẵn sàng; tôi chưa chứng minh được, vì hai node còn lại tạo cùng lúc vẫn bình thường. Tôi reboot để khôi
phục, và thêm một script lúc boot chờ có credential rồi mới restart agent."

> **Mẹo:** chuyện 3 chỉ kể như ví dụ về cách tìm bằng chứng, và nói rõ đâu là giả thuyết. Xác nhận script đã có trong
> repo trước khi nói câu cuối (xem checklist đầu file).

**Điểm chung để nhấn mạnh:** đọc đúng thông báo lỗi, thu bằng chứng trước khi can thiệp, và nói rõ đâu là nguyên nhân
đã chứng minh, đâu là giả thuyết.

**9.2** **Ý chính:** sửa ba điểm yếu lớn nhất: quyền IAM dùng chung của node, quyền admin của workstation, và NAT
gateway đơn. Chi tiết từng điểm ở 6.4.

Sau đó: bộ đánh giá chất lượng câu trả lời (3.7), load test để có con số scale thật (4.6), và đưa Terraform vào CI
với credential tạm thời qua OIDC.

**9.3** **Ý chính:** kiến trúc tương tự, nhưng quy mô, quyền hạn và quy trình đơn giản hơn nhiều.

| Ở project này | Ở công ty |
|---|---|
| Một account AWS, dùng chung | Nhiều account tách theo môi trường, có chính sách chung toàn tổ chức |
| Một người, apply từ workstation | Apply qua CI, có review, credential tạm thời |
| Tự dựng Kubernetes | Nhiều khả năng dùng EKS |
| Cluster xoá khi không dùng | Chạy liên tục, có SLO và on-call |
| Một NAT gateway | Mỗi AZ một NAT gateway |
| App qua HTTP | HTTPS, WAF |
| VPN bằng key quản lý tay | Truy cập qua hệ thống định danh có MFA |

**9.4** **Ý chính:** ba bài học lớn.

1. **Thiết kế theo vòng đời và theo ranh giới trách nhiệm.** Tách thứ cần giữ khỏi thứ có thể xoá, và mỗi công cụ chỉ
   lo một lớp, làm hệ thống dễ dựng lại và dễ sửa hơn rất nhiều.
2. **Bằng chứng trước khi sửa.** Lỗi Free plan và lỗi mạng khi build Docker đều được giải quyết nhờ đọc kỹ lỗi và đo
   đạc, không phải nhờ thử mò.
3. **Ghi rõ đánh đổi.** Một NAT gateway, quyền dùng chung của node, VPN tự quản lý đều là lựa chọn có chủ đích. Ghi
   lại lý do và cách sửa giúp người khác, và chính mình sau này, hiểu vì sao hệ thống như vậy.
