# Đáp án Ansible

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Phần A mở đầu bằng **Ý chính**: câu nói thành tiếng, ngôi
thứ nhất, thường là đủ. *Nếu được hỏi thêm* dùng khi người phỏng vấn đào sâu; tham chiếu như `(B6.7)` là để bạn tra,
không đọc ra. Đường dẫn tính từ `infra/ansible/`, trừ khi ghi khác.

Các đáp án mô tả project **khi đã hoàn thành**. Chỗ `[điền: …]` là số liệu hoặc kiểm tra phải lấy từ lần chạy thật; đừng
nói điều chưa đo. Ghi chú **[kiểm chứng]** là hành vi của công cụ cần xác nhận trên workstation trước khi nói chắc.

**Số liệu đã có** ([`docs/evidence/ansible.md`](../evidence/ansible.md)): Kubernetes 1.36.4, containerd 2.3.5, Calico
v3.32.2 (VXLAN), ecr-credential-provider v1.37.0, collection `amazon.aws` 10.3.2; ba node `Ready`, mọi pod chạy với 0
restart; `make cluster` chạy lại trên cluster đã có mất 2 phút 59 giây; tắt node 2 thì `kubectl get pods -A` vẫn trả lời.

**Cần điền hoặc xác nhận:**

- `kubectl get nodes -o wide`; bảng member etcd. (Thời gian `make cluster` trên node mới và PLAY RECAP lần hai đã có:
  6 m 10 s, `changed=0`.)
- `server:` trong `/etc/kubernetes/kubelet.conf` của node control plane (A1.6).
- `spec.calicoNetwork.bgp` trong `kubectl get installation default -o yaml` (A6.4).
- `upgrade.yml` **đã có** (phase drills) nhưng **chưa chạy**: 1.36.4 là bản vá mới nhất của 1.36, nên số request lỗi khi
  nâng cấp không đo được (A3.3).
- Script boot chờ credential cho SSM agent **chưa có**; `infra/scripts/timed-rebuild.sh` thay bằng một lần reboot có điều
  kiện (A4.4). Nhánh reboot đó chưa từng phải chạy.

**Nếu bạn sửa code trước khi nộp CV, sửa cả đáp án:** các đáp án mô tả đúng code hiện tại, kể cả điểm yếu đã biết.

| Điểm yếu trong code | Câu liên quan |
|---|---|
| Assert đầu `site.yml` chỉ kiểm tra `is defined` | B1.9, A8.2 |
| Thay node 1 bằng máy mới sẽ chạy `kubeadm init` lần nữa | B6.7, A3.1, A8.2 |
| Nhóm `other_nodes` gồm mọi máy không phải node 1, nên worker mới sẽ join làm control plane | A3.2 |
| Output của `kubeadm init` không có `no_log`; init để lại token mặc định sống 24 giờ | B6.8, A2.3 |
| File join không được xoá khi join lỗi; không có `block` nào | B7.4, A5.4 |
| Đổi phiên bản package thì cả ba node nâng cùng lúc, không drain | A5.6, B3.3, B4.4 |
| Manifest Calico, key của Docker và của Kubernetes không được kiểm tra; checksum binary lấy cùng nguồn | A7.4, B5.1 |
| Không có mã hoá Secret at-rest, audit log, resource reserve cho kubelet | A7.2, A7.3 |
| Task apply của Calico luôn báo `ok` khi đổi `calico_version` | B8.3 |
| `make cluster` ghi đè toàn bộ `~/.kube/config` | B9.2 |

---

## Phần A — Phỏng vấn

### A1. Tổng quan và HA

**A1.1** **Ý chính:** "Terraform dừng ở ba máy Ubuntu trần. Ansible biến chúng thành cluster kubeadm có ba control plane
ở ba AZ, sau một load balancer nội bộ. Mọi thứ chạy qua Session Manager, không SSH, không key pair."

*Nếu được hỏi thêm:*

- **Tám role:** `common`, `containerd`, `kubernetes_packages`, `ecr_credential_provider` trên cả ba node; `kubeadm_init`
  trên node 1; `kubeadm_join` cho node 2 và 3, từng node một; `cni_calico` và `untaint_control_plane`.
- **Inventory** lấy từ EC2 API theo tag; Makefile truyền DNS name của NLB từ `terraform output`.
- **Kết quả:** ba node `Ready`; kubectl trên workstation qua SSM port-forward; tắt một node thì API vẫn trả lời.
- **Chạy lại:** được viết để không đổi gì: lần hai ra `changed=0` trên cả ba node, mất 2 phút 56 giây.
- **Từ máy trần:** `make cluster` trên node mới mất 6 phút 10 giây; từ stack trống tới ba node Ready là 9 phút 57 giây
  thời gian lệnh, chưa tính khoảng chờ SSM agent đăng ký.

**A1.2** **Ý chính:** "Để control plane chịu được mất một node. Một control plane thì mất máy đó là mất API và etcd. Ba
control plane thì etcd có ba member, chịu được mất một. Chỉ có ba máy 8 GB, nên tôi bỏ taint để cả ba cùng chạy
workload."

*Nếu được hỏi thêm:* đánh đổi là workload chạy cạnh etcd và API server, nên một pod ngốn bộ nhớ có thể làm chậm control
plane (A7.3). Ở quy mô lớn hơn tôi tách worker riêng.

**A1.3** **Ý chính:** "Stacked nghĩa là etcd chạy ngay trên node control plane, dưới dạng static pod; external là một cụm
etcd riêng. Stacked cần ít máy hơn và kubeadm dựng sẵn. Đổi lại, mất một node là mất cả một API server lẫn một member etcd
cùng lúc."

*Nếu được hỏi thêm:* external etcd hợp cluster lớn, nơi etcd cần đĩa và máy riêng, hoặc muốn nâng etcd độc lập. Với ba
máy, nó cần thêm ít nhất ba máy nữa.

**A1.4** **Ý chính:** "etcd còn 2/3 member, vẫn đủ quorum, nên API tiếp tục hoạt động. Tôi đã tắt node 2: node đó chuyển
`NotReady`, `kubectl get pods -A` vẫn trả lời qua load balancer, và bật lại thì node tự về `Ready` mà không cần chạy
playbook."

*Nếu được hỏi thêm:*

- Việc node chuyển `NotReady` cũng là một lần ghi vào etcd, nên cluster vẫn ghi được, không chỉ đọc.
- NLB bỏ API server hỏng sau hai lần health check cách nhau 10 giây, tức khoảng 20 giây theo cấu hình; con số này chưa
  được đo.
- Tắt node 2 chứ không tắt node 1, vì tunnel kubectl đi qua node 1. Bài drill chứng minh được gì và không chứng minh được
  gì: B10.1.

**A1.5** **Ý chính:** "etcd chỉ còn 1/3, mất quorum. API ngừng ghi, và phần lớn lệnh đọc cũng lỗi vì cần etcd xác nhận;
controller manager và scheduler mất lease nên dừng. Pod đang chạy vẫn chạy, nhưng không có gì được lên lịch hay sửa. Bật
lại một node là quorum quay lại."

*Nếu được hỏi thêm:*

- **Không bật lại được:** dựng lại etcd từ member còn sống bằng `--force-new-cluster`, giữ dữ liệu tới lần ghi cuối, rồi
  join lại hai member mới. Snapshot là phương án sau cùng, vì mất tới 6 giờ dữ liệu.
- **Đọc vẫn được:** chỉ các request list từ watch cache của API server (`resourceVersion=0`).

**A1.6** **Ý chính:** "Vì mọi lệnh join và mọi kubeconfig đều ghi địa chỉ này. Nếu là IP của node 1, mất node 1 là mất
đường tới API dù hai API server kia vẫn sống, và thay node 1 thì phải cấu hình lại mọi thứ. Sau load balancer thì thay bất
kỳ node nào cũng không ai phải đổi gì."

*Nếu được hỏi thêm:*

- `[điền: kubelet của node control plane trỏ tới NLB hay API server local; xem server trong /etc/kubernetes/kubelet.conf]`.
- Đổi `controlPlaneEndpoint` sau khi init được nhưng tốn công: sinh lại certificate, sửa mọi kubeconfig và ConfigMap
  `cluster-info`. Tốt hơn là một tên DNS riêng như `api.<domain>` trỏ tới NLB (Terraform B5.5).

**A1.7** **Ý chính:** "Quorum là quá nửa. Ba member chịu được mất một; hai member không chịu được mất cái nào; bốn member
vẫn chỉ chịu được mất một mà mỗi lần ghi phải chờ thêm một máy. Nên số member luôn lẻ. Về vận hành, etcd rất nhạy với độ
trễ ghi đĩa, và ở đây nó dùng chung ổ gốc với image, log và workload."

*Nếu được hỏi thêm:*

- **Đĩa:** theo dõi `etcd_disk_wal_fsync_duration_seconds` p99, nên dưới khoảng 10 ms. Ổ gốc gp3 có baseline 3.000 IOPS
  (AWS B3.5), nhưng không tách riêng cho etcd.
- **Quota:** mặc định 2 GB; vượt thì etcd bật alarm `NOSPACE` và từ chối ghi. API server tự compact lịch sử, nhưng không
  defrag.
- **Defrag:** chạy từng member một, không bao giờ cả cụm cùng lúc, vì member đang defrag bị chặn.
- **Backup:** snapshot từ một member khoẻ; khôi phục phải làm trên cả ba member (common A7.2).

### A2. kubeadm bên trong

