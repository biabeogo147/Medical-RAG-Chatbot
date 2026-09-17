# Câu hỏi về Ansible

Bộ câu hỏi về phần Ansible của project: biến ba máy EC2 trần thành cluster kubeadm HA, qua Session Manager, không SSH.
Dùng để tự kiểm tra mức hiểu và luyện phỏng vấn. Đáp án nằm ở [`answers.md`](answers.md), cùng số thứ tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Phỏng vấn** (ưu tiên) | Bạn giải thích được vì sao dựng cluster theo cách này, vận hành nó ra sao, và giới hạn của nó |
| **B. Chi tiết** | Bạn biết vì sao từng task được viết như vậy, và đổi đi thì cái gì hỏng |

Bộ liên quan: [tổng quan project](../common/questions.md), [Terraform](../terraform/questions.md),
[AWS](../aws/questions.md). Tham chiếu dạng `Terraform A3.1` trỏ tới bộ tương ứng.

**Cách dùng.** Làm Phần A trước: trả lời thành tiếng, khoảng một phút mỗi câu, rồi so với đáp án. Phần B làm không
mở code; chỉ tính là đã hiểu khi bạn nói được *lý do*. Trong mỗi nhóm, câu hỏi khó dần về cuối.

---

## Phần A — Phỏng vấn

### A1. Tổng quan và HA

**A1.1** Trình bày phần Ansible của project trong một phút.

**A1.2** Vì sao cả ba node đều là control plane, thay vì một control plane và hai worker?

**A1.3** Stacked etcd và external etcd khác nhau thế nào? Vì sao chọn stacked?

**A1.4** Mất một node thì sao? Bạn đã kiểm chứng thế nào?

**A1.5** Mất hai trong ba node thì sao, và khôi phục thế nào?

**A1.6** Vì sao `controlPlaneEndpoint` là DNS name của load balancer? Nếu dùng IP của node 1 thì sao?

**A1.7** Vì sao etcd có 3 member chứ không phải 2 hay 4? Vận hành etcd cần để ý đĩa, quota và defrag thế nào?

### A2. kubeadm bên trong

**A2.1** `kubeadm init` làm gì, từng phase một?

**A2.2** `kubeadm join` làm gì? TLS bootstrap và CA cert hash để làm gì, và join thêm control plane khác join worker ở đâu?

**A2.3** Join token và certificate key là bí mật. Chúng đi qua đâu, sống bao lâu? Sao không dùng Ansible Vault?

**A2.4** API server không trả lời và không có SSH. Bạn debug thế nào?

### A3. Vận hành ngày 2

**A3.1** Một node control plane chết hẳn. Thay nó thế nào?

**A3.2** Muốn thêm một worker node thì làm gì?

**A3.3** Nâng cấp Kubernetes lên minor mới thế nào?

**A3.4** Certificate do kubeadm tạo hết hạn khi nào, và bạn xử lý ra sao?

**A3.5** Vá hệ điều hành hoặc nâng kernel cho ba control plane mà không downtime thế nào?

### A4. Xử lý sự cố

**A4.1** Sau khi cài xong, các node vẫn `NotReady`. Bạn tìm ở đâu?

**A4.2** Pod cùng node gọi nhau được, khác node thì không. Tìm lỗi thế nào?

**A4.3** `kubeadm join` lỗi giữa chừng. Bạn đưa node đó về trạng thái chạy lại được thế nào?

**A4.4** Kể về sự cố `TargetNotConnected` trên node 2 và cách bạn tìm nguyên nhân.

**A4.5** Kiểm tra DNS trong pod trả `NXDOMAIN`. Đó có phải lỗi DNS không?

**A4.6** Guide báo `crictl: not found`. Bạn tìm ra nguyên nhân thế nào?

### A5. Thiết kế playbook

**A5.1** Playbook "idempotent" nghĩa là gì trong project này, và bạn chứng minh điều đó thế nào?

**A5.2** Module `command` và `shell` phá idempotency thế nào? Bạn xử lý ra sao?

**A5.3** Playbook chạy song song ở đâu, tuần tự ở đâu, và vì sao?

**A5.4** Playbook chết giữa chừng thì cluster ở trạng thái nào? Bạn có dùng `block` và `rescue` không?

**A5.5** Thứ tự ưu tiên biến, handler, `delegate_to` và tag được dùng thế nào trong project?

**A5.6** Có thể chạy `make cluster` lại trên một cluster đang phục vụ không? Thay đổi nào là nguy hiểm?

**A5.7** Bạn test playbook thế nào?

**A5.8** Chạy lại mà không đổi gì vẫn mất gần 3 phút. Làm sao nhanh hơn khi đi qua SSM?

**A5.9** Ansible chạy qua Session Manager thay vì SSH. Được gì, mất gì?

**A5.10** Vì sao inventory lấy từ EC2 API mỗi lần chạy, mà không dùng một file hosts?

