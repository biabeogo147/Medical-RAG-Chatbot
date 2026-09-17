# Đáp án tổng quan về project

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Mỗi câu mở đầu bằng **ý chính** để nói trước,
phần sau là chi tiết khi người phỏng vấn hỏi thêm.

## Trạng thái các phần

Người phỏng vấn sẽ hỏi "cái này bạn đã chạy thật chưa". Bảng dưới đây là căn cứ để trả lời trung thực. Cập
nhật nó mỗi khi xong một phase.

| Phần | Trạng thái | Căn cứ |
|---|---|---|
| App: gunicorn, health check, metrics, index có version, image gọn | ✅ Đã làm, kiểm chứng ở local | [`evidence/local.md`](../evidence/local.md) |
| Terraform: 3 stack, WireGuard, Route 53 | ✅ Đã làm, kiểm chứng trên AWS | [`evidence/terraform.md`](../evidence/terraform.md) |
| Ansible: cluster kubeadm HA | 🔧 Đang làm | [`ansible/guide.md`](../ansible/guide.md) |
| Argo CD, Helm chart, dev/prod, External Secrets, Rancher | 📐 Đã thiết kế, chưa làm | [design §4.2.1, §4.4](../selfmanaged-k8s-ops-design.md) |
| Jenkins pipeline: scan, SBOM, ký image, promote | 📐 Đã thiết kế, chưa làm | [design §4.5](../selfmanaged-k8s-ops-design.md) |
| Kyverno, backup/restore etcd, upgrade drill | 📐 Đã thiết kế, chưa làm (P1) | [design §4.6](../selfmanaged-k8s-ops-design.md) |

Trong đáp án, phần nào chưa làm được đánh dấu **📐 Thiết kế**. Khi phỏng vấn, nói "tôi thiết kế như sau" cho
những phần đó, đừng nói "tôi đã làm".

---

## 1. Giới thiệu

**1.1** **Ý chính:** "Đây là một chatbot hỏi đáp y khoa dùng RAG. Tôi dùng nó làm bài toán để dựng toàn bộ
phần vận hành theo cách một công ty tự chạy Kubernetes: hạ tầng dựng lại được bằng code, cluster HA tự quản
lý, triển khai theo GitOps, và chuỗi cung ứng image có ký và kiểm tra."

Nếu có thêm thời gian, kể theo ba lớp:

- **Hạ tầng:** Terraform dựng mọi thứ trên AWS, chia ba stack theo vòng đời. Phần cluster xoá khi không dùng
  và dựng lại trong vài phút.
- **Cluster:** Ansible biến ba máy EC2 thành cluster kubeadm có ba control plane ở ba AZ, không dùng SSH.
- **Triển khai:** Jenkins build, quét và ký image; Argo CD đồng bộ từ Git sang cluster; dev tự cập nhật, prod
  chỉ đổi qua pull request có review.

Chốt bằng một con số: "Cluster 65 resource dựng lại từ đầu mất khoảng ba phút rưỡi, và plan sau đó không còn
thay đổi nào."

**1.2** **Ý chính:** người dùng hỏi một câu về y khoa, app tìm đoạn liên quan trong bộ bách khoa y khoa rồi
để Gemini trả lời ngắn gọn **chỉ dựa trên các đoạn đó**. Không có trong tài liệu thì trả lời "không biết".

Bên trong có hai giai đoạn:

1. **Chuẩn bị (làm một lần):** đọc PDF (759 trang), cắt thành 7.079 đoạn nhỏ, biến mỗi đoạn thành vector
   bằng model embedding qua Hugging Face API, rồi lưu vào FAISS index.
2. **Trả lời (mỗi câu hỏi):**
   - biến câu hỏi thành vector
   - tìm 3 đoạn gần nhất trong FAISS
   - gửi câu hỏi kèm 3 đoạn đó cho Gemini, với chỉ dẫn "chỉ dùng thông tin trong ngữ cảnh"

Cách này gọi là RAG (Retrieval Augmented Generation): model không phải "nhớ" kiến thức y khoa, nên câu trả lời
bám vào tài liệu và ít bịa hơn.

**1.3** **Ý chính:** phần vận hành. Phần RAG giữ ở mức đơn giản; việc của tôi là đưa nó từ một app chạy trên
máy cá nhân thành một hệ thống triển khai, vận hành và kiểm chứng được.

Cụ thể:

- sửa app để chạy được trong môi trường thật: server production, health check, metrics, index có version
- thiết kế và dựng hạ tầng AWS bằng Terraform
- dựng cluster Kubernetes bằng Ansible
- thiết kế luồng CI/CD, bảo mật chuỗi cung ứng và vận hành ngày 2
- đo đạc và ghi lại bằng chứng cho từng bước

**1.4** **Ý chính:** tôi hướng tới vị trí DevOps / Platform / SRE, nên muốn có một project chứng minh được
bốn năng lực bằng số liệu thật, không chỉ bằng lời:

1. **Hạ tầng tái tạo được:** xoá đi dựng lại mà không cần thao tác tay.
2. **Triển khai theo GitOps:** Git là nguồn sự thật, prod đổi qua review.
3. **Bảo mật chuỗi cung ứng:** quét, SBOM, ký image bằng KMS, chặn image chưa ký.
4. **Vận hành ngày 2:** backup/khôi phục etcd, nâng cấp cluster.

