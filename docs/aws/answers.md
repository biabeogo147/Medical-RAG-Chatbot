# Đáp án AWS

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Phần A mở đầu bằng **Ý chính**: câu nói thành tiếng, ngôi thứ
nhất, thường là đủ. *Nếu được hỏi thêm* dùng khi người phỏng vấn đào sâu; tham chiếu trong đó là để bạn tra, không đọc ra.
Tham chiếu dạng `Terraform A1.1` trỏ tới [`../terraform/answers.md`](../terraform/answers.md), `Ansible …` và `Common …`
tương tự.

Các đáp án mô tả project **khi đã hoàn thành** theo [thiết kế](../selfmanaged-k8s-ops-design.md). Chỗ `[điền: …]` là số
liệu hay kiểm tra phải lấy từ lần chạy thật. Ghi chú **[kiểm chứng]** là chi tiết về giá, giới hạn hay hành vi của AWS có thể
đổi theo thời gian; kiểm tra tài liệu trước khi nói chắc.

**Cần xác nhận trước khi dùng:**

- Budget có thật sự báo khi account còn credit không: `shared/bugdets.tf` không đặt `cost_types`, và nếu budget tính cả
  credit thì chi phí ròng gần bằng 0 và cảnh báo không bao giờ bắn (A5.2, B6.2).
- Ngày kết thúc Free plan, khác với ngày hết hạn credit (B6.1).

---

## Phần A — Phỏng vấn

### A1. Cloud và on-premises

**A1.1** **Ý chính:** "Nguyên tắc của tôi: tự vận hành Kubernetes, vì đó là thứ project muốn chứng minh; còn những gì có trạng
thái hay là bí mật và phải giữ lại khi xoá cluster thì để dịch vụ managed: S3, ECR, KMS, Secrets Manager, Route 53. Cluster
chạy trên EC2 trải ba AZ sau NLB, quyền đi qua IAM role, và người vận hành vào máy bằng Session Manager."

*Nếu được hỏi thêm:* khoảng 0.53 USD/giờ khi cluster chạy; khi xoá, phần giữ lại khoảng 9 USD/tháng.

**A1.2** **Ý chính:** "AWS lo phần cứng, datacenter, mạng vật lý, hypervisor, và bản thân các dịch vụ managed như S3, KMS, NLB.
Phần từ hệ điều hành trở lên là của tôi: vá Ubuntu, Kubernetes, etcd, mạng trong VPC, security group, IAM và dữ liệu.
On-premises thì cả phần của AWS cũng là của mình, kể cả điện, làm mát và thay ổ hỏng."

*Nếu được hỏi thêm:* với EC2, ranh giới nằm ở hypervisor; với S3 hay KMS, AWS lo gần hết và tôi chỉ lo quyền và cấu hình. Chọn
tự dựng Kubernetes trên EC2 nghĩa là tôi nhận phần trách nhiệm lớn hơn so với EKS. Mô hình này cũng không che được dữ liệu gửi
ra ngoài AWS, như câu hỏi đi tới Gemini (A6.4).

**A1.3** **Ý chính:** "Dịch vụ nào cũng có tương đương, nhưng mỗi cái là một hệ thống phải tự vận hành và làm HA: load balancer
thành HAProxy với keepalived, KMS và Secrets Manager thành Vault, S3 thành MinIO hoặc Ceph, ECR thành Harbor, Session Manager
thành bastion hoặc Teleport."

*Nếu được hỏi thêm:*

| AWS | On-premises |
|---|---|
| VPC, subnet, route table | VLAN, subnet, router |
| Security group | Distributed firewall (ví dụ NSX), host firewall, microsegmentation |
| NAT gateway | NAT trên firewall biên |
| NLB | HAProxy + keepalived, kube-vip, hoặc F5; MetalLB cho Service |
| EC2 | VM trên VMware, Proxmox, OpenStack, hoặc bare metal |
| EBS + EBS CSI | LUN trên SAN, Ceph RBD, Longhorn + CSI tương ứng |
| S3 | MinIO, Ceph RGW |
| ECR | Harbor |
| KMS | HSM, hoặc Vault Transit |
| Secrets Manager | Vault |
| IAM role, instance profile | Vault với xác thực theo máy, chứng chỉ máy, SPIFFE |
| Session Manager | Bastion SSH, Teleport, Boundary |
| Route 53 | BIND, PowerDNS |
| CloudTrail | Audit log của vCenter, AD, gom về SIEM |

**A1.4** **Ý chính:** "Dễ hơn: máy, load balancer và mạng tạo bằng code trong vài phút, xoá được, và không còn IP cố định nào
phải ghi tay. Khó hơn: danh tính và quyền. Ở một mạng phẳng kiểu cũ, máy trong mạng nội bộ thường được tin; trên AWS mọi lời gọi
đều qua IAM, và tôi phải hiểu instance profile, metadata service, policy của bucket và của key."

*Nếu được hỏi thêm:* các vấn đề chỉ có trên cloud mà tôi gặp thật: Free plan chặn loại máy (Terraform A7.1), SSM agent không lấy
được credential lúc boot (Ansible A4.4), và chi phí tính theo giờ khiến mọi thiết kế phải xoá được.

**A1.5** **Ý chính:** "Lý do thực tế: account AWS có credit Free plan, và AWS là cloud xuất hiện nhiều nhất trong tin tuyển DevOps
tôi nhắm tới. Về kỹ thuật, kiến trúc này dựng được trên cloud nào cũng được; phần Kubernetes, Ansible và GitOps gần như giữ
nguyên."

> **Mẹo:** đừng bịa lý do kỹ thuật cho một lựa chọn thực chất là chi phí và thị trường.

**A1.6** **Ý chính:** "Nếu ở công ty, mặc định tôi chọn managed: một app web như thế này chạy trên ECS Fargate là ít công vận
hành nhất, còn khi đã có nhiều workload Kubernetes thì EKS. Tự dựng trên EC2 khi cần kiểm soát thứ EKS không cho, hoặc để giống
một môi trường on-premises. On-premises đúng khi dữ liệu bắt buộc nằm tại chỗ, tải ổn định và lớn tới mức phần cứng rẻ hơn, hoặc
đã có sẵn datacenter."

*Nếu được hỏi thêm:*

- Project này tự dựng vì mục tiêu là chứng minh kỹ năng vận hành control plane; project thứ hai của tôi dùng EKS.
- Nếu app cần database, tôi dùng RDS Multi-AZ thay vì tự chạy database trên EBS.
- Loại máy ở đây chạy chung phần cứng với khách hàng khác; cần cách ly phần cứng vì license hay tuân thủ thì có Dedicated
  Instance hoặc Dedicated Host.

### A2. Mạng

**A2.1** **Ý chính:** "VPC giống mạng riêng của mình trong datacenter, subnet giống VLAN, route table giống router. Một
Availability Zone là một hoặc nhiều datacenter có điện và mạng riêng, cách biệt vật lý với các AZ khác trong cùng region. Tôi trải
ba AZ để mất một AZ vẫn còn hai node và etcd vẫn đủ quorum."

*Nếu được hỏi thêm:* mỗi subnet chỉ nằm trong một AZ. Ba subnet private cho node và internal NLB, ba subnet public cho public NLB,
NAT gateway và WireGuard gateway. Độ trễ giữa các AZ đủ thấp cho etcd theo khuyến nghị chung
`[điền: etcd_network_peer_round_trip_time_seconds thật]`.

**A2.2** **Ý chính:** "Route table của subnet private gửi mọi traffic ra internet tới NAT gateway ở subnet public, và NAT gateway đi
ra bằng một Elastic IP. Khác NAT trên firewall on-premises: nó là dịch vụ managed, tự mở rộng, nhưng tính tiền theo giờ và theo
từng GB đi qua."

*Nếu được hỏi thêm:*

- NAT gateway kiểu thông thường nằm trong một AZ; project chỉ dùng một cái để tiết kiệm, nên nó là điểm lỗi đơn cho traffic đi
  ra (A5.5). AWS đã có chế độ NAT gateway theo region, trải qua nhiều AZ **[kiểm chứng]**.
- Traffic tới S3 trong region đi qua gateway endpoint miễn phí, không qua NAT (B1.4).
- NAT instance tự dựng rẻ hơn nhưng là một máy phải vá và tự làm HA.

**A2.3** **Ý chính:** "Security group là firewall stateful gắn vào từng network interface, không gắn ở biên mạng. Nó chỉ có luật cho
phép, và luật có thể tham chiếu một security group khác thay vì dải IP, nên 'cho load balancer gọi node' không phụ thuộc IP nào cả."

*Nếu được hỏi thêm:*

- Tương đương gần nhất on-premises là distributed firewall: lọc ngay tại máy, kể cả giữa hai máy cùng subnet.
- Network ACL là lớp stateless ở mức subnet; project để mặc định và dựa vào security group (B1.2).
- Tham chiếu security group là lý do thay một node, node nhận IP mới, mà không phải sửa rule nào. Ngoại lệ: internal NLB đang tin
  cả CIDR của VPC (Terraform A1.1).

