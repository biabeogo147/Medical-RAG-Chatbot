# Đáp án Argo CD và GitOps

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Phần A mở đầu bằng **Ý chính**: câu nói thành tiếng, ngôi thứ
nhất, thường là đủ. *Nếu được hỏi thêm* dùng khi người phỏng vấn đào sâu; tham chiếu như `(B2.1)` là để bạn tra, không đọc
ra. Dòng **Mẹo** là lời nhắc cho bạn, không nói ra. Đường dẫn tính từ `deploy/argocd/`, trừ khi ghi khác. Tham chiếu dạng
`Common A2.3` trỏ tới [`../common/answers.md`](../common/answers.md), tương tự với `Terraform`, `Ansible`,
`AWS` và `Jenkins`.

Chỗ `[điền: …]` là số liệu hoặc kiểm tra phải lấy từ lần chạy thật; đừng nói điều chưa đo. Ghi chú **[kiểm chứng]** là hành
vi của công cụ cần xác nhận (trên cluster hoặc trong tài liệu chính thức) trước khi nói chắc.

**Số liệu đã có** ([`docs/evidence/gitops.md`](../evidence/gitops.md)):

- **Phiên bản:** chart `argo-cd` 10.9.2 (Argo CD v3.5.3), ingress-nginx 4.15.1, aws-ebs-csi-driver 2.66.0, external-secrets
  2.10.0, cert-manager v1.21.2, kube-prometheus-stack 91.4.1, Rancher 2.15.1.
- **Dựng lại từ cluster stack trống (18/09):** `make infra` 4 m 45 s, `make cluster` 6 m 11 s, `make bootstrap` 52 s, rồi
  2 m 22 s để `root` chuyển `Healthy`. Tổng **14 m 11 s thời gian chạy lệnh** (cộng từ giá trị `real` chính xác); khoảng chờ
  giữa các lệnh không được đo. Lần đó health check còn là bản cũ, chỉ đọc health, nên các wave không chờ nhau thật và con số
  có thể thấp hơn thực tế (A7.2). Lần dựng lại 19/09 với check đã sửa không được đo thời gian.
- **Sự cố 18/09:** lần dựng lại đó xin một certificate mới. Suy ra từ event, cert-manager xử lý `Certificate` khi chưa có
  Secret, sớm hơn Secret khôi phục ít nhất ~48 s.
- **Dựng lại 19/09, sau khi sửa health check:** Secret khôi phục có trước `Certificate` 3 s (thật ra 2–4 s), `status.revision`
  rỗng, không có `CertificateRequest` nào. Certificate đang phục vụ do `YR1` của Let's Encrypt ký, fingerprint trùng với
  `AWSCURRENT` trong Secrets Manager. **Không cấp certificate nào.**
- **UI qua VPN:** người vận hành báo đã mở được Argo CD, Rancher và Grafana qua WireGuard; chưa có ảnh chụp.

**Cần điền hoặc xác nhận** (mục "Still to record" của evidence):

- Bảng `make apps`: chín Application cộng `root`, tất cả `Synced` và `Healthy`, kèm ảnh chụp UI (B7.4).
- `AGE` và số restart của pod Argo CD trước và sau khi Application `argocd` tiếp quản (A2.2).
- Thời gian dựng lại với health check đã sửa (A7.2).
- Laptop không có VPN thì UI timeout, có VPN thì `200` (A6.1).
- Target `kube-etcd`, `kube-scheduler`, `kube-controller-manager`, `kube-proxy` đều `up`; email alert thử (A7.1).
- `time make down` và `describe-volumes` rỗng sau đó (A7.3).
- `kubectl top` của các component, để thay các con số "chưa đo" trong values (A7.5).

**Nếu bạn sửa code trước khi nộp CV, sửa cả đáp án:** các đáp án dưới đây mô tả đúng code hiện tại, kể cả điểm yếu đã biết.

| Điểm yếu trong code | Câu liên quan |
|---|---|
| Chỉ có tài khoản `admin`, không SSO, không RBAC; mọi Application dùng AppProject `default` | A6.2, A6.3, A9.2 |
| Notifications tắt, và Prometheus chưa scrape metric của Argo CD: sync lỗi không báo cho ai | A7.1, A9.1 |
| Health check để `root` chờ im lặng khi một Application con `Healthy` mà `OutOfSync`, hoặc `Suspended`; nhánh `Degraded` và nhánh "không có resource" chưa chạy thật lần nào | A3.7, B2.4 |
| Retry chỉ là mặc định ngầm (automated sync tự dùng `limit: 5`), không ghi trong file nào | B1.8 |
| Mỗi component của Argo CD chạy một replica; request và limit là điểm xuất phát, chưa đo | A7.5, A9.2 |
| Polling 3 phút, không webhook | A4.4 |
| Mọi pod dùng chung IAM role của node, gồm cả quyền ghi bản backup certificate và hai managed policy phạm vi cả account | A5.2, A6.4 |
| ingress-nginx đã ngừng phát triển (tháng 3/2026) | A7.6, A9.1 |
| Thiết kế §8 liệt kê `make up` và `make cost`, nhưng Makefile chưa có | A7.2 |

---

## Phần A — Phỏng vấn

### A1. Tổng quan và lựa chọn

**A1.1** **Ý chính:** "Terraform dựng máy, Ansible dựng cluster. Từ đó trở đi, mọi thứ chạy trong cluster do Argo CD cài từ
thư mục `deploy/argocd/` trong Git: chính Argo CD, ingress-nginx, EBS CSI driver, External Secrets, cert-manager, monitoring
với Alertmanager cấu hình gửi email, và Rancher. Tôi chỉ cài Argo CD bằng tay đúng một lần qua `make bootstrap`; sau đó nó tự
quản lý chính nó, và muốn đổi gì thì commit. Dựng lại từ lúc stack cluster bị xoá hẳn, chỉ giữ stack shared và bootstrap
(secret, DNS zone, ECR, bucket state), tới khi `root` `Healthy` mất 14 phút 11 giây thời gian chạy lệnh."

*Nếu được hỏi thêm:*

- **Cấu trúc:** app-of-apps. `root` tạo chín Application, chia bốn sync wave để thứ tự khởi động là đúng (A3.4).
- **Secret:** Git chỉ chứa *tên*, giá trị nằm trong Secrets Manager, External Secrets chép vào cluster (A5.1).
- **Certificate:** một wildcard Let's Encrypt qua DNS-01. Nó được backup vào Secrets Manager và khôi phục khi dựng lại, để
  không tốn hạn mức 5 certificate/tuần (A5.5). Lần dựng lại 19/09 không cấp certificate nào.
- **Truy cập:** mọi UI nội bộ chỉ mở qua WireGuard (A6.1).
- **Teardown:** `make down` dọn EBS volume do cluster tạo ra trước khi Terraform xoá máy (A7.3).

**Mẹo:** kết bằng một câu về sự cố ở A8.1. Đó là phần người phỏng vấn nhớ nhất.

**A1.2** **Ý chính:** "Với tôi GitOps là: trạng thái mong muốn của cluster nằm trong Git, và một agent *bên trong* cluster
liên tục kéo về, so sánh và sửa cho khớp. Khác pipeline chạy `helm upgrade` ở ba điểm: pipeline CI không cần credential vào
cluster; sai lệch được phát hiện và sửa liên tục chứ không chỉ lúc deploy; và `git log` là lịch sử thay đổi, `git revert` là
rollback."

*Nếu được hỏi thêm:*

- Bảng so sánh push/pull ở `Jenkins A2.1`.
- Một pipeline `helm upgrade` chạy một lần rồi thôi. Nếu ai đó sửa tay sau đó, không ai biết. Argo CD thì báo `OutOfSync`
  và với `selfHeal` sẽ đưa về đúng Git (A4.2).
- **Giới hạn:** Git là trạng thái *mong muốn*. Git ghi `Synced` không có nghĩa là app đang chạy tốt; phải nhìn health, và
  monitoring (A7.1).

**A1.3** **Ý chính:** "Cả hai đều là dự án graduated của CNCF và đều làm được việc này. Tôi chọn Argo CD vì ba lý do: UI cho
thấy cây resource, diff và health, rất có ích khi chỉ có một người vận hành và khi demo; app-of-apps với sync wave là một mô
hình rõ ràng; và theo tôi thấy nó phổ biến hơn trong các tin tuyển dụng tôi nhắm tới. Cái giá là: Flux có `dependsOn` chờ
readiness sẵn, còn ở Argo CD tôi phải tự viết lại health check cho Application."

*Nếu được hỏi thêm:*

- **Flux dùng Helm SDK thật:** `helm list` thấy release, Helm hook và hàm `lookup` chạy đúng. Argo CD chỉ `helm template`
  rồi apply, nên không có Helm release. Hook của Helm được dịch sang hook của Argo CD, còn `lookup` không đọc được cluster.
- **Argo CD nặng hơn:** năm component, tổng request khoảng 475m CPU và 1 GiB RAM trong values của tôi (A7.5).
- Tôi sẽ không nói Flux kém hơn. Với một team thích CLI và Kustomize, Flux gọn hơn.

**A1.4** **Ý chính:** "Argo CD sở hữu mọi thứ chạy *trong* cluster, kể cả chính nó. Nó cố ý không làm ba việc: không tạo
resource AWS nào, không giữ giá trị secret nào, và không có quyền ghi vào Git."

*Nếu được hỏi thêm:*

- **AWS:** load balancer, target group, tên DNS, quyền IAM và *tên* secret đều do Terraform tạo trước. Ba thứ trong cluster
  gọi AWS, đều trong phạm vi quyền Terraform cấp: EBS CSI driver tạo volume, cert-manager tạo một bản ghi TXT tạm, External
  Secrets đọc Secrets Manager và PushSecret ghi đúng một secret backup. Ngoài volume, không cái nào tạo resource AWS mới.
- **Secret:** Git có tên, Secrets Manager có giá trị (A5.1).
- **Git:** repo public, Argo CD đọc ẩn danh (A1.7).
- **Ranh giới với Ansible:** Calico do Ansible cài, vì pod network phải có trước khi bất kỳ pod nào chạy, kể cả Argo CD
  (`Ansible A6.5`). Ranh giới giữa các công cụ: `Common A2.3`.

**A1.5** **Ý chính:** "Trong Git tôi chỉ muốn giữ những gì mình *quyết định*: một version chart và một file values vài chục
dòng. Argo CD tự render chart. Nâng cấp là sửa một dòng, và diff trong pull request đọc được. Render sẵn rồi commit thì Git
đầy hàng nghìn dòng YAML sinh ra; review không ai đọc nổi, và sớm muộn sẽ có người sửa tay vào file sinh ra."

*Nếu được hỏi thêm:*

- **Kustomize:** tôi không dùng. `platform-secrets` và `platform-tls` là thư mục YAML thuần, Argo CD đọc thẳng (directory
  source), không có `kustomization.yaml`. Kustomize hợp khi cần overlay theo môi trường; tới phase dev/prod tôi sẽ cân nhắc
  lại. Còn các addon thì upstream phát hành dưới dạng Helm chart, nên dùng chart là đi theo đường được hỗ trợ.
- **Hai source trong một Application:** chart từ repo Helm, values từ Git qua `$values` (B1.2).
- **Đánh đổi:**
  - Thứ thật sự được apply chỉ thấy trong diff của Argo CD, hoặc khi chạy `helm template` ở máy.
  - Repo chart của upstream thành một phụ thuộc: nó sập thì Argo CD không render được, nhưng những gì đang chạy vẫn
    chạy.

**A1.6** **Ý chính:** "`root` là một Application mà việc duy nhất là tạo các Application khác, mỗi file trong `apps/` một cái.
Tôi chọn app-of-apps vì chín component khác nhau ở những chỗ quan trọng: wave, một cái có finalizer, một cái tắt `prune`,
syncOptions khác nhau. ApplicationSet mạnh khi sinh nhiều Application giống nhau từ một template, ví dụ mỗi cluster hay mỗi
môi trường một bản. Nó làm được các ngoại lệ bằng `templatePatch`, nhưng với chín file, đọc thẳng từng file dễ review hơn
một template nhiều điều kiện."

*Nếu được hỏi thêm:*

- **Khi nào tôi đổi:** khi có nhiều cluster, hoặc app có nhiều môi trường giống nhau. Khi đó cluster generator hoặc git
  generator hợp hơn (A7.7).
- Controller ApplicationSet vẫn được chart cài sẵn, với request nhỏ (25m, 64Mi).
- App-of-apps có một bẫy: mặc định Argo CD không chờ health của Application con, nên các wave giữa chúng không có tác dụng
  (A3.2).

**A1.7** **Ý chính:** "Với project này là điểm mạnh: không có credential nào để lộ, xoay vòng hay lưu, và Argo CD vốn chỉ cần
đọc. Cái giá là ai cũng thấy cấu hình: tên host, tên secret, kiến trúc. Nhưng không có giá trị secret nào, và mọi UI đều chỉ
qua VPN."

*Nếu được hỏi thêm*, chuyển sang repo private:

- Tạo một deploy key chỉ đọc, hoặc một GitHub App, rồi khai báo nó cho Argo CD dưới dạng repository Secret.
- **Bài toán con gà quả trứng:** tôi muốn key đó cũng đi từ Secrets Manager qua External Secrets. Nhưng Argo CD cần key để
  đọc được chính ExternalSecret đó. Nên `make bootstrap` phải tạo repository Secret trực tiếp, đọc từ Secrets Manager, trước
  khi apply `root.yaml`. Sau đó mới giao cho External Secrets giữ và xoay vòng.

