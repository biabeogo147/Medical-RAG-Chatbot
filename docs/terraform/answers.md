# Đáp án Terraform

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. **Ở đâu** chỉ ra code hoặc tài liệu làm căn cứ
cho câu trả lời. **Hỏi tiếp** là câu mà người phỏng vấn nhiều khả năng sẽ hỏi ngay sau đó.

Các con số lấy từ [`docs/evidence/terraform.md`](../evidence/terraform.md):

- **Số resource:** bootstrap 18, shared 17, cluster 84.
- **Thời gian:** ở step 15, bản cluster 65 resource (chưa có WireGuard) destroy mất 1 phút 27 giây và dựng
  lại từ đầu mất 3 phút 19 giây. Bản 84 resource đã `make infra` thành công nhưng chưa được đo lại thời gian.
- **Chi phí:** khoảng 0.53 USD/giờ khi cluster đang chạy.

Các target `make ping`, `make cluster`, `make tunnel` được nhắc tới dưới đây thuộc phase Ansible;
`Makefile` hiện tại chỉ có các target Terraform.

---

## Phần A — Code

### A1. State và backend

**A1.1** Lần apply đầu tiên chạy trong CloudShell với **state local**: lúc đó chưa có `backend.tf`, nên
state chỉ là một file nằm cạnh code. Lần apply đó tạo bucket và workstation. Ở step 6, `backend.tf` được
thêm vào và `terraform init -migrate-state -backend-config=...` chép file local lên
`bootstrap/terraform.tfstate` trong bucket. Sau đó `terraform plan` báo `No changes` và bản local bị xoá.

Nếu có `backend.tf` ngay từ đầu, `terraform init` sẽ lỗi: S3 backend kiểm tra bucket lúc init, mà bucket
lúc đó chưa tồn tại. Đây là bài toán con gà quả trứng quen thuộc của remote state, và migrate sau khi tạo
bucket là cách giải chuẩn.

*Ở đâu:* `bootstrap/backend.tf`; guide step 4 và 6.

**A1.2** Block `backend` được đọc trong lúc `terraform init`, trước khi variable, local hay data source
tồn tại, nên không dùng được những thứ đó. Tên bucket chứa account ID, nên được bỏ ra và truyền vào dưới
dạng **partial configuration**:

- **Workstation:** Makefile dựng `-backend-config="bucket=$(PROJECT)-tfstate-$(ACCOUNT_ID)"`, với
  `ACCOUNT_ID` lấy từ `aws sts get-caller-identity`.
- **CloudShell:** gõ tay đúng hai cờ đó ở step 6.

Nhờ vậy không có account ID nào bị commit vào Git, và cùng một code chạy được trên mọi account.

*Ở đâu:* `Makefile` (`BACKEND`); mọi file `backend.tf`.

**A1.3** S3 backend tự lock được state, không cần bảng DynamoDB như các setup cũ. Tính năng này xuất hiện
dạng thử nghiệm ở Terraform 1.10 và chính thức từ 1.11, cũng là lúc lock bằng DynamoDB bị deprecated.

Trong lúc làm việc, Terraform tạo object `<key>.tflock` cạnh file state bằng một *conditional write*: lệnh
ghi chỉ thành công nếu object đó chưa tồn tại. Vì vậy người chạy cần thêm quyền `s3:PutObject` và
`s3:DeleteObject` trên `<key>.tflock`. Lần chạy thứ hai lỗi ngay với `Error acquiring the state lock`, kèm
lock ID, ai đang giữ lock và giữ từ lúc nào. `plan` cũng lấy lock.

Lần chạy bị crash sẽ để lock lại. Trước tiên phải chắc chắn không còn process Terraform nào đang chạy, rồi
chạy `terraform force-unlock <LOCK_ID>` trong đúng stack đó.

*Ở đâu:* `use_lockfile = true` trong mỗi `backend.tf`; `required_version = ">= 1.10"`.
*Hỏi tiếp:* vì sao không nâng `required_version` lên `>= 1.11`, bản đầu tiên tính năng này chính thức?
(Nên nâng.)

**A1.4**

- **Versioning.** Mỗi lần ghi state đều giữ lại bản trước, nên một lần ghi hỏng, file bị hỏng hay bị xoá
  đều khôi phục được.
- **`noncurrent_version_expiration` 90 ngày.** Mỗi lần apply sinh một version mới. Không có hạn xoá thì
  bucket phình mãi; 90 ngày đủ dài để kịp phát hiện sự cố.
- **`abort_incomplete_multipart_upload`.** Upload lớn bị ngắt giữa chừng để lại các phần ẩn, vẫn bị tính
  tiền cho tới khi xoá. File state nhỏ, nên đây là dọn dẹp cho gọn chứ không tiết kiệm đáng kể.

**Khôi phục một version:**

1. Đảm bảo không ai đang chạy Terraform.
2. `aws s3api list-object-versions --bucket <bucket> --prefix cluster/terraform.tfstate`, chọn version
   trước lần ghi hỏng.
3. Tải nó về bằng `aws s3api get-object --version-id <id> ...`, rồi nạp lại bằng `terraform state push`
   (thêm `-force` nếu serial của nó cũ hơn).
4. Chạy `terraform plan`: nó cho thấy chênh lệch giữa bản ghi cũ và những gì thực sự tồn tại trên AWS; xử
   lý phần chênh bằng import hoặc apply.

**A1.5** Versioning chỉ cần bucket tồn tại, và reference `aws_s3_bucket.state.id` đã thể hiện điều đó.
Encryption và public access block cũng chỉ tham chiếu bucket, và cả ba chạy song song với nhau không vấn đề
gì.

Policy cũng chỉ tham chiếu bucket, nên nếu không có `depends_on` nó sẽ chạy song song với public access
block. `PutBucketPolicy` và `PutPublicAccessBlock` cùng lúc trên một bucket mới là một race đã biết của S3
(lỗi `OperationAborted` hoặc `AccessDenied`). Không có reference nào giữa hai resource để Terraform tự suy
ra thứ tự, nên phải khai báo. Đây là sắp thứ tự phòng thủ: project này chưa gặp lỗi đó.

Lifecycle rule có `depends_on` tới versioning vì lý do khác: rule về noncurrent version chỉ có nghĩa khi
versioning đã bật.

*Ở đâu:* `bootstrap/state.tf`, `shared/storage.tf`, `cluster/storage.tf`.

**A1.6**

**Có trong state:**

- ID và ARN của resource, account ID, IP private, DNS name của NLB, name server của Route 53
- email nhận cảnh báo budget (một thuộc tính của budget)
- **user data ở dạng plaintext.** Từ AWS provider v6, `user_data` được lưu nguyên văn trong state (v5 chỉ
  lưu hash). Cụ thể là `workstation-init.sh` trong state bootstrap, và user data đã render của gateway,
  vốn chỉ chứa region, *tên* secret và các dải CIDR.

Không cái nào là credential, nhưng gộp lại thì thành bản đồ hạ tầng. Vì vậy bucket phải private, mã hoá và
chỉ nhận TLS, và không bao giờ được nhét secret vào user data.

**Không có trong state, và vì sao:**

- **Giá trị secret.** Terraform chỉ tạo `aws_secretsmanager_secret`, không bao giờ tạo `secret_version`;
  giá trị được đưa vào bằng `put-secret-value --secret-string file://…`.
- **Private key của Rancher.** Sinh bằng OpenSSL trên workstation.
- **Server key của WireGuard.** Gateway tự lấy lúc boot, không đi qua biến của template.
- **Private key WireGuard của laptop.** Không bao giờ rời khỏi laptop.
- **GitHub token.** Do `gh` lưu trên workstation.
- **AWS access key.** Không tồn tại: CloudShell dùng phiên đăng nhập console, các máy dùng instance role.

**A1.7** `~> 6.64` là một khoảng: bất kỳ bản 6.x nào từ 6.64 trở lên. Lock file ghi lại **đúng phiên bản**
provider đã chọn (6.64.0) và **checksum** của nó. Lần `init` sau trên bất kỳ máy nào cũng cài đúng bản đó
và từ chối bản không khớp.

Stack bootstrap được init trong CloudShell, và lock file của nó chưa bao giờ được đưa vào repo. Lần `init`
sau ở đó có thể lấy provider 6.x mới hơn và cho ra thay đổi bất ngờ trong plan, ngay trên stack giữ bucket
state. Cách sửa: chép lock file đó vào repo, hoặc sinh nó bằng `terraform providers lock`.

Lock file chỉ ghim **provider**, không ghim module: `~> 6.7` của module VPC vẫn có thể trôi lên bản mới ở
lần `init` trên máy sạch (xem B5.4).

### A2. Các stack và cách chúng nối với nhau

**A2.1**

- **bootstrap, bucket state.** Mọi stack khác lưu state vào nó, nên nó phải có trước. Đặt trong `shared/`
  thì bucket sẽ chứa chính state mô tả bucket đó.
- **shared, cosign KMS key.** Chữ ký image chỉ kiểm tra được bằng public key của đúng key này. Đặt trong
  `cluster/` thì mỗi lần dựng lại nó bị tạo lại và làm mất hiệu lực mọi chữ ký. Đặt trong `bootstrap/` thì
  chỉ apply được từ CloudShell, dù nó không thuộc phần nền móng.
- **cluster, NAT gateway.** Tính tiền theo giờ và chỉ có ích khi có node. Đặt trong `shared/` thì nó tốn
  tiền suốt ngày đêm mà không để làm gì.

**A2.2** **Ưu điểm:** coupling lỏng. Cluster không cần quyền đọc file state của shared (file mô tả mọi thứ
trong stack đó), cũng không phụ thuộc vào tên output hay nơi lưu state. Việc tra cứu còn kiểm tra resource
*thực sự đang tồn tại* trên AWS, chứ không chỉ là một file state nói vậy.

**Điểm yếu:** hợp đồng giữa hai stack là một quy ước đặt tên không được ghi ở đâu (`${project}/llm`,
`alias/${project}-cosign`).

- Đổi tên thứ gì đó trong `shared/` thì không có cảnh báo nào cho tới khi plan cluster lần sau lỗi.
- Terraform không có đồ thị phụ thuộc giữa các stack, nên xoá một resource shared mà cluster đang dùng
  không có cảnh báo gì.
- Tra cứu theo tên có thể khớp nhiều đối tượng: hai hosted zone cùng tên `recruitai.io.vn` sẽ làm
  `data "aws_route53_zone"` lỗi.

**A2.3** Nó lỗi ngay trong **plan**, lúc đọc các data source trong `cluster/main.tf` (`aws_ecr_repository`,
`aws_s3_bucket`, `aws_kms_alias`, `aws_secretsmanager_secret`) và trong `wireguard.tf` / `rancher.tf`. Data
source có input đã biết được đọc trước khi tạo bất cứ thứ gì, nên chưa có resource nào tồn tại.

Đó là hành vi tốt: thiếu phụ thuộc thì dừng trước khi dựng được nửa cluster rồi phải dọn dẹp.

**A2.4** `shared/` sở hữu `aws_route53_zone.main`. `cluster/` sở hữu `aws_route53_record.rancher` (alias
tới internal NLB) và `aws_route53_record.vpn` (Elastic IP của gateway). Hai record đổi sau mỗi lần dựng
lại; zone thì không được đổi.

Nếu zone nằm trong cluster, `make infra-destroy` sẽ cố xoá nó. Lệnh xoá thực tế không qua nổi: zone đang chứa
các record tạo tay (CNAME xác minh của Sectigo, các record chép sang), nên AWS trả `HostedZoneNotEmpty` (xem
A3.2) và teardown kẹt lại.

Còn nếu xoá được, lần dựng lại sau sẽ tạo zone với **bốn name server mới, chọn ngẫu nhiên**. Bạn phải nhập
chúng ở registrar (nơi mua domain), rồi chờ hàng giờ cho record NS cũ ở zone cha hết hạn cache. Trong thời
gian đó cả domain không phân giải được, và các record tạo tay đã mất theo zone cũ.

**A2.5** Workstation là một resource của stack bootstrap. Apply chạy từ chính nó có thể stop nó (đổi
instance type) hoặc thay nó (một thay đổi bắt buộc tạo lại) ngay giữa lúc apply. Phiên làm việc chết,
process Terraform chết theo, lock của state bị bỏ lại và stack chỉ apply được một nửa.

CloudShell chạy bên ngoài mọi thứ Terraform quản lý ở đây, nên không thay đổi nào có thể làm nó chết.
`AdministratorAccess` là chuyện quyền hạn, không phải chuyện an toàn.

**A2.6** Qua **output**, đọc bằng `terraform output -raw`:

- `api_nlb_dns`: Makefile của phase Ansible truyền nó làm `control_plane_endpoint` cho kubeadm, và làm đích
  của `make tunnel`.
- `wireguard_instance_id`, `wireguard_client_address`, `wireguard_public_ip`: dùng ở guide step 18.
- `route53_name_servers`: nhập ở registrar.
- `ecr_repository_url`, `cosign_kms_key_arn`, `buckets`: dành cho Helm values và CI ở các phase sau.

Output chính là API công khai của một stack. Đổi tên thì **không lỗi lúc apply**, mà lỗi ở nơi dùng, vào lúc
chạy: `terraform output -raw api_nlb_dns` báo *Output not found*, biến trong `make` thành chuỗi rỗng, và
kubeadm nhận endpoint rỗng. Vì vậy playbook trong guide Ansible kiểm tra `control_plane_endpoint` không rỗng
trước khi làm gì.

