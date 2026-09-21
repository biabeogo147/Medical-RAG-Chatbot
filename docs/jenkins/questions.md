# Câu hỏi về Jenkins

Phase này dựng một pipeline chạy *bên trong* cluster: từ một commit trên GitHub tới một image đã test, đã quét,
đã ký, rồi tới pod dev đang chạy, và một pull request đề nghị prod. Bộ câu hỏi kiểm xem bạn giải thích được vì
sao pipeline được xây theo cách này, nó hỏng ở đâu trong lúc dựng, và giới hạn của nó tới đâu.

Đáp án nằm ở [`answers.md`](answers.md), cùng số thứ tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Phỏng vấn** (ưu tiên) | Bạn kể được một release đi từ đâu tới đâu, vì sao CI tách khỏi CD, build pod lấy quyền AWS bằng cách nào, và ba sự cố đáng kể nhất của phase |
| **B. Chi tiết** | Bạn biết vì sao từng khối trong `Jenkinsfile`, `deploy/argocd/values/jenkins.yaml` và `deploy/argocd/manifests/jenkins/` được viết như vậy, và đổi đi thì cái gì hỏng |

Bộ liên quan: [tổng quan project](../common/questions.md), [Terraform](../terraform/questions.md),
[Ansible](../ansible/questions.md), [GitOps](../gitops/questions.md), [App](../app/questions.md),
[AWS](../aws/questions.md). Tham chiếu dạng `Common A2.3` trỏ tới bộ tương ứng. Câu về Kyverno, Rancher và
chính sách sync của từng môi trường nằm ở `Common B4`; câu về Argo CD nói chung nằm ở bộ GitOps.

**Cách dùng.** Trả lời thành tiếng trước khi mở đáp án. Phần A là thứ bạn nói ra; nếu một câu khiến bạn phải mở
code mới trả lời được thì đó là câu cần học lại. Phần B để tự kiểm, không phải để đọc thuộc.

---

## Phần A — Phỏng vấn

### A1. Tổng quan

**A1.1** Trình bày phase Jenkins trong một tới hai phút.

**A1.2** Từ lúc bạn push code tới lúc prod chạy bản mới, chuyện gì xảy ra?

**A1.3** Phase này bắt đầu từ trạng thái nào? Trước nó, image được build và đưa lên prod bằng cách nào?

**A1.4** Mất bao lâu từ commit tới khi pod dev chạy bản mới? Con số đó chắc tới mức nào?

**A1.5** Phase này chứng minh được điều gì, và điều gì vẫn chỉ là giả định?

### A2. Vì sao Jenkins, và vì sao đặt trong cluster

**A2.1** Vì sao tách CI (Jenkins) và CD (Argo CD)? Sao Jenkins không `kubectl apply` luôn?

**A2.2** Vì sao chọn Jenkins mà không phải GitHub Actions hay GitLab CI?

**A2.3** Jenkins chạy trong chính cluster mà nó build cho. Điều đó được gì và mất gì?

**A2.4** Vì sao Jenkins poll GitHub mỗi 2 phút thay vì dùng webhook?

**A2.5** Jenkins được cài bằng hai Argo CD Application chứ không phải một. Vì sao?

### A3. Danh tính và quyền của build pod

**A3.1** Build pod lấy quyền AWS từ đâu? Kể luồng đó.

**A3.2** Vai trò `medical-rag-ci` được làm những gì, và cố ý *không* được làm gì?

**A3.3** Trong bốn container của build pod, container nào cầm token AWS? Vì sao chỉ một?

**A3.4** Vì sao stage test phải chạy trước stage đăng nhập ECR?

**A3.5** Bạn đã tước quyền push ECR và ký KMS khỏi vai trò của node. Chứng minh nó có tác dụng bằng cách nào?

**A3.6** NetworkPolicy chặn metadata service. Nếu bỏ nó đi thì chuyện gì xảy ra?

### A4. Build image không cần root