**A2.4** **Ý chính:** "On-premises, keepalived giữ một VIP bằng VRRP và gratuitous ARP, còn HAProxy phía sau chia tải. VPC không có
multicast hay gratuitous ARP giữa các máy, nên VIP không tự trôi được; muốn chuyển IP phải gọi API AWS. NLB thay cả hai lớp đó:
managed, health check `/readyz` từng API server, đổi lại tính tiền theo giờ và phải xử lý hairpin."

*Nếu được hỏi thêm:*

- keepalived chạy kiểu unicast vẫn bầu được master trên AWS, kèm script gọi API gán lại IP phụ hoặc Elastic IP.
- Hairpin: node gọi NLB mà rơi vào chính nó; xử lý bằng tắt client IP preservation trên target group (Terraform B6.1).
- On-premises, kube-vip còn làm được việc của MetalLB cho Service `LoadBalancer`.

**A2.5** **Ý chính:** "Cloud controller manager là thứ nối Kubernetes với AWS. Không cài nó, Service kiểu `LoadBalancer` không bao giờ
tạo được load balancer, nên NLB phải tạo sẵn bằng Terraform. Node cũng không tự có nhãn zone hay provider ID, và khi một instance bị
terminate, object Node không tự bị xoá."

*Nếu được hỏi thêm:*

- Project bù: NLB và NodePort cố định do Terraform quản lý; xoá object Node bằng tay khi thay node (Ansible A3.1).
- EBS CSI driver tự gắn nhãn topology của nó, nên volume được tạo đúng AZ của pod khi StorageClass dùng
  `volumeBindingMode: WaitForFirstConsumer`.
- Cài cloud-provider-aws cần kubelet `--cloud-provider=external`, tag cho tài nguyên, thêm quyền IAM, và tên node khớp với cách
  controller nhận diện instance **[kiểm chứng]**; nên tôi không cài.

**A2.6** **Ý chính:** "Hai lý do. VPC không có route nào tới dải pod `192.168.0.0/16`, và network interface mặc định bỏ gói tin có
IP nguồn không phải của nó. Vì vậy Calico bọc gói tin giữa các node trong VXLAN với IP của node. VPC CNI thì cấp cho pod IP thật trong
subnet, gắn vào network interface của node, nên pod định tuyến được trực tiếp; nó cài được cả trên cluster kubeadm, không riêng
EKS."

*Nếu được hỏi thêm:*

- **Cái giá của VPC CNI:** số pod mỗi node bị giới hạn theo số network interface và số IP mỗi interface **[kiểm chứng: loại large
  thường khoảng 3 interface × 10 IP, tối đa khoảng 29 pod]**; prefix delegation nới giới hạn nhưng tốn IP subnet; cần quyền IAM
  quản lý network interface trên role vốn dùng chung.
- **Hệ quả của overlay ở đây:** NLB phải dùng target kiểu instance và NodePort, không trỏ thẳng vào pod được; VXLAN tốn 50 byte
  MTU.

**A2.7** **Ý chính:** "Trên AWS, dữ liệu đi ra internet, đi qua NAT gateway, và phần lớn traffic giữa các AZ đều tính tiền theo GB,
nên thiết kế mạng cũng là thiết kế chi phí. On-premises, băng thông nội bộ gần như miễn phí; cái bạn trả là đường truyền ra ngoài
theo hợp đồng."

*Nếu được hỏi thêm:*

- S3 gateway endpoint để image layer và backup không đi qua NAT (B1.4).
- Chỉ có một NAT ở AZ đầu tiên, nên node ở hai AZ kia trả thêm phí liên AZ cho mọi traffic ra internet (B1.3).
- Cross-zone load balancing trên NLB và traffic etcd, VXLAN giữa các AZ cũng là traffic liên AZ; nhỏ, nhưng không miễn phí
  **[kiểm chứng: luồng nào được miễn]**.

**A2.8** **Ý chính:** "Với kubectl, tôi không cần VPN: SSM port-forward từ workstation tới NLB nội bộ là đủ. WireGuard là cho giao
diện Rancher trên trình duyệt, cần tên thật và certificate khớp. Client VPN làm được việc đó với SAML và MFA, nhưng tính tiền theo
giờ cho mỗi subnet và mỗi kết nối. Site-to-site VPN và Direct Connect là để nối cả một mạng văn phòng hay datacenter, không phải cho
một người."

*Nếu được hỏi thêm:* on-premises, tương đương là VPN của firewall biên. Ở công ty tôi sẽ chọn truy cập qua hệ thống định danh có MFA
(Common A10.6). Vì sao không dùng SSM port-forward cho Rancher: Terraform A1.9.

**A2.9** **Ý chính:** "Domain được delegate từ registrar sang một public hosted zone trên Route 53. Rancher có record public trỏ tới IP
private của NLB nội bộ: phân giải được ở mọi nơi, nhưng chỉ ai có đường vào VPC mới kết nối được. Split-horizon đúng nghĩa trên AWS là
private hosted zone; tôi chọn record public vì đơn giản, và chấp nhận lộ dải IP nội bộ."

*Nếu được hỏi thêm:*

- Split-horizon on-premises trả IP khác nhau cho người bên trong và bên ngoài.
- Private hosted zone gắn vào VPC vẫn hoạt động với laptop, vì laptop dùng resolver của VPC qua tunnel; certificate cũng chỉ cần
  CNAME xác minh ở zone public. Không dùng nó chỉ vì thêm một zone phải gắn và gỡ theo VPC bị xoá hằng ngày (Terraform B9.5).
- Record alias trả thẳng record A, và truy vấn alias tới ELB không tính phí (B5.1).

### A3. Danh tính và bảo mật

**A3.1** **Ý chính:** "Từ IAM role gắn vào instance. Metadata service trên máy cấp credential tạm thời, AWS tự thay trước khi hết
hạn, và SDK tự lấy, nên không có key nào để lưu, rotate hay lọt vào Git. On-premises không có sẵn cơ chế này; thường phải dùng Vault
với xác thực theo máy, hoặc chứng chỉ máy."

*Nếu được hỏi thêm:*

- CloudShell dùng phiên đăng nhập console; workstation, node và WireGuard gateway mỗi loại một role.
- Máy on-premises cần gọi AWS thì có IAM Roles Anywhere, dùng chứng chỉ X.509 để đổi lấy credential tạm thời.
- Credential của instance role mang theo thông tin VPC và IP nguồn; policy có thể `Deny` khi credential bị dùng từ ngoài VPC
  **[kiểm chứng: condition key aws:EC2InstanceSourceVPC]**.

**A3.2** **Ý chính:** "IMDSv2 bắt mọi lời gọi metadata phải lấy token bằng một request `PUT` trước, nên một lỗi SSRF chỉ bắt ứng dụng
gọi `GET` không lấy được credential. Hop limit của phản hồi token để 1 thì chỉ process trên chính host nhận được. Node để 2 vì các
pod nền tảng (EBS CSI, External Secrets, cert-manager, Kyverno, CronJob snapshot etcd) cần role của node."

*Nếu được hỏi thêm:*

- 1 là mặc định của API; một số AMI mới mặc định 2 **[kiểm chứng]**.
- Cái giá: mọi pod tới được metadata service đều dùng được role của node. Bốn namespace chặn nó bằng NetworkPolicy: dev, prod,
  `jenkins` và `jenkins-agents`. Pod app, Job build index và Jenkins build pod có role riêng qua IRSA tự host; controller Jenkins
  thì không cần role AWS nào. Không chặn namespace nền tảng, không chặn pod
  `hostNetwork` (Common B5.3).

**A3.3** **Ý chính:** "Node không có cổng inbound nào, không có key SSH để mất hay rotate, và IAM quyết định ai được mở session. Mỗi lần
mở session là một sự kiện trong CloudTrail. So với bastion on-premises, không còn một máy SSH public phải vá; máy public duy nhất của
project là WireGuard gateway, và nó chỉ mở UDP."

*Nếu được hỏi thêm:*

- Nội dung session có thể ghi ra S3 hoặc CloudWatch; project không bật.
- Agent phải tới được endpoint của SSM, nên node cần NAT hoặc interface endpoint.
- Sự cố thật: agent của node 2 không lấy được credential lúc boot (Ansible A4.4).

**A3.4** **Ý chính:** "Private key nằm trong KMS và không bao giờ ra ngoài: cosign gửi hash của payload chữ ký, trong đó có digest
của image, lên KMS, và KMS trả chữ ký. Không có file key nào trong Jenkins để bị đánh cắp, và mọi lần ký đều có trong CloudTrail."

*Nếu được hỏi thêm:*

- KMS dùng HSM đạt chuẩn FIPS nhưng dùng chung giữa nhiều khách hàng; cần HSM riêng thì có CloudHSM. On-premises tương đương là HSM
  thật hoặc Vault Transit.
- Ai có `kms:Sign` trên key đều ký được, nên chữ ký chứng minh "được ký bằng key này", không chứng minh "đã qua pipeline" (Common
  A6.2).
- Key bất đối xứng không tự rotate; tạo key mới thì phải giữ public key cũ hoặc ký lại image (B4.5).

**A3.5** **Ý chính:** "Secret phải sống lâu hơn cluster, vì cluster bị xoá hằng ngày. Secrets Manager giữ chúng lâu dài, có version và
kiểm soát bằng IAM; External Secrets đồng bộ vào cluster. Vault làm được nhiều hơn, nhưng là một hệ thống HA phải tự vận hành. Điểm yếu
tôi phải nói: vào tới cluster, secret nằm trong etcd chưa mã hoá, và trong snapshot etcd trên S3."