**A2.1** **Ý chính:** "Nó sinh CA và certificate, viết kubeconfig cho từng thành phần, viết manifest static pod cho etcd
và control plane, rồi start kubelet để kubelet chạy các pod đó mà không cần API. Khi API lên, nó lưu cấu hình vào cluster,
đánh dấu node là control plane, tạo bootstrap token, và cài CoreDNS với kube-proxy."

*Nếu được hỏi thêm*, các phase theo thứ tự:

1. `preflight`: kiểm tra swap, port, module kernel, runtime.
2. `certs`: CA của cluster, etcd, front-proxy; certificate cho API server với các SAN; key của service account.
3. `kubeconfig`: `admin.conf`, `super-admin.conf`, controller manager, scheduler, kubelet.
4. `etcd` và `control-plane`: manifest trong `/etc/kubernetes/manifests`.
5. `kubelet-start`, `wait-control-plane`.
6. `upload-config`: ConfigMap `kubeadm-config` và `kubelet-config`.
7. `upload-certs` (vì có `--upload-certs`), `mark-control-plane` (label và taint mà role untaint gỡ).
8. `bootstrap-token`: RBAC cho node join và ConfigMap `cluster-info`.
9. `kubelet-finalize`, `addon`: CoreDNS và kube-proxy.

Vì control plane là static pod, node bật lại thì kubelet tự chạy lại chúng (B10.2).

**A2.2** **Ý chính:** "Node mới dùng bootstrap token để đọc ConfigMap `cluster-info` công khai, và kiểm tra CA trong đó
bằng hash truyền kèm lệnh join, để không bị giả mạo. Rồi kubelet dùng token gửi yêu cầu ký certificate, được duyệt tự động
và nhận certificate client riêng. Join control plane thêm hai việc: tải certificate của CA từ Secret bằng certificate key,
và thêm một member etcd."

*Nếu được hỏi thêm:*

- **TLS bootstrap:** kubelet dùng `bootstrap-kubelet.conf` với token trong nhóm `system:bootstrappers`, gửi CSR, controller
  duyệt tự động, rồi ghi `kubelet.conf`.
- **Control plane:** sinh certificate riêng của node từ CA vừa tải, viết manifest, thêm member etcd. kubeadm mặc định thêm
  member ở dạng learner rồi mới promote, và etcd chỉ cho một learner mỗi lúc; đó là một lý do join phải tuần tự (A5.3).
- **Worker:** chỉ có discovery và TLS bootstrap, không cần certificate key, không đụng etcd.

**A2.3** **Ý chính:** "Token join được tạo riêng cho từng node và hết hạn sau 15 phút. Certificate key giải mã được
Secret `kubeadm-certs`, chứa private key của các CA, tức toàn quyền cluster, nhưng Secret đó tự xoá sau hai giờ. Chúng được
tạo ngay trong lúc chạy nên không có gì để lưu vào Vault; Vault dành cho secret tĩnh nằm trong repo."

*Nếu được hỏi thêm:*

- **Đường đi:** node 1 tạo token và certificate key; giá trị nằm trong biến `register` với `no_log`; được ghi vào
  `/root/kubeadm-join.sh` quyền 0700 trên node đang join, chạy, rồi xoá.
- **Chỗ hở tôi biết:**
  - Nội dung file đi qua bucket truyền file của SSM như mọi tham số module (A7.5).
  - Trong lúc join, lệnh kèm `--certificate-key` hiện trong danh sách process của máy (B7.7).
  - Join lỗi thì file không được xoá (B7.4).
  - `kubeadm init` tự tạo thêm một token mặc định sống 24 giờ, và output của init không có `no_log` (B6.8).
- **Nên làm:** xoá Secret `kubeadm-certs` và token của init ngay sau khi join xong.

**A2.4** **Ý chính:** "Vào node control plane bằng Session Manager, vì `kubectl` lúc này vô dụng. Xem container của
kube-apiserver và etcd bằng `crictl ps -a` và `crictl logs`, rồi log của kubelet. Thứ tự nghi vấn của tôi: etcd có sống
không, certificate có hết hạn không, manifest có bị sửa sai không, đĩa có đầy không."

*Nếu được hỏi thêm:*

- `journalctl -u kubelet`: kubelet có chạy được static pod không.
- `kubeadm certs check-expiration`; `df -h`; `timedatectl`.
- etcd: `crictl exec` vào container etcd rồi `etcdctl endpoint health` với certificate trong `/etc/kubernetes/pki/etcd`.
- Đây là lý do thật để cài `cri-tools` trên node (A4.6).

### A3. Vận hành ngày 2

**A3.1** **Ý chính:** "Gỡ member etcd của node chết trước, xoá object Node, rồi thay máy bằng Terraform và chạy lại
playbook: role join thấy máy mới chưa có manifest etcd nên join nó như một control plane. Cuối cùng kiểm tra etcd có đủ ba
member khoẻ. Riêng node 1 thì playbook hiện chưa xử lý đúng."

*Nếu được hỏi thêm:*

1. Trên một node còn sống, trong static pod etcd (lệnh như B10.4): `member list`, rồi `member remove <id>`. Không gỡ thì
   etcd coi như có ba member mà chỉ hai sống, và lần join sau thành member thứ tư.
2. `kubectl delete node medical-rag-node-2`.
3. `terraform apply -replace='aws_instance.nodes[1]'`.
4. `make cluster`; kiểm tra `member list` có ba member `started`.

**Node 1:** play init chạy trên nhóm `first_node`, với điều kiện duy nhất là máy chưa có `admin.conf`, nên máy node 1 mới
sẽ init một cluster thứ hai (B6.7). Muốn thay node 1 phải ép máy đó đi nhánh join **và** trỏ `first_control_plane` sang một
node còn sống, vì task tạo token delegate tới node 1; `make tunnel` và `make kubectl` cũng đang cố định node 1.

**A3.2** **Ý chính:** "Terraform tạo máy với cùng tag. Trong Ansible, trước hết phải sửa định nghĩa nhóm: `other_nodes`
hiện gồm mọi máy không phải node 1, nên worker mới sẽ bị join làm control plane và thêm member etcd. Sau đó thêm nhóm worker,
chạy bốn role chuẩn bị máy, rồi join không có `--control-plane`."

*Nếu được hỏi thêm:* worker cần gắn vào target group của ingress nếu nhận traffic từ NLB, không cần target group của API.
Với nhiều worker, `count` của node trong Terraform nên chuyển sang `for_each` (Terraform A3.3).

**A3.3** **Ý chính:** "Qua một cổng kiểm tra trước: chart Rancher phải chấp nhận minor đích, và minor đó nằm trong support
matrix của Rancher; nâng Rancher trước. Rồi nâng từng node một bằng `upgrade.yml`: nâng kubeadm, `kubeadm upgrade`, drain,
nâng kubelet, uncordon, chờ `Ready` và Argo CD khoẻ mới sang node tiếp."

*Nếu được hỏi thêm:*

- **Mỗi node:** nâng package kubeadm; node đầu `kubeadm upgrade apply`, các node sau `kubeadm upgrade node`; drain; nâng
  kubelet và kubectl, restart kubelet; uncordon.
- **Trước khi nâng:** snapshot etcd; đổi cả `kubernetes_minor`, vì repository của pkgs.k8s.io tách theo minor.
- **Quy tắc:** mỗi lần một minor; kubelet không được mới hơn API server.
- **Cổng kiểm tra không đạt:** giữ `1.36.4`, như thiết kế ghi.
- **Đo:** một vòng `curl` đếm request lỗi. `upgrade.yml` đã có từ phase drills (bốn play, play đầu kiểm tra trước khi
  đụng node), đã qua `--syntax-check` và `--list-hosts`, nhưng **chưa chạy**: không có bản 1.36 nào mới hơn 1.36.4, nên
  chưa có con số nào. Cách đo được: dựng ở 1.36.3 rồi nâng lên 1.36.4. Kể cả khi đo, đó mới là đường patch; câu hỏi
  này về nâng minor, cần nâng Rancher trước và đổi `kubernetes_minor`, và chưa được thử.
- Tôi cũng sẽ đối chiếu ma trận phiên bản của Calico và các addon khác, dù thiết kế chỉ gác bằng Rancher (common B6.6).