**A4.1** Jenkins chạy trong cluster thì build Docker image bằng cách nào?

**A4.2** Vì sao không mount Docker socket của node? Vì sao không Docker-in-Docker? Vì sao không Kaniko?

**A4.3** BuildKit rootless đòi hỏi gì ở namespace, và bạn bù lại bằng gì?

**A4.4** Một bài test độc hại chạy trong pipeline có thể làm được gì?

**A4.5** Cache build nằm ở đâu, và vì sao chỉ `main` được ghi vào nó?

### A5. Supply chain: quét, SBOM, chữ ký

**A5.1** Cổng chặn lỗ hổng dừng build với điều kiện chính xác nào, và vì sao lại là điều kiện đó?

**A5.2** Cổng đó đã bao giờ chặn cái gì chưa? Nếu chưa thì bạn kết luận được gì?

**A5.3** Cosign ký cái gì, bằng key nào? Vì sao ký digest chứ không ký tag?

**A5.4** Chữ ký nằm ở đâu trong ECR, và điều đó ảnh hưởng thế nào tới lifecycle policy?

**A5.5** Vì sao không đẩy chữ ký lên Rekor?

**A5.6** Image đã ký rồi, vậy ai kiểm chữ ký đó?

### A6. Promotion qua Git

**A6.1** Dev và prod được cập nhật khác nhau thế nào?

**A6.2** Jenkins commit ngược vào Git. Làm sao nó không tự kích hoạt chính nó thành vòng lặp vô hạn?

**A6.3** Một commit của bạn tạo ra mấy lần chạy Jenkins? Vì sao chỉ một lần xanh hết?

**A6.4** Vì sao image được ghi bằng digest chứ không chỉ bằng tag?

**A6.5** Bản mới trên prod bị lỗi thì rollback thế nào?

**A6.6** "Prod chỉ đổi qua pull request" — điều đó được bảo đảm bằng cái gì?

### A7. Vận hành và số đo

**A7.1** Ba node còn bao nhiêu CPU, và điều đó quyết định gì trong thiết kế pipeline?

**A7.2** Mật khẩu admin của Jenkins nằm ở đâu? Dựng lại cluster thì nó ra sao?

**A7.3** Cấu hình của controller nằm ở đâu? Nếu mất cả cluster thì khôi phục thế nào?

**A7.4** Bạn theo dõi pipeline bằng gì? Số nào bạn thực sự đo được?

**A7.5** Một build đỏ thì bạn làm gì, theo thứ tự nào?

**A7.6** Phase này tốn thêm bao nhiêu tiền mỗi tháng?

### A8. Sự cố và bài học

**A8.1** Kể sự cố tốn kém nhất của phase này.

**A8.2** Có một credential bị lộ trong phase này. Chuyện gì đã xảy ra, và bạn xử lý thế nào?

**A8.3** Trong phase có năm phép kiểm "đạt" trong khi thứ chúng canh thì hỏng. Kể một cái và nói vì sao nó lọt.

**A8.4** Có lệnh nào trong guide không chạy được không? Vì sao chỉ lộ ra khi chạy thật?

**A8.5** Bạn đã chẩn đoán sai điều gì, và điều gì làm bạn nhận ra?

**A8.6** Vì sao phải push nhiều lần mới thử được một thay đổi của pipeline?

**A8.7** Một phép sửa ở bước này từng suýt phá bước khác. Kể lại.

### A9. Nhìn lại

**A9.1** Làm lại phase này thì bạn đổi gì trước tiên?

**A9.2** Điểm yếu lớn nhất của pipeline hiện tại là gì?

**A9.3** Pipeline này đưa vào công ty thật thì phải đổi những gì?

**A9.4** Phần nào của phase này bạn sẽ giữ nguyên nếu làm lại từ đầu?

---

## Phần B — Chi tiết