Tôi có một project thứ hai chạy trên EKS. Hai project bổ sung cho nhau: project này tự vận hành control plane,
project kia dùng dịch vụ managed và tập trung vào autoscaling, canary và observability.

**1.5** **Ý chính:** app và hạ tầng AWS đã xong và có số liệu; cluster Kubernetes đang dựng; phần GitOps, CI và
vận hành ngày 2 đã thiết kế xong nhưng chưa triển khai.

Xem bảng *Trạng thái các phần* ở đầu file. Nói thẳng điều này khi được hỏi. Người phỏng vấn đánh giá cao việc
tách rõ "đã chạy và đo" với "đã thiết kế", hơn là nghe tất cả đều đã xong.

---

## 2. Kiến trúc tổng thể

**2.1** **Ý chính:** ba lớp. Hạ tầng AWS ở dưới cùng, cluster Kubernetes ở giữa, các ứng dụng và công cụ
chạy trong cluster ở trên cùng.

```
Người dùng ──HTTP 80──> Public NLB ──> ingress-nginx ──> app dev (/dev) và prod (/)
                                                            │
                                                            ├─> Hugging Face API (embedding câu hỏi)
                                                            ├─> Gemini API (sinh câu trả lời)
                                                            └─< S3 (FAISS index theo version)

Vận hành ──WireGuard──> gateway ──> Internal NLB :443 ──> ingress-nginx ──> Rancher
         ──SSM────────> node (Ansible, kubectl qua tunnel tới Internal NLB :6443)

GitHub ──> Jenkins (build, quét, ký) ──> ECR
   ▲            │ cập nhật version trong Git
   └────────────┘
GitHub ──> Argo CD ──> đồng bộ vào cluster
```

- **AWS:** một VPC trải ba AZ; ba node ở subnet private; hai NLB (public cho app, internal cho Kubernetes API
  và Rancher); một NAT gateway; S3, ECR, KMS, Secrets Manager.
- **Cluster:** ba node đều là control plane và đều chạy workload.
- **Trong cluster** (📐 Thiết kế): Argo CD, ingress-nginx, External Secrets, Prometheus/Grafana, Jenkins,
  Rancher, và app ở hai môi trường dev, prod.

**2.2** **Ý chính:** trình duyệt → public NLB → ingress-nginx → pod của app → FAISS trong bộ nhớ →
Hugging Face và Gemini → trả về.

1. Trình duyệt gửi request tới DNS name của public NLB, cổng 80.
2. NLB chuyển tới NodePort 30080 trên một trong ba node.
3. ingress-nginx xem đường dẫn: `/dev` sang app dev, còn lại sang app prod.
4. gunicorn nhận request trong pod. Chain RAG đã được dựng sẵn lúc khởi động, nên không phải load lại index.
5. App gọi Hugging Face để biến câu hỏi thành vector, tìm 3 đoạn gần nhất trong FAISS (nằm sẵn trong bộ nhớ),
   rồi gọi Gemini để sinh câu trả lời.
6. Trả về HTML. Thời gian tìm kiếm và thời gian gọi LLM được đo riêng thành metric.

Hạn chế đã biết: app đi qua HTTP thường, chưa có HTTPS, vì chưa có domain cho app. Điều này được ghi rõ là
ngoài phạm vi.

**2.3** **Ý chính:** mỗi công cụ sở hữu đúng một lớp và không chạm sang lớp khác.

| Công cụ | Sở hữu | Không làm |
|---|---|---|
| Terraform | Tài nguyên AWS: mạng, máy, load balancer, IAM, bucket, DNS | Không cài gì lên máy |
| Ansible | Cấu hình bên trong máy và chạy `kubeadm` để dựng cluster | Không tạo tài nguyên AWS, không cài addon |
| Argo CD | Mọi thứ chạy trong cluster, đồng bộ từ Git | Không build image |
| Jenkins | Build, test, quét, ký image, rồi cập nhật version trong Git | Không có quyền triển khai vào cluster |

**Vì sao chia rõ:**

- **Biết ngay sửa ở đâu:** lỗi ở tầng nào thì tìm ở công cụ của tầng đó.
- **Dựng lại độc lập:** xoá cluster không đụng tới image, index hay secret.
- **An toàn hơn:** Jenkins không cần quyền admin của cluster, nên lộ Jenkins không đồng nghĩa lộ cluster.

**2.4** **Ý chính:** mục tiêu là tự vận hành control plane (etcd HA, backup, certificate, nâng cấp), và EKS giấu
đúng những thứ đó. Project thứ hai của tôi đã dùng EKS.

- **Được:** hiểu và chứng minh được cách Kubernetes vận hành từ bên trong; không mất phí control plane của EKS
  (0.10 USD/giờ).
- **Mất:** không có nâng cấp tự động và SLA của AWS; không có IRSA / Pod Identity nên pod dùng chung quyền của
  node; không có AWS Load Balancer Controller nên NLB phải tạo tĩnh bằng Terraform; nhiều việc bảo trì hơn.
- **Ở công ty:** tôi sẽ chọn EKS làm mặc định, trừ khi có lý do cụ thể như cần giống môi trường on-premise.