**A3.4** **Ý chính:** "Certificate của các thành phần có hạn một năm, CA có hạn mười năm. `kubeadm certs
check-expiration` cho biết ngày hết hạn. `kubeadm upgrade` tự gia hạn; nếu một năm không nâng cấp thì `kubeadm certs renew
all` trên từng control plane rồi restart các static pod."

*Nếu được hỏi thêm:*

- **Restart static pod:** kubelet không tự restart khi certificate đổi; chuyển manifest ra khỏi `/etc/kubernetes/manifests`
  vài giây rồi đưa lại.
- **kubelet:** certificate client tự rotate; certificate serving mặc định tự ký và không rotate (`serverTLSBootstrap:
  false`), nên metrics-server thường cần bật `serverTLSBootstrap` hoặc bỏ kiểm tra TLS của kubelet.
- `admin.conf` cũng được gia hạn, nên chạy lại `make cluster` để lấy kubeconfig mới về workstation.
- Lab xoá cluster hằng ngày nên chưa chạm mốc một năm; cluster chạy lâu cần alert trước ngày hết hạn.

**A3.5** **Ý chính:** "Từng node một: drain, cài bản vá, reboot, chờ node `Ready` và etcd báo khoẻ trên cả cụm, uncordon,
rồi mới sang node tiếp. Không bao giờ reboot hai control plane cùng lúc, vì đó là mất quorum. Repo hiện chưa có playbook này;
tôi sẽ viết nó theo cùng khuôn `serial: 1` với `upgrade.yml`."

*Nếu được hỏi thêm:* `hold` chỉ khoá package Kubernetes và containerd, không khoá kernel. unattended-upgrades cài bản vá
bảo mật nhưng mặc định không reboot, nên các node có thể chạy kernel khác nhau cho tới lần reboot có kiểm soát.

### A4. Xử lý sự cố

**A4.1** **Ý chính:** "`kubectl describe node` trước. Nếu là `network plugin not ready`, vấn đề nằm ở CNI: xem pod trong
`calico-system` và log của kubelet có `cni config uninitialized` không, và `/etc/cni/net.d` có file chưa. Trước khi có CNI,
CoreDNS `Pending` là bình thường."

*Nếu được hỏi thêm:*

- Pod Calico `Pending`: `kubectl describe pod` (thiếu tài nguyên, CRD hay operator lỗi). Pod Calico chịu được taint
  control-plane, nên thường không phải do taint.
- `ImagePullBackOff`: node không ra được internet (NAT).
- `calico-node` chạy mà không `Ready`: xem readiness của nó, log, và BGP nếu còn bật (A6.4).
- Operator: `kubectl -n tigera-operator logs deploy/tigera-operator`; trên node: `journalctl -u kubelet`, `crictl ps -a`.

**A4.2** **Ý chính:** "Đó là dấu hiệu của đường VXLAN giữa các node. Trên node, tôi xem interface `vxlan.calico` và route
tới dải pod của node kia, rồi `tcpdump` UDP 4789 trên network card xem gói tin có đi ra và có tới không. Hai nghi phạm hay
gặp là MTU và Calico chọn nhầm interface để lấy IP node."

*Nếu được hỏi thêm:*

- `ip -d link show vxlan.calico`, `ip route | grep vxlan`, `tcpdump -ni ens5 udp port 4789`.
- MTU: VXLAN tốn 50 byte header; gói nhỏ qua được mà gói lớn thì treo là dấu hiệu MTU.
- Log của `calico-node` (Felix), `kubectl get ippool -o yaml`.
- Security group giữa các node ở đây mở mọi protocol (Terraform B5.2), nên hiếm khi là lỗi security group.

**A4.3** **Ý chính:** "Reset riêng node đó bằng `kubeadm reset -f`, rồi kiểm tra lại danh sách member etcd từ một node
khoẻ: reset thường tự gỡ member của nó, nhưng có thể còn sót, nhất là một learner. Còn sót thì gỡ tay, nếu không lần join sau
lỗi ở bước kiểm tra etcd. Rồi chạy lại `make cluster`."

*Nếu được hỏi thêm:* reset không dọn `/etc/cni/net.d` và rule iptables, nên dọn tay. File đánh dấu join là
`manifests/etcd.yaml` chứ không phải `kubelet.conf`, để một lần join chết giữa chừng được làm lại (B7.1).

**A4.4** **Ý chính:** "Node 1 và 3 thành công, node 2 báo `TargetNotConnected`. Máy vẫn chạy và qua status check, nên tôi
tìm bằng chứng trước khi reboot. SSM không thấy máy đó, tức agent chưa từng đăng ký. Console log cho thấy agent không lấy được
credential, chuyển sang Default Host Management và bị `AccessDeniedException`, dù instance profile đã gắn. Reboot thì agent
đăng ký bình thường."

*Nếu được hỏi thêm:*

- **Giả thuyết, chưa chứng minh:** agent chạy trước khi credential của role có trong metadata service. Chưa chứng minh được
  vì hai node kia tạo cùng lúc, cùng role, vẫn bình thường.
- **Phòng ngừa đề xuất:** script boot chờ credential rồi restart agent. **Chưa thêm.** Thay vào đó
  `infra/scripts/timed-rebuild.sh` hỏi SSM có bản ghi của node không, và reboot nó một lần nếu SSM chưa từng thấy nó;
  nhánh đó chưa từng phải chạy. Lần gặp lại ngày 22/09 thì ping lại là được, nhưng lần đó không đọc bản ghi SSM và log
  console, nên không phân biệt được với sự cố ở phase này về nguyên nhân.
- **Lệnh:** `aws ssm describe-instance-information`, `aws ec2 describe-instance-status`, `aws ec2 get-console-output`.

**A4.5** **Ý chính:** "`NXDOMAIN` chứng minh pod đã tới được DNS server, vì câu trả lời đến từ `10.96.0.10`. Việc tiếp theo
là xem câu hỏi gửi đi là tên gì: `nslookup` của busybox bỏ qua danh sách `search`, nên nó hỏi đúng chữ `kubernetes.default`.
Hỏi tên đầy đủ thì trả về `10.96.0.1`."

*Nếu được hỏi thêm:* `NXDOMAIN` cũng có thể là lỗi thật, như sai `clusterDomain` hay cấu hình CoreDNS; timeout mới là dấu
hiệu không tới được server.

**A4.6** **Ý chính:** "Guide giả định `crictl` đi kèm `kubeadm`. Tôi kiểm tra: package `kubeadm` không có dòng `Depends`, và
`cri-tools` chưa được cài. Vậy role phải cài `cri-tools` riêng, ghim theo minor."

### A5. Thiết kế playbook

**A5.1** **Ý chính:** "Chạy lại trên cluster đã dựng thì không task nào được phép thay đổi gì, và PLAY RECAP phải báo
`changed=0` trên cả ba node, như lần chạy lại đã đo (2 phút 56 giây, `../evidence/ansible.md`). Mỗi role giữ điều đó bằng module so nội dung trước khi ghi, task
`command` có điều kiện hoặc `changed_when`, và file đánh dấu cho các bước kubeadm."

*Nếu được hỏi thêm:* giới hạn là các task apply của Calico đặt `changed_when: false`, nên nâng `calico_version` vẫn ra
`changed=0` (B8.3).

**A5.2** **Ý chính:** "`command` và `shell` luôn chạy và mặc định luôn báo `changed`. Tôi xử lý ba cách: kiểm tra trạng
thái trước bằng `stat` rồi dùng `when`, như `kubeadm init` chỉ chạy khi chưa có `admin.conf`; đặt `changed_when` theo output,
như untaint chỉ `changed` khi có chữ `untainted`; và dùng module có sẵn thay cho lệnh khi được."

*Nếu được hỏi thêm:* lệnh chỉ đọc như `containerd config default`, `timedatectl`, `kubectl rollout status` đặt
`changed_when: false`; `hostname`, `copy`, `dpkg_selections` là module thay cho lệnh.

**A5.3** **Ý chính:** "Chuẩn bị máy chạy song song trên cả ba node. Init chỉ chạy trên node 1. Join thì tuần tự, `serial:
1`: kubeadm join không được thiết kế để chạy song song, etcd chỉ cho một learner chưa promote mỗi lúc, và tuần tự thì lỗi
dừng sớm, dễ đọc."

**A5.4** **Ý chính:** "Chưa có `block` nào, nên chết giữa chừng thì node đó ở trạng thái dở dang: join lỗi để lại file
join chứa bí mật, và vì `serial: 1`, play dừng luôn nên node 3 không được join. Cách sửa là bọc init và join trong `block`,
`rescue` chạy `kubeadm reset` và gỡ member etcd, `always` xoá file join."

*Nếu được hỏi thêm:* nhờ file đánh dấu, chạy lại sau khi reset là đủ để hoàn tất (A4.3). Play init nên có
`any_errors_fatal`.

**A5.5** **Ý chính:** "Makefile truyền biến bằng `-e`, có độ ưu tiên cao nhất, nên thắng `group_vars`. Handler được
`flush_handlers` ngay trong role khi role sau cần thay đổi đó có hiệu lực. `delegate_to` dùng cho việc phải làm trên node
khác, như tạo token trên node 1 cho node đang join, hay ghi kubeconfig về workstation. Tag thì chưa có, nên chưa chạy riêng
được bước Calico."

*Nếu được hỏi thêm:* với task delegate, Ansible kết nối bằng biến của host được delegate, còn kết quả `register` lưu trên
host đang chạy play (B7.6).

**A5.6** **Ý chính:** "Chạy lại với cùng cấu hình là được: gần như mọi task chỉ kiểm tra rồi bỏ qua. Nguy hiểm là đổi phiên
bản rồi chạy lại, vì playbook nâng package trên cả ba node cùng lúc, không drain. Chạy lại khi có node hỏng cũng không được:
các bước chờ Calico sẽ lỗi."

*Nếu được hỏi thêm:*

- Đổi `kubernetes_apt_version` hay `containerd_version`: B4.4, B3.3.
- Sửa template kubeadm: file đổi, cluster không đổi (B6.6).
- Node đang stop: bị loại khỏi inventory, và chờ `calico-node` cùng `kubectl wait nodes --all` hết giờ (B8.8).
- Chạy lại còn ghi đè `~/.kube/config`, và apply lại Calico với `--force-conflicts` đè lên thay đổi của người khác.

**A5.7** **Ý chính:** "Chưa có test tự động như Molecule. Tôi kiểm chứng bằng chạy thật: mỗi step trong guide kết thúc bằng
một lệnh verify, chạy lần hai phải `changed=0`, và có bài drill tắt một node."

*Nếu được hỏi thêm:* sẽ thêm `ansible-lint` và `--syntax-check` trong CI; `--check --diff` hữu ích cho role cấu hình file
nhưng không nói gì về các bước kubeadm; Molecule với máy ảo tạm cho các role chuẩn bị máy.

**A5.8** **Ý chính:** "Thời gian nằm ở số lượt đi qua SSM: mỗi task một session và một lần truyền file qua S3, nhân ba node.
Tôi sẽ giảm số lượt: thu ít fact hơn, cache fact, gộp các lệnh nhỏ, và bỏ qua các bước chờ Calico khi không có gì thay đổi."

*Nếu được hỏi thêm:* `gather_subset: min` và fact cache kiểu `jsonfile`; pipelining hay Mitogen, cách tăng tốc quen thuộc
với SSH, không áp dụng cho plugin SSM `[kiểm chứng]`. Hai task apt cài containerd và package Kubernetes vẫn `update_cache`
mỗi lần chạy (B10.3).

**A5.9** **Ý chính:** "Được: không có cổng inbound, không key pair phải rotate, không bastion, và IAM quyết định ai được chạy.
Mất: chậm hơn SSH vì mỗi module đi qua một bucket S3, node phụ thuộc NAT để tới SSM, và có thêm một kiểu lỗi là SSM agent
không đăng ký được (A4.4)."

**A5.10** **Ý chính:** "Vì cluster bị xoá và dựng lại thường xuyên, và instance ID, IP đổi mỗi lần. Inventory động hỏi EC2
API theo tag mỗi lần chạy, nên không có địa chỉ nào trong Git và lần chạy sau tự tìm ra máy mới."

*Nếu được hỏi thêm:* hợp đồng giữa Terraform và Ansible là tag `k8s-cluster` và `Name`. File inventory ghi cứng region và
giá trị tag; đổi tên project bên Terraform mà quên file này thì inventory rỗng, và Ansible chỉ cảnh báo (Terraform B2.8).

**A5.11** **Ý chính:** "Để mọi node và mọi lần dựng lại giống hệt nhau, và để không một lệnh `apt upgrade` nào, do người hay
do script, đổi phiên bản dưới cluster. kubelet không được lệch minor với control plane, nên nâng cấp phải đi theo thứ tự của
`kubeadm upgrade`, từng node một."

*Nếu được hỏi thêm:*

- **Ghim ở đâu:** `inventory/group_vars/all.yml`: Kubernetes `1.36.4-1.1`, cri-tools `1.36.0-1.1`, containerd
  `2.3.5-1~ubuntu.24.04~noble`, Calico `v3.32.2`, ecr-credential-provider `v1.37.0`.
- **Muốn nâng** thì không sửa pin rồi chạy lại `site.yml` (B4.4), mà dùng `upgrade.yml` (A3.3).

### A6. Lựa chọn công nghệ

**A6.1** **Ý chính:** "Vì mục tiêu là chạm vào từng phase mà công ty tự chạy Kubernetes phải hiểu: kubeadm là công cụ chuẩn
của upstream, không giấu etcd, certificate hay quy trình nâng cấp. kops thì tự động hoá cả phần AWS mà Terraform của tôi đã
làm. RKE2 là lựa chọn rất hợp lý cho production có Rancher; tôi không chọn nó chỉ vì mục tiêu học kubeadm."

*Nếu được hỏi thêm:*

- **k3s:** rất nhẹ; một server thì mặc định SQLite, HA thì dùng etcd nhúng. Hợp edge và lab nhỏ.
- **RKE2:** control plane cũng chạy bằng static pod và etcd, có hardening theo CIS sẵn, và Rancher quản lý trực tiếp.
- Ở công ty chỉ dùng AWS, tôi mặc định chọn EKS (A8.3).

**A6.2** **Ý chính:** "Kubespray rất tốt nhưng lớn: hàng trăm task và biến cho mọi hệ điều hành, mọi CNI. Tôi muốn hiểu
từng bước kubeadm làm gì, và tám role ngắn đọc được từ đầu tới cuối. Đổi lại, tôi tự chịu những trường hợp Kubespray đã có
quy trình được cộng đồng kiểm chứng, như thay node đầu tiên."

*Nếu được hỏi thêm:* role trên Galaxy tốt xấu lẫn lộn và ít khi ghim phiên bản như cần. Ở công ty có nhiều cluster, tôi dùng
Kubespray hoặc Cluster API thay vì tự viết.

**A6.3** **Ý chính:** "Kubernetes đã bỏ dockershim; kubelet nói chuyện thẳng với containerd qua CRI, nên Docker trên node chỉ
là một daemon thừa. Tôi lấy containerd từ repository của Docker vì bản đó mới hơn bản của Ubuntu và có chuỗi phiên bản ghim
được."

*Nếu được hỏi thêm:* image build bằng BuildKit trong pod, không cần Docker trên node. containerd được `hold` để một lệnh
`apt upgrade` không restart runtime dưới cluster đang chạy.

**A6.4** **Ý chính:** "VXLAN đóng gói traffic pod trong UDP và không cần BGP: Calico tự lập route, nên bớt một thành phần
phải vận hành. VPC không biết dải IP của pod, nên routing thuần cần tắt source/destination check và thêm route cho từng node.
Cái giá của VXLAN là thêm 50 byte header, và IP pod không định tuyến được từ VPC."

*Nếu được hỏi thêm:*

- **IPIP:** cũng chạy được ở đây, vì security group giữa các node mở mọi protocol; nhưng IPIP trong Calico cần BGP để phân
  phối route. Khi siết security group theo port, VXLAN chỉ cần một rule UDP 4789.
- **Kiểm tra:** `Installation` không đặt `bgp: Disabled` tường minh `[điền: giá trị thật của spec.calicoNetwork.bgp]`.
- **AWS VPC CNI:** pod lấy IP thật của VPC, nhưng số pod mỗi node bị giới hạn theo số network interface và số IP mỗi
  interface của loại máy; prefix delegation nới giới hạn nhưng tốn IP subnet, và cần thêm quyền IAM trên role vốn dùng chung.
- **Cilium:** mạnh hơn (eBPF, observability), nhưng nặng hơn cho ba node 8 GB.

**A6.5** **Ý chính:** "Ansible lo mọi thứ bên trong máy và bản thân kubeadm; Argo CD lo mọi thứ chạy trong cluster. Calico là
ngoại lệ vì không có pod network thì node không `Ready`, CoreDNS không chạy, và Argo CD cũng không cài được."

### A7. Bảo mật

**A7.1** **Ý chính:** "`admin.conf` nằm trên node control plane, bản sao ở `/root/.kube/config` của cả ba node, và một bản
trên workstation. Nó là certificate một năm thuộc nhóm `kubeadm:cluster-admins`, được gắn quyền qua ClusterRoleBinding, nên
xoá binding là thu hồi được. `super-admin.conf` chỉ có trên node 1, thuộc `system:masters` và vượt qua RBAC, nên phải cất kỹ."

*Nếu được hỏi thêm:*

- Ai mở được SSM session kèm `sudo` trên bất kỳ node nào cũng có quyền admin cluster.
- File trên workstation quyền 0600, và workstation chỉ vào được qua SSM; nhưng file bị chép đi thì những lớp đó không còn tác
  dụng.
- **Ở công ty:** không phát certificate admin cho người; kubectl xác thực qua OIDC, quyền theo nhóm, token ngắn hạn.

**A7.2** **Ý chính:** "Chưa. Cấu hình kubeadm không có `EncryptionConfiguration`, nên Secret nằm trong etcd và trong snapshot
dạng đọc được; không có audit policy; và tôi chưa chạy kube-bench. Ổ EBS được mã hoá, nhưng đó là mã hoá ở tầng đĩa, không
bảo vệ khỏi ai đọc được etcd hay snapshot."

*Nếu được hỏi thêm:*

- **Mã hoá Secret:** thêm `--encryption-provider-config` cho API server qua `apiServer.extraArgs` và `extraVolumes`, dùng
  `aescbc` hoặc KMS v2, rồi ghi lại toàn bộ Secret để chúng được mã hoá.
- **Audit:** một audit policy ghi metadata cho Secret và toàn bộ request của người dùng.
- **kubelet** mặc định của kubeadm đã tắt anonymous auth và dùng authorization kiểu Webhook; còn `/readyz` của API server vẫn
  đọc được ẩn danh, và health check của NLB dựa vào điều đó.
- `[điền: kết quả kube-bench nếu đã chạy]`; đừng nói đã đạt CIS.

**A7.3** **Ý chính:** "Hiện chưa đủ. Không có `systemReserved`, `kubeReserved` hay ngưỡng eviction riêng cho kubelet, nên một
pod ngốn bộ nhớ có thể làm etcd và API server chậm hoặc bị OOM. Tôi sẽ thêm reserve cho kubelet, bắt request và limit cho mọi
workload, và dùng PriorityClass; ở quy mô lớn hơn thì tách worker."

**A7.4** **Ý chính:** "Package apt được kiểm tra bằng signing key của repository. Binary ecr-credential-provider có checksum,
nhưng file checksum nằm cùng chỗ với binary, nên chỉ bắt được file hỏng chứ không bắt được nguồn bị tráo. Manifest Calico tải
từ GitHub theo tag, không có checksum. Tôi sẽ siết cả ba."

*Nếu được hỏi thêm:* ghi sẵn giá trị SHA256 trong `group_vars`; kiểm tra fingerprint của signing key Docker và Kubernetes
thay vì chỉ tin HTTPS; lưu manifest Calico vào repo hoặc tải theo commit SHA kèm checksum.

**A7.5** **Ý chính:** "Mọi tham số module đi qua bucket đó, kể cả nội dung file chứa join token. Plugin xoá object sau khi
truyền; bucket còn mã hoá, chỉ nhận TLS, không versioning và tự xoá object sau một ngày, để phòng file còn sót khi một lần chạy
bị ngắt. Rủi ro còn lại là role của node đọc ghi được chính bucket này."

*Nếu được hỏi thêm:* node lấy file bằng presigned URL nên không cần quyền đó. Pod nào lấy được credential của node có thể đọc
payload đang truyền, hoặc ghi đè file module trong lúc Ansible chạy, và module đó chạy bằng root (Terraform B7.3). Cách siết:
tách bucket `ssm-transfer` ra khỏi statement S3 chung trong policy của node.

### A8. Nhìn lại

**A8.1** **Ý chính:** "Guide ban đầu giả định `crictl` đi kèm package `kubeadm`, nên bước kiểm tra báo `not found` trên cả
ba node. Sai lầm không nằm ở lệnh mà ở chỗ tôi viết một giả định về dependency mà không kiểm chứng. Từ đó mỗi thứ role cần
đều được cài riêng và ghim phiên bản, và tôi kiểm tra `dpkg -s` trước khi tin một package kéo theo package khác."

> **Mẹo:** chỉ kể chuyện thật sự xảy ra. Nếu việc chuyển Calico sang server-side apply là do từng bị từ chối thật, đó là
> một chuyện hay hơn để kể `[điền]`.

**A8.2** **Ý chính:** "Ba việc có giá trị nhất: xử lý đúng việc thay node 1 để không bao giờ init cluster thứ hai, bọc init và
join trong `block` với `rescue` và `always`, và kiểm tra biến truyền vào không rỗng. Sau đó là ghim checksum cho mọi thứ tải từ
internet."

*Nếu được hỏi thêm:* xoá token của init và Secret `kubeadm-certs` sau khi join; `no_log` cho output của init; sửa nhóm
`other_nodes`; `ansible-lint` trong CI; `changed_when` đúng cho Calico bằng `kubectl diff --server-side`; resource reserve cho
kubelet; gộp kubeconfig thay vì ghi đè.

**A8.3** **Ý chính:** "Ở công ty chỉ dùng AWS, tôi chọn EKS. Nếu buộc phải tự dựng, tôi dùng Cluster API hoặc Kubespray, bake
AMI sẵn bằng Packer để node lên nhanh và giống hệt nhau, và cho kubectl xác thực qua OIDC thay vì certificate admin."

*Nếu được hỏi thêm:* tách worker khỏi control plane; resource reserve cho kubelet và etcd; mã hoá Secret at-rest và audit log
ngay từ đầu; alert trước ngày hết hạn certificate.

---

## Phần B — Chi tiết

### B1. Inventory, kết nối và Makefile

**B1.1** Tên file phải kết thúc bằng `aws_ec2.yml` hoặc `aws_ec2.yaml`; plugin `amazon.aws.aws_ec2` chỉ nhận file có
đuôi đó.

Đặt tên khác, hoặc collection chưa được cài (`make ansible-deps`), thì Ansible chỉ in **cảnh báo** không parse được
inventory rồi chạy tiếp với `localhost` ngầm định. `site.yml` qua được assert, các play còn lại báo không có host nào, và
lệnh kết thúc với mã 0. Không phải lỗi cứng, nên phải đọc cảnh báo.

*Ở đâu:* `inventory/aws_ec2.yml`; `ansible.cfg`.

**B1.2** Plugin `aws_ec2` tự thêm một bộ lọc trạng thái mặc định khi bạn không khai báo, loại instance đã terminate
**[kiểm chứng]** trong source của `amazon.aws` 10.3.2. Vậy bỏ bộ lọc `running` thì máy **đang stop** và **đang pending**
lọt vào: task trên chúng lỗi `TargetNotConnected`.

Nếu node 1 cũ chỉ stop chứ chưa terminate trong lúc máy thay thế đã chạy, hai instance cùng tag `Name` gộp thành một host,
và host đó mang instance ID của máy được xử lý sau cùng: Ansible có thể nói chuyện với máy đã chết.

Instance đã terminate vẫn hiện khoảng một giờ trong `aws ec2 describe-instances` thô, như lệnh tìm `NODE_1` trong
Makefile; lệnh đó cũng lọc `running`.

**B1.3** Plugin SSM dùng `ansible_aws_ssm_instance_id`: nó định danh máy bằng instance ID, không bằng địa chỉ.
`ansible_host` được gán IP private chỉ để log và các lệnh kiểm tra etcd dễ đọc hơn.

*Ở đâu:* `inventory/aws_ec2.yml` (`compose`).

**B1.4** `groups` trong inventory: `first_node` là máy có tag `Name` kết thúc bằng `-node-1`, `other_nodes` là mọi máy
còn lại, `nodes` là tất cả. `group_vars/all.yml` đặt `first_control_plane: "{{ groups['first_node'] | first }}"`.

Node 1 đang stop thì bị bộ lọc `running` loại, nhóm `first_node` rỗng:

- Play init, play Calico và play ghi kubeconfig không có host nên bị bỏ qua; workstation không nhận kubeconfig mới.
- Ở role join, node đã join thì task tạo token bị bỏ qua theo `when`, không lỗi. Chỉ khi có một node thật sự cần join,
  task delegate tới `first_control_plane` mới lỗi, có thể hiện là biến không xác định hoặc host không kết nối được
  **[kiểm chứng trên ansible-core 2.16]**.
- `make tunnel` và `make kubectl` cũng hỏng, vì chúng cố định node 1.

**B1.5** Để đúng phạm vi: chỉ nhóm dùng SSM mang các biến SSM.

Comment trong `nodes.yml` nói rằng để trong `all.yml` thì task `delegate_to: localhost` cũng đi qua SSM. Điều đó chưa
chắc: `localhost` ngầm định được Ansible gán sẵn `ansible_connection: local` ở mức biến của host, cao hơn `group_vars/all`
**[kiểm chứng: `ansible localhost -m debug -a var=ansible_connection`]**. Nhưng nếu sau này `localhost` được khai báo tường
minh trong inventory, biến ở `all.yml` sẽ áp cho nó, nên để trong `nodes.yml` vẫn là cách an toàn.

**B1.6** Bucket `medical-rag-ssm-transfer-<account_id>` của stack cluster. Máy chạy Ansible upload file module bằng quyền
IAM của nó, tạo presigned URL, và node tải bằng `curl` qua S3 gateway endpoint. Nên về nguyên tắc node **không cần** quyền
S3 cho việc này.

Plugin xoá object sau khi truyền xong. Bucket không bật versioning, để object đã xoá không sống tiếp ở một version cũ,
và tự xoá object sau một ngày, để dọn file còn sót khi một lần chạy bị ngắt (A7.5).

*Ở đâu:* `inventory/group_vars/nodes.yml`; `infra/terraform/cluster/storage.tf`.

**B1.7** `amazon.aws` 11 yêu cầu `ansible-core` ≥ 2.17, còn Ubuntu 24.04 trên workstation có 2.16. `ansible-galaxy`
vẫn cài được bản 11; lúc chạy, Ansible chỉ cảnh báo collection không hỗ trợ phiên bản này, rồi có thể hỏng ở chỗ code dùng
API mới. Ghim 10.3.2 tránh tình trạng lỗi mơ hồ đó; `ansible-galaxy collection install -r requirements.yml --force` đưa lại
bản đã ghim.

**B1.8** Extra var (`-e`) có độ ưu tiên cao nhất, thắng cả `group_vars`. Truyền lại `project` và `aws_region` từ
`PROJECT` và `REGION` của Makefile nên Makefile và `all.yml` không bao giờ lệch nhau về cluster đang dựng. `aws_account_id`
chỉ có thể đến từ Makefile (`aws sts get-caller-identity`).

**Không áp dụng cho file inventory:** file đó được đọc trước khi có extra var, nên region và tag trong nó vẫn ghi cứng
(Terraform B2.8).

**B1.9** Assert chỉ kiểm tra `is defined`. Makefile luôn truyền `-e control_plane_endpoint=$(API_ENDPOINT)`; nếu
`terraform output` lỗi, biến là chuỗi rỗng nhưng vẫn được định nghĩa, nên assert cho qua. Với `aws_account_id` rỗng qua `make
cluster`, lệnh hỏng sớm hơn, ngay ở `terraform init`, vì tên bucket state cũng dùng account ID; chỉ khi chạy
`ansible-playbook` trực tiếp thì tên bucket SSM mới thành `medical-rag-ssm-transfer-` và upload đầu tiên lỗi. Sửa bằng
`control_plane_endpoint | default('') | length > 0` cho cả hai biến.

*Ở đâu:* `site.yml` play đầu tiên.

**B1.10** Nó chạy lệnh ad-hoc `ansible first_node -b -m command -a "kubectl --kubeconfig /etc/kubernetes/admin.conf
$(CMD)"`: trên node 1, qua SSM, bằng root, với `admin.conf`. Dùng trước khi có tunnel.

