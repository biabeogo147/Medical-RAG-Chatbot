# Câu hỏi về AWS

Bộ câu hỏi về các dịch vụ AWS mà project dùng, và **khác biệt so với chạy on-premises**. Bộ này xuyên suốt mọi phase:
Terraform, Ansible, app và GitOps. Đáp án nằm ở [`answers.md`](answers.md), cùng số thứ tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Phỏng vấn** (ưu tiên) | Bạn giải thích được vì sao dùng từng dịch vụ AWS, nó thay thế thứ gì ở on-premises, và đánh đổi là gì |
| **B. Chi tiết** | Bạn hiểu các dịch vụ đó thực sự hoạt động thế nào ở mức cơ chế, giới hạn và giá |

Bộ liên quan: [tổng quan project](../common/questions.md), [Terraform](../terraform/questions.md),
[Ansible](../ansible/questions.md). Tham chiếu dạng `Terraform A1.1` trỏ tới bộ tương ứng. Bộ này sẽ được bổ sung khi các
phase sau hoàn thành.

**Cách dùng.** Làm Phần A trước: trả lời thành tiếng, khoảng một phút mỗi câu, rồi so với đáp án. Với mỗi dịch vụ, tập nói
được cả hai vế: nó làm gì trên AWS, và ở on-premises bạn sẽ dựng thứ gì thay thế.

---

## Phần A — Phỏng vấn

### A1. Cloud và on-premises

**A1.1** Trình bày phần AWS của project trong một phút: dùng những dịch vụ nào, và vì sao.

**A1.2** Mô hình trách nhiệm chung áp vào project này thế nào: AWS lo gì, bạn lo gì? Khác gì khi chạy on-premises?

**A1.3** Dựng đúng kiến trúc này ở on-premises thì mỗi dịch vụ AWS được thay bằng gì?

**A1.4** Scripts cũ của project dựng cluster on-premises bằng bash và IP cố định. Lên AWS thì việc gì dễ hơn, việc gì khó
hơn?

**A1.5** Vì sao chọn AWS mà không phải GCP hay Azure?

**A1.6** Khi nào bạn chọn EKS và dịch vụ managed, khi nào tự dựng trên EC2, và khi nào on-premises mới là lựa chọn đúng?

### A2. Mạng

**A2.1** VPC, subnet và Availability Zone tương ứng với gì trong một datacenter? Vì sao trải ba AZ?

**A2.2** Node nằm ở subnet private ra internet bằng cách nào? So NAT gateway với NAT ở firewall on-premises.

**A2.3** Security group khác firewall truyền thống thế nào?

**A2.4** Kubernetes HA on-premises thường dùng VIP với keepalived hoặc kube-vip. Ở đây dùng NLB. Khác nhau thế nào?

**A2.5** Cluster không cài AWS cloud controller manager. Bạn mất những gì?

**A2.6** Vì sao pod IP không định tuyến được trong VPC, và AWS VPC CNI giải quyết điều đó thế nào?

**A2.7** Chi phí truyền dữ liệu ảnh hưởng thiết kế mạng thế nào? On-premises có tương đương không?

**A2.8** Người vận hành vào mạng private bằng WireGuard tự dựng. So với Client VPN, site-to-site VPN hay Direct Connect?

**A2.9** DNS của project hoạt động thế nào, và khác split-horizon DNS on-premises ra sao?

### A3. Danh tính và bảo mật

**A3.1** Không máy nào có access key. Credential đến từ đâu, và on-premises làm điều tương tự thế nào?

**A3.2** IMDSv2 bảo vệ khỏi gì? Vì sao node lại để hop limit 2?

**A3.3** Session Manager thay bastion và SSH. Được gì về bảo mật và audit?

**A3.4** Ký image bằng KMS khác gì giữ private key trong CI hoặc dùng HSM on-premises?

**A3.5** Vì sao secret nằm ở Secrets Manager, không phải Kubernetes Secret thuần hay HashiCorp Vault?

**A3.6** EKS có IRSA và Pod Identity. Cluster tự dựng trên EC2 thiếu gì, và bù thế nào?

**A3.7** Làm sao biết ai đã làm gì trên account AWS này?

**A3.8** AWS đánh giá quyền của một request thế nào? Permission boundary, SCP và role cross-account dùng khi nào?

**A3.9** Dữ liệu trong project được mã hoá ở đâu, bằng key nào? Khi nào đáng dùng customer managed key?

### A4. Compute và lưu trữ

**A4.1** Bạn chọn loại EC2 thế nào? Khác gì lên kế hoạch phần cứng on-premises?

