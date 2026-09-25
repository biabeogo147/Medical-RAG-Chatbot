# Câu hỏi tổng quan về project

Bộ câu hỏi để giải thích project cho người phỏng vấn: project làm gì, vì sao thiết kế như vậy, kết quả ra sao và
còn giới hạn gì. Câu hỏi không giới hạn trong một công cụ. Đáp án nằm ở [`answers.md`](answers.md), cùng số thứ
tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Phỏng vấn** (ưu tiên) | Bạn kể được project làm gì, vì sao thiết kế như vậy, xử lý tình huống thế nào, kết quả và giới hạn |
| **B. Chi tiết** | Bạn nắm các con số, luồng đi và cơ chế xuyên suốt project: port, CIDR, probe, pipeline, secret |

Các bộ câu hỏi chuyên sâu: [Terraform](../terraform/questions.md), [Ansible](../ansible/questions.md),
[Argo CD và GitOps](../gitops/questions.md), [AWS và khác biệt với on-premises](../aws/questions.md).

**Cách dùng.** Làm Phần A trước: trả lời thành tiếng trong khoảng một phút mỗi câu, rồi so với đáp án. Các nhóm
đi từ tổng quan tới chi tiết, rồi tình huống, cuối cùng là bài học. Người phỏng vấn có thể nhảy cóc, nên mỗi đáp
án tự đứng được. Phần B dùng để tự kiểm tra: không mở tài liệu, nói được con số và lý do.

---

## Phần A — Phỏng vấn

### A1. Giới thiệu

**A1.1** Giới thiệu project trong một phút.

**A1.2** App này làm gì cho người dùng, và bên trong nó trả lời một câu hỏi như thế nào?

**A1.3** Phần việc chính của bạn trong project là gì?

**A1.4** Vì sao bạn làm project này, và bạn muốn chứng minh điều gì?

**A1.5** Project gồm những phase nào, và bạn làm theo thứ tự nào?

**A1.6** Bạn làm một mình hay theo nhóm? Mất bao lâu?

**A1.7** Phần code app có phải bạn viết từ đầu không?

### A2. Kiến trúc tổng thể

**A2.1** Mô tả kiến trúc tổng thể: có những thành phần nào và chúng nối với nhau ra sao?

**A2.2** Một người dùng gõ câu hỏi. Request đi qua những đâu cho tới khi có câu trả lời?

**A2.3** Terraform, Ansible, Argo CD và Jenkins mỗi công cụ lo phần nào? Vì sao phải chia ranh giới rõ như
vậy?

**A2.4** Vì sao tự dựng Kubernetes bằng kubeadm trên EC2 mà không dùng EKS?

**A2.5** App nhỏ như vậy có cần Kubernetes không?

**A2.6** Môi trường dev và prod được tách ra thế nào?

### A3. Ứng dụng và dữ liệu

**A3.1** Bản app ban đầu có những vấn đề gì khi đem ra chạy thật?

**A3.2** FAISS index được tạo và quản lý thế nào? Muốn quay về index cũ thì làm sao?

**A3.3** `/healthz` và `/readyz` khác nhau thế nào, và vì sao cần cả hai?

**A3.4** App phụ thuộc Hugging Face và Gemini. Khi các API đó lỗi hoặc giới hạn tốc độ thì chuyện gì xảy ra?

**A3.5** Bạn đã làm gì với Docker image, và kết quả đo được là gì?

**A3.6** Vì sao dùng RAG mà không fine-tune model?

**A3.7** Làm sao biết câu trả lời của chatbot là đúng? Có đánh giá chất lượng không?

**A3.8** Dữ liệu y tế có vấn đề riêng tư không? Câu hỏi của người dùng có bị lưu hay gửi ra ngoài không?

### A4. Hạ tầng và cluster

**A4.1** Nói ngắn gọn: hạ tầng trên AWS gồm những gì?

**A4.2** Vì sao bạn xoá cluster khi không dùng, và dựng lại nhanh bằng cách nào?

**A4.3** Bạn vào máy chủ và vào Kubernetes API bằng cách nào, khi không có SSH?

**A4.4** Cluster chịu lỗi thế nào? Mất một node thì sao?

**A4.5** Rancher được truy cập thế nào, và vì sao không mở nó ra internet?

**A4.6** Traffic tăng gấp 10 lần thì hệ thống chịu thế nào? Scale ở đâu, nghẽn ở đâu?