Module `command` không đi qua shell, nên pipe, chuyển hướng, `&&` và biến môi trường không hoạt động; dấu nháy lồng trong
`CMD` dễ vỡ; lệnh tương tác như `exec -it` không chạy được.

### B2. Role `common`

**B2.1** kubeadm đăng ký node bằng hostname của máy. Mặc định AMI đặt hostname kiểu `ip-10-10-1-23`, không nói gì về node
nào; đổi tên sau khi đã join nghĩa là xoá node khỏi cluster và join lại.

- `hostname` đặt tên theo tag `Name` (`inventory_hostname`).
- File `/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg` với `preserve_hostname: true`, để cloud-init không đặt lại tên
  sau khi stop rồi start máy. cloud-init thường tự nhận ra hostname do người dùng đổi và để yên, nhưng file này làm điều đó
  chắc chắn thay vì dựa vào hành vi mặc định. Tên bị đặt lại thì kubelet không còn khớp với object `medical-rag-node-1`.
- Dòng `127.0.1.1 <tên>` trong `/etc/hosts`, để tên mới luôn phân giải được, kể cả với công cụ không đi qua
  systemd-resolved **[kiểm chứng: lỗi `unable to resolve host` của `sudo` có thật sự xảy ra không]**.

**B2.2** `swapoff -a` chỉ chạy khi `ansible_swaptotal_mb > 0`; `replace` comment mọi dòng swap trong `/etc/fstab` để swap
không bật lại sau reboot. AMI Ubuntu không có swap, nên `swapoff` bị **skip**, và `ansible.cfg` đặt
`display_skipped_hosts = False` nên nó không hiện ra; chỉ task `replace` báo `ok`. kubelet mặc định từ chối chạy khi swap
bật.

