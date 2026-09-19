# Câu hỏi về Argo CD và GitOps

Bộ câu hỏi về phase GitOps của project: Argo CD tự cài và giữ mọi thứ chạy trong cluster từ `deploy/argocd/`, gồm chính nó,
ingress-nginx, EBS CSI driver, External Secrets, cert-manager, monitoring và Rancher. Dùng để tự kiểm tra mức hiểu và luyện
phỏng vấn. Đáp án nằm ở [`answers.md`](answers.md), cùng số thứ tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Phỏng vấn** (ưu tiên) | Bạn giải thích được vì sao nền tảng được giao cho Argo CD theo cách này, vận hành nó ra sao, đã hỏng ở đâu và giới hạn của nó |
| **B. Chi tiết** | Bạn biết vì sao từng file trong `deploy/argocd/` và `Makefile` được viết như vậy, và đổi đi thì cái gì hỏng |

Bộ liên quan: [tổng quan project](../common/questions.md), [Terraform](../terraform/questions.md),
[Ansible](../ansible/questions.md), [AWS](../aws/questions.md). Tham chiếu dạng `Common A5.2` trỏ tới bộ tương ứng. Chart của
app và dev/prod có bộ riêng: [App](../app/questions.md). Pipeline Jenkins thuộc phase sau; câu về nó nằm ở `Common A5` và
`Common B4`.

**Cách dùng.** Làm Phần A trước: trả lời thành tiếng, khoảng một phút mỗi câu, rồi so với đáp án. Nhóm A8 là các câu chuyện
sự cố; tập kể chúng tới khi nói trôi mà không cần nhìn. Phần B làm không mở code; chỉ tính là đã hiểu khi bạn nói được *lý
do*. Trong mỗi nhóm, câu hỏi khó dần về cuối.

---

## Phần A — Phỏng vấn

### A1. Tổng quan và lựa chọn

**A1.1** Trình bày phần GitOps của project trong hai phút.

**A1.2** GitOps nghĩa là gì, nói bằng chính project này? Nó khác gì một pipeline CI chạy `helm upgrade` vào cluster?

**A1.3** Vì sao chọn Argo CD mà không phải Flux?

**A1.4** Argo CD quản lý những gì, và cố ý *không* làm những gì?

**A1.5** Vì sao chart lấy từ Helm repository của upstream còn values nằm trong Git? Sao không render sẵn manifest rồi commit,
hoặc dùng Kustomize?

**A1.6** App-of-apps là gì? Vì sao không dùng ApplicationSet?

**A1.7** Repo public và Argo CD không có credential Git nào. Đó là điểm mạnh hay rủi ro? Repo chuyển sang private thì phải làm
gì?

**A1.8** Khi app và Jenkins vào ở phase sau, chúng cắm vào cấu trúc này thế nào?

**A1.9** Vì sao Jenkins ghi digest vào Git, mà không dùng Argo CD Image Updater?

### A2. Bootstrap: Argo CD tự quản lý chính nó

**A2.1** Argo CD cài mọi thứ. Vậy ai cài Argo CD?

**A2.2** Argo CD quản lý chính nó. Lúc nó tiếp quản bản cài bằng Helm, pod có khởi động lại không, và làm sao bạn chắc?

**A2.3** Chạy lại `make bootstrap` trên một cluster đang chạy thì chuyện gì xảy ra?

**A2.4** Một commit sai làm chính Argo CD hỏng, ví dụ repo-server crash liên tục. Ai sửa, sửa bằng gì, và trong lúc đó các
workload ra sao?

**A2.5** Bạn nâng cấp Argo CD lên phiên bản mới thế nào?

### A3. Thứ tự: sync wave và health

**A3.1** Sync wave là gì, và khác sync hook ở đâu? Thứ tự *trong* một Application và thứ tự *giữa* các Application khác nhau
thế nào?

**A3.2** Vì sao mặc định các wave giữa các Application không chờ nhau, và bạn khôi phục việc chờ đó thế nào?

**A3.3** `Healthy` và `Synced` khác nhau thế nào? Vì sao chỉ đọc `Healthy` là không đủ để xếp thứ tự?

**A3.4** Vì sao nền tảng được chia thành bốn wave như hiện tại? Lấy một ví dụ: nếu gộp hai wave thì cái gì hỏng?

**A3.5** CRD phải có trước custom resource dùng nó. Bạn đảm bảo điều đó bằng gì, và còn cách nào khác?