**A1.8** **Ý chính:** "Theo đúng khuôn đã có: chart của app và Jenkins mỗi thứ là một file trong `apps/`, ở wave sau nền tảng.
Jenkins không có quyền deploy; nó chỉ ghi digest image mới vào file values của dev trong Git, còn Argo CD làm phần còn lại. Hạ
tầng đi trước (secret, certificate, ingress, monitoring) đã sẵn sàng khi app tới."

*Nếu được hỏi thêm:*

- **Thiết kế:** hai Application `medical-rag-dev` và `medical-rag-prod`. Prod chỉ đổi qua pull request đã review (`Common
  A1.2`, `Common B4.1`).
- **Build index:** chạy như một hook `PreSync` trong Application của app. Đây là thứ tự *trong* một Application, khác với wave
  giữa các Application (A3.1, `Common B2.2`).
- **Monitoring:** Prometheus đã chọn mọi ServiceMonitor, nên ServiceMonitor của app sẽ được nhận mà không phải sửa gì (B6.4).

**A1.9** **Ý chính:** "Vì chỉ Jenkins biết image nào đã qua quét và ký. Image được push lên ECR rồi mới quét và ký, nên trong
registry có lúc có image chưa được kiểm; Image Updater theo dõi registry có thể đưa đúng image đó lên. Thêm nữa, Image Updater
cần credential ECR và quyền ghi Git ngay trong cluster, trong khi hiện Argo CD không giữ credential nào."

*Nếu được hỏi thêm:*

- Để Jenkins commit thì mỗi lần đổi version đều là một commit có người đọc được, với digest cụ thể (`Jenkins A6.4`).
- Vòng lặp Jenkins tự kích hoạt chính nó được chặn bằng skip guard (`Jenkins A6.2`).
- Image Updater hợp khi nhiều team đẩy image và không muốn pipeline nào có quyền ghi vào repo deploy.

### A2. Bootstrap: Argo CD tự quản lý chính nó

**A2.1** **Ý chính:** "`make bootstrap`, đúng một lần. Nó cài chart Argo CD bằng Helm, với version đọc từ `apps/argocd.yaml`
và cùng file values Argo CD sẽ dùng, rồi apply `root.yaml`. `root` tạo ra Application `argocd` trỏ vào đúng chart, version và
values đó, nên Argo CD tiếp quản chính bản cài của nó. Lệnh đó mất 52 giây."

*Nếu được hỏi thêm:*

- Từ đó, nâng cấp Argo CD là sửa `targetRevision` trong `apps/argocd.yaml` (A2.5).
- `make bootstrap` đọc file trên ổ của workstation, nên phải `git pull` trước. Nếu không, Helm cài version cũ còn Argo CD đọc
  version mới, và lần tiếp quản sẽ đổi pod (B2.8).

**A2.2** **Ý chính:** "Theo thiết kế thì không: cùng chart, cùng version, cùng values, nên manifest giống hệt, và Makefile
đọc version từ chính file Application để hai bên không lệch nhau. Thay đổi chính Argo CD làm là thêm annotation tracking. Nhưng
tôi nói thẳng: tôi chưa ghi lại `AGE` và số restart của lần tiếp quản, nên đó là kỳ vọng, chưa phải số đo. Cách kiểm là
`kubectl -n argocd get pods` trước và sau khi `argocd` chuyển `Synced`."

*Nếu được hỏi thêm:*

- `[điền: AGE và restart của pod Argo CD trước và sau khi tiếp quản]`
- Argo CD 3.x mặc định tracking bằng annotation (`argocd.argoproj.io/tracking-id`), không bằng label như các bản cũ, nên nó
  không đụng tới label của chart. Server-side apply còn đổi `managedFields` (field manager `argocd-controller`), nhưng pod
  không thấy thay đổi đó.
- **Chỗ có thể lệch:** chart dùng `lookup` hoặc sinh giá trị ngẫu nhiên thì `helm install` và `helm template` của Argo CD có
  thể ra khác nhau. Chart Argo CD không làm vậy với values này **[kiểm chứng]** bằng cách xem diff của `argocd` ngay sau lần
  tiếp quản.
- **Để ý:** Secret lưu release Helm (`sh.helm.release.v1.argocd.v1`) vẫn nằm lại, vì nó không có annotation tracking nên Argo
  CD không bao giờ prune nó. `helm list` sẽ mãi thấy revision 1; đừng dùng Helm để đọc trạng thái của Argo CD.

**A2.3** **Ý chính:** "Không có gì xảy ra ngoài việc apply lại `root.yaml`. `make bootstrap` thấy Application `argocd` đã tồn
tại thì bỏ qua Helm. Tôi thêm điều kiện đó sau khi chạy lại lần hai và bị lỗi conflict: Argo CD đã sở hữu các object qua
server-side apply, và Helm 4 cũng apply server-side, nên hai field manager tranh nhau."

*Nếu được hỏi thêm:* câu chuyện đầy đủ ở A8.4. Nhờ vậy `make bootstrap` là một lệnh duy nhất cho cả cluster mới lẫn cluster
đang chạy (B5.1).

**A2.4** **Ý chính:** "Trước hết, workload vẫn chạy: Argo CD không nằm trên đường đi của traffic. Thứ mất đi là khả năng thay
đổi và tự sửa. Lúc đó phải sửa tay, vì Argo CD hỏng thì không tự cứu mình được. Tôi vẫn
revert commit để Git đúng, rồi đưa bản đúng vào cluster trực tiếp. Khi Argo CD sống lại, nó đọc Git và thấy mọi thứ đã khớp."

*Nếu được hỏi thêm:*

- **Cách đưa vào:** `helm template` với version và values tốt, rồi `kubectl apply --server-side --force-conflicts`. Hoặc sửa
  thẳng Deployment hỏng, nếu biết chính xác cái gì sai.
- **Vì sao không chạy lại `make bootstrap`:** nó bỏ qua Helm khi Application `argocd` còn tồn tại. Mà kể cả chạy Helm thì
  cũng đụng conflict field manager.
- **Lớp bảo vệ đã có:** Application `argocd` đặt `prune: false`. Một values sai không thể khiến Argo CD xoá chính controller
  đang chạy sync (A4.1).
- **Phòng trước:** đổi version Argo CD trong một commit riêng, và xem pod mới `Ready` rồi mới làm việc khác.

**A2.5** **Ý chính:** "Sửa `targetRevision` trong `apps/argocd.yaml` rồi push; Argo CD tự nâng chính nó. Phần việc thật nằm ở
trước đó: đọc release notes và hướng dẫn nâng cấp, nhất là giữa các major, và nâng từng minor một."

*Nếu được hỏi thêm:*

- CRD của Argo CD đi cùng chart và được apply server-side, vì chúng lớn hơn giới hạn 262 KB của client-side apply (A4.6).
- Controller khởi động lại giữa chừng không sao: sync được làm lại ở vòng reconcile sau.
- **Rollback:** revert commit. Nhưng một bản mới có thể đã đổi CRD hoặc dữ liệu, nên phải đọc release notes cả chiều hạ
  version.
- Sau đó `git pull` trên workstation, để lần `make bootstrap` sau trên cluster mới cài đúng version mới.

### A3. Thứ tự: sync wave và health

**A3.1** **Ý chính:** "Sync wave là một annotation số nguyên. Trong một lần sync, Argo CD apply từ wave thấp lên cao, và chỉ
sang wave sau khi resource của wave trước đã healthy. Hook thì khác: đó là resource, thường là Job, chạy ở một pha của sync
như `PreSync` hay `PostSync`, ví dụ migrate database. Wave xếp thứ tự các thứ luôn tồn tại; hook là thứ chạy xong rồi thôi."

*Nếu được hỏi thêm:*

- **Trong một Application:** ví dụ `platform-tls` có ClusterIssuer ở wave 0, Certificate ở wave 1, PushSecret ở wave 2 (B4.3).
- **Giữa các Application:** wave được đặt trên *chính các object Application* bên trong `root`. `root` apply chúng từng wave,
  và chờ Application con healthy. Nhưng "healthy" của một Application mặc định không được tính (A3.2).
- **Hook:** app sẽ dùng hook `PreSync` để build index (`Common B2.2`).

**A3.2** **Ý chính:** "Từ Argo CD 1.8, health của resource Application không còn được tính, nên với `root`, mọi Application con
đều healthy ngay lúc được tạo, và các wave không thật sự chờ nhau. Tôi khôi phục bằng một health check Lua cho kind
`argoproj.io/Application` trong `argocd-cm`. Bản của tôi yêu cầu con phải `Healthy` *và* `Synced`, truyền `Degraded` lên, và
coi một Application không có resource nào là lỗi."

*Nếu được hỏi thêm:* check nằm trong `values/argocd.yaml`, dưới
`configs.cm.resource.customizations.health.argoproj.io_Application`. Từng nhánh ở B2.1–B2.4. Vì sao phải có `Synced`: A3.3.

**A3.3** **Ý chính:** "`Healthy` nói về các resource *đang có*; `Synced` nói tất cả resource trong Git đã có trên cluster và
khớp. Điểm quan trọng: Argo CD cố ý không tính resource *chưa tồn tại* vào health của Application. Nên một Application mới apply
được nửa manifest vẫn báo `Healthy`, chỉ có `sync` là còn `OutOfSync`. Check chỉ đọc health thì thả wave sau đi quá sớm. Tôi đã
gặp đúng chuyện đó."

*Nếu được hỏi thêm:*

- Trong source của Argo CD, `controller/health.go` ghi rõ: "Missing resources should not affect parent app health — the
  OutOfSync status already indicates resources are missing". Còn `controller/state.go` ép `OutOfSync` khi còn resource
  thiếu. Nên `Synced` mới là điều kiện thật sự xếp thứ tự.
- Hậu quả thật: A8.1.

**A3.4** **Ý chính:** "Bốn wave theo phụ thuộc. Wave -3 là nền móng: Argo CD, ingress-nginx, EBS CSI driver. Wave -2 là hai
operator mang CRD: External Secrets và cert-manager. Wave -1 là `platform-secrets`: secret store, các ExternalSecret và
certificate được khôi phục. Wave 0 là những thứ dùng chúng: issuer và certificate, monitoring, Rancher. Gộp -1 với 0 thì
cert-manager đua với bản khôi phục và xin certificate mới; đó chính là sự cố 18/09. Gộp -2 với -1 thì ExternalSecret được
apply trước khi CRD của nó tồn tại."

*Nếu được hỏi thêm*, các phụ thuộc cụ thể:

| Phải có trước | Trước | Vì |
|---|---|---|
| EBS CSI driver | monitoring | Prometheus xin volume; thiếu StorageClass `gp3` thì nó `Pending` |
| External Secrets, cert-manager | `platform-secrets`, `platform-tls` | `ExternalSecret`, `Certificate` là custom resource |
| `platform-secrets` | `platform-tls` | Certificate cũ phải về trước khi `Certificate` tồn tại (A5.5) |
| `platform-secrets` | Rancher, monitoring | Certificate và mật khẩu Rancher, mật khẩu Grafana, cấu hình Alertmanager phải có khi chúng khởi động |

Nền móng không phụ thuộc gì, nhưng có nó sớm thì volume bind ngay và target của load balancer healthy trước khi UI nào được
cài.

**A3.5** **Ý chính:** "Bằng wave: chart mang CRD đứng một wave riêng, và wave sau chỉ bắt đầu khi Application đó `Healthy` và
`Synced`, tức CRD đã có và operator đã chạy. Có cách khác: `SkipDryRunOnMissingResource=true` cho phép apply dù CRD chưa có, hoặc
tách CRD thành một Application riêng. Nhưng thứ tự rõ ràng thì dễ hiểu hơn là trông vào việc sync được thử lại."

*Nếu được hỏi thêm:*

- Operator chạy mới là điều quan trọng, không chỉ có CRD: cert-manager và External Secrets có admission webhook. Resource
  apply khi webhook chưa sẵn sàng sẽ bị từ chối (B6.1).
- Triệu chứng khi thiếu thứ tự: `no matches for kind "ExternalSecret"` (troubleshooting).

**A3.6** **Ý chính:** "Theo thiết kế, và tôi nói rõ là nhánh này chưa chạy thật lần nào: `root` cũng chuyển `Degraded`, vì check
của tôi truyền `Degraded` lên, và wave 0 không bắt đầu: không có monitoring, không Rancher, không certificate mới. Chặn như vậy
là cứng, nên tôi thiết kế `platform-secrets` để nó xuống cấp chứ không chặn: bản khôi phục certificate luôn có thứ để đọc, kể
cả trên account mới."

*Nếu được hỏi thêm:*

- **Vì sao dừng tốt hơn chạy tiếp:** thiếu mật khẩu Grafana hay cấu hình Alertmanager thì các chart kia cũng hỏng. Nhưng hỏng
  ở chỗ khó hiểu hơn, và cert-manager có thể tốn một lần cấp certificate.
- **Placeholder:** trên account mới, backup được seed một certificate *cố ý sai*, tên `placeholder.invalid` và hạn 1 ngày.
  Tên không khớp nên cert-manager cấp đè lên nó, và `platform-secrets` không bao giờ `Degraded` vì backup trống (B3.5).