Đáp án ngắn, để tự kiểm. Căn cứ chính: `Jenkinsfile`, `deploy/argocd/values/jenkins.yaml`,
`deploy/argocd/manifests/jenkins/`, `infra/terraform/shared/irsa.tf` và `docs/evidence/jenkins.md`.

### B1. `Jenkinsfile`

**B1.1** Kể mười stage theo thứ tự. Stage nào là cổng chặn có chủ đích?

**B1.2** Stage nào chỉ chạy trên `main`? Một build trên nhánh chạy mấy stage?

**B1.3** Vì sao stage gắn tag `release-` đứng *trên* skip guard chứ không đứng dưới?

**B1.4** Skip guard kiểm những điều kiện gì? Danh sách file rỗng thì nó xử lý ra sao, và vì sao?

**B1.5** Cổng chặn Trivy được viết bằng `jq` chứ không bằng cờ của `trivy`. Vì sao?

**B1.6** Trong pod template, `automountServiceAccountToken: false` để làm gì khi pod vẫn có token?

**B1.7** `set +x` trong stage đăng nhập ECR để làm gì?

**B1.8** Stage `Index version` làm gì, và nó *không* làm gì?

### B2. Chart và `values/jenkins.yaml`

**B2.1** `installLatestPlugins: false` thay đổi cách phân giải phiên bản plugin thế nào?

**B2.2** Job Multibranch được định nghĩa ở đâu, và nó theo dõi những branch nào?

**B2.3** `containerCap: 1` nằm ở đâu và chặn điều gì?

**B2.4** `controller.admin.existingSecret` trỏ tới đâu, và ai tạo ra secret đó?

**B2.5** Vì sao controller đặt `numExecutors: 0`?

**B2.6** Chart Jenkins được ghim phiên bản nào, và phiên bản core thực tế đang chạy là bao nhiêu?

### B3. `manifests/jenkins/`

**B3.1** Thư mục đó có những file nào, và mỗi file tạo ra cái gì?

**B3.2** Hai namespace đặt mức Pod Security nào, và vì sao khác nhau?

**B3.3** ValidatingAdmissionPolicy chặn những gì? Đã thử được mấy luật trong số đó?

**B3.4** NetworkPolicy cho phép những đường nào ra ngoài?

**B3.5** Secret `jenkins-github` đi từ đâu tới đâu?

**B3.6** Vì sao `jenkins-platform` phải ở wave trước `jenkins`?

### B4. IAM, ECR và KMS

**B4.1** Trust policy của `medical-rag-ci` tin đúng cái gì?

**B4.2** Liệt kê từng quyền của `medical-rag-ci`.

**B4.3** Sau bước 18, vai trò node còn quyền gì trên ECR và KMS?

**B4.4** Repository ECR có mấy cái, và lifecycle policy của mỗi cái là gì?

**B4.5** Vì sao tag được đặt immutable nhưng lại có hai ngoại lệ?

**B4.6** Mười tag cùng trỏ vào một digest thì lifecycle policy đếm là mấy?

### B5. Cổng chặn và kiểm tra

**B5.1** Trivy quét mấy lần trong một build, và báo cáo đi đâu?

**B5.2** `cosign verify` được chạy với tham số gì, và nó từ chối cái gì?

**B5.3** Stage `Index version` so sánh cái gì với cái gì, và dừng khi nào?

**B5.4** Phép kiểm plugin của guide là gì, và vì sao nó không thấy bộ plugin bị tách?

**B5.5** Làm sao biết build pod thật sự dùng vai trò CI chứ không phải vai trò node?

### B6. Evidence

**B6.1** Tiêu chí #8, #9 và #10 của design được đo bằng con số nào?

**B6.2** Số nào trong phase này là "mềm", và mềm vì lý do gì?

**B6.3** Phase ghi nhận bao nhiêu khiếm khuyết, và chúng thuộc mấy dạng?

**B6.4** Evidence của phase này còn thiếu gì, và bạn sẽ đo nó thế nào?