**A5.11** Vì sao ghim chính xác phiên bản và `hold` package? Muốn nâng thì làm thế nào?

### A6. Lựa chọn công nghệ

**A6.1** Vì sao dựng cluster bằng kubeadm, mà không dùng k3s, RKE2 hay kops?

**A6.2** Vì sao tự viết role, mà không dùng Kubespray hay role có sẵn trên Galaxy?

**A6.3** Vì sao containerd mà không phải Docker, và vì sao lấy containerd từ repository của Docker?

**A6.4** Vì sao Calico chạy VXLAN, mà không dùng IPIP, routing thuần, Cilium hay AWS VPC CNI?

**A6.5** Ansible và Argo CD chia ranh giới thế nào? Vì sao Calico lại do Ansible cài?

### A7. Bảo mật

**A7.1** Ai có quyền admin cluster? Các file kubeconfig admin nằm ở đâu, và thu hồi quyền thế nào?

**A7.2** Secret trong etcd có được mã hoá không? Có audit log không? Cluster đã được kiểm tra theo CIS chưa?

**A7.3** Workload chạy ngay cạnh etcd và API server. Bạn bảo vệ control plane bằng gì?

**A7.4** Playbook tải binary và manifest từ internet. Bạn đảm bảo chúng không bị tráo thế nào?

**A7.5** Module Ansible đi qua bucket S3 của SSM. Cách đó có rủi ro gì, và được giảm thế nào?

### A8. Nhìn lại

**A8.1** Kể một quyết định kỹ thuật trong phần Ansible mà bạn phải làm lại.

**A8.2** Nếu có thêm một tuần, bạn sẽ sửa gì trong phần Ansible?

**A8.3** Ở công ty, bạn sẽ dựng và vận hành cluster khác đi thế nào?

---

## Phần B — Chi tiết

### B1. Inventory, kết nối và Makefile

**B1.1** File inventory phải đặt tên thế nào, và vì sao?

**B1.2** Inventory lọc `instance-state-name: running`. Bỏ bộ lọc đó thì những máy nào lọt vào inventory, và
chuyện gì xảy ra?

**B1.3** `compose` đặt cả `ansible_aws_ssm_instance_id` lẫn `ansible_host`. Cái nào dùng để kết nối, và cái kia để
làm gì?

**B1.4** Nhóm `first_node` được tạo thế nào? Nếu node 1 đang stop thì play nào hỏng, và hỏng ra sao?

**B1.5** Vì sao các biến kết nối nằm trong `group_vars/nodes.yml` chứ không phải `all.yml`?

**B1.6** Module Ansible tới node qua bucket nào? Node có cần quyền S3 không, và vì sao bucket không bật versioning?

**B1.7** Vì sao collection `amazon.aws` ghim ở 10.3.2?

**B1.8** Makefile truyền `project`, `aws_region`, `aws_account_id` và `control_plane_endpoint` bằng `-e`. Vì sao
truyền cả hai biến đã có trong `all.yml`, và biến `-e` thắng ở đâu?

**B1.9** Assert ở đầu `site.yml` bỏ sót trường hợp nào?

**B1.10** `make kubectl CMD="…"` chạy lệnh ở đâu, với kubeconfig nào, và lệnh nào không chạy được qua nó?

### B2. Role `common`

**B2.1** Vì sao phải đặt hostname trước khi chạy kubeadm? Ba task về hostname mỗi cái để làm gì?

**B2.2** Swap được tắt thế nào? Vì sao task tắt swap thường không hiện ra trong output?

**B2.3** Hai kernel module và ba sysctl để làm gì? Vì sao role gọi `flush_handlers` ở cuối?

**B2.4** Kiểm tra đồng hồ bằng `timedatectl` thay vì kiểm tra service chrony. Vì sao?

**B2.5** `lock_timeout: 300` và `cache_valid_time: 3600` giải quyết chuyện gì?

**B2.6** Sau khi node reboot, cái gì bảo đảm module kernel và sysctl của Kubernetes vẫn còn?

### B3. Role `containerd`

**B3.1** File `config.toml` được tạo thế nào? Vì sao không viết sẵn một file template?

**B3.2** Nếu containerd và kubelet dùng hai cgroup driver khác nhau thì sao? Role kiểm tra điều đó thế nào?

**B3.3** Đổi `containerd_version` rồi chạy lại trên cluster đang chạy. Các container đang chạy có bị dừng không?

### B4. Role `kubernetes_packages`

**B4.1** Vì sao URL của repository và signing key chứa minor version?

**B4.2** Vì sao kubelet được `enabled` nhưng không được `started` trong role này?

**B4.3** Vì sao `cri-tools` được cài tường minh nhưng không bị `hold`?

**B4.4** Đổi `kubernetes_apt_version` sang bản patch mới rồi `make cluster`. Chuyện gì xảy ra với cả ba node?

**B4.5** Đổi `kubernetes_minor` từ `v1.36` sang `v1.37` rồi chạy lại role. Repository và signing key trên node
ra sao?