- **Người vận hành thấy lý do:** thông báo lỗi của con được chép lên `root`.

**A3.7** **Ý chính:** "Bốn giới hạn. Một là nó chỉ xếp thứ tự những gì đi qua `root`; sau đó mỗi con sync theo policy riêng. Hai
là `Synced` nghĩa là manifest đã apply, không có nghĩa việc chúng yêu cầu đã xong, nên tôi dựa vào health check có sẵn cho
ExternalSecret và Certificate. Ba là có hai trạng thái làm `root` chờ im lặng. Bốn là nó mới được chứng minh trên một lần dựng
lại."

*Nếu được hỏi thêm:*

- **Chỉ những thay đổi đi qua `root`:** commit sửa file trong `apps/` làm `root` sync lại, và `root` vẫn đi theo wave. Còn một
  commit chỉ sửa `values/` hay `manifests/` thì mỗi Application con sync độc lập, không theo wave.
- **Chờ im lặng:** một con `Healthy` nhưng `OutOfSync` mãi, hoặc một con `Suspended` (B2.4).
- **Chưa thử:** nhánh `Degraded` và nhánh "không có resource" chưa chạy thật lần nào. Tôi sẽ thử cố ý trên một nhánh Git
  riêng (A9.1).

### A4. Sync policy, drift và rollback

**A4.1** **Ý chính:** "`prune` xoá khỏi cluster những gì đã bị xoá khỏi Git; `selfHeal` đưa những gì bị sửa tay về lại đúng
Git. Riêng Application `argocd` tắt `prune`, vì nó đang quản lý chính controller đang chạy sync. Một values sai có thể khiến
Argo CD xoá mất chính mình giữa chừng. Nên ở đó, những gì bị xoá khỏi Git sẽ nằm lại, tôi xem rồi mới xoá bằng tay."

*Nếu được hỏi thêm:*

- `selfHeal` vẫn bật cho `argocd`; chỉ việc *xoá* là cần người.
- Mọi Application khác bật cả hai.
- `root` bật `prune`, nên xoá một file trong `apps/` sẽ xoá Application đó (A4.7).

**A4.2** **Ý chính:** "Argo CD thấy sai lệch gần như ngay lập tức, vì nó watch cluster chứ không đợi polling. Application
chuyển `OutOfSync`, và `selfHeal` đưa Deployment về đúng Git sau vài giây. Muốn sửa nóng thì cách tốt nhất vẫn là commit.
Nếu thật sự phải sửa trên cluster, tôi tắt automated sync, nhưng phải tắt ở `root` trước rồi mới tắt ở con."

*Nếu được hỏi thêm:*

- **Giới hạn của drift detection:** chỉ các field Git khai báo mới bị đưa về. Một field Git không có, do ai đó thêm bằng
  `kubectl edit` (một biến env, một annotation), thuộc field manager khác và thường không hiện diff, nên `selfHeal` để yên nó
  **[kiểm chứng trên v3.5]**.
- "Vài giây" là theo mặc định của `selfHeal`; tôi chưa đo.
- **Vì sao `root` trước:** `root` quản lý object Application của con với `selfHeal`. Sửa `syncPolicy` của con thì `root`
  lập tức đặt lại. `make down` tắt `root` trước cũng vì cùng lý do đó (B5.3).
- **Sau sự cố:** đưa bản sửa vào Git, bật lại sync, xem `Synced`. Nếu không, lần bật lại sẽ xoá mất bản sửa nóng.

**A4.3** **Ý chính:** "`git revert` rồi push; Argo CD đưa addon về bản cũ ở vòng reconcile tiếp theo. Tôi không dùng nút
Rollback, vì Argo CD không cho rollback khi automated sync đang bật, và nếu dùng thì cluster sẽ khác Git, đúng thứ GitOps muốn
tránh."

*Nếu được hỏi thêm*, những gì revert không đưa về được:

- **CRD và dữ liệu:** một chart mới có thể đã nâng CRD hoặc migrate dữ liệu, và không phải chart nào cũng hỗ trợ hạ version.
  Nên phải đọc release notes cả chiều hạ.
- **Trạng thái trong volume:** dữ liệu Prometheus không quay lại.
- **Những gì ngoài cluster:** một certificate đã cấp hay một bản backup đã bị ghi đè (A8.3).
- Rollback của app phase: `Jenkins A6.5`.

**A4.4** **Ý chính:** "Tối đa khoảng ba phút: Argo CD poll Git theo chu kỳ mặc định. Muốn nhanh hơn thì bấm Refresh. Tôi không dùng
webhook vì GitHub phải gọi được vào `argocd-server`, mà server đó chỉ mở qua VPN. Mở một đường public chỉ để tiết kiệm ba phút
thì không đáng, với một nền tảng thay đổi vài lần một tuần."

*Nếu được hỏi thêm:*

- Values không đặt `timeout.reconciliation`, nên dùng mặc định của chart: 120 giây cộng jitter ngẫu nhiên tới 60 giây, tức tối
  đa 3 phút.
- **Khi app vào:** độ trễ tới dev quan trọng hơn. Khi đó có thể mở riêng đường `/api/webhook` qua ingress public, với secret
  của webhook. Hoặc để Jenkins gọi refresh sau khi push.

**A4.5** **Ý chính:** "Tôi xem diff của Argo CD để biết *field* nào lệch, rồi hỏi: ai đang ghi field đó? Thường gặp nhất là
API server hoặc webhook điền giá trị mặc định mà Git không ghi, một controller khác ghi vào spec, hoặc chart sinh giá trị ngẫu
nhiên mỗi lần render. Tôi sửa ở gốc trước; `ignoreDifferences` là cách cuối cùng, và phải hẹp nhất có thể."

*Nếu được hỏi thêm:*

- **Server-side diff:** tôi bật `ServerSideDiff=true` cho `platform-tls`. Argo CD hỏi API server bằng một lần dry-run
  server-side apply, nên các giá trị mặc định không còn hiện là khác biệt (B1.6).
- **Hai chủ:** nếu hai bên cùng ghi một object thì `selfHeal` đánh nhau mãi. Ví dụ Argo CD (render chart Rancher) và External
  Secrets cùng ghi `bootstrap-secret` khi `bootstrapPassword` được đặt trong values (B3.8).
- **HPA:** trường hợp kinh điển của một controller khác ghi vào spec (A4.9).
- `ignoreDifferences` nên dùng với `jqPathExpressions` trỏ đúng một field, kèm `RespectIgnoreDifferences=true` nếu không muốn
  sync ghi đè field đó.

**A4.6** **Ý chính:** "Lý do đầu tiên là bắt buộc: CRD của Argo CD và của Prometheus Operator quá lớn cho client-side apply.
Kiểu đó lưu cả object trong annotation `last-applied-configuration`, giới hạn 262144 byte. Lý do thứ hai là field ownership:
nhiều bên có thể cùng ghi một object mà không đè nhau. Tôi bật cho mọi Application con để có một quy tắc chung."

*Nếu được hỏi thêm:*

- **Cái giá:** field manager thành một phần của trạng thái. Một tool khác cũng apply server-side, như Helm 4, sẽ bị conflict
  (A8.4).
- `platform-secrets` không thật sự cần; comment trong file ghi rõ nó được bật để giữ một quy tắc. `root` thì không bật: nó
  chỉ chứa vài object Application nhỏ.

**A4.7** **Ý chính:** "`root` có `prune`, nên Application tương ứng bị xoá. Resource của nó có bị xoá theo hay không là do
finalizer: chỉ `kube-prometheus-stack` có, nên chỉ nó kéo theo mọi thứ nó cài. Các Application khác bị xoá thì resource nằm
lại, vẫn chạy nhưng không ai quản lý. Xoá nhầm `root` thì chỉ mất đúng `root`, vì nó cố ý không có finalizer. Các con vẫn
chạy và vẫn tự sync, và `make bootstrap` tạo lại `root`."

*Nếu được hỏi thêm:*

- `argocd` cũng không có finalizer: xoá Application đó không bao giờ gỡ Argo CD.
- Điều này đúng khi xoá bằng `kubectl delete`. `argocd app delete` mặc định là cascade và tự thêm finalizer; muốn giữ con thì
  dùng `--cascade=false`.
- Nếu `root` có finalizer, xoá nó sẽ xoá mọi Application con. Kéo theo đó là toàn bộ monitoring cùng volume của nó (B1.1).

**A4.8** **Ý chính:** "Không atomic. Argo CD apply từng wave; lỗi ở wave hai thì những gì wave một đã apply vẫn nằm đó, không
có rollback tự động. Application báo sync lỗi, và cluster ở trạng thái nửa cũ nửa mới. Tôi sửa tiến: sửa commit, hoặc revert
để Git về trạng thái cũ rồi để Argo CD apply lại."

*Nếu được hỏi thêm:*

- Một lần automated sync lỗi được thử lại tối đa 5 lần (mặc định khi không đặt `retry`); sau đó automated sync không
  tự chạy lại cùng commit (B1.8).
- Hook `SyncFail` chạy được việc dọn dẹp khi sync lỗi. Project chưa dùng.
- Vì vậy thứ tự wave quan trọng: đặt trước những gì an toàn khi đứng một mình, như namespace và secret, để một lần dừng giữa
  chừng không làm hỏng thứ đang chạy.

**A4.9** **Ý chính:** "Có, nếu Git cũng khai báo `replicas`: HPA đổi số replica, Argo CD thấy lệch và `selfHeal` đặt lại, rồi HPA
lại đổi. Cách sửa gọn nhất là không khai báo `replicas` trong manifest khi có HPA. Với server-side apply, field Git không khai
báo thì Argo CD không giành. Nếu chart bắt buộc có, tôi dùng `ignoreDifferences` cho đúng `/spec/replicas`, kèm
`RespectIgnoreDifferences=true`."

*Nếu được hỏi thêm:* nền tảng hiện chưa có HPA nào. Đây là việc của chart app ở phase sau.

### A5. Secret và certificate

**A5.1** **Ý chính:** "Git chỉ chứa ExternalSecret, tức *tên* secret trong Secrets Manager. External Secrets đọc giá trị và tạo
Secret của Kubernetes. Tôi chọn nó vì secret vốn đã nằm trong Secrets Manager: Terraform tạo secret rỗng, tôi đặt giá trị bằng
một lệnh. Không có key giải mã nào trong Git hay trong Argo CD, và xoay vòng không cần commit."

*Nếu được hỏi thêm:*

| | Vì sao không chọn ở đây |
|---|---|
| **Sealed Secrets** | Key giải mã nằm trong cluster. Cluster này bị dựng lại liên tục, nên phải backup key đó ở đâu đó, tức là lại cần một kho secret. Mỗi lần đổi giá trị lại phải commit |
| **SOPS** | Argo CD phải giải mã (qua plugin), nên giá trị đi qua repo-server và cache của nó |
| **Vault** | Thêm một hệ thống có trạng thái, phải vận hành và unseal. Quá nặng cho một người vận hành |

Điểm yếu của lựa chọn này: phụ thuộc AWS, và quyền đọc đi theo node role (A5.2).

**A5.2** **Ý chính:** "Từ instance profile của node. ClusterSecretStore không có block `auth`, nên SDK AWS dùng chuỗi credential
mặc định và lấy role của node qua metadata service. Rủi ro là mọi pod trên node đều dùng được role đó. Tôi giới hạn role chỉ
đọc sáu secret có tên, và chỉ ghi đúng một secret là bản backup certificate."

*Nếu được hỏi thêm:*

- **Vì sao chưa có cách tốt hơn:** cluster tự dựng không có IRSA hay EKS Pod Identity. Hop limit 2 là để pod gọi được metadata
  service (`Terraform B7.1`).
- **Kế hoạch:** NetworkPolicy chặn `169.254.169.254` cho namespace của app (phase app), sau đó là IRSA tự host (P2 trong thiết
  kế).
- Quyền nguy hiểm nhất của role, và thiệt hại nếu một pod bị chiếm: `Terraform B7.3`.

**A5.3** **Ý chính:** "Một lệnh `put-secret-value` vào Secrets Manager, không commit gì. ExternalSecret của Alertmanager refresh
mỗi giờ. Muốn ngay thì annotate `force-sync`, External Secrets sẽ ghi lại Secret và Alertmanager nạp cấu hình mới."

*Nếu được hỏi thêm:*

- **Ngoại lệ:**
  - Bản khôi phục certificate chỉ tạo một lần (`CreatedOnce`); cert-manager tự gia hạn và PushSecret backup bản mới.
  - Mật khẩu Grafana được sinh trong cluster, không nằm trong Secrets Manager (B3.6).
- Prometheus Operator watch `configSecret`, sinh lại cấu hình, và sidecar config-reloader nạp lại Alertmanager. Mất thêm
  khoảng 1–2 phút vì kubelet đồng bộ volume Secret theo chu kỳ.

**A5.4** **Ý chính:** "Các tên như `argocd.recruitai.io.vn` trỏ về địa chỉ private, nên Let's Encrypt không vào được để kiểm tra
bằng HTTP. DNS-01 chứng minh quyền sở hữu domain bằng một bản ghi TXT, và cũng là cách duy nhất để xin wildcard. Một wildcard
nghĩa là một lần cấp cho mọi UI thay vì bốn. ingress-nginx dùng nó làm certificate mặc định, nên không phải chép Secret sang
từng namespace."