*Nếu được hỏi thêm:*

- Chi phí khoảng 0.40 USD mỗi secret mỗi tháng **[kiểm chứng]**.
- Parameter Store `SecureString` rẻ hơn nhưng không có recovery window và giới hạn kích thước nhỏ hơn (B4.6).
- On-premises tôi dùng Vault; External Secrets giữ nguyên, chỉ đổi backend.
- Cách sửa phần etcd: A3.9.

**A3.6** **Ý chính:** "EKS cho mỗi service account một IAM role riêng. Cluster tự dựng không có sẵn, nên tôi tự dựng IRSA: app ở
dev và prod, Job build index và Jenkins build pod đều có role riêng, và namespace của chúng chặn metadata service. Còn lại là pod
nền tảng, vẫn dùng chung role của node; role đó đã mất quyền ký KMS, quyền push ECR và bucket artifacts."

*Nếu được hỏi thêm:* IRSA tự dựng ở đây gồm: API server phát token service account với issuer là một URL công khai, ký bằng một key
cố định giữ trong Secrets Manager để sống qua rebuild; tài liệu OIDC discovery và public key trên S3; một IAM OIDC identity provider
trỏ tới URL đó (`infra/terraform/shared/oidc.tf`, `irsa.tf`). Không cài pod-identity-webhook: chart tự mount token projected và đặt
biến môi trường. Sau mỗi rebuild, `make oidc-check` so key đang ký với key đã công bố.

**A3.7** **Ý chính:** "CloudTrail ghi mọi lời gọi API quản lý, và lịch sử 90 ngày xem được miễn phí. Nhưng tôi phải nói thẳng: lệnh
chạy trên workstation hiện ra dưới tên role admin dùng chung của máy, và mọi người vào máy đều là `ssm-user`. Khi hai người cùng mở
session, tôi không phân biệt được ai gõ lệnh nào."

*Nếu được hỏi thêm:*

- Cách sửa: mỗi người assume một role riêng kèm source identity, và bật ghi log nội dung session.
- Event history chỉ có management event; ai đọc object S3 thì không được ghi nếu không có trail cho data event.
- Lưu lâu hơn cần trail vào S3; phát hiện bất thường cần GuardDuty; theo dõi cấu hình cần AWS Config. Project không bật (B6.5).

**A3.8** **Ý chính:** "Mặc định là từ chối. Một `Deny` tường minh ở bất kỳ đâu thắng tất cả. Sau đó request phải được SCP của
Organization, permission boundary và session policy cho phép, rồi được identity policy hoặc resource policy cấp quyền. Project chỉ
dùng identity policy và bucket policy; boundary và SCP là thứ tôi sẽ thêm khi có nhiều người."

*Nếu được hỏi thêm:*

- **Ví dụ trong project:** bucket policy `Deny` request không dùng TLS thắng `Allow` của role node (B4.2).
- **Permission boundary:** cho phép người khác tạo role mà không tự nâng quyền được, vì role tạo ra không vượt quá boundary; đi cùng
  giới hạn `iam:PassRole` (Terraform A4.6).
- **Cross-account:** CI ở account build push sang ECR của account prod bằng cách assume một role có trust policy trỏ tới account
  build; bên thứ ba thì thêm `sts:ExternalId` để chống confused deputy.
- **Hai điểm yếu tự nói trước:** workstation có `AdministratorAccess`, và pod nền tảng vẫn dùng chung role của node.

**A3.9** **Ý chính:** "Mọi thứ đều được mã hoá at-rest bằng key do AWS quản lý: S3 dùng SSE-S3, EBS dùng key mặc định, ECR và Secrets
Manager cũng vậy. KMS key tự quản lý duy nhất là key ký image. Chỗ không được mã hoá là Kubernetes Secret trong etcd, và vì vậy cả
snapshot etcd."

*Nếu được hỏi thêm:*

- **Envelope encryption:** KMS sinh một data key, dữ liệu được mã hoá bằng data key, và data key được mã hoá bằng key trong KMS; dữ
  liệu lớn không bao giờ phải gửi lên KMS.
- **Customer managed key đáng tiền khi:** cần key policy tách quyền, ví dụ admin S3 vẫn không đọc được backup; cần audit từng lần
  giải mã; cần chia sẻ sang account khác; hoặc cần xoá key để huỷ dữ liệu. Giá khoảng 1 USD mỗi key mỗi tháng cộng phí request
  **[kiểm chứng]**.
- **Sửa phần etcd:** `EncryptionConfiguration` cho API server với provider KMS v2, và mã hoá bucket backup bằng customer managed key
  mà role của node không giải mã được.

### A4. Compute và lưu trữ

**A4.1** **Ý chính:** "Ràng buộc cứng nhất là Free plan chỉ cho chạy loại máy đủ điều kiện; trong số đó tôi cần 2 vCPU và 8 GB cho mỗi
node, và loại máy phải có ở cả ba AZ. On-premises, bạn mua phần cứng theo dự báo cho vài năm; trên AWS, đổi loại máy chỉ là sửa một
biến và thay máy."

*Nếu được hỏi thêm:* `m7i-flex.large` chạy ở mức CPU nền khoảng 40% và được vượt lên, nhưng không có metric CPU credit như dòng T,
nên cảnh báo phải dựa vào mức dùng CPU và CPU steal (B3.6, Terraform A5.4).

**A4.2** **Ý chính:** "EBS là ổ mạng, được nhân bản trong một AZ, sống độc lập với máy và có snapshot, giống một LUN trên SAN của một
datacenter: muốn sang AZ hay site khác thì phải snapshot hoặc replicate. gp3 cho IOPS nền cố định nên etcd không bị tụt khi hết burst.
Đổi lại, nó có độ trễ mạng mà ổ local không có."

*Nếu được hỏi thêm:*

- Volume EBS chỉ gắn vào máy cùng AZ, nên pod có PersistentVolume không dời sang AZ khác được.
- Ổ gốc bị xoá cùng instance; volume do EBS CSI tạo thì không, và bị bỏ lại nếu xoá cluster mà không xoá PVC trước (Common B6.1).
- etcd dùng chung ổ gốc với image và log; ở production tôi tách ổ riêng cho etcd, và đo độ trễ fsync thay vì chỉ nhìn IOPS.

**A4.3** **Ý chính:** "S3 giữ state của Terraform, FAISS index theo version, snapshot etcd, và file truyền của Ansible. Nó bền, không
phải vận hành, có versioning và lifecycle, và đọc được ngay thứ vừa ghi. NFS là một máy chủ phải vận hành và làm HA; MinIO là lựa chọn
đúng ở on-premises, và vì MinIO nói giao thức S3, app đổi được sang nó bằng cấu hình endpoint."

*Nếu được hỏi thêm:* app đọc index qua `INDEX_STORE`, hỗ trợ `file://` và `s3://`; trỏ sang MinIO bằng biến endpoint của SDK AWS
**[kiểm chứng]**. S3 còn có conditional write, thứ giúp Terraform khoá state mà không cần DynamoDB (B4.7).

**A4.4** **Ý chính:** "ECR nằm cùng region và cùng IAM: node pull bằng role của chính nó qua credential provider, Jenkins push cũng
bằng role, và token đăng nhập 12 giờ được lấy lúc cần, không có mật khẩu registry nào lưu sẵn. ECR còn quét image khi push và hỗ trợ tag
immutable. Harbor là lựa chọn đúng ở on-premises nhưng phải tự vận hành."

*Nếu được hỏi thêm:*

- Layer của image được phục vụ từ S3, nên đi qua gateway endpoint.
- Image nền và image của addon vẫn kéo từ Docker Hub và các registry công khai qua NAT, nên vẫn có thể chạm giới hạn tốc độ của Docker
  Hub; pull-through cache của ECR là cách xử lý.

**A4.5** **Ý chính:** "Trên AWS, máy là thứ thay được bất cứ lúc nào: Terraform thay máy trong vài phút, và mọi cấu hình quan trọng nằm
ở code. Máy vật lý thì phải sửa hoặc chờ phần cứng. Nhưng phải biết rõ hành động nào giữ gì: reboot và stop rồi start giữ ổ EBS và IP
private, còn terminate thì mất ổ gốc lẫn máy."

*Nếu được hỏi thêm:*

| | Reboot | Stop rồi start | Terminate |
|---|---|---|---|
| Ổ EBS gốc | Giữ | Giữ | Xoá (mặc định) |
| IP private chính | Giữ | Giữ | Mất |
| IP public tự cấp | Giữ | Đổi | Mất |
| Elastic IP | Giữ | Giữ | Bị gỡ khỏi máy, vẫn thuộc account và vẫn tính phí tới khi release |
| Host vật lý bên dưới | Giữ | Thường đổi | — |

Vì vậy bài drill HA stop rồi start node 2, và node tự về `Ready` mà không chạy playbook, vì dữ liệu etcd nằm trên ổ gốc được giữ
(Ansible B10.2); bảng member etcd sau drill: `[điền]`.

### A5. Chi phí, giới hạn và rủi ro