**B2.3**

- `overlay`: containerd dùng snapshotter overlayfs cho layer của image.
- `br_netfilter` cùng `net.bridge.bridge-nf-call-iptables` và `…ip6tables = 1`: traffic đi qua bridge vẫn qua iptables,
  nơi kube-proxy đặt rule cho Service.
- `net.ipv4.ip_forward = 1`: node chuyển tiếp gói tin giữa pod và ra ngoài.

Module được ghi vào `/etc/modules-load.d/` cho mọi lần boot và `modprobe` ngay cho kernel đang chạy. Handler `sysctl
--system` bình thường chạy ở cuối play, tức sau cả role `containerd`; `flush_handlers` áp sysctl ngay, trước khi runtime
khởi động.

**B2.4** Image có thể đồng bộ giờ bằng chrony hoặc systemd-timesyncd. Kiểm tra kết quả
(`timedatectl show --property=NTPSynchronized --value` phải là `yes`) đúng với cả hai, thay vì đoán tên service. Task chờ
tối đa khoảng một phút (12 lần, cách nhau 5 giây) cho máy vừa boot. Certificate và bầu leader của etcd đều hỏng khi đồng
hồ lệch.

**B2.5**

- `lock_timeout: 300`: máy vừa boot có unattended-upgrades giữ lock dpkg một hai phút; không chờ thì lần chạy đầu lỗi vì
  lock.