Quy tắc: coi output như API. Thêm tên mới trước, chuyển nơi dùng sang, rồi mới bỏ tên cũ.

### A3. Lifecycle và các lớp bảo vệ

**A3.1** `make infra-destroy` chỉ chạy trên **state của cluster**, nên hai bucket đầu không bao giờ nằm
trong đó.

| Bucket | Lớp bảo vệ | Tác dụng |
|---|---|---|
| State (bootstrap) | `prevent_destroy` | Chặn ở phía Terraform: plan nào định xoá nó đều lỗi trước khi xoá bất cứ thứ gì |
| Artifacts (shared) | Không có `force_destroy` | Chặn ở phía AWS: S3 không xoá bucket còn object, nên destroy lỗi `BucketNotEmpty` |
| `etcd-backups`, `ssm-transfer` (cluster) | `force_destroy = true` | Provider xoá hết object rồi mới xoá bucket, nên teardown không bao giờ bị kẹt |

Mất snapshot etcd vẫn chấp nhận được vì một snapshot chỉ khôi phục được đúng cluster đã tạo ra nó. Sau
teardown, cluster được dựng lại từ code và Git, không phải từ etcd. Snapshot bảo vệ trước sự cố khi cluster
còn sống: upgrade hỏng, mất quorum, hoặc bài drill khôi phục.

**A3.2** Xoá block `aws_route53_zone`, hoặc chỉ xoá block `lifecycle` của nó, rồi apply. Lớp bảo vệ nằm
trong cấu hình, nên khi bị xoá đi thì Terraform lên plan xoá zone mà không phàn nàn gì. `prevent_destroy`
chặn tai nạn, không chặn thay đổi code có chủ ý; code review phải bắt được chuyện đó.

AWS thêm lớp bảo vệ thứ hai: nó không cho xoá hosted zone còn chứa record ngoài NS và SOA mặc định, và zone
không bật `force_destroy`. Chừng nào CNAME xác minh của Sectigo hay các record đã chép còn đó, lệnh xoá sẽ
lỗi `HostedZoneNotEmpty`.

**A3.3** Xoá một secret chỉ **lên lịch** xoá. Giá trị vẫn khôi phục được bằng `restore-secret` trong thời
gian recovery window. 7 ngày là mức ngắn nhất AWS cho phép; đặt `0` trong Terraform nghĩa là xoá hẳn ngay.
Ở đây điều này quan trọng vì giá trị được gõ tay.

- **Đổi tên.** Tên là key của `for_each` và không đổi tại chỗ được, nên Terraform lên plan xoá
  `medical-rag/rancher-tls` và tạo secret mới.
  - Secret mới **rỗng**; giá trị cũ không được chép sang.
  - Secret mới có ARN mới (hậu tố ngẫu nhiên khác).
  - Stack cluster tra secret theo tên `rancher-tls` để đưa ARN vào policy của node, nên plan `make infra`
    tiếp theo lỗi cho tới khi hai bên khớp tên lại.
- **Đổi lại tên cũ.** Terraform tạo lại `medical-rag/rancher-tls` và AWS trả về
  `InvalidRequestException: You can't create this secret because a secret with this name is already
  scheduled for deletion`.
- **Khôi phục.** Chạy `aws secretsmanager restore-secret`, rồi `terraform import` secret vừa khôi phục. Hoặc,
  nếu không cần giá trị nữa, xoá hẳn bằng `--force-delete-without-recovery` rồi tạo lại.

**A3.4**

- **Node, `[ami]`.** AMI lấy từ parameter "Ubuntu 24.04 mới nhất" của Canonical, vài tuần lại đổi một lần.
  Không có `ignore_changes`, plan đầu tiên sau khi có image mới sẽ thay cả ba node cùng lúc, tức là phá
  huỷ etcd.
- **Workstation, `[ami, user_data]`.** Đó là máy bạn đang làm việc. Image mới hay script boot đã sửa đều
  không được phép bất ngờ restart hay thay nó; muốn thay thì chủ động dùng `-replace`.
- **Gateway, chỉ `[ami]`.** User data *chính là* cấu hình của nó, và nó là máy disposable, dựng lại lúc nào
  cũng được, nên script đã sửa phải được áp dụng.

**Tính tái tạo.** `ignore_changes` chỉ bảo vệ instance đang tồn tại; instance dựng lại dùng giá trị của ngày
hôm đó. Mỗi lần dựng lại có thể bắt đầu từ một image Ubuntu mới hơn. Những gì bắt buộc giống hệt nhau được
ghim ở tầng trên: Ansible ghim Kubernetes `1.36.4-1.1`, containerd và Calico. Ghim AMI ID bằng một biến thì
chặt hơn, đổi lại phải tự tay nâng lên để nhận bản vá hệ điều hành.

**A3.5** Với `true`, mọi thay đổi trong user data đã render đều lên plan **thay thế**: tạo instance mới, và
Elastic IP chuyển sang nó, nên `vpn.recruitai.io.vn` giữ nguyên.

Bỏ nó đi thì provider cập nhật `user_data` **tại chỗ**, tức là stop rồi start instance. cloud-init chỉ chạy
user script một lần cho mỗi instance ID, nên script mới **không bao giờ chạy**. Gateway giữ cấu hình cũ
trong khi Terraform báo thành công. Đó chính là lý do `wireguard.tf` đặt thuộc tính này, kèm comment giải
thích.

**A3.6** Instance tham chiếu subnet, nhưng không có gì tham chiếu tới route table association. Vì vậy
Terraform có thể launch instance trước khi association tồn tại, trong lúc subnet vẫn dùng main route table
của VPC, không có route ra internet.

Không phải lúc nào cũng hỏng: bước `apt-get update` của `workstation-init.sh` thử lại 20 lần, cách nhau 15
giây, nên vài giây thiếu route nhiều khả năng vẫn qua. Nhưng các lệnh tải về phía sau không thử lại, `set -e`
dừng script ở lỗi đầu tiên, và cloud-init không bao giờ chạy lại. `depends_on` loại bỏ hẳn race đó bằng cách
ghi lại một thứ tự chỉ tồn tại lúc chạy.

Gateway cũng có rủi ro tương tự: nó tham chiếu `module.vpc.public_subnets`, giá trị này lấy từ resource
subnet chứ không phải từ route table association của module. Nó xoay xở bằng cách thử lại: mọi bước dùng
mạng trong `wireguard-init.sh` đều đi qua `retry` (10 lần, cách nhau 10 giây), và apt chờ lock tối đa 600
giây. Node không gặp rủi ro này vì chúng không chạy gì lúc boot.

**A3.7** Không. Terraform chỉ biết những gì nằm trong state của nó. Volume do EBS CSI tạo cho PVC (và
snapshot nếu có) là do Kubernetes gọi API AWS, nên không stack nào quản lý chúng.

**Khi `make infra-destroy`:** instance bị xoá, volume của PVC bị tách ra và chuyển sang `available`, rồi
**nằm lại và tiếp tục tính tiền**. Cluster dựng lại không biết gì về chúng. Tệ hơn, EBS CSI không dùng
`default_tags` của Terraform, nên nếu không cấu hình thêm thì các volume đó không có tag `project` và budget
không thấy chúng (xem A8.6).

**Cách xử lý:**

- trước khi destroy, xoá PVC (StorageClass `reclaimPolicy: Delete`) để driver tự xoá volume khi cluster còn
  sống
- cấu hình tag thêm cho volume trong Helm chart của driver (`extraVolumeTags`, ví dụ `project=medical-rag`)
- sau destroy, kiểm tra `aws ec2 describe-volumes --filters Name=status,Values=available`

**Destroy treo ở subnet hoặc security group:** AWS không cho xoá khi còn network interface dùng chúng, và báo
`DependencyViolation`. Nguyên nhân thường là ENI của NLB hay NAT gateway chưa giải phóng xong (tự hết sau vài
phút), hoặc ENI của thứ nằm ngoài state. Tìm bằng
`aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>`.

### A4. Mạng

**A4.1** `cidrsubnet(10.10.0.0/16, 8, n)` cộng thêm 8 bit vào mask và cho ra `10.10.n.0/24`:

- private (node): `10.10.1.0/24`, `10.10.2.0/24`, `10.10.3.0/24`
- public (NLB, NAT, gateway): `10.10.101.0/24`, `10.10.102.0/24`, `10.10.103.0/24`

**Không được trùng với:**

| Dải | CIDR |
|---|---|
| VPC của ops | `10.20.0.0/24` |
| WireGuard | `10.99.0.0/24` (đang nằm trong dải Service, xem A9.7) |
| Pod của Calico | `192.168.0.0/16` |
| Service của Kubernetes | `10.96.0.0/12` |

Trùng dải làm định tuyến trở nên mơ hồ. Một IP pod trùng IP trong VPC sẽ được giao trong mạng pod thay vì ra
VPC; route `10.10.0.0/16` trên laptop sẽ "nuốt" traffic đáng lẽ đi tới mạng ở nhà. Kiểu lỗi này biểu hiện
thành một số kết nối đi sai chỗ mà không báo lỗi gì, rất khó chẩn đoán. VPC peering và VPN cũng từ chối các
dải trùng nhau.

**A4.2** Một số region liệt kê Local Zone hoặc Wavelength Zone như AZ. Chúng cần opt-in và có thể không có
loại máy hay không hỗ trợ NLB. `opt-in-not-required` chỉ giữ lại AZ chuẩn, và `slice(..., 0, 3)` lấy ba cái.

`node_count = 4` đặt node 4 vào `private_subnets[3 % 3]`, tức subnet đầu tiên, cạnh node 1. Bốn member etcd
cần 3 để có quorum, nên vẫn chỉ chịu được **một** member lỗi, y như ba member. Hơn nữa, mất AZ đầu tiên giờ
làm mất hai member cùng lúc và mất quorum. Với etcd, số member luôn nên là số lẻ.

**A4.3** Gateway endpoint thêm prefix list của S3 theo region vào các route table **private**. Traffic từ
node tới S3 trong `ap-southeast-1` không đi qua NAT gateway, nên không mất phí xử lý theo GB của NAT:

- snapshot etcd
- FAISS index trong bucket artifacts
- file truyền của Ansible
- **các layer image pull từ ECR**, vì ECR phục vụ layer từ S3

**Vẫn đi qua NAT:**

- API và lệnh xác thực của ECR
- SSM, Secrets Manager, KMS, STS
- các registry khác (Docker Hub, quay.io)
- Gemini và Hugging Face
- S3 ở region khác, và tên toàn cục `s3.amazonaws.com`

Subnet public không được gắn endpoint; gateway ra S3 qua internet gateway, vốn không mất phí NAT.

**A4.4** Module đặt NAT gateway duy nhất ở subnet public đầu tiên, và mọi route table private gửi
`0.0.0.0/0` tới nó. WireGuard gateway cũng nằm ở `public_subnets[0]`, và node 1 ở subnet private cùng AZ. NAT,
VPN và node 1 **dùng chung một failure domain**. Nếu AZ đó sập:

**Ngừng chạy:**

- toàn bộ traffic ra internet của **cả ba** node, không riêng node trong AZ đó
- các lệnh gọi Gemini và Hugging Face của app, nên app không trả lời được câu hỏi
- kết nối của SSM agent, nên Session Manager, Ansible, `make ping` và `make tunnel` đều hỏng
- việc pull image mới
- việc làm mới secret từ Secrets Manager (các Kubernetes Secret đã có vẫn còn)
- truy cập Rancher, vì WireGuard gateway sập theo
- node 1

**Vẫn chạy:**

- traffic vào qua cả hai NLB, tới node 2 và 3
- Kubernetes API và etcd, vì 2/3 member vẫn sống
- S3 qua gateway endpoint

**Cách sửa:**

- mỗi AZ một NAT gateway (tốn thêm khoảng 0.12 USD/giờ)
- hoặc interface endpoint cho SSM, ECR, Secrets Manager, KMS và STS: tính tiền theo endpoint, theo AZ, theo
  giờ, và cũng không cứu được Gemini
- rẻ nhất: đặt gateway ở `public_subnets[1]` để ít nhất VPN không chết cùng NAT

**A4.5** VPC của ops có internet gateway nhưng không có NAT. SSM agent phải tới được các endpoint `ssm`,
`ssmmessages` và `ec2messages`, còn cloud-init phải tới được GitHub, HashiCorp và mirror của apt. Ở subnet
public, muốn vậy thì phải có public IP. Security group không có rule inbound nào, nên IP đó là lối ra chứ
không phải cửa vào.

Bỏ nó đi nghĩa là chuyển sang subnet private, cộng thêm NAT gateway, hoặc interface endpoint cho ba dịch vụ
SSM kèm một proxy cho mọi thứ còn lại. Cả hai đều đắt hơn phí IPv4 public 0.005 USD/giờ.

### A5. Security group

**A5.1** Hai đường, không còn gì khác:

1. **TCP 80 tới public NLB:** `aws_vpc_security_group_ingress_rule.ingress_nlb_http` (`0.0.0.0/0`), rồi
   `nodes_http_from_nlb` tới NodePort 30080.
2. **UDP 51820 tới WireGuard gateway:** `wireguard_udp`.

**Không phải đường vào:**

- Security group của workstation không có rule ingress nào (workstation có public IP, nhưng chỉ để đi ra).
- Node không có public IP.
- Internal NLB chỉ nhận từ `10.10.0.0/16`.
- Module VPC làm rỗng default security group của VPC cluster.

**A5.2** Mọi protocol và port từ bất kỳ network interface nào trong group `nodes` tới interface khác trong
group đó, và chỉ những interface đó. Rule này bao gồm:

- etcd `2379-2380` và API server `6443`
- kubelet `10250`
- Calico VXLAN `UDP 4789` và Typha `5473`
- NodePort giữa các node, và DNS tới CoreDNS trên node khác

Với VXLAN, traffic giữa các pod đi bên trong UDP 4789 giữa các IP node, nên security group chỉ thấy 4789,
không thấy port thật của pod.

**Siết lại:** mỗi port ở trên một rule. Cái giá là công bảo trì: quên một port là có thứ hỏng lặt vặt mà
không báo lỗi, ví dụ `kubectl logs` timeout khi thiếu 10250.

**A5.3**

- **Có ID và mô tả riêng.** Thêm hay bớt một rule không phải viết lại cả group.
- **Rule nằm được ở file khác.** `rancher.tf` thêm rule 443 vào các group định nghĩa trong `security.tf`.
- **Không tạo vòng phụ thuộc.** `nodes` tham chiếu `api_nlb` và `api_nlb` tham chiếu `nodes`. Nếu viết
  inline, mỗi group phụ thuộc vào group kia, và Terraform không sắp được thứ tự.

**Trộn cả hai kiểu trên một group:** Terraform coi danh sách inline là toàn bộ rule của group. Mỗi lần apply
nó xoá các rule do resource riêng tạo ra, lần apply sau tạo lại chúng, và plan không bao giờ ổn định.

**A5.4** **Trả lời ngắn:** firewall iptables trên gateway, không phải AWS.

Từ `wg0`, chain `WG_FWD` chỉ chuyển tiếp DNS tới `10.10.0.2` và TCP 443 vào `10.10.0.0/16`, rồi `DROP` mọi
thứ còn lại, nên một gói tin tới 6443 bị huỷ ngay trên gateway. `INPUT` từ `wg0` cũng bị drop.

**Gỡ lớp đó đi thì không còn gì chặn.** MASQUERADE gán cho laptop địa chỉ VPC của gateway, và địa chỉ này nằm
trong CIDR mà security group của NLB tin tưởng.

**Thêm một lớp ở AWS:** đổi rule 6443 trên `api_nlb` từ `cidr_ipv4 = var.vpc_cidr` sang
`referenced_security_group_id = aws_security_group.nodes.id`. Khi đó rule 6443 không còn khớp với traffic từ
gateway, nên AWS chặn luôn. Cách này đúng vì security group của NLB đánh giá network interface của *bên gọi*
(`preserve_client_ip` chỉ ảnh hưởng tới thứ target nhìn thấy), và mọi bên gọi hợp lệ đều đi ra từ ENI của
node:

- kubelet
- `make tunnel`: kết nối do SSM agent trên node 1 mở
- pod: traffic tới IP của NLB (nằm ngoài pod pool) bị Calico `natOutgoing` SNAT về IP của node

**Lưu ý:** rule 443 vẫn phải giữ theo CIDR, vì traffic WireGuard tới với IP của gateway. Sau khi đổi, kiểm tra
lại bằng test TCP từ laptop và metric `SecurityGroupBlockedFlowCount_Inbound` của NLB.

**A5.5** Security group chỉ gắn được vào NLB lúc tạo. NLB tạo ra không có security group thì không bao giờ
gắn thêm được, nên cách duy nhất là tạo NLB mới, tức DNS name mới.

Với NLB của API, đổi DNS name kéo theo sinh lại SAN trong certificate của API server, sửa mọi kubeconfig và
ConfigMap `cluster-info`: đau nhưng cứu được. Nếu `controlPlaneEndpoint` là một tên Route 53 ổn định (ví dụ
`api.recruitai.io.vn`) thay vì DNS name thô của NLB, đổi NLB chỉ còn là sửa một record.

Không có security group thì rule của node cũng phải tin theo dải IP thay vì tham chiếu group của NLB.

**A5.6** Security group của NLB có hai chiều với hai việc khác nhau:

- **Inbound** lọc client gọi vào listener.
- **Outbound** phải cho phép cả traffic chuyển tiếp tới target **lẫn health check**, vì health check xuất phát
  từ NLB. Thiếu `api_nlb_to_nodes` thì mọi target unhealthy dù API server vẫn chạy tốt.

Rule của node tham chiếu security group của NLB vẫn có hiệu lực kể cả khi bật client IP preservation, nên
`nodes_http_from_nlb` hoạt động với public NLB giữ IP client.

**Egress tường minh:** AWS tạo mỗi security group mới kèm rule cho ra tất cả, nhưng `aws_security_group` của
Terraform **xoá rule mặc định đó**. Vì vậy mọi egress phải được khai báo: `nodes_all`, `wireguard_all`,
`workstation_all`, và egress của hai NLB. Quên một cái là máy đó không ra được ngoài, ví dụ node không pull
được image.

### A6. Load balancer

**A6.1** Khi bật client IP preservation, internal NLB chuyển tiếp gói tin nguyên vẹn: IP nguồn vẫn là IP của
bên gọi. Khi node 1 gọi NLB và NLB chọn đúng node 1 làm target, node 1 nhận một gói tin có IP nguồn là chính
nó. Nó trả lời trực tiếp, không đi qua NLB, và kết nối không bao giờ hoàn tất. AWS ghi rõ vòng lặp này
(hairpinning) không được hỗ trợ khi bật preservation.

Triệu chứng là khoảng một phần ba lệnh gọi từ node tới API bị timeout, làm hỏng `kubeadm join` và khiến
kubelet chập chờn.

Với `false`, NLB thay IP nguồn bằng IP private của chính nó, nên phản hồi quay về qua NLB. Cái giá là API
server chỉ thấy địa chỉ của NLB, không thấy bên gọi thật.

Target group HTTP public giữ mặc định (bật). Bên gọi của nó đến từ internet, còn node gọi public NLB thì đi
ra qua NAT, nên IP nguồn là IP public của NAT, không bao giờ là IP của node.

**A6.2** Check TCP chỉ chứng minh port đang mở. API server mở 6443 trước khi phục vụ được: trong lúc khởi
động, hoặc khi không kết nối được etcd. `/readyz` chỉ trả 200 khi server thực sự sẵn sàng.

NLB không kiểm tra certificate và không gửi client certificate. Nó vẫn nhận được câu trả lời vì kubeadm để
`--anonymous-auth` bật, và role có sẵn `system:public-info-viewer` cho phép người dùng ẩn danh đọc `/readyz`,
`/livez`, `/healthz` và `/version`.

Tắt anonymous auth sẽ khiến mọi target thành unhealthy. Cách siết an toàn là cấu hình anonymous
authenticator để chỉ cho phép các endpoint health đó.

**A6.3** Không phải lỗi: chưa có API server nào cho tới khi Ansible chạy `kubeadm`.

Khi **mọi** target trong group đều unhealthy, NLB **fail open** và gửi traffic tới tất cả. Trong lúc
`kubeadm init`, chỉ node 1 đang lắng nghe, nên khoảng hai phần ba kết nối qua `controlPlaneEndpoint` rơi vào
node 2, 3 và bị từ chối. kubeadm thử lại. Khi node 1 qua được hai lần check (khoảng 20 giây), NLB gửi tất cả
về nó. Đây là nhiễu tạm thời, có thể đoán trước, và đã có trong phần troubleshooting của guide Ansible.

**A6.4** Cluster kubeadm không có cloud controller manager, cũng không có AWS Load Balancer Controller, nên
`type: LoadBalancer` sẽ `Pending` mãi. NLB của API cũng phải tồn tại **trước** cluster, vì kubeadm cần DNS
name của nó làm `controlPlaneEndpoint`. Vì vậy Terraform sở hữu các load balancer và tên của chúng;
ingress-nginx lắng nghe trên các NodePort cố định (30080, 30443) mà target group trỏ tới.

**Vì sao dùng target kiểu instance:** Terraform biết instance ID. IP của pod dưới Calico VXLAN không định
tuyến được từ VPC, nên target kiểu IP không tới được pod.

**Cái giá của thiết kế này:** thêm một chặng qua kube-proxy, và số port phải tự tay giữ khớp giữa Terraform
với Helm values.

**A6.5** **Tiết kiệm:** phí theo giờ và capacity unit của một NLB thứ ba, cộng thêm ba network interface.
Internal NLB đã có sẵn và nằm đúng subnet.

**Cái giá:**

- Một security group giờ canh cả hai listener, nên 443 và 6443 chung một mức tin tưởng toàn VPC ở tầng AWS.
- Sửa một listener cũng là sửa load balancer của API.
- `rancher.recruitai.io.vn` công khai địa chỉ private của NLB API.
- `aws_lb.api` giờ mang cả traffic không phải API, người đọc code khó nhận ra hơn.

### A7. Compute, IAM và instance metadata

**A7.1** Đó là số chặng mạng mà phản hồi token IMDSv2 được phép đi qua. Process chạy trên host cách một
chặng. Container có network namespace riêng cách hai chặng, vì traffic của nó phải qua veth hoặc bridge
trước.

| Máy | Hop limit | Vì sao |
|---|---|---|
| Workstation, gateway | 1 | Chỉ host cần credential, nên container trên đó không lấy được instance role |
| Node | 2 | EBS CSI driver và External Secrets chạy dưới dạng pod và xác thực bằng role của node, vì cluster tự quản lý không có IRSA hay Pod Identity |

**Để 2 thì đánh đổi:** **mọi** pod đều lấy được credential của node (xem A7.3). Biện pháp dự kiến là một
NetworkPolicy chặn `169.254.169.254` cho mọi namespace trừ vài namespace cần dùng.

**Giới hạn:** cả hop limit lẫn NetworkPolicy đều không chặn được pod `hostNetwork`. Pod đó dùng network của
host, nên tới IMDS chỉ với một chặng. Muốn chặn phải dùng policy admission (không cho pod thường bật
`hostNetwork`).

**A7.2** `GetAuthorizationToken` là action cấp registry mà IAM không giới hạn theo repository được, nên
resource hợp lệ duy nhất là `"*"`. Token tự nó không cấp quyền gì: mỗi lệnh pull hay push vẫn bị kiểm tra
theo ARN của repository trong `EcrPullPush`. Node vẫn chỉ tới được `medical-rag`.

**A7.3** **Không, thiệt hại lan ra ngoài project.** Inline policy ghi đúng ARN, nhưng hai AWS managed policy
gắn vào role là quyền toàn account, mà account này dùng chung với project khác.

**Từ nguy hiểm nhất tới ít nhất:**

1. **`kms:Sign` trên cosign key.** Kẻ tấn công ký được image của họ, và image đó qua được bước kiểm tra chữ
   ký lúc admission.
2. **Token GitHub trong `medical-rag/github`.** Nếu token ghi được vào repo mà Argo CD theo dõi, họ đổi được
   manifest và Argo CD tự deploy thay họ: tệ ngang hoặc hơn `kms:Sign`.
3. **`AmazonSSMManagedInstanceCore`:** `ssm:GetParameter(s)` trên `*`, tức đọc được mọi parameter trong
   account, kể cả `SecureString` mã hoá bằng key mặc định `aws/ssm`.
4. **`AmazonEBSCSIDriverPolicy`:** attach, detach, snapshot, modify **mọi** EBS volume trong account, không
   có điều kiện. Một pod có thể snapshot hoặc gắn đĩa của project khác.
5. **Ghi vào bucket `ssm-transfer`.** Plugin `aws_ssm` của Ansible tải file module từ bucket này rồi chạy với
   quyền root. Ghi đè file trong lúc Ansible đang chạy là chiếm được root trên node.
6. **`GetSecretValue` trên các secret còn lại:** key của Gemini và Hugging Face, mật khẩu bootstrap và
   private key TLS của Rancher.
7. **Quyền push ECR.** Push được tag mới; tag release là immutable nên không ghi đè được.
8. **Đọc và xoá trên bucket artifacts và etcd-backups.** Sửa được FAISS index (versioning cho phép quay lại),
   hoặc đọc snapshot etcd, vốn chứa mọi Kubernetes Secret.

**Hiện tại cái gì hạn chế:** rất ít, và tài liệu thiết kế nói rõ đây là giới hạn đã biết. Biện pháp dự kiến:

- NetworkPolicy chặn IMDS
- Kyverno kiểm tra chữ ký image (một quyền `kms:Sign` bị đánh cắp vẫn vượt qua được)
- IRSA tự host, để mỗi workload có role riêng và bỏ được hai managed policy khỏi role dùng chung

**A7.4** Gateway là máy lộ ra ngoài nhiều nhất: có public IP và một port UDP mở. Nếu dùng role của node, bị
chiếm quyền ở đó sẽ lộ tất cả những gì ở A7.3. Role riêng của nó có `AmazonSSMManagedInstanceCore` và một
statement inline: `GetSecretValue` và `DescribeSecret` chỉ trên `medical-rag/wireguard`.

Node không đọc được secret này vì policy của node liệt kê ARN secret tường minh: `llm`, `github`, `rancher`,
`rancher-tls`. Không có wildcard nào bao được `wireguard`. (Shared tạo năm secret; node đọc bốn, gateway đọc
riêng cái thứ năm.)

Lưu ý: `AmazonSSMManagedInstanceCore` vẫn cho gateway đọc mọi SSM parameter trong account, giống node.

**A7.5** `value` của data source `aws_ssm_parameter` luôn bị đánh dấu sensitive, vì parameter có thể là
`SecureString`. Như vậy AMI ID, và mọi giá trị suy ra từ nó, sẽ hiện là `(sensitive value)` trong mọi plan.
`insecure_value` trả về cùng giá trị nhưng không đánh dấu. Parameter AMI của Canonical là thông tin công
khai, nên không lộ gì mà plan vẫn đọc được.