**A5.1** **Ý chính:** "Cluster tốn khoảng 0.53 USD mỗi giờ khi chạy; khi xoá chỉ còn khoảng 9 USD mỗi tháng cho phần giữ lại.
On-premises, phần cứng đã mua thì tắt đi cũng không lấy lại tiền. Đổi lại, mọi thứ phải dựng lại được nhanh và không có bước tay, và
những gì cần giữ phải tách sang stack riêng."

*Nếu được hỏi thêm:* thời gian dựng lại cả nền tảng, tới 17 Application khoẻ: 21 phút 47 giây (phase drills). Credit Free plan đủ khoảng 240 giờ cluster theo evidence, chưa trừ phần chi
phí luôn giữ và workstation (Terraform A5.1).

**A5.2** **Ý chính:** "Budget chỉ **báo**, không chặn: 100 USD mỗi tháng, lọc theo tag `project`, gửi email ở 50% và 100% chi phí thực.
Thứ thật sự giữ chi phí là thói quen xoá cluster. On-premises, chi phí là khoản đầu tư ban đầu cộng điện và người; trên cloud, một máy
quên tắt là tiền mất ngay."

*Nếu được hỏi thêm:*

- **Chặn thật:** Budget Actions gắn policy `Deny` hoặc dừng EC2 khi vượt ngưỡng; SCP giới hạn loại máy; Cost Anomaly Detection.
- **Giới hạn cần kiểm tra:** budget cập nhật vài lần mỗi ngày nên luôn chậm hơn chi phí thật; volume không có tag lọt khỏi budget; và
  nếu budget tính cả credit thì trong lúc còn credit, chi phí ròng gần bằng 0 và cảnh báo không bắn `[điền: kiểm tra cost_types]`
  (B6.2).

**A5.3** **Ý chính:** "Quota vCPU cho On-Demand, số Elastic IP và số VPC mỗi region là ba giới hạn dễ chạm nhất, nhất là khi account
dùng chung. Chúng không báo trước nếu không tự đặt alarm, và xin tăng phải xin trước. Có một loại khác quota thật sự: AZ hết máy
(`InsufficientInstanceCapacity`), xin tăng quota không giải quyết được; phải đổi AZ hoặc loại máy."

*Nếu được hỏi thêm:* Free plan còn chặn loại máy không đủ điều kiện, bất kể quota (Terraform A7.1). Terraform chạy nhiều resource một lúc
cũng có thể bị API của AWS throttle. Chi tiết con số: B6.4.

**A5.4** **Ý chính:** "App, Helm chart và phần lớn role Ansible gần như không phụ thuộc AWS. Phụ thuộc nằm ở Terraform, IAM, và các dịch
vụ managed như KMS, ECR, Secrets Manager. Rủi ro lớn nhất là chính account: credit hết hoặc account bị khoá thì mất state, image, secret,
và không ký tiếp được bằng key đó; chữ ký cũ chỉ còn kiểm được nếu tôi đã lưu public key ra ngoài."

*Nếu được hỏi thêm:* cách giảm: giữ bản sao state và giá trị secret ngoài account, lưu public key của cosign, và giữ các dịch vụ phía sau
lớp trừu tượng như External Secrets (Terraform A6.7).

**A5.5** **Ý chính:** "Mất một AZ: control plane còn hai node nên vẫn chạy. Nhưng nếu đó là AZ đầu tiên, nơi có NAT gateway duy nhất, thì
cả ba node mất đường ra internet: app không gọi được Gemini và Hugging Face, không pull được image, SSM ngắt nên tôi mất cả Ansible lẫn
tunnel, và WireGuard gateway cùng AZ nên mất Rancher. Mất cả region thì mọi thứ dừng; DR đa region nằm ngoài phạm vi."

*Nếu được hỏi thêm:* sửa cho trường hợp AZ: mỗi AZ một NAT gateway (hoặc NAT gateway theo region **[kiểm chứng]**), dời WireGuard gateway
khỏi AZ đầu tiên, interface endpoint cho SSM và ECR. PersistentVolume ở AZ lỗi không dời được. Một AZ là một hoặc nhiều datacenter riêng,
nên mất AZ nặng hơn mất một phòng máy (Terraform A1.11).

**A5.6** **Ý chính:** "Mang đi gần nguyên: app, Helm chart, Argo CD, và phần lớn role Ansible. Phải viết lại: toàn bộ Terraform; cách kết
nối và inventory của Ansible, vì đang dùng SSM và EC2 API; credential provider của ECR; và trong Jenkinsfile và chart, các bước ký bằng
KMS, push ECR, SecretStore trỏ Secrets Manager, initContainer tải từ S3. Các dịch vụ managed thay bằng Vault, MinIO, Harbor, HAProxy."

*Nếu được hỏi thêm:* thứ khó nhất không phải code mà là danh tính: mọi chỗ đang dựa vào IAM role phải được thay bằng một cơ chế cấp
credential khác (A3.1).

**A5.7** **Ý chính:** "Với project này, đòn bẩy gần như duy nhất là xoá cluster, vì nó chỉ chạy vài trăm giờ. Savings Plans và Reserved
Instances cam kết theo năm nên vô lý ở đây. Spot không hợp với control plane vì máy có thể bị lấy lại sau hai phút báo trước, dễ mất
quorum etcd; nhưng hợp với một nhóm worker riêng cho build Jenkins."

*Nếu được hỏi thêm:*

- **Graviton** rẻ hơn cho cùng hiệu năng, nhưng cần image đa kiến trúc và phải đủ điều kiện Free plan.
- **Right-sizing** dựa trên metric thật của node sau vài lần chạy.
- **Khoản ẩn:** NAT theo GB, IPv4 public theo giờ, phí liên AZ (A2.7).
- **Ở công ty** với tải chạy liên tục: Savings Plans cho phần nền, Spot cho phần co giãn.

### A6. Độ tin cậy, dữ liệu và tổ chức

**A6.1** **Ý chính:** "Hạ tầng có RTO là thời gian dựng lại từ code: 21 phút 47 giây tới khi mọi Application khoẻ. Với dữ liệu trong
cluster, chiến lược là backup và restore: snapshot etcd 6 giờ một lần, nên RPO tối đa 6 giờ theo lịch, và drill khôi phục đo được RTO 7 phút 02 giây (lần chạy được chứng
minh là dưới một lịch tạm 15 phút; RPO của chính lần drill là 6 phút 01 giây).
Điểm yếu tôi tự nói: role của node xoá được object trong bucket backup, và bucket không bật versioning."

*Nếu được hỏi thêm:*

- **Sửa:** bucket backup đã sang stack shared (phase drills). Còn lại: bật versioning và Object Lock, bỏ `s3:DeleteObject`
  khỏi role của node (hoặc cho CronJob một role IRSA riêng chỉ có `PutObject`), và replicate sang region khác.
- **Các mức cao hơn trên AWS:** pilot light (dữ liệu replicate sẵn, hạ tầng dựng khi cần; cần replicate cả ECR, S3 và KMS key đa
  region), warm standby, multi-site.
- **On-premises:** backup ra site khác hoặc tape theo quy tắc 3-2-1, và một site DR lạnh hoặc ấm.
- Dữ liệu quan trọng nhất (index, image, secret) đã nằm ở stack shared nên không mất khi xoá cluster.

**A6.2** **Ý chính:** "Prometheus trong cluster, vì nó thu được metric của app, Kubernetes và node, và rẻ. Nhưng nó chết cùng cluster, nên
không ai báo khi chính cluster sập. Cần ít nhất một cảnh báo từ bên ngoài: CloudWatch alarm trên số target unhealthy của NLB, một Route 53
health check, hoặc một dead man's switch cho Alertmanager."

*Nếu được hỏi thêm:* CloudWatch có sẵn metric của dịch vụ AWS như NLB, EBS, NAT gateway, nhưng tính phí theo metric và theo GB log.
Prometheus rẻ và linh hoạt nhưng phải tự vận hành. Project không bật CloudWatch agent hay VPC Flow Logs.

**A6.3** **Ý chính:** "Trước khi kết luận là lỗi của mình, tôi xem AWS Health Dashboard và status check của máy. Nếu sự cố nằm ở một AZ,
tôi cordon và drain node ở đó. Hệ thống nên chạy tiếp được mà không cần gọi API AWS trong lúc sự cố, vì control plane của một số dịch vụ
như IAM hay Route 53 cũng có thể bị ảnh hưởng."

*Nếu được hỏi thêm:* on-premises bạn tự điều tra phần cứng hoặc gọi vendor; trên AWS, bạn chủ yếu né và chờ. Với NLB có zonal shift để
tạm bỏ một AZ **[kiểm chứng]**.

**A6.4** **Ý chính:** "Region là Singapore. Quan trọng hơn: câu hỏi của người dùng đi ra khỏi AWS tới Gemini và Hugging Face, nên mô hình
trách nhiệm chung của AWS không che phần đó. Tài liệu là bách khoa công khai và câu hỏi là thử nghiệm, nên project chấp nhận được; với dữ
liệu bệnh nhân thật thì không."

*Nếu được hỏi thêm:*

- **Với dữ liệu thật:** dùng model chạy trong AWS cùng region (ví dụ Bedrock), không log câu hỏi, HTTPS, customer managed key, trail cho
  audit.
