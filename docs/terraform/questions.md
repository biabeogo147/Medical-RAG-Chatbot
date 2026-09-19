# Câu hỏi về Terraform

Bộ câu hỏi về phần Terraform của project, dùng để tự kiểm tra mức hiểu và luyện phỏng vấn. Đáp án
nằm ở [`answers.md`](answers.md), cùng số thứ tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Phỏng vấn** (ưu tiên) | Bạn giải thích được kiến trúc, bảo vệ được lựa chọn và nói rõ giới hạn của nó |
| **B. Chi tiết** | Bạn biết vì sao từng block được viết như vậy, và đổi đi thì cái gì hỏng |

Câu hỏi về bản thân các dịch vụ AWS (VPC, NLB, IAM, KMS, Route 53…) và khác biệt với on-premises nằm ở
[`../aws/questions.md`](../aws/questions.md). Tham chiếu dạng `AWS B1.1` trỏ tới bộ đó. Phần Argo CD và GitOps nằm ở
[`../gitops/questions.md`](../gitops/questions.md).

**Cách dùng.** Làm Phần A trước: trả lời thành tiếng, khoảng một phút mỗi câu, rồi so với đáp án. Phần B
làm không mở code; chỉ tính là đã hiểu khi bạn nói được *lý do*, không chỉ nêu sự kiện. Trong mỗi nhóm, câu
hỏi khó dần về cuối.

---

## Phần A — Phỏng vấn

### A1. Kiến trúc và lựa chọn công cụ

**A1.1** Trình bày hạ tầng của project này trong hai phút.

**A1.2** Vì sao dùng Terraform mà không dùng CloudFormation hay CDK?

**A1.3** Vì sao dùng kubeadm trên EC2 mà không dùng EKS?

**A1.4** Vì sao chia ba stack Terraform? Bạn quyết định ranh giới giữa chúng thế nào?

**A1.5** Vì sao Terraform chỉ tạo máy còn Ansible cấu hình máy, thay vì dồn hết vào user data, hoặc bake
sẵn AMI bằng Packer?

**A1.6** Terraform có provider cho Helm và Kubernetes. Sao không để Terraform cài luôn Argo CD và các addon?

**A1.7** Vì sao dùng Network Load Balancer mà không dùng Application Load Balancer?

**A1.8** Bạn vào máy bằng cách nào? Vì sao không có SSH và bastion host?

**A1.9** Vì sao chọn WireGuard cho Rancher, thay vì AWS Client VPN, SSM port-forward, hay HTTPS public
chỉ cho phép IP của bạn?

**A1.10** Bạn có tự viết module không? Vì sao VPC dùng module cộng đồng còn mọi thứ khác là resource
thường?

**A1.11** Hệ thống này HA ở đâu, và bạn đã chấp nhận những single point of failure nào?

### A2. Plan, state và làm việc nhóm

**A2.1** State nằm ở đâu, được bảo vệ thế nào và lock thế nào?

**A2.2** Có thêm hai kỹ sư vào team. Bạn thay đổi gì để cả ba cùng làm việc an toàn?

**A2.3** `make infra` chạy `terraform apply` tương tác, không có plan file được lưu. Cách này rủi ro gì, và
khi nào bạn đổi sang `plan -out`?

**A2.4** `terraform plan` báo một resource quan trọng `must be replaced`. Bạn làm gì trước khi gõ `yes`?

**A2.5** Bạn có dùng `-target` không?

**A2.6** Bạn sẽ chạy Terraform trong pipeline CI thế nào? Pipeline dùng credential gì?

**A2.7** Có người thêm một rule security group trên console. `terraform plan` có thấy không? Phát hiện và
xử lý drift thế nào?

**A2.8** Bạn không sửa dòng code nào, vậy mà `terraform plan` lần nào cũng báo có thay đổi. Bạn tìm nguyên
nhân ở đâu?

**A2.9** Làm sao đổi tên một resource, hoặc chuyển nó sang stack khác, mà không xoá nó?

**A2.10** Công ty đã có sẵn hạ tầng tạo tay trên console. Bạn đưa nó vào Terraform thế nào mà không xoá
hay tạo lại gì?

**A2.11** Bạn sẽ thêm môi trường production thế nào?

**A2.12** Account AWS này dùng chung với project khác. Làm sao bạn chắc mình không apply hay destroy nhầm
account, và không đụng tài nguyên của người khác?

### A3. Khái niệm Terraform, giải thích bằng chính project