**A7.6** **Giảm `node_count` xuống 2.** `count` xoá **index cao nhất**: `aws_instance.nodes[2]` (node 3)
cùng hai target group attachment của nó. Với `count` bạn không xoá riêng node 2 được, vì index sẽ bị dồn
lại. Đó là lập luận kinh điển để dùng `for_each` với key ổn định.

**Thay riêng node 2:** `terraform apply -replace='aws_instance.nodes[1]'`.

**Trong Kubernetes, làm trước:**

1. Chụp snapshot etcd.
2. Drain node.
3. Gỡ member etcd của nó: chạy `kubeadm reset` trên node, hoặc `etcdctl member remove`.
4. Xoá object Node.
5. Thay node bằng Terraform, rồi join máy mới bằng Ansible.
6. Kiểm tra etcd có 3 member khoẻ trước khi động tới node tiếp theo.

Bỏ qua bước gỡ member thì etcd giữ lại một member chết: 3 member mà chỉ 2 sống, nên lỗi **tiếp theo** là mất
quorum. Node mới sau đó thành member thứ tư.

### A8. Các dịch vụ dùng chung

**A8.1** **Tag immutable.** Tag theo git SHA không bao giờ bị ghi đè, nên image đã được scan và ký chính là
image đang chạy.

**Hai ngoại lệ:**

- `sha256-*`: tag chữ ký kiểu cũ của cosign, bị ghi lại khi thêm chữ ký.
- `buildcache*`: cache của BuildKit, bị ghi lại sau mỗi lần build.

Nếu các tag này cũng immutable thì việc ký và dùng cache sẽ lỗi.

**Lifecycle policy chỉ đếm `tagged`.** Cosign v3 lưu chữ ký và SBOM attestation dưới dạng OCI *referrer*
không có tag của image. Rule đếm `any` hoặc `untagged` sẽ xoá chúng. Image đang chạy mất chữ ký, và lần khởi
động pod tiếp theo sẽ không qua được bước kiểm tra.

**A8.2** Với key bất đối xứng, private key không bao giờ rời KMS: CI gọi `kms:Sign`, còn ai cũng kiểm tra
được bằng public key, vốn không phải bí mật. `SIGN_VERIFY` cũng có nghĩa key không dùng để mã hoá được.

Key nằm ở `shared/` vì chữ ký chỉ kiểm tra được bằng đúng key đã tạo ra nó. Key tạo lại là một cặp key mới,
nên mọi chữ ký hiện có đều không qua được kiểm tra và mọi image phải ký lại. Deletion window 7 ngày cho thời
gian huỷ một lần xoá nhầm.

**A8.3** Để giá trị không bao giờ lọt vào state hay Git. `aws_secretsmanager_secret_version` với
`secret_string` sẽ lưu plaintext trong state, và giá trị phải đi vào qua một biến: nằm trong file tfvars,
biến môi trường hoặc lịch sử shell.

Terraform 1.11 thêm **write-only argument**: `secret_string_wo` của AWS provider được gửi lên AWS nhưng không
lưu trong state hay plan. Nó cần thêm `secret_string_wo_version` (tăng số này mới đẩy giá trị mới), và giá
trị vẫn phải đi vào qua một biến `ephemeral`. Tạo secret rỗng vẫn đơn giản hơn: giá trị được nhập một lần, từ
một file.

**A8.4** Trong chuỗi Terraform, `${` bắt đầu một phép nội suy. Viết một ký tự `$` đứng ngay trước
`${var.project}` đòi hỏi escape rất rối, và `format("user:project$%s", var.project)` tránh được chuyện đó.

**Trước khi budget đếm được gì:**

- **Kích hoạt tag.** Trong Billing, mục *Cost allocation tags*, kích hoạt `project` làm tag do người dùng
  định nghĩa. Tag xuất hiện tối đa 24 giờ sau khi resource có tag đầu tiên được tạo.
- **Account trong Organization.** Chỉ management account kích hoạt được.
- **Không tính ngược.** Chi phí trước lúc kích hoạt không được gán tag.
- **Độ trễ.** Budget cập nhật vài lần mỗi ngày, nên cảnh báo luôn chậm hơn chi phí thực.

**A8.5** **Không phải drift theo nghĩa của Terraform.** `aws_route53_zone` chỉ quản lý zone, không quản lý
record bên trong. Record không được khai báo ở đâu thì không nằm trong state nào, nên `plan` không bao giờ
nhắc tới chúng, dù bị sửa hay bị xoá.

**Vì sao để tay:** CNAME xác minh chỉ dùng khi đặt hoặc gia hạn certificate, giá trị do Sectigo cấp lúc đặt
hàng; các record chép sang là việc làm một lần khi chuyển DNS.

**Cái giá:** chúng không được review, không tái tạo được nếu zone mất, và không ai biết chúng tồn tại nếu
không mở console. Cách chặt hơn là khai báo `aws_route53_record` trong `shared/`, với giá trị qua biến (không
phải bí mật). Một tác dụng phụ đáng giá của việc để chúng trong zone: chúng làm lệnh xoá zone lỗi
`HostedZoneNotEmpty` (A3.2).

**A8.6** `default_tags` gắn `project`, `owner`, `stack`, `managed-by` (và `env` ở shared, cluster) lên mọi
resource **mà provider đó tạo** và có hỗ trợ tag. Tag khai báo ở resource được gộp vào, trùng key thì tag của
resource thắng.

**Vẫn lọt khỏi budget:**

- **Thứ Terraform không tạo:** volume và snapshot do EBS CSI tạo (A3.7), ENI mà AWS tự tạo cho NLB và NAT
  gateway.
- **Khoản phí không gắn với resource có tag:** thuế, support, một phần phí truyền dữ liệu.
- **Chi phí trước khi kích hoạt tag.**

**Kiểm tra thay vì đoán:** `aws resourcegroupstaggingapi get-resources --tag-filters
Key=project,Values=medical-rag` để xem cái gì có tag, và trong Cost Explorer nhóm theo tag `project` để xem
dòng *No tag key* còn bao nhiêu.

### A9. WireGuard và DNS

**A9.1** `templatefile` thay các phép nội suy `${...}` (và directive `%{...}`) bằng map truyền vào trong
`wireguard.tf`:

- `region`, `secret_id`
- `server_address`, `peer_address`
- `wireguard_cidr`, `vpc_cidr`, `vpc_resolver`

`$PRIVATE_KEY` không có ngoặc nhọn thì không phải cú pháp template, nên tới máy nguyên như đã viết. Bash mở
rộng nó lúc chạy; heredoc không có nháy `<<EOF` sau đó ghi key thật vào `wg0.conf`.

`${PRIVATE_KEY}` sẽ làm plan lỗi với *vars map does not contain key "PRIVATE_KEY"*. Biến bash nào cần ngoặc
nhọn thì phải viết `$${PRIVATE_KEY}`.

**A9.2** User data không phải chỗ cất bí mật:

- Ai có `ec2:DescribeInstanceAttribute` cũng đọc được.
- Bất kỳ process nào trên máy cũng lấy được qua IMDS.
- Terraform lưu nó nguyên văn trong state (A1.6) và hiện nó trong plan.
- Key truyền qua template trước hết phải là một biến Terraform, nên cũng sẽ nằm trong file tfvars hoặc
  lịch sử shell.

Lấy lúc boot thì key chỉ tồn tại trong Secrets Manager (mọi lần đọc được CloudTrail ghi lại, chỉ role của
gateway đọc được) và trong `/etc/wireguard/wg0.conf` với quyền 600. Gateway dựng lại lấy đúng key cũ, nên
profile trên laptop không bao giờ phải đổi.

**A9.3** Source/destination check huỷ gói tin có IP nguồn hoặc đích không phải địa chỉ của chính instance.
Mọi gói tin trên network card của gateway đều dùng địa chỉ của chính nó:

- **Gói tin tunnel** tới dưới dạng UDP gửi đến gateway.
- **Traffic đã giải mã** đi ra sau MASQUERADE với IP nguồn là địa chỉ VPC của gateway.
- **Phản hồi** quay về đúng địa chỉ đó; conntrack đảo ngược NAT, mã hoá lại và gửi đi dưới dạng UDP từ
  gateway.

Chỉ phải tắt check này nếu VPC định tuyến `10.99.0.0/24` tới gateway mà không NAT, để cluster thấy được địa
chỉ của laptop.

**A9.4** `associate_public_ip_address = true` cho cloud-init có internet ngay lập tức. Khi `aws_eip` được gắn
vào, địa chỉ public đổi, và mọi kết nối TCP đang mở lúc đó bị đứt: một lượt tải của `apt`, file zip AWS CLI,
lệnh gọi Secrets Manager.

Script bọc mọi bước dùng mạng trong `retry` (10 lần, cách nhau 10 giây), và apt chờ lock dpkg tối đa 600
giây. Bước kiểm tra key `jq -e '.serverPrivateKey and .operatorPublicKey'` cố tình không thử lại: thiếu key
không phải lỗi tạm thời, và script nên dừng với `status: error`.

**A9.5** Địa chỉ **private** của internal NLB, mỗi AZ một `10.10.x.x`. Chúng không định tuyến được trên
internet, nên câu trả lời vô dụng nếu không có đường vào VPC. Nó chỉ để lộ cách đánh địa chỉ của VPC.

**Đổi lại được:**

- Một tên dùng chung cho laptop qua WireGuard và cho agent của Rancher bên trong VPC.
- Certificate công khai khớp đúng tên đó.
- Không cần private hosted zone hay rule cho resolver.

**A9.6** Trong mọi VPC, DNS resolver do Amazon cung cấp nằm ở địa chỉ gốc của VPC cộng hai: `10.10.0.2` với
`10.10.0.0/16`. Từ trong VPC nó cũng trả lời ở `169.254.169.253`.

Vì sao laptop dùng nó: đây là lập luận thiết kế chứ không phải sự cố đã gặp. Nhiều router gia đình và một số
nhà mạng bật **chống DNS rebinding**: họ bỏ các câu trả lời public trỏ tới địa chỉ private như `10.10.x.x`,
nên `rancher.recruitai.io.vn` có thể không phân giải được. `10.10.0.2` nằm trong `AllowedIPs`, và gateway
chuyển tiếp port 53 tới nó, nên truy vấn đi trong tunnel và nhận câu trả lời sạch.

**Đánh đổi:** khi tunnel bật, toàn bộ DNS của laptop đi qua tunnel. Nếu gateway chết, duyệt web bị treo cho
tới khi tắt tunnel.

**A9.7** Không khớp: **mô tả đúng, giá trị mặc định vi phạm nó.** `10.96.0.0/12` trải từ `10.96.0.0` tới
`10.111.255.255`, và `10.99.0.0/24` nằm trong đó.

**Vì sao hiện tại chưa ảnh hưởng:**

- MASQUERADE giấu `10.99.x.x` khỏi cluster.
- Gateway không phải node Kubernetes, nên không có rule Service nào.
- Laptop chỉ định tuyến `10.10.0.0/16` vào tunnel.

**Khi nào sẽ ảnh hưởng:** ngay khi `10.99.x.x` tới được cluster, ví dụ nếu bỏ NAT để thấy địa chỉ thật của
client. Khi đó bất cứ thứ gì coi cả dải Service là nội bộ cluster (định tuyến, NetworkPolicy, cấu hình
Calico) đều có thể định tuyến sai hoặc chặn nó.

**Cách sửa:** đổi mặc định ra ngoài cả bốn khối, ví dụ `10.200.0.0/24`, và sửa `Address` trong profile tunnel
trên laptop.

**A9.8** Một request, `https://rancher.recruitai.io.vn`:

1. **DNS.** Truy vấn đi qua tunnel tới `10.10.0.2`. Gateway chấp nhận UDP 53 trong `WG_FWD`, MASQUERADE rồi
   chuyển tiếp. Resolver đi theo alias và trả về các IP private của internal NLB.
2. **Laptop.** Gói SYN tới `10.10.x.x:443` khớp `AllowedIPs = 10.10.0.0/16`. WireGuard mã hoá và gửi UDP tới
   EIP của `vpn.recruitai.io.vn`, port 51820.
3. **Vào AWS.** `wireguard_udp` cho phép UDP 51820. Internet gateway dịch EIP thành IP private của gateway.
4. **Gateway.** `wg0` giải mã. IP nguồn `10.99.0.2` được chấp nhận vì khớp `AllowedIPs` của peer.
   `FORWARD -i wg0` nhảy sang `WG_FWD`, nơi chấp nhận TCP 443 vào VPC. MASQUERADE ở `POSTROUTING` đổi IP nguồn
   thành địa chỉ VPC của gateway.
5. **NLB.** Security group của gateway cho phép mọi egress. `api_nlb_https_from_vpc` cho phép 443 từ VPC.
   Listener chuyển tới `ingress_https`, và `preserve_client_ip = false` đổi IP nguồn thành IP của NLB.
   `api_nlb_to_nodes_https` cho phép egress tới 30443, và `nodes_ingress_https` cho nó vào node.
6. **Node.** Rule NodePort của kube-proxy đổi đích thành IP của một pod ingress-nginx. Nếu pod đó ở node
   khác, Calico bọc gói tin trong VXLAN (UDP 4789, được `nodes_from_nodes` cho phép).
7. **Ingress.** ingress-nginx terminate TLS bằng certificate Sectigo (`tls-rancher-ingress`), định tuyến theo
   header `Host` tới Service của Rancher, rồi tới một pod Rancher, có thể qua thêm một chặng VXLAN.