**A3.6** Một Application ở wave -1 bị `Degraded`. Phần còn lại của nền tảng ra sao, và thiết kế của bạn xử lý thế nào?

**A3.7** Cổng chặn giữa các wave của bạn còn những giới hạn gì?

### A4. Sync policy, drift và rollback

**A4.1** `prune` và `selfHeal` làm gì? Vì sao riêng Application `argocd` lại tắt `prune`?

**A4.2** Có người `kubectl edit` một Deployment do Argo CD quản lý. Chuyện gì xảy ra? Giữa một sự cố, bạn cần sửa nóng trên
cluster thì làm thế nào?

**A4.3** Rollback một addon thế nào? Sao không bấm Rollback trong UI của Argo CD?

**A4.4** Commit xong bao lâu thì cluster thay đổi? Vì sao không dùng webhook?

**A4.5** Một Application cứ `OutOfSync` dù không ai sửa gì. Bạn tìm nguyên nhân thế nào?

**A4.6** Vì sao mọi Application con đều bật server-side apply?

**A4.7** Xoá một file trong `apps/` thì chuyện gì xảy ra? Còn nếu xoá nhầm chính `root`?

**A4.8** Một lần sync lỗi giữa chừng, ở wave thứ hai. Cluster lúc đó ở trạng thái nào? Sync có atomic không?

**A4.9** Một Deployment có HorizontalPodAutoscaler. Argo CD và HPA có tranh nhau `replicas` không, và bạn xử lý thế nào?

### A5. Secret và certificate

**A5.1** Git không chứa secret nào. Vậy secret vào cluster bằng đường nào? Vì sao chọn External Secrets mà không phải Sealed
Secrets, SOPS hay Vault?

**A5.2** External Secrets lấy quyền đọc Secrets Manager từ đâu? Cách đó có rủi ro gì?

**A5.3** Rotate một secret, ví dụ app password của hộp thư gửi alert, thế nào? Có cần commit không?

**A5.4** Vì sao certificate cho các UI nội bộ được xin bằng DNS-01, và vì sao là một wildcard?

**A5.5** Let's Encrypt chỉ cấp 5 certificate cho cùng một bộ tên trong 7 ngày, còn cluster này bị dựng lại thường xuyên. Bạn
giải quyết thế nào?

**A5.6** cert-manager báo `Ready=True`. Vậy certificate đang dùng chắc chắn là certificate production chưa?

### A6. Truy cập và bảo mật

**A6.1** UI của Argo CD mở cho ai, và được bảo vệ bằng mấy lớp?

**A6.2** Ai đăng nhập được Argo CD? Team có thêm ba kỹ sư thì bạn thay đổi gì?

**A6.3** Kẻ tấn công push được vào branch `main`. Họ làm được gì trên cluster, và bạn chặn thế nào?

**A6.4** Argo CD có quyền gì trên cluster? Nếu Argo CD bị chiếm thì thiệt hại tới đâu?

**A6.5** Prometheus và Alertmanager không có đăng nhập. Như vậy có chấp nhận được không?

### A7. Vận hành

**A7.1** Làm sao bạn biết một lần sync bị lỗi, khi Argo CD notifications đang tắt?

**A7.2** Dựng lại toàn bộ nền tảng từ đầu mất bao lâu, và bạn đo thế nào?

**A7.3** Vì sao teardown là `make down` chứ không chỉ là `terraform destroy`?

**A7.4** `make down` treo ở bước xoá Application. Bạn làm gì?

**A7.5** Argo CD và các addon chiếm bao nhiêu tài nguyên trên ba node 8 GB? Bạn đặt request và limit dựa trên gì?

**A7.6** Một chart upstream ra bản mới có breaking change. Quy trình nâng cấp của bạn thế nào?

**A7.7** Công ty muốn thêm một cluster thứ hai, hoặc một môi trường staging. Bạn thay đổi gì trong cấu trúc này?

**A7.8** Mất cả namespace `argocd`, hoặc phải dựng lại riêng Argo CD. Bạn khôi phục thế nào, và có cần backup gì không?

**A7.9** Bạn triển khai canary hay blue-green với Argo CD thế nào?

**A7.10** Đang có sự cố, hoặc cuối tuần, bạn muốn chặn mọi thay đổi tự động vào cluster. Argo CD làm được không?