### A5. Rancher và ranh giới giữa các công cụ

Câu về pipeline Jenkins đã chuyển sang bộ riêng: [Jenkins](../jenkins/questions.md).

**A5.1** Đã có Argo CD và kubectl, sao còn cần Rancher?

### A6. Bảo mật

**A6.1** Secret như API key đi từ đâu tới pod, và làm sao nó không lọt vào Git?

**A6.2** Làm sao bạn chắc image đang chạy trên prod đúng là image đã được build, quét và ký?

**A6.3** Những gì đang mở ra internet, và nguyên tắc bảo mật chung của project là gì?

**A6.4** Project còn những điểm yếu bảo mật nào mà bạn biết?

### A7. Vận hành ngày 2 và quan sát

**A7.1** Bạn theo dõi app và cluster thế nào? App xuất ra những metric gì?

**A7.2** Backup và khôi phục cluster thế nào?

**A7.3** Nâng cấp phiên bản Kubernetes thế nào mà không làm app ngừng?

**A7.4** Làm sao chứng minh những gì bạn kể là đã chạy thật?

**A7.5** App lỗi lúc 2 giờ sáng thì bạn biết bằng cách nào? Có alert không?

### A8. Chi phí và ràng buộc

**A8.1** Project tốn bao nhiêu tiền, và bạn kiểm soát chi phí thế nào?

**A8.2** Những ràng buộc nào đã định hình thiết kế?

### A9. Tình huống

**A9.1** Mọi người dùng đều nhận lỗi 502 hoặc 504. Bạn xử lý thế nào, từng bước?

**A9.2** Prod đang lỗi và cần hotfix gấp. Bạn có sửa thẳng trên cluster không? Còn khi đổi một secret, hoặc khi
ai đó đã `kubectl edit` trên prod?

**A9.3** Đem nguyên hệ thống này ra chạy production thật, cái gì hỏng đầu tiên?

**A9.4** Kẻ tấn công chiếm được một pod của app. Họ đi được tới đâu?

**A9.5** Đổi model Gemini, sửa prompt hoặc đổi model embedding thì deploy và rollback thế nào? Bạn theo dõi
token và độ trễ ra sao?

**A9.6** Bạn đặt SLO gì cho app này?

**A9.7** Chiến lược test của cả project là gì? Còn thiếu gì?

**A9.8** Một người khác tiếp quản hệ thống. Họ đọc gì đầu tiên?

**A9.9** Hệ thống này tốn bao nhiêu công vận hành mỗi tháng? Có đáng không?

### A10. Khó khăn và bài học

**A10.1** Kể về vấn đề khó nhất bạn gặp và cách bạn tìm ra nguyên nhân.

**A10.2** Kể về một sai lầm của bạn trong project.

**A10.3** Timebox chỉ có ba ngày. Bạn đã cắt gì, và vì sao?

**A10.4** Phần nào bạn tự quyết định, phần nào tham khảo? Bạn có dùng AI không?

**A10.5** Nếu làm lại hoặc có thêm thời gian, bạn sẽ thay đổi gì?

**A10.6** Project này khác gì so với một hệ thống production thật ở công ty?

**A10.7** Bạn học được gì từ project này?

---

## Phần B — Chi tiết

### B1. Mạng và luồng request

**B1.1** Pod CIDR và Service CIDR được chọn thế nào so với các dải của VPC? Có cặp dải nào đang trùng không?

**B1.2** Một request của người dùng đi qua những port nào, từ NLB tới process trong container? ingress-nginx có
thấy IP thật của người dùng không?

**B1.3** Người vận hành mở Rancher. TLS được terminate ở đâu, và vì sao không ở load balancer?

**B1.4** `kubectl` trên workstation tới Kubernetes API bằng đường nào? Vì sao certificate của API server phải
có `127.0.0.1`?

**B1.5** Dev và prod chia một public NLB thế nào? Probe và Prometheus gọi pod của hai môi trường bằng path nào?

**B1.6** NetworkPolicy của namespace app cho gì đi vào, gì đi ra? Pod nào trong namespace đó lại cần quyền AWS?

### B2. App và index

**B2.1** Version của index được tính từ những gì? Đổi tên file PDF mà không đổi nội dung thì version có đổi
không?

**B2.2** Job build index chạy lúc nào trong một lần sync của Argo CD, và làm sao lần sync thứ hai không embed
lại?