8. **Phản hồi** đi ngược lại từng lần dịch địa chỉ nhờ conntrack. Trên gateway,
   `FORWARD -o wg0 ... ESTABLISHED,RELATED` cho chúng quay vào, NAT được đảo ngược về `10.99.0.2`, và gói tin
   được mã hoá gửi về địa chỉ public của laptop.

Bước 6 và 7 chỉ tồn tại sau khi phase GitOps cài ingress-nginx và Rancher.

---

## Phần B — Phỏng vấn

Câu trả lời mẫu viết theo giọng nói, ngôi thứ nhất. Khi phỏng vấn bằng tiếng Anh, giữ nguyên ý và các thuật
ngữ.

### B1. Kiến trúc và quyết định

**B1.1** "Tôi chia Terraform thành ba stack theo vòng đời, state của cả ba nằm trong một bucket S3 có state
lock native.

Stack bootstrap chỉ apply một lần từ CloudShell. Nó tạo bucket state và một ops workstation mà tôi chỉ vào
qua SSM, nên laptop không cần cài công cụ cloud nào.

Stack shared giữ những thứ phải sống sót khi cluster bị xoá: ECR với tag immutable và scan on push, một KMS
key để ký image, bucket chứa index, năm secret mà Terraform tạo rỗng, Route 53 zone và một budget.

Stack cluster bị xoá khi không dùng. Nó có một VPC trải ba AZ với một NAT gateway, ba node trong subnet
private mà Ansible sẽ biến thành cluster kubeadm HA, một internal NLB cho API và một public NLB cho app, và
một WireGuard gateway nhỏ để vào Rancher riêng tư. Security group tham chiếu lẫn nhau thay vì dải IP, và
inline policy của các role ghi đúng ARN.

Bản cluster 65 resource destroy mất 1 phút 27 giây, dựng lại từ đầu mất 3 phút 19 giây, và plan sau đó báo
không có thay đổi. Bản đầy đủ 84 resource có WireGuard đã dựng thành công, tôi chưa đo lại thời gian. Chạy
cluster tốn khoảng nửa đô mỗi giờ.

Terraform dừng ở ranh giới máy: Ansible cấu hình node, Argo CD sở hữu mọi thứ bên trong cluster."

*Hỏi tiếp:* vì sao chọn ranh giới đó (B1.3); các stack nói chuyện với nhau thế nào (A2.2).

**B1.2** Mục đích của project này là tự vận hành control plane: etcd HA, backup và restore, certificate,
nâng cấp phiên bản. EKS giấu đúng những kỹ năng đó. Project thứ hai của tôi dùng EKS, nên hai project bổ sung
cho nhau: một bên tự vận hành control plane, một bên dùng managed. EKS cũng tốn thêm 0.10 USD/giờ cho control
plane.

**Những gì tôi từ bỏ:**

- nâng cấp được quản lý sẵn và SLA
- IRSA / Pod Identity, nên pod dùng chung role của node
- AWS Load Balancer Controller, nên NLB là tĩnh và NodePort cố định
- thêm việc phải bảo trì

**Ở công ty:** tôi mặc định chọn EKS, trừ khi có lý do cụ thể: cần giống môi trường on-premise, cần phiên bản
EKS không có, hoặc quy mô lớn tới mức phí control plane đáng kể.

**B1.3** Với mỗi resource tôi hỏi một câu: *nếu xoá nó mỗi khi không dùng, tôi mất gì?*

- **Không mất gì** (mạng, node, NLB): cho vào `cluster/`, xoá khi không dùng.
- **Mất thời gian, tiền hoặc niềm tin** (index tốn quota API, giá trị secret gõ tay, KMS key mới làm mất hiệu
  lực chữ ký, zone mới làm đổi name server): cho vào `shared/`.
- **Thứ bản thân Terraform cần** (bucket state) và **máy tôi chạy Terraform**: cho vào `bootstrap/`, apply
  từ CloudShell.

State tách riêng còn giới hạn phạm vi ảnh hưởng (plan của cluster không động được tới KMS key) và giữ plan
chạy nhanh. Workspace không hợp: workspace dùng lại một cấu hình với nhiều state, còn ba cấu hình này khác
nhau.

**B1.4** Ba lý do:

- **Kubernetes API cần TCP passthrough.** Client xác thực bằng certificate trong mutual TLS, mà ALB thì
  terminate TLS.
- **TLS của Rancher terminate ở ingress-nginx** bằng certificate đã mua, nên không load balancer hay ACM nào
  giữ private key.
- **ingress-nginx đã định tuyến HTTP rồi,** nên ALB chỉ làm trùng việc.

NLB còn có một IP cố định mỗi AZ và giờ đã hỗ trợ security group.

**ALB sẽ mang thêm:** WAF, certificate ACM, health check và định tuyến ở tầng HTTP. Với app public ở
production, tôi sẽ đặt một ALB có certificate ACM phía trước để có HTTPS.

**B1.5** Chỉ Session Manager:

- không có port inbound
- không có key pair phải rotate hay có thể bị lộ
- IAM quyết định ai được vào; session có thể ghi log ra S3 hoặc CloudWatch (hiện chưa bật)
- Ansible dùng connection plugin `aws_ssm`, còn kubectl đi qua SSM port-forward

Bastion sẽ thêm một máy public, SSH key và thêm một hệ điều hành phải vá.

**Đánh đổi:**

- Ansible qua SSM chậm hơn, vì module phải đi qua S3.
- Node phụ thuộc NAT để tới SSM.
- Ai được phép mở session trên workstation thì thừa hưởng role admin của nó.

**B1.6** "Client VPN tốn vài chục đô mỗi tháng kể cả khi không dùng. SSM port-forward làm certificate không
khớp tên. Mở HTTPS theo IP nhà thì IP đổi liên tục, mà Rancher lại là UI admin. WireGuard rẻ, xoá cùng
cluster, và port UDP của nó im lặng với người không có key."

| Lựa chọn | Vì sao không, hoặc vì sao có |
|---|---|
| AWS Client VPN | Được quản lý sẵn và hỗ trợ SAML, nhưng tính tiền theo giờ cho mỗi subnet gắn vào cộng theo giờ cho mỗi kết nối |
| SSM port-forward | Ổn cho một port TCP, nhưng trình duyệt phải gọi `rancher.recruitai.io.vn` thì certificate mới khớp, nên phải sửa file hosts trỏ tên đó về localhost. Session cũng hay hết hạn |
| HTTPS public + chỉ cho phép IP của tôi | IP ở nhà thay đổi, và tôi không muốn một UI cluster-admin phơi ra internet chờ lỗ hổng tiếp theo |
| **WireGuard (đã chọn)** | Máy nhỏ khoảng 0.03 USD/giờ. Split tunnel. Domain và certificate thật dùng được |

**Cái giá tôi chấp nhận:**

- Tôi tự vận hành gateway, và nó nằm cùng AZ với NAT gateway (A4.4).
- Key quản lý bằng tay.
- Bộ lọc traffic nằm trong iptables trên gateway (A5.4 nói cách thêm một lớp ở AWS).

**B1.7** VPC dùng module cộng đồng được ghim phiên bản (`~> 6.7`). Subnet, route table, association, NAT,
cùng default security group và NACL mà module quản lý luôn, tổng cộng 23 resource: phần boilerplate mạng mà
cộng đồng dùng rất rộng rãi.

Mọi thứ khác là resource thường, vì chỉ có một môi trường và một nơi dùng. Module chỉ dùng một lần chỉ thêm
một lớp abstraction, còn người đọc thì theo được từng file từ trên xuống dưới.

Tôi sẽ tách module khi có nơi dùng thứ hai. Ứng viên đầu tiên là module *hardened bucket*: bucket, public
access block, mã hoá, policy chỉ TLS và lifecycle rule đang lặp lại cho bốn bucket.

**B1.8**

**HA:**

- ba node ở ba AZ với stacked etcd, chịu được mất một node
- internal NLB bật cross-zone với health check `/readyz`
- public NLB trải trên ba subnet public

**Single point of failure đã chấp nhận:**

- **Một NAT gateway:** toàn bộ traffic ra internet, gồm cả Gemini và SSM. Tiết kiệm khoảng 0.12 USD/giờ.
- **WireGuard gateway:** chỉ UI quản trị phụ thuộc vào nó.
- **Workstation:** chỉ việc vận hành phụ thuộc vào nó.
- **Một region.**

**Điểm tôi tự tìm ra khi rà lại:** NAT, WireGuard và node 1 cùng nằm ở AZ đầu tiên, nên một sự cố AZ đánh sập
cả ba cùng lúc (A4.4). Sửa rẻ nhất là dời gateway sang subnet thứ hai.

Với lab, tôi thấy ghi rõ từng SPOF kèm lý do chi phí quan trọng hơn là cố loại bỏ hết.

### B2. State và làm việc nhóm

**B2.1** Một bucket S3 do stack bootstrap tạo:

- bật versioning, noncurrent version hết hạn sau 90 ngày
- mã hoá SSE-S3 và bật đủ bốn cài đặt public access block
- bucket policy từ chối mọi request không dùng TLS
- `prevent_destroy`

Mỗi stack một key riêng, nên sai sót ở state này không làm hỏng state khác. Lock là native: object `.tflock`
tạo bằng conditional write, không cần bảng DynamoDB (chi tiết ở A1.3, A1.4).

**Bước tiếp theo ở công ty:** một account riêng cho state, KMS key do khách hàng quản lý, bucket policy ghi rõ
các role được phép, và bản sao hoặc backup nằm ngoài account.

**B2.2**

- State lock đã ngăn hai lệnh apply đè lên nhau.
- Không ai apply từ laptop hay workstation nữa: thay đổi đi qua pull request, CI đăng plan lên, reviewer
  duyệt, và CI apply đúng plan đã lưu đó.
- Mỗi kỹ sư có một role chỉ đủ cho việc của mình (B3.6).
- pre-commit chạy `fmt`, `validate` và `tflint`.
- `CODEOWNERS` bảo vệ `bootstrap/` và `shared/`.
- Lock file được commit cho mọi stack.
- Có một lần kiểm tra drift theo lịch (B2.4).

**B2.3** Phần này tôi chưa dựng, vì lab chỉ có một người vận hành; đây là cách tôi sẽ làm.

- **Credential:** OIDC federation từ hệ thống CI tới IAM role, nên không có key dài hạn nào tồn tại. Hai role:
  - role *plan*: chỉ đọc resource, đọc được state, và ghi được object `.tflock` (plan cũng lấy lock), hoặc
    chạy plan với `-lock=false`
  - role *apply*: chỉ dùng được từ branch hoặc environment được bảo vệ, sau khi đã duyệt
- **Plan và apply:** `terraform plan -out=tfplan`, lưu làm artifact; bước apply chạy `terraform apply tfplan`,
  nên thứ đã được review chính là thứ được chạy.
- **Đồng thời:** mỗi stack chỉ một job tại một thời điểm, thêm vào state lock.

**B2.4** **Không, trong project này thì không thấy.** Rule được viết thành resource riêng, và Terraform chỉ so
những gì có trong state; một rule thêm tay không nằm trong state nào. Plan *sẽ* thấy nếu ai đó sửa một rule
đang được quản lý, hoặc sửa một group được định nghĩa bằng block inline.

**Phát hiện:**

- `terraform plan -detailed-exitcode` chạy theo lịch (exit code 2 nghĩa là có thay đổi) cho resource được
  quản lý
- AWS Config rule, hoặc script so `describe-security-group-rules` với tập rule mong muốn, cho những thứ thêm
  ngoài Terraform

**Xử lý:** apply để trả về như cũ, hoặc đưa nó vào code bằng block `import` và review như mọi thay đổi khác.
Tag `managed-by = terraform` trên mọi resource nhắc mọi người đừng sửa tay.

**B2.5**

- **Đổi tên trong một stack:** block `moved` (Terraform 1.1+). Plan hiện là di chuyển, không phải xoá rồi tạo
  lại.
- **Chuyển giữa các stack:** ở stack cũ, block `removed` với `lifecycle { destroy = false }` (1.7+) làm
  Terraform quên resource mà không xoá nó. Ở stack mới, block `import` (1.5+) nhận nó vào. Cách cũ tương đương
  là `terraform state rm` và `terraform import`.

Quy tắc cho cả hai: plan phải báo **0 to destroy** trước khi ai đó gõ `yes`.

`moved`, `removed` và `import` chỉ đổi địa chỉ trong Terraform. Đổi tên thật trên AWS (tên bucket, tên
secret) vẫn là tạo resource mới.

**B2.6** Tốt nhất là **một AWS account riêng** cho prod: ranh giới mạnh nhất về IAM, quota và chi phí. Tối
thiểu là một state key và backend riêng.

**Cấu trúc code:**

- biến các mẫu lặp lại thành module
- tạo thư mục `envs/dev` và `envs/prod` gọi các module đó với biến riêng
- hoặc dùng Terragrunt để nối phụ thuộc giữa các stack

Tôi không dùng workspace của CLI cho các môi trường khác nhau nhiều như vậy.

**Prod sẽ khác ở:**

- không xoá khi không dùng
- mỗi AZ một NAT gateway
- HTTPS cho app
- interface endpoint
- zone hoặc subdomain riêng

**B2.7** `terraform apply` tương tác tự tính plan, hiện ra, chờ `yes`, rồi apply **đúng plan đó**. Nên plan
không bị cũ, và với một người vận hành thì chấp nhận được.