- **Pháp lý:** dữ liệu sức khoẻ là dữ liệu nhạy cảm theo quy định bảo vệ dữ liệu cá nhân của Việt Nam, và chuyển ra nước ngoài có thủ tục
  riêng **[kiểm chứng: văn bản đang hiệu lực]**; ở Mỹ thì là HIPAA, và AWS chỉ ký BAA cho các dịch vụ đủ điều kiện, không tự làm hệ thống
  tuân thủ.
- **On-premises** thường được chọn chính vì yêu cầu dữ liệu nằm tại chỗ (A1.6).

**A6.5** **Ý chính:** "Một AWS Organization với account riêng cho từng việc: quản lý, log, bảo mật, dịch vụ dùng chung như ECR và Route 53,
và mỗi môi trường một account. Người dùng đăng nhập qua IAM Identity Center, và SCP đặt giới hạn cho cả tổ chức, ví dụ chỉ dùng region đã
duyệt, cấm tắt CloudTrail. Project hiện chạy trong một account dùng chung, nên phải dựa vào tag và tiền tố tên."

*Nếu được hỏi thêm:* Control Tower dựng sẵn khung này. Tương đương on-premises là OU và group policy của Active Directory, cùng việc tách
tenant hay VLAN theo môi trường.

**A6.6** **Ý chính:** "Lần launch EC2 đầu tiên lỗi `not eligible for Free Tier` dù account còn credit. Tôi tưởng là chuyện credit, nhưng đọc
kỹ thì lỗi nói về loại máy: account ở Free plan, gói này chặn mọi loại máy không đủ điều kiện, bất kể còn bao nhiêu credit. Tôi kiểm tra
trạng thái gói bằng API, liệt kê loại máy hợp lệ, và đổi cấu hình."

*Nếu được hỏi thêm:* chuyện thứ hai là SSM agent của node 2 không lấy được credential lúc boot, và nguyên nhân mới là giả thuyết (Ansible
A4.4). Chi tiết chuyện Free plan: Terraform A7.1.

**A6.7** **Ý chính:** "Reliability yếu nhất: một NAT gateway cho cả ba AZ, và bucket backup etcd chưa có versioning hay Object Lock. Security
đứng thứ hai: pod nền tảng vẫn dùng chung role của node, workstation có quyền admin, Secret trong etcd chưa mã hoá. Cost optimization và operational excellence là phần
mạnh: xoá cluster khi không dùng, mọi thứ là code, có drill."

*Nếu được hỏi thêm:* sửa reliability trước: NAT mỗi AZ hoặc theo region, thêm versioning và Object Lock cho bucket backup (đã ở shared) (A5.5, A6.1). Nói một
trụ cột yếu nhất kèm cách sửa là đủ, không cần đọc cả sáu.

---

## Phần B — Chi tiết

Đáp án ngắn, để tự kiểm tra.

### B1. VPC và mạng

**B1.1** Subnet là public khi route table của nó gửi `0.0.0.0/0` tới **internet gateway**. Chỉ bật
auto-assign public IP thì subnet chưa phải là public.

- `10.10.101.0/24` gắn với route table public của module, trỏ tới internet gateway.
- `10.10.1.0/24` dùng route table private, có default route trỏ tới NAT gateway.

`map_public_ip_on_launch = false` chỉ ngăn instance ở đó tự nhận địa chỉ; WireGuard gateway thì xin địa chỉ
một cách tường minh.

**B1.2** Project dựa vào **security group**. Security group là **stateful** (traffic trả về tự động được cho
phép), gắn vào network interface, chỉ có allow, và tham chiếu được group khác.

Network ACL là **stateless**: traffic trả về cần rule riêng, kể cả dải port tạm. NACL áp cho cả subnet và hỗ
trợ explicit deny.

Module VPC quản lý luôn các cấu hình mặc định của VPC:

- **default NACL:** đặt lại thành cho phép tất cả, nên security group là bộ lọc duy nhất
- **default security group:** làm rỗng, nên thứ gì vô tình dùng nó cũng không có quyền truy cập nào
- **default route table:** làm rỗng

**B1.3** Nó nằm ở subnet **public**: subnet đầu tiên, vì `single_nat_gateway = true`. Nó cần Elastic IP vì nó
dịch các IP nguồn private của node thành một địa chỉ public duy nhất ra internet.

**Các khoản phí:**

- phí theo giờ
- phí xử lý theo GB cho mọi thứ nó chuyển tiếp (vì vậy S3 gateway endpoint mới quan trọng)
- phí IPv4 public cho EIP của nó
- phí truyền dữ liệu thông thường, và vì chỉ có một NAT ở AZ đầu tiên, node ở hai AZ kia trả thêm **phí truyền dữ liệu
  giữa AZ** cho mọi traffic ra internet **[kiểm chứng: đơn giá]**

AWS đã có NAT gateway theo region, tự trải qua nhiều AZ, là một phương án thay cho `single_nat_gateway` **[kiểm chứng]**.

**B1.4**

| | Gateway endpoint | Interface endpoint |
|---|---|---|
| Cách hoạt động | Một dòng trong route table trỏ tới prefix list | Network interface có IP private trong subnet của bạn, kèm private DNS |
| Giá | Miễn phí | Theo giờ cho mỗi endpoint mỗi AZ, cộng theo GB |
| Dịch vụ | Chỉ S3 và DynamoDB | Phần lớn dịch vụ AWS (SSM, ECR, Secrets Manager, KMS, STS, …) |
| Phạm vi tới được | Chỉ từ route table của VPC | Cả từ mạng peering và VPN, qua IP private của nó |

**B1.5** Khi cluster đang chạy:

| Nơi giữ | Số địa chỉ |
|---|---|
| EIP của NAT gateway | 1 |
| EIP của WireGuard | 1 |
| Public NLB, mỗi AZ một địa chỉ | 3 |
| Workstation, khi đang chạy | 1 |

Tổng cộng 5 tới 6 địa chỉ. Internal NLB không có địa chỉ public nào. Từ tháng 2/2024, AWS tính khoảng 0.005
USD/giờ cho **mọi** địa chỉ IPv4 public, dù đang dùng hay để không, nên chúng cộng thêm khoảng 0.03 USD/giờ.

**B1.6** Một `/28` có 16 địa chỉ, và AWS giữ lại 5: địa chỉ mạng, `+1` (router của VPC), `+2` (DNS), `+3` (dành
cho tương lai) và địa chỉ broadcast. Còn **11 địa chỉ dùng được**, thừa cho một máy.

**B1.7** Không nhất thiết. Tên AZ được ánh xạ tới zone vật lý riêng cho từng account; định danh ổn định là
**AZ ID** (`apse1-az1`, …).

**Khi nào quan trọng:**

- chia sẻ subnet hoặc đặt resource giữa nhiều account
- so sánh độ trễ hoặc báo cáo sự cố với account khác
- khả năng có sẵn của loại máy, vốn tính theo zone

Trong cùng một account, như project này, tên AZ là nhất quán.

**B1.8** **Có:** mỗi endpoint có một endpoint policy, mặc định cho phép tất cả. Policy này đánh giá thêm, không thay cho
IAM hay bucket policy. Siết được, nhưng danh sách phải gồm cả bucket do AWS quản lý mà node dùng gián tiếp, như bucket chứa
layer của ECR trong region **[kiểm chứng: tên bucket]**; thiếu nó thì pull image lỗi 403 dù IAM của node đúng.

**Region khác:** gateway endpoint chỉ thêm route tới prefix list của S3 **trong cùng region**; bucket ở region khác đi theo
route mặc định, qua NAT.

**ECR:** lệnh xác thực và API của ECR là dịch vụ khác, không có gateway endpoint, nên đi qua NAT; chỉ phần tải layer, do ECR
phục vụ từ S3, mới đi qua gateway endpoint. Muốn bỏ hẳn NAT cho ECR thì cần interface endpoint `ecr.api` và `ecr.dkr`, tính tiền
theo giờ.

### B2. Cân bằng tải

**B2.1**

| | NLB | ALB |
|---|---|---|
| Tầng | 4 (TCP/UDP/TLS) | 7 (HTTP/HTTPS/gRPC) |
| TLS | Passthrough, hoặc terminate trên listener TLS | Luôn terminate |
| IP nguồn | Có thể giữ nguyên | Bị thay; IP client nằm trong `X-Forwarded-For` |
| Địa chỉ | Mỗi AZ một IP cố định (dùng được EIP nếu là internet-facing) | Thay đổi theo thời gian; dùng DNS name |
| Security group | Hỗ trợ, nhưng chỉ khi gắn lúc tạo | Luôn có |
| Định tuyến | Theo port | Theo host, path, header |

Project này cần tầng 4 và passthrough (Terraform A1.7).

**B2.2** Node của load balancer ở mỗi AZ có thể gửi traffic tới target ở **bất kỳ** AZ nào, không chỉ AZ của nó.
Traffic chia đều theo target chứ không theo AZ, và khi một AZ không còn target khoẻ thì IP của AZ đó vẫn dùng được
ngay. Tắt cross-zone thì NLB rút IP của AZ đó khỏi DNS, và client còn giữ bản cache cũ lỗi cho tới khi hết TTL. Trên NLB, cross-zone mặc định tắt, và bật lên thì **phí truyền dữ liệu giữa các AZ**
bắt đầu được tính. Ở đây lưu lượng rất nhỏ.