**A4.2** etcd và PersistentVolume dùng EBS. So với đĩa local và SAN on-premises?

**A4.3** S3 được dùng vào những việc gì, và vì sao không dùng NFS hay MinIO?

**A4.4** Vì sao dùng ECR mà không dùng Docker Hub hay Harbor tự host?

**A4.5** Thay một máy trên AWS khác thay một máy vật lý thế nào? Stop, reboot và terminate giữ lại những gì?

### A5. Chi phí, giới hạn và rủi ro

**A5.1** Xoá cluster khi không dùng là điều chỉ cloud làm được. Nó tiết kiệm bao nhiêu, và đổi lại gì?

**A5.2** Bạn theo dõi và chặn chi phí thế nào? On-premises tính chi phí khác ra sao?

**A5.3** Quota và giới hạn nào của AWS có thể chặn project?

**A5.4** Project phụ thuộc AWS tới đâu? Rủi ro vendor lock-in và rủi ro của chính account là gì?

**A5.5** Một AZ sập, hoặc cả region sập, thì hệ thống chịu thế nào? So với mất một rack hay một datacenter?

**A5.6** Nếu phải chuyển project sang on-premises, phần nào mang đi được, phần nào phải viết lại?

**A5.7** Ngoài việc xoá cluster, còn những cách tối ưu chi phí nào trên AWS, và cách nào hợp với project này?

### A6. Độ tin cậy, dữ liệu và tổ chức

**A6.1** RPO và RTO của project là bao nhiêu? Bạn chọn chiến lược khôi phục nào trên AWS?

**A6.2** Bạn quan sát hệ thống bằng CloudWatch hay Prometheus? Ai báo động khi chính cluster chết?

**A6.3** AWS gặp sự cố. Bạn biết bằng cách nào, và làm gì?

**A6.4** Đây là chatbot y khoa. Region, nơi lưu dữ liệu và tuân thủ ảnh hưởng thiết kế thế nào?

**A6.5** Ở công ty có nhiều team và nhiều môi trường, bạn tổ chức account AWS thế nào?

**A6.6** Kể một lần AWS làm bạn bất ngờ.

**A6.7** Nhìn theo AWS Well-Architected, trụ cột nào của project yếu nhất?

---

## Phần B — Chi tiết

### B1. VPC và mạng

**B1.1** Trong AWS, điều gì làm một subnet trở thành public? Chỉ ra cái gì làm `10.10.101.0/24` là public
và `10.10.1.0/24` là private.

**B1.2** Security group và network ACL: project này dựa vào cái nào, cái nào là stateful, và module VPC
làm gì với NACL và security group mặc định?

**B1.3** NAT gateway nằm ở đâu, vì sao nó cần Elastic IP, và nó tính tiền những gì?

**B1.4** Gateway endpoint và interface endpoint khác nhau thế nào về cách định tuyến, giá và các dịch vụ
hỗ trợ?

**B1.5** Khi cluster đang chạy, project giữ bao nhiêu địa chỉ IPv4 public, và vì sao chúng xuất hiện
trên hoá đơn?

**B1.6** Subnet `/28` của workstation có bao nhiêu địa chỉ dùng được?

**B1.7** `ap-southeast-1a` trong account này và `ap-southeast-1a` trong account khác có phải cùng một
datacenter không? Khi nào điều đó quan trọng?

**B1.8** Gateway endpoint của S3 có policy riêng không? Vì sao node vẫn phải qua NAT để tới bucket ở region khác, và để
gọi API của ECR?

### B2. Cân bằng tải

**B2.1** So sánh NLB và ALB: tầng OSI, cách xử lý TLS, IP nguồn, địa chỉ cố định, security group.

**B2.2** Cả hai NLB đều bật cross-zone load balancing. Nó thay đổi điều gì, và trên NLB thì tốn thêm gì?

**B2.3** Khi API server trên một node chết, khi node bị stop, và khi node bị deregister khỏi target group, các
kết nối đang mở tới nó ra sao?

**B2.4** Health check của hai target group được cấu hình thế nào? Khi mọi target đều unhealthy thì NLB làm gì, và health
check đi qua security group theo chiều nào?

**B2.5** Target group có ba kiểu: `instance`, `ip` và `alb`. Project dùng kiểu nào, và vì sao không trỏ thẳng vào pod?

**B2.6** NLB giữ một kết nối TCP rảnh bao lâu? Điều đó ảnh hưởng gì tới `kubectl --watch` hay agent của Rancher?

**B2.7** Health check TCP trên NodePort 30080 thật sự kiểm tra gì về ingress-nginx trên từng node?