- `cache_valid_time: 3600`: task apt đầu tiên chỉ chạy `apt update` nếu cache cũ hơn một giờ, nên lần chạy lại nhanh hơn.
  Trạng thái `changed` của task có danh sách package phản ánh package, không phản ánh việc cập nhật cache.

Hai task apt ở role `containerd` và `kubernetes_packages` đặt `update_cache: true` mà không có `cache_valid_time`, nên vẫn
`apt update` ở mỗi lần chạy (B10.3).

**B2.6** Hai file được systemd đọc lúc boot: `/etc/modules-load.d/kubernetes.conf` nạp `overlay` và `br_netfilter`, còn
`/etc/sysctl.d/99-kubernetes.conf` đặt lại `ip_forward` và `bridge-nf-call-iptables`. Chỉ `modprobe` và `sysctl` trên kernel
đang chạy thì node reboot sẽ mất chúng: traffic qua bridge không còn đi qua iptables, Service hỏng. Nhờ hai file này, node 2
trong bài drill chạy lại bình thường mà không cần playbook (B10.2).

### B3. Role `containerd`

**B3.1** Role chạy `containerd config default`, thay `SystemdCgroup = false` bằng `SystemdCgroup = true` bằng
`regex_replace`, rồi ghi bằng `copy`. `copy` so nội dung nên chỉ `changed` khi file thật sự khác, và báo handler restart
containerd.

Không viết template cố định vì tên và vị trí option thay đổi giữa các bản containerd (bản 2.x dùng cấu hình phiên bản 3).
Sinh từ chính binary đã ghim thì file luôn đúng với phiên bản đó.

**Bẫy:** nếu một bản sau đổi chuỗi `SystemdCgroup = false`, `regex_replace` không báo lỗi gì. Vì vậy có bước kiểm tra ở
B3.2.

**B3.2** Nếu containerd và kubelet dùng hai cgroup driver khác nhau, trên máy có hai trình quản lý cgroup cùng lúc, và
node dễ mất ổn định khi thiếu bộ nhớ.

Với Kubernetes và containerd mới, kubelet có thể tự lấy cgroup driver từ containerd qua CRI, nên hai bên khó lệch nhau hơn
**[kiểm chứng: tính năng KubeletCgroupDriverFromCRI trên 1.36]**. Rủi ro còn lại là containerd dùng `cgroupfs` thì kubelet
cũng theo `cgroupfs`, trong khi systemd vẫn quản lý cgroup của máy. Vì vậy role vẫn bảo đảm containerd dùng systemd.

Role kiểm tra bằng `containerd config dump | grep -q 'SystemdCgroup = true'`. `config dump` gộp file với mặc định, nên bắt
được option nằm sai chỗ. Nó đọc file, không đọc daemon; handler restart chạy trước đó qua `flush_handlers` là thứ làm daemon
dùng file mới, và restart lỗi thì play lỗi.

**B3.3** Không. Mỗi container chạy dưới một process `containerd-shim` riêng, và unit `containerd.service` đặt
`KillMode=process`, nên restart containerd chỉ dừng daemon, không giết shim và container.
kubelet mất kết nối CRI trong vài giây rồi nối lại.

Nhưng `apt` với `allow_change_held_packages: true` vượt qua `hold` có chủ đích, và `forks = 3` nên cả ba node restart
runtime cùng lúc. Trên cluster phục vụ thật, việc này nên đi qua `serial: 1`.

### B4. Role `kubernetes_packages`

**B4.1** pkgs.k8s.io có một repository và một signing key riêng cho mỗi minor: `core:/stable:/v1.36/deb`. Vì vậy nâng
minor nghĩa là đổi `kubernetes_minor` để trỏ sang repository mới, không chỉ đổi số phiên bản package. Cách tách này cũng
ngăn `apt upgrade` vô tình nhảy minor.

**B4.2** Package kubelet của pkgs.k8s.io thường tự bật và start service lúc cài, và trước khi kubeadm ghi
`/var/lib/kubelet/config.yaml`, kubelet restart liên tục vì chưa có cấu hình; tài liệu kubeadm ghi đó là trạng thái bình
thường **[kiểm chứng]**. Task chỉ bảo đảm `enabled`, để kubelet khởi động cùng máy sau mỗi lần reboot (B10.2); start thêm
cũng không đổi gì. kubeadm restart kubelet ở phase `kubelet-start`.

**B4.3** `crictl` chỉ là client để xem container khi kubelet hay static pod không lên. Package `kubeadm` không phụ thuộc
nó nên phải cài tường minh. Phiên bản theo minor (`1.36.0-1.1`), không theo patch. Không `hold` vì nâng nó không restart
gì cả.

**B4.4** `apt` với `allow_change_held_packages: true` cài bản mới trên **cả ba node cùng lúc** (`forks = 3`, không có
`serial`), không drain. Các static pod của control plane vẫn chạy 1.36.4 cho tới khi có người chạy `kubeadm upgrade apply`.

- **Không vỡ ngay:** chính sách lệch phiên bản tính theo minor, nên kubelet 1.36.5 với API server 1.36.4 vẫn được hỗ trợ.
- **Kubelet đang chạy có thể vẫn là bản cũ** tới lần restart kế tiếp; quy trình nâng cấp chuẩn luôn có `systemctl
  daemon-reload` và restart kubelet **[kiểm chứng]**.
- **Trôi cấu hình:** `kubernetes_version` (dùng trong kubeadm config) và `kubernetes_apt_version` là hai biến riêng, dễ lệch
  nhau.

Kết quả là một trạng thái nửa nâng cấp không có quy trình, nên đổi phiên bản phải đi qua `upgrade.yml`.

**B4.5** `get_url` không tải lại signing key, vì file đích `/etc/apt/keyrings/kubernetes.asc` đã tồn tại. `apt_repository`
với `filename: kubernetes` **thêm** dòng repository `v1.37` vào file mà không xoá dòng `v1.36`, nên máy có hai repository
song song, và key có thể không còn đúng với repository mới. Nâng minor vì vậy cần xoá dòng cũ và tải lại key có chủ đích,
việc của `upgrade.yml`.

### B5. Role `ecr_credential_provider`

**B5.1** `get_url` với `checksum: "sha256:<url>.sha256"`: Ansible tải file checksum nằm cạnh binary và từ chối cài binary
không khớp. Lần chạy sau, file đích đã có và khớp checksum nên không tải lại binary, nhưng vẫn tải file `.sha256` để so.

**Giới hạn:** checksum đến từ cùng nguồn với binary, nên nó bắt được file hỏng chứ không bắt được nguồn bị tráo (A7.4).

**B5.2** Trong `/etc/default/kubelet`: `KUBELET_EXTRA_ARGS=--image-credential-provider-bin-dir=… --image-credential-provider-config=…`.
Drop-in systemd của kubeadm đọc file này làm `EnvironmentFile`, còn cờ do kubeadm tự sinh nằm ở
`/var/lib/kubelet/kubeadm-flags.env`. Hai file khác nhau, nên `init`, `join` và nâng cấp không ghi đè cờ của mình.

**B5.3** Bốn mẫu: `*.dkr.ecr.*.amazonaws.com`, `*.dkr.ecr.*.amazonaws.com.cn`, `*.dkr.ecr-fips.*.amazonaws.com`,
`*.dkr.ecr.*.on.aws`. Mẫu cuối nhắm tới endpoint dual-stack, nhưng tên endpoint đó có thể có dạng khác **[kiểm chứng]**.

`defaultCacheDuration: "12h"` bằng đúng thời hạn của token ECR, nên sát biên: nếu plugin trả thời gian cache riêng thì
kubelet dùng giá trị đó. Plugin chạy trên host và dùng instance profile của node.

