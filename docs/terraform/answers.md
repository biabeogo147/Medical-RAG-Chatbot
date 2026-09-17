# Đáp án Terraform

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. *Ở đâu* chỉ ra code hoặc tài liệu làm căn cứ
cho câu trả lời. *Hỏi tiếp* là câu mà người phỏng vấn nhiều khả năng sẽ hỏi ngay sau đó. Tham chiếu dạng
`AWS B1.1` trỏ tới [`../aws/answers.md`](../aws/answers.md).

Các đáp án mô tả project **khi đã hoàn thành**, vì bộ này dùng lúc nộp CV. Chỗ `[điền: …]` là số liệu phải lấy
từ lần chạy thật trước khi dùng; đừng nói con số bạn chưa đo.

Các con số lấy từ [`docs/evidence/terraform.md`](../evidence/terraform.md):

- **Số resource:** bootstrap 18, shared 17, cluster 84.
- **Thời gian:** ở step 15, bản cluster 65 resource (chưa có WireGuard) destroy mất 1 phút 27 giây và dựng
  lại từ đầu mất 3 phút 19 giây. Bản đủ 84 resource: `[điền: thời gian make infra-destroy và make infra]`.
- **Chi phí:** khoảng 0.53 USD/giờ khi cluster đang chạy.

**Nếu bạn sửa code trước khi nộp CV, sửa cả đáp án:** các đáp án dưới đây mô tả đúng code hiện tại, kể cả
những điểm yếu đã biết. Sửa điểm nào thì cập nhật các câu liên quan.

| Điểm yếu trong code | Câu liên quan |
|---|---|
| Assert đầu `site.yml` chỉ kiểm tra `is defined` | A3.1, B2.6 |
| `required_version = ">= 1.10"` thay vì 1.11 | B1.3, A8.1 |
| `bootstrap/` chưa commit lock file; module VPC ghim `~> 6.7` | B1.7, A2.2, A6.4, A8.1 |
| `wireguard_cidr` mặc định nằm trong dải Service | B9.7, A7.2, A8.1 |
| WireGuard gateway ở `public_subnets[0]`, cùng AZ với NAT | B4.4, A1.11, A8.1 |
| Rule 6443 của internal NLB tin cả CIDR của VPC | B5.4, A4.2, A8.1 |
| Provider chưa có `allowed_account_ids` | A2.12, A8.1 |

---

## Phần A — Phỏng vấn

Mỗi đáp án mở đầu bằng **Ý chính**: 2–4 câu nói thành tiếng, ngôi thứ nhất, thường là đủ. Phần *Nếu được
hỏi thêm* chỉ dùng khi người phỏng vấn đào sâu; bảng và tên file trong đó để bạn nắm, không đọc nguyên văn.
Khi phỏng vấn bằng tiếng Anh, giữ nguyên ý và các thuật ngữ.

### A1. Kiến trúc và lựa chọn công cụ

**A1.1** **Ý chính:** "Tôi chia Terraform thành ba stack theo vòng đời, state của cả ba nằm trong một bucket
S3 có lock native. Bootstrap tạo bucket state và một ops workstation. Shared giữ những thứ phải sống sót khi
xoá cluster: registry, khoá ký image, secret, domain. Cluster là phần xoá đi dựng lại hằng ngày: VPC ba AZ, ba
node, hai load balancer và một VPN gateway."

*Nếu được hỏi thêm:*

- **Bootstrap** chỉ apply từ CloudShell. Workstation chỉ vào được qua SSM, nên laptop không cần cài công cụ
  cloud nào.
- **Shared:** ECR với tag immutable (trừ tag chữ ký và cache build), KMS key bất đối xứng để ký image,
  bucket chứa index, năm secret mà Terraform tạo rỗng, Route 53 zone và một budget.
- **Cluster:** VPC ba AZ với một NAT gateway; ba node ở subnet private mà Ansible dựng thành cluster kubeadm
  HA; internal NLB cho Kubernetes API và Rancher; public NLB cho app; WireGuard gateway để vào Rancher.
- **Mạng và quyền:** phần lớn rule security group tham chiếu group khác thay vì dải IP (ngoại lệ: internal
  NLB tin cả CIDR của VPC). Inline policy ghi đúng ARN.
- **Con số:** stack cluster 84 resource dựng lại từ đầu trong `[điền: thời gian make infra]`, và plan ngay sau
  đó `[điền: No changes]`. Chạy cluster tốn khoảng 0.53 USD/giờ.
- **Ranh giới:** Terraform dừng ở máy. Ansible cấu hình node, Argo CD sở hữu mọi thứ bên trong cluster (A1.5,
  A1.6).

**A1.2** **Ý chính:** "Không phải vì CloudFormation kém. Tôi chọn Terraform vì `plan` cho tôi đọc chính xác
cái gì sẽ đổi trước khi apply, vì phần lớn tin tuyển DevOps yêu cầu nó, và vì cách làm này dùng lại được ở
cloud khác. Project chỉ dùng provider AWS, nên multi-cloud không phải lý do."

*Nếu được hỏi thêm*, những gì CloudFormation cho sẵn mà tôi phải tự làm:

- **State:** AWS giữ state của stack CloudFormation. Với Terraform tôi phải có bucket state, lock và
  versioning; cả stack bootstrap tồn tại vì chuyện này.
- **Rollback:** stack CloudFormation lỗi thì tự quay về trạng thái trước; `terraform apply` lỗi thì dừng ở giữa,
  và tôi apply lại cho tới khi xong (A6.3).
- **Drift detection** có sẵn trong console.

CDK viết bằng TypeScript hay Python rồi sinh ra template CloudFormation, nên thừa hưởng cả ưu lẫn nhược điểm đó.
Ở công ty đã chuẩn hoá CloudFormation thì tôi theo chuẩn; các nguyên tắc (stack theo vòng đời, tham chiếu thay
vì ID cứng, review thay đổi trước khi chạy) vẫn giữ nguyên.

**A1.3** **Ý chính:** "Mục tiêu của project này là tự vận hành control plane: etcd HA, backup và restore,
certificate, nâng cấp phiên bản. EKS làm hộ đúng những việc đó. Project thứ hai của tôi dùng EKS, nên hai
project bổ sung cho nhau. Ở công ty tôi mặc định chọn EKS."

*Nếu được hỏi thêm*, những gì tôi từ bỏ:

- nâng cấp được quản lý sẵn và SLA của AWS
- IRSA / Pod Identity, nên pod dùng chung role của node (A4.4)
- AWS Load Balancer Controller, nên NLB là tĩnh và NodePort cố định
- thêm việc phải bảo trì

Không nên lấy phí control plane của EKS (0.10 USD/giờ) làm lý do: ba node control plane tự dựng còn tốn hơn.
Ở công ty tôi chỉ tự dựng khi có lý do cụ thể, như phải giống môi trường on-premises hoặc cần phiên bản EKS
chưa hỗ trợ.

**A1.4** **Ý chính:** "Với mỗi resource tôi hỏi: nếu xoá nó mỗi khi không dùng thì mất gì? Không mất gì thì
cho vào cluster. Mất công, mất tiền hay làm hỏng thứ đang dựa vào nó thì cho vào shared. Thứ bản thân
Terraform cần, và máy tôi chạy Terraform, thì cho vào bootstrap."

*Nếu được hỏi thêm:*

- **cluster:** mạng, node, NLB.
- **shared:** index tốn quota API để build lại; giá trị secret gõ tay; KMS key mới làm mất hiệu lực mọi chữ
  ký; zone mới đổi name server.
- **bootstrap:** bucket state và workstation, apply từ CloudShell (B2.5).

State tách riêng còn giới hạn phạm vi ảnh hưởng (plan của cluster không động được tới KMS key) và giữ plan
nhanh. Workspace không hợp, vì workspace dùng lại *một* cấu hình với nhiều state, còn ba cấu hình này khác
nhau. Các stack nối với nhau bằng data source tra theo tên (B2.2).

**A1.5** **Ý chính:** "Terraform so tài nguyên AWS với state và không biết gì bên trong hệ điều hành. Dựng
kubeadm HA là một quy trình có thứ tự giữa các máy: node 1 init, rồi hai node còn lại lần lượt join bằng token
vừa tạo. User data chạy độc lập trên từng máy, một lần duy nhất, nên không làm được việc đó; Ansible thì chạy
lại được và dùng tiếp cho nâng cấp, thay node."

*Nếu được hỏi thêm:*

| | User data (cloud-init) | Ansible |
|---|---|---|
| Khi nào chạy | Một lần, lúc máy boot lần đầu | Bất cứ lúc nào; được viết để lần hai `changed=0` (`[điền: PLAY RECAP lần hai]`) |
| Phối hợp giữa các máy | Không: mỗi máy chạy độc lập | Có: node 1 trước, rồi join từng node |
| Token join | Phải tự dựng cơ chế chia sẻ | Node 1 tạo token hạn 15 phút cho từng lần join; giá trị giữ trong biến `no_log`, ghi tạm vào file chỉ root đọc được, rồi xoá |
| Lỗi | Nằm trong `cloud-init-output.log` trên máy | Hiện ngay, dừng đúng task |
| Day-2 | Không | Có: nâng cấp, thay node |

Project vẫn dùng user data ở chỗ nó hợp: workstation và WireGuard gateway là máy đơn lẻ, cấu hình một lần; đổi
script của gateway thì thay luôn máy (`user_data_replace_on_change`).

**Packer:** bake sẵn containerd, kubelet, kubeadm đã ghim vào AMI thì node boot nhanh hơn và giống hệt nhau.
Tôi không dùng, vì phải thêm pipeline build và vá AMI, trong khi phần chậm và dễ lỗi nhất (`kubeadm init/join`)
vẫn chạy lúc runtime. Nếu cần autoscaling node, tôi sẽ thêm Packer cho phần cài package.

**A1.6** **Ý chính:** "Vì lúc Terraform plan thì cluster chưa tồn tại: Ansible mới là thứ dựng nó, sau
Terraform. Kubernetes API cũng chỉ vào được qua tunnel SSM, nên provider không có endpoint ổn định. Vì vậy
`make bootstrap` cài Argo CD một lần, rồi Argo CD tự quản lý chính nó và mọi addon từ Git."

*Nếu được hỏi thêm:*

- **Vòng đời khác nhau:** addon đổi hằng ngày theo Git; hạ tầng AWS thì hiếm khi đổi. Gộp chung thì mỗi lần đổi
  chart là một lần plan cả VPC.
- **Destroy dễ kẹt:** resource trong cluster (PVC, Service) phụ thuộc node và NLB mà Terraform đang xoá. `make
  down` vì vậy xoá các Application của Argo CD trước để giải phóng volume, rồi mới `make infra-destroy`.
- **Hai nơi sở hữu một thứ:** Argo CD tự sửa mọi lệch khỏi Git, nên nếu Terraform cũng quản lý cùng object thì
  hai bên giành nhau.
- Với EKS, cluster được tạo ngay trong Terraform, nên cài Argo CD bằng provider Helm là chuyện hợp lý hơn.

**A1.7** **Ý chính:** "Kubernetes API server tự terminate TLS, nên load balancer phía trước phải chuyển nguyên
TCP, tức là tầng 4. TLS của Rancher cũng terminate ở ingress-nginx bằng certificate đã mua, và ingress đã
định tuyến HTTP rồi, nên ALB chỉ làm lại việc đó."

*Nếu được hỏi thêm:*

- NLB có một IP cố định mỗi AZ và giờ hỗ trợ security group, nhưng chỉ gắn được lúc tạo (B5.5).
- **ALB sẽ mang thêm:** WAF, certificate ACM, health check và định tuyến ở tầng HTTP. Với app public ở
  production, tôi sẽ đặt một ALB có certificate ACM phía trước để có HTTPS.
- So sánh NLB và ALB chi tiết: AWS B2.1.

**A1.8** **Ý chính:** "Chỉ qua Session Manager. Không có port inbound nào, không có key pair phải rotate hay có
thể bị lộ, và IAM quyết định ai được vào. Ansible dùng connection plugin SSM, còn kubectl đi qua SSM
port-forward."

*Nếu được hỏi thêm:*

- Bastion sẽ thêm một máy public, SSH key và thêm một hệ điều hành phải vá.
- **Đánh đổi:** Ansible qua SSM chậm hơn vì file module phải đi qua S3; node phụ thuộc NAT để tới được SSM; ai
  mở được session trên workstation thì thừa hưởng role admin của nó (A4.7).
- Session có thể ghi log ra S3 hoặc CloudWatch; project chưa bật.

**A1.9** **Ý chính:** "Rancher là giao diện có quyền admin cluster, nên tôi không muốn nó có địa chỉ public.
Client VPN tính tiền theo giờ cho mỗi subnet gắn vào và mỗi kết nối, đắt hơn nhiều lần một máy nhỏ. SSM
port-forward làm certificate không khớp tên. WireGuard rẻ, bị xoá cùng cluster, và port UDP của nó im lặng với
ai không có key."

*Nếu được hỏi thêm:*

| Lựa chọn | Vì sao không, hoặc vì sao có |
|---|---|
| AWS Client VPN | Được quản lý sẵn và hỗ trợ SAML, nhưng đắt theo giờ và cần dựng mutual auth bằng certificate |
| SSM port-forward | Ổn cho một port TCP, nhưng trình duyệt phải gọi đúng `rancher.recruitai.io.vn` thì certificate mới khớp, nên phải sửa file hosts; session cũng hay hết hạn |
| HTTPS public, chỉ cho IP của tôi | IP ở nhà thay đổi, và một UI cluster-admin phơi ra internet sẽ chờ lỗ hổng tiếp theo |
| **WireGuard (đã chọn)** | Máy nhỏ khoảng 0.03 USD/giờ, split tunnel, domain và certificate thật dùng được |

