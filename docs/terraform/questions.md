# Câu hỏi về Terraform

Bộ câu hỏi về phần Terraform của project, dùng để tự kiểm tra mức hiểu và luyện phỏng vấn. Đáp án
nằm ở [`answers.md`](answers.md), cùng số thứ tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Code** | Bạn biết vì sao từng block được viết như vậy, và đổi đi thì cái gì hỏng |
| **B. Phỏng vấn** | Bạn giải thích được kiến trúc, bảo vệ được lựa chọn và nói rõ giới hạn của nó |
| **C. AWS phía sau code** | Bạn hiểu các dịch vụ AWS mà Terraform tạo ra thực sự hoạt động thế nào |

**Cách dùng.** Trả lời thành tiếng, không mở code, rồi so với đáp án. Chỉ tính là đã hiểu khi bạn nói
được *lý do*, không chỉ nêu sự kiện. Trong mỗi nhóm, câu hỏi khó dần về cuối.

---

## Phần A — Code

### A1. State và backend

**A1.1** Stack bootstrap tạo ra chính bucket lưu state của nó. Việc đó diễn ra theo thứ tự nào, và
nếu `bootstrap/backend.tf` đã có sẵn ở lần apply đầu tiên thì cái gì sẽ lỗi?

**A1.2** Cả ba file `backend.tf` đều không khai báo `bucket` và `region`. Vì sao, và hai giá trị này đến
từ đâu khi chạy trên workstation và trong CloudShell?

**A1.3** `use_lockfile = true` làm gì, nó thay thế cái gì, và người thứ hai thấy gì khi hai lệnh
`make infra` chạy cùng lúc? Gỡ lock do một lần chạy bị crash để lại bằng cách nào?

**A1.4** Bucket state có versioning, `noncurrent_version_expiration` 90 ngày và
`abort_incomplete_multipart_upload`. Mỗi cái bảo vệ khỏi điều gì? Nếu state của cluster bị ghi hỏng thì
khôi phục thế nào?

**A1.5** `aws_s3_bucket_policy.state` có `depends_on` tới public access block, còn
`aws_s3_bucket_versioning.state` thì không có `depends_on` nào. Vì sao lại khác nhau?

**A1.6** State của ba stack hiện chứa những thông tin nhạy cảm nào, và những lựa chọn thiết kế nào giữ
giá trị secret nằm ngoài state?

**A1.7** `shared/` và `cluster/` có commit `.terraform.lock.hcl`, còn `bootstrap/` thì không. Lock file
ghim được điều gì mà `version = "~> 6.64"` không ghim được, và stack bootstrap gặp rủi ro gì?

### A2. Các stack và cách chúng nối với nhau

**A2.1** Chọn một resource trong mỗi stack và giải thích, dựa vào vòng đời của nó, vì sao nó không thể
nằm ở một trong hai stack còn lại.

**A2.2** Stack cluster tìm resource của shared bằng `data` source theo tên, không dùng
`terraform_remote_state`. Nêu một ưu điểm và một điểm yếu của cách này.

**A2.3** Trên một account chưa từng chạy `make shared`, bạn chạy `make infra`. Nó lỗi ở thời điểm nào, và
hành vi đó tốt hay xấu?

**A2.4** Có cả `shared/rancher.tf` lẫn `cluster/rancher.tf`. File nào sở hữu hosted zone, file nào sở hữu
các record? Nếu chuyển zone sang stack cluster thì chuyện gì xảy ra?

**A2.5** Workstation có `AdministratorAccess`, vậy mà stack bootstrap chỉ được apply từ CloudShell. Vì
sao?

**A2.6** Makefile và Ansible lấy DNS name của NLB, instance ID của gateway từ Terraform bằng cách nào? Nếu
ai đó đổi tên một output thì cái gì hỏng, và hỏng lúc nào?

### A3. Lifecycle và các lớp bảo vệ

**A3.1** So sánh `prevent_destroy` trên bucket state, việc không có `force_destroy` trên bucket
artifacts, và `force_destroy = true` trên hai bucket của cluster. `make infra-destroy` làm gì với từng
bucket? Vì sao mất snapshot etcd sau mỗi lần teardown vẫn chấp nhận được?

**A3.2** Route 53 zone có `prevent_destroy`. Hãy mô tả một cách để Terraform vẫn xoá được nó mà không
báo lỗi gì. Khi zone còn chứa record, AWS thêm lớp bảo vệ thứ hai nào?