**2.5** **Ý chính:** chỉ để phục vụ lưu lượng của app thì không cần. Nhưng project cần chạy cùng lúc nhiều
thành phần, và Kubernetes là nơi hợp lý để vận hành chúng theo một cách thống nhất.

Những thứ chạy cùng nhau: app ở hai môi trường, job build index, Jenkins với agent tạm thời, Argo CD,
Prometheus/Grafana, Rancher, Kyverno. Kubernetes cho chúng một cách chung để triển khai, kiểm tra sức khoẻ, tự
khởi động lại, cô lập mạng và quản lý secret.

Nếu chỉ có một app nhỏ ở công ty thật, tôi sẽ dùng dịch vụ đơn giản hơn như ECS hoặc một máy chạy container.
Trả lời thẳng như vậy tốt hơn là cố biện minh.

**2.6** **Ý chính:** cùng một Helm chart, hai file values khác nhau, hai Argo CD Application, hai namespace.
**📐 Thiết kế.**

| | dev | prod |
|---|---|---|
| Values | `deploy/envs/dev/values.yaml` | `deploy/envs/prod/values.yaml` |
| Replica | 1 | 2, trải trên các node khác nhau, PodDisruptionBudget |
| Đường dẫn | `/dev` | `/` |
| Cách đổi version | Jenkins commit thẳng | Pull request, người duyệt merge |
| Kyverno | Chỉ ghi log (Audit) | Chặn image chưa ký (Enforce) |

Chưa có domain cho app, nên hai môi trường chia nhau một NLB theo đường dẫn. Vì vậy app phải hỗ trợ chạy dưới
tiền tố `/dev`, và phần này chưa làm xong.

---

## 3. Ứng dụng và dữ liệu

**3.1** **Ý chính:** app chạy được nhưng không vận hành được. Mỗi lần khởi động mất nhiều phút và tốn quota API,
không có health check thật, và triển khai bằng quyền admin.

1. **Dựng lại toàn bộ index mỗi lần pod khởi động.** Chậm, tốn quota Hugging Face, và liveness probe có thể
   giết pod giữa chừng.
2. **Mỗi request lại load lại FAISS và LLM client.**
3. **Chạy bằng server development của Flask,** health check chỉ là trang chủ `/`.
4. **Tên Secret trong README không khớp với Deployment.**
5. **CI đẩy thẳng lên cluster bằng kubeconfig admin,** không quét, không ký image, tag image sửa bằng `sed`.
6. **Embedding gửi toàn bộ đoạn văn trong một request,** không chia lô, không thử lại.

**3.2** **Ý chính:** index là một artifact có version, build một lần, lưu trên S3. Pod chỉ tải về đúng version
được ghi trong Git. Rollback là sửa một dòng trong Git.

- **Version là một mã băm của nội dung:** SHA-256 của file PDF, kích thước đoạn, độ chồng lấn và tên model
  embedding, lấy 12 ký tự đầu. Cùng đầu vào thì luôn ra cùng version. Đã kiểm chứng: build trong container và
  trên máy Windows đều ra `cc759ae1a093`.
- **Không build lại khi không cần:** lệnh `python -m app.index build` kiểm tra version đó đã có trên kho chưa.
  Có rồi thì bỏ qua. Lần đầu mất 150,7 giây cho 7.079 đoạn; lần sau dưới 1 giây.
- **Chống lỗi khi build:** embedding gửi theo lô, gặp lỗi giới hạn tốc độ (429) hoặc lỗi 5xx thì thử lại với
  thời gian chờ tăng dần.
- **Trên Kubernetes (📐 Thiết kế):** Argo CD chạy job build index *trước* khi cập nhật app (PreSync hook).
  Version được ghi trong `values.yaml` của từng môi trường; một initContainer tải đúng version đó về.
- **Rollback:** đổi `index.version` về giá trị cũ trong Git, Argo CD đồng bộ lại.

**3.3** **Ý chính:** `/healthz` trả lời "process còn sống không", `/readyz` trả lời "đã sẵn sàng phục vụ chưa".
Gộp làm một thì Kubernetes sẽ khởi động lại một pod chỉ đang chờ, hoặc gửi request tới pod chưa sẵn sàng.

- **`/healthz`** không kiểm tra gì bên ngoài. Dùng cho **liveness probe**: nếu fail, Kubernetes khởi động lại
  container.
- **`/readyz`** chỉ trả 200 khi index đã load và chain RAG đã dựng xong; trước đó trả 503 kèm lỗi gần nhất. Dùng
  cho **readiness probe** (có nhận traffic không) và **startup probe** (cho tối đa 5 phút để khởi động).

Ví dụ: Hugging Face tạm lỗi lúc khởi động. App thử lại với thời gian chờ tăng dần. Trong lúc đó `/readyz` trả
503 nên không nhận request, còn `/healthz` vẫn 200 nên Kubernetes không giết pod vô ích. Việc này đã có unit
test.

**3.4** **Ý chính:** mỗi chỗ gọi API bên ngoài đều có cách xử lý riêng, để lỗi tạm thời không biến thành sự cố.