**Cái giá:** tôi tự vận hành gateway, và nó nằm cùng AZ với NAT gateway (B4.4); key quản lý bằng tay; bộ lọc
traffic nằm trong iptables trên gateway (B5.4).

**A1.10** **Ý chính:** "VPC dùng module cộng đồng được ghim phiên bản, vì đó là boilerplate mạng mà rất nhiều
người dùng. Mọi thứ khác là resource thường, vì chỉ có một môi trường và một nơi dùng: module chỉ dùng một lần
thì thêm một lớp abstraction mà không được gì. Tôi sẽ tách module khi có nơi dùng thứ hai."

*Nếu được hỏi thêm:*

- Module VPC tạo 23 resource: subnet, route table, association, NAT, cùng default security group và NACL.
- **Ứng viên module đầu tiên:** *hardened bucket*. Bucket, public access block, mã hoá, policy chỉ nhận TLS và
  lifecycle rule đang lặp lại cho bốn bucket.
- **Nếu nhiều team dùng chung:** module nằm ở repo riêng, gắn tag semver, gọi bằng `?ref=vX.Y.Z` hoặc qua
  private registry, có changelog, và dùng block `moved` bên trong module khi đổi địa chỉ resource.

**A1.11** **Ý chính:** "Control plane chịu được mất một node: ba node ở ba AZ, etcd còn 2/3 vẫn đủ quorum, và
tôi đã tắt thử một node trong khi API vẫn trả lời. Nhưng hệ thống chưa chịu được mất AZ đầu tiên, vì NAT
gateway duy nhất nằm ở đó. Đó là đánh đổi chi phí tôi chấp nhận và ghi lại."

*Nếu được hỏi thêm:*

- **HA:** internal NLB bật cross-zone, health check `/readyz`; public NLB trải trên ba subnet public. Bài drill
  tắt node 2 nằm trong `docs/evidence/ansible.md`.
- **Single point of failure đã chấp nhận:**
  - **Một NAT gateway:** mọi traffic ra internet, gồm Gemini và SSM. Thêm hai cái nữa tốn khoảng 0.12 USD/giờ.
  - **WireGuard gateway:** chỉ UI quản trị phụ thuộc vào nó.
  - **Workstation:** chỉ việc vận hành phụ thuộc vào nó.
  - **Một region.**
- **Điểm tôi tự tìm ra khi rà lại:** NAT, WireGuard gateway và node 1 cùng nằm ở AZ đầu tiên, nên một sự cố AZ
  đánh sập cả ba (B4.4). Sửa rẻ nhất là dời WireGuard gateway sang `public_subnets[1]`.

### A2. Plan, state và làm việc nhóm

**A2.1** **Ý chính:** "State của cả ba stack nằm trong một bucket S3 do stack bootstrap tạo: có versioning,
mã hoá, chặn truy cập public, chỉ nhận TLS và không xoá được bằng Terraform. Mỗi stack một key riêng. Lock là
native của S3 backend, không cần bảng DynamoDB."

*Nếu được hỏi thêm:*

- Version cũ hết hạn sau 90 ngày; bucket có `prevent_destroy`.
- Lock là một object `.tflock` tạo bằng conditional write: chỉ tạo được khi chưa có (B1.3, B1.4).
- **Ở công ty:** một account riêng cho state, KMS key do khách hàng quản lý, bucket policy ghi rõ các role
  được phép, và bản sao nằm ngoài account.

**A2.2** **Ý chính:** "State lock đã ngăn hai lệnh apply đè lên nhau. Việc cần thêm là không ai apply từ máy
mình nữa: thay đổi đi qua pull request, CI đăng plan, người khác review, và CI apply đúng plan đã duyệt. Mỗi
người có role chỉ đủ cho việc của mình."

*Nếu được hỏi thêm*, cần thêm:

- pre-commit chạy `fmt`, `validate` và `tflint`
- `CODEOWNERS` bảo vệ `bootstrap/` và `shared/`
- commit lock file cho cả ba stack (bootstrap hiện chưa có, B1.7)
- kiểm tra drift theo lịch (A2.7)
- role riêng thay cho `AdministratorAccess` của workstation (A4.6)

**A2.3** **Ý chính:** "`apply` tương tác tự tính plan, hiện ra, chờ `yes`, rồi apply đúng plan đó, nên plan
không bị cũ. Với một người vận hành thì chấp nhận được. Rủi ro là không có bản ghi nào về plan đã duyệt, không
ai khác review, và thói quen gõ `yes` mà không đọc."

*Nếu được hỏi thêm:*

- Guide luôn ghi con số mong đợi ("84 to add") để so với dòng tóm tắt, bù một phần cho việc không có reviewer.
- **Khi nào đổi:** ngay khi có người thứ hai hoặc có CI. Khi đó `plan -out=tfplan`, người review đọc `terraform
  show tfplan`, và `terraform apply tfplan` chạy đúng thứ đã duyệt. Nếu state đổi giữa chừng, Terraform từ chối
  plan cũ thay vì apply sai.

**A2.4** **Ý chính:** "Tôi không gõ `yes` cho tới khi trả lời được vì sao. Dòng `# forces replacement` trong
plan chỉ đúng thuộc tính gây ra việc thay. Nếu đó là thay đổi có chủ đích thì chấp nhận; nếu chỉ là đổi tên
trong code thì thêm block `moved`; còn nếu là node control plane thì thay theo quy trình, từng node một."

*Nếu được hỏi thêm:*

| Nguyên nhân | Ví dụ | Xử lý |
|---|---|---|
| Thay đổi có chủ đích | Sửa `wireguard-init.sh`: gateway được thay, Elastic IP chuyển sang máy mới | Chấp nhận |
| Giá trị bên ngoài code đổi | AMI mới nhất đổi | `ignore_changes`, hoặc thay có kế hoạch |
| Đổi *địa chỉ* trong code | Đổi tên resource, chuyển vào module, `count` sang `for_each` | Block `moved`; plan phải về 0 destroy |
| Thuộc tính không sửa tại chỗ được | Tên bucket, subnet của instance, port của target group | Giữ giá trị cũ, hoặc lên kế hoạch thay |

Thay node control plane: snapshot etcd, drain, gỡ member etcd, rồi `-replace` từng node (B7.6). Lưới an toàn là
`prevent_destroy` trên những thứ không được mất, và khi có CI thì tự động chặn plan có `delete` trên chúng.

**A2.5** **Ý chính:** "Không dùng trong vận hành thường ngày. `-target` chỉ apply một phần đồ thị, nên state và
code lệch nhau cho tới lần apply đầy đủ sau, và chính Terraform cũng cảnh báo điều đó. Thay một máy thì tôi dùng
`-replace`; muốn giới hạn phạm vi thì đã có ba stack."

*Nếu được hỏi thêm:* `-target` hợp lý khi cứu sự cố, ví dụ tạo lại riêng một resource đang chặn cả plan, và
ngay sau đó phải chạy một plan đầy đủ để chắc không còn gì lệch.

**A2.6** **Ý chính:** "Phần này tôi chưa dựng, vì lab chỉ có một người vận hành. Tôi sẽ dùng OIDC từ hệ thống CI
tới IAM role, nên không có access key dài hạn nào. Pull request chạy plan với role chỉ đọc; sau khi merge, job
apply chạy đúng plan file đã lưu, với role apply chỉ dùng được từ branch được bảo vệ."

*Nếu được hỏi thêm:*

- **Role plan:** đọc resource, đọc state, và `GetObject`, `PutObject`, `DeleteObject` trên object `.tflock`
  (plan cũng lấy lock); hoặc chạy plan với `-lock=false`.
- **Role apply:** chỉ assume được từ environment được bảo vệ, sau khi đã duyệt.
- **Đồng thời:** mỗi stack chỉ một job tại một thời điểm, cộng thêm state lock.
- **Chi phí:** Infracost comment vào pull request để thấy một thay đổi làm tăng bao nhiêu tiền.

**A2.7** **Ý chính:** "Trong project này thì không thấy. Rule được viết thành resource riêng, và Terraform chỉ so
những gì có trong state; một rule thêm tay không nằm trong state nào. Plan chỉ thấy nếu ai đó sửa một rule đang
được quản lý."

*Nếu được hỏi thêm:*

- **Phát hiện:** `terraform plan -detailed-exitcode` chạy theo lịch (exit code 2 nghĩa là có thay đổi) cho
  resource được quản lý; AWS Config rule, hoặc script so `describe-security-group-rules` với tập rule mong muốn,
  cho những thứ thêm ngoài Terraform.
- **Xử lý:** apply để trả về như cũ, hoặc đưa vào code bằng block `import` và review như mọi thay đổi khác.
- Tag `managed-by = terraform` trên mọi resource có hỗ trợ tag nhắc mọi người đừng sửa tay.

**A2.8** **Ý chính:** "Tôi đọc chính xác thuộc tính nào bị báo đổi, giá trị trước và sau. Thường là một trong
ba chuyện: một giá trị đọc từ bên ngoài đổi, như AMI mới nhất; hai nơi cùng quản lý một thứ; hoặc AWS chuẩn hoá
giá trị khác với chuỗi trong code. Tôi sửa gốc, không vá bằng `ignore_changes`."

*Nếu được hỏi thêm:*

| Nguyên nhân | Ví dụ | Sửa |
|---|---|---|
| Giá trị đọc từ bên ngoài đổi | Data source AMI "mới nhất" | `ignore_changes = [ami]`, hoặc ghim AMI |
| Hai nơi cùng quản lý một thứ | Security group trộn rule inline và rule rời (B5.3); controller hay người dùng console sửa lại thuộc tính | Chỉ để một nơi sở hữu |
| AWS chuẩn hoá khác chuỗi trong code | JSON policy viết tay: thứ tự key, chuỗi đơn và danh sách một phần tử | Dùng `aws_iam_policy_document`, như project đang làm |
| Tag do bên ngoài gắn thêm | Công cụ chi phí hay controller gắn tag lên resource | `ignore_tags` trong block provider |
| Nâng provider | Giá trị mặc định mới | Đọc upgrade guide, khai báo tường minh |

`terraform plan -refresh-only` cho xem state lệch thực tế thế nào mà không đề xuất sửa gì. `ignore_changes` vá
cho nhanh thì cũng che luôn drift thật trên đúng thuộc tính đó.

**A2.9** **Ý chính:** "Trong cùng một stack thì dùng block `moved`: plan hiện là di chuyển, không phải xoá rồi
tạo lại. Chuyển sang stack khác thì dùng block `removed` với `destroy = false` ở stack cũ để Terraform quên
resource mà không xoá, và block `import` ở stack mới. Tiêu chí là plan báo 0 destroy trước khi ai gõ `yes`."

*Nếu được hỏi thêm:* `moved` có từ Terraform 1.1, `import` từ 1.5, `removed` từ 1.7; cách cũ tương đương là
`terraform state rm` và `terraform import`. Ba block này chỉ đổi địa chỉ trong Terraform; đổi tên thật trên AWS
(tên bucket, tên secret) vẫn là tạo resource mới.

**A2.10** **Ý chính:** "Project này dựng từ đầu nên tôi chưa phải import hạ tầng thật. Tôi sẽ khai báo block
`import`, cho Terraform sinh HCL từ tài nguyên đang có, dọn lại code đó, rồi lặp plan tới khi báo đúng số
resource cần import và 0 add, 0 change, 0 destroy. Chỉ khi đó mới apply."

*Nếu được hỏi thêm:*

1. Khoanh phạm vi theo VPC hoặc tag, chia theo vòng đời giống ba stack ở đây.
2. `import { to = aws_security_group.web, id = "sg-…" }`, rồi `terraform plan -generate-config-out=generated.tf`.
3. Dọn code sinh ra: bỏ thuộc tính mặc định, thay ID cứng bằng tham chiếu, tách file có nghĩa.
4. Lặp plan tới tiêu chí ở trên; commit; các block `import` xoá được vì chỉ có tác dụng một lần.

**Bẫy:** security group có rule vừa inline vừa rời thì plan không bao giờ ổn định (B5.3); `default_tags` gắn
thêm tag vào tài nguyên vừa import nên plan báo `update in-place`, cần chấp nhận có chủ đích; tài nguyên do AWS tự
tạo, như network interface của NLB, không import. Terraformer hay former2 giúp sinh bản nháp cho số lượng lớn,
nhưng vẫn phải qua bước 3 và 4.

**A2.11** **Ý chính:** "Tốt nhất là một AWS account riêng cho prod, vì đó là ranh giới mạnh nhất về IAM, quota và
chi phí. Code thì tách các mẫu lặp lại thành module, và mỗi môi trường một thư mục gọi module với biến riêng và
state riêng. Tôi không dùng workspace cho các môi trường khác nhau nhiều như vậy."

*Nếu được hỏi thêm*, prod sẽ khác ở: không xoá khi không dùng; mỗi AZ một NAT gateway; HTTPS cho app; interface
endpoint; zone hoặc subdomain riêng. Terragrunt là một lựa chọn để nối phụ thuộc giữa các stack.

**A2.12** **Ý chính:** "Tên bucket state có account ID, lấy từ `aws sts get-caller-identity` lúc chạy. Chạy nhầm
account thì `init` không tìm thấy backend và dừng ngay, trước khi plan. Còn tài nguyên của người khác thì tôi
không đụng tới vì Terraform chỉ quản lý những gì có trong state của mình, và mọi thứ của project mang tiền tố
`medical-rag-` cùng tag `project`."

*Nếu được hỏi thêm:*

- **Còn thiếu:** provider chưa đặt `allowed_account_ids`, lớp chặn thứ hai rẻ nhất; tôi sẽ thêm.
- **Rủi ro thật của account dùng chung:** hai managed policy trên role của node có quyền trên toàn account (A4.4),
  và ai đó đã xoá subnet của default VPC, nên project tự tạo VPC riêng.