**A3.3** Vì sao các secret dùng `recovery_window_in_days = 7`? Bạn đổi tên `"rancher-tls"` trong tập
`for_each`, apply, rồi đổi ý và đổi lại tên cũ. Chuyện gì xảy ra ở mỗi lần apply?

**A3.4** Node có `ignore_changes = [ami]`, workstation có `[ami, user_data]`, còn gateway chỉ có
`[ami]`. Giải thích từng lựa chọn. AMI không bao giờ được ghim: điều đó ảnh hưởng thế nào tới tính
"tái tạo được"?

**A3.5** Vì sao gateway đặt `user_data_replace_on_change = true`? Bỏ nó đi rồi sửa `wireguard-init.sh`
và apply thì chuyện gì xảy ra?

**A3.6** Vì sao `aws_instance.workstation` cần `depends_on = [aws_route_table_association.ops_public]`?
WireGuard gateway có gặp rủi ro tương tự không?

**A3.7** Sau phase GitOps, EBS CSI driver tạo volume cho Jenkins và Prometheus. Những volume đó có nằm
trong state không? `make infra-destroy` xử lý chúng thế nào, và vì sao destroy đôi khi bị treo ở bước
xoá subnet hoặc security group?

### A4. Mạng

**A4.1** Tính sáu CIDR subnet của cluster từ `cidrsubnet(var.vpc_cidr, 8, i + 1)` và `i + 101`. Chúng
không được trùng với những dải nào khác, và vì sao trùng dải lại là vấn đề?

**A4.2** Vì sao phần tra cứu AZ lọc theo `opt-in-not-required`? Nếu `node_count = 4` thì node 4 nằm ở
đâu, và etcd 4 member có chịu lỗi tốt hơn 3 member không?

**A4.3** S3 gateway endpoint chỉ gắn vào route table private. Nó giúp traffic nào không phải đi qua NAT
gateway, và traffic nào vẫn phải đi qua?

**A4.4** Chỉ có một NAT gateway cho ba AZ. Nếu AZ của nó sập, cái gì ngừng chạy và cái gì vẫn chạy? Trả
lời cả phần app, Ansible, Session Manager và Rancher.

**A4.5** Vì sao workstation cần public IP? Muốn bỏ nó thì phải làm gì?

### A5. Security group

**A5.1** Liệt kê mọi đường đi từ internet vào project này, và resource Terraform mở ra từng đường.

**A5.2** `nodes_from_nodes` tham chiếu chính security group của nó với `ip_protocol = "-1"`. Rule này
cho phép gì, bao gồm những port Kubernetes nào, và siết lại thế nào?

**A5.3** Vì sao rule được viết thành các resource `aws_vpc_security_group_*_rule` riêng thay vì block
`ingress {}` inline? Nếu một group trộn cả hai kiểu thì hỏng ở đâu?

**A5.4** Internal NLB nhận 6443 và 443 từ toàn bộ CIDR của VPC. Khi WireGuard đưa laptop vào trong VPC,
cái gì ngăn laptop gọi tới 6443, và nếu gỡ lớp đó đi thì còn gì chặn không?

**A5.5** Cả hai NLB được tạo kèm `security_groups`. Nếu một NLB được tạo mà không có security group thì
về sau bạn sẽ không bao giờ làm được điều gì?

**A5.6** Vì sao `api_nlb` cần rule *egress* tới node, trong khi NLB chỉ nhận kết nối vào? Và vì sao mọi
security group trong code đều khai báo egress tường minh, kể cả rule "cho ra tất cả"?

### A6. Load balancer

**A6.1** Giải thích vấn đề hairpin mà `preserve_client_ip = false` xử lý trên target group của API. Vì
sao target group HTTP public không cần?

**A6.2** Vì sao health check của API là `HTTPS /readyz` chứ không phải TCP? NLB gọi được nó mà không cần
client certificate là nhờ đâu, và thay đổi nào ở API server sẽ khiến mọi target thành unhealthy?

**A6.3** Ngay sau `make infra`, mọi target của API đều `unhealthy`. Đó có phải lỗi không? NLB làm gì khi
tất cả target đều unhealthy, và điều đó ảnh hưởng thế nào tới `kubeadm init` trên node 1?

**A6.4** Vì sao Terraform tạo sẵn NLB trỏ vào các NodePort cố định, thay vì để Kubernetes tự tạo load
balancer từ `Service type: LoadBalancer`?

**A6.5** Listener 443 của Rancher nằm trên internal NLB của API chứ không phải trên một NLB thứ ba. Cách
này tiết kiệm được gì, và phải trả giá gì?