| Tình huống | Cách xử lý |
|---|---|
| Hugging Face trả 429/5xx khi build index | Thử lại theo lô, chờ tăng dần, tối đa 6 lần. Hết lượt thì job fail, và **bản app cũ vẫn chạy với index cũ** |
| API lỗi lúc app khởi động | Thử lại trong nền; `/readyz` trả 503 cho tới khi xong |
| Gemini lỗi khi đang trả lời | Trả lỗi 502 dạng JSON, thử lại tối đa 1 lần có jitter để không dồn request; lỗi được đếm trong metric (📐 Thiết kế) |
| Version index chưa có trên S3 | initContainer fail, pod mới không Ready, rolling update dừng lại và pod cũ vẫn phục vụ (📐 Thiết kế) |

Nguyên tắc chung: **lỗi thì dừng lại ở bản đang chạy tốt**, không phá bản cũ.

**3.5** **Ý chính:** image nhỏ đi gần một nửa, chạy bằng user thường với filesystem chỉ đọc, và test chạy ngay
trong bước build.

- **Kích thước:** 926 MB → 483 MB (giảm 48 %), nhờ build nhiều stage: công cụ build nằm ở stage riêng, không
  mang theo PDF hay `.git`.
- **Bảo mật:** chạy bằng UID 10001, root filesystem chỉ đọc (đã thử `touch` và nhận `Read-only file system`),
  chỉ `/tmp` và thư mục index được ghi.
- **Server:** gunicorn 2 worker, mỗi worker 4 thread, thay cho server development của Flask.
- **Test:** `docker build --target test .` chạy ruff và 22 unit test.
- **Phụ thuộc:** khoá bằng `uv.lock` (93 package), không kéo PyTorch vì embedding gọi qua API.

---

## 4. Hạ tầng và cluster

Phần này có bộ câu hỏi chi tiết riêng: [`../terraform/questions.md`](../terraform/questions.md).

**4.1** **Ý chính:** một VPC ba AZ, ba node Kubernetes ở subnet private, hai load balancer, và các dịch vụ
dùng chung (ECR, S3, KMS, Secrets Manager, Route 53), tất cả dựng bằng Terraform.

- **Mạng:** VPC `10.10.0.0/16`, subnet public và private ở ba AZ, một NAT gateway, S3 gateway endpoint.
- **Máy:** ba node `m7i-flex.large` (2 vCPU, 8 GB), không public IP, không key SSH; một WireGuard gateway nhỏ;
  một ops workstation để chạy mọi lệnh.
- **Load balancer:** public NLB cổng 80 cho app; internal NLB cổng 6443 cho Kubernetes API và 443 cho Rancher.
- **Dịch vụ dùng chung:** ECR chứa image, S3 chứa index và state, KMS key để ký image, Secrets Manager chứa
  secret, Route 53 cho domain, và một budget cảnh báo chi phí.

**4.2** **Ý chính:** cluster tốn khoảng 0.53 USD mỗi giờ, nên chỉ chạy khi cần. Nó xoá được vì mọi thứ quan
trọng nằm ở chỗ khác, và dựng lại nhanh vì mọi thứ đều là code.

- **Chia theo vòng đời:** ba stack Terraform. `bootstrap` (bucket state, workstation) và `shared` (image, index,
  KMS key, secret, DNS) được giữ lại; `cluster` (mạng, node, load balancer) bị xoá.
- **Đã đo:** bản cluster 65 resource xoá mất 1 phút 27 giây, dựng lại từ đầu mất 3 phút 19 giây, không có bước
  thủ công, và `terraform plan` sau đó báo không còn thay đổi. Bản đầy đủ 84 resource có WireGuard đã dựng
  thành công nhưng chưa đo lại thời gian.
- **Phần còn lại** (Ansible dựng cluster, Argo CD cài addon) cũng là code, nên cả chuỗi dựng lại được bằng vài
  lệnh `make`.

**4.3** **Ý chính:** qua AWS Systems Manager Session Manager. Không máy nào mở cổng SSH, không có key pair, không
có bastion.

- **Vào máy:** mở session trong trình duyệt hoặc bằng `aws ssm start-session`. IAM quyết định ai được vào.
- **Ansible:** dùng connection plugin `aws_ssm` thay cho SSH; file module được chuyển qua một bucket S3.
- **kubectl:** Kubernetes API chỉ có trên internal NLB. `make tunnel` mở một SSM port-forward từ workstation,
  qua node 1, tới NLB; kubectl gọi `https://127.0.0.1:6443`. Vì vậy certificate của API server phải có thêm
  `127.0.0.1`.

**Đánh đổi:** Ansible qua SSM chậm hơn SSH, và node cần NAT để tới được SSM.

**Sự cố thật:** một lần node 2 không kết nối được SSM. Log boot cho thấy agent khởi động khi credential của IAM
role chưa sẵn sàng. Reboot để agent lấy lại credential; cách phòng lần sau là script chờ credential lúc boot
(xem 9.1).

**4.4** **Ý chính:** ba node ở ba AZ, cả ba đều là control plane với etcd, và API được gọi qua một load balancer.
Mất một node thì etcd vẫn đủ đa số (2/3) và API vẫn trả lời.

- **etcd** cần đa số member sống để ghi dữ liệu. Ba member chịu được mất một.
- **Internal NLB** đứng trước ba API server, kiểm tra `/readyz` và chỉ gửi traffic tới server khoẻ. Mọi thứ
  (kubelet, kubectl) gọi qua NLB, không gọi thẳng node nào.