- **Ở công ty:** mỗi môi trường một account, và SCP chặn các thao tác nguy hiểm ở tầng Organization.

### A3. Khái niệm Terraform, giải thích bằng chính project

**A3.1** **Ý chính:** "Ansible không đọc state. Makefile lấy `terraform output` rồi truyền DNS name của NLB vào
Ansible bằng extra var, còn inventory tìm node theo tag qua EC2 API. Vì vậy Git không chứa IP hay instance ID
nào. Điểm yếu là hợp đồng giữa hai bên chỉ là tên output và tên tag, không có gì kiểm tra trước lúc chạy."

*Nếu được hỏi thêm:*

1. **Output qua Makefile:** `API_ENDPOINT = $(shell terraform -chdir=infra/terraform/cluster output -raw
   api_nlb_dns)`, rồi `ansible-playbook site.yml -e control_plane_endpoint=$(API_ENDPOINT)`. Giá trị đi vào
   `controlPlaneEndpoint` và `certSANs` của kubeadm. Account ID lấy từ `aws sts get-caller-identity`, để ghép tên
   bucket truyền file của SSM.
2. **Tag qua EC2 API:** Terraform gắn `k8s-cluster = medical-rag` và `Name = medical-rag-node-N`. Inventory
   `amazon.aws.aws_ec2` lọc theo tag mỗi lần chạy, lấy instance ID cho plugin SSM, và chia nhóm `first_node` /
   `other_nodes` theo đuôi tên.

**Chỗ dễ vỡ:**

- File inventory ghi cứng region và giá trị tag, vì nó được đọc trước khi có extra var. Đổi `project` bên
  Terraform mà quên file này thì inventory rỗng, và Ansible chỉ báo không có host nào, không lỗi (B2.8).
- Output lỗi thì Makefile truyền chuỗi rỗng. Assert đầu `site.yml` hiện chỉ kiểm tra `is defined`, nên chuỗi
  rỗng vẫn qua; cần thêm `| length > 0` (B2.6).

Chi tiết phía Ansible: [`../ansible/questions.md`](../ansible/questions.md).

**A3.2** **Ý chính:** "Terraform dựng đồ thị phụ thuộc từ các tham chiếu, và chạy song song những gì độc lập.
`depends_on` chỉ cần khi có một phụ thuộc lúc chạy mà không tham chiếu nào thể hiện, ví dụ workstation phải chờ
route table được gắn vào subnet, nếu không script boot không ra được internet."

*Nếu được hỏi thêm*, ba tình huống trong project:

- **Instance chờ route table association** (B3.6).
- **Bucket policy chờ public access block:** hai API cùng lúc trên một bucket mới có thể race (B1.5).
- **Lifecycle rule chờ versioning:** rule về version cũ chỉ có nghĩa khi versioning đã bật.

**Vì sao không viết ở mọi chỗ:** nó ép chạy tuần tự; nó không nói *vì sao*, nên người đọc sau không biết dòng đó
còn cần không; và `depends_on` trên cả một module làm data source bên trong bị hoãn tới lúc apply khi thứ nó phụ
thuộc có thay đổi, nên plan đầy `(known after apply)`.

**A3.3** **Ý chính:** "`count` đánh địa chỉ theo số, `for_each` theo key. Bỏ một phần tử ở giữa danh sách
`count` làm các phần tử sau dồn index, và Terraform thay nhầm resource; với `for_each` chỉ key đó bị ảnh hưởng.
Tôi dùng `count` cho ba node và `for_each` cho bucket, secret và policy."

*Nếu được hỏi thêm:*

- `count = var.node_count` cho node và các target group attachment theo node.
- `for_each` cho hai bucket của cluster (map `etcd-backups` / `ssm-transfer` kèm số ngày giữ), các secret, các
  managed policy gắn vào role; `dynamic` block cho hai mức cảnh báo budget.
- **Có giữ `count` cho node không?** Có. Đây là ba control plane, số lượng cố định và phải lẻ; node không bị bỏ ở
  giữa mà được thay tại chỗ bằng `-replace`; tên `node-1..3` sinh thẳng từ index. Nếu cần bỏ đúng node 2 hoặc thêm
  nhóm worker, tôi chuyển sang `for_each` với key ổn định, kèm block `moved` cho cả node lẫn các target group
  attachment, để không phải tạo lại máy nào.

**A3.4** **Ý chính:** "`prevent_destroy` trên bucket state và Route 53 zone, vì mất chúng là mất state hoặc
domain chết hàng giờ. `ignore_changes = [ami]` trên node, vì AMI mới nhất đổi vài tuần một lần và không có dòng
này thì plan đòi thay cả ba node cùng lúc. Tôi không dùng `create_before_destroy`, vì resource ở đây mang tên cố
định nên bản mới sẽ trùng tên bản cũ."

*Nếu được hỏi thêm:*

| Cài đặt | Ở đâu | Để làm gì |
|---|---|---|
| `prevent_destroy` | Bucket state, Route 53 zone | Mất bucket là mất state của mọi stack; mất zone là phải sửa ở registrar và chờ DNS |
| `ignore_changes = [ami]` | Node, WireGuard gateway | Không thay máy mỗi khi Canonical ra image mới |
| `ignore_changes = [ami, user_data]` | Workstation | Máy đang làm việc; muốn thay thì chủ động `-replace` |
| `user_data_replace_on_change = true` | WireGuard gateway | Không phải `lifecycle`, nhưng cùng mục đích: đổi script thì thay máy, vì cloud-init chỉ chạy một lần |

Với `create_before_destroy`, security group `medical-rag-nodes`, NLB `medical-rag-api`, tên bucket, tên role đều
sẽ trùng; muốn dùng phải chuyển sang `name_prefix`. Với node control plane thì tạo máy mới trước cũng không đủ:
máy mới phải join etcd và máy cũ phải được gỡ khỏi etcd, và thứ tự đó do kubeadm quyết định.

**A3.5** **Ý chính:** "Không. `sensitive` chỉ che giá trị khi in ra màn hình; trong state nó vẫn là plaintext,
ai đọc được bucket state là đọc được. Vì vậy project không cho giá trị secret nào đi qua Terraform: Terraform
chỉ tạo secret rỗng, còn giá trị được nhập bằng CLI."

*Nếu được hỏi thêm:*

- `terraform output -raw <tên>` vẫn in giá trị sensitive ra.
- Không đặt secret vào user data: từ AWS provider v6, `user_data` nằm nguyên văn trong state (B1.6).
- **Nếu buộc phải đưa giá trị qua Terraform:** Terraform 1.10 có giá trị `ephemeral`, không ghi vào state hay
  plan; 1.11 có write-only argument như `secret_string_wo` (B8.3).

### A4. Bảo mật

**A4.1** **Ý chính:** "Terraform chỉ tạo secret rỗng, nên giá trị không bao giờ vào state. Giá trị được đưa vào
Secrets Manager một lần bằng CLI từ một file, rồi file bị `shred`. Trong cluster, External Secrets đồng bộ giá trị
thành Kubernetes Secret. Không máy nào có access key: mọi thứ dùng instance role."

*Nếu được hỏi thêm:*

- **Git:** `.gitignore` loại `*.tfvars` (chỉ commit file `.example`) và mọi file state. Giá trị tfvars thật duy nhất
  là email nhận cảnh báo budget.
- **Key không bao giờ đi qua Terraform:** private key của Rancher và server key của WireGuard sinh trên
  workstation, đưa vào Secrets Manager rồi file bị `shred -u`. Gateway đọc key lúc boot. Private key WireGuard của
  laptop không rời laptop.
- **CloudShell** dùng phiên đăng nhập console.
- **Rủi ro còn lại:** thứ gì gõ inline sẽ nằm trong lịch sử shell, và role admin của workstation đọc được mọi
  secret.

**A4.2** **Ý chính:** "Chỗ đạt: inline policy của node ghi đúng ARN của một repository, ba bucket, bốn secret và
một key, còn WireGuard gateway chỉ đọc được đúng một secret. Chỗ chưa đạt: workstation có `AdministratorAccess`,
mọi pod tới được metadata service dùng chung role của node, và hai managed policy trên role đó có quyền toàn
account."

*Nếu được hỏi thêm:*

- `"*"` duy nhất trong inline policy là token xác thực của ECR, vì IAM không cho giới hạn action đó theo
  resource (B7.2).
- Hai managed policy: đọc mọi SSM parameter; attach, detach, snapshot mọi EBS volume (B7.3). Account lại dùng chung
  với project khác.
- Internal NLB tin cả CIDR của VPC (B5.4).
- **Cách sửa:** tách role plan và role apply; IAM riêng cho từng workload bằng IRSA tự host; tham chiếu security
  group thay cho CIDR.

**A4.3** **Ý chính:** "Chỉ hai đường vào từ internet: TCP 80 trên public NLB cho app, và UDP 51820 trên WireGuard
gateway. Không có SSH ở đâu cả, và node không có public IP. Tôi kiểm chứng bằng cách rà rule inbound, gửi request
thử và mô phỏng IAM."

*Nếu được hỏi thêm:*

- **Không có đường vào:** workstation có public IP nhưng không có rule inbound; Kubernetes API và Rancher chỉ có
  trên internal NLB.
- **Lớp bảo vệ khác:** IMDSv2 bắt buộc, EBS mã hoá, S3 chặn truy cập public và chỉ nhận TLS. HTTPS cho app nằm
  ngoài phạm vi và đã ghi rõ.
- **Đã kiểm chứng:**
  - request HTTP thường tới bucket state trả `AccessDenied`
  - IAM policy simulation: `kms:Sign` trên cosign key là `allowed`, `s3:GetObject` trên bucket lạ là `implicitDeny`
  - rà rule inbound: TCP 80 là rule duy nhất mở ra internet, WireGuard thêm UDP 51820
  - qua tunnel, handshake WireGuard thành công và DNS trả về IP private của NLB
  - qua VPN, test TCP cho thấy 443 mở và 6443 đóng: `[điền: lệnh và kết quả]`

**A4.4** **Ý chính:** "Tuỳ pod nằm ở namespace nào. Pod của app bị NetworkPolicy chặn gọi metadata service, nên
không lấy được credential. Pod ở namespace được phép gọi, như Jenkins agent, External Secrets, EBS CSI, thì dùng
được role của node. Nặng nhất là quyền ký image bằng KMS: image độc hại được ký sẽ qua được Kyverno."

*Nếu được hỏi thêm:*

- **Vì sao pod tới được role của node:** cluster tự quản lý không có sẵn IRSA hay Pod Identity, mà các driver cần
  quyền AWS, nên hop limit của IMDSv2 để 2 (B7.1).
- **Tiếp theo:** token GitHub (đổi được thứ Argo CD deploy), hai managed policy có quyền toàn account trên SSM
  parameter và EBS volume. Danh sách xếp hạng đầy đủ ở B7.3.
- **Lỗ còn lại:** pod `hostNetwork` không bị NetworkPolicy chặn, nên phải dùng Kyverno để cấm pod thường bật
  `hostNetwork`. Việc dài hạn là IRSA tự host để mỗi workload có role riêng.
- NetworkPolicy chặn metadata: `[điền: file manifest và bằng chứng test]`.

**A4.5** **Ý chính:** "Hiện project chỉ chạy `fmt` và `validate` trên cả ba stack. Cách tôi sẽ làm: `tflint` và
Checkov chạy ở pre-commit rồi chạy lại trong CI, còn quy tắc riêng của tổ chức thì viết bằng Conftest trên JSON
của plan. Mục tiêu là phân loại từng cảnh báo kèm lý do, không phải ép scanner về 0."

*Nếu được hỏi thêm*, những cảnh báo tôi dự đoán scanner sẽ đưa ra (chưa chạy):

| Cảnh báo | Quyết định |
|---|---|
| Không bật S3 access logging | Bỏ qua: bucket nhỏ, CloudTrail đã ghi các API call quản lý |
| SSE-S3 thay vì KMS key do khách hàng quản lý | Bỏ qua: lab, không cần key policy riêng |
| Egress mở tới `0.0.0.0/0` | Bỏ qua: node cần ra Gemini, ECR, SSM qua NAT |
| Public IP của workstation | Bỏ qua: không có rule inbound, chỉ là lối ra |
| `AdministratorAccess` trên workstation | Giữ lại làm lỗi thật |
| Managed policy toàn account trên role của node | Giữ lại làm lỗi thật |

Ví dụ quy tắc tổ chức: "không có ingress `0.0.0.0/0` ngoài hai rule đã duyệt".

**A4.6** **Ý chính:** "Tôi không viết tay policy đó. Tôi chạy một vòng apply rồi destroy bằng role rộng, để IAM
Access Analyzer sinh policy từ CloudTrail, rồi siết theo tiền tố `medical-rag-*` và tag `project`. Phần khó nhất là
IAM: ai tạo được role và gắn policy tuỳ ý thì tự nâng mình lên admin được, nên phải bắt buộc permissions boundary
và chỉ cho `PassRole` đúng các role của project."

*Nếu được hỏi thêm*, các nhóm quyền:

- **State:** `s3:ListBucket` trên bucket state; `GetObject`, `PutObject` trên `cluster/terraform.tfstate`;
  `GetObject`, `PutObject`, `DeleteObject` trên `cluster/terraform.tfstate.tflock`.
- **Tra cứu shared:** `ecr:DescribeRepositories`, `s3:GetBucket*`, `kms:DescribeKey`, `kms:ListAliases`,
  `secretsmanager:DescribeSecret`, `route53:GetHostedZone`, `route53:ListHostedZones`, `ssm:GetParameter` cho AMI,
  `sts:GetCallerIdentity`.