**A3.1** Terraform và Ansible truyền giá trị cho nhau bằng cách nào?

**A3.2** Terraform biết thứ tự tạo resource bằng cách nào? Khi nào bạn phải viết `depends_on`, và vì sao
không nên viết nó ở mọi chỗ?

**A3.3** `count` và `for_each` khác nhau thế nào? Project dùng mỗi cái ở đâu, và bạn có giữ `count` cho
node không?

**A3.4** Project dùng những `lifecycle` nào, để làm gì? Vì sao không dùng `create_before_destroy`?

**A3.5** Đánh dấu `sensitive = true` có giữ secret ngoài state không?

### A4. Bảo mật

**A4.1** Làm sao để secret không lọt vào Git và không lọt vào state của Terraform?

**A4.2** Kể về least privilege trong project này, và chỗ nào nó chưa đạt.

**A4.3** Cái gì đang mở ra internet, và bạn đã kiểm chứng thế nào?

**A4.4** Kẻ tấn công chạy được code trong một pod. Nói ngắn gọn: họ làm được gì trên AWS?

**A4.5** Bạn quét lỗi bảo mật trong code Terraform này trước khi apply thế nào?

**A4.6** Một người thứ hai cần chạy `make infra` nhưng không được có `AdministratorAccess`. IAM policy tối
thiểu cần những gì, và phần nào khó giới hạn nhất?

**A4.7** Hôm qua ai đã chạy `terraform apply`, bằng credential gì? Bạn trả lời câu đó bằng cách nào?

**A4.8** Rotate một secret thế nào: token GitHub, key của WireGuard, certificate của Rancher sắp hết hạn? Có
phải sửa Terraform không?

### A5. Chi phí

**A5.1** Hạ tầng này tốn bao nhiêu, và các con số đó lấy từ đâu?

**A5.2** Bạn đã làm gì để giảm chi phí, và mỗi khoản tiết kiệm đánh đổi điều gì?

**A5.3** Làm sao tránh bị bất ngờ vì hoá đơn?

**A5.4** Bạn chọn loại máy cho node và workstation dựa trên những ràng buộc nào?

### A6. Vận hành, độ tin cậy và khôi phục

**A6.1** Làm sao bạn biết hạ tầng tái tạo được?

**A6.2** Canonical ra AMI có bản vá bảo mật. Bạn đưa nó lên cả ba node thế nào, khi node có
`ignore_changes = [ami]`?

**A6.3** `terraform apply` lỗi giữa chừng. Lúc đó hệ thống ở trạng thái nào, và bạn làm gì?

**A6.4** AWS provider ra phiên bản 7. Bạn nâng cấp thế nào?

**A6.5** Bạn test code Terraform thế nào?

**A6.6** File state của stack cluster bị xoá mất, hoặc bị ghi hỏng. Bạn làm gì?

**A6.7** Mất cả account AWS, ví dụ Free plan hết hạn hoặc account bị khoá. Dựng lại ở account mới thì mất
những gì?

### A7. Sự cố và bài học

**A7.1** Kể về một vấn đề thật bạn gặp khi dựng hệ thống này, và cách bạn tìm ra nguyên nhân gốc.

**A7.2** Kể về một sai lầm của bạn trong phần Terraform.

**A7.3** `terraform init` trong CloudShell báo `no space left on device`. Chuyện gì đang xảy ra?

**A7.4** Một WireGuard gateway mới báo `cloud-init status: error`. Bạn debug thế nào khi không có SSH?

**A7.5** Sau `kubeadm init`, các target 6443 vẫn unhealthy. Bạn tìm ở đâu?

### A8. Nhìn lại

**A8.1** Nếu có thêm một tuần, bạn sẽ thay đổi gì trong code Terraform này?

**A8.2** Ở một công ty thật, bạn sẽ làm khác đi điều gì?

---

## Phần B — Chi tiết

### B1. State và backend

**B1.1** Stack bootstrap tạo ra chính bucket lưu state của nó. Việc đó diễn ra theo thứ tự nào, và
nếu `bootstrap/backend.tf` đã có sẵn ở lần apply đầu tiên thì cái gì sẽ lỗi?

**B1.2** Cả ba file `backend.tf` đều không khai báo `bucket` và `region`. Vì sao, và hai giá trị này đến
từ đâu khi chạy trên workstation và trong CloudShell?