- **App prod** (📐 Thiết kế): 2 replica trải trên các node khác nhau, PodDisruptionBudget giữ ít nhất 1.
- **Bài kiểm tra** (🔧 phase Ansible): stop một node, xác nhận `kubectl get nodes` vẫn chạy.

**Điểm yếu đã biết:** chỉ có một NAT gateway, và nó nằm cùng AZ với node 1 và WireGuard gateway. Mất AZ đó thì cả
ba node mất đường ra internet: app không gọi được Gemini, SSM ngắt, Rancher không vào được. Đây là đánh đổi chi
phí có ghi lại; cách sửa là mỗi AZ một NAT gateway.

**4.5** **Ý chính:** Rancher là giao diện quản trị toàn quyền cluster, nên chỉ vào được qua VPN WireGuard. Cổng
443 chỉ tồn tại trên load balancer nội bộ.

- **Đường đi:** laptop → WireGuard (UDP 51820) → gateway → internal NLB :443 → ingress-nginx → Rancher.
- **Tên miền:** `rancher.recruitai.io.vn` trỏ tới IP **private** của internal NLB. Ai tra DNS cũng thấy, nhưng
  không có VPN thì không tới được.
- **Gateway lọc chặt:** chỉ cho qua DNS và HTTPS; cổng 6443 của Kubernetes API bị chặn dù cùng nằm trên NLB đó.
- **TLS:** certificate Sectigo mua riêng, private key nằm trong Secrets Manager; TLS được terminate ở
  ingress-nginx.
- **Trạng thái:** tunnel, DNS và cổng 443 đã dựng và kiểm chứng; Rancher được cài ở phase GitOps (📐 Thiết kế).

**Vì sao không dùng AWS Client VPN:** tốn vài chục đô mỗi tháng kể cả khi không dùng. WireGuard chỉ cần một máy
nhỏ, xoá cùng cluster.

---

## 5. CI/CD và GitOps

Toàn bộ phần này là **📐 Thiết kế**; Jenkinsfile hiện tại vẫn là bản cũ.

**5.1** **Ý chính:** push code → Jenkins test, build, quét, ký image → Jenkins ghi version mới vào Git → Argo CD
thấy Git đổi và cập nhật dev → Jenkins mở pull request cho prod → người duyệt merge → Argo CD cập nhật prod.

1. **Test:** ruff, pytest, hadolint cho Dockerfile.
2. **Build và push:** BuildKit build image, đẩy lên ECR với tag là git SHA.
3. **Quét:** Trivy; có lỗ hổng CRITICAL đã có bản sửa thì dừng pipeline.
4. **SBOM:** Syft tạo danh sách thành phần của image.
5. **Ký:** Cosign ký image và gắn SBOM bằng KMS key.
6. **Lên dev:** Jenkins sửa `deploy/envs/dev/values.yaml` và commit. Argo CD đồng bộ.
7. **Lên prod:** Jenkins mở pull request sửa `deploy/envs/prod/values.yaml`, kèm tóm tắt kết quả quét. Người
   duyệt merge thì Argo CD đồng bộ.

**5.2** **Ý chính:** CI tạo ra artifact đáng tin; CD đưa trạng thái trong Git vào cluster. Tách ra thì Jenkins
không cần quyền vào cluster, và Git trở thành nơi duy nhất quyết định cái gì đang chạy.

- **Push (Jenkins `kubectl apply`):** Jenkins phải giữ credential mạnh của cluster; ai sửa tay trên cluster thì
  không ai biết; muốn biết đang chạy gì phải hỏi cluster.
- **Pull (Argo CD):** Argo CD chạy trong cluster và tự kéo từ Git. Cluster lệch khỏi Git thì Argo CD báo và tự
  sửa lại. Muốn biết đang chạy gì, đọc Git.
- **Hệ quả tốt:** Jenkins sập thì không ảnh hưởng gì tới thứ đang chạy, chỉ tạm dừng việc ra bản mới.

**5.3** **Ý chính:** lên prod là merge một pull request đổi version trong Git; rollback là revert commit đó.

- **Lên prod:** pull request do Jenkins mở chỉ sửa một file values. Người duyệt xem kết quả quét và digest của
  image rồi merge.
- **Rollback app:** `git revert` commit đổi version, Argo CD đồng bộ về image cũ. Image cũ vẫn còn trên ECR (giữ
  20 bản gần nhất).
- **Rollback index:** đổi `index.version` về giá trị cũ, tương tự.
- **Ưu điểm:** mọi lần thay đổi prod đều có người duyệt, có lịch sử, và quay lại được bằng thao tác Git quen
  thuộc.

**5.4** **Ý chính:** tag có thể bị trỏ sang image khác, còn digest là mã băm của chính nội dung image. Ghi digest
thì thứ đã được quét và ký chính xác là thứ đang chạy.

- Values ghi dạng `tag@sha256:...`: tag để người đọc hiểu, digest để máy dùng.
- Chữ ký Cosign gắn với digest, nên Kyverno kiểm tra chữ ký trên đúng image sẽ chạy.
- ECR còn đặt tag immutable: tag đã dùng thì không ghi đè được.