- **Tạo và xoá:** EC2 (VPC, subnet, gateway, EIP, security group, instance, endpoint), Elastic Load Balancing, S3
  cho hai bucket `medical-rag-*`, `route53:ChangeResourceRecordSets` trên đúng zone.
- **IAM:** tạo role, policy, instance profile, và `iam:PassRole`; siết thêm bằng `aws:ResourceTag/project` và
  `aws:RequestTag/project`.

**A4.7** **Ý chính:** "Hôm nay câu trả lời chưa đủ tốt, và tôi nói thẳng đó là điểm yếu. Terraform chạy trên
workstation bằng instance role có `AdministratorAccess`, nên CloudTrail chỉ ghi tên role và instance, không ghi
người. Muốn biết ai, tôi phải tìm sự kiện mở session SSM quanh thời điểm đó để thấy IAM identity của người mở."

*Nếu được hỏi thêm:*

- Bước tra cụ thể trong CloudTrail: AWS B6.5.
- Log nội dung session SSM chưa bật, nên không xem lại được người đó đã gõ lệnh gì.
- **Cách sửa:** apply chỉ qua CI (A2.6), mỗi người một role SSO, bật log session ra S3 hoặc CloudWatch, và tách
  role của workstation (A4.6).

**A4.8** **Ý chính:** "Không phải sửa Terraform: Terraform chỉ quản lý phần vỏ của secret. Rotate là
`put-secret-value` để tạo version mới, và External Secrets đồng bộ xuống cluster. Chỗ cần để ý là thứ chỉ đọc
secret một lần, như WireGuard gateway đọc key lúc boot, nên đổi key thì phải thay gateway."

*Nếu được hỏi thêm:*

| Secret | Cách rotate | Để ý |
|---|---|---|
| Token GitHub | Tạo token mới, `put-secret-value`, thu hồi token cũ | Pod đọc secret qua biến môi trường chỉ thấy giá trị mới sau khi restart |
| Key server WireGuard | Sinh cặp key mới, `put-secret-value`, `terraform apply -replace=aws_instance.wireguard` | Profile trên laptop phải cập nhật public key mới của server |
| Certificate Rancher | Gia hạn với Sectigo, `put-secret-value` cho `rancher-tls` | Không có gì tự gia hạn; chỉ có nhắc lịch trước ngày hết hạn. Nếu phiền, chuyển sang cert-manager với Let's Encrypt DNS-01 |
| Cosign KMS key | Không rotate tự động được | Tạo key mới, chuyển alias, giữ public key cũ hoặc ký lại image (AWS B4.5) |

### A5. Chi phí

**A5.1** **Ý chính:** "Cluster khoảng 0.53 USD mỗi giờ và chỉ sống theo giờ; phần luôn giữ khoảng 7 USD mỗi
tháng. Đơn giá lấy từ bảng giá AWS cho Singapore, còn chi phí thực được budget theo dõi theo tag `project`."

*Nếu được hỏi thêm:*

| Hạng mục | Chi phí |
|---|---|
| Cluster, khi đang tồn tại | ≈ 0.53 USD/giờ |
| Workstation, khi đang chạy | ≈ 0.03 USD/giờ |
| Luôn giữ: KMS key, 5 secret, zone, bucket, image | ≈ 4 USD/tháng |
| Ổ đĩa của workstation khi đã stop | ≈ 2.90 USD/tháng |
| **Tổng phần luôn giữ** | **≈ 7 USD/tháng** |

- Cluster gồm ba node `m7i-flex.large`, NAT gateway, hai NLB, địa chỉ IPv4 public, 120 GB gp3 và WireGuard
  gateway.
- Credit Free plan: 128.47 USD, hạn tới 2027-02-13, đủ khoảng 240 giờ cluster theo evidence (chưa trừ phần chi phí
  luôn giữ). Cập nhật số credit còn lại trước buổi phỏng vấn: `[điền: credit còn lại]`.

**A5.2** **Ý chính:** "Tiết kiệm lớn nhất là xoá cluster khi không dùng. Cái giá là phải chia ba stack và phải
dựng lại được trong vài phút, và tôi đã đo việc đó. Sau đó là một NAT gateway thay vì ba, đổi lại một điểm lỗi
đơn cho traffic đi ra."

*Nếu được hỏi thêm:*

| Khoản tiết kiệm | Đánh đổi |
|---|---|
| Xoá cluster khi không dùng | Chia ba stack; phải dựng lại nhanh |
| Một NAT gateway thay vì ba | Điểm lỗi đơn cho traffic đi ra (A1.11) |
| Loại máy hợp lệ với Free plan | `m7i-flex.large` không có metric CPU credit để cảnh báo (AWS B3.6) |
| S3 gateway endpoint | Không mất gì; nó miễn phí |
| Không dùng interface endpoint | SSM phụ thuộc NAT |
| SSE-S3 thay vì KMS | Không tốn phí KMS theo request, nhưng không kiểm soát được bằng key policy |
| WireGuard thay vì Client VPN | Tự quản lý gateway |
| Stop workstation khi không dùng | Mất vài phút để bật lại |
| Lifecycle rule trên mọi bucket | Version cũ biến mất sau thời hạn |

**A5.3** **Ý chính:** "Budget 100 USD mỗi tháng gửi email ở mức 50 % và 100 % chi phí thực, chỉ đếm tài nguyên có
tag `project` vì account dùng chung. Thói quen quan trọng hơn là xoá cluster khi không dùng. Trên Free plan, rủi ro
thật không phải hoá đơn mà là hết credit và account bị đóng, nên tôi theo dõi số credit còn lại."

*Nếu được hỏi thêm:*

- Tag `project` phải được kích hoạt làm cost allocation tag thì budget mới đếm được: `[điền: đã kích hoạt, ngày]`.
- Budget chỉ cảnh báo trên chi phí thực, không dùng FORECASTED, vì dự báo trên tài khoản bật tắt theo giờ gây báo
  động giả.
- Budget mặc định tính chi phí sau khi trừ credit **[kiểm chứng]**, và code không đặt `cost_types`; nếu đúng, lúc còn credit
  cảnh báo không bao giờ bắn. Sửa bằng `cost_types { include_credit = false }` `[điền: kiểm tra budget thật]` (AWS B6.2).
- **Lọt khỏi budget:** volume do EBS CSI tạo không có tag nếu không cấu hình (B3.7), thuế, một phần phí truyền dữ
  liệu (B8.6).
- **Sẽ thêm:** Cost Anomaly Detection, kiểm tra volume `available` bị bỏ lại sau mỗi lần xoá cluster, và một job
  theo lịch tự xoá stack cluster nếu nửa đêm vẫn còn chạy.

**A5.4** **Ý chính:** "Ràng buộc cứng nhất là Free plan chỉ cho chạy loại máy đủ điều kiện. Trong số đó tôi cần
tối thiểu 2 vCPU cho kubeadm, và khoảng 8 GB vì mỗi node vừa là control plane vừa chạy Jenkins, Prometheus và
app. Kết quả là node `m7i-flex.large`, workstation `t3.small` kèm swap."

*Nếu được hỏi thêm*, theo thứ tự ràng buộc:

1. **Free plan:** chỉ loại máy đủ điều kiện (A7.1).
2. **kubeadm:** tối thiểu 2 vCPU và 2 GB mỗi node control plane.
3. **Tải thật:** control plane cộng Jenkins, Prometheus và app.
4. **Có ở cả ba AZ:** `aws ec2 describe-instance-type-offerings --location-type availability-zone`.
5. **Quota vCPU** của account (AWS B6.4).
6. **Giá theo giờ.**

Workstation chỉ chạy Terraform, Ansible và kubectl; image được build trong cluster, nên 2 GB cộng 2 GB swap là đủ.
Rủi ro đi kèm: `m7i-flex` không có metric CPU credit, nên monitoring cảnh báo theo mức dùng CPU kéo dài.

### A6. Vận hành, độ tin cậy và khôi phục

**A6.1** **Ý chính:** "Bằng cách đo, không phải bằng niềm tin. Tôi xoá stack cluster rồi dựng lại từ đầu, không có
bước thủ công nào ở giữa, và plan ngay sau đó báo không còn thay đổi. Bản 65 resource mất 1 phút 27 giây để xoá và
3 phút 19 giây để dựng lại; bản đủ 84 resource: `[điền]`."

*Nếu được hỏi thêm:*

- `make shared-plan` sau khi dựng lại cluster cũng báo `No changes`, nên các stack cô lập với nhau.
- Mọi bước verify của step 18 (WireGuard, DNS, listener) đạt trên bản 84 resource.
- **Giới hạn cần nói thẳng:**
  - "không bước thủ công" chỉ nói về Terraform; cả chuỗi từ hạ tầng tới app là `make up`: `[điền: thời gian]`.
  - AMI không được ghim, nên mỗi lần dựng lại có thể bắt đầu từ image Ubuntu mới hơn (B3.4).
  - Một số bước về bản chất là thủ công nhưng đã được ghi lại và kiểm chứng: apply bootstrap, delegate DNS, nhập
    giá trị secret.

**A6.2** **Ý chính:** "Nếu cluster được phép nghỉ thì không cần làm gì: `ignore_changes` chỉ bảo vệ máy đang tồn
tại, nên lần dựng lại sau tự lấy AMI mới nhất. Nếu cluster phải chạy liên tục thì thay từng node một, theo đúng
quy trình thay node control plane, và chỉ sang node tiếp khi etcd có đủ ba member khoẻ."

*Nếu được hỏi thêm:*

- **Thay từng node:** snapshot etcd, drain, gỡ member etcd, `terraform apply -replace='aws_instance.nodes[N]'`, join
  bằng Ansible, xác nhận ba member khoẻ (B7.6).
- **Bản vá gấp không cần đổi AMI:** Ansible chạy `apt` tại chỗ theo cùng khuôn với `upgrade.yml`: `serial: 1`,
  drain, reboot, chờ node Ready rồi mới sang node tiếp.
- Nâng phiên bản Kubernetes là việc của kubeadm và `upgrade.yml`, không phải của Terraform.

**A6.3** **Ý chính:** "Không có rollback. Terraform vẫn ghi vào state mọi resource đã tạo xong trước khi lỗi, nên
tôi đọc lỗi, sửa nguyên nhân rồi apply lại: phần đã có được giữ, phần còn thiếu được tạo tiếp. Ví dụ thật là lần
launch EC2 đầu tiên lỗi vì Free plan: đổi loại máy rồi apply lại."

*Nếu được hỏi thêm:*

1. Đọc lỗi.
2. Kiểm tra lock đã được nhả; chỉ `force-unlock` khi process thực sự đã chết.
3. `terraform plan` để xem còn lại gì.
4. Sửa nguyên nhân gốc, apply lại.

- Resource đã tạo nhưng chưa hoàn tất bước sau đó bị đánh dấu `tainted`, và bị thay ở lần apply tiếp theo.
- **Trường hợp hiếm:** process chết giữa lúc AWS tạo xong và lúc ghi state để lại resource mồ côi mà Terraform
  không biết. Tìm theo tag rồi `import`.

**A6.4** **Ý chính:** "Provider không tự nhảy phiên bản: ràng buộc `~> 6.64` chặn bản 7, và lock file ghim đúng
6.64.0. Nâng cấp là đọc upgrade guide, chạy `init -upgrade` trên một branch, plan cả ba stack cho tới khi mọi khác
biệt đều giải thích được, rồi apply từ stack dùng xong xoá được trước."

*Nếu được hỏi thêm:*

1. Apply `cluster/` trước, vì xoá dựng lại được.
2. Rồi `shared/`, rồi `bootstrap/` từ CloudShell.
3. Commit lock file mới.

- Lock file hiện có ở `shared/` và `cluster/`; `bootstrap/` chưa commit (B1.7).
- Lock file không ghi phiên bản module, nên `~> 6.7` của module VPC có thể trôi lên bản mới ở lần `init` trên máy
  sạch. Muốn chặt thì ghim chính xác đúng bản đang dùng (ví dụ `version = "6.7.0"`) và nâng có chủ đích theo cùng
  quy trình.

**A6.5** **Ý chính:** "Những gì tôi đã làm thật: `fmt` và `validate` trên cả ba stack, và chu trình xoá rồi dựng
lại cluster thật với các bước kiểm tra được ghi lại. Mỗi step trong guide kết thúc bằng một bước verify. Tôi chưa
viết `terraform test` hay Terratest."

*Nếu được hỏi thêm*, cách tôi sẽ làm theo từng lớp:

1. **Tĩnh:** `fmt`, `validate`, `tflint`, Checkov.
2. **Review plan:** assert trên JSON của plan cho các quy tắc.
3. **Unit:** `terraform test` (có từ 1.6; provider giả lập từ 1.7) cho logic như tính CIDR, đặt tên, số lượng.
4. **Tích hợp:** apply và destroy thật kèm kiểm tra; Terratest tự động hoá được, đổi lại tốn resource thật.

**A6.6** **Ý chính:** "Nếu file bị ghi hỏng hoặc bị xoá, bucket có versioning nên tôi lấy lại version trước và đẩy
lên. Nếu mất hẳn, hạ tầng thật vẫn chạy nhưng Terraform không biết: với stack cluster, tôi xoá tài nguyên theo tag
rồi dựng lại; với stack shared thì bắt buộc import, vì KMS key và secret có giá trị không được tạo lại."

*Nếu được hỏi thêm:*

- **Lấy lại version:** tải version cũ rồi `terraform state push` (kèm `-force` nếu serial cũ hơn, B1.4). Object bị
  xoá chỉ có thêm delete marker; xoá marker đó là file quay lại.
- **Nếu cứ `make infra` khi state đã mất:** Terraform tạo một VPC và NAT gateway thứ hai (có tính tiền), rồi mới lỗi
  vì trùng tên ở IAM role, instance profile, NLB, target group, bucket và record Route 53. Security group thì không
  trùng, vì tên chỉ cần duy nhất trong một VPC.