**Rủi ro:**

- Không có bản ghi nào về plan đã được duyệt, và không ai khác review.
- Thói quen gõ `yes` mà không đọc, nhất là với plan dài. Guide vì vậy luôn ghi con số mong đợi ("84 to add")
  để so dòng tóm tắt.
- Chạy nhầm stack hoặc nhầm account mà không có bước chặn.

**Khi nào đổi:** ngay khi có người thứ hai hoặc có CI. Khi đó `make plan` ghi `-out=tfplan`, người review đọc
`terraform show tfplan`, và `terraform apply tfplan` chạy đúng thứ đã duyệt. Nếu state đổi giữa chừng,
Terraform từ chối plan cũ thay vì apply sai.

### B3. Bảo mật

**B3.1**

- **Git:** `.gitignore` loại `*.tfvars` (chỉ commit file `.example`) và mọi file state. Giá trị tfvars thật duy
  nhất là email nhận cảnh báo budget.
- **State của Terraform:** Terraform tạo secret **rỗng**. Giá trị được đưa vào một lần bằng
  `put-secret-value --secret-string file://…`, sau đó file bị xoá bằng `shred -u`.
- **Key được sinh ngay nơi dùng:**
  - Private key của Rancher được tạo trên workstation.
  - Server key của WireGuard do gateway lấy lúc boot.
  - Private key WireGuard của laptop không bao giờ rời laptop.
- **Không có access key:** CloudShell dùng phiên console, mọi máy dùng instance role.
- **Vào cluster:** sau này External Secrets đồng bộ giá trị vào.

**Rủi ro còn lại:** thứ gì gõ inline sẽ nằm trong lịch sử shell, và role admin của workstation đọc được mọi
secret.

**B3.2** **Chỗ đạt:** inline policy của node ghi đúng ARN (một repository, ba bucket, bốn secret, một key),
còn gateway đọc được một secret. `"*"` duy nhất trong inline policy là token xác thực của ECR, thứ IAM không
giới hạn được.

**Chỗ chưa đạt, và tài liệu thiết kế có nói rõ phần lớn:**

- **Workstation có `AdministratorAccess`.** Ai được mở SSM session trên nó là admin.
- **Mọi pod dùng chung role của node.**
- **Hai managed policy trên role của node là quyền toàn account:** đọc mọi SSM parameter, và attach, detach,
  snapshot mọi EBS volume (A7.3). Account lại dùng chung với project khác.
- **Internal NLB tin cả CIDR của VPC.**

**Cách sửa:** tách role plan và role apply, IAM riêng cho từng workload bằng IRSA tự host, và tham chiếu
security group thay cho CIDR.

**B3.3** **Mở ra internet:**

- TCP 80 trên public NLB, cho app. HTTPS cho app nằm ngoài phạm vi và đã ghi rõ như vậy.
- UDP 51820 trên WireGuard gateway.

**Không mở:** không có SSH ở đâu cả, node không có public IP, workstation có public IP nhưng không có rule
inbound, bắt buộc IMDSv2, EBS mã hoá, S3 chặn truy cập public và chỉ nhận TLS.

**Đã kiểm chứng:**

- request HTTP thường tới bucket state trả `AccessDenied`
- IAM policy simulation cho thấy `kms:Sign` trên cosign key là `allowed`, còn `s3:GetObject` trên bucket lạ
  là `implicitDeny`
- rà rule inbound: ở step 15 TCP 80 là rule duy nhất mở ra internet, step 18 thêm UDP 51820
- qua tunnel, handshake WireGuard thành công và DNS trả về IP private của NLB

**Sẽ kiểm chứng ở phase GitOps:** qua VPN, test TCP cho thấy 443 mở và 6443 đóng, sau khi cài ingress-nginx.

**B3.4** Họ dùng được instance role của node qua IMDS, vì node đặt hop limit 2 để chính các pod driver làm
được việc đó. Nặng nhất là `kms:Sign` (image độc hại đã ký qua được admission), token GitHub (đổi được thứ
Argo CD deploy), và hai managed policy cho quyền toàn account trên SSM parameter và EBS volume. Chi tiết ở
A7.3.

**Vì sao:** cluster tự quản lý không có sẵn IRSA hay Pod Identity, mà một số pod hệ thống cần quyền AWS.

**Dự kiến:** NetworkPolicy chặn địa chỉ metadata trừ vài namespace cần dùng, Kyverno cho chính sách image, và
IRSA tự host để mỗi workload có role riêng.

**B3.5**

- **Kiểm tra tĩnh:** `terraform fmt -check`, `terraform validate`, `tflint` với bộ rule AWS, và Checkov hoặc
  Trivy (đã gộp tfsec). Chạy trong pre-commit và chạy lại trong CI.
- **Quy tắc của tổ chức:** OPA/Conftest trên `terraform show -json` của plan, ví dụ "không có ingress
  `0.0.0.0/0` ngoài hai rule này".

**Những cảnh báo scanner sẽ đưa ra ở đây:**

| Cảnh báo | Quyết định |
|---|---|
| Không bật S3 access logging | Bỏ qua: bucket nhỏ, CloudTrail đã ghi các API call quản lý |
| SSE-S3 thay vì KMS key do khách hàng quản lý | Bỏ qua: lab, không cần key policy riêng |
| Egress mở tới `0.0.0.0/0` | Bỏ qua: node cần ra Gemini, ECR, SSM qua NAT |
| Public IP của workstation | Bỏ qua: không có rule inbound, chỉ là lối ra |
| `AdministratorAccess` trên workstation | Giữ lại làm lỗi thật |
| Managed policy toàn account trên role của node | Giữ lại làm lỗi thật |

Mục tiêu là phân loại từng cảnh báo kèm lý do, chứ không phải cố ép scanner về 0 cảnh báo.

**B3.6** Chia theo nhóm quyền:

- **State:** `s3:ListBucket` trên bucket state; `GetObject`, `PutObject` trên `cluster/terraform.tfstate`;
  `PutObject`, `DeleteObject` trên `cluster/terraform.tfstate.tflock`.
- **Tra cứu shared:** `ecr:DescribeRepositories`, `s3:GetBucket*`, `kms:DescribeKey` và `kms:ListAliases`,
  `secretsmanager:DescribeSecret`, `route53:GetHostedZone` và `ListHostedZones`, `ssm:GetParameter` cho AMI,
  `sts:GetCallerIdentity`.
- **Tạo và xoá:** EC2 (VPC, subnet, gateway, EIP, security group, instance, endpoint), Elastic Load
  Balancing, S3 cho hai bucket `medical-rag-*`, `route53:ChangeResourceRecordSets` trên đúng zone.
- **IAM:** tạo role, policy, instance profile, và `iam:PassRole`.

**Phần khó nhất là IAM.** Ai tạo được role rồi gắn policy tuỳ ý thì tự nâng mình lên admin được. Phải giới
hạn tên theo `medical-rag-*`, bắt buộc **permissions boundary** trên mọi role tạo ra, và chỉ cho `PassRole`
đúng các role đó.

**Cách làm thực tế:** chạy một chu trình apply và destroy bằng role rộng, dùng IAM Access Analyzer sinh policy
từ CloudTrail, rồi siết thêm bằng điều kiện `aws:ResourceTag/project` và `aws:RequestTag/project`.

### B4. Chi phí

**B4.1**

| Hạng mục | Chi phí |
|---|---|
| Cluster, khi đang tồn tại | ≈ 0.53 USD/giờ |
| Workstation, khi đang chạy | ≈ 0.03 USD/giờ |
| Luôn giữ: KMS key, 5 secret, zone, bucket, image | ≈ 4 USD/tháng |
| Ổ đĩa của workstation khi đã stop | ≈ 2.90 USD/tháng |
| **Tổng phần luôn giữ** | **≈ 7 USD/tháng** |

Con số của cluster gồm ba node `m7i-flex.large`, NAT gateway, hai NLB, địa chỉ IPv4 public, 120 GB gp3 và
gateway.

Đơn giá lấy từ bảng giá AWS cho `ap-southeast-1`. Chi phí thực tế được budget theo dõi, lọc theo tag
`project`. Credit còn 128.47 USD, hạn tới 2027-02-13; trừ khoảng 35 USD chi phí cố định tới lúc đó, còn đủ
khoảng 175 giờ cluster. Vì vậy cluster chỉ sống theo giờ chứ không theo ngày.

**B4.2**

| Khoản tiết kiệm | Đánh đổi |
|---|---|
| Xoá cluster khi không dùng (lớn nhất) | Phải chia ba stack và phải dựng lại được trong vài phút |
| Một NAT gateway thay vì ba | Single point of failure cho traffic đi ra |
| Loại máy hợp lệ với Free plan | `m7i-flex.large` không có metric credit để cảnh báo khi CPU bị giới hạn |
| S3 gateway endpoint | Không mất gì; nó miễn phí |
| Không dùng interface endpoint | SSM phụ thuộc NAT |
| SSE-S3 thay vì KMS | Không tốn phí KMS theo request, nhưng không kiểm soát được bằng key policy |
| WireGuard thay vì Client VPN | Phải tự quản lý gateway |
| Stop workstation khi không dùng | Mất vài phút để bật lại |
| Lifecycle rule trên mọi bucket | Version cũ biến mất sau thời hạn |

**B4.3**

- **Hiện tại:** budget 100 USD/tháng gửi email ở mức 50 % và 100 % chi phí thực, lọc theo tag `project` (khi đã
  kích hoạt); thói quen xoá cluster khi không dùng; và theo dõi số credit còn lại.
- **Sẽ thêm:** cảnh báo FORECASTED để biết sớm hơn, Cost Anomaly Detection, kiểm tra volume `available` bị bỏ
  lại (A3.7), và một job theo lịch tự xoá stack cluster nếu nửa đêm vẫn còn chạy, làm lưới an toàn cho lúc
  quên.

### B5. Vận hành và độ tin cậy

**B5.1** Bằng cách đo, ở step 15 với bản cluster 65 resource:

- `make infra-destroy`, rồi `make infra` từ đầu, không có bước thủ công nào ở giữa (1 phút 27 giây và 3 phút
  19 giây)
- `terraform plan` ngay sau apply và ngay sau khi dựng lại đều báo `No changes`, tức apply lại không còn gì để
  sửa
- `make shared-plan` sau teardown cũng báo `No changes`, nên các stack cô lập với nhau

Sau khi thêm WireGuard, `make infra` dựng đủ 84 resource và mọi bước verify của step 18 đạt; thời gian dựng
lại chưa được đo lại.

**Giới hạn cần nói thẳng:**

- **AMI không được ghim** (xem A3.4).
- **Một số bước về bản chất là thủ công, nhưng đã được ghi lại và kiểm chứng:** apply bootstrap, delegate DNS
  và nhập giá trị secret.

**B5.2** Có hai trường hợp.

**Cluster được phép nghỉ:** không cần làm gì đặc biệt. `ignore_changes` chỉ bảo vệ instance đang tồn tại, nên
lần `make infra` tiếp theo sau khi xoá sẽ tự lấy AMI mới nhất.

**Cluster phải chạy liên tục** (bài drill, hoặc môi trường thật): thay lần lượt từng node, theo đúng các bước
ở A7.6: snapshot etcd, drain, gỡ member etcd, `terraform apply -replace='aws_instance.nodes[N]'`, join bằng
Ansible, xác nhận ba member khoẻ, rồi mới sang node tiếp theo. Không bao giờ quá một node cùng lúc.

**Bản vá gấp không cần đổi AMI:** Ansible chạy `apt` tại chỗ, rồi reboot từng node một, có drain.

Nâng phiên bản Kubernetes là việc của kubeadm, không phải của Terraform.

**B5.3** Không có rollback. Terraform lưu state sau mỗi resource hoàn tất, nên state chứa đúng những gì đã
thành công.

1. Đọc lỗi.
2. Kiểm tra lock đã được nhả (chỉ `force-unlock` khi process thực sự đã chết).
3. Chạy `terraform plan` để xem còn lại gì.
4. Sửa nguyên nhân gốc.
5. Apply lại: phần đã tạo được giữ nguyên, phần còn thiếu được tạo tiếp.

**Trường hợp hiếm:** crash giữa lúc tạo resource và lúc lưu state để lại một resource mồ côi trên AWS mà
Terraform không biết. Tìm nó theo tag rồi `import`.

**Ví dụ thật:** lỗi Free plan ở `RunInstances` (B6.1). Cách xử lý đúng như trên: đổi instance type rồi apply
lại.

**B5.4**

1. `~> 6.64` đã chặn 7.0, và lock file ghim 6.64.0, nên provider không tự nhảy phiên bản.
2. Đọc upgrade guide.
3. Trên một branch, chạy `terraform init -upgrade` và plan mọi stack. Phải hiểu mọi khác biệt; mục tiêu là
   `No changes` hoặc những thay đổi đã giải thích được.
4. Apply `cluster/` trước, vì nó disposable.
5. Rồi tới `shared/`, rồi `bootstrap/` từ CloudShell.
6. Commit lock file mới.

**Module khác provider:** lock file không ghi phiên bản module, nên `~> 6.7` của module VPC có thể trôi lên bản
mới ở lần `init` trên máy sạch. Muốn chặt thì ghim chính xác (`version = "6.7.x"`) và nâng có chủ đích theo
cùng quy trình.

**B5.5** Theo từng lớp:

1. **Tĩnh:** `fmt`, `validate`, `tflint`, Checkov.
2. **Review plan:** đọc plan, và assert trên JSON của plan cho các quy tắc.
3. **Test kiểu unit:** `terraform test` (1.6+) với provider giả lập, cho phần logic như tính CIDR, đặt tên, số
   lượng.