**5.5** **Ý chính:** dùng BuildKit ở chế độ rootless trong một pod agent, không mount Docker socket của node.

- **Vì sao không mount Docker socket:** ai điều khiển Docker daemon của node thì gần như có quyền root trên node
  đó.
- **Vì sao không dùng Kaniko:** dự án Kaniko đã bị lưu trữ (archived), không còn được phát triển.
- **Agent tạm thời:** mỗi build chạy trong pod riêng (Python, BuildKit, Trivy, Syft, Cosign), xong thì xoá.
- **Cache:** cache của build lưu trên ECR, nên build sau nhanh hơn dù agent là pod mới.

**5.6** **Ý chính:** bước đầu tiên của pipeline kiểm tra commit: nếu tác giả là `jenkins-bot` hoặc commit chỉ đổi
thư mục `deploy/`, pipeline dừng ngay mà không build.

Không có bước này, Jenkins commit version mới → Jenkins thấy commit mới → build lại → commit version mới → vòng
lặp vô hạn.

---

## 6. Bảo mật

**6.1** **Ý chính:** secret nằm trong AWS Secrets Manager. External Secrets trong cluster đọc nó bằng quyền IAM
của node và tạo Kubernetes Secret. Git, Terraform state và image không chứa giá trị secret nào.

1. **Terraform** chỉ tạo secret rỗng (tên và quyền). ✅
2. **Người vận hành** nhập giá trị một lần bằng AWS CLI từ một file tạm, rồi xoá file bằng `shred`. ✅
3. **External Secrets** đồng bộ vào Kubernetes Secret; pod dùng như biến môi trường. 📐 Thiết kế
4. **Đổi secret** chỉ cần cập nhật trên Secrets Manager; External Secrets tự đẩy xuống.

Các key riêng cũng được sinh ngay nơi dùng: private key của certificate sinh trên workstation, private key
WireGuard của laptop không bao giờ rời laptop.

**6.2** **Ý chính:** chuỗi bốn bước: quét → SBOM → ký bằng KMS → kiểm tra chữ ký lúc triển khai. Image chưa ký
thì không vào được prod. **📐 Thiết kế.**

- **Quét:** Trivy chặn pipeline khi có lỗ hổng CRITICAL đã có bản sửa.
- **SBOM:** Syft liệt kê mọi thành phần trong image, lưu kèm image dưới dạng attestation.
- **Ký:** Cosign ký digest của image bằng KMS key bất đối xứng. Private key không bao giờ rời KMS; Jenkins chỉ
  được gọi lệnh ký.
- **Kiểm tra:** Kyverno kiểm tra chữ ký bằng public key trước khi cho pod chạy. Prod chặn, dev chỉ ghi log.
- **Bằng chứng dự kiến:** thử triển khai một image chưa ký lên prod và chụp lỗi bị từ chối.

**6.3** **Ý chính:** chỉ hai cổng mở ra internet: HTTP 80 của app và UDP 51820 của WireGuard. Mọi thứ khác là
private.

- **Không SSH:** vào máy bằng Session Manager.
- **Node không có public IP;** API Kubernetes và Rancher chỉ có trên load balancer nội bộ.
- **Quyền tối thiểu có giới hạn:** policy tự viết ghi đúng từng tài nguyên; gateway WireGuard chỉ đọc được
  secret của chính nó.
- **Mã hoá:** ổ đĩa EBS mã hoá, bucket S3 chặn truy cập public và chỉ nhận HTTPS.
- **Metadata:** bắt buộc IMDSv2 để chống lấy trộm credential qua lỗi SSRF.
- **Pod** (📐 Thiết kế): chạy non-root, filesystem chỉ đọc, NetworkPolicy mặc định chặn traffic vào.

**6.4** **Ý chính:** có, và tôi ghi lại rõ trong thiết kế. Nói ra điểm yếu kèm cách sửa cho thấy mình hiểu hệ
thống.

1. **Mọi pod dùng chung quyền IAM của node.** Cluster tự dựng không có sẵn IRSA, nên pod bị chiếm quyền có thể
   dùng quyền ký image, đọc secret, và hai managed policy của AWS còn cho quyền rộng trên cả account. Cách sửa:
   NetworkPolicy chặn metadata service, về lâu dài dựng IRSA.
2. **Workstation có quyền `AdministratorAccess`.** Ai mở được session trên nó là admin. Cách sửa: tách role chỉ
   plan và role apply.
3. **App chưa có HTTPS**, vì chưa có domain cho app.
4. **Một NAT gateway** là điểm lỗi đơn cho traffic đi ra (xem 4.4).
5. **Load balancer nội bộ tin cả dải IP của VPC;** hiện chỉ firewall trên gateway WireGuard chặn laptop gọi
   API. Cách sửa: giới hạn theo security group của node.

---

## 7. Vận hành ngày 2 và quan sát

**7.1** **Ý chính:** app xuất metric Prometheus ở `/metrics`, đo riêng thời gian tìm kiếm và thời gian gọi LLM;
kube-prometheus-stack thu thập metric của app và cluster, Grafana để xem.

**Metric của app** (✅ đã làm):