- **Xoá theo tag:** Resource Groups Tagging API với `stack = cluster` và `project = medical-rag`.
- **Phòng ngừa:** versioning 90 ngày, `prevent_destroy`, chặn truy cập public và chỉ nhận TLS. Ở công ty: replication
  sang account khác và giới hạn quyền xoá object trong bucket state.

**A6.7** **Ý chính:** "Code thì mang đi được, vì account ID và tên bucket đều suy ra lúc chạy. Cái mất là thứ nằm
trong account: KMS key không export được nên không ký tiếp được bằng key đó, giá trị secret, image cùng chữ ký trong
ECR, và zone mới có name server mới nên phải sửa ở registrar. Chữ ký cũ chỉ còn kiểm được nếu đã lưu public key ra ngoài. Hiện không có bản sao nào nằm ngoài account."

*Nếu được hỏi thêm:*

- **Trước khi Free plan hết hạn:** cách đơn giản nhất là nâng lên gói trả phí (AWS B6.1).
- **Nếu phải rời account:** chép các version state ra ngoài; ghi lại public key của cosign key; push image sang
  registry khác; giữ bản sao mã hoá của giá trị secret; đổi name server ở registrar và làm lại bước xác minh của
  Sectigo.
- Index build lại được từ PDF, chỉ tốn thời gian và quota API.

### A7. Sự cố và bài học

**A7.1** **Ý chính:** "Lần launch EC2 đầu tiên lỗi `not eligible for Free Tier` dù account còn credit. Tôi nghĩ
ngay tới credit, nhưng đọc kỹ thì lỗi nói về loại máy. Tôi kiểm tra trạng thái gói của account bằng API, thấy
account đang ở Free plan, gói chặn mọi loại máy không đủ điều kiện bất kể credit. Tôi liệt kê loại máy hợp lệ, đổi
cấu hình, và ghi lại rủi ro mới vào thiết kế."

*Nếu được hỏi thêm:*

- **Lệnh kiểm chứng:** `aws freetier get-account-plan-state`; `aws ec2 describe-instance-types --filters
  Name=free-tier-eligible,Values=true`.
- **Thay đổi:** workstation `t3.medium` → `t3.small` kèm 2 GB swap; node `t3.large` → `m7i-flex.large`.
- **Rủi ro mới ghi lại:** `m7i-flex` không có metric CPU credit, nên monitoring cảnh báo theo mức dùng CPU kéo dài.
- **Chuyện khác:** thư mục home 1 GB của CloudShell (A7.3); delegate DNS thay vì chuyển domain sang Route 53, vì Free
  plan không cho phép. Chuyện SSM agent của node 2 thuộc phần Ansible, có quy trình chẩn đoán tốt nhưng nguyên nhân
  mới là giả thuyết.

**A7.2** **Ý chính:** "WireGuard gateway đầu tiên boot lỗi `cloud-init`, và tôi dựng lại máy ngay mà không giữ log.
Máy mới chạy được, nhưng tôi mất nguyên nhân gốc: khả năng cao là secret còn rỗng lúc boot, nhưng không chứng minh
được. Bài học: thu log trước khi thay máy, và bây giờ đó là bước đầu tiên trong troubleshooting."

*Nếu được hỏi thêm*, hai sai sót khác tôi tự tìm ra khi rà lại code:

- Giá trị mặc định của `wireguard_cidr` là `10.99.0.0/24`, nằm trong dải Service `10.96.0.0/12` dù mô tả của biến nói
  không được trùng. Chưa gây hỏng vì gateway NAT địa chỉ của laptop (B9.7).
- NAT gateway, WireGuard gateway và node 1 cùng nằm ở AZ đầu tiên (A1.11).
- `[điền: một plan có "must be replaced" hoặc "N to destroy" mà bạn đã dừng lại — chỉ kể nếu thật sự xảy ra]`.

**A7.3** **Ý chính:** "Thư mục home của CloudShell chỉ có 1 GB, mà AWS provider sau khi giải nén chiếm khoảng 830 MB
trong `.terraform/`. Tôi xác nhận bằng `df -h`, rồi trỏ `TF_DATA_DIR` sang `/tmp` và `init` lại."

*Nếu được hỏi thêm:* `/tmp` không được giữ giữa các phiên, nên mỗi phiên mới phải export và init lại. CloudShell
giữ gì và vì sao không nên để state ở đó: AWS B6.3.

**A7.4** **Ý chính:** "Vào gateway qua Session Manager, vì role của nó có quyền SSM. Rồi đọc `cloud-init-output.log`:
mấy dòng ngay trên `Failed to run module scripts_user` cho biết nguyên nhân. Nếu cả SSM cũng không vào được, lấy log
boot bằng `get-console-output` mà không cần đăng nhập."

*Nếu được hỏi thêm:*

1. `aws ssm start-session --target <id>`, `cloud-init status --wait`, `sudo tail -20 /var/log/cloud-init-output.log`.
2. `ResourceNotFoundException` hoặc `can't find the specified secret value`: key chưa được lưu lúc gateway boot. Lưu
   key, rồi `terraform apply -replace=aws_instance.wireguard`.
3. Không có dòng lỗi nào: bước kiểm tra key bằng `jq -e` thất bại, tức secret thiếu một key.
4. **Lưu log trước khi `-replace`** (A7.2).

**A7.5** **Ý chính:** "Trước hết xem mã lý do của target trong NLB. Rồi vào node 1 gọi thẳng `/readyz` trên
localhost: lỗi thì vấn đề nằm ở API server, xem static pod và kubelet; trả lời được thì vấn đề nằm trên đường đi, tức
security group. Và nhớ rằng health check cần hai lần đạt, cách nhau 10 giây."

*Nếu được hỏi thêm:*

1. `aws elbv2 describe-target-health`: `Target.FailedHealthChecks`, `Target.Timeout`…
2. Trên node 1: `curl -k https://localhost:6443/readyz`; nếu lỗi, `sudo crictl ps -a` và `journalctl -u kubelet`.
3. Đường đi: egress của security group NLB tới node trên 6443 (health check đi theo egress, B5.6), ingress
   `nodes_api_from_nlb`.
4. `/readyz` trả `401`/`403`: anonymous auth đã bị tắt (B6.2).

### A8. Nhìn lại

**A8.1** **Ý chính:** "Việc đầu tiên là bỏ `AdministratorAccess` trên workstation, tách thành role plan và role apply.
Thứ hai là giới hạn 6443 trên internal NLB bằng security group của node thay vì cả CIDR của VPC. Thứ ba là CI chạy
plan trên pull request qua OIDC. Mấy việc còn lại đều nhỏ và đã ghi lại."

*Nếu được hỏi thêm*, các việc nhỏ:

- Dời WireGuard gateway sang AZ khác NAT gateway (B4.4).
- Đổi mặc định `wireguard_cidr` ra khỏi dải Service (B9.7).
- Commit lock file của bootstrap, ghim chính xác module VPC, nâng `required_version` lên 1.11 (B1.3, B1.7).
- Thêm `allowed_account_ids` cho provider (A2.12).
- Tách module hardened bucket (A1.10).
- Job xoá cluster theo lịch làm lưới an toàn cho chi phí.

**A8.2** **Ý chính:** "Ở công ty tôi sẽ tách account theo môi trường trong một AWS Organization, không có máy admin
nào mà chỉ apply qua CI có review, và nhiều khả năng dùng EKS để mỗi workload có role IAM riêng."

*Nếu được hỏi thêm:*

- **Truy cập:** role SSO cho người, role OIDC cho CI.
- **Mạng:** mỗi AZ một NAT gateway, và interface endpoint.
- **Traffic của app:** HTTPS qua ALB và ACM.
- **Truy cập quản trị:** qua identity provider có MFA (Client VPN, hoặc một zero-trust access proxy) thay vì key
  WireGuard quản lý bằng tay.
- **Kiểm toán:** CloudTrail toàn organization, AWS Config, GuardDuty, SCP và tag policy.

---

## Phần B — Chi tiết

### B1. State và backend

**B1.1** Lần apply đầu tiên chạy trong CloudShell với **state local**: lúc đó chưa có `backend.tf`, nên
state chỉ là một file nằm cạnh code. Lần apply đó tạo bucket và workstation. Ở step 6, `backend.tf` được
thêm vào và `terraform init -migrate-state -backend-config=...` chép file local lên
`bootstrap/terraform.tfstate` trong bucket. Sau đó `terraform plan` báo `No changes` và bản local bị xoá.

Nếu có `backend.tf` ngay từ đầu, `terraform init` sẽ lỗi: S3 backend kiểm tra bucket lúc init, mà bucket
lúc đó chưa tồn tại. Đây là bài toán con gà quả trứng quen thuộc của remote state, và migrate sau khi tạo
bucket là cách giải chuẩn.

*Ở đâu:* `bootstrap/backend.tf`; guide step 4 và 6.

**B1.2** Block `backend` được đọc trong lúc `terraform init`, trước khi variable, local hay data source
tồn tại, nên không dùng được những thứ đó. Tên bucket chứa account ID, nên được bỏ ra và truyền vào dưới
dạng **partial configuration**:

- **Workstation:** Makefile dựng `-backend-config="bucket=$(PROJECT)-tfstate-$(ACCOUNT_ID)"
  -backend-config="region=$(REGION)"`. `ACCOUNT_ID` lấy từ `aws sts get-caller-identity`; `REGION` mặc định
  `ap-southeast-1` và ghi đè được bằng `make REGION=…`.
- **CloudShell:** gõ tay đúng hai cờ đó ở step 6.

Nhờ vậy không có account ID nào bị commit vào Git, và cùng một code chạy được trên mọi account.

*Ở đâu:* `Makefile` (`BACKEND`); mọi file `backend.tf`.

**B1.3** S3 backend tự lock được state, không cần bảng DynamoDB như các setup cũ. Tính năng này xuất hiện
dạng thử nghiệm ở Terraform 1.10 và chính thức từ 1.11, cũng là lúc lock bằng DynamoDB bị deprecated.

Trong lúc làm việc, Terraform tạo object `<key>.tflock` cạnh file state bằng một *conditional write*: lệnh
ghi chỉ thành công nếu object đó chưa tồn tại. Vì vậy người chạy cần thêm quyền `s3:GetObject`,
`s3:PutObject` và `s3:DeleteObject` trên `<key>.tflock` (Terraform đọc lock để in ra ai đang giữ nó). Lần chạy thứ hai lỗi ngay với `Error acquiring the state lock`, kèm
lock ID, ai đang giữ lock và giữ từ lúc nào. `plan` cũng lấy lock.

Lần chạy bị crash sẽ để lock lại. Trước tiên phải chắc chắn không còn process Terraform nào đang chạy, rồi
chạy `terraform force-unlock <LOCK_ID>` trong đúng stack đó.

*Ở đâu:* `use_lockfile = true` trong mỗi `backend.tf`; `required_version = ">= 1.10"`.
*Hỏi tiếp:* vì sao `required_version` vẫn là `>= 1.10`? Nên nâng lên 1.11, bản đầu tiên tính năng này
chính thức.

**B1.4**

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

**B1.5** Versioning chỉ cần bucket tồn tại, và reference `aws_s3_bucket.state.id` đã thể hiện điều đó.
Encryption và public access block cũng chỉ tham chiếu bucket, và cả ba chạy song song với nhau không vấn đề
gì.

Policy cũng chỉ tham chiếu bucket, nên nếu không có `depends_on` nó sẽ chạy song song với public access
block. `PutBucketPolicy` và `PutPublicAccessBlock` cùng lúc trên một bucket mới là một race đã biết của S3
(lỗi `OperationAborted` hoặc `AccessDenied`). Không có reference nào giữa hai resource để Terraform tự suy
ra thứ tự, nên phải khai báo. Đây là sắp thứ tự phòng thủ: project này chưa gặp lỗi đó.

Lifecycle rule có `depends_on` tới versioning vì lý do khác: rule về noncurrent version chỉ có nghĩa khi
versioning đã bật.

*Ở đâu:* `bootstrap/state.tf`, `shared/storage.tf`, `cluster/storage.tf`.

**B1.6**

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

**B1.7** `~> 6.64` là một khoảng: bất kỳ bản 6.x nào từ 6.64 trở lên. Lock file ghi lại **đúng phiên bản**
provider đã chọn (6.64.0) và **checksum** của nó. Lần `init` sau trên bất kỳ máy nào cũng cài đúng bản đó
và từ chối bản không khớp.

Stack bootstrap được init trong CloudShell, và lock file của nó chưa bao giờ được đưa vào repo. Lần `init`
sau ở đó có thể lấy provider 6.x mới hơn và cho ra thay đổi bất ngờ trong plan, ngay trên stack giữ bucket
state. Cách sửa: chép lock file đó vào repo, hoặc sinh nó bằng `terraform providers lock`.

Lock file chỉ ghim **provider**, không ghim module: `~> 6.7` của module VPC vẫn có thể trôi lên bản mới ở
lần `init` trên máy sạch (xem A6.4).

**B1.8** Bucket state chưa tồn tại, nên `terraform init` với backend S3 sẽ lỗi (B1.1). Phải tạm dùng state local:

1. Thêm `bootstrap/backend_override.tf` chứa `terraform { backend "local" {} }` (file `*_override.tf` ghi đè
   cấu hình gốc), hoặc tạm đổi tên `backend.tf`.
2. `terraform init`, `terraform apply`: bucket và workstation được tạo, state nằm ở local.
3. Xoá file override, rồi `terraform init -migrate-state -backend-config="bucket=…" -backend-config="region=…"`.
4. `terraform plan` phải báo `No changes`.