4. **Tích hợp:** apply và destroy thật kèm kiểm tra, giống cách guide kết thúc mỗi step bằng một bước verify.
   Terratest tự động hoá được, đổi lại tốn resource thật.

**Những gì tôi thực sự đã làm:** chạy validate và fmt trên bản copy của từng stack, cộng với chu trình destroy
và dựng lại thật, có các bước kiểm tra được ghi lại.

### B6. Xử lý sự cố

**B6.1** "Lần launch EC2 đầu tiên lỗi `InvalidParameterCombination: The specified instance type is not eligible
for Free Tier`, dù account vẫn còn credit. Thông báo nghe như chuyện credit, nhưng tôi đọc kỹ thì nó nói về
*loại máy*.

Nguyên nhân gốc: account đang ở **AWS Free plan**. Gói này chặn mọi loại máy không đủ điều kiện free tier, bất
kể còn bao nhiêu credit. Kiểm tra được bằng `aws freetier get-account-plan-state`, và liệt kê loại máy hợp lệ
bằng `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.

Tôi đổi workstation từ `t3.medium` sang `t3.small` kèm 2 GB swap, và node từ `t3.large` sang `m7i-flex.large`.
Sau đó apply thành công. Tôi ghi lại rủi ro mới vào thiết kế: `m7i-flex` không có metric credit, nên monitoring
sẽ cảnh báo theo mức dùng CPU kéo dài."

*Chuyện khác:* home 1 GB của CloudShell (B6.2); delegate DNS thay vì chuyển domain sang Route 53, vì Free plan
không cho phép. Lỗi `cloud-init` của gateway (B6.4) thì *không* nên kể như chuyện tìm ra nguyên nhân gốc: log
không được giữ lại.

**B6.2** Thư mục home của CloudShell chỉ chứa được 1 GB, mà AWS provider sau khi giải nén chiếm khoảng 830 MB
trong `.terraform/`. `df -h ~` xác nhận điều đó.

**Cách sửa:** xoá `.terraform/` cũ, `export TF_DATA_DIR=/tmp/tf-bootstrap`, rồi `terraform init` lại. `/tmp`
không được giữ giữa các phiên, nên mỗi phiên mới phải export và init lại.

**B6.3** Theo thứ tự ràng buộc:

1. **Free plan:** chỉ loại máy đủ điều kiện free tier (B6.1). Đây là ràng buộc cứng nhất.
2. **kubeadm:** tối thiểu 2 vCPU và 2 GB mỗi node control plane.
3. **Tải thật:** mỗi node vừa là control plane vừa chạy Jenkins, Prometheus và app, nên cần khoảng 8 GB.
4. **Có sẵn ở cả ba AZ:** kiểm tra bằng `aws ec2 describe-instance-type-offerings --location-type
   availability-zone`.
5. **Quota vCPU** của account (C6.4).
6. **Giá theo giờ,** vì cluster chỉ sống theo giờ.

Kết quả: node `m7i-flex.large` (2 vCPU, 8 GB). Workstation `t3.small` (2 vCPU, 2 GB) cộng 2 GB swap, vì nó chỉ
chạy Terraform, Ansible và kubectl; image được build trong cluster.

**Rủi ro đi kèm:** `m7i-flex` có CPU baseline và không có metric credit (C3.6).

**B6.4**

1. `aws ssm start-session --target <id>`. Role của gateway có SSM, nên không cần SSH.
2. `cloud-init status --wait`, rồi `sudo tail -20 /var/log/cloud-init-output.log`. Các dòng ngay trên `Failed
   to run module scripts_user` cho biết nguyên nhân.
3. **`ResourceNotFoundException`** hoặc **`can't find the specified secret value`**: key chưa được lưu lúc
   gateway boot. Lưu key, rồi `terraform apply -replace=aws_instance.wireguard`.
4. **Không có dòng lỗi nào:** bước kiểm tra key bằng `jq -e` thất bại, tức secret thiếu một key.
5. **SSM không bao giờ kết nối được** (agent cần ra internet): `aws ec2 get-console-output --instance-id <id>`
   cho xem log boot mà không cần đăng nhập.

**Lần gặp thật:** tôi không giữ log trước khi dựng lại, nên không xác nhận được nguyên nhân; khả năng cao là
secret còn rỗng lúc boot. Bài học: lưu `cloud-init-output.log` trước khi `-replace`.

**B6.5**

1. `aws elbv2 describe-target-health` để xem mã lý do, như `Target.FailedHealthChecks` hay `Target.Timeout`.
2. Trên node 1 (qua SSM): `curl -k https://localhost:6443/readyz`. Nếu lỗi, kiểm tra static pod bằng
   `sudo crictl ps -a` và kubelet bằng `journalctl -u kubelet`.
3. Nếu trả lời được ở local, kiểm tra đường đi: egress của `api_nlb` tới node trên 6443 (health check đi theo
   egress, A5.6), ingress `nodes_api_from_nlb`, và API server có lắng nghe trên địa chỉ của node không.
4. Nếu `/readyz` trả `401`/`403`, anonymous auth đã bị tắt (xem A6.2).
5. Cho health check đủ thời gian: hai lần đạt, cách nhau 10 giây.

### B7. Nhìn lại

**B7.1** Theo thứ tự giá trị:

1. **Tách `AdministratorAccess` của workstation** thành role plan và role apply (B3.6).
2. **Giới hạn 6443 trên internal NLB** về security group của node thay vì CIDR của VPC, để AWS chặn được điều
   mà hiện chỉ iptables chặn (A5.4).
3. **Dời WireGuard gateway sang AZ khác NAT gateway** (A4.4).
4. **Đổi mặc định `wireguard_cidr` ra khỏi dải Service** (A9.7).
5. **Commit lock file của bootstrap, ghim chính xác module VPC, nâng `required_version` lên 1.11** (A1.3, A1.7,
   B5.4).
6. **Tách module hardened bucket.**
7. **CI cho Terraform:** plan trên pull request với OIDC, tflint và Checkov.
8. **Xoá theo lịch** làm lưới an toàn cho chi phí, và đo lại thời gian dựng lại bản 84 resource.

**B7.2**

- **Account:** các account riêng trong một AWS Organization (state, bảo mật, workload theo môi trường), kèm
  SCP và tag policy.
- **Truy cập:** role SSO cho người, role OIDC cho CI, không có máy admin.
- **Triển khai:** chỉ apply qua CI, có review.
- **Nền tảng:** nhiều khả năng là EKS, để có IRSA / Pod Identity thay cho role dùng chung.
- **Mạng:** mỗi AZ một NAT gateway, và interface endpoint.
- **Traffic của app:** HTTPS qua ALB và ACM.
- **Truy cập quản trị:** qua identity provider có MFA (Client VPN, hoặc một zero-trust access proxy) thay vì key
  WireGuard quản lý bằng tay.
- **Kiểm toán:** CloudTrail toàn organization, AWS Config và GuardDuty.

---

## Phần C — AWS phía sau code

### C1. VPC và mạng

**C1.1** Subnet là public khi route table của nó gửi `0.0.0.0/0` tới **internet gateway**. Chỉ bật
auto-assign public IP thì subnet chưa phải là public.

- `10.10.101.0/24` gắn với route table public của module, trỏ tới internet gateway.
- `10.10.1.0/24` dùng route table private, có default route trỏ tới NAT gateway.

`map_public_ip_on_launch = false` chỉ ngăn instance ở đó tự nhận địa chỉ; WireGuard gateway thì xin địa chỉ
một cách tường minh.

**C1.2** Project dựa vào **security group**. Security group là **stateful** (traffic trả về tự động được cho
phép), gắn vào network interface, chỉ có allow, và tham chiếu được group khác.

Network ACL là **stateless**: traffic trả về cần rule riêng, kể cả dải port tạm. NACL áp cho cả subnet và hỗ
trợ explicit deny.

Module VPC quản lý luôn các cấu hình mặc định của VPC:

- **default NACL:** đặt lại thành cho phép tất cả, nên security group là bộ lọc duy nhất
- **default security group:** làm rỗng, nên thứ gì vô tình dùng nó cũng không có quyền truy cập nào
- **default route table:** làm rỗng

**C1.3** Nó nằm ở subnet **public**: subnet đầu tiên, vì `single_nat_gateway = true`. Nó cần Elastic IP vì nó
dịch các IP nguồn private của node thành một địa chỉ public duy nhất ra internet.

**Các khoản phí:**

- phí theo giờ
- phí xử lý theo GB cho mọi thứ nó chuyển tiếp (vì vậy S3 gateway endpoint mới quan trọng)
- phí IPv4 public cho EIP của nó
- cộng thêm phí truyền dữ liệu thông thường

**C1.4**

| | Gateway endpoint | Interface endpoint |
|---|---|---|
| Cách hoạt động | Một dòng trong route table trỏ tới prefix list | Network interface có IP private trong subnet của bạn, kèm private DNS |
| Giá | Miễn phí | Theo giờ cho mỗi endpoint mỗi AZ, cộng theo GB |
| Dịch vụ | Chỉ S3 và DynamoDB | Phần lớn dịch vụ AWS (SSM, ECR, Secrets Manager, KMS, STS, …) |
| Phạm vi tới được | Chỉ từ route table của VPC | Cả từ mạng peering và VPN, qua IP private của nó |

**C1.5** Khi cluster đang chạy:

| Nơi giữ | Số địa chỉ |
|---|---|
| EIP của NAT gateway | 1 |
| EIP của WireGuard | 1 |
| Public NLB, mỗi AZ một địa chỉ | 3 |
| Workstation, khi đang chạy | 1 |

Tổng cộng 5 tới 6 địa chỉ. Internal NLB không có địa chỉ public nào. Từ tháng 2/2024, AWS tính khoảng 0.005
USD/giờ cho **mọi** địa chỉ IPv4 public, dù đang dùng hay để không, nên chúng cộng thêm khoảng 0.03 USD/giờ.

**C1.6** Một `/28` có 16 địa chỉ, và AWS giữ lại 5: địa chỉ mạng, `+1` (router của VPC), `+2` (DNS), `+3` (dành
cho tương lai) và địa chỉ broadcast. Còn **11 địa chỉ dùng được**, thừa cho một máy.

**C1.7** Không nhất thiết. Tên AZ được ánh xạ tới zone vật lý riêng cho từng account; định danh ổn định là
**AZ ID** (`apse1-az1`, …).

**Khi nào quan trọng:**

- chia sẻ subnet hoặc đặt resource giữa nhiều account
- so sánh độ trễ hoặc báo cáo sự cố với account khác
- khả năng có sẵn của loại máy, vốn tính theo zone

Trong cùng một account, như project này, tên AZ là nhất quán.

### C2. Cân bằng tải

**C2.1**

| | NLB | ALB |
|---|---|---|
| Tầng | 4 (TCP/UDP/TLS) | 7 (HTTP/HTTPS/gRPC) |
| TLS | Passthrough, hoặc terminate trên listener TLS | Luôn terminate |
| IP nguồn | Có thể giữ nguyên | Bị thay; IP client nằm trong `X-Forwarded-For` |
| Địa chỉ | Mỗi AZ một IP cố định (dùng được EIP nếu là internet-facing) | Thay đổi theo thời gian; dùng DNS name |
| Security group | Hỗ trợ, nhưng chỉ khi gắn lúc tạo | Luôn có |
| Định tuyến | Theo port | Theo host, path, header |

Project này cần tầng 4 và passthrough (B1.4).

**C2.2** Mỗi node AZ của load balancer có thể gửi traffic tới target ở **bất kỳ** AZ nào, không chỉ AZ của nó.
Traffic vẫn chia đều kể cả khi câu trả lời DNS của client nghiêng về một AZ, và API server vẫn tới được khi hai
AZ không có target khoẻ. Trên NLB, cross-zone mặc định tắt, và bật lên thì **phí truyền dữ liệu giữa các AZ**
bắt đầu được tính. Ở đây lưu lượng rất nhỏ.

**C2.3** Hai tình huống khác nhau:

- **Target thành unhealthy** (node bị stop, khoảng 20 giây ở đây): NLB ngừng gửi kết nối mới tới nó. Mặc định
  NLB cũng chủ động đóng các kết nối đang mở tới target unhealthy (unhealthy connection termination), nên
  client như kubectl watch hay kubelet sớm nhận lỗi và kết nối lại.
- **Target bị deregister** (thay node có kế hoạch): NLB chờ **deregistration delay**, mặc định **300 giây**,
  để các kết nối đang dở kịp xong rồi mới gỡ hẳn.

Khi thay node có kế hoạch: drain trước, rồi tính cả thời gian delay. Hạ nó xuống (ví dụ 30 giây) giúp bài drill
nhanh hơn.

### C3. Compute và lưu trữ

**C3.1** Instance profile đưa role ra qua metadata service tại
`/latest/meta-data/iam/security-credentials/<role>`. AWS SDK và CLI tự đọc ở đó.

Credential là **credential STS tạm thời**: access key, secret key và session token. Chúng có hiệu lực vài giờ
và được tự động rotate trước khi hết hạn. Không có gì phải lưu hay tự tay rotate, và cũng không có gì để lọt
vào Git.

**C3.2** **Server-side request forgery (SSRF).** Với IMDSv1, một lỗi khiến ứng dụng tải một URL do kẻ tấn công
cung cấp (`http://169.254.169.254/...`) sẽ trả về credential của role.