**B2.3** Ba tình huống khác nhau:

- **API server chết, máy treo:** target thành unhealthy sau khoảng 20 giây với cấu hình này. NLB ngừng gửi kết nối mới, và
  mặc định còn đóng các kết nối đang mở tới target unhealthy, nên kubectl hay kubelet nhận lỗi và kết nối lại **[kiểm chứng]**.
- **Máy bị stop:** target chuyển sang trạng thái không dùng được gần như ngay, không phải chờ health check, và kết nối mất cùng
  hệ điều hành.
- **Target bị deregister** (thay node có kế hoạch): NLB chờ **deregistration delay**, mặc định **300 giây**, để kết nối đang dở
  kịp xong. Hết delay, NLB không tự đóng kết nối còn lại trừ khi bật connection termination khi deregister, mặc định tắt
  **[kiểm chứng]**; `loadbalancers.tf` không đặt thuộc tính nào.

Khi thay node có kế hoạch: drain trước, rồi tính cả thời gian delay. Hạ nó xuống, ví dụ 30 giây, giúp bài drill nhanh hơn.

**B2.4**

| Target group | Kiểm tra | Chu kỳ | Ngưỡng |
|---|---|---|---|
| API, cổng 6443 | `HTTPS /readyz`, mong đợi 200 | 10 giây | 2 lần đạt, 2 lần hỏng |
| Ingress, NodePort | TCP | 10 giây | 2 lần đạt, 2 lần hỏng |

- Target bị coi là hỏng sau khoảng 20 giây, và khoẻ lại sau khoảng 20 giây, theo cấu hình (chưa đo).
- **Mọi target đều unhealthy:** NLB **fail open**, gửi traffic tới tất cả. Vì vậy trong khoảng 20 giây sau khi API server của node
  1 lên mà chưa qua đủ hai lần check, khoảng hai phần ba kết nối rơi vào node 2 và 3 và bị từ chối. Khi node 1 đã healthy, NLB chỉ
  gửi tới node 1 (Terraform B6.3).
- **Chiều security group:** health check xuất phát từ chính NLB, nên security group của NLB phải cho **egress** tới node, và
  security group của node phải cho **ingress** từ security group của NLB (Terraform B5.6).

*Ở đâu:* `infra/terraform/cluster/loadbalancers.tf`.

**B2.5** Kiểu **`instance`**: target là instance ID cộng một port, ở đây là NodePort hoặc 6443.

- **`ip`** trỏ thẳng vào một địa chỉ IP, dùng khi pod có IP thật trong VPC (VPC CNI) hoặc target nằm ngoài VPC. Pod ở đây dùng dải
  overlay của Calico nên NLB không tới được IP pod (A2.6).
- **`alb`** đặt một ALB phía sau NLB, dùng khi cần IP cố định của NLB cùng định tuyến HTTP của ALB.
- **`alb`** còn dùng để đưa một ALB ra qua PrivateLink.
- **Cái giá của `instance` + NodePort:** thêm một chặng qua kube-proxy, và số port phải khớp giữa Terraform với values của
  ingress-nginx.

**B2.6** Idle timeout TCP của NLB mặc định **350 giây**, nay chỉnh được theo listener **[kiểm chứng]**. Hết timeout, NLB xoá
flow mà không báo cho hai đầu; gói tin sau đó bị từ chối, và client có thể treo tới khi tự phát hiện. Kết nối sống lâu như `kubectl
--watch`, kết nối của kubelet hay agent của Rancher cần TCP keepalive hoặc ping ngắn hơn 350 giây; client của Kubernetes và
websocket của Rancher thường đã có **[kiểm chứng]**.

**B2.7** Chỉ kiểm tra NodePort có mở trên node. Với `externalTrafficPolicy: Cluster`, kube-proxy nhận kết nối trên mọi node rồi
chuyển tới pod ingress-nginx ở bất kỳ đâu, nên **mọi node đều healthy** dù node đó không có pod ingress nào. Health check vì vậy
không phản ánh pod cục bộ, và có thêm một chặng SNAT. Dùng `Local` kèm `healthCheckNodePort` thì NLB chỉ gửi tới node có pod, và
giữ được IP client. Ở project này là `Local`, và ingress-nginx chạy dạng DaemonSet nên node nào cũng có một pod để nhận
(`deploy/argocd/values/ingress-nginx.yaml`). Health check của NLB vẫn là TCP trên chính NodePort. `Local` còn là thứ giữ IP thật
của client cho allowlist `10.10.0.0/16` trên các UI nội bộ: để `Cluster` thì kube-proxy đổi source thành địa chỉ VPC của node, và
allowlist sẽ cho traffic từ internet đi qua.

### B3. Compute và lưu trữ

**B3.1** Instance profile đưa role ra qua metadata service tại
`/latest/meta-data/iam/security-credentials/<role>`. AWS SDK và CLI tự đọc ở đó.

SDK gửi `PUT /latest/api/token` để lấy token IMDSv2 trước, rồi đọc đường dẫn trên kèm header token.

Credential là **credential STS tạm thời**: access key, secret key và session token. Chúng thường có hiệu lực khoảng 6 giờ,
và bản mới có sẵn trước khi bản cũ hết hạn **[kiểm chứng]**. Không có gì phải lưu hay tự tay rotate, và cũng không có gì để lọt
vào Git.

**B3.2** **Server-side request forgery (SSRF).** Với IMDSv1, một lỗi khiến ứng dụng tải một URL do kẻ tấn công
cung cấp (`http://169.254.169.254/...`) sẽ trả về credential của role.

IMDSv2 bắt buộc lấy session token trước, bằng request `PUT` kèm header TTL. Lỗi SSRF đơn giản không gửi được
request như vậy. AWS còn từ chối request lấy token có header `X-Forwarded-For`, và hop limit giữ token không ra
khỏi host. `http_tokens = "required"` tắt IMDSv1.

**B3.3** **Role** là một IAM identity có trust policy và quyền. EC2 không gắn trực tiếp role được; nó gắn một
**instance profile**, tức một lớp bọc chứa đúng một role. Console giấu điều này bằng cách tạo cả hai cùng lúc;
Terraform tạo riêng từng cái (`aws_iam_instance_profile`).

Gắn role vào instance cần quyền **`iam:PassRole`** trên role đó. Quyền này ngăn người dùng launch instance với
một role mạnh hơn quyền của chính họ.

**B3.4** Ổ gốc có `delete_on_termination = true` mặc định, nên xoá instance là **xoá luôn ổ đĩa**. Thư mục dữ
liệu của etcd (`/var/lib/etcd`) biến mất theo. Đó là lý do:

- node control plane bị thay phải được gỡ khỏi etcd trước (Terraform B7.6)
- snapshot etcd được đẩy lên S3, vào bucket `etcd-backups` ở stack `shared` (từ phase drills), giữ object 14 ngày, và theo cấu hình thì
  sống qua `make infra-destroy` vì bucket không nằm trong state của cluster; chưa kiểm lại object sau một lần teardown. Trước đó bucket nằm trong stack cluster với `force_destroy = true` và mất theo mỗi lần teardown (A6.1)
- sau teardown, cluster được dựng lại chứ không khôi phục

Volume của PVC thì ngược lại: không bị xoá cùng instance (Terraform B3.7).

**B3.5** gp3 cho baseline **3.000 IOPS và 125 MB/s ở mọi dung lượng**, và rẻ hơn gp2 khoảng 20 % mỗi GB. Một ổ
gp2 40 GB chỉ có baseline 120 IOPS (3 IOPS mỗi GB), cộng một lượng burst credit sẽ cạn dần.

etcd ghi xuống đĩa và chờ mỗi lần ghi được xác nhận, nên đĩa chậm gây bầu lại leader và API timeout. gp3 tránh
chuyện hết burst credit là IOPS tụt đột ngột, đúng lúc node bận nhất.

Nhưng loại máy cũng có giới hạn băng thông và IOPS tới EBS của riêng nó, và loại nhỏ chỉ burst được trong thời gian giới hạn
`[điền: số từ describe-instance-types]` **[kiểm chứng]**. Với etcd, chỉ số cần đo là độ trễ fsync
(`etcd_disk_wal_fsync_duration_seconds`), không phải IOPS.

**B3.6**

| | `t3.large` | `m7i-flex.large` |
|---|---|---|
| Mô hình | CPU credit: tích luỹ khi dưới baseline (30 % mỗi vCPU), tiêu khi vượt | Chạy full CPU khoảng 95 % thời gian, tối thiểu 40 % phần còn lại |
| Chế độ mặc định | *Unlimited*, nên burst thêm sẽ bị tính tiền | — |
| Metric cảnh báo | `CPUCreditBalance` trong CloudWatch | Không có metric tương đương |

Với `m7i-flex`, chỉ tải nặng gần như liên tục mới bị giới hạn, không phải một lần build dài. Nhưng khi bị giới
hạn thì không có metric nào báo trước, nên cảnh báo theo mức dùng CPU kéo dài và theo CPU steal
(`node_cpu_seconds_total{mode="steal"}`), phần CPU hypervisor lấy bớt khi máy bị giới hạn **[kiểm chứng]**.