`terraform init -backend=false` không đủ, vì `apply` vẫn đòi backend đã được khởi tạo.

### B2. Các stack và cách chúng nối với nhau

**B2.1**

- **bootstrap, bucket state.** Mọi stack khác lưu state vào nó, nên nó phải có trước. Đặt trong `shared/`
  thì bucket sẽ chứa chính state mô tả bucket đó.
- **shared, cosign KMS key.** Chữ ký image chỉ kiểm tra được bằng public key của đúng key này. Đặt trong
  `cluster/` thì mỗi lần dựng lại nó bị tạo lại và làm mất hiệu lực mọi chữ ký. Đặt trong `bootstrap/` thì
  chỉ apply được từ CloudShell, dù nó không thuộc phần nền móng.
- **cluster, NAT gateway.** Tính tiền theo giờ và chỉ có ích khi có node. Đặt trong `shared/` thì nó tốn
  tiền suốt ngày đêm mà không để làm gì.

**B2.2** **Ưu điểm:** loose coupling. Cluster không cần quyền đọc file state của shared (file mô tả mọi thứ
trong stack đó), cũng không phụ thuộc vào tên output hay nơi lưu state. Việc tra cứu còn kiểm tra resource
*thực sự đang tồn tại* trên AWS, chứ không chỉ là một file state nói vậy.

**Điểm yếu:** hợp đồng giữa hai stack là một quy ước đặt tên không được ghi ở đâu (`${project}/llm`,
`alias/${project}-cosign`).

- Đổi tên thứ gì đó trong `shared/` thì không có cảnh báo nào cho tới khi plan cluster lần sau lỗi.
- Terraform không có đồ thị phụ thuộc giữa các stack, nên xoá một resource shared mà cluster đang dùng
  không có cảnh báo gì.
- Tra cứu theo tên có thể khớp nhiều đối tượng: hai hosted zone cùng tên `recruitai.io.vn` sẽ làm
  `data "aws_route53_zone"` lỗi.

**B2.3** Nó lỗi ngay trong **plan**, lúc đọc các data source trong `cluster/main.tf` (`aws_ecr_repository`,
`aws_s3_bucket`, `aws_kms_alias`, `aws_secretsmanager_secret`) và trong `wireguard.tf` / `rancher.tf`. Data
source có input đã biết được đọc trước khi tạo bất cứ thứ gì, nên chưa có resource nào tồn tại.

Đó là hành vi tốt: thiếu phụ thuộc thì dừng trước khi dựng được nửa cluster rồi phải dọn dẹp.

**B2.4** `shared/` sở hữu `aws_route53_zone.main`. `cluster/` sở hữu `aws_route53_record.rancher` (alias
tới internal NLB) và `aws_route53_record.vpn` (Elastic IP của gateway). Hai record đổi sau mỗi lần dựng
lại; zone thì không được đổi.

Nếu zone nằm trong cluster mà vẫn giữ `prevent_destroy`, `make infra-destroy` lỗi ngay ở **plan**
(`Instance cannot be destroyed`), nên không xoá được gì của cluster và việc xoá cluster hằng ngày bị chặn. Nếu bỏ
`prevent_destroy`, lệnh xoá zone sẽ không thành công: zone đang chứa các record tạo tay (CNAME xác minh của Sectigo, các record chép sang), nên AWS trả `HostedZoneNotEmpty` (xem
B3.2) và teardown kẹt lại.

Còn nếu xoá được, lần dựng lại sau sẽ tạo zone với **bốn name server mới, chọn ngẫu nhiên**. Bạn phải nhập
chúng ở registrar (nơi mua domain), rồi chờ hàng giờ cho record NS cũ ở zone cha hết hạn cache. Trong thời
gian đó cả domain không phân giải được, và các record tạo tay đã mất theo zone cũ.

**B2.5** Workstation là một resource của stack bootstrap. Apply chạy từ chính nó có thể stop nó (đổi
instance type) hoặc thay nó (một thay đổi bắt buộc tạo lại) ngay giữa lúc apply. Phiên làm việc chết,
process Terraform chết theo, lock của state bị bỏ lại và stack chỉ apply được một nửa.

CloudShell chạy bên ngoài mọi thứ Terraform quản lý ở đây, nên không thay đổi nào có thể làm nó chết.
`AdministratorAccess` là chuyện quyền hạn, không phải chuyện an toàn.

**B2.6** Qua **output**, đọc bằng `terraform output -raw`:

- `api_nlb_dns`: Makefile đọc nó vào biến `API_ENDPOINT`, truyền cho Ansible bằng
  `-e control_plane_endpoint=$(API_ENDPOINT)`, và dùng làm đích port-forward của `make tunnel`. Instance ID của
  node 1 cho `make tunnel` thì không lấy từ output mà từ `aws ec2 describe-instances`, lọc theo tag `Name`.
- `wireguard_instance_id`, `wireguard_client_address`, `wireguard_public_ip`: dùng ở guide step 18.
- `route53_name_servers`: nhập ở registrar.
- `public_nlb_dns`: địa chỉ để mở app; `rancher_url`: địa chỉ Rancher.
- `ecr_repository_url`, `cosign_kms_key_alias`, `buckets`: dùng trong Jenkinsfile và Helm values
  `[điền: file dùng từng output]`.

Output chính là API công khai của một stack. Đổi tên thì **không lỗi lúc apply**, mà lỗi ở nơi dùng, vào lúc
chạy: `terraform output -raw api_nlb_dns` báo *Output not found*, biến trong `make` thành chuỗi rỗng, và
Ansible nhận `control_plane_endpoint=` rỗng. Assert ở đầu `site.yml` hiện chỉ kiểm tra `is defined`, mà biến
rỗng vẫn *được định nghĩa*, nên assert cho qua và kubeadm lỗi giữa chừng. Muốn dừng ngay ở giây đầu thì phải
kiểm tra độ dài: `control_plane_endpoint | default('') | length > 0`. `make cluster` cũng phụ thuộc `init`, để trên một bản clone
mới `terraform output` không trả về rỗng.

Quy tắc: coi output như API. Thêm tên mới trước, chuyển nơi dùng sang, rồi mới bỏ tên cũ.

**B2.7** Data source chỉ là ảnh chụp lúc apply. Policy của node (`cluster/iam.tf`) chứa **ARN đã resolve** ở lần
apply cluster trước:

- Secret tạo lại có ARN mới (hậu tố ngẫu nhiên khác), nên External Secrets bị `AccessDenied` ở lần refresh tiếp.
- `data.aws_kms_alias.cosign.target_key_arn` vẫn trỏ key cũ, nên bước ký của CI bị `AccessDenied` trên key mới.

Không có gì báo lỗi ở phía Terraform cho tới khi apply lại cluster. Comment "the key can be rotated without
touching this code" trong `cluster/main.tf` chỉ đúng nếu sau đó có apply lại stack cluster.

**B2.8** Inventory `infra/ansible/inventory/aws_ec2.yml` ghi cứng `regions: ap-southeast-1` và
`tag:k8s-cluster: medical-rag`, vì file inventory được đọc trước khi có extra var. Node mới mang tag `demo`, nên
inventory ra **0 host**. Ansible chỉ cảnh báo không có host nào khớp, **không lỗi**, và playbook "thành công" mà
không làm gì.

Những hợp đồng ngầm khác: tên bucket truyền file SSM được ghép lại trong `group_vars/nodes.yml` theo quy ước
`<project>-ssm-transfer-<account>`; nhóm `first_node` dựa vào hậu tố tên `-node-1`. Makefile truyền
`project` và `aws_region` bằng `-e`, nhưng chỉ có tác dụng với biến, không với file inventory.

**B2.9** `:=` được tính **một lần lúc make đọc Makefile**, trước khi bất kỳ target nào chạy, kể cả `init` mà
`cluster` phụ thuộc. Trên bản clone mới, `terraform output` lỗi vì chưa init, biến thành chuỗi rỗng, và việc khai
báo `cluster: init` không cứu được. Ngoài ra mọi lệnh `make`, kể cả `make ansible-deps`, đều gọi Terraform.

`=` được tính lại mỗi lần biến được dùng, tức lúc recipe của `cluster` chạy, sau `init`. `ACCOUNT_ID` dùng `:=`
vì gần như target nào cũng cần nó, và gọi STS một lần là đủ.

**B2.10** Instance đã terminate vẫn hiện trong `describe-instances` khoảng một giờ, còn nguyên tag `Name`. Không
lọc thì:

- `Reservations[0].Instances[0]` có thể chọn trúng máy đã chết, nên `make tunnel` báo `TargetNotConnected`.
- Inventory có hai host cùng tên `medical-rag-node-1`.

Ngược lại, khi node 1 đang stop, `NODE_1` trả về `None`, nên `make tunnel` lỗi ngay; đó là hành vi đúng.

### B3. Lifecycle và các lớp bảo vệ

**B3.1** `make infra-destroy` chỉ chạy trên **state của cluster**, nên hai bucket đầu không bao giờ nằm
trong đó.

| Bucket | Lớp bảo vệ | Tác dụng |
|---|---|---|
| State (bootstrap) | `prevent_destroy` | Chặn ở phía Terraform: plan nào định xoá nó đều lỗi trước khi xoá bất cứ thứ gì |
| Artifacts (shared) | Không có `force_destroy` | Chặn ở phía AWS: S3 không xoá bucket còn object, nên destroy lỗi `BucketNotEmpty` |
| `etcd-backups`, `ssm-transfer` (cluster) | `force_destroy = true` | Provider xoá hết object rồi mới xoá bucket, nên teardown không bao giờ bị kẹt |

Mất snapshot etcd vẫn chấp nhận được vì một snapshot chỉ khôi phục được đúng cluster đã tạo ra nó. Sau
teardown, cluster được dựng lại từ code và Git, không phải từ etcd. Snapshot bảo vệ trước sự cố khi cluster
còn sống: upgrade hỏng, mất quorum, hoặc bài drill khôi phục.

**B3.2** Xoá block `aws_route53_zone`, hoặc chỉ xoá block `lifecycle` của nó, rồi apply. Lớp bảo vệ nằm
trong cấu hình, nên khi bị xoá đi thì Terraform lên plan xoá zone mà không phàn nàn gì. `prevent_destroy`
chặn tai nạn, không chặn thay đổi code có chủ ý; code review phải bắt được chuyện đó.

AWS thêm lớp bảo vệ thứ hai: nó không cho xoá hosted zone còn chứa record ngoài NS và SOA mặc định, và zone
không bật `force_destroy`. Chừng nào CNAME xác minh của Sectigo hay các record đã chép còn đó, lệnh xoá sẽ
lỗi `HostedZoneNotEmpty`.

**B3.3** Xoá một secret chỉ **lên lịch** xoá. Giá trị vẫn khôi phục được bằng `restore-secret` trong thời
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

**B3.4**

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

**B3.5** Với `true`, mọi thay đổi trong user data đã render đều lên plan **thay thế**: tạo instance mới, và
Elastic IP chuyển sang nó, nên `vpn.recruitai.io.vn` giữ nguyên.

Bỏ nó đi thì provider cập nhật `user_data` **tại chỗ**, tức là stop rồi start instance. cloud-init chỉ chạy
user script một lần cho mỗi instance ID, nên script mới **không bao giờ chạy**. Gateway giữ cấu hình cũ
trong khi Terraform báo thành công. Đó chính là lý do `wireguard.tf` đặt thuộc tính này, kèm comment giải
thích.

**B3.6** Instance tham chiếu subnet, nhưng không có gì tham chiếu tới route table association. Vì vậy
Terraform có thể launch instance trước khi association tồn tại, trong lúc subnet vẫn dùng main route table
của VPC, không có route ra internet.

Không phải lúc nào cũng hỏng: bước `apt-get update` của `workstation-init.sh` thử lại 20 lần, cách nhau 15
giây, nên vài giây thiếu route nhiều khả năng vẫn qua. Nhưng các lệnh tải về phía sau không thử lại, `set -e`
dừng script ở lỗi đầu tiên, và cloud-init không bao giờ chạy lại. `depends_on` khai báo thứ tự mà Terraform không suy ra được
từ tham chiếu, nên race biến mất.

Gateway cũng có rủi ro tương tự: nó tham chiếu `module.vpc.public_subnets`, giá trị này lấy từ resource
subnet chứ không phải từ route table association của module. Nó xoay xở bằng cách thử lại: mọi bước dùng
mạng trong `wireguard-init.sh` đều đi qua `retry` (10 lần, cách nhau 10 giây), và apt chờ lock tối đa 600
giây. Node không gặp rủi ro này vì chúng không chạy gì lúc boot.

**B3.7** Không. Terraform chỉ biết những gì nằm trong state của nó. Volume do EBS CSI tạo cho PVC (và
snapshot nếu có) là do Kubernetes gọi API AWS, nên không stack nào quản lý chúng.

**Khi `make infra-destroy`:** instance bị xoá, volume của PVC bị tách ra và chuyển sang `available`, rồi
**nằm lại và tiếp tục tính tiền**. Cluster dựng lại không biết gì về chúng. Tệ hơn, EBS CSI không dùng
`default_tags` của Terraform, nên nếu không cấu hình thêm thì các volume đó không có tag `project` và budget
không thấy chúng (xem B8.6).

**Cách xử lý:**

- trước khi destroy, xoá PVC (StorageClass `reclaimPolicy: Delete`) để driver tự xoá volume khi cluster còn
  sống
- cấu hình tag thêm cho volume trong Helm chart của driver (`extraVolumeTags`, ví dụ `project=medical-rag`)
- sau destroy, kiểm tra `aws ec2 describe-volumes --filters Name=status,Values=available`