**B2.3** Pod lấy index vào bằng cách nào, index nằm ở đâu trong container, và vì sao values ghi version cụ thể
chứ không dùng con trỏ `LATEST`?

**B2.4** Lúc build index, embedding được gửi thế nào và thử lại ra sao? Lỗi nào không được thử lại?

**B2.5** Mỗi worker gunicorn dựng RAG chain thế nào? Pod `Ready` có nghĩa là gì, và không có nghĩa là gì?

**B2.6** Ba probe của pod app trỏ vào endpoint nào? Startup probe giới hạn 5 phút đánh đổi điều gì?

**B2.7** Vì sao metric cần `PROMETHEUS_MULTIPROC_DIR`, vì sao `start.sh` xoá thư mục đó mỗi lần khởi động, và
`child_exit` trong `gunicorn.conf.py` thực sự làm gì?

**B2.8** Lịch sử chat nằm ở đâu, giữ bao nhiêu tin? Cookie session của dev và prod có ảnh hưởng nhau không?

**B2.9** Câu trả lời của Gemini được đưa vào HTML thế nào để không thành lỗ XSS?

**B2.10** Ai tính `index.version` để ghi vào values, và file PDF tới Job build index bằng đường nào?

### B3. Container và manifest

**B3.1** Image runtime dựa trên gì, chạy bằng user nào, và những gì cố ý không có trong image?

**B3.2** Root filesystem chỉ đọc. App còn phải ghi vào đâu, và những cài đặt nào đưa mọi thứ ghi vào đó?

**B3.3** App dev chỉ có 1 replica. Nếu chart cũng tạo PodDisruptionBudget `minAvailable: 1` cho dev thì chuyện gì
xảy ra khi nâng cấp node?

**B3.4** Mất một node đột ngột khác drain một node thế nào? PodDisruptionBudget và `maxUnavailable: 0` giúp ở
trường hợp nào?

**B3.5** Values trỏ tới một version index chưa có trên S3. Kể từng bước chuyện gì xảy ra, trong hai trường hợp: version đó
là version mới hợp lệ, và version bị gõ sai.

**B3.6** Node pull image từ ECR mà không có `imagePullSecrets`. Cơ chế nào làm việc đó?

### B4. Kyverno, Rancher và chính sách từng môi trường

Câu về `Jenkinsfile`, cổng chặn Trivy, cosign và skip guard nằm ở [Jenkins](../jenkins/questions.md) phần B.

**B4.1** Dev và prod khác nhau thế nào ở sync policy của Argo CD và ở chế độ của Kyverno?

**B4.2** Kyverno kiểm tra chữ ký của những image nào? Image nào chạy trong cluster mà không được kiểm tra?

**B4.3** Rancher được cài theo sync wave nào, và vì sao không đặt `bootstrapPassword` trong values?

### B5. Secret và quyền

**B5.1** Các secret trong Secrets Manager là gì, ai đọc được cái nào? Có secret nào của hệ thống không nằm trong
Secrets Manager không?

**B5.2** Jenkins không có quyền deploy vào cluster. Vậy cụ thể nó có những quyền gì, trên AWS, trên Kubernetes
và trên GitHub?

**B5.3** Những pod nào được phép gọi metadata service? NetworkPolicy có thật sự chặn được mọi pod khác không?

**B5.4** Snapshot etcd chứa những gì, và ai đọc được nó?

### B6. Vận hành

**B6.1** `make up` và `make down` chạy những gì theo thứ tự? `make down` có để lại EBS volume nào không?

**B6.2** CronJob backup etcd chạy ở đâu, cần gì để nói chuyện với etcd, bao lâu một lần, và snapshot được giữ bao
lâu? Khôi phục cần thêm gì ngoài snapshot?

**B6.3** Trước khi đổi minor Kubernetes, bạn kiểm tra những gì và theo thứ tự nào?

**B6.4** Cảnh báo CPU cho node `m7i-flex` dựa trên metric nào, và vì sao ngưỡng không nên là 80%?

**B6.5** Ba node 8 GB chạy cả control plane, Jenkins, Prometheus, Rancher và app. Những cài đặt nào giữ cho
chúng không hết bộ nhớ, và còn thiếu gì?

**B6.6** Các addon như ingress-nginx, Calico, Kyverno cũng có ma trận phiên bản. Vì sao cổng kiểm tra trước khi
nâng cấp không nên chỉ xét Rancher?