### B5. Role `ecr_credential_provider`

**B5.1** Binary được tải và kiểm tra thế nào? Lần chạy thứ hai có tải lại không?

**B5.2** Cờ của kubelet được đặt ở đâu, và vì sao chúng sống sót qua `kubeadm init`, `join` và nâng cấp?

**B5.3** File cấu hình của plugin khớp những image nào, và token được cache bao lâu?

**B5.4** Handler restart kubelet chạy trước khi có kubeadm. Vì sao chuyện đó vô hại?

### B6. Role `kubeadm_init`

**B6.1** Role biết cluster đã được tạo bằng cách nào? Nếu `kubeadm init` lỗi sau khi đã ghi `admin.conf` thì sao?

**B6.2** `--upload-certs` làm gì, và bí mật đó sống bao lâu?

**B6.3** Kể các giá trị trong `kubeadm-config.yaml`. Giá trị nào phải khớp với role khác?

**B6.4** Vì sao `certSANs` có cả `127.0.0.1` và `localhost`? Nếu thiếu thì sửa trên cluster đang chạy thế nào?

**B6.5** Task chờ `/readyz` qua load balancer chứng minh được những gì, và không chứng minh được gì? `validate_certs:
false` có cần thiết không?

**B6.6** Sửa `kubeadm-config.yaml.j2` (ví dụ thêm một SAN) rồi chạy lại `make cluster`. Cluster có nhận thay đổi đó
không?

**B6.7** Node 1 chết hẳn và được thay bằng một máy mới cùng tên. Chạy `make cluster` thì chuyện gì xảy ra?

**B6.8** Sau `kubeadm init`, bí mật nào sống lâu hơn 15 phút, và nó có thể lộ ở đâu?

### B7. Role `kubeadm_join`

**B7.1** Role đánh dấu "đã join" bằng file nào? Vì sao không dùng `kubelet.conf`?

**B7.2** Token được tạo ở đâu, bao lâu hết hạn, và vì sao task tạo token báo `changed_when: false`?

**B7.3** Certificate key được lấy thế nào, và vì sao phải upload certificate lại cho mỗi lần join?

**B7.4** Vì sao lệnh join được ghi ra file thay vì chạy thẳng? Nếu join lỗi thì file đó ra sao?

**B7.5** Vì sao play join có `serial: 1`? Nếu node 2 join lỗi thì node 3 có được join không?

**B7.6** Task tạo token chạy cho node 2 nhưng `delegate_to` node 1. Ansible kết nối tới máy nào, và kết quả
`register` được lưu ở host nào?

**B7.7** Lệnh join được ghi ra file để không lộ trong log. Nó còn lộ ở đâu trên máy?

### B8. Role `cni_calico` và `untaint_control_plane`

**B8.1** Vì sao mọi lệnh apply của Calico đều `--server-side`?

**B8.2** `--field-manager=ansible` và `--force-conflicts` để làm gì?

**B8.3** Các task apply của Calico đều `changed_when: false`. Hệ quả với con số `changed=0` là gì?

**B8.4** Vì sao chờ DaemonSet `calico-node` bằng vòng poll `kubectl get` thay vì `kubectl wait`?

**B8.5** Resource `Installation` cấu hình những gì, và cố ý bỏ những gì so với file mẫu của Calico?

**B8.6** `untaint_control_plane` xử lý lần chạy thứ hai thế nào, khi taint đã không còn?

**B8.7** Task chờ DaemonSet `calico-node` có `until` và `failed_when: false`. Hết lượt thử thì chuyện gì
xảy ra, và task assert ngay sau nó có chạy không?

**B8.8** Chạy `make cluster` khi một node đang stop. Play nào lỗi, và vì sao?

### B9. Kubeconfig trên workstation

**B9.1** Play cuối lấy `admin.conf` về workstation bằng những kỹ thuật nào?

**B9.2** Vì sao phải sửa dòng `server:` trong kubeconfig? Chạy lại `make cluster` ảnh hưởng gì tới `~/.kube/config`?

**B9.3** `make tunnel` tìm node 1 thế nào, và vì sao kubectl lỗi `connection refused` khi đóng cửa sổ tunnel?

**B9.4** Trên đường từ node 1 về workstation, nội dung `admin.conf` có thể lộ ở đâu?

### B10. Evidence và HA drill

**B10.1** Bài drill HA chứng minh được gì, và không chứng minh được gì?

**B10.2** Node 2 được bật lại và tự về `Ready` mà không chạy playbook. Những gì trên máy làm điều đó xảy ra?

**B10.3** `make cluster` chạy lại trên cluster đã có mất 2 phút 59 giây. Vì sao con số đó không phải thời gian dựng
cluster, và thời gian đó đi đâu?

**B10.4** Đọc bảng member etcd thế nào để biết etcd khoẻ, và làm sao biết member nào là leader?