**B1.3** `use_lockfile = true` làm gì, nó thay thế cái gì, và người thứ hai thấy gì khi hai lệnh
`make infra` chạy cùng lúc? Gỡ lock do một lần chạy bị crash để lại bằng cách nào?

**B1.4** Bucket state có versioning, `noncurrent_version_expiration` 90 ngày và
`abort_incomplete_multipart_upload`. Mỗi cái bảo vệ khỏi điều gì? Nếu state của cluster bị ghi hỏng thì
khôi phục thế nào?

**B1.5** `aws_s3_bucket_policy.state` có `depends_on` tới public access block, còn
`aws_s3_bucket_versioning.state` thì không có `depends_on` nào. Vì sao lại khác nhau?

**B1.6** State của ba stack hiện chứa những thông tin nhạy cảm nào, và những lựa chọn thiết kế nào giữ
giá trị secret nằm ngoài state?

**B1.7** `shared/` và `cluster/` có commit `.terraform.lock.hcl`, còn `bootstrap/` thì không. Lock file
ghim được điều gì mà `version = "~> 6.64"` không ghim được, và stack bootstrap gặp rủi ro gì?

**B1.8** Account mới tinh, nhưng repo đã commit sẵn `bootstrap/backend.tf`. Lần apply đầu tiên của stack
bootstrap làm thế nào?

### B2. Các stack và cách chúng nối với nhau

**B2.1** Chọn một resource trong mỗi stack và giải thích, dựa vào vòng đời của nó, vì sao nó không thể
nằm ở một trong hai stack còn lại.

**B2.2** Stack cluster tìm resource của shared bằng `data` source theo tên, không dùng
`terraform_remote_state`. Nêu một ưu điểm và một điểm yếu của cách này.

**B2.3** Trên một account chưa từng chạy `make shared`, bạn chạy `make infra`. Nó lỗi ở thời điểm nào, và
hành vi đó tốt hay xấu?

**B2.4** Có cả `shared/rancher.tf` lẫn `cluster/rancher.tf`. File nào sở hữu hosted zone, file nào sở hữu
các record? Nếu chuyển zone sang stack cluster thì chuyện gì xảy ra?

**B2.5** Workstation có `AdministratorAccess`, vậy mà stack bootstrap chỉ được apply từ CloudShell. Vì
sao?

**B2.6** Makefile và Ansible lấy DNS name của NLB, instance ID của gateway từ Terraform bằng cách nào? Nếu
ai đó đổi tên một output thì cái gì hỏng, và hỏng lúc nào?

**B2.7** Ai đó tạo lại secret `medical-rag/llm` (xoá hẳn rồi tạo lại, cùng tên), hoặc tạo cosign key mới và
chuyển alias sang, trong stack shared, nhưng không chạy lại `make infra`. Cái gì hỏng, và hỏng lúc nào?

**B2.8** Có những hợp đồng giữa Terraform và Ansible không đi qua output. Chạy `terraform apply -var
project=demo` (hoặc đổi region), Terraform chạy êm. `make ping` và `make cluster` ra sao?

**B2.9** Trong Makefile, `ACCOUNT_ID` dùng `:=` còn `API_ENDPOINT` dùng `=`. Đổi `API_ENDPOINT` sang `:=` thì
`make cluster` trên một bản clone mới ra sao?

**B2.10** Vì sao `NODE_1` trong Makefile và inventory của Ansible đều lọc `instance-state-name=running`? Bỏ bộ
lọc đó ngay sau khi `-replace` node 1 thì sao?

### B3. Lifecycle và các lớp bảo vệ

**B3.1** So sánh `prevent_destroy` trên bucket state, việc không có `force_destroy` trên bucket
artifacts, và `force_destroy = true` trên hai bucket của cluster. `make infra-destroy` làm gì với từng
bucket? Vì sao mất snapshot etcd sau mỗi lần teardown vẫn chấp nhận được?

**B3.2** Route 53 zone có `prevent_destroy`. Hãy mô tả một cách để Terraform vẫn xoá được nó mà không
báo lỗi gì. Khi zone còn chứa record, AWS thêm lớp bảo vệ thứ hai nào?

**B3.3** Vì sao các secret dùng `recovery_window_in_days = 7`? Bạn đổi tên `"rancher-tls"` trong tập
`for_each`, apply, rồi đổi ý và đổi lại tên cũ. Chuyện gì xảy ra ở mỗi lần apply?