- `http_requests_total` theo route và mã trạng thái: tỉ lệ lỗi
- `http_request_duration_seconds`: độ trễ
- `rag_retrieval_duration_seconds` và `llm_request_duration_seconds`: biết chậm do tìm kiếm hay do Gemini
- `rag_index_info{version}`: pod đang dùng index version nào

**Chi tiết kỹ thuật:** gunicorn chạy 2 worker, mỗi worker có bộ đếm riêng. App dùng chế độ multiprocess của
Prometheus để cộng dồn qua các worker; nếu không, mỗi lần scrape chỉ thấy số liệu của một worker ngẫu nhiên.

**Trên cluster** (📐 Thiết kế): ServiceMonitor để Prometheus tự tìm app, Prometheus giữ dữ liệu 24 giờ cho nhẹ,
Grafana chỉ vào qua port-forward. Node `m7i-flex` không có metric CPU credit, nên cảnh báo theo mức dùng CPU kéo
dài.

**7.2** **Ý chính:** snapshot etcd định kỳ lên S3, và diễn tập khôi phục có đo thời gian. **📐 Thiết kế (P1).**

- **Backup:** một CronJob chạy trên node control plane, 6 giờ một lần `etcdctl snapshot save`, kiểm tra snapshot
  hợp lệ rồi mới đẩy lên S3.
- **Diễn tập:** xoá một namespace thử, khôi phục snapshot trên cả ba member, xác nhận namespace quay lại, và ghi
  lại **RTO** (thời gian từ lúc bắt đầu khôi phục tới khi mọi ứng dụng khoẻ lại).
- **Ghi chú:** snapshot chỉ phục hồi đúng cluster đã tạo ra nó. Khi xoá cả cluster thì dựng lại từ code và Git,
  không cần etcd.

**7.3** **Ý chính:** nâng từng node một: drain → nâng kubeadm, kubelet → đưa node trở lại → chờ mọi thứ khoẻ rồi
mới sang node tiếp. Trước đó kiểm tra Rancher có hỗ trợ phiên bản mới không. **📐 Thiết kế (P1).**

- **Cổng kiểm tra tương thích:** chart Rancher 2.15.1 chỉ chấp nhận Kubernetes dưới 1.37. Nên phải nâng Rancher
  trước, xác nhận chart mới chấp nhận phiên bản đích, rồi mới nâng Kubernetes. Không đạt thì giữ 1.36.4.
- **Playbook:** `upgrade.yml` với `serial: 1`, chờ node Ready và mọi Argo CD Application khoẻ trước khi sang node
  tiếp.
- **Đo:** chạy một vòng `curl` liên tục trong lúc nâng cấp và đếm số request lỗi.

**7.4** **Ý chính:** mỗi bước đều có lệnh kiểm tra và kết quả được ghi vào thư mục `docs/evidence/`. Tôi chỉ nói
những con số đã đo được.

- **Local:** 22 test pass; image 926 → 483 MB; build index 150,7 giây, lần hai dưới 1 giây; container khoẻ sau
  khoảng 6 giây.
- **Terraform:** 18 / 17 / 84 resource; dựng lại 3 phút 19 giây; plan sau khi dựng không còn thay đổi; kiểm tra
  bảo mật như request HTTP tới bucket bị từ chối, mô phỏng IAM cho thấy quyền đúng như thiết kế.
- **Các phase sau** (📐 Thiết kế) có sẵn định nghĩa "xong khi nào": chạy Ansible lần hai phải `changed=0`, mất một
  node API vẫn trả lời, image chưa ký bị từ chối, đo RTO khi khôi phục etcd.

---

## 8. Chi phí và ràng buộc

**8.1** **Ý chính:** cluster khoảng 0.53 USD/giờ và chỉ chạy khi cần; phần luôn giữ khoảng 7 USD/tháng. Chi phí
được kiểm soát bằng thiết kế (xoá khi không dùng) và bằng cảnh báo (budget).

| Hạng mục | Chi phí |
|---|---|
| Cluster khi đang chạy (3 node, NAT, 2 NLB, WireGuard, ổ đĩa, IPv4) | ≈ 0.53 USD/giờ |
| Workstation khi đang chạy | ≈ 0.03 USD/giờ |
| Luôn giữ (KMS key, 5 secret, Route 53, bucket, image, ổ đĩa workstation) | ≈ 7 USD/tháng |

**Cách giảm:**

- xoá cluster khi không dùng (tiết kiệm lớn nhất)
- một NAT gateway thay vì ba
- loại máy hợp lệ với Free plan
- S3 gateway endpoint (miễn phí) để traffic S3 không đi qua NAT
- WireGuard thay vì dịch vụ VPN managed

**Cảnh báo:** budget 100 USD/tháng gửi email ở mức 50 % và 100 %, lọc theo tag `project` để không lẫn với
project khác trong cùng account.

**8.2** **Ý chính:** bốn ràng buộc: account AWS Free plan, ngân sách credit có hạn, account dùng chung với
project khác, và chỉ có một người vận hành.