**B5.4** Trước khi có kubeadm, kubelet vốn đang restart liên tục vì chưa có cấu hình; restart thêm một lần không đổi gì.
`kubeadm init` và `join` sau đó start kubelet với cấu hình đầy đủ, và kubelet đọc luôn các cờ trong
`/etc/default/kubelet`.

### B6. Role `kubeadm_init`

**B6.1** Bằng `stat` file `/etc/kubernetes/admin.conf`: có rồi thì bỏ qua `kubeadm init`.

Nếu `kubeadm init` lỗi sau khi đã ghi `admin.conf`, lần chạy sau thấy file và bỏ qua init. Kết quả tuỳ lúc lỗi:

- API server không bao giờ lên: task chờ `/readyz` hết lượt thử và play lỗi.
- Init chết ở bước chờ control plane vì image kéo chậm, nhưng API server lên sau đó: `/readyz` trả 200 và play đi tiếp, trong
  khi các phase sau (`upload-config`, `bootstrap-token`, CoreDNS, kube-proxy) chưa bao giờ chạy. Lỗi chỉ lộ ra ở bước join,
  khi thiếu ConfigMap `cluster-info` hay `kubeadm-config`.

Cách gỡ trong cả hai trường hợp: `kubeadm reset -f` trên node 1, dọn `/etc/cni/net.d` nếu đã có, rồi chạy lại.

**B6.2** kubeadm mã hoá bằng một certificate key các **CA** của cluster: certificate và private key của CA chính,
front-proxy và etcd, cùng cặp key của service account. Kết quả lưu vào Secret `kubeadm-certs` trong `kube-system`. Secret có
ownerReference tới một bootstrap token sống hai giờ, nên bị xoá sau hai giờ. Certificate key được in ra để node join giải mã.

Vì Secret chứa private key của CA, certificate key tương đương toàn quyền cluster trong hai giờ đó.

**B6.3**

| Trường | Giá trị | Phải khớp với |
|---|---|---|
| `nodeRegistration.criSocket` | `unix:///run/containerd/containerd.sock` | Role `containerd` |
| `kubernetesVersion` | `v1.36.4` | Package ghim trong `kubernetes_packages` |
| `controlPlaneEndpoint` | `<DNS của internal NLB>:6443` | Output `api_nlb_dns` của Terraform |
| `apiServer.certSANs` | DNS của NLB, `127.0.0.1`, `localhost` | `make tunnel` và kubeconfig trên workstation |
| `networking.podSubnet` | `192.168.0.0/16` | `cidr` của IP pool trong `Installation` của Calico |
| `networking.serviceSubnet` | `10.96.0.0/12` | CoreDNS ở `10.96.0.10`, Service `kubernetes` ở `10.96.0.1` |

Cả `podSubnet` và IP pool của Calico đều lấy từ cùng biến `pod_cidr`, để không bao giờ lệch.

**B6.4** Tunnel mở ở `127.0.0.1:6443`, nên certificate phải hợp lệ cho `127.0.0.1`; `localhost` cho người gõ tên thay
vì IP. kubeadm không tự thêm hai tên này.

**Sửa trên cluster đang chạy:**

1. Thêm SAN vào template và vào ConfigMap `kubeadm-config`, để các lần join và nâng cấp sau giữ SAN mới.
2. File `/etc/kubernetes/kubeadm-config.yaml` chỉ có trên node 1. Trên node 2 và 3, lấy cấu hình từ ConfigMap:
   `kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /root/cc.yaml`.
3. Trên **từng** control plane: chuyển `apiserver.crt` và `apiserver.key` cũ đi (bắt buộc, vì kubeadm không ghi đè
   certificate đang có), chạy `kubeadm init phase certs apiserver --config <file>`, rồi restart static pod của
   kube-apiserver.

Dòng tương ứng trong bảng troubleshooting của guide Ansible đang thiếu bước 2 và 3.

**B6.5** Một lần trả 200 qua `https://<NLB>:6443/readyz` chứng minh API server của node 1 đã lên, và node 1 tới được NLB rồi
quay về chính nó (được nhờ `preserve_client_ip = false` trên target group, Terraform B6.1).

**Không chứng minh** NLB đã đánh dấu node 1 healthy: khi mọi target còn unhealthy, NLB gửi traffic tới tất cả, nên một lần
rơi đúng node 1 cũng trả 200 (Terraform B6.3). Comment trong role nói ngược lại.

`validate_certs: false` chỉ đọc `/readyz`, không gửi credential nào, nên rủi ro thấp. Nhưng nó không cần thiết: DNS name của
NLB có trong SAN, nên dùng `ca_path: /etc/kubernetes/pki/ca.crt` được.

**B6.6** Không. Task template ghi file mới trên node 1 và báo `changed`, nhưng `kubeadm init` bị bỏ qua vì `admin.conf` đã
có. Certificate không được sinh lại, và ConfigMap `kubeadm-config` mà các lần join sau đọc cũng không đổi. File trên đĩa
và cấu hình thật của cluster lệch nhau.

Thay đổi cấu hình của cluster đã có phải đi qua các phase của kubeadm hoặc `kubeadm upgrade`, như B6.4.

**B6.7** Máy mới có tag `Name` đuôi `-node-1`, nên nằm trong nhóm `first_node`, và chưa có `admin.conf`. Play init chạy
`kubeadm init`, tạo **một cluster thứ hai** sau cùng NLB.

`admin.conf` của cluster mới cũng trỏ vào NLB, mà NLB chia kết nối cho cả ba target. Node 2 và 3 trả certificate ký bởi CA
cũ, nên kubeadm và kubectl trên node mới lỗi `x509: certificate signed by unknown authority` ở phần lớn số lần. Init có thể
treo hoặc lỗi ở các phase cần API, các lệnh apply của Calico không có retry nên dễ lỗi, và play có thể dừng trước bước ghi
kubeconfig.

**Hậu quả nặng nhất:** kubelet và mọi client của cluster cũ cũng đi qua NLB; mỗi khi rơi vào API server của cluster mới,
chúng lỗi x509. Cả hai cluster hỏng chập chờn. `[điền: nếu đã thử thật]`.

**Cách tránh:** trước khi init, hỏi NLB xem cluster đã tồn tại chưa và đi theo nhánh join nếu có, kèm trỏ
`first_control_plane` sang một node còn sống (A3.1).

**B6.8** `InitConfiguration` không khai báo `bootstrapTokens`, nên `kubeadm init` tự tạo một **token mặc định sống 24 giờ**,
lâu hơn nhiều so với token 15 phút mà role join tạo. Cộng thêm certificate key, dùng được tới khi Secret `kubeadm-certs` bị
xoá sau hai giờ.

**Có thể lộ ở đâu:** output của `kubeadm init` in cả lệnh join lẫn certificate key, và task init được `register` mà không có
`no_log`. Task lỗi, hoặc chạy với `-v`, là giá trị hiện ra màn hình và log.

**Sửa:** đặt `ttl` ngắn trong `bootstrapTokens` hoặc `kubeadm token delete` sau khi join xong; thêm `no_log` cho task init.

### B7. Role `kubeadm_join`

**B7.1** File `/etc/kubernetes/manifests/etcd.yaml`. Nó chỉ xuất hiện khi máy đã được thêm vào etcd, gần cuối quá trình
join. `kubelet.conf` xuất hiện sớm hơn, ngay sau bước TLS bootstrap; dùng nó làm dấu thì một lần join chết giữa chừng bị
coi là xong và bị bỏ qua mãi, trên một node không thật sự là control plane.

Manifest etcd được ghi **sau** khi member đã được thêm. Nếu join chết đúng giữa hai bước đó, chạy lại sẽ lỗi vì member đã tồn
tại, và phải gỡ member đó trước (A4.3).

**B7.2** Trên node 1 (`delegate_to: first_control_plane`): `kubeadm token create --ttl 15m --print-join-command`. Mỗi node
đang join nhận một token riêng, hết hạn sau 15 phút.

Task chỉ chạy khi node chưa join, nên cluster đã dựng thì nó bị bỏ qua. `changed_when: false` vì token là thứ tạm thời, tự
hết hạn, không phải thay đổi lâu dài; `no_log` giữ token khỏi output.

**B7.3** `kubeadm init phase upload-certs --upload-certs` trên node 1: upload lại certificate với một certificate key mới
và in key đó ở dòng cuối, được đọc bằng `stdout_lines[-1]`.

Phải upload lại vì Secret từ lúc `init` chỉ sống hai giờ; thay một node vài ngày sau thì Secret cũ đã không còn.

**B7.4** Ghi token và certificate key vào `/root/kubeadm-join.sh` (quyền 0700) để task join không cần `no_log`. Khi join
lỗi, bạn đọc được lý do; nếu tham số nằm ngay trong task thì phải ẩn toàn bộ output.

**Nếu join lỗi:** play dừng trên node đó trước task xoá file, nên file còn lại với token (hết hạn sau 15 phút) và
certificate key (dùng được tới khi Secret `kubeadm-certs` hết hạn). Lần chạy sau ghi đè và xoá sau khi join thành công.
Cách đúng là đặt các task trong `block` và xoá file trong `always`.

**B7.5** kubeadm join không được thiết kế để chạy song song. kubeadm mặc định thêm member etcd ở dạng learner rồi mới
promote, và etcd chỉ cho một learner chưa promote mỗi lúc, nên hai lần join cùng lúc thường lỗi ở bước thêm member hoặc ở
`check-etcd` **[kiểm chứng: mặc định learner trên 1.36]**.

Với `serial: 1`, mỗi batch chỉ có một host. Node 2 join lỗi thì batch đó lỗi toàn bộ, và Ansible dừng **cả playbook**: node
3 không được join, và các play sau (Calico, kubeconfig) cũng không chạy.