*Nếu được hỏi thêm:*

- **Quyền:** node role chỉ được sửa đúng bản ghi TXT `_acme-challenge.recruitai.io.vn` (B4.2).
- **Rancher** dùng certificate Sectigo mua riêng.
- **Đánh đổi:** lộ key của wildcard là lộ cho mọi tên. Chấp nhận được vì mọi tên đó chỉ mở qua VPN.

**A5.5** **Ý chính:** "Tôi backup certificate và khôi phục nó khi dựng lại. Khi cluster chạy, một PushSecret chép Secret của
certificate vào Secrets Manager. Khi dựng lại, một ExternalSecret ở wave -1 đưa nó về, trước khi `Certificate` tồn tại, kèm
annotation ghi đúng issuer. cert-manager thấy một certificate hợp lệ thì giữ lại, không xin mới. Lần dựng lại 19/09 cấp đúng 0
certificate."

*Nếu được hỏi thêm:*

- **Hạn mức:** 5 certificate cho cùng một bộ tên trong 7 ngày, tính trên toàn Let's Encrypt, không theo account. Hồi lại một
  suất khoảng mỗi 34 giờ. Account ACME mới sau mỗi lần dựng lại không reset được hạn mức này, và việc tạo account cũng có
  hạn mức riêng (B4.1).
- **Staging:** hạn mức cao hơn nhiều, dùng để thử. Nhưng không đổi issuer trên cluster đang chạy (A8.3).
- **Bản khôi phục phải thắng một cuộc đua**, và chỉ có cổng wave làm nó thắng (A8.1).

**A5.6** **Ý chính:** "Chưa. cert-manager quyết định certificate do ai cấp bằng cách đọc ba annotation `issuer-*` trên Secret,
chứ không giải mã xem ai ký. Một certificate staging mang annotation production vẫn `Ready=True`. Nên tôi kiểm certificate đang
phục vụ bằng `openssl`: dòng issuer của bản production là một intermediate của Let's Encrypt, như `YR1`; bản staging có chữ
`(STAGING)`."

*Nếu được hỏi thêm:* đây là lý do evidence 19/09 ghi dòng issuer đọc bằng `openssl` và fingerprint, chứ không chỉ ghi `Ready`.
Quy tắc tôi rút ra là tin `openssl x509 -issuer`, không tin `Ready`.

### A6. Truy cập và bảo mật

**A6.1** **Ý chính:** "Chỉ người trong VPN. Có ba lớp. DNS: tên của nó trỏ về địa chỉ private của load balancer nội bộ. Mạng:
địa chỉ đó chỉ tới được từ trong VPC, tức qua WireGuard. ingress-nginx: mọi Ingress nội bộ chỉ nhận nguồn `10.10.0.0/16`. Sau ba
lớp đó mới tới màn hình đăng nhập của Argo CD."

*Nếu được hỏi thêm:*

- **Lớp thứ ba cần `externalTrafficPolicy: Local`:** với mặc định `Cluster`, kube-proxy thay địa chỉ nguồn bằng địa chỉ của
  node, vốn nằm trong VPC, và allowlist sẽ nhận cả traffic từ internet đi qua load balancer public (B6.2).
- **Kiểm chứng:** người vận hành đã mở được Argo CD qua WireGuard. `[điền: timeout khi tắt VPN, 200 khi bật]`

**A6.2** **Ý chính:** "Chỉ tài khoản `admin`; tôi tắt Dex vì chỉ có một người vận hành. Có thêm ba người thì tôi bật SSO qua
OIDC với GitHub hay Google, viết RBAC theo nhóm (mặc định chỉ đọc, sync cho nhóm vận hành), rồi tắt `admin`. Tôi cũng tách
AppProject để giới hạn repo, namespace đích và loại resource cluster-scoped mỗi nhóm được đụng tới."

*Nếu được hỏi thêm:*

- Quan trọng hơn Argo CD là **quyền trên Git**, vì Git mới là nơi ra lệnh (A6.3).
- Mật khẩu `admin` ban đầu nằm trong `argocd-initial-admin-secret`, do chính Argo CD tạo khi chưa có mật khẩu. Đổi mật khẩu
  rồi xoá Secret đó, như tài liệu Argo CD khuyên.

**A6.3** **Ý chính:** "Gần như là cluster-admin: một file trong `apps/` có thể cài bất cứ thứ gì, và AppProject `default` không
giới hạn gì. Lớp chặn chính phải ở Git: branch protection, bắt buộc review, CODEOWNERS cho `deploy/`. Sau đó là giới hạn trong
Argo CD: AppProject chỉ cho phép repo và namespace đích đã biết. Nếu cần chặt hơn thì bắt commit phải được ký."

*Nếu được hỏi thêm:*

- Argo CD kiểm được chữ ký GPG của commit. Từ 3.5 cấu hình ở `spec.sourceIntegrity` của AppProject; `signatureKeys` cũ đã
  deprecated. Nó chỉ áp dụng cho source Git, không cho chart từ Helm repo.
- **Lớp thứ hai trong cluster:** Kyverno (P1 trong thiết kế) chặn image chưa ký ở prod.
- Hiện tại tôi là người duy nhất push được. Đó là giới hạn chấp nhận cho một project cá nhân, không phải thiết kế cho team.

**A6.4** **Ý chính:** "Application controller có quyền trên mọi resource của cluster; nó cần vậy để cài bất cứ thứ gì. Nên
chiếm được Argo CD là chiếm cluster: đọc mọi Secret, chạy bất cứ pod nào. Và vì pod chạy trên node, còn có IAM role của node.
Tôi giữ bề mặt tấn công nhỏ: UI chỉ qua VPN, không credential Git nào để lấy cắp. Inline policy của role node chỉ ghi đúng
ARN, nhưng tôi nói rõ: role còn gắn hai managed policy của AWS, cho EBS CSI và SSM, có quyền trên cả account."

*Nếu được hỏi thêm:*

- **Thiệt hại trên AWS:** `Terraform B7.3`.
- **Cải thiện được:** siết NetworkPolicy của namespace `argocd`. Chart tạo sẵn NetworkPolicy (`global.networkPolicy.create`
  mặc định bật; lỗi ở A8.4 xảy ra trên hai cái trong số đó); `[kiểm chứng: chúng cho phép những gì]`. Chặn metadata
  service với pod không cần. SSO kèm RBAC (A6.2).
- UI của Argo CD che giá trị của Secret trong diff, nhưng đó là che hiển thị, không phải kiểm soát truy cập.

**A6.5** **Ý chính:** "Chấp nhận được ở đây, không ở công ty. Hai UI đó chỉ mở qua VPN, và VPN chỉ có một người. Rủi ro không
phải chỉ là xem: ai vào được Alertmanager thì tạo được silence, tức tắt alert. Cách sửa là basic auth trên Ingress, hoặc một
OAuth proxy trước mọi UI."

*Nếu được hỏi thêm:* Argo CD và Grafana có đăng nhập riêng. Mật khẩu Grafana được sinh trong cluster, không ai gõ ra (B3.6).

### A7. Vận hành

**A7.1** **Ý chính:** "Hiện tại là tôi tự nhìn: `make apps`, hoặc UI. Đó là một lỗ hổng, và tôi nói thẳng như vậy. Cách tôi sẽ
sửa là không bật thêm notifications controller, mà cho Prometheus scrape metric của Argo CD, rồi đặt alert khi một Application
không `Synced` hoặc không `Healthy` quá 15 phút. Như vậy mọi alert đi chung một đường, qua Alertmanager tới email."

*Nếu được hỏi thêm:*

- Chart Argo CD có ServiceMonitor: bật `controller.metrics.enabled` và `controller.metrics.serviceMonitor.enabled` (cả hai
  mặc định tắt), tương tự cho server và repoServer nếu cần. Prometheus của tôi đã chọn mọi ServiceMonitor (B6.4).
- Nên có thêm alert certificate sắp hết hạn từ metric của cert-manager, và alert ExternalSecret sync lỗi.
- **Đã cấu hình:** Alertmanager gửi email, và rule riêng `NodeCpuHighSustained`. Email thử chưa được ghi lại. `[điền: email
  alert thử, target control plane up]`

**A7.2** **Ý chính:** "14 phút 11 giây thời gian chạy lệnh, đo ngày 18/09 từ một cluster stack trống: `make infra` 4 phút 45,
`make cluster` 6 phút 11, `make bootstrap` 52 giây, rồi 2 phút 22 để `root` `Healthy`. Tôi đo bằng `time` trên từng lệnh, và
bước cuối bằng `kubectl wait` trên `root`. Nhưng có một chú thích quan trọng: lần đo đó chạy với health check cũ, chính là lần
có sự cố ở A8.1, nên các wave không chờ nhau thật và con số có thể thấp hơn thực tế."

*Nếu được hỏi thêm:*

- **Chưa tính:** khoảng chờ giữa các lệnh, như SSM agent đăng ký và mở tunnel. Nên con số thật từ đầu tới cuối lớn hơn.
- Tổng 14:11 cộng từ giá trị `real` chính xác; cộng các số đã làm tròn thì ra 14:10.
- Với check hiện tại, chờ riêng `root` là đủ vì `root` chỉ `Healthy` khi mọi con đều `Healthy` và `Synced` (B7.3).
- Lần dựng lại 19/09 với check đã sửa là để chứng minh việc khôi phục certificate; thời gian lần đó không được đo. `[điền: thời
  gian dựng lại với check đã sửa]`
- Thiết kế có `make up` cho cả chuỗi, nhưng Makefile chưa có. Hiện chạy bốn lệnh.

**A7.3** **Ý chính:** "Vì Terraform không biết các EBS volume mà CSI driver tạo cho Prometheus. `terraform destroy` xoá máy,
còn volume ở lại và vẫn tính tiền. `make down` tắt sync của `root`, xoá Application có volume, xoá PVC, chờ tới khi AWS không
còn volume nào của driver, rồi mới destroy."

*Nếu được hỏi thêm:*

- **Thứ tự quan trọng:** driver phải còn chạy lúc xoá PVC, vì chính nó xoá volume (`reclaimPolicy: Delete`).
- **Cổng chặn:** hỏi AWS chứ không hỏi cluster (B5.5).
- **Sống sót sau teardown:** mọi thứ trong Secrets Manager, kể cả bản backup certificate (PushSecret `deletionPolicy: None`).
- `[điền: thời gian make down]`

**A7.4** **Ý chính:** "Lệnh đó chờ vì `kube-prometheus-stack` có finalizer: Argo CD xoá mọi thứ nó cài rồi mới xoá chính nó.
Treo nghĩa là một resource bên dưới kẹt `Terminating`. Tôi tìm resource đó và xem `metadata.finalizers` của nó. Lỗi hay gặp là
finalizer của một operator đã bị xoá trước, nên không còn ai gỡ được."

*Nếu được hỏi thêm:*

- `kubectl -n monitoring get prometheus -o yaml` là chỗ nhìn đầu tiên (troubleshooting).
- **Gỡ finalizer bằng tay là cách cuối cùng:** nó làm mất việc dọn dẹp mà finalizer có nhiệm vụ làm. Với PVC, thứ tôi quan tâm
  là volume trên AWS, nên sau đó vẫn kiểm bằng `describe-volumes`.
- PVC treo: một pod vẫn mount nó (`Used By` trong `describe pvc`).

**A7.5** **Ý chính:** "Request của Argo CD cộng lại khoảng 475m CPU và 1 GiB RAM. Prometheus 1 GiB, Rancher 1 GiB, phần còn lại
nhỏ. Tôi nói thẳng: đó là điểm xuất phát cho cluster nhỏ, ghi rõ trong values là chưa đo, và mới có một lần tôi phải sửa vì số
thật: Grafana."

*Nếu được hỏi thêm:*

- **Nguyên tắc:** request để scheduler giữ chỗ; memory limit để một component không làm cạn node; không đặt CPU limit, vì CPU
  bị throttle làm chậm mà không cứu được gì (B2.7).
- **Grafana:** từ 256Mi lên 512Mi sau lỗi 502 (A8.8).
- **Chật:** ba node 8 GB chạy cả control plane. Đó là lý do Rancher, Alertmanager và mỗi component của Argo CD chỉ có một
  replica.
- `[điền: kubectl top nodes và kubectl top pods -A]`

**A7.6** **Ý chính:** "Đọc changelog của chart và release notes của app trước. Sau đó chạy `helm template` bản cũ và bản mới với
cùng values rồi diff, để biết chính xác cái gì đổi. Nâng từng component một, trong một pull request sửa đúng một dòng
`targetRevision`. Theo dõi health, và revert nếu cần."

*Nếu được hỏi thêm:*

- **CRD:** thay đổi CRD là phần rủi ro nhất, vì revert không luôn hạ được CRD (A4.3).
- **Không có bản xem trước tự động:** với automated sync, push là apply. Muốn xem trước trong Argo CD thì tắt automated sync
  của Application đó (và của `root`, A4.2), sync bằng tay, rồi bật lại.
- **ingress-nginx:** không còn bản mới để nâng. Hướng đi là chuyển sang controller còn được duy trì hoặc Gateway API, giữ
  nguyên hai NodePort.
- **Rancher:** chart của nó tự chặn Kubernetes quá mới (B1.7).