### A8. Sự cố và bài học

**A8.1** Kể về một sự cố thật trong phase này và cách bạn tìm ra nguyên nhân gốc.

**A8.2** Bạn chứng minh bản sửa đó có tác dụng thế nào?

**A8.3** Kể về một sai lầm của chính bạn trong phase này.

**A8.4** `make bootstrap` chạy lần hai lỗi `conflict with "argocd-controller"`. Chuyện gì đã xảy ra?

**A8.5** `platform-tls` `OutOfSync` mãi, sync thử lại không dứt. Nguyên nhân là gì?

**A8.6** Một Application kẹt `Unknown` với `ComparisonError: … no such file or directory`, dù file có trên máy bạn. Vì sao?

**A8.7** `kubectl -n argocd get app root` trả về `NotFound`, dù UI vẫn thấy `root`. Vì sao?

**A8.8** Grafana trả `502 Bad Gateway` ngay sau khi đăng nhập. Bạn tìm nguyên nhân thế nào?

### A9. Nhìn lại

**A9.1** Nếu có thêm một tuần cho phần này, bạn sẽ làm gì?

**A9.2** Ở một công ty thật, bạn sẽ làm khác đi điều gì?

---

## Phần B — Chi tiết

### B1. `root` và các Application

**B1.1** `root.yaml` không có `resources-finalizer`, `kube-prometheus-stack` thì có. Vì sao lại khác nhau? Nếu thêm finalizer
vào `root` rồi xoá `root` thì sao?

**B1.2** Application cho chart có hai source. `ref: values` và `$values` làm gì? Nếu source thứ hai trỏ nhầm branch thì sao?

**B1.3** `targetRevision` của Git là `main`, còn của chart là một version cụ thể. Vì sao khác nhau, và `main` có rủi ro gì?

**B1.4** Vì sao `ingress-nginx`, `cert-manager` và `external-secrets` có `CreateNamespace=true`, còn `kube-prometheus-stack` và
`rancher` thì không?

**B1.5** `platform-secrets` và `platform-tls` không đặt `destination.namespace`. Vì sao làm vậy được, và manifest bên trong phải
tuân theo quy tắc gì?

**B1.6** `platform-tls` là Application duy nhất có `compare-options: ServerSideDiff=true`. Nó giải quyết vấn đề gì?

**B1.7** Chart Rancher khai báo `kubeVersion: "< 1.37.0-0"`. Nâng Kubernetes lên 1.37 thì Application `rancher` ra sao, và vì
sao đó lại là điều tốt?

**B1.8** Không Application nào đặt `syncPolicy.retry`. Điều đó ảnh hưởng gì, và bạn có thêm không?

**B1.9** Vì sao `helm.releaseName: argocd` phải trùng đúng tên trong lệnh `helm install` của `make bootstrap`?

### B2. `values/argocd.yaml`

**B2.1** Đi qua từng nhánh của health check Lua cho `argoproj.io/Application`. Vì sao giá trị mặc định là `Progressing` chứ
không phải `Healthy`?

**B2.2** Vì sao `Degraded` của Application con phải được truyền lên? Bỏ nhánh đó thì `root` hiện gì?

**B2.3** Vì sao một Application không có resource nào lại bị coi là `Degraded`? Tình huống thật nào sinh ra nó?

**B2.4** Hai trường hợp nào vẫn khiến `root` chờ mà không báo lý do? Bạn sửa thế nào nếu chúng xảy ra?

**B2.5** `server.insecure: true` nghe nguy hiểm. Vì sao cần nó, và đoạn traffic nào không được mã hoá?

**B2.6** `extraTls` chỉ có host, không có `secretName`. Vì sao vẫn phải khai báo nó?

**B2.7** Các component của Argo CD chỉ có memory limit, không có CPU limit. Vì sao?

**B2.8** Cùng một file values được dùng cho `helm install` lần đầu và cho Argo CD. Nếu hai bên lệch nhau thì bạn thấy gì?

### B3. `platform-secrets`

**B3.1** `ClusterSecretStore` không có block `auth`. Credential đến từ đâu, và node role được làm gì với Secrets Manager?

**B3.2** Vì sao namespace `cattle-system` và `monitoring` do `platform-secrets` tạo? Wave nội bộ -1, 0 và 1 trong Application
này để làm gì?