**B7.6** Ansible kết nối tới **node 1**, dùng biến kết nối của host được delegate, tức `ansible_aws_ssm_instance_id` của
node 1. Kết quả `register` thì lưu trên **node 2**, host đang chạy play, nên task ghi file join ngay sau đó trên node 2 đọc
được `kubeadm_join_command` và `kubeadm_certificate_key`.

**B7.7** File chỉ giữ bí mật khỏi log của Ansible:

- Trong lúc join, tiến trình `kubeadm join … --token … --certificate-key …` hiện trong danh sách process (`/proc/<pid>/cmdline`),
  mọi user trên máy đọc được.
- Nội dung file đi qua bucket truyền file của SSM như mọi tham số module (A7.5).
- Join lỗi thì file còn lại (B7.4).

Cách tốt hơn là `kubeadm join --config` với một file `JoinConfiguration` quyền 0600 chứa token và certificate key.

### B8. Role `cni_calico` và `untaint_control_plane`

**B8.1** Apply phía client lưu cấu hình đã apply của **mỗi object** vào annotation `last-applied-configuration` của chính
object đó. Vài CRD của Calico lớn tới mức annotation vượt giới hạn tổng annotation 262144 byte, và API server báo
`metadata.annotations: Too long`. Server-side apply không dùng annotation đó, mà theo dõi ai sở hữu trường nào bằng
`managedFields`.

**B8.2** `--field-manager=ansible` đặt tên chủ sở hữu cho các trường Ansible gửi, tách với trường operator tự ghi.
`--force-conflicts` cho Ansible giành lại quyền sở hữu khi một bên khác đã ghi cùng trường, để lần chạy lại không lỗi
xung đột. Cái giá là Ansible sẽ ghi đè bất kỳ thay đổi nào của bên khác trên đúng các trường nó khai báo.

**B8.3** Apply phía server in cùng một output ở mọi lần chạy, nên không có gì để suy ra thay đổi. Vì vậy các task được đặt
`changed_when: false`. Hệ quả: nâng `calico_version` vẫn cho ra `changed=0`, nên con số đó không chứng minh Calico
không đổi. (Sửa template `installation.yaml.j2` hay `pod_cidr` thì task `template` vẫn báo `changed`.) Cách đúng là chạy `kubectl diff --server-side` trước và dùng exit code của nó.

**B8.4** Ngay sau khi apply `Installation`, cả namespace `calico-system` lẫn DaemonSet `calico-node` chưa tồn tại, và
`kubectl wait` kiểu cũ lỗi ngay khi object chưa có. Role poll `kubectl get daemonset calico-node` tối đa 5 phút, rồi mới
`rollout status`. Từ kubectl 1.31 có `kubectl wait --for=create`, làm được việc này gọn hơn.

**B8.5**

- **IP pool:** `cidr` bằng `pod_cidr`, `encapsulation: VXLAN`, `natOutgoing: Enabled`, `nodeSelector: all()`.
- **`natOutgoing`:** VPC không biết dải IP của pod, nên traffic từ pod ra ngoài dải pod được SNAT về IP của node.
- **Cố ý bỏ:** file mẫu của Calico còn tạo API server của Calico, thành phần gom flow log và giao diện web; trên node 8 GB,
  bộ nhớ đó dành cho workload.

Lý do chọn VXLAN: A6.4.

**B8.6** `kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-`. Khi taint đã không còn, kubectl
thoát với mã khác 0 và báo `not found`: `failed_when` coi đó là trạng thái mong muốn, không phải lỗi. Task chỉ `changed`
khi output có chữ `untainted`. Điểm yếu: cách này phụ thuộc vào đúng câu chữ của kubectl.

**B8.7** Khi `until` hết lượt thử, Ansible đánh dấu task **lỗi** bất kể `failed_when: false` **[kiểm chứng trên
ansible-core 2.16]**. Play dừng với thông báo chung chung về số lần thử, và task assert "Say something useful" ngay sau không
bao giờ chạy. Cách sửa: dùng `kubectl wait --for=create --timeout=300s`, hoặc đặt cả hai trong `block` với `rescue` in thông
báo hữu ích.

**B8.8** Node stop bị loại khỏi inventory, nhưng nó vẫn là một Node trong cluster. Ở role `cni_calico`:

- `kubectl rollout status ds/calico-node --timeout=600s` chờ 10 phút rồi lỗi, vì pod `calico-node` trên node chết không bao
  giờ available.
- `kubectl wait --for=condition=Ready nodes --all` cũng lỗi.

Vì vậy playbook không dùng để sửa được một cluster đang suy giảm; phải đưa node về, hoặc gỡ nó khỏi cluster trước.

### B9. Kubeconfig trên workstation

**B9.1**

1. `slurp` đọc `admin.conf` trên node 1 bằng root, trả về dạng base64.
2. `file` với `delegate_to: localhost` và `become: false` tạo `~/.kube` quyền 0700 trên workstation (`copy` không tự tạo
   thư mục cha).
3. `copy` với `content` đã `b64decode` và sửa dòng `server:`, ghi ra `~/.kube/config` quyền 0600.

`lookup('env', 'HOME')` chạy trên máy điều khiển, nên trỏ đúng home của workstation.

**B9.2** `admin.conf` trỏ tới `https://<DNS internal NLB>:6443`, mà workstation nằm ở VPC khác, không tới được NLB nội
bộ. `regex_replace` đổi thành `https://127.0.0.1:6443`, đầu bên này của tunnel.

Chạy lại `make cluster` **ghi đè toàn bộ** `~/.kube/config`: mọi context khác trong file mất. Cách tốt hơn là ghi ra file
riêng và gộp bằng `KUBECONFIG`.

**B9.3** `NODE_1` là kết quả `aws ec2 describe-instances` lọc tag `Name=medical-rag-node-1` và trạng thái `running`.
`make tunnel` chạy `aws ssm start-session` với document `AWS-StartPortForwardingSessionToRemoteHost`,
`host=<DNS NLB>`, `portNumber=6443`, `localPortNumber=6443`.

Tunnel chỉ sống khi cửa sổ đó mở. Đóng cửa sổ, hoặc session hết hạn, thì không còn gì lắng nghe ở `127.0.0.1:6443`, nên
kubectl báo `connection refused`. Node 1 đang stop cũng cho cùng lỗi.

**B9.4**

- `slurp` trả nội dung `admin.conf`, gồm private key admin, về máy điều khiển qua output của SSM, không có `no_log`.
- `copy` với `content:` chạy kèm `--diff` sẽ in toàn bộ file ra màn hình.
- File cuối cùng nằm ở `~/.kube/config` quyền 0600, với certificate client một năm.

### B10. Evidence và HA drill

**B10.1** **Chứng minh được:** mất một control plane thì API vẫn trả lời qua NLB (etcd còn quorum 2/3, NLB bỏ target
hỏng), controller vẫn ghi được trạng thái `NotReady` của node, và node bật lại tự về `Ready`.

**Không chứng minh được:**

- Mất cả một AZ: NAT gateway duy nhất nằm ở AZ đầu tiên (Terraform A1.11).
- Mất node 1: tunnel kubectl đi qua node 1, nên bài drill cố ý tránh nó.
- App HA: chưa có app nào chạy lúc drill.
- Sự cố đột ngột: `stop-instances` là tắt máy có trật tự, không giống máy chết giữa chừng.
- Thời gian chuyển đổi: không được đo.

**B10.2**

- containerd và kubelet được `enabled`, nên khởi động cùng máy.
- Manifest của etcd, API server, controller manager và scheduler nằm sẵn trong `/etc/kubernetes/manifests`; kubelet chạy
  lại chúng.
- Dữ liệu etcd nằm trên ổ EBS gốc, được giữ nguyên khi stop và start.
- IP private chính của instance không đổi khi stop và start, nên peer URL của etcd vẫn đúng.
- Hostname được giữ nhờ `preserve_hostname` (B2.1), nên kubelet vẫn đăng ký đúng tên node.
- Module kernel và sysctl được nạp lại lúc boot từ file cấu hình (B2.6).
- NLB theo dõi target bằng instance ID, nên tự đánh dấu healthy lại.

**B10.3** Trên cluster đã có, gần như mọi task kiểm tra rồi bỏ qua, nhưng vẫn tốn thời gian: mỗi task là một session SSM
và một lần truyền file qua S3, nhân với ba node. Cộng thêm các bước chờ không đổi gì như `rollout status` của Calico, chờ
`/readyz`, kiểm tra đồng hồ, hai lần `apt update` mỗi node (B2.5), và `terraform init` mà target `cluster` phụ thuộc.
Con số dựng từ máy trần thì lớn hơn: 6 phút 10 giây cho `make cluster` trên node mới, so với 2 phút 56 giây khi chạy lại.

**B10.4** Lệnh, viết trên **một dòng** (tách dòng thì `make` chạy sai):

```
make kubectl CMD="exec -n kube-system etcd-medical-rag-node-1 -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list -w table"
```

- **Khoẻ:** ba dòng, `STATUS` là `started`, tên trùng tên ba node, peer URL là IP private của node cổng 2380, client URL cổng
  2379, `IS LEARNER` là `false`. Một learner còn sót là dấu hiệu join dở dang.
- **Leader:** `member list` không cho biết; dùng `endpoint status --cluster -w table`, cột `IS LEADER`, cùng raft term và
  kích thước DB của từng member.
- `healthcheck-client.crt` là certificate client đúng chuẩn cho việc này; `server.crt` cũng dùng được vì có quyền client.
- `[điền: bảng thật]`.