**A7.7** **Ý chính:** "Tôi sẽ để mỗi cluster một Argo CD, để một sự cố không lan qua nhiều cluster, và tách values theo môi
trường. Khi số cluster nhiều lên, tôi chuyển sang ApplicationSet với cluster generator thay vì chép file. Riêng certificate và
secret thì mỗi cluster cần tên riêng trong Secrets Manager."

*Nếu được hỏi thêm:*

- **Hub-and-spoke:** một Argo CD quản lý nhiều cluster thì dễ nhìn tổng thể, nhưng giữ credential của mọi cluster. Hợp khi có
  nhiều cluster nhỏ và một team nền tảng.
- **Bản backup certificate:** hai cluster cùng ghi `medical-rag/wildcard-tls` sẽ đè lên nhau, nên mỗi cluster cần một key
  backup riêng.
- **Thứ tự:** sync wave vẫn dùng được, vì health check nằm trong mỗi Argo CD.

**A7.8** **Ý chính:** "Trạng thái của Argo CD gần như chỉ là Git: mọi Application, values và health check đều nằm trong
`deploy/argocd/`. Mất namespace `argocd` thì chạy lại `make bootstrap`: Application `argocd` không còn nên Helm cài lại, rồi
`root` tạo lại mọi Application, và chúng nhận lại các resource đang chạy. Ngoài Git chỉ mất mật khẩu `admin`, vốn được sinh lại."

*Nếu được hỏi thêm:*

- **Bẫy:** resource cluster-scoped của Argo CD, như CRD và ClusterRole, vẫn còn và vẫn mang field manager `argocd-controller`.
  Helm cài lại có thể đụng conflict như A8.4 **[kiểm chứng]**. Và đừng xoá CRD `applications.argoproj.io` để "dọn cho sạch":
  xoá CRD là xoá mọi Application.
- **Khi có SSO, repo private hay nhiều cluster:** lúc đó mới có thứ ngoài Git cần backup. `argocd admin export` xuất toàn bộ
  cấu hình.

**A7.9** **Ý chính:** "Argo CD chỉ đưa manifest vào cluster; tự nó không làm canary. App hiện dùng rolling update của Deployment,
có readiness probe. Muốn canary hay blue-green thì thêm Argo Rollouts: thay Deployment bằng Rollout, chuyển traffic từng phần
qua ingress-nginx, và dùng metric Prometheus để tự quyết định đi tiếp hay lùi lại. Tôi chưa làm phần đó trong project này."

*Nếu được hỏi thêm:* với một app demo một người dùng, rolling update cộng rollback bằng `git revert` là đủ. Canary đáng công
khi có traffic thật để đo.

**A7.10** **Ý chính:** "Được, bằng sync window trong AppProject: một cửa sổ `deny` theo lịch cron chặn automated sync, và có thể
vẫn cho phép sync tay khi cần. Hiện tôi chưa đặt cửa sổ nào. Khi có sự cố, cách nhanh nhất của tôi là tắt automated sync của
`root` rồi của Application liên quan (A4.2)."

### A8. Sự cố và bài học

**A8.1** **Ý chính:** "Lần dựng lại 18/09 tốn một trong năm suất certificate mỗi tuần, dù bản khôi phục đã nằm trong Git.
Timestamp trên cluster cho thấy cert-manager xử lý `Certificate` trước khi Secret khôi phục tồn tại, dù Certificate ở wave sau.
Tôi đọc `argocd-cm` và source Argo CD: health check chỉ chép health của con, mà resource chưa tồn tại không được tính, nên con
`Healthy` ngay khi được tạo. Tôi sửa để yêu cầu cả `Synced`. Lần dựng lại sau không tốn suất nào."

*Nếu được hỏi thêm*, theo thứ tự:

1. **Triệu chứng:** sau lần dựng lại 18/09 có một `CertificateRequest`, trong khi mong đợi là không có cái nào. Cái giá là một
   trong 5 suất của tuần.
2. **Đo, không đoán:** dùng giờ của cluster, không dùng giờ laptop, vì hai đồng hồ lệch nhau.
   - Secret có `creationTimestamp` 13:40:34.
   - Event `Issuing certificate as Secret does not exist` được suy ra là khoảng 13:39:46, từ `Ready` lúc 13:41:26 trừ đi 100
     giây giữa hai event. Cách suy ra ở B7.1.
3. **Một dấu hiệu phụ:** `make bootstrap` 52 giây cộng 2 phút 22 là 194 giây. Có vẻ quá ngắn cho sáu chart cài lần lượt, cộng
   thêm một lần xin certificate qua DNS-01. Nhưng không có số đo theo từng wave để chứng minh; bằng chứng trực tiếp là thứ tự hai
   timestamp.
4. **Nguyên nhân:** check cũ là `hs.status = obj.status.health.status`. `controller/health.go` loại resource chưa tồn tại khỏi
   health. `controller/state.go` ép `OutOfSync` khi còn resource thiếu.
5. **Sửa:**
   - Yêu cầu `Healthy` và `Synced`.
   - Truyền `Degraded` lên, để `root` không chờ mãi mà không nói lý do.
   - Coi Application không có resource nào là lỗi, vì `path:` sai sẽ render ra rỗng, và khi đó nó `Healthy` lẫn `Synced`
     ngay lập tức.
6. **Kết quả:** A8.2.

**Mẹo:** con số 48 giây và tên file source để dành cho phần hỏi thêm. Nếu được hỏi "sao không dời bản khôi phục ra khỏi Argo
CD cho chắc", nói rằng đó là phương án đầu tiên được đưa ra và bạn đã bác bỏ: nó né triệu chứng, còn thứ tự của cả nền tảng vẫn
sai. Sửa gốc thì mọi wave đều được lợi.

**A8.2** **Ý chính:** "Tôi dựng lại từ đầu ngày 19/09. Bằng chứng chính là `status.revision` của Certificate rỗng và không có
`CertificateRequest` nào. Thứ tự đúng: Secret khôi phục có trước `Certificate` 2 tới 4 giây. Và dòng issuer đọc bằng `openssl`
là `YR1`, xác nhận certificate là bản production. Không tốn suất nào."

*Nếu được hỏi thêm:*

- **Độ chính xác:** hai timestamp đều bị cắt tới giây, nên khoảng cách thật là 2–4 giây. Nhưng thứ tự thì không thể là do làm
  tròn.
- **Vì sao revision rỗng mới là bằng chứng:** fingerprint trùng thì kiểu gì cũng trùng, vì PushSecret chép Secret đang chạy về
  backup (B7.2).
- **Tôi không nói quá:** đó là một lần chạy. Nhánh `Degraded` và nhánh "không có resource" chưa được thử.

**A8.3** **Ý chính:** "Tôi push một commit đổi issuer sang staging khi cluster đang chạy. Tôi muốn thử lại đường khôi phục bằng
staging cho khỏi tốn suất production, và nghĩ đổi issuer chỉ ảnh hưởng lần cấp sau. Tôi quên rằng annotation issuer trên Secret
sẽ lệch với spec ngay lập tức, nên cert-manager xin ngay một certificate staging. Trong vòng 10 phút, PushSecret có thể chép nó
đè lên bản backup production. Tôi xử lý như thể nó đã đè."

*Nếu được hỏi thêm*, cách khôi phục:

1. `make down` để dừng mọi thứ có thể ghi vào backup.
2. Theo runbook, đưa một phiên bản production của `medical-rag/wildcard-tls` về `AWSCURRENT`. External Secrets ghi bằng
   `PutSecretValue`, nên bản trước vẫn còn ở `AWSPREVIOUS`. Output của bước này không được lưu, nên tôi không biết chính xác
   phiên bản nào đã được đưa về.
3. Revert commit (`c0c1cb3`) rồi dựng lại. Bằng chứng bước 2 đúng là lần dựng lại đó: `openssl` cho issuer `YR1`, fingerprint
   trùng với `AWSCURRENT`.
4. Staging không tính vào hạn mức production, nên sự cố không tốn suất nào.

*Bài học:*

- **Quy tắc:** `make down` trước khi đổi bất cứ thứ gì PushSecret có thể ghi đè. Nó được ghi thành comment ngay trên dòng
  `issuerRef`.
- **Với thao tác trên cluster thật:** tôi viết runbook có kết quả mong đợi cho từng bước, *trước* khi chạy.
- `AWSPREVIOUS` chỉ giữ đúng một thế hệ. Một lần ghi nữa là bản cũ mất nhãn. Nên phải lưu backup ra đĩa *trước* khi thử.

**Mẹo:** kể phần này bình thản và ngắn. Người phỏng vấn muốn thấy bạn phát hiện nhanh, chặn thiệt hại, và biến bài học thành
quy tắc trong code.

**A8.4** **Ý chính:** "Lần đầu, `make bootstrap` cài Argo CD bằng Helm. Sau đó Argo CD tự quản lý các object đó bằng
server-side apply, với field manager `argocd-controller`. Chạy lại `make bootstrap` thì Helm 4, cũng apply server-side, cố ghi
cùng những field đó và bị API server từ chối: `Apply failed with 1 conflict`, trên hai NetworkPolicy và Deployment của
applicationset. Tôi sửa Makefile: chỉ cài Helm khi Application `argocd` chưa tồn tại."

*Nếu được hỏi thêm:*

- **Không ép bằng `--force-conflicts`:** hai công cụ cùng sở hữu một object là sai về thiết kế. Sau bootstrap chỉ có một chủ là
  Argo CD.
- **Kết quả:** `make bootstrap` giờ an toàn trên cả cluster mới lẫn cluster đang chạy (A2.3).

**A8.5** **Ý chính:** "Deadlock. Bản khôi phục certificate nằm cùng Application với bản backup, ở wave trước. Backup trong Secrets
Manager còn trống, nên bản khôi phục lỗi `could not get secret data from provider`. Lỗi đó chặn wave sau, nơi PushSecret sẽ ghi
backup. Không có backup thì khôi phục không bao giờ thành công, và không khôi phục được thì backup không bao giờ được ghi."

*Nếu được hỏi thêm:*

- **Sửa:**
  - Bỏ bản khôi phục khỏi `platform-tls`. PushSecret sync được và ghi backup.
  - Chuyển bản khôi phục sang `platform-secrets` ở wave -1, chạy trước `Certificate` khi dựng lại.
  - Tiện thể bật `ServerSideDiff=true` cho `platform-tls` (B1.6).
- **Bài học chung:** thứ *đọc* và thứ *ghi* cùng một trạng thái không nên nằm trong một đơn vị sync mà thứ này chặn thứ kia.

**A8.6** **Ý chính:** "Vì Argo CD đọc Git, không đọc máy tôi. File values được commit với tên `cert-manger.yaml`, sai chính tả,
trong khi Application trỏ tới `cert-manager.yaml`. Tôi `git mv` về đúng tên. Nhưng lỗi vẫn còn, vì kết quả được cache; phải
refresh hard mới hết."

*Nếu được hỏi thêm:*

- Refresh hard: annotation `argocd.argoproj.io/refresh=hard`, hoặc nút Hard Refresh. Nó bỏ cache của manifest đã render.
- Chính file Application cũng từng tên `apps/cert-manger.yaml`. Cái đó chỉ là thẩm mỹ, vì `root` đọc mọi file trong thư mục, và
  Application được nhận ra qua `metadata.name`. Đã đổi tên ngày 19/09.

**A8.7** **Ý chính:** "Vì Rancher cài CRD `apps.catalog.cattle.io`, và `app` trở thành một tên mơ hồ. kubectl chọn resource của
Rancher và trả `NotFound`. Từ đó lệnh trong evidence luôn viết đầy đủ `applications.argoproj.io`."

*Nếu được hỏi thêm:* một lệnh sai im lặng như vậy rất nguy hiểm trong script: `NotFound` bị hiểu là "không có Application",
trong khi thật ra hỏi nhầm chỗ.

**A8.8** **Ý chính:** "Pod Grafana khởi động lại ngay sau khi đăng nhập, lúc nó nạp các dashboard có sẵn, với limit 256Mi. Tôi
tăng request lên 192Mi, limit lên 512Mi, và lỗi hết. Nhưng tôi nói rõ: lý do kill không được ghi lại, nên thiếu bộ nhớ là nguyên
nhân *nhiều khả năng nhất*, chưa phải đã chứng minh."

*Nếu được hỏi thêm:* muốn chứng minh thì cần `kubectl describe pod` có `Last State: Terminated, Reason: OOMKilled`, số restart
tăng đúng lúc 502 xuất hiện, hoặc log `oom-kill` của kernel trên node. Lần sau tôi chụp những thứ đó trước khi sửa.

### A9. Nhìn lại

**A9.1** **Ý chính:** "Ba việc. Alert khi sync hoặc health lỗi, qua Prometheus. Cố ý chạy nhánh `Degraded` và nhánh 'không có
resource' của health check, trên một nhánh Git riêng, để chứng minh chúng như đã chứng minh nhánh chính. Và thu nốt evidence còn
thiếu, nhất là timeout khi không có VPN."

*Nếu được hỏi thêm*, tiếp theo:

- NetworkPolicy chặn metadata service cho các namespace không cần.
- Xử lý trường hợp con `Healthy` mà `OutOfSync` mãi: thêm thời hạn, hoặc một alert.
- Lên kế hoạch thay ingress-nginx.
- Ghi log của application-controller và `kubectl get applications.argoproj.io -w` trong lần dựng lại sau, để thấy wave diễn
  ra trực tiếp thay vì phải dựng lại từ event.