**B3.3** ExternalSecret khôi phục certificate dùng `refreshPolicy: CreatedOnce` và `creationPolicy: Orphan`. Mỗi cái chặn lỗi
gì?

**B3.4** Vì sao template của bản khôi phục phải gắn bốn annotation `cert-manager.io/*`? Nếu `issuer-name` sai thì sao?

**B3.5** Bản khôi phục chạy khi Secrets Manager chưa có backup thì sao? Trên một account mới, bạn xử lý thế nào?

**B3.6** Mật khẩu Grafana được sinh bằng generator, với `refreshInterval: "0"`. Vì sao là `"0"`? Dựng lại cluster thì mật khẩu
ra sao?

**B3.7** Cấu hình Alertmanager là một template trong ExternalSecret. Vì sao không viết cấu hình trong values của chart?

**B3.8** Vì sao values của Rancher không được đặt `bootstrapPassword`?

### B4. `platform-tls`

**B4.1** ClusterIssuer không có email. Vì sao? `privateKeySecretRef` lưu gì, và dựng lại cluster thì account ACME ra sao?

**B4.2** Solver Route 53 khai báo `region` dù Route 53 là dịch vụ global. Vì sao? Node role được phép sửa gì trong hosted zone?

**B4.3** Wave nội bộ của `platform-tls` là 0, 1 và 2. Mỗi wave chờ điều gì?

**B4.4** PushSecret có `deletionPolicy: None` và `refreshInterval: 10m`. Mỗi cái bảo vệ điều gì? Sau một lần ghi mới, bản cũ
nằm ở đâu?

**B4.5** Vì sao `--enable-certificate-owner-ref` của cert-manager để tắt?

**B4.6** Đổi `issuerRef` sang `letsencrypt-staging` và push khi cluster đang chạy. Kể từng bước điều gì xảy ra trong 10 phút sau
đó.

**B4.7** Trước đây bản khôi phục nằm chung Application với bản backup. Vì sao đó là deadlock?

### B5. `Makefile`

**B5.1** `make bootstrap` quyết định có chạy Helm hay không bằng điều kiện gì? Điều kiện đó sai trong trường hợp nào? Và vì
sao lệnh ở đây viết `application` trong khi evidence cảnh báo tránh `app`?

**B5.2** `ARGOCD_VERSION` được đọc bằng `yq` từ `apps/argocd.yaml`. Vì sao không ghi thẳng version vào Makefile?

**B5.3** Đi qua từng lệnh của `make down`. Vì sao phải tắt automated sync của `root` trước tiên?

**B5.4** Vì sao phải xoá PVC riêng, sau khi đã xoá Application?

**B5.5** Cổng chặn cuối của `make down` hỏi AWS chứ không hỏi cluster. Vì sao? Nó dừng lại trong những trường hợp nào?

### B6. Values của các chart khác

**B6.1** Vì sao `crds.enabled: true` của cert-manager và `installCRDs: true` của External Secrets lại buộc hai chart này đứng ở
một wave riêng?

**B6.2** ingress-nginx chạy dạng DaemonSet với `externalTrafficPolicy: Local`. Đổi sang Deployment một replica thì cái gì hỏng?

**B6.3** StorageClass `gp3` có `reclaimPolicy: Delete` và `WaitForFirstConsumer`. Teardown dựa vào cái nào, và cái còn lại để
làm gì?

**B6.4** `serviceMonitorSelectorNilUsesHelmValues: false` trong kube-prometheus-stack làm gì, và vì sao cần nó ngay từ bây giờ?

**B6.5** Vì sao values của Rancher đặt `agentTLSMode: system-store`?

**B6.6** Dựng lại cluster thì mất dữ liệu gì của monitoring? Vì sao chấp nhận được?

**B6.7** Vì sao Service của ingress-nginx là `NodePort` với cổng cố định, và nginx phục vụ certificate gì trước khi wildcard
tồn tại?

### B7. Evidence

**B7.1** Con số 48 giây được suy ra thế nào? Vì sao nó là một cận dưới?

**B7.2** Điều gì chứng minh lần dựng lại ngày 19/09 không cấp certificate nào? Vì sao fingerprint trùng nhau chưa đủ?

**B7.3** Lệnh đo chỉ chờ `root` chuyển `Healthy`. Vì sao như vậy là đủ?

**B7.4** Evidence của phase này còn thiếu những gì, và bạn sẽ thu thập chúng thế nào?