**B3.7**

- **System status check:** phần hạ tầng AWS bên dưới máy: phần cứng của host, mạng, nguồn. Lỗi thì thường phải stop rồi start
  để máy chuyển sang host khác.
- **Instance status check:** bên trong máy: hệ điều hành không boot được, hết bộ nhớ, cấu hình mạng sai. Lỗi thì thường phải
  reboot hoặc sửa hệ điều hành.
- **Attached EBS status check:** các ổ EBS gắn vào máy còn đọc ghi được không. Với node chạy etcd, đây là check đáng đặt alarm
  **[kiểm chứng]**.

Các check đó chỉ nói máy boot được, có mạng và có đĩa. Chúng không biết gì về SSM agent: agent chạy nhưng không lấy được credential vẫn qua
mọi check. Vì vậy phải xem `aws ssm describe-instance-information` (máy có đăng ký không) và `aws ec2 get-console-output`
(log boot, không cần đăng nhập) (Ansible A4.4).

**B3.8** Resource instance của node đó lỗi (`Unsupported` nếu AZ không bán loại máy, `InsufficientInstanceCapacity` nếu tạm hết
máy), các resource khác vẫn được tạo, và phải apply lại. `cluster/main.tf` lấy ba AZ đầu tiên đã lọc AZ chuẩn, nhưng không kiểm
tra AZ có bán `m7i-flex.large` không. Cách chặt hơn: đọc `aws_ec2_instance_type_offerings` theo AZ và chỉ chọn AZ có loại máy đó.
Hết máy tạm thời thì xin tăng quota cũng không giải quyết được; đổi AZ hoặc loại máy.

### B4. IAM, mã hoá và secret

**B4.1** **Trust policy** (`assume_role_policy`) nói ai được assume role. Ở đây là `ec2.amazonaws.com`, qua
`data.aws_iam_policy_document.ec2_assume_role`. **Permissions policy** (các managed policy gắn vào và inline
policy) nói role được làm gì sau khi được assume. Role cần cả hai: có quyền mà không có trust thì không ai dùng
được, có trust mà không có quyền thì chẳng làm được gì.

**B4.2** AWS đánh giá mọi policy liên quan cùng lúc.

1. Request được xác thực là role của node.
2. AWS tìm **explicit Deny**. Bucket policy từ chối `s3:*` khi `aws:SecureTransport` là `false`, mà với HTTP
   thường thì đúng như vậy, nên request bị **từ chối**.
3. Explicit Deny kết thúc việc đánh giá: `Allow` trên `s3:GetObject` của role node không còn được xét.

Qua HTTPS, điều kiện là false, Deny không áp dụng, và `Allow` trong identity policy cấp quyền cho request (cùng
account, nên không cần Allow trong bucket policy).

**B4.3**

- **AWS managed:** `AmazonSSMManagedInstanceCore`, `AmazonEBSCSIDriverPolicy` và `AdministratorAccess` của
  workstation. Tiện vì AWS bảo trì và cập nhật khi dịch vụ có action mới, nhưng chúng viết cho mọi account nên
  thường rộng hơn mức cần (Terraform B7.3).
- **Inline:** `medical-rag-nodes` và `read-wireguard-secret`. Chúng dành riêng cho một role, ghi đúng ARN, và
  bị xoá cùng role.
- **Customer managed:** không dùng. Loại này đáng dùng khi cùng một policy tự viết được gắn vào nhiều role,
  hoặc để thay một managed policy quá rộng bằng bản đã siết.

**B4.4** **IAM có tính nhất quán sau (eventual consistency).** Role hay instance profile mới có thể mất vài
giây mới lan tới EC2, dù IAM đã xác nhận tạo xong. `RunInstances` trong khoảng đó lỗi
`Invalid IAM Instance Profile name`. AWS provider tự thử lại lỗi này một lúc, nên hiếm khi gặp. Nếu vẫn lỗi, chỉ
cần apply lại.

**B4.5** **KMS key bất đối xứng không rotate tự động được;** chỉ key mã hoá đối xứng mới làm được.

**Rotate thủ công:**

1. Tạo key mới.
2. Chuyển alias sang key mới.
3. Giữ public key của key cũ, nếu không các chữ ký cũ không kiểm tra được nữa. Phần lớn hệ thống chọn ký lại
   các image đang dùng.

**Chi phí:** khoảng 1 USD/tháng mỗi key. Request dùng key bất đối xứng tính riêng và không nằm trong mức miễn phí
**[kiểm chứng: đơn giá]**, nhưng ở mức CI vẫn không đáng kể.

**Chuyển alias chưa đủ:** policy của node ghi ARN của key mà alias trỏ tới **lúc apply** stack cluster, nên sau khi chuyển alias
phải apply lại stack cluster (Terraform B2.7).

**B4.6**

| | Secrets Manager (đang dùng) | Parameter Store `SecureString` |
|---|---|---|
| Giá | 0.40 USD mỗi secret mỗi tháng, cộng phí gọi API **[kiểm chứng]** | Parameter standard miễn phí (mỗi lần đọc tốn một lần KMS decrypt) |
| Giới hạn kích thước | 64 KB | 4 KB standard, 8 KB advanced (có tính phí) |
| Recovery window khi xoá | Có | Không |
| Rotation có sẵn | Có | Không |
| Resource policy | Có | Không có policy trên parameter; parameter advanced chia sẻ sang account khác qua AWS RAM **[kiểm chứng]** |
| IAM cho node | `GetSecretValue` | `ssm:GetParameter` cộng `kms:Decrypt` |

Full chain của Sectigo cộng private key có thể vượt **4 KB**, buộc phải dùng parameter advanced. External
Secrets hỗ trợ cả hai. Ở đây lựa chọn này chênh nhau khoảng 2 USD/tháng, chủ yếu đổi lấy recovery window.

Một điểm đáng nói: vì node đã có `ssm:GetParameter` trên `*` qua managed policy (Terraform B7.3), secret cất trong
Parameter Store với key mặc định sẽ bị mọi pod đọc được. Secrets Manager với ARN tường minh tránh được điều đó.

**B4.7**

- **Mã hoá mặc định:** từ tháng 1/2023, S3 mặc định mã hoá mọi object mới bằng SSE-S3. Các resource
  `server_side_encryption_configuration` tường minh nhắc lại điều đó, để scanner và người đọc thấy ngay trong
  code.
- **Strong consistency:** từ tháng 12/2020, S3 có strong read-after-write consistency. Trước đó, lock lưu trong
  S3 không đáng tin, nên Terraform mới cần DynamoDB.
- **Conditional write:** từ 2024, S3 hỗ trợ `If-None-Match`. Nhờ đó Terraform chỉ tạo object `.tflock` khi chưa
  có object nào. Cộng với strong consistency, đây là điều làm `use_lockfile` khả thi.

**B4.8**

1. **Agent** đang chạy; AMI Ubuntu có sẵn dưới dạng snap.
2. **Credential:** instance profile có quyền như `AmazonSSMManagedInstanceCore`, lấy qua metadata service.
3. **Mạng tới endpoint** `ssm`, `ssmmessages` và `ec2messages` của region: qua NAT, internet gateway, hoặc interface endpoint.

Máy đăng ký xong thì `describe-instance-information` báo `Online`.

**Default Host Management Configuration** là cơ chế cấp quyền SSM ở mức account, không cần instance profile: agent tự lấy
credential bằng một role do SSM quản lý, và cần IMDSv2. Account này không bật nó, nên khi agent không đọc được credential của
instance profile lúc boot, nó thử cơ chế này và bị từ chối `AccessDeniedException`, đúng như log của node 2.

**B4.9** **Máy chạy Ansible** cần quyền ghi, đọc, xoá object trong bucket truyền file: nó upload module, rồi ký một URL có
hạn bằng credential của chính nó. **Node** chỉ `curl` URL đó, nên về nguyên tắc không cần quyền S3 nào; URL tới S3 qua gateway
endpoint.

**Presigned URL** mang theo chữ ký và thời hạn: ai có URL trong thời hạn đó đều tải được object, không cần credential. Nó chỉ
đi trong lệnh SSM tới đúng node, nhưng không gắn với node nào.

**Giới hạn của presigned URL:** URL ký bằng credential STS tạm thời hết hiệu lực khi session token hết hạn, dù tham số hết hạn
dài hơn. URL xuất hiện trong lệnh `curl` trên node, thấy được qua danh sách process, và trong log session nếu bật. URL chỉ đi qua
gateway endpoint nếu dùng endpoint S3 theo region **[kiểm chứng: plugin sinh dạng nào]**.

Rủi ro thật ở project là role của node **cũng** đọc ghi được bucket này qua policy S3 chung trong `cluster/iam.tf` (Ansible A7.5).

**B4.10** `ecr:GetAuthorizationToken` trả một token dùng như mật khẩu registry, có hạn **12 giờ**. kubelet cache token theo thời gian mà
plugin trả về, chỉ dùng `defaultCacheDuration: 12h` khi plugin không trả giá trị **[kiểm chứng]** (Ansible B5.3).