**Destroy treo ở subnet hoặc security group:** AWS không cho xoá khi còn network interface dùng chúng, và báo
`DependencyViolation`. Nguyên nhân thường là ENI của NLB hay NAT gateway chưa giải phóng xong (tự hết sau vài
phút), hoặc ENI của thứ nằm ngoài state. Tìm bằng
`aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>`.

### B4. Mạng

**B4.1** `cidrsubnet(10.10.0.0/16, 8, n)` cộng thêm 8 bit vào mask và cho ra `10.10.n.0/24`:

- private (node): `10.10.1.0/24`, `10.10.2.0/24`, `10.10.3.0/24`
- public (public NLB, NAT, WireGuard gateway): `10.10.101.0/24`, `10.10.102.0/24`, `10.10.103.0/24`

Internal NLB của API nằm ở subnet private.

**Không được trùng với:**

| Dải | CIDR |
|---|---|
| VPC của ops | `10.20.0.0/24` |
| WireGuard | `10.99.0.0/24` (đang nằm trong dải Service, xem B9.7) |
| Pod của Calico | `192.168.0.0/16` |
| Service của Kubernetes | `10.96.0.0/12` |

Trùng dải làm định tuyến trở nên mơ hồ. Một IP pod trùng IP trong VPC sẽ được giao trong mạng pod thay vì ra
VPC; route `10.10.0.0/16` trên laptop sẽ "nuốt" traffic đáng lẽ đi tới mạng ở nhà. Kiểu lỗi này biểu hiện
thành một số kết nối đi sai chỗ mà không báo lỗi gì, rất khó chẩn đoán. VPC peering và VPN cũng từ chối các
dải trùng nhau.

**B4.2** Nếu account đã opt-in một Local Zone hay Wavelength Zone, `aws_availability_zones` trả về cả
chúng. Chúng có thể không có loại máy cần dùng hoặc không hỗ trợ NLB. `opt-in-not-required` chỉ giữ lại AZ chuẩn, và `slice(..., 0, 3)` lấy ba cái.

`node_count = 4` đặt node 4 vào `private_subnets[3 % 3]`, tức subnet đầu tiên, cạnh node 1. Bốn member etcd
cần 3 để có quorum, nên vẫn chỉ chịu được **một** member lỗi, y như ba member. Hơn nữa, mất AZ đầu tiên giờ
làm mất hai member cùng lúc và mất quorum. Với etcd, số member luôn nên là số lẻ.

**B4.3** Gateway endpoint thêm prefix list của S3 theo region vào các route table **private**. Traffic từ
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

**B4.4** Module đặt NAT gateway duy nhất ở subnet public đầu tiên, và mọi route table private gửi
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

**B4.5** VPC của ops có internet gateway nhưng không có NAT. SSM agent phải tới được các endpoint `ssm`,
`ssmmessages` và `ec2messages`, còn cloud-init phải tới được GitHub, HashiCorp và mirror của apt. Ở subnet
public, muốn vậy thì phải có public IP. Security group không có rule inbound nào, nên IP đó là lối ra chứ
không phải cửa vào.

Bỏ nó đi nghĩa là chuyển sang subnet private, cộng thêm NAT gateway, hoặc interface endpoint cho ba dịch vụ
SSM kèm một proxy cho mọi thứ còn lại. Cả hai đều đắt hơn phí IPv4 public 0.005 USD/giờ.

### B5. Security group

**B5.1** Hai đường, không còn gì khác:

1. **TCP 80 tới public NLB:** `aws_vpc_security_group_ingress_rule.ingress_nlb_http` (`0.0.0.0/0`), rồi
   `nodes_http_from_nlb` tới NodePort 30080.
2. **UDP 51820 tới WireGuard gateway:** `wireguard_udp`.

**Không phải đường vào:**

- Security group của workstation không có rule ingress nào (workstation có public IP, nhưng chỉ để đi ra).
- Node không có public IP.
- Internal NLB chỉ nhận từ `10.10.0.0/16`.
- Module VPC làm rỗng default security group của VPC cluster.

**B5.2** Mọi protocol và port từ bất kỳ network interface nào trong group `nodes` tới interface khác trong
group đó, và chỉ những interface đó. Rule này bao gồm:

- etcd `2379-2380` và API server `6443`
- kubelet `10250`
- Calico VXLAN `UDP 4789` và Typha `5473`
- NodePort giữa các node, và DNS tới CoreDNS trên node khác

Với VXLAN, traffic giữa các pod đi bên trong UDP 4789 giữa các IP node, nên security group chỉ thấy 4789,
không thấy port thật của pod.

**Siết lại:** mỗi port ở trên một rule. Cái giá là công bảo trì: quên một port là có thứ hỏng lặt vặt mà
không báo lỗi, ví dụ `kubectl logs` timeout khi thiếu 10250.

**B5.3**

- **Có ID và mô tả riêng.** Thêm hay bớt một rule không phải viết lại cả group.
- **Rule nằm được ở file khác.** `rancher.tf` thêm rule 443 vào các group định nghĩa trong `security.tf`.
- **Không tạo vòng phụ thuộc.** `nodes` tham chiếu `api_nlb` và `api_nlb` tham chiếu `nodes`. Nếu viết
  inline, mỗi group phụ thuộc vào group kia, và Terraform báo lỗi `Cycle`.

**Trộn cả hai kiểu trên một group:** Terraform coi danh sách inline là toàn bộ rule của group. Mỗi lần apply
nó xoá các rule do resource riêng tạo ra, lần apply sau tạo lại chúng, và plan không bao giờ ổn định.

**B5.4** **Trả lời ngắn:** firewall iptables trên gateway, không phải AWS.

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

**B5.5** Security group chỉ gắn được vào NLB lúc tạo. NLB tạo ra không có security group thì không bao giờ
gắn thêm được, nên cách duy nhất là tạo NLB mới, tức DNS name mới.

Với NLB của API, đổi DNS name kéo theo sinh lại SAN trong certificate của API server, sửa mọi kubeconfig và
ConfigMap `cluster-info`: đau nhưng cứu được. Nếu `controlPlaneEndpoint` là một tên Route 53 ổn định (ví dụ
`api.recruitai.io.vn`) thay vì DNS name thô của NLB, đổi NLB chỉ còn là sửa một record.

Không có security group thì rule của node cũng phải tin theo dải IP thay vì tham chiếu group của NLB.

**B5.6** Security group của NLB có hai chiều với hai việc khác nhau:

- **Inbound** lọc client gọi vào listener.
- **Outbound** phải cho phép cả traffic chuyển tiếp tới target **lẫn health check**, vì health check xuất phát
  từ NLB. Thiếu `api_nlb_to_nodes` thì mọi target unhealthy dù API server vẫn chạy tốt.

Rule của node tham chiếu security group của NLB vẫn có hiệu lực kể cả khi bật client IP preservation, nên
`nodes_http_from_nlb` hoạt động với public NLB giữ IP client.

**Egress tường minh:** AWS tạo mỗi security group mới kèm rule cho ra tất cả, nhưng `aws_security_group` của
Terraform **xoá rule mặc định đó**. Vì vậy mọi egress phải được khai báo: `nodes_all`, `wireguard_all`,
`workstation_all`, và egress của hai NLB. Quên một cái là máy đó không ra được ngoài, ví dụ node không pull
được image.

### B6. Load balancer

**B6.1** Khi bật client IP preservation, internal NLB chuyển tiếp gói tin nguyên vẹn: IP nguồn vẫn là IP của
bên gọi. Khi node 1 gọi NLB và NLB chọn đúng node 1 làm target, node 1 nhận một gói tin có IP nguồn là chính
nó. Nó trả lời trực tiếp, không đi qua NLB, và kết nối không bao giờ hoàn tất. AWS ghi rõ vòng lặp này
(hairpinning) không được hỗ trợ khi bật preservation.

Triệu chứng là khoảng một phần ba lệnh gọi từ node tới API bị timeout, làm hỏng `kubeadm join` và khiến
kubelet chập chờn.

Với `false`, NLB thay IP nguồn bằng IP private của chính nó, nên phản hồi quay về qua NLB. Cái giá là API
server chỉ thấy địa chỉ của NLB, không thấy bên gọi thật.

Target group HTTP public giữ mặc định (bật). Bên gọi của nó đến từ internet, còn node gọi public NLB thì đi
ra qua NAT, nên IP nguồn là IP public của NAT, không bao giờ là IP của node.

**B6.2** Check TCP chỉ chứng minh port đang mở. API server mở 6443 trước khi phục vụ được: trong lúc khởi
động, hoặc khi không kết nối được etcd. `/readyz` chỉ trả 200 khi server thực sự sẵn sàng.

NLB không kiểm tra certificate và không gửi client certificate. Nó vẫn nhận được câu trả lời vì kubeadm để
`--anonymous-auth` bật, và role có sẵn `system:public-info-viewer` cho phép người dùng ẩn danh đọc `/readyz`,
`/livez`, `/healthz` và `/version`.

Tắt anonymous auth sẽ khiến mọi target thành unhealthy. Cách siết an toàn là cấu hình anonymous
authenticator để chỉ cho phép các endpoint health đó.

**B6.3** Không phải lỗi: chưa có API server nào cho tới khi Ansible chạy `kubeadm`.

Khi **mọi** target trong group đều unhealthy, NLB **fail open** và gửi traffic tới tất cả. Trong lúc
`kubeadm init`, chỉ node 1 đang lắng nghe, nên khoảng hai phần ba kết nối qua `controlPlaneEndpoint` rơi vào
node 2, 3 và bị từ chối. kubeadm thử lại. Khi node 1 qua được hai lần check (khoảng 20 giây), NLB gửi tất cả
về nó. Đây là nhiễu tạm thời, có thể đoán trước. Role `kubeadm_init` chờ `/readyz` qua chính NLB (thử lại 30 lần, cách
nhau 10 giây) trước khi join node khác, nên nhiễu này không làm hỏng lần chạy.

**B6.4** Cluster kubeadm không có cloud controller manager, cũng không có AWS Load Balancer Controller, nên
`type: LoadBalancer` sẽ `Pending` mãi. NLB của API cũng phải tồn tại **trước** cluster, vì kubeadm cần DNS
name của nó làm `controlPlaneEndpoint`. Vì vậy Terraform sở hữu các load balancer và tên của chúng;
ingress-nginx lắng nghe trên các NodePort cố định (30080, 30443) mà target group trỏ tới.

**Vì sao dùng target kiểu instance:** Terraform biết instance ID. IP của pod dưới Calico VXLAN không định
tuyến được từ VPC, nên target kiểu IP không tới được pod.

**Cái giá của thiết kế này:** thêm một chặng qua kube-proxy, và số port phải tự tay giữ khớp giữa Terraform
với Helm values.

**B6.5** **Tiết kiệm:** phí theo giờ và capacity unit của một NLB thứ ba.
Internal NLB đã có sẵn và nằm đúng subnet.

**Cái giá:**

- Một security group giờ canh cả hai listener, nên 443 và 6443 chung một mức tin tưởng toàn VPC ở tầng AWS.
- Sửa một listener cũng là sửa load balancer của API.
- `rancher.recruitai.io.vn` công khai địa chỉ private của NLB API.
- Tên `aws_lb.api` không còn đúng nghĩa: nó mang cả traffic của Rancher.

**B6.6** `port` của target group không sửa tại chỗ được, nên plan **thay** `aws_lb_target_group.ingress_https`.
Mặc định Terraform xoá trước rồi mới tạo, mà group đang được listener 443 dùng, nên AWS trả `ResourceInUse` và
apply dừng.

`create_before_destroy` cũng không cứu được, vì `name` cố định sẽ trùng với group cũ còn đang tồn tại. Cách sửa:
đổi sang `name_prefix` kèm `create_before_destroy`, và đổi NodePort trong Helm values của ingress-nginx cùng lúc;
nếu không, target unhealthy dù apply thành công.

### B7. Compute, IAM và instance metadata

**B7.1** Đó là IP hop limit (TTL) của gói phản hồi cho lệnh PUT lấy token IMDSv2. Process chạy trên host cách một
chặng. Container có network namespace riêng cách hai chặng, vì traffic của nó phải qua veth hoặc bridge
trước.

| Máy | Hop limit | Vì sao |
|---|---|---|
| Workstation, gateway | 1 | Chỉ host cần credential, nên container trên đó không lấy được instance role |
| Node | 2 | EBS CSI driver và External Secrets chạy dưới dạng pod và xác thực bằng role của node, vì cluster tự quản lý không có IRSA hay Pod Identity |

**Để 2 thì đánh đổi:** mọi pod tới được IMDS đều lấy được credential của node (xem B7.3). Vì vậy NetworkPolicy
chặn egress tới `169.254.169.254/32` cho mọi namespace của app; chỉ external-secrets, ebs-csi và Jenkins agent
được gọi.

**Giới hạn:** cả hop limit lẫn NetworkPolicy đều không chặn được pod `hostNetwork`. Pod đó dùng network của
host, nên tới IMDS chỉ với một chặng. Muốn chặn phải dùng policy admission (không cho pod thường bật
`hostNetwork`).

**B7.2** `GetAuthorizationToken` là action cấp registry mà IAM không giới hạn theo repository được, nên
resource hợp lệ duy nhất là `"*"`. Token tự nó không cấp quyền gì: mỗi lệnh pull hay push vẫn bị kiểm tra
theo ARN của repository trong `EcrPullPush`. Node vẫn chỉ tới được `medical-rag`.

**B7.3** **Không, thiệt hại lan ra ngoài project.** Inline policy ghi đúng ARN, nhưng hai AWS managed policy
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

**Cái gì hạn chế thiệt hại:**

- NetworkPolicy chặn IMDS cho namespace của app, nên danh sách trên chỉ áp dụng cho pod trong external-secrets,
  ebs-csi, Jenkins agent, hoặc pod `hostNetwork` `[điền: manifest và bằng chứng test]`.