### A7. Compute, IAM và instance metadata

**A7.1** `http_put_response_hop_limit` là 1 trên workstation và gateway nhưng là 2 trên node. Con số này
kiểm soát điều gì, vì sao node cần 2, và để 2 thì phải đánh đổi gì?

**A7.2** Vì sao `ecr:GetAuthorizationToken` được cấp trên `"*"`? Việc đó có làm node pull được nhiều
repository hơn không?

**A7.3** Mọi pod đều dùng được IAM role của node nó chạy trên. Quyền nào của role đó gây hại nhiều nhất
nếu một pod bị chiếm quyền, và thiệt hại có dừng lại trong phạm vi project không?

**A7.4** Vì sao WireGuard gateway có IAM role riêng thay vì dùng role của node? Nó đọc được chính xác
những gì, và cái gì ngăn node đọc secret của WireGuard?

**A7.5** Vì sao AMI được đọc bằng `insecure_value`, và vì sao điều đó an toàn ở đây?

**A7.6** Node dùng `count`. Nếu giảm `node_count` từ 3 xuống 2 thì sao? Làm sao thay riêng node 2, và
trong Kubernetes phải làm gì trước khi Terraform thay một node control plane?

### A8. Các dịch vụ dùng chung

**A8.1** Vì sao ECR để `IMMUTABLE_WITH_EXCLUSION`, và loại trừ `sha256-*` cùng `buildcache*`? Vì sao
lifecycle policy chỉ đếm image `tagged`?

**A8.2** Vì sao cosign key là key bất đối xứng `SIGN_VERIFY`, và vì sao nó nằm trong stack shared? Nếu
tạo lại key thì các chữ ký đang có ra sao?

**A8.3** Vì sao Terraform tạo secret rỗng? Resource nào sẽ đưa giá trị secret vào state, và tính năng mới
nào của Terraform tránh được chuyện đó?

**A8.4** Budget lọc theo `user:project$medical-rag`. Vì sao chuỗi này được dựng bằng `format()`, và cần
làm gì trong Billing console trước khi budget bắt đầu đếm chi phí?

**A8.5** CNAME xác minh của Sectigo và các record chép từ nhà cung cấp DNS cũ được tạo tay trong một zone
do Terraform quản lý. Đó có phải là drift không? Vì sao chúng không nằm trong code?

**A8.6** `default_tags` gắn tag lên những gì, và những khoản chi nào vẫn lọt khỏi budget dù tag đã được
kích hoạt?

### A9. WireGuard và DNS

**A9.1** `wireguard-init.sh` được render bằng `templatefile`. Terraform thay những giá trị nào? Vì sao
`$PRIVATE_KEY` và `$INTERFACE` đi qua nguyên vẹn, và nếu viết `${PRIVATE_KEY}` thì sao?

**A9.2** Vì sao gateway lấy private key từ Secrets Manager lúc boot, thay vì nhận key qua
`templatefile`?

**A9.3** Máy chuyển tiếp traffic thường phải đặt `source_dest_check = false`. Vì sao gateway giữ được
giá trị mặc định?

**A9.4** Elastic IP được gắn vào vài giây sau khi gateway boot. Việc đó làm hỏng cái gì, và script sống
sót bằng cách nào?

**A9.5** `rancher.recruitai.io.vn` là record public trỏ tới một internal NLB. Một người lạ trên internet
tra tên này thì nhận được gì, và vì sao điều đó chấp nhận được?

**A9.6** Vì sao VPC resolver là `cidrhost(var.vpc_cidr, 2)`, và vì sao tunnel trên laptop dùng
`DNS = 10.10.0.2` thay vì router ở nhà?

**A9.7** Mô tả của biến `wireguard_cidr` nói "không được trùng với VPC, pod và Service CIDR". Với dải
Service `10.96.0.0/12`, code hiện tại có khớp với mô tả đó không? Hiện tại việc này có ảnh hưởng gì không?

**A9.8** Đi theo một request HTTPS từ trình duyệt trên laptop tới pod Rancher. Kể ra từng chặng, từng lần
đổi địa chỉ và từng rule cho phép nó đi qua.

---

## Phần B — Phỏng vấn

### B1. Kiến trúc và quyết định

**B1.1** Trình bày hạ tầng của project này trong hai phút.

**B1.2** Vì sao dùng kubeadm trên EC2 mà không dùng EKS?