**B3.4** Node có `ignore_changes = [ami]`, workstation có `[ami, user_data]`, còn gateway chỉ có
`[ami]`. Giải thích từng lựa chọn. AMI không bao giờ được ghim: điều đó ảnh hưởng thế nào tới tính
"tái tạo được"?

**B3.5** Vì sao gateway đặt `user_data_replace_on_change = true`? Bỏ nó đi rồi sửa `wireguard-init.sh`
và apply thì chuyện gì xảy ra?

**B3.6** Vì sao `aws_instance.workstation` cần `depends_on = [aws_route_table_association.ops_public]`?
WireGuard gateway có gặp rủi ro tương tự không?

**B3.7** Sau phase GitOps, EBS CSI driver tạo volume cho Jenkins và Prometheus. Những volume đó có nằm
trong state không? `make infra-destroy` xử lý chúng thế nào, và vì sao destroy đôi khi bị treo ở bước
xoá subnet hoặc security group?

### B4. Mạng

**B4.1** Tính sáu CIDR subnet của cluster từ `cidrsubnet(var.vpc_cidr, 8, i + 1)` và `i + 101`. Chúng
không được trùng với những dải nào khác, và vì sao trùng dải lại là vấn đề?

**B4.2** Vì sao phần tra cứu AZ lọc theo `opt-in-not-required`? Nếu `node_count = 4` thì node 4 nằm ở
đâu, và etcd 4 member có chịu lỗi tốt hơn 3 member không?

**B4.3** S3 gateway endpoint chỉ gắn vào route table private. Nó giúp traffic nào không phải đi qua NAT
gateway, và traffic nào vẫn phải đi qua?

**B4.4** Chỉ có một NAT gateway cho ba AZ. Nếu AZ của nó sập, cái gì ngừng chạy và cái gì vẫn chạy? Trả
lời cả phần app, Ansible, Session Manager và Rancher.

**B4.5** Vì sao workstation cần public IP? Muốn bỏ nó thì phải làm gì?

### B5. Security group

**B5.1** Liệt kê mọi đường đi từ internet vào project này, và resource Terraform mở ra từng đường.

**B5.2** `nodes_from_nodes` tham chiếu chính security group của nó với `ip_protocol = "-1"`. Rule này
cho phép gì, bao gồm những port Kubernetes nào, và siết lại thế nào?

**B5.3** Vì sao rule được viết thành các resource `aws_vpc_security_group_*_rule` riêng thay vì block
`ingress {}` inline? Nếu một group trộn cả hai kiểu thì hỏng ở đâu?

**B5.4** Internal NLB nhận 6443 và 443 từ toàn bộ CIDR của VPC. Khi WireGuard đưa laptop vào trong VPC,
cái gì ngăn laptop gọi tới 6443, và nếu gỡ lớp đó đi thì còn gì chặn không?

**B5.5** Cả hai NLB được tạo kèm `security_groups`. Nếu một NLB được tạo mà không có security group thì
về sau không làm được gì?

**B5.6** Vì sao `api_nlb` cần rule *egress* tới node, trong khi NLB chỉ nhận kết nối vào? Và vì sao mọi
security group trong code đều khai báo egress tường minh, kể cả rule "cho ra tất cả"?

### B6. Load balancer

**B6.1** Giải thích vấn đề hairpin mà `preserve_client_ip = false` xử lý trên target group của API. Vì
sao target group HTTP public không cần?

**B6.2** Vì sao health check của API là `HTTPS /readyz` chứ không phải TCP? NLB gọi được nó mà không cần
client certificate là nhờ đâu, và thay đổi nào ở API server sẽ khiến mọi target thành unhealthy?

**B6.3** Ngay sau `make infra`, mọi target của API đều `unhealthy`. Đó có phải lỗi không? NLB làm gì khi
tất cả target đều unhealthy, và điều đó ảnh hưởng thế nào tới `kubeadm init` trên node 1?

**B6.4** Vì sao Terraform tạo sẵn NLB trỏ vào các NodePort cố định, thay vì để Kubernetes tự tạo load
balancer từ `Service type: LoadBalancer`?

**B6.5** Listener 443 của Rancher nằm trên internal NLB của API chứ không phải trên một NLB thứ ba. Cách
này tiết kiệm được gì, và phải trả giá gì?

**B6.6** Đổi `ingress_https_nodeport` từ 30443 sang 31443. Plan trông bình thường; apply thì sao?

### B7. Compute, IAM và instance metadata