- **IAM policy** gắn vào identity (role của node) nói identity đó được làm gì trên repository nào.
- **Repository policy** gắn vào chính repository, dùng để cho account hay principal **khác** truy cập, ví dụ cho một account
  prod pull image từ account build.

Cùng account như project này, IAM policy của role là đủ. Role của node chỉ còn quyền pull; push thuộc về role `ci` của Jenkins
build pod (Jenkins step 18). Một repository policy `Deny` push cho mọi principal trừ role `ci` sẽ siết thêm một lớp, dù cùng
account.

**B4.11** Với KMS, **key policy là gốc**: không identity nào dùng được key nếu key policy không cho, kể cả admin của account.
Key policy mặc định có một statement cho phép chính account, nghĩa là "để IAM policy quyết định".

Terraform tạo key với key policy mặc định, nên một `kms:Sign` trong IAM policy của một role là đủ để role đó ký. Nếu key policy bị
thay bằng một policy chỉ liệt kê vài principal mà thiếu statement đó, IAM policy không còn tác dụng.

**Chỉ CI được ký, và đã làm vậy:** chỉ role `medical-rag-ci` có `kms:Sign`. Jenkins build pod assume role đó qua IRSA tự dựng (A3.6);
role của node mất `kms:Sign` ở Jenkins step 18, và evidence ghi lại lỗi `AccessDeniedException` khi một pod thử ký bằng role node.
Siết thêm được bằng key policy chỉ cho `medical-rag-ci` gọi `kms:Sign`, để một IAM policy lỡ tay ở role khác cũng không ký được.

**B4.12** Mỗi lần `put-secret-value` tạo một **version** mới và gắn nhãn `AWSCURRENT`; version trước được chuyển sang
`AWSPREVIOUS`. Đọc secret mà không chỉ version thì nhận `AWSCURRENT`.

External Secrets đọc `AWSCURRENT` theo chu kỳ refresh và cập nhật Kubernetes Secret khi giá trị đổi. Rollback một secret là đưa
nhãn `AWSCURRENT` về version cũ, không cần nhập lại giá trị.

Xoá secret chỉ **lên lịch** xoá sau recovery window (ở đây 7 ngày), trong thời gian đó `restore-secret` được (Terraform B3.3).

**B4.13** Có. Credential của instance role mang theo thông tin về VPC và IP private của máy đã nhận nó, và IAM có condition key cho
chúng, như `aws:EC2InstanceSourceVPC` và `aws:EC2InstanceSourcePrivateIPv4` **[kiểm chứng]**. Một statement `Deny` khi các giá trị đó
không khớp, đặt trong policy của role hoặc trong bucket policy, làm credential bị mang ra ngoài vô dụng. GuardDuty cũng có finding
riêng cho credential của instance bị dùng từ ngoài AWS **[kiểm chứng]**. Project chưa áp dụng.

### B5. DNS

**B5.1** Một CNAME trỏ tới `aws_lb.api.dns_name` cũng tự cập nhật khi NLB đổi tên, nên đó không phải lý do.
Lý do thật của alias:

- **Trả thẳng record `A`** của đích: resolver không phải đi theo thêm một chặng CNAME.
- **Truy vấn alias tới đích AWS như ELB là miễn phí,** còn CNAME tính phí truy vấn bình thường.
- **Đặt được ở zone apex** (chính `recruitai.io.vn`), nơi CNAME bị cấm. Project chưa dùng apex, nhưng alias là
  lựa chọn nhất quán cho mọi record trỏ vào resource AWS.

**B5.2**

- **Ở registrar:** đổi NS của `recruitai.io.vn` thành bốn name server của Route 53. Registrar đẩy thay đổi lên zone cha,
  do registry của tên miền `.vn` vận hành.
- **Bên trong zone:** Route 53 tự tạo NS và SOA khi tạo zone.

**Vì sao mất hàng giờ:** resolver cache các record NS cũ của zone cha theo TTL, thường một tới hai ngày. Cho tới
khi các bản cache đó hết hạn, một số resolver vẫn hỏi DNS provider cũ, vì vậy phải chép record sang và giữ
provider cũ 48 giờ.

**DNSSEC:** record DS ở zone cha trỏ tới key ký DNSSEC của DNS provider *cũ*. Câu trả lời mới, không ký, từ
Route 53 sẽ không qua được kiểm tra, và resolver có kiểm tra DNSSEC sẽ trả `SERVFAIL` cho cả domain. Vì vậy
phải gỡ record DS trước, và chờ TTL của nó hết hạn.

**B5.3** Mỗi hosted zone mới nhận một **delegation set** bốn name server chọn ngẫu nhiên, nên zone mới dù cùng
tên vẫn có server mới. **Reusable delegation set** (`aws_route53_delegation_set`) cố định bốn server, và các
zone tạo bằng nó dùng lại đúng bốn server đó. Cách này giải quyết chuyện tạo lại, nhưng trong project này
`prevent_destroy` cộng với việc giữ zone ở `shared/` đã đủ.

**B5.4** **Domain control validation** qua DNS: Sectigo đưa ra tên và giá trị của một CNAME, suy ra từ
certificate request. Record đó được tạo trong Route 53 zone, và Sectigo kiểm tra nó phân giải được công khai.

**Những gì có thể chặn việc cấp:**

- record **CAA** trên tên hoặc trên domain chỉ cho phép các CA khác
- chuỗi DNSSEC bị hỏng
- delegation chưa lan tới resolver của Sectigo
- request có tên không khớp (`rancher.recruitai.io.vn`)

### B6. Account, chi phí và vận hành

**B6.1** **Giới hạn:** chỉ dùng được một số dịch vụ và **loại máy** đủ điều kiện free tier (vì vậy mới có
Terraform A7.1), và chi phí được trừ vào **credit**, không phát sinh hoá đơn.

**Khi kết thúc:** Free plan kết thúc sau một thời hạn tính từ lúc tạo account, hoặc sớm hơn nếu hết credit
**[kiểm chứng: thời hạn hiện hành]**. Hạn của Free plan **khác** hạn của credit: credit của account này hết hạn 2027-02-13, còn hạn
của gói đọc từ `aws freetier get-account-plan-state` `[điền: ngày]`. Khi gói kết thúc mà chưa nâng cấp, account bị đóng, và có một
khoảng thời gian để nâng lên gói trả phí trước khi dữ liệu bị xoá **[kiểm chứng]**.

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

**B6.2** Resource mang tag (ở đây nhờ `default_tags`). Tag do người dùng định nghĩa phải được **kích hoạt** làm
cost allocation tag; từ đó dữ liệu billing có thêm cột `user:project`. Filter của budget
`TagKeyValue user:project$medical-rag` chọn theo cột đó. Những gì filter này bỏ sót nằm ở Terraform B8.6.

**Credit:** cost budget mặc định tính chi phí **sau khi trừ credit** **[kiểm chứng]**, và `shared/bugdets.tf` không đặt
`cost_types`. Nếu đúng, trong lúc còn credit chi phí ròng gần bằng 0 và cảnh báo 50%, 100% không bao giờ bắn. Sửa bằng
`cost_types { include_credit = false }` `[điền: kiểm tra budget thật]`.

**B6.3** Chỉ **thư mục home**: 1 GB mỗi region, bị xoá sau 120 ngày không dùng. Phần máy phía sau chỉ là tạm
thời và session sẽ hết hạn.

State Terraform để ở đó có thể mất cùng môi trường, người khác không nhìn thấy, và không lock được cho làm việc
nhóm. Vì vậy phải migrate lên S3 ngay (Terraform B1.1), và đặt `TF_DATA_DIR` trong `/tmp` để provider không làm đầy home
(Terraform A7.3).

**B6.4** Kiểm tra trong Service Quotas, vì account mới có thể có mức mặc định thấp:

- **vCPU cho On-Demand Standard instances:** project cần khoảng 10 vCPU (6 cho node, 2 cho gateway, 2 cho
  workstation), cộng phần của các project khác.
- **Elastic IP, mặc định 5 mỗi region:** project này giữ 2 (NAT gateway và WireGuard).
- **VPC, mặc định 5 mỗi region:** project này dùng 2 (ops và cluster), cộng VPC mặc định.

Các project khác dùng chung account, nên `make infra` có thể lỗi `VcpuLimitExceeded`, `AddressLimitExceeded`
hoặc `VpcLimitExceeded` dù bản thân nó không đổi gì. Xin tăng trước khi chúng chặn một lần dựng lại.

**B6.5** **CloudTrail.** Event history miễn phí giữ 90 ngày management event. Lọc theo tên event
`RevokeSecurityGroupIngress`, `RevokeSecurityGroupEgress` hoặc `ModifySecurityGroupRules` (rule có thể bị sửa thay vì xoá), hoặc
theo ID security group. Event cho thấy
identity, IP nguồn, thời điểm và nguyên văn request.

**Bẫy:** lệnh chạy trên workstation hiện ra dưới tên
`assumed-role/medical-rag-ops-workstation/i-…`, tức instance, không phải người. Muốn biết *ai*, tìm event
`StartSession` của Session Manager quanh thời điểm đó (identity của người mở session), rồi đối chiếu lịch sử
session. Lệnh chạy trong CloudShell thì mang identity đăng nhập console của người đó. Muốn lịch sử dài hơn 90
ngày thì cần một trail đẩy log vào S3.