| Ràng buộc | Ảnh hưởng tới thiết kế |
|---|---|
| **Free plan** chỉ cho chạy loại máy đủ điều kiện | Node `m7i-flex.large`, workstation `t3.small` kèm swap; không chuyển được domain sang Route 53 nên delegate DNS |
| **Credit có hạn** | Chia stack để xoá cluster khi không dùng; một NAT gateway |
| **Account dùng chung** | Tag `project` cho budget; đặt tên mọi thứ theo `medical-rag-*`; tự tạo VPC riêng vì VPC mặc định đã bị xoá subnet |
| **Một người vận hành** | Chạy Terraform từ một workstation thay vì CI; nhiều bước có hướng dẫn và lệnh kiểm tra |
| **Không cài gì lên laptop** | Mọi công cụ nằm trên ops workstation trong AWS, vào bằng Session Manager |

---

## 9. Khó khăn và bài học

**9.1** **Ý chính:** chọn một chuyện có nguyên nhân gốc được chứng minh bằng log. Dưới đây là hai chuyện như vậy;
kể một, giữ chuyện kia nếu được hỏi thêm.

**Chuyện 1: node không kết nối được Session Manager.**
"Sau khi dựng cluster, lệnh ping của Ansible thành công trên node 1 và 3 nhưng node 2 báo `TargetNotConnected`.
Máy vẫn chạy bình thường, nên tôi không khởi động lại ngay mà đi tìm bằng chứng. SSM không có bản ghi nào của
node 2, tức agent chưa từng đăng ký. Tôi đọc log boot qua `get-console-output` và thấy agent báo không lấy được
credential của IAM role, dù role đã được gắn. Nguyên nhân là role vừa được tạo cùng lúc với máy, và credential
chưa kịp sẵn sàng khi agent khởi động; agent sau đó chờ rất lâu mới thử lại. Tôi reboot node để agent lấy lại
credential. Để lỗi không lặp lại ngẫu nhiên ở lần dựng sau, cách sửa là một script lúc boot chờ tới khi có
credential rồi khởi động lại agent."

Lưu ý khi kể: script này mới là đề xuất, chưa có trong repo. Khi đã thêm và dựng lại thành công thì đổi câu cuối
thành "tôi đã thêm…".

**Chuyện 2: Free plan chặn loại máy.**
"Lần launch EC2 đầu tiên lỗi `not eligible for Free Tier` dù account còn credit. Tôi đọc kỹ thì lỗi nói về loại
máy chứ không phải credit. Account đang ở AWS Free plan, gói này chặn mọi loại máy không đủ điều kiện, bất kể
credit. Tôi liệt kê các loại hợp lệ, chọn `m7i-flex.large` đủ 2 vCPU và 8 GB cho node, và ghi lại rủi ro mới: loại
máy này không có metric CPU credit, nên phải cảnh báo theo mức dùng CPU."

**Điểm chung để nhấn mạnh:** đọc đúng thông báo lỗi, tìm bằng chứng trước khi sửa, rồi sửa ở nguyên nhân gốc thay
vì chỉ khởi động lại.

**9.2** **Ý chính:** ưu tiên sửa những điểm yếu đã biết về quyền và độ sẵn sàng, rồi mới thêm tự động hoá.

1. Tách quyền admin của workstation thành role plan và role apply.
2. Cho mỗi workload quyền IAM riêng (IRSA) thay vì dùng chung quyền của node.
3. Tách NAT gateway, WireGuard gateway và node 1 ra khỏi cùng một AZ.
4. Giới hạn cổng 6443 của load balancer nội bộ theo security group của node thay vì cả VPC.
5. Đưa Terraform vào CI: plan trên pull request, credential tạm thời qua OIDC, quét bằng tflint và Checkov.
6. Thêm HTTPS cho app khi có domain.

**9.3** **Ý chính:** kiến trúc giống, nhưng quy mô, quyền hạn và quy trình thì đơn giản hơn nhiều.

| Ở project này | Ở công ty |
|---|---|
| Một account AWS, dùng chung | Nhiều account tách theo môi trường, có chính sách chung toàn tổ chức |
| Một người, apply từ workstation | Apply qua CI, có review, credential tạm thời |
| Tự dựng Kubernetes | Nhiều khả năng dùng EKS |
| Cluster xoá khi không dùng | Chạy liên tục, có SLO và trực sự cố |
| Một NAT gateway | Mỗi AZ một NAT gateway |
| App qua HTTP | HTTPS, WAF |
| VPN bằng key quản lý tay | Truy cập qua hệ thống định danh có MFA |

Nói rõ những khác biệt này cho thấy mình biết đâu là lựa chọn cho lab, đâu là lựa chọn cho production.

**9.4** **Ý chính:** ba bài học lớn.

1. **Thiết kế theo vòng đời và theo ranh giới trách nhiệm.** Tách thứ cần giữ khỏi thứ có thể xoá, và mỗi công
   cụ chỉ sở hữu một lớp, làm hệ thống dễ dựng lại và dễ sửa hơn rất nhiều.
2. **Bằng chứng trước khi sửa.** Các lỗi khó nhất (Free plan, SSM agent, mạng chậm khi build Docker) đều được
   giải quyết nhờ đọc log và đo đạc, không phải nhờ thử khởi động lại.
3. **Ghi rõ đánh đổi.** Một NAT gateway, quyền dùng chung của node, VPN tự quản lý đều là lựa chọn có chủ đích.
   Ghi lại lý do và cách sửa giúp người khác (và chính mình sau này) hiểu vì sao hệ thống như vậy.