- Kyverno kiểm tra chữ ký image trên prod; một quyền `kms:Sign` bị đánh cắp từ Jenkins agent vẫn vượt qua được.
- **Còn lại:** IRSA tự host, để mỗi workload có role riêng và bỏ được hai managed policy khỏi role dùng chung.
  Tài liệu thiết kế ghi đây là giới hạn đã biết.

**B7.4** Gateway là máy lộ ra ngoài nhiều nhất: có public IP và một port UDP mở. Nếu dùng role của node, bị
chiếm quyền ở đó sẽ lộ tất cả những gì ở B7.3. Role riêng của nó có `AmazonSSMManagedInstanceCore` và một
statement inline: `GetSecretValue` và `DescribeSecret` chỉ trên `medical-rag/wireguard`.

Node không đọc được secret này vì policy của node liệt kê ARN secret tường minh: `llm`, `github`, `rancher`,
`rancher-tls`. Không có wildcard nào bao được `wireguard`. (Shared tạo năm secret; node đọc bốn, gateway đọc
riêng cái thứ năm.)

Lưu ý: `AmazonSSMManagedInstanceCore` vẫn cho gateway đọc mọi SSM parameter trong account, giống node.

**B7.5** `value` của data source `aws_ssm_parameter` luôn bị đánh dấu sensitive, vì parameter có thể là
`SecureString`. Như vậy AMI ID, và mọi giá trị suy ra từ nó, sẽ hiện là `(sensitive value)` trong mọi plan.
`insecure_value` trả về cùng giá trị nhưng không đánh dấu. Parameter AMI của Canonical là thông tin công
khai, nên không lộ gì mà plan vẫn đọc được.

**B7.6** **Giảm `node_count` xuống 2.** `count` xoá **index cao nhất**: `aws_instance.nodes[2]` (node 3)
cùng ba target group attachment của nó (api, ingress_http, ingress_https). Với `count` bạn không xoá riêng node 2 được, vì index sẽ bị dồn
lại. Đó là lập luận kinh điển để dùng `for_each` với key ổn định. Còn 2 member etcd thì quorum là 2, nên cluster
không chịu được thêm member nào lỗi.

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

### B8. Các dịch vụ dùng chung

**B8.1** **Tag immutable.** Tag theo git SHA không bao giờ bị ghi đè, nên image đã được scan và ký chính là
image đang chạy.

**Hai ngoại lệ:**

- `sha256-*`: tag chữ ký kiểu cũ của cosign, bị ghi lại khi thêm chữ ký.
- `buildcache*`: cache của BuildKit, bị ghi lại sau mỗi lần build.

Nếu các tag này cũng immutable thì việc ký và dùng cache sẽ lỗi.

**Lifecycle policy chỉ đếm `tagged`.** Cosign v3 lưu chữ ký và SBOM attestation dưới dạng OCI *referrer*
không có tag của image. Rule đếm `any` hoặc `untagged` sẽ xoá chúng. Image đang chạy mất chữ ký, và lần khởi
động pod tiếp theo sẽ không qua được bước kiểm tra.

**B8.2** Với key bất đối xứng, private key không bao giờ rời KMS: CI gọi `kms:Sign`, còn ai cũng kiểm tra
được bằng public key, vốn không phải bí mật. `SIGN_VERIFY` cũng có nghĩa key không dùng để mã hoá được.

Key nằm ở `shared/` vì chữ ký chỉ kiểm tra được bằng đúng key đã tạo ra nó. Key tạo lại là một cặp key mới,
nên mọi chữ ký hiện có đều không qua được kiểm tra và mọi image phải ký lại. Deletion window 7 ngày cho phép huỷ lệnh
xoá nhầm bằng `cancel-key-deletion`.

**B8.3** Để giá trị không bao giờ lọt vào state hay Git. `aws_secretsmanager_secret_version` với
`secret_string` sẽ lưu plaintext trong state, và giá trị phải đi vào qua một biến: nằm trong file tfvars,
biến môi trường hoặc lịch sử shell.

Terraform 1.11 thêm **write-only argument**: `secret_string_wo` của AWS provider được gửi lên AWS nhưng không
lưu trong state hay plan. Nó cần thêm `secret_string_wo_version` (tăng số này mới đẩy giá trị mới), và giá
trị nên đi vào qua một biến `ephemeral = true`; biến thường vẫn dùng được, nhưng giá trị sẽ nằm trong plan file
nếu plan được lưu lại. Tạo secret rỗng vẫn đơn giản hơn: giá trị được nhập một lần, từ
một file.

**B8.4** Trong chuỗi Terraform, `$${` là escape của `${`. Vì vậy cách viết tự nhiên
`"user:project$${var.project}"` cho ra đúng chữ `user:project${var.project}`, không phải `user:project$medical-rag`.
Muốn có `$` ngay trước một phép nội suy thì phải viết `"user:project${"$"}${var.project}"`, hoặc dùng
`format("user:project$%s", var.project)`, dễ đọc hơn.

**Trước khi budget đếm được gì:**

- **Kích hoạt tag.** Trong Billing, mục *Cost allocation tags*, kích hoạt `project` làm tag do người dùng
  định nghĩa. Tag xuất hiện tối đa 24 giờ sau khi resource có tag đầu tiên được tạo.
- **Account trong Organization.** Chỉ management account kích hoạt được.
- **Không tính ngược.** Chi phí trước lúc kích hoạt không được gán tag.
- **Độ trễ.** Budget cập nhật vài lần mỗi ngày, nên cảnh báo luôn chậm hơn chi phí thực.

**B8.5** **Không phải drift theo nghĩa của Terraform.** `aws_route53_zone` chỉ quản lý zone, không quản lý
record bên trong. Record không được khai báo ở đâu thì không nằm trong state nào, nên `plan` không bao giờ
nhắc tới chúng, dù bị sửa hay bị xoá.

**Vì sao để tay:** CNAME xác minh chỉ dùng khi đặt hoặc gia hạn certificate, giá trị do Sectigo cấp lúc đặt
hàng; các record chép sang là việc làm một lần khi chuyển DNS.

**Cái giá:** chúng không được review, không tái tạo được nếu zone mất, và không ai biết chúng tồn tại nếu
không mở console. Cách chặt hơn là khai báo `aws_route53_record` trong `shared/`, với giá trị qua biến (không
phải bí mật). Một tác dụng phụ đáng giá của việc để chúng trong zone: chúng làm lệnh xoá zone lỗi
`HostedZoneNotEmpty` (B3.2).

**B8.6** `default_tags` gắn `project`, `owner`, `stack`, `managed-by` (và `env` ở shared, cluster) lên mọi
resource **mà provider đó tạo** và có hỗ trợ tag. Tag khai báo ở resource được gộp vào, trùng key thì tag của
resource thắng.

**Vẫn lọt khỏi budget:**

- **Thứ Terraform không tạo:** volume và snapshot do EBS CSI tạo (B3.7).
- **Root volume của instance:** kiểm tra volume gốc có mang tag `project` không, bằng
  `aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=<id>` `[điền: kết quả]`.
- **Khoản phí không gắn với resource có tag:** thuế, support, một phần phí truyền dữ liệu.
- **Chi phí trước khi kích hoạt tag.**

**Kiểm tra thay vì đoán:** `aws resourcegroupstaggingapi get-resources --tag-filters
Key=project,Values=medical-rag` để xem cái gì có tag, và trong Cost Explorer nhóm theo tag `project` để xem
dòng *No tag key* còn bao nhiêu.

### B9. WireGuard và DNS

**B9.1** `templatefile` thay các phép nội suy `${...}` (và directive `%{...}`) bằng map truyền vào trong
`wireguard.tf`:

- `region`, `secret_id`
- `server_address`, `peer_address`
- `wireguard_cidr`, `vpc_cidr`, `vpc_resolver`

`$PRIVATE_KEY` không có ngoặc nhọn thì không phải cú pháp template, nên tới máy nguyên như đã viết. Bash mở
rộng nó lúc chạy; heredoc không có nháy `<<EOF` sau đó ghi key thật vào `wg0.conf`.

`${PRIVATE_KEY}` sẽ làm plan lỗi với *vars map does not contain key "PRIVATE_KEY"*. Biến bash nào cần ngoặc
nhọn thì phải viết `$${PRIVATE_KEY}`.

**B9.2** User data không phải chỗ cất bí mật:

- Ai có `ec2:DescribeInstanceAttribute` cũng đọc được.
- Bất kỳ process nào trên máy cũng lấy được qua IMDS.
- Terraform lưu nó nguyên văn trong state (B1.6) và hiện nó trong plan.
- Key truyền qua template trước hết phải là một biến Terraform, nên cũng sẽ nằm trong file tfvars hoặc
  lịch sử shell.

Lấy lúc boot thì key chỉ tồn tại trong Secrets Manager (mọi lần đọc được CloudTrail ghi lại, chỉ role của
gateway đọc được) và trong `/etc/wireguard/wg0.conf` với quyền 600. Gateway dựng lại lấy đúng key cũ, nên
profile trên laptop không bao giờ phải đổi.

**B9.3** Source/destination check huỷ gói tin có IP nguồn hoặc đích không phải địa chỉ của chính instance.
Mọi gói tin trên network card của gateway đều dùng địa chỉ của chính nó:

- **Gói tin tunnel** tới dưới dạng UDP gửi đến gateway.
- **Traffic đã giải mã** đi ra sau MASQUERADE với IP nguồn là địa chỉ VPC của gateway.
- **Phản hồi** quay về đúng địa chỉ đó; conntrack đảo ngược NAT, mã hoá lại và gửi đi dưới dạng UDP từ
  gateway.

Chỉ phải tắt check này nếu VPC định tuyến `10.99.0.0/24` tới gateway mà không NAT, để cluster thấy được địa
chỉ của laptop.

**B9.4** `associate_public_ip_address = true` cho cloud-init có internet ngay lập tức. Khi `aws_eip` được gắn
vào, địa chỉ public đổi, và mọi kết nối TCP đang mở lúc đó bị đứt: một lượt tải của `apt`, file zip AWS CLI,
lệnh gọi Secrets Manager.

Script bọc mọi bước dùng mạng trong `retry` (10 lần, cách nhau 10 giây), và apt chờ lock dpkg tối đa 600
giây. Bước kiểm tra key `jq -e '.serverPrivateKey and .operatorPublicKey'` cố tình không thử lại: thiếu key
không phải lỗi tạm thời, và script nên dừng với `status: error`.

**B9.5** Địa chỉ **private** của internal NLB, mỗi AZ một `10.10.x.x`. Chúng không định tuyến được trên
internet, nên câu trả lời vô dụng nếu không có đường vào VPC. Nó chỉ để lộ cách đánh địa chỉ của VPC.

**Đổi lại được:**

- Một tên dùng chung cho laptop qua WireGuard và cho agent của Rancher bên trong VPC.
- Certificate công khai khớp đúng tên đó.
- Không cần private hosted zone hay rule cho resolver.

**B9.6** Trong mọi VPC, DNS resolver do Amazon cung cấp nằm ở địa chỉ gốc của VPC cộng hai: `10.10.0.2` với
`10.10.0.0/16`. Từ trong VPC nó cũng trả lời ở `169.254.169.253`.

Vì sao laptop dùng nó: đây là lập luận thiết kế chứ không phải sự cố đã gặp. Nhiều router gia đình và một số
nhà mạng bật **chống DNS rebinding**: họ bỏ các câu trả lời public trỏ tới địa chỉ private như `10.10.x.x`,
nên `rancher.recruitai.io.vn` có thể không phân giải được. `10.10.0.2` nằm trong `AllowedIPs`, và gateway
chuyển tiếp port 53 tới nó, nên truy vấn đi trong tunnel và nhận câu trả lời sạch.

**Đánh đổi:** khi tunnel bật, toàn bộ DNS của laptop đi qua tunnel. Nếu gateway chết, duyệt web bị treo cho
tới khi tắt tunnel.

**B9.7** Không khớp: **mô tả đúng, giá trị mặc định vi phạm nó.** `10.96.0.0/12` trải từ `10.96.0.0` tới
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

**B9.8** Một request, `https://rancher.recruitai.io.vn`:

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

**B9.9** **Chain riêng** gom mọi rule lọc traffic từ tunnel vào một chỗ, nên PostDown dọn sạch bằng `-F` và
`-X` mà không đụng rule khác trên máy.

**Thứ tự ngược:** không xoá được chain khi còn rule trong `FORWARD` nhảy tới nó, nên phải gỡ `-j WG_FWD` trước,
rồi mới flush và xoá chain.

**`Chain already exists`:** `iptables -N WG_FWD` lỗi nếu chain đã có. Nếu một lần PostUp dừng giữa chừng, chain
còn lại mà PostDown không chạy, nên lần start sau lỗi ngay ở dòng đầu. Cách gỡ trong guide: xoá rule nhảy, flush,
xoá chain, rồi restart `wg-quick@wg0`.

**B9.10** **Plan:** thuộc tính này không sửa tại chỗ được, nên gateway bị **thay**. Elastic IP chuyển sang máy
mới, nên `vpn.recruitai.io.vn` vẫn đúng.

**Boot:** subnet public của module đặt `map_public_ip_on_launch = false`, nên máy mới không có địa chỉ public và
không ra được internet cho tới khi EIP được gắn, vài giây sau. Các bước dùng mạng trong `wireguard-init.sh` đều
đi qua `retry` (10 lần, cách nhau 10 giây), nên nhiều khả năng vẫn qua, chỉ tốn vài lượt thử.

Đánh đổi ngược lại là lý do dòng đó tồn tại: có IP tạm thì cloud-init chạy ngay, nhưng kết nối đang mở bị đứt
lúc đổi sang EIP (B9.4).