IMDSv2 bắt buộc lấy session token trước, bằng request `PUT` kèm header TTL. Lỗi SSRF đơn giản không gửi được
request như vậy. AWS còn từ chối request lấy token có header `X-Forwarded-For`, và hop limit giữ token không ra
khỏi host. `http_tokens = "required"` tắt IMDSv1.

**C3.3** **Role** là một IAM identity có trust policy và quyền. EC2 không gắn trực tiếp role được; nó gắn một
**instance profile**, tức một wrapper chứa đúng một role. Console giấu điều này bằng cách tạo cả hai cùng lúc;
Terraform tạo riêng từng cái (`aws_iam_instance_profile`).

Gắn role vào instance cần quyền **`iam:PassRole`** trên role đó. Quyền này ngăn người dùng launch instance với
một role mạnh hơn quyền của chính họ.

**C3.4** Ổ gốc có `delete_on_termination = true` mặc định, nên xoá instance là **xoá luôn ổ đĩa**. Thư mục dữ
liệu của etcd (`/var/lib/etcd`) biến mất theo. Đó là lý do:

- node control plane bị thay phải được gỡ khỏi etcd trước (A7.6)
- snapshot etcd được đẩy lên S3
- sau teardown, cluster được dựng lại chứ không khôi phục

Volume của PVC thì ngược lại: không bị xoá cùng instance (A3.7).

**C3.5** gp3 cho baseline **3.000 IOPS và 125 MB/s ở mọi dung lượng**, và rẻ hơn gp2 khoảng 20 % mỗi GB. Một ổ
gp2 40 GB chỉ có baseline 120 IOPS (3 IOPS mỗi GB), cộng một lượng burst credit sẽ cạn dần.

etcd ghi xuống đĩa và chờ mỗi lần ghi được xác nhận, nên đĩa chậm gây bầu lại leader và API timeout. gp3 tránh
chuyện hết burst credit là IOPS tụt đột ngột, đúng lúc node bận nhất.

**C3.6**

| | `t3.large` | `m7i-flex.large` |
|---|---|---|
| Mô hình | CPU credit: tích luỹ khi dưới baseline (30 % mỗi vCPU), tiêu khi vượt | Chạy full CPU khoảng 95 % thời gian, tối thiểu 40 % phần còn lại |
| Chế độ mặc định | *Unlimited*, nên burst thêm sẽ bị tính tiền | — |
| Metric cảnh báo | `CPUCreditBalance` trong CloudWatch | Không có metric tương đương |

Với `m7i-flex`, chỉ tải nặng gần như liên tục mới bị giới hạn, không phải một lần build dài. Nhưng khi bị giới
hạn thì không có metric nào báo trước, nên thiết kế cảnh báo theo mức dùng CPU kéo dài
(`node_cpu_seconds_total`).

### C4. IAM, mã hoá và secret

**C4.1** **Trust policy** (`assume_role_policy`) nói ai được assume role. Ở đây là `ec2.amazonaws.com`, qua
`data.aws_iam_policy_document.ec2_assume_role`. **Permissions policy** (các managed policy gắn vào và inline
policy) nói role được làm gì sau khi được assume. Role cần cả hai: có quyền mà không có trust thì không ai dùng
được, có trust mà không có quyền thì chẳng làm được gì.

**C4.2** AWS đánh giá mọi policy liên quan cùng lúc.

1. Request được xác thực là role của node.
2. AWS tìm **explicit Deny**. Bucket policy từ chối `s3:*` khi `aws:SecureTransport` là `false`, mà với HTTP
   thường thì đúng như vậy, nên request bị **từ chối**.
3. Explicit Deny kết thúc việc đánh giá: `Allow` trên `s3:GetObject` của role node không còn được xét.

Qua HTTPS, điều kiện là false, Deny không áp dụng, và `Allow` trong identity policy cấp quyền cho request (cùng
account, nên không cần Allow trong bucket policy).

**C4.3**

- **AWS managed:** `AmazonSSMManagedInstanceCore`, `AmazonEBSCSIDriverPolicy` và `AdministratorAccess` của
  workstation. Tiện vì AWS bảo trì và cập nhật khi dịch vụ có action mới, nhưng chúng viết cho mọi account nên
  thường rộng hơn mức cần (A7.3).
- **Inline:** `medical-rag-nodes` và `read-wireguard-secret`. Chúng dành riêng cho một role, ghi đúng ARN, và
  bị xoá cùng role.
- **Customer managed:** không dùng. Loại này đáng dùng khi cùng một policy tự viết được gắn vào nhiều role,
  hoặc để thay một managed policy quá rộng bằng bản đã siết.

**C4.4** **IAM có tính nhất quán sau (eventual consistency).** Role hay instance profile mới có thể mất vài
giây mới lan tới EC2, dù IAM đã xác nhận tạo xong. `RunInstances` trong khoảng đó lỗi
`Invalid IAM Instance Profile name`. AWS provider tự thử lại lỗi này một lúc, nên hiếm khi gặp. Nếu vẫn lỗi, chỉ
cần apply lại.

**C4.5** **KMS key bất đối xứng không rotate tự động được;** chỉ key mã hoá đối xứng mới làm được.

**Rotate thủ công:**

1. Tạo key mới.
2. Chuyển alias sang key mới.
3. Giữ public key của key cũ, nếu không các chữ ký cũ không kiểm tra được nữa. Phần lớn hệ thống chọn ký lại
   các image đang dùng.

**Chi phí:** khoảng 1 USD/tháng mỗi key, cộng phí theo request cho `Sign` và `GetPublicKey`, không đáng kể ở mức
CI.

**C4.6**

| | Secrets Manager (đang dùng) | Parameter Store `SecureString` |
|---|---|---|
| Giá | 0.40 USD mỗi secret mỗi tháng, cộng phí gọi API | Parameter standard miễn phí (mỗi lần đọc tốn một lần KMS decrypt) |
| Giới hạn kích thước | 64 KB | 4 KB standard, 8 KB advanced (có tính phí) |
| Recovery window khi xoá | Có | Không |
| Rotation có sẵn | Có | Không |
| Resource policy | Có | Không |
| IAM cho node | `GetSecretValue` | `ssm:GetParameter` cộng `kms:Decrypt` |

Full chain của Sectigo cộng private key có thể vượt **4 KB**, buộc phải dùng parameter advanced. External
Secrets hỗ trợ cả hai. Ở đây lựa chọn này chênh nhau khoảng 2 USD/tháng, chủ yếu đổi lấy recovery window.

Một điểm đáng nói: vì node đã có `ssm:GetParameter` trên `*` qua managed policy (A7.3), secret cất trong
Parameter Store với key mặc định sẽ bị mọi pod đọc được. Secrets Manager với ARN tường minh tránh được điều đó.

**C4.7**

- **Mã hoá mặc định:** từ tháng 1/2023, S3 mặc định mã hoá mọi object mới bằng SSE-S3. Các resource
  `server_side_encryption_configuration` tường minh nhắc lại điều đó, để scanner và người đọc thấy ngay trong
  code.
- **Strong consistency:** từ tháng 12/2020, S3 có strong read-after-write consistency. Trước đó, lock lưu trong
  S3 không đáng tin, nên Terraform mới cần DynamoDB.
- **Conditional write:** từ 2024, S3 hỗ trợ `If-None-Match`. Nhờ đó Terraform chỉ tạo object `.tflock` khi chưa
  có object nào. Cộng với strong consistency, đây là điều làm `use_lockfile` khả thi.

### C5. DNS

**C5.1** Một CNAME trỏ tới `aws_lb.api.dns_name` cũng tự cập nhật khi NLB đổi tên, nên đó không phải lý do.
Lý do thật của alias:

- **Trả lời thẳng record `A`** của đích, client không phải tra thêm một lần.
- **Truy vấn alias tới đích AWS như ELB là miễn phí,** còn CNAME tính phí truy vấn bình thường.
- **Đặt được ở zone apex** (chính `recruitai.io.vn`), nơi CNAME bị cấm. Project chưa dùng apex, nhưng alias là
  lựa chọn nhất quán cho mọi record trỏ vào resource AWS.

**C5.2**

- **Ở registrar** (registry `.vn` là zone cha): các record NS của `recruitai.io.vn` được thay bằng bốn name
  server của Route 53.
- **Bên trong zone:** Route 53 tự tạo NS và SOA khi tạo zone.

**Vì sao mất hàng giờ:** resolver cache các record NS cũ của zone cha theo TTL, thường một tới hai ngày. Cho tới
khi các bản cache đó hết hạn, một số resolver vẫn hỏi DNS provider cũ, vì vậy phải chép record sang và giữ
provider cũ 48 giờ.

**DNSSEC:** record DS ở zone cha trỏ tới key ký DNSSEC của DNS provider *cũ*. Câu trả lời mới, không ký, từ
Route 53 sẽ không qua được kiểm tra, và resolver có kiểm tra DNSSEC sẽ trả `SERVFAIL` cho cả domain. Vì vậy
phải gỡ record DS trước, và chờ TTL của nó hết hạn.

**C5.3** Mỗi hosted zone mới nhận một **delegation set** bốn name server chọn ngẫu nhiên, nên zone mới dù cùng
tên vẫn có server mới. **Reusable delegation set** (`aws_route53_delegation_set`) cố định bốn server, và các
zone tạo bằng nó dùng lại đúng bốn server đó. Cách này giải quyết chuyện tạo lại, nhưng trong project này
`prevent_destroy` cộng với việc giữ zone ở `shared/` đã đủ.

**C5.4** **Domain control validation** qua DNS: Sectigo đưa ra tên và giá trị của một CNAME, suy ra từ
certificate request. Record đó được tạo trong Route 53 zone, và Sectigo kiểm tra nó phân giải được công khai.

**Những gì có thể chặn việc cấp:**

- record **CAA** trên tên hoặc trên domain chỉ cho phép các CA khác
- chuỗi DNSSEC bị hỏng
- delegation chưa lan tới resolver của Sectigo
- request có tên không khớp (`rancher.recruitai.io.vn`)

### C6. Account, chi phí và vận hành

**C6.1** **Giới hạn:** chỉ dùng được một số dịch vụ và **loại máy** đủ điều kiện free tier (vì vậy mới có
B6.1), và chi tiêu bằng **credit** thay vì hoá đơn.

**Khi kết thúc:** Free plan kết thúc sau 6 tháng hoặc khi hết credit, tuỳ cái nào tới trước. Khi đó account bị
đóng, còn 90 ngày để nâng lên gói trả phí trước khi dữ liệu bị xoá. Với account này, credit hết hạn ngày
2027-02-13.

**Kế hoạch:**

- **Cách đơn giản nhất:** nâng lên gói trả phí trước hạn. Việc này cũng gỡ luôn giới hạn loại máy.
- **Nếu phải rời account:**
  - chép các version state ra ngoài account
  - ghi lại ARN và public key của cosign key: private key không export được, nên account mới nghĩa là key mới
    và phải ký lại image
  - push image sang registry khác
  - giữ bản sao mã hoá của giá trị secret (private key của Rancher hiện chỉ có trên workstation và trong
    Secrets Manager)
  - trỏ name server ở registrar về nơi mới, nếu không domain chết theo zone

**C6.2** Resource mang tag (ở đây nhờ `default_tags`). Tag do người dùng định nghĩa phải được **kích hoạt** làm
cost allocation tag; từ đó dữ liệu billing có thêm cột `user:project`. Filter của budget
`TagKeyValue user:project$medical-rag` chọn theo cột đó. Những gì filter này bỏ sót nằm ở A8.6.

**C6.3** Chỉ **thư mục home**: 1 GB mỗi region, bị xoá sau 120 ngày không dùng. Phần máy phía sau chỉ là tạm
thời và session sẽ hết hạn.

State Terraform để ở đó có thể mất cùng môi trường, người khác không nhìn thấy, và không lock được cho làm việc
nhóm. Vì vậy phải migrate lên S3 ngay (A1.1), và đặt `TF_DATA_DIR` trong `/tmp` để provider không làm đầy home
(B6.2).

**C6.4** Kiểm tra trong Service Quotas, vì account mới có thể có mức mặc định thấp:

- **vCPU cho On-Demand Standard instances:** project cần khoảng 10 vCPU (6 cho node, 2 cho gateway, 2 cho
  workstation), cộng phần của các project khác.
- **Elastic IP, mặc định 5 mỗi region:** project này giữ 2 (NAT gateway và WireGuard).
- **VPC, mặc định 5 mỗi region:** project này dùng 2 (ops và cluster), cộng VPC mặc định.

Các project khác dùng chung account, nên `make infra` có thể lỗi `VcpuLimitExceeded`, `AddressLimitExceeded`
hoặc `VpcLimitExceeded` dù bản thân nó không đổi gì. Xin tăng trước khi chúng chặn một lần dựng lại.

**C6.5** **CloudTrail.** Event history miễn phí giữ 90 ngày management event. Lọc theo tên event
`RevokeSecurityGroupIngress` (hoặc `RevokeSecurityGroupEgress`), hoặc theo ID security group. Event cho thấy
identity, IP nguồn, thời điểm và nguyên văn request.

**Bẫy:** lệnh chạy trên workstation hiện ra dưới tên
`assumed-role/medical-rag-ops-workstation/i-…`, tức instance, không phải người. Muốn biết *ai*, tìm event
`StartSession` của Session Manager quanh thời điểm đó (identity của người mở session), rồi đối chiếu lịch sử
session. Lệnh chạy trong CloudShell thì mang identity đăng nhập console của người đó. Muốn lịch sử dài hơn 90
ngày thì cần một trail đẩy log vào S3.