**A9.2** **Ý chính:** "Phần lớn thay đổi là về con người và quyền, không phải công nghệ. Repo private với deploy key đi qua
External Secrets. SSO, RBAC và AppProject cho từng team. Branch protection với review bắt buộc, và CI render sẵn diff của Argo CD
vào pull request. Argo CD chạy HA. Pod lấy quyền AWS qua IRSA thay vì role của node."

*Nếu được hỏi thêm:*

- **Certificate:** mẹo backup và khôi phục tồn tại vì tôi dựng lại cluster hằng ngày để tiết kiệm tiền. Cluster của công ty
  sống lâu, nên cert-manager tự gia hạn là đủ; hoặc dùng CA nội bộ cho tên nội bộ.
- **Nhiều cluster:** A7.7.
- **Alert:** gửi vào kênh chat của team, có người trực, thay vì một hộp thư.

---

## Phần B — Chi tiết

### B1. `root` và các Application

**B1.1** Finalizer `resources-finalizer.argocd.argoproj.io` khiến việc xoá Application thành xoá theo tầng: Argo CD xoá mọi
resource Application đó đã cài, rồi mới xoá Application.

- **`kube-prometheus-stack` cần nó:** đây là Application duy nhất sở hữu một EBS volume. `make down` xoá nó và phải chờ tới
  khi pod Prometheus thật sự biến mất. PVC không nằm trong danh sách resource Argo CD quản lý (B5.4), nên finalizer không xoá
  nó. Việc của finalizer là bảo đảm không còn pod nào dùng PVC; nếu không, StatefulSet vẫn chạy, `pvc-protection` giữ PVC, và
  bước xoá PVC treo tới timeout.
- **`root` cố ý không có:** nếu có, xoá `root` sẽ xoá mọi Application con. Khi đó `kube-prometheus-stack` lại kéo theo mọi thứ
  nó cài, nên một lệnh xoá nhầm sẽ gỡ cả monitoring và volume. Không có finalizer thì xoá `root` chỉ xoá `root`.
- **`argocd` cũng không có:** xoá Application đó không bao giờ được gỡ Argo CD.

*Ở đâu:* `root.yaml:8-10`, `apps/kube-prometheus-stack.yaml:9-16`, `apps/argocd.yaml:12`.

**B1.2** Source thứ hai là Git repo, gắn `ref: values`. Trong source thứ nhất (chart), `$values` được thay bằng gốc của repo đó,
nên `$values/deploy/argocd/values/argocd.yaml` trỏ tới file values trong Git. Chart ở ngoài Git, values ở trong Git.

Nếu source thứ hai trỏ nhầm branch, Argo CD render chart với values của branch đó. Nếu file có ở đó, cluster lặng lẽ nhận một
cấu hình khác. Nếu không có, Application lỗi `ComparisonError` (A8.6).

*Ở đâu:* `apps/argocd.yaml:15-26`, và mọi Application chart khác.

**B1.3**

- **Git dùng `main`:** mỗi commit vào `main` được deploy. Đó chính là GitOps, và cổng chặn phải là review trước khi merge.
- **Chart ghim version:** có hai lý do.
  - Dựng lại hôm nay và tuần sau ra cùng một thứ.
  - Nâng cấp là một thay đổi có chủ đích, một dòng, có trong `git log`.

  Không ghim thì một bản chart mới của upstream có thể vào cluster mà không ai commit gì.
- **Rủi ro của `main`:** không có môi trường nào đứng trước. Một commit hỏng tới cluster trong khoảng ba phút. Ở phase app,
  dev/prod được tách bằng file values và pull request (`Common B4.1`), không bằng branch.

*Ở đâu:* `targetRevision` trong `root.yaml` và `apps/*.yaml`; bảng version ở `README.md` mục 11.

**B1.4** `CreateNamespace=true` cho Argo CD tạo namespace đích nếu nó chưa có.

- **`ingress-nginx`, `cert-manager`, `external-secrets`:** không ai cần namespace của chúng trước khi chúng được cài.
- **`monitoring` và `cattle-system`:** do `platform-secrets` tạo ở wave -1. Secret mà Grafana, Alertmanager và Rancher đọc phải
  nằm sẵn trong đó *trước khi* chart được cài. Thêm `CreateNamespace` vào hai Application kia cũng không hại gì, nhưng sẽ làm
  người đọc hiểu sai ai tạo namespace.
- **`aws-ebs-csi-driver`:** cài vào `kube-system`, vốn đã có.

*Ở đâu:* `syncOptions` trong `apps/*.yaml`; `manifests/platform-secrets/namespaces.yaml`.

**B1.5** Mỗi manifest trong hai thư mục đó tự ghi namespace của nó, vì chúng rải trên nhiều namespace: `ingress-nginx`,
`monitoring`, `cattle-system`. Có resource còn là cluster-scoped: `Namespace`, `ClusterSecretStore`, `ClusterIssuer`.

**Quy tắc:** mọi resource namespaced phải có `metadata.namespace`. Thiếu nó thì Argo CD không có namespace đích để điền.
Resource có thể bị apply vào `default`, hoặc sync lỗi, tuỳ version **[kiểm chứng trên v3.5]**. Cả hai đều sai.

*Ở đâu:* `apps/platform-secrets.yaml:17-19`, `apps/platform-tls.yaml:19-20`.

**B1.6** Mặc định Argo CD so sánh Git với cluster ở phía nó. Các field do API server hoặc webhook điền mặc định thì Git không có,
nên hiện ra như khác biệt. `ServerSideDiff=true` bắt Argo CD hỏi API server bằng một lần dry-run server-side apply, và so với
kết quả đó. Như vậy diff khớp với thứ API server thật sự sẽ apply.

Nó được thêm khi xử lý `platform-tls` `OutOfSync` (A8.5). Resource của `platform-tls` đều là CRD của cert-manager và External
Secrets, có nhiều giá trị mặc định.

*Ở đâu:* `apps/platform-tls.yaml:11`; evidence, bảng "Problems found and fixed".

**B1.7** Argo CD truyền version của cluster cho Helm khi render. Với Kubernetes 1.37, chart từ chối render, và Application lỗi
`chart requires kubeVersion`. Không có gì được apply, Rancher đang chạy vẫn chạy nguyên.

Đó là điều tốt vì nó biến một quy tắc trong tài liệu thành một cổng chặn thật: không nâng Kubernetes vượt quá thứ Rancher hỗ trợ
mà không chọn trước một bản Rancher tương thích (design §4.2.1). Nếu không có cổng, Rancher sẽ được cài lên một cluster nó chưa
từng được test.

*Ở đâu:* `apps/rancher.yaml:14-17`; troubleshooting, dòng `kubeVersion`.

**B1.8** `retry` cho một lần sync lỗi được thử lại với backoff, trong một số lần giới hạn. **Không đặt `retry` không có nghĩa
là không retry:** khi Application không khai báo, automated sync tự gắn `retry: {limit: 5}` cho operation của nó
(`controller/appcontroller.go`). Khoảng chờ theo backoff mặc định, 5 giây nhân đôi mỗi lần **[kiểm chứng]** trong tài liệu
của bản 3.5. Phase App đã thấy đúng điều này trên cluster:
operation có `initiatedBy: automated`, `retry: {"limit":5}`, message `(retried 5 times)` (`App A7.1`). Hết năm lần thì sync
`Failed`, và automated sync không thử lại cùng commit nữa, kể cả khi bật `selfHeal`. Nó chỉ chạy lại khi có commit mới lên
`main` trong lúc app còn `OutOfSync`, hoặc khi sync tay. Evidence ghi `platform-tls` "thử lại liên tục" khi deadlock (A8.5); đó có thể là chính các lần retry mặc định
này **[kiểm chứng]** với log của controller.

Vậy lỗi tạm thời như "webhook chưa sẵn sàng" đã được mặc định che phần lớn. Đặt `retry` tường minh chỉ để chọn con số khác,
và để người đọc file thấy được hành vi đó.

*Ở đâu:* không có trong `apps/*.yaml`, nên dùng mặc định.

**B1.9** Tên resource của chart được sinh từ release name, ví dụ `argocd-server` và `argocd-repo-server`. `make bootstrap` cài
bằng `helm upgrade --install argocd`. Nếu Application dùng một `releaseName` khác, Argo CD render ra object tên khác, tức cài một
bản Argo CD thứ hai bên cạnh thay vì tiếp quản bản đang chạy. Bản cũ trở thành rác không ai quản lý, và hai controller cùng
reconcile một cluster.

*Ở đâu:* `apps/argocd.yaml:21`; `Makefile`, target `bootstrap`.

### B2. `values/argocd.yaml`

**B2.1** Check chạy trên mỗi Application con, và `root` dùng kết quả đó.

1. **Mặc định:** `Progressing`, "waiting for the child Application".
2. **Chưa có `status`, `health` hoặc `sync`:** trả mặc định. Application vừa được tạo, controller chưa xử lý nó.
3. **Con `Degraded`:** trả `Degraded` kèm thông báo của con (B2.2).
4. **Con `Healthy` và `Synced`:**
   - Nếu danh sách resource rỗng, trả `Degraded` (B2.3).
   - Nếu không, trả `Healthy`.
5. **Mọi trường hợp khác:** `Healthy` nhưng `OutOfSync`, `Progressing`, `Missing`, `Suspended`, `Unknown` đều giữ mặc định.

Mặc định là `Progressing` vì check phải *an toàn khi không biết*. Trạng thái nào chưa được nghĩ tới thì wave sau chờ, chứ không
chạy. Mặc định `Healthy` chính là lỗi của bản cũ.

*Ở đâu:* `values/argocd.yaml:38-63`.

**B2.2** Không có nhánh đó, con `Degraded` rơi vào mặc định `Progressing`. `root` sẽ `Progressing` mãi, wave sau không bao giờ
chạy, và không chỗ nào nói vì sao. Truyền `Degraded` lên thì `root` chuyển `Degraded` kèm thông báo lỗi của con. Người vận hành
biết ngay nhìn vào đâu. Evidence ghi rõ nhánh này chưa chạy thật lần nào.

*Ở đâu:* `values/argocd.yaml:31-32`, `:47-51`.

**B2.3** Một Application render ra rỗng thì không có gì để thiếu và không có gì để hỏng. Nên nó `Healthy` và `Synced` ngay lập
tức, và `root` đi qua mọi wave trong một giây.

Tình huống thật: `path:` trỏ tới một thư mục *có tồn tại* nhưng không có manifest ở cấp đó. Ví dụ `deploy/argocd/manifests`:
nó chỉ chứa thư mục con, và directory source mặc định không đệ quy. Gõ nhầm thành một thư mục không tồn tại thì nhiều khả năng
Argo CD báo `ComparisonError` ("app path does not exist") **[kiểm chứng]**, vì Git không lưu thư mục rỗng; trường hợp đó giống
A8.6.

*Ở đâu:* `values/argocd.yaml:32-34`, `:54-58`.

**B2.4** Có hai trường hợp.

- **Con `Healthy` nhưng `OutOfSync` mãi:** ví dụ một field luôn bị ghi lại (A4.5), hoặc sync lỗi nhưng mọi thứ đang chạy vẫn
  khoẻ.
- **Con `Suspended`:** ví dụ một CronJob hay rollout đang tạm dừng.

Cả hai rơi vào mặc định `Progressing`. Comment trong file ghi rằng chúng chưa từng xảy ra ở đây. Nếu xảy ra, tôi sửa gốc ở con:
diff noise thì dùng `ServerSideDiff` hoặc `ignoreDifferences` hẹp. Nếu một con được phép `Suspended`, thêm nhánh coi `Suspended`
là đủ cho con đó. Ngoài ra, một alert "Application không `Synced` quá 15 phút" bắt được cả hai (A7.1).

*Ở đâu:* `values/argocd.yaml:36-37`.

**B2.5** TLS kết thúc ở ingress-nginx, bằng certificate wildcard. Từ ingress-nginx tới `argocd-server` là HTTP thường trong
cluster. Nếu không có `server.insecure`, `argocd-server` sẽ chuyển hướng request HTTP đó sang HTTPS, trình duyệt quay lại
ingress, và cứ thế lặp mãi.

**Đoạn không mã hoá:** từ pod ingress-nginx tới pod `argocd-server`, qua pod network của Calico. Muốn mã hoá cả đoạn đó thì bật
TLS passthrough ở ingress, hoặc cho ingress nói HTTPS tới backend.

*Ở đâu:* `values/argocd.yaml:64-67`.

**B2.6** Ingress cần một mục `tls` cho host thì ingress-nginx mới phục vụ HTTPS cho host đó, và mới chuyển HTTP sang HTTPS.
Không có `secretName` thì nó dùng certificate mặc định, tức wildcard (`default-ssl-certificate`). Bỏ hẳn mục đó thì host vẫn
được phục vụ qua HTTPS bằng certificate mặc định, nhưng ingress-nginx không còn tự chuyển HTTP sang HTTPS: request HTTP được
trả lời luôn, không bị chuyển hướng.

*Ở đâu:* `values/argocd.yaml:92-96`; `values/ingress-nginx.yaml:19-22`.

**B2.7** Memory không nén được: một process vượt quá mức sẽ làm cạn node, và kernel sẽ giết một thứ nào đó, có thể là thứ quan
trọng hơn. Limit giới hạn thiệt hại vào đúng container đó.