### B3. Compute và lưu trữ

**B3.1** Credential của instance role tới được một process trên máy bằng cách nào, và có hiệu lực bao
lâu?

**B3.2** IMDSv2 chặn được kiểu tấn công nào mà IMDSv1 không chặn được?

**B3.3** Instance profile và role khác nhau thế nào: vì sao EC2 cần cả hai, và quyền nào cho phép một
identity gắn role vào instance?

**B3.4** Khi Terraform xoá một node, ổ EBS gốc của nó và dữ liệu etcd trên đó ra sao?

**B3.5** etcd rất nhạy với độ trễ ghi đĩa. Vì sao ổ 40 GB của node dùng gp3 chứ không phải gp2?

**B3.6** `m7i-flex.large` và `t3.large` xử lý CPU burst khác nhau thế nào, và vì sao điều đó quan trọng
với việc monitoring?

**B3.7** EC2 có những loại status check nào? Mỗi loại phát hiện gì, và vì sao node 2 qua hết mà vẫn không vào được
Session Manager?

**B3.8** `m7i-flex.large` không có ở một AZ, hoặc AZ đó tạm hết máy. `make infra` ra sao, và code nên chọn AZ thế
nào?

### B4. IAM, mã hoá và secret

**B4.1** Trust policy và permissions policy: cái nào nói "EC2 được dùng role này"?

**B4.2** Bucket policy chỉ cho phép TLS là một `Deny`, còn role của node có `Allow` trên `s3:GetObject`.
Hãy đi qua cách AWS đánh giá một request HTTP thường (không TLS) từ node.

**B4.3** AWS managed policy, customer managed policy và inline policy: project này dùng loại nào ở đâu,
và vì sao?

**B4.4** Terraform tạo role và instance profile rồi launch instance với nó, và thỉnh thoảng lệnh launch
lỗi `Invalid IAM Instance Profile`. Vì sao?

**B4.5** Rotation của KMS key bất đối xứng có gì khác, và cosign key tốn bao nhiêu?

**B4.6** Secrets Manager và SSM Parameter Store `SecureString`: nếu dùng Parameter Store thì những gì thay
đổi?

**B4.7** S3 giờ mặc định mã hoá mọi object mới, có strong consistency và conditional write. Ba điều này
thể hiện thế nào trong code Terraform của project?

**B4.8** SSM agent cần những gì để một máy xuất hiện trong Session Manager? Default Host Management Configuration là gì?

**B4.9** Ansible truyền file module tới node qua S3 bằng presigned URL. Ai cần quyền S3, và presigned URL an toàn tới đâu?

**B4.10** Token đăng nhập ECR sống bao lâu? IAM policy và repository policy của ECR khác nhau thế nào?

**B4.11** KMS key policy và IAM policy quan hệ với nhau thế nào? Vì sao `kms:Sign` trong policy của node là đủ để
ký, và muốn chỉ CI được ký thì cluster tự dựng này thiếu gì?

**B4.12** Secrets Manager giữ version của secret thế nào? `put-secret-value` và External Secrets tương tác ra sao?

**B4.13** Một pod lấy trộm được credential của role node và mang ra ngoài. Có cách nào làm credential đó vô dụng ở
ngoài VPC không?

### B5. DNS

**B5.1** Vì sao record `rancher` dùng Route 53 alias mà không dùng CNAME?

**B5.2** Delegate `recruitai.io.vn` sang Route 53: record NS nào đổi ở đâu, vì sao việc chuyển có thể mất
hàng giờ, và vì sao phải tắt DNSSEC trước?

**B5.3** Vì sao một hosted zone được tạo lại lại nhận name server khác, và AWS có cách nào tránh điều đó?

**B5.4** Sectigo xác minh bạn kiểm soát `rancher.recruitai.io.vn` bằng cách nào, và điều gì có thể chặn
việc cấp certificate?

### B6. Account, chi phí và vận hành

**B6.1** AWS Free plan giới hạn những gì, chuyện gì xảy ra khi nó kết thúc, và bạn giữ state cùng các
shared resource thế nào trước thời điểm đó?

**B6.2** Cost allocation tag đi tới budget bằng cách nào?

**B6.3** CloudShell giữ lại gì giữa các phiên, và vì sao đó là nơi tệ để giữ state của Terraform?

**B6.4** Nếu account dùng chung ngày càng nhiều project, quota mặc định nào có thể chặn `make infra`?

**B6.5** Bạn tìm ở đâu để biết ai đã xoá một rule security group vào thứ Ba tuần trước?