**B1.3** Vì sao chia ba stack Terraform? Bạn quyết định ranh giới giữa chúng thế nào?

**B1.4** Vì sao dùng Network Load Balancer mà không dùng Application Load Balancer?

**B1.5** Bạn vào máy bằng cách nào? Vì sao không có SSH và bastion host?

**B1.6** Vì sao chọn WireGuard cho Rancher, thay vì AWS Client VPN, SSM port-forward, hay HTTPS public
chỉ cho phép IP của bạn?

**B1.7** Bạn có tự viết module không? Vì sao VPC dùng module cộng đồng còn mọi thứ khác là resource
thường?

**B1.8** Hệ thống này HA ở đâu, và bạn đã chấp nhận những single point of failure nào?

### B2. State và làm việc nhóm

**B2.1** State nằm ở đâu, được bảo vệ thế nào và lock thế nào?

**B2.2** Có thêm hai kỹ sư vào team. Bạn thay đổi gì để cả ba cùng làm việc an toàn?

**B2.3** Bạn sẽ chạy Terraform trong pipeline CI thế nào? Pipeline dùng credential gì?

**B2.4** Có người thêm một rule security group trên console. `terraform plan` có thấy không? Phát hiện và
xử lý drift thế nào?

**B2.5** Làm sao đổi tên một resource, hoặc chuyển nó sang stack khác, mà không xoá nó?

**B2.6** Bạn sẽ thêm môi trường production thế nào?

**B2.7** `make infra` chạy `terraform apply` tương tác, không có plan file được lưu. Cách này rủi ro gì, và
khi nào bạn đổi sang `plan -out`?

### B3. Bảo mật

**B3.1** Làm sao để secret không lọt vào Git và không lọt vào state của Terraform?

**B3.2** Kể về least privilege trong project này, và chỗ nào nó chưa đạt.

**B3.3** Cái gì đang mở ra internet, và bạn đã kiểm chứng thế nào?

**B3.4** Kẻ tấn công chạy được code trong một pod. Nói ngắn gọn: họ làm được gì trên AWS?

**B3.5** Bạn quét lỗi bảo mật trong code Terraform này trước khi apply thế nào?

**B3.6** Một người thứ hai cần chạy `make infra` nhưng không được có `AdministratorAccess`. IAM policy tối
thiểu cần những gì, và phần nào khó giới hạn nhất?

### B4. Chi phí

**B4.1** Hạ tầng này tốn bao nhiêu, và các con số đó lấy từ đâu?

**B4.2** Bạn đã làm gì để giảm chi phí, và mỗi khoản tiết kiệm đánh đổi điều gì?

**B4.3** Làm sao tránh bị bất ngờ vì hoá đơn?

### B5. Vận hành và độ tin cậy

**B5.1** Làm sao bạn biết hạ tầng tái tạo được?

**B5.2** Canonical ra AMI có bản vá bảo mật. Bạn đưa nó lên cả ba node thế nào, khi node có
`ignore_changes = [ami]`?

**B5.3** `terraform apply` lỗi giữa chừng. Lúc đó hệ thống ở trạng thái nào, và bạn làm gì?

**B5.4** AWS provider ra phiên bản 7. Bạn nâng cấp thế nào?

**B5.5** Bạn test code Terraform thế nào?

### B6. Xử lý sự cố

**B6.1** Kể về một vấn đề thật bạn gặp khi dựng hệ thống này, và cách bạn tìm ra nguyên nhân gốc.

**B6.2** `terraform init` trong CloudShell báo `no space left on device`. Chuyện gì đang xảy ra?

**B6.3** Bạn chọn loại máy cho node và workstation dựa trên những ràng buộc nào?

**B6.4** Một WireGuard gateway mới báo `cloud-init status: error`. Bạn debug thế nào khi không có SSH?

**B6.5** Sau `kubeadm init`, các target 6443 vẫn unhealthy. Bạn tìm ở đâu?

### B7. Nhìn lại

**B7.1** Nếu có thêm một tuần, bạn sẽ thay đổi gì trong code Terraform này?

**B7.2** Ở một công ty thật, bạn sẽ làm khác đi điều gì?

---

## Phần C — AWS phía sau code

### C1. VPC và mạng

**C1.1** Trong AWS, điều gì làm một subnet trở thành public? Chỉ ra cái gì làm `10.10.101.0/24` là public
và `10.10.1.0/24` là private.

**C1.2** Security group và network ACL: project này dựa vào cái nào, cái nào là stateful, và module VPC
làm gì với NACL và security group mặc định?