CPU thì nén được: thiếu CPU chỉ làm chậm. CPU limit gây throttle kể cả khi node còn rảnh, làm chậm thêm mà không bảo vệ được gì;
request đã đủ để chia CPU công bằng khi node bận.

*Ở đâu:* mọi khối `resources` trong `values/*.yaml`.

**B2.8** Lần tiếp quản sẽ đổi object. Pod khởi động lại, hoặc `argocd` báo `OutOfSync` ngay sau bootstrap (troubleshooting).
Hai bên có thể lệch nhau vì hai lý do.

- **Version:** Makefile đọc version từ `apps/argocd.yaml` trên ổ đĩa. Quên `git pull` thì Helm cài bản cũ, còn Argo CD đọc bản
  mới trên GitHub.
- **Values:** cùng lý do. File values trên ổ và trên GitHub khác nhau.

*Ở đâu:* `values/argocd.yaml:1-3`; `Makefile` (`ARGOCD_VERSION`, `bootstrap`).

### B3. `platform-secrets`

**B3.1** Không có `auth` thì External Secrets dùng chuỗi credential mặc định của SDK AWS, và tìm thấy instance profile của node
qua metadata service.

**Node role:**

- Đọc được sáu secret: `llm`, `github`, `rancher`, `rancher-tls`, `alertmanager`, `wildcard-tls`.
- Chỉ ghi được `wildcard-tls`, bằng `PutSecretValue` và `DeleteResourcePolicy`. External Secrets gọi cả hai ở mỗi lần push.

Tên secret nằm trong `infra/terraform/cluster/main.tf`, quyền trong `iam.tf`.

*Ở đâu:* `manifests/platform-secrets/cluster-secret-store.yaml:3-6`; `Terraform B7.3`.

**B3.2** Secret của Grafana, Alertmanager và Rancher phải nằm sẵn trong namespace của chúng trước khi chart được cài. Nên
namespace phải tồn tại trước cả chart. Trong một Application, wave hoạt động như giữa các Application: số nhỏ trước.

| Wave | Resource | Chờ để |
|---|---|---|
| -1 | `Namespace` `cattle-system`, `monitoring` | Có chỗ để đặt Secret |
| 0 | `ClusterSecretStore` | Store `Valid`, tức đã nói chuyện được với AWS, trước khi ExternalSecret nào dùng nó |
| 1 | Các `ExternalSecret`, generator `Password`, bản khôi phục certificate | |

*Ở đâu:* annotation `sync-wave` trong từng file của `manifests/platform-secrets/`.

**B3.3**

- **`refreshPolicy: CreatedOnce`:** Secret chỉ được tạo khi chưa có, và không bao giờ cập nhật lại. Sau đó cert-manager sở
  hữu nó. Nếu External Secrets còn refresh, nó sẽ ghi đè certificate vừa được gia hạn bằng bản backup cũ hơn.
- **`creationPolicy: Orphan`:** External Secrets tạo Secret nhưng không làm chủ nó. Xoá ExternalSecret, hoặc Argo CD prune nó,
  không bao giờ xoá certificate đang chạy.

*Ở đâu:* `manifests/platform-secrets/wildcard-tls-restore.yaml:17-27`.

**B3.4** cert-manager giữ một Secret có sẵn khi certificate bên trong còn hạn, đúng tên, đúng loại key, và annotation ghi *cùng
issuer* với spec. Annotation được so bằng name, kind và group. PushSecret chỉ chép `tls.crt` và `tls.key`, không chép annotation.
Nên template của bản khôi phục phải tự gắn lại cả bốn annotation, kể cả `certificate-name`.

Nếu `issuer-name` sai, cert-manager coi Secret là do issuer khác cấp, và xin certificate mới đè lên. Sau đó PushSecret chép
certificate mới đó về backup.

*Ở đâu:* `wildcard-tls-restore.yaml:28-37`; comment trên `issuerRef` ở `platform-tls/wildcard-certificate.yaml:18-28`.

**B3.5** ExternalSecret lỗi `could not get secret data from provider`, và Argo CD đánh giá nó `Degraded`. Kéo theo
`platform-secrets` `Degraded`, `root` `Degraded`, và wave 0 không chạy.

**Trên account mới:** seed backup một lần bằng placeholder (guide bước 8.3).

- Placeholder là một certificate *cố ý sai*: tên `placeholder.invalid`, hạn 1 ngày. Tên không khớp nên cert-manager cấp đè, và
  PushSecret thay placeholder bằng certificate thật.
- **Vì sao phải sai:** template gắn annotation issuer đúng lên bất cứ gì đọc về. Một certificate tự ký trông hợp lệ cho
  `*.recruitai.io.vn` sẽ qua mọi kiểm tra và được giữ lại. Nó sẽ được phục vụ trên mọi UI, rồi mười phút sau được push đè lên
  backup thật.

*Ở đâu:* `wildcard-tls-restore.yaml:7-8`; README mục 6.

**B3.6** `refreshInterval: "0"` nghĩa là sinh một lần, không bao giờ refresh. Với một generator, mỗi lần refresh là một mật
khẩu mới, nên bất kỳ khoảng nào khác "0" đều đổi Secret theo chu kỳ. Grafana chỉ đọc mật khẩu lúc khởi động, nên Secret và mật
khẩu của Grafana đang chạy sẽ lệch nhau tới lần pod khởi động lại.

Dựng lại cluster thì có mật khẩu mới. Nó không nằm trong Git, không nằm trong Secrets Manager, không ai gõ ra. Đọc bằng
`kubectl get secret grafana-admin` (guide bước 10). Grafana không có volume, nên cũng không có gì cần mật khẩu cũ.

*Ở đâu:* `manifests/platform-secrets/grafana-admin.yaml`.

**B3.7** Alertmanager muốn mật khẩu SMTP nằm *bên trong* file cấu hình của nó. Viết cấu hình trong values của chart thì mật khẩu
phải nằm trong Git. Template của ExternalSecret giữ cấu trúc (route, receiver, nhóm alert) trong Git, còn tài khoản, app
password và người nhận được điền từ `medical-rag/alertmanager`. Chart được chỉ tới Secret đó bằng `useExistingSecret: true` và
`configSecret: alertmanager-email`.

*Ở đâu:* `manifests/platform-secrets/alertmanager-email.yaml`; `values/kube-prometheus-stack.yaml:1-7`.

**B3.8** Trong chart 2.15.1, `bootstrapPassword` làm chart render thêm một `bootstrap-secret` thứ hai và một biến
`CATTLE_BOOTSTRAP_PASSWORD` thứ hai. Khi đó Argo CD (qua chart) và External Secrets cùng làm chủ một Secret, và `selfHeal` của
bên này đè lên bên kia mãi mãi. Mật khẩu được đưa vào qua `extraEnv` từ Secret do External Secrets tạo.

*Ở đâu:* `values/rancher.yaml:23-32`; troubleshooting, dòng "flipping".

### B4. `platform-tls`

**B4.1**

- **Không có email:** Let's Encrypt không còn gửi email báo hết hạn, và cert-manager tự gia hạn.
- **`privateKeySecretRef`:** tên Secret giữ private key của account ACME. cert-manager tự tạo nó ở lần đăng ký đầu.
- **Khi dựng lại:** Secret đó mất theo cluster, nên mỗi lần dựng lại là một account mới. Không ảnh hưởng hạn mức certificate,
  vì hạn mức tính theo bộ tên. Nhưng có một hạn mức riêng cho việc tạo account: 10 account mỗi IP trong 3 giờ. Mỗi lần dựng lại
  đăng ký hai account, staging và production, mỗi cái tính trên server Let's Encrypt của nó. Dựng lại liên tục trong một buổi
  có thể chạm hạn mức này.

*Ở đâu:* `manifests/platform-tls/cluster-issuers.yaml`.

**B4.2**

- **Vì sao có `region`:** Route 53 là global, nhưng SDK AWS vẫn cần một region để khởi tạo và ký request.
- **Quyền của node role:**
  - `ChangeResourceRecordSets` chỉ khi mọi bản ghi được sửa có tên `_acme-challenge.recruitai.io.vn` và loại `TXT`, qua điều
    kiện `ChangeResourceRecordSetsNormalizedRecordNames` và `…RecordTypes`.
  - `ListResourceRecordSets` trên zone, `GetChange`, `ListHostedZonesByName` để tìm zone và chờ thay đổi lan ra.
- **Hai cờ trong `values/cert-manager.yaml`:** `--dns01-recursive-nameservers-only` buộc cert-manager *chỉ* tự kiểm tra bản
  ghi TXT qua `--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53`, thay vì hỏi resolver của VPC hay tự hỏi nameserver
  authoritative. Nó thấy đúng thứ Let's Encrypt sẽ thấy. Cái giá: resolver public có thể cache câu trả lời "không có" theo TTL
  âm, làm lần kiểm tra chậm hơn.

*Ở đâu:* `cluster-issuers.yaml:17-23`; `infra/terraform/cluster/iam.tf:88-124`; `values/cert-manager.yaml:6-10`.

**B4.3**

| Wave | Resource | Chờ |
|---|---|---|
| 0 | Hai `ClusterIssuer` | Issuer `Ready`, tức đã đăng ký account ACME |
| 1 | `Certificate` | Certificate `Ready`: được giữ từ bản khôi phục, hoặc được cấp mới |
| 2 | `PushSecret` | Chỉ backup khi đã có certificate thật, để không push một Secret rỗng |

Argo CD có sẵn health check cho resource của cert-manager và External Secrets, nên "chờ" ở đây là chờ điều kiện `Ready` thật,
không chỉ chờ object được tạo.

*Ở đâu:* annotation `sync-wave` trong `manifests/platform-tls/`.

**B4.4**

- **`deletionPolicy: None`:** xoá PushSecret, hoặc cả cluster, không bao giờ xoá secret trong Secrets Manager. Backup sống sót
  qua teardown là yêu cầu cốt lõi.
- **`refreshInterval: 10m`:** PushSecret so và đẩy Secret mỗi 10 phút. Certificate được gia hạn sẽ được backup trong vòng 10
  phút. Đổi lại, một certificate *sai* cũng được backup nhanh như vậy (A8.3).
- **Bản cũ ở đâu:** External Secrets ghi bằng `PutSecretValue`, nên bản mới nhận nhãn `AWSCURRENT` và bản trước chuyển sang
  `AWSPREVIOUS`. Chỉ đúng một thế hệ: lần ghi tiếp theo làm bản đó mất nhãn, và không có cam kết giữ lại. Xem những gì còn bằng
  `list-secret-version-ids --include-deprecated`.
- **Điều kiện ghi:** secret phải có tag `managed-by=external-secrets` (Terraform đặt sẵn), nếu không PushSecret từ chối ghi.

*Ở đâu:* `manifests/platform-tls/wildcard-tls-backup.yaml`; evidence, "Two things this rebuild also showed".

**B4.5** Cờ đó làm Secret của certificate thành con của object `Certificate`. `platform-tls` chạy với `prune: true`. Một lần
prune sai, ví dụ file certificate bị xoá hay đổi tên nhầm, sẽ xoá luôn certificate đang chạy *và* nguồn của PushSecret trong
một bước. Để tắt, như mặc định của cert-manager, thì Secret sống độc lập với object `Certificate`.

*Ở đâu:* README mục 6.

**B4.6**

1. **Trong khoảng 3 phút:** Argo CD thấy commit và apply `Certificate` với `issuerRef` mới.
2. **cert-manager:** thấy annotation `issuer-name` trên Secret là `letsencrypt-production`, khác spec. Nó coi certificate hiện
   tại là của issuer khác và xin lại.
3. **Cấp staging:** một `CertificateRequest` gửi tới staging, giải DNS-01, và certificate staging được ghi vào Secret. Mọi UI
   nội bộ bắt đầu phục vụ một certificate trình duyệt không tin.
4. **Trong vòng 10 phút:** PushSecret đẩy certificate staging vào Secrets Manager thành `AWSCURRENT`. Bản production xuống
   `AWSPREVIOUS`.
5. **Hệ quả:** lần dựng lại sau khôi phục certificate staging. Nếu có thêm một lần ghi nữa, bản production mất nhãn.

Cách làm đúng: `make down`, lưu backup ra đĩa, rồi mới đổi. Comment trên `issuerRef` ghi đúng các bước này.

*Ở đâu:* `platform-tls/wildcard-certificate.yaml:18-28`; A8.3.

**B4.7** Bản khôi phục nằm ở wave trước PushSecret trong cùng `platform-tls`. Backup còn trống, nên bản khôi phục lỗi. Lỗi ở một
wave chặn các wave sau của cùng Application, nên PushSecret không bao giờ được tạo để ghi backup. Hai thứ chờ nhau mãi. Chuyển
bản khôi phục sang Application khác (`platform-secrets`) cắt vòng đó: lỗi của nó không còn chặn PushSecret. Và vì Application
`platform-secrets` ở wave -1 (bên trong nó, bản khôi phục ở wave 1), nó vẫn chạy trước `Certificate` khi dựng lại.

*Ở đâu:* evidence, bảng "Problems found and fixed"; A8.5.

### B5. `Makefile`

**B5.1**

- **Điều kiện:** `kubectl -n argocd get application argocd` thành công thì bỏ qua Helm, chỉ apply `root.yaml`. Không thì
  `helm upgrade --install` rồi apply `root.yaml`.