**B7.1** `http_put_response_hop_limit` là 1 trên workstation và gateway nhưng là 2 trên node. Con số này
kiểm soát điều gì, vì sao node cần 2, và để 2 thì phải đánh đổi gì?

**B7.2** Vì sao `ecr:GetAuthorizationToken` được cấp trên `"*"`? Việc đó có làm node pull được nhiều
repository hơn không?

**B7.3** Mọi pod đều dùng được IAM role của node nó chạy trên. Quyền nào của role đó gây hại nhiều nhất
nếu một pod bị chiếm quyền, và thiệt hại có dừng lại trong phạm vi project không?

**B7.4** Vì sao WireGuard gateway có IAM role riêng thay vì dùng role của node? Nó đọc được chính xác
những gì, và cái gì ngăn node đọc secret của WireGuard?

**B7.5** Vì sao AMI được đọc bằng `insecure_value`, và vì sao điều đó an toàn ở đây?

**B7.6** Node dùng `count`. Nếu giảm `node_count` từ 3 xuống 2 thì sao? Làm sao thay riêng node 2, và
trong Kubernetes phải làm gì trước khi Terraform thay một node control plane?

### B8. Các dịch vụ dùng chung

**B8.1** Vì sao ECR để `IMMUTABLE_WITH_EXCLUSION`, và loại trừ `sha256-*` cùng `buildcache*`? Vì sao
lifecycle policy chỉ đếm image `tagged`?

**B8.2** Vì sao cosign key là key bất đối xứng `SIGN_VERIFY`, và vì sao nó nằm trong stack shared? Nếu
tạo lại key thì các chữ ký đang có ra sao?

**B8.3** Vì sao Terraform tạo secret rỗng? Resource nào sẽ đưa giá trị secret vào state, và tính năng mới
nào của Terraform tránh được chuyện đó?

**B8.4** Budget lọc theo `user:project$medical-rag`. Vì sao chuỗi này được dựng bằng `format()`, và cần
làm gì trong Billing console trước khi budget bắt đầu đếm chi phí?

**B8.5** CNAME xác minh của Sectigo và các record chép từ nhà cung cấp DNS cũ được tạo tay trong một zone
do Terraform quản lý. Đó có phải là drift không? Vì sao chúng không nằm trong code?

**B8.6** `default_tags` gắn tag lên những gì, và những khoản chi nào vẫn lọt khỏi budget dù tag đã được
kích hoạt?

### B9. WireGuard và DNS

**B9.1** `wireguard-init.sh` được render bằng `templatefile`. Terraform thay những giá trị nào? Vì sao
`$PRIVATE_KEY` và `$INTERFACE` đi qua nguyên vẹn, và nếu viết `${PRIVATE_KEY}` thì sao?

**B9.2** Vì sao gateway lấy private key từ Secrets Manager lúc boot, thay vì nhận key qua
`templatefile`?

**B9.3** Máy chuyển tiếp traffic thường phải đặt `source_dest_check = false`. Vì sao gateway giữ được
giá trị mặc định?

**B9.4** Elastic IP được gắn vào vài giây sau khi gateway boot. Việc đó làm hỏng cái gì, và script sống
sót bằng cách nào?

**B9.5** `rancher.recruitai.io.vn` là record public trỏ tới một internal NLB. Một người lạ trên internet
tra tên này thì nhận được gì, và vì sao điều đó chấp nhận được?

**B9.6** Vì sao VPC resolver là `cidrhost(var.vpc_cidr, 2)`, và vì sao tunnel trên laptop dùng
`DNS = 10.10.0.2` thay vì router ở nhà?

**B9.7** Mô tả của biến `wireguard_cidr` nói "không được trùng với VPC, pod và Service CIDR". Với dải
Service `10.96.0.0/12`, code hiện tại có khớp với mô tả đó không? Hiện tại việc này có ảnh hưởng gì không?

**B9.8** Đi theo một request HTTPS từ trình duyệt trên laptop tới pod Rancher. Kể ra từng chặng, từng lần
đổi địa chỉ và từng rule cho phép nó đi qua.

**B9.9** Vì sao rule iptables của gateway nằm trong chain riêng `WG_FWD`, vì sao PostDown gỡ theo thứ tự ngược
lại, và vì sao `wg-quick` có thể lỗi `Chain already exists` khi khởi động lại?

**B9.10** Xoá dòng `associate_public_ip_address = true` của gateway. Chuyện gì xảy ra ở plan, và lúc boot?