**C1.3** NAT gateway nằm ở đâu, vì sao nó cần Elastic IP, và nó tính tiền những gì?

**C1.4** Gateway endpoint và interface endpoint khác nhau thế nào về cách định tuyến, giá và các dịch vụ
hỗ trợ?

**C1.5** Khi cluster đang chạy, project giữ bao nhiêu địa chỉ IPv4 public, và vì sao chúng xuất hiện
trên hoá đơn?

**C1.6** Subnet `/28` của workstation có bao nhiêu địa chỉ dùng được?

**C1.7** `ap-southeast-1a` trong account này và `ap-southeast-1a` trong account khác có phải cùng một
data centre không? Khi nào điều đó quan trọng?

### C2. Cân bằng tải

**C2.1** So sánh NLB và ALB: tầng OSI, cách xử lý TLS, IP nguồn, địa chỉ cố định, security group.

**C2.2** Cả hai NLB đều bật cross-zone load balancing. Nó thay đổi điều gì, và trên NLB thì tốn thêm gì?

**C2.3** Khi một node bị stop hoặc bị deregister khỏi target group, các kết nối đang mở tới nó ra sao?

### C3. Compute và lưu trữ

**C3.1** Credential của instance role tới được một process trên máy bằng cách nào, và có hiệu lực bao
lâu?

**C3.2** IMDSv2 chặn được kiểu tấn công nào mà IMDSv1 không chặn được?

**C3.3** Instance profile và role khác nhau thế nào: vì sao EC2 cần cả hai, và quyền nào cho phép một
identity gắn role vào instance?

**C3.4** Khi Terraform xoá một node, ổ EBS gốc của nó và dữ liệu etcd trên đó ra sao?

**C3.5** etcd rất nhạy với độ trễ ghi đĩa. Vì sao ổ 40 GB của node dùng gp3 chứ không phải gp2?

**C3.6** `m7i-flex.large` và `t3.large` xử lý CPU burst khác nhau thế nào, và vì sao điều đó quan trọng
với việc monitoring?

### C4. IAM, mã hoá và secret

**C4.1** Trust policy và permissions policy: cái nào nói "EC2 được dùng role này"?

**C4.2** Bucket policy chỉ cho phép TLS là một `Deny`, còn role của node có `Allow` trên `s3:GetObject`.
Hãy đi qua cách AWS đánh giá một request HTTP thường (không TLS) từ node.

**C4.3** AWS managed policy, customer managed policy và inline policy: project này dùng loại nào ở đâu,
và vì sao?

**C4.4** Terraform tạo role và instance profile rồi launch instance với nó, và thỉnh thoảng lệnh launch
lỗi `Invalid IAM Instance Profile`. Vì sao?

**C4.5** Rotation của KMS key bất đối xứng có gì khác, và cosign key tốn bao nhiêu?

**C4.6** Secrets Manager và SSM Parameter Store `SecureString`: nếu dùng Parameter Store thì những gì thay
đổi?

**C4.7** S3 giờ mặc định mã hoá mọi object mới, có strong consistency và conditional write. Ba điều này
thể hiện thế nào trong code Terraform của project?

### C5. DNS

**C5.1** Vì sao record `rancher` dùng Route 53 alias mà không dùng CNAME?

**C5.2** Delegate `recruitai.io.vn` sang Route 53: record NS nào đổi ở đâu, vì sao việc chuyển có thể mất
hàng giờ, và vì sao phải tắt DNSSEC trước?

**C5.3** Vì sao một hosted zone được tạo lại lại nhận name server khác, và AWS có cách nào tránh điều đó?

**C5.4** Sectigo xác minh bạn kiểm soát `rancher.recruitai.io.vn` bằng cách nào, và điều gì có thể chặn
việc cấp certificate?

### C6. Account, chi phí và vận hành

**C6.1** AWS Free plan giới hạn những gì, chuyện gì xảy ra khi nó kết thúc, và bạn giữ state cùng các
shared resource thế nào trước thời điểm đó?

**C6.2** Cost allocation tag đi tới budget bằng cách nào?

**C6.3** CloudShell giữ lại gì giữa các phiên, và vì sao đó là nơi tệ để giữ state của Terraform?

**C6.4** Nếu account dùng chung ngày càng nhiều project, quota mặc định nào có thể chặn `make infra`?

**C6.5** Bạn tìm ở đâu để biết ai đã xoá một rule security group vào thứ Ba tuần trước?