- **Sai khi:**
  - Application `argocd` bị xoá nhưng Argo CD vẫn chạy (không có finalizer nên xoá Application không gỡ Argo CD). Helm sẽ chạy
    trên các object mà field manager của Argo CD còn giữ, và conflict (A8.4).
  - Tunnel chưa mở: `get` lỗi, và Helm cũng lỗi kết nối. Vô hại, nhưng thông báo lỗi dễ gây hiểu nhầm. `>/dev/null 2>&1`
    giấu khác biệt giữa `NotFound` và lỗi quyền hay kết nối.
  - Application `argocd` còn nhưng Argo CD hỏng, ví dụ repo-server crash: bootstrap bỏ qua Helm nên không sửa được (A2.4).
- **`application` với `app`:** `app` trùng với CRD `apps.catalog.cattle.io` của Rancher (A8.7). `application` chỉ khớp
  `applications.argoproj.io` trên cluster này **[kiểm chứng]** bằng `kubectl api-resources | grep -i app`. Viết đầy đủ
  `applications.argoproj.io` thì chắc chắn nhất.

*Ở đâu:* `Makefile`, target `bootstrap`.

**B5.2** Version được ghi đúng một lần, trong Application Argo CD dùng để tự quản lý. Makefile đọc lại nó, nên lần cài đầu và
bản tự quản lý không thể lệch nhau. Ghi thẳng vào Makefile thì sẽ có hai chỗ, và sớm muộn chỉ một chỗ được sửa.

Nó dùng `=`, nên `yq` chỉ chạy khi biến được dùng, tức khi chạy `bootstrap`, không phải mỗi lần gọi `make`.

*Ở đâu:* `Makefile` (`ARGOCD_APP`, `ARGOCD_VERSION`).

**B5.3**

1. **Tắt automated sync của `root`:** `kubectl patch` đặt `automated: null`. Nếu không, `root` thấy một Application bị thiếu
   và tạo lại ngay. Dấu `-` cho `make` đi tiếp khi `root` không tồn tại, ví dụ sau một lần bootstrap lỗi.
2. **Xoá Application có label `medical-rag/volumes=true`**, timeout 10 phút. Hiện chỉ có `kube-prometheus-stack`, và finalizer
   khiến lệnh chờ mọi thứ bên dưới bị xoá.
3. **Xoá mọi PVC**, timeout 15 phút.
4. **Chờ tối đa 30 × 10 giây** tới khi AWS không còn volume nào của driver.
5. **Cổng chặn**, rồi `make infra-destroy`.

*Ở đâu:* `Makefile`, target `down`; guide bước 12.

**B5.4** Mặc định StatefulSet không xoá PVC sinh từ `volumeClaimTemplates` khi chính nó bị xoá (`whenDeleted: Retain`).
Prometheus chạy dạng StatefulSet do operator quản lý, nên PVC của nó còn lại sau khi Application đã biến mất. PVC đó do
StatefulSet controller tạo, không nằm trong resource Argo CD quản lý, nên finalizer không xoá nó. Chính việc xoá PVC, với
`reclaimPolicy: Delete`, mới làm driver xoá EBS volume.

Có thể đặt `persistentVolumeClaimRetentionPolicy` (GA từ Kubernetes 1.32) qua prometheusSpec để PVC tự xoá theo, nhưng một
bước xoá PVC tường minh trong `make down` vẫn chắc hơn, và bắt được cả PVC của các chart sau này.

*Ở đâu:* `Makefile`, target `down`; README mục 9.

**B5.5** Câu hỏi thật là "còn volume nào tính tiền không", và chỉ AWS trả lời được. Cluster có thể nói "không còn PV" trong khi
volume trên AWS vẫn đang xoá, hoặc bị kẹt. Lệnh tìm volume theo tag `project=medical-rag` và tag key `ebs.csi.aws.com/cluster`.

Bộ lọc cần *cả hai* tag. Một volume thiếu tag `project=medical-rag` không được đếm, nên cổng có thể qua trong khi vẫn còn
một volume tính tiền; tag đó do `extraVolumeTags` của driver gắn (B6.3).

**Nó dừng (exit 1) khi:**

- Không hỏi được AWS: `n=$(…) || exit 1`.
- Sau khoảng 5 phút vẫn còn volume.

Dừng *trước* khi destroy cluster, lúc driver còn chạy để làm nốt. Trong Makefile, `$$` là để `make` truyền `$` cho shell.

*Ở đâu:* `Makefile` (`CSI_VOLUMES`, `down`).

### B6. Values của các chart khác

**B6.1** Hai chart tự cài CRD của chúng (`Certificate`, `ClusterIssuer`, `ExternalSecret`, `ClusterSecretStore`, các generator).
Resource dùng các CRD đó chỉ apply được khi CRD đã có. Chúng còn cần webhook của operator chạy, vì cả hai đều có admission
webhook kiểm tra resource. Một wave riêng, cộng health check yêu cầu `Healthy` và `Synced`, bảo đảm CRD đã có và giảm mạnh khả
năng webhook chưa sẵn sàng trước wave -1. Nhưng không tuyệt đối: CA bundle của webhook (do cainjector của cert-manager và
cert-controller của External Secrets inject) có thể tới chậm hơn lúc Deployment `Available`. Retry mặc định của automated sync
che trường hợp đó (B1.8).

*Ở đâu:* `values/cert-manager.yaml:1-4`, `values/external-secrets.yaml:1-3`.

**B6.2**

- **`externalTrafficPolicy: Local`:** kết nối vào NodePort chỉ được giao cho controller *trên chính node đó*, giữ nguyên địa
  chỉ nguồn.
- **Nếu đổi sang Deployment một replica:**
  - Hai node không có controller trả lời health check thất bại, và load balancer chỉ còn một target.
  - Pod đó dời node là có một khoảng gián đoạn.
- **Nếu sửa bằng cách đổi về `Cluster`:** kube-proxy SNAT địa chỉ nguồn thành địa chỉ node, trong VPC. Allowlist
  `10.10.0.0/16` sẽ nhận cả traffic từ internet đi qua load balancer public.

DaemonSet và `Local` phải đi cùng nhau.

*Ở đâu:* `values/ingress-nginx.yaml:1-17`.

**B6.3**

- **Teardown dựa vào `reclaimPolicy: Delete`:** xoá PVC là driver xoá EBS volume. Với `Retain`, volume nằm lại sau `make down`.
- **`WaitForFirstConsumer`:** chỉ tạo volume khi pod đã được xếp lịch, ở đúng AZ của pod. EBS chỉ gắn được trong AZ của nó.
  `Immediate` có thể chọn AZ trước, và pod bị kẹt.
- **`extraVolumeTags: project: medical-rag`:** thứ giúp `make down` và budget tìm ra volume.

*Ở đâu:* `values/aws-ebs-csi-driver.yaml`.

**B6.4** Mặc định Prometheus chỉ nhận ServiceMonitor, PodMonitor và rule có label của đúng Helm release của nó. Đặt `false`
thì selector rỗng, nghĩa là nhận tất cả.

Cần từ bây giờ vì chart của app, ở phase sau, sẽ tự mang ServiceMonitor của nó mà không biết tên release của monitoring. Metric
của Argo CD cũng sẽ được nhận ngay khi bật ServiceMonitor của nó (A7.1). `probeSelectorNilUsesHelmValues` và
`scrapeConfigSelectorNilUsesHelmValues` chưa được đặt, nên Probe và ScrapeConfig vẫn chỉ nhận của release này.

*Ở đâu:* `values/kube-prometheus-stack.yaml:46-50`.

**B6.5** Mặc định `strict` khiến agent của Rancher chỉ tin CA ghi trong setting của Rancher. Certificate của
`rancher.recruitai.io.vn` là Sectigo mua, do một CA public ký, nên agent phải kiểm nó bằng trust store của hệ thống. Để `strict`
thì agent không kết nối được về Rancher.

*Ở đâu:* `values/rancher.yaml:19-21`.

**B6.6** Mất toàn bộ metric lịch sử: Prometheus giữ `retention: 24h` trên PVC 10Gi, và `make down` xoá PVC đó. Grafana không có
volume (`persistence.enabled: false`); dashboard được nạp lại từ chart mỗi lần khởi động. Chấp nhận được vì monitoring ở đây là
để nhìn một phiên làm việc, và cluster bị dựng lại liên tục. Metric dài hạn cần remote storage, như Thanos hay một Prometheus
ngoài cluster.

*Ở đâu:* `values/kube-prometheus-stack.yaml:44-45`, `:57-64`, `:103-105`.

**B6.7** Cluster không có AWS cloud controller, nên Service `LoadBalancer` sẽ `Pending` mãi. Terraform tạo sẵn hai NLB trỏ vào
30080 (public, HTTP) và 30443 (nội bộ, HTTPS) trên mọi node, nên cổng phải cố định và khớp với Terraform. Đổi cổng ở một bên mà
không đổi bên kia thì target group unhealthy (`Terraform B6.6`).

Trước khi Secret wildcard tồn tại, nginx phục vụ certificate tự ký của nó, `Kubernetes Ingress Controller Fake Certificate`.
Thấy nó trên trình duyệt nghĩa là certificate chưa có (troubleshooting).

*Ở đâu:* `values/ingress-nginx.yaml:6-12`, `:19-22`.

### B7. Evidence

**B7.1** cert-manager in event dưới dạng tuổi, không có timestamp, nên thời điểm `Issuing` phải được suy ra.

- `Ready` chuyển `True` lúc 13:41:26, đọc thẳng từ object.
- `describe` cho thấy 100 giây giữa event `Issuing` và `The certificate has been successfully issued`.
- 13:41:26 − 100 s = **13:39:46**. Secret khôi phục có `creationTimestamp` 13:40:34, nên cách nhau khoảng 48 giây.
- **Giả định:** `Ready` rơi đúng lúc cấp xong.
- **Kiểm chứng chéo:** Let's Encrypt lùi `notBefore` khoảng 3510 giây. Con số đó đo từ thí nghiệm sau (revision 3, `notBefore`
  13:08:55, cấp khoảng 14:07:25). Áp vào `notBefore` của revision 1 (12:42:56) cũng ra 13:41:26. Nếu dùng tròn 3600 giây thì
  `Issuing` rơi *sau* khi Secret đã có, trái với event "Secret does not exist".

**Cận dưới:** object `Certificate` được tạo lúc hoặc trước lần reconcile đó, nên hai Application cách nhau *ít nhất* 48 giây.
Phần không cần suy ra là thứ tự: event nói Secret không tồn tại, và Secret có sau đó.

*Ở đâu:* evidence, "Why the restore lost the race".

**B7.2**

- **Bằng chứng:**
  - `status.revision` của Certificate rỗng. Mọi lần cấp mà cert-manager hoàn tất đều đặt revision, nên rỗng nghĩa là không có
    lần nào.
  - Không có `CertificateRequest`.
  - Không có event `Issuing` chỉ có nghĩa nếu lúc đọc vẫn còn trong TTL của event (khoảng 1 giờ), mà thời điểm đọc không được
    ghi lại.
- **Vì sao fingerprint chưa đủ:** PushSecret chép Secret đang chạy về backup, nên backup và certificate đang phục vụ kiểu gì
  cũng trùng nhau. Nó chứng minh backup chạy, không chứng minh không có lần cấp nào.
- **Dòng issuer đọc bằng `openssl` (`YR1`):** chứng minh certificate đó là production (A5.6).
- **Không có mốc so sánh:** `notAfter` không được ghi lại trước teardown.

*Ở đâu:* evidence, "Rebuild with the corrected check — 2026-09-19".

**B7.3** `root` dùng health check Lua cho mọi Application con, và health của `root` là tổng health của các con. `root` chỉ
`Healthy` khi mọi con `Healthy` *và* `Synced`, và mỗi con lại gồm health của từng resource, kể cả health có sẵn của
ExternalSecret và Certificate. Nên một lệnh `kubectl wait` trên `root` chờ cả nền tảng.

Điều đó chỉ đúng với check hiện tại. Con số 2 m 22 s ngày 18/09 đo dưới check cũ, chỉ đọc health: con báo `Healthy` khi còn
thiếu resource, nên `root` có thể `Healthy` sớm, và con số có thể thấp hơn thực tế (evidence, "The cause"). Chưa có lần đo thời
gian nào với check mới.

*Ở đâu:* evidence, "Rebuild from nothing"; guide bước 13.

**B7.4** Theo mục "Still to record":

- Bảng `make apps` và ảnh chụp.
- Timeout khi không có VPN, `200` khi có.
- Target control plane `up`; `amtool` chỉ thấy `Watchdog`; email alert thử.
- Các kiểm tra của Rancher:
  - Query security group trả `[]`.
  - `308` từ load balancer public.
  - `Verification: OK` từ WireGuard gateway, và thời điểm handshake.
  - Timeout khi không có VPN, `pong` khi có.
  - `Test-NetConnection`: `True` trên 443, `False` trên 6443.
- Ảnh chụp dashboard etcd của Grafana.
- `time make down`, dòng `Destroy complete!`, và `describe-volumes` rỗng.
- `kubectl get applications.argoproj.io -w` cùng log của application-controller từ lúc apply `root`.

Cách thu: chạy trong lần dựng lại tới, dán output vào evidence *ngay khi chạy*. Thời điểm đọc cũng ghi lại, vì evidence 19/09
thiếu đúng thông tin đó.

*Ở đâu:* evidence, "Still to record".
