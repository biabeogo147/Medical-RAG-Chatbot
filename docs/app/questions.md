# Câu hỏi về phase App: chatbot trên cluster

Bộ câu hỏi về phase App của project: pod của app có danh tính AWS riêng qua issuer OIDC tự dựng, image và index được build
một lần rồi pin, một Helm chart được Argo CD deploy ra dev và prod, và request/limit được đặt từ số đo. Dùng để tự kiểm tra
mức hiểu và luyện phỏng vấn. Đáp án nằm ở [`answers.md`](answers.md), cùng số thứ tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Phỏng vấn** (ưu tiên) | Bạn giải thích và bảo vệ được cách app chạy an toàn trên một cluster tự quản lý, kể được các sự cố, và nói được doanh nghiệp làm khác thế nào |
| **B. Chi tiết code** | Bạn biết vì sao từng dòng quan trọng trong chart, values, health check, Terraform và Ansible được viết như vậy, và đổi đi thì cái gì hỏng |

Bộ liên quan: [tổng quan project](../common/questions.md), [GitOps](../gitops/questions.md),
[Terraform](../terraform/questions.md), [Ansible](../ansible/questions.md), [AWS](../aws/questions.md). Tham chiếu dạng
`Common A5.2` trỏ tới bộ tương ứng. Câu tổng quan về app (probe, retry khi gọi model, image size, CI/CD, Kyverno) nằm ở
`Common A3`, `A5`, `B2`–`B4`; bộ này không lặp lại.

**Cách dùng.** Làm Phần A trước: trả lời thành tiếng, khoảng một phút mỗi câu, rồi so với đáp án. Nhóm A7 là các câu chuyện
sự cố; tập kể chúng tới khi nói trôi mà không cần nhìn. Nhóm A10 luyện riêng cho câu "ở công ty thì bạn làm thế nào". Phần B
làm không mở code; chỉ tính là đã hiểu khi bạn nói được *lý do*. Trong mỗi nhóm, câu hỏi khó dần về cuối.

---

## Phần A — Phỏng vấn

### A1. Tổng quan

**A1.1** Trình bày phase App của project trong hai phút.

**A1.2** Một release đi từ commit tới pod mới qua những bước nào?

**A1.3** Vì sao một chart với hai file values và hai Application, mà không dùng Kustomize overlay hay ApplicationSet?

**A1.4** Vì sao mỗi môi trường có một hostname riêng, thay vì chia path `/dev` và `/` trên cùng một load balancer?

**A1.5** Hiện giờ bạn promote từ dev lên prod thế nào? Khi có Jenkins thì cái gì thay đổi?

**A1.6** Phase này đã chứng minh được gì trên cluster thật, và cái gì vẫn chỉ là giả định?

### A2. Danh tính AWS cho pod

**A2.1** Vì sao pod của app không được dùng IAM role của node? Trước phase này, pod lấy credential của node bằng đường nào?

**A2.2** Kể chuỗi đi từ ServiceAccount token tới credential tạm thời của AWS.

**A2.3** EKS tiêm token vào pod bằng một webhook. Bạn làm mà không có webhook thế nào, và cách đó an toàn hơn ở điểm nào?

**A2.4** Vì sao signing key của ServiceAccount phải giữ nguyên qua mỗi lần dựng lại cluster? Key nằm ở đâu, và ai *không*
được đọc nó?

**A2.5** Issuer bucket để public. Như vậy có an toàn không, và cái gì thật sự phải được bảo vệ?

**A2.6** Trust policy của role kiểm tra những gì? Bỏ điều kiện `sub` thì chuyện gì xảy ra?

**A2.7** Vì sao `sts.amazonaws.com` cố ý *không* nằm trong `api-audiences` của API server?

**A2.8** Hop limit của IMDS trên node vẫn là 2. Vậy cái gì chặn pod app gọi IMDS, bạn chứng minh bằng gì, và NetworkPolicy
đó còn hở ở đâu?

### A3. Image và index là artifact

**A3.1** Vì sao index là một artifact build một lần, mà không build lúc pod khởi động? Con số trước và sau là bao nhiêu?

**A3.2** Vì sao Job build index là Sync hook ở wave 1, mà không phải PreSync hook?

**A3.3** Vì sao lần sync thứ hai, và môi trường prod, không embed lại corpus?

**A3.4** Job được báo trước version nó phải build. Nếu corpus băm ra một version khác thì chuyện gì xảy ra, và vì sao thiết
kế như vậy?

**A3.5** Vì sao image được ghi là `tag@sha256:digest`, và `make image` từ chối chạy trong những trường hợp nào? (phần vì sao
cần digest: `Common A5.4`)

**A3.6** Rollback image hoặc index thế nào? Vì sao revert xong đôi khi vẫn phải bấm sync một lần bằng tay?

### A4. Hình dạng deployment, bảo mật và tài nguyên

**A4.1** Pod Security `restricted` chặn những gì? Vì sao bật cả `warn` bên cạnh `enforce`?

**A4.2** Vì sao chỉ init container có token AWS, còn container app thì không?

**A4.3** Prod có 2 replica với topology spread `DoNotSchedule`. Vì sao không dùng `ScheduleAnyway`, và vì sao PDB chỉ được
render khi có hơn một replica?

**A4.4** Một rolling update có làm rớt request nào không? Những thiết lập nào lo chuyện đó?

**A4.5** Cluster không có metrics-server. Bạn đặt request và limit dựa trên cái gì, và ra con số bao nhiêu?

**A4.6** Đo được 1.1m CPU mà bạn request 50m, và không đặt CPU limit. Bảo vệ lựa chọn đó.

**A4.7** Ingress chỉ route `/` và `/clear` với path `Exact`, cộng rate limit 30 request mỗi phút. Chúng bảo vệ gì, và
giới hạn của chúng là gì?

### A5. Ingress, load balancer và HTTPS

**A5.1** Trong project này, Ingress object, ingress controller và NLB khác nhau thế nào? Đã có ingress-nginx thì sao còn
cần NLB?

**A5.2** Vì sao Terraform tạo NLB và NodePort, mà không để Kubernetes tạo bằng Service `type: LoadBalancer`?

**A5.3** App đang chạy HTTP thường. Vì sao không mở cổng 443 của public NLB vào NodePort 30443 là xong?

**A5.4** Nếu phải có HTTPS cho app vào tuần sau, bạn làm thế nào?

**A5.5** ingress-nginx có thấy IP thật của người dùng không, và điều đó ảnh hưởng tới rate limit ra sao?

### A6. Quan sát và vận hành

**A6.1** Một lần build index hỏng thì bạn biết bằng cách nào?

**A6.2** Vì sao phải thêm luật `report-failed-sync` vào health check của `root`? Không có nó thì `root` hiện gì?

**A6.3** Prometheus scrape app bằng cách nào, và vì sao `/metrics` không mở ra internet?

**A6.4** Pod Ready sau 10 s, câu trả lời mất 1.41–2.91 s. Bạn đo những con số đó thế nào, và chúng *không* nói lên điều gì?

**A6.5** Rotate `FLASK_SECRET_KEY` của prod thế nào? Pod có tự nhận giá trị mới không?

**A6.6** Push lên `main` chính là deploy, mà laptop không có `helm` hay `kubectl`. Bạn kiểm tra một thay đổi trước khi nó
lên `main` thế nào?

### A7. Sự cố và bài học

**A7.1** Bạn cố ý làm hỏng một lần build, nhưng `root` đứng `Progressing` nhiều phút chứ không chuyển `Degraded` ngay. Vì
sao?

**A7.2** Revert xong mà `root` vẫn `Degraded`. Chuyện gì đã xảy ra, và bạn làm gì?

**A7.3** Bạn pin version `000000000000`, nhưng log lại báo `0 was expected`. Chuyện gì đã xảy ra?

**A7.4** Sau khi thêm ServiceMonitor, hai query Prometheus trả về rỗng. Bạn tìm ra nguyên nhân thế nào, và đã sửa quy trình ra sao?

**A7.5** Vì sao bạn cố ý làm hỏng một bản build trên cluster thật, và bài test đó chứng minh được gì?

### A8. Tình huống

**A8.1** Pod mới kẹt ở `Init:CrashLoopBackOff`. Bạn debug theo thứ tự nào?

**A8.2** Hugging Face trả `429` khi Job đang embed một corpus mới. Người dùng thấy gì, và bạn làm gì?

**A8.3** Signing key của ServiceAccount bị lộ, hoặc issuer bucket bị xoá. Hậu quả là gì, và khôi phục thế nào?

**A8.4** Mất một node, trong khi CPU request trên các node đã ở mức 57–68%. Pod prod thứ hai đi đâu?

**A8.5** Kẻ tấn công chiếm được container app. So với trước phase này, giờ họ đi được tới đâu?

### A9. Đánh đổi và quy mô

**A9.1** Nếu làm lại phase này, bạn đổi gì?

**A9.2** Traffic tăng gấp mười. Không có metrics-server, bạn scale dựa trên tín hiệu nào?

**A9.3** Index lớn gấp một trăm lần. Mỗi pod tự tải index trong init container còn ổn không?

**A9.4** Mười team cùng dùng cluster này. Role IAM, namespace và Argo CD phải thay đổi thế nào?

**A9.5** Account ID nằm trong Git, và hai môi trường dùng chung API key của model. Như vậy có chấp nhận được không?

### A10. Doanh nghiệp làm thế nào

**A10.1** IRSA trên EKS, EKS Pod Identity, hay tự dựng như bạn: ở một công ty bạn chọn cái nào?

**A10.2** Công ty thường tách traffic public và công cụ nội bộ thế nào? HTTPS, ingress controller, WAF.

**A10.3** External Secrets, Vault hay Secrets Store CSI Driver? Khi secret đổi thì pod nhận giá trị mới bằng cách nào?

**A10.4** Ở công ty, bạn right-size request và limit thế nào?

**A10.5** Các pod nền tảng vẫn dùng role của node. Bạn chuyển chúng sang role riêng thế nào?

**A10.6** Image có 4 lỗ hổng CRITICAL làm mốc "trước". Ở công ty, quy trình xử lý CVE trông ra sao? (cổng Trivy: `Common
A6.2`)

---

## Phần B — Chi tiết code

### B1. Chart `deploy/charts/medical-rag/`

**B1.1** `_helpers.tpl`: bốn biến môi trường AWS và volume token được chiếu vào pod. Mỗi thứ để làm gì, và token có
audience, thời hạn bao nhiêu?

**B1.2** `index-job.yaml`: `backoffLimit: 0`, `activeDeadlineSeconds: 1200` và `hook-delete-policy: BeforeHookCreation`, mỗi
cái để làm gì?

**B1.3** Pod đặt `automountServiceAccountToken: false`, nhưng init container vẫn mount token AWS còn container `app` thì
không. Hai token này khác nhau thế nào, và vì sao chỉ init container có token?

**B1.4** `deployment.yaml`: vì sao startup probe cho tới 30 × 10 s, liveness probe có timeout 5 s, và grace period là
45 s kèm `preStop: sleep 5`?

**B1.5** Root filesystem là read-only. App và init container ghi gì vào `emptyDir` `/tmp` dùng chung? Vì sao Job có
`sizeLimit` lớn hơn pod app, và vượt giới hạn thì kubelet làm gì?

**B1.6** Vì sao có ba NetworkPolicy cộng dồn, và vì sao policy `default` không bao giờ phải sửa khi thêm một nguồn traffic
mới?

**B1.7** `ingress.yaml`: `pathType: Exact` với `/` và `/clear` khiến `/metrics` và `/readyz` ra sao khi gọi từ ngoài? Vì sao
`proxy-read-timeout` là 120?

**B1.8** `pdb.yaml` chỉ render khi `gt (int .Values.replicas) 1`. Nếu render PDB `minAvailable: 1` cho một replica thì
`kubectl drain` ra sao? Vì sao cần `int`?

**B1.9** Những giá trị nào dùng `required`? `required` bắt được lỗi gì, và không bắt được lỗi gì (ví dụ
`environment: staging`)?

**B1.10** Nếu bỏ `helm.releaseName` khỏi Application, Argo CD đặt release name là gì, và phần nào của manifest được render sẽ
thay đổi?

**B1.11** `podSecurity` và `containerSecurity` trong `_helpers.tpl` đặt những gì để qua mức `restricted`? Vì sao namespace có
cả nhãn `warn` bên cạnh `enforce`?

**B1.12** Prod có 2 replica trên 3 node, `maxUnavailable: 0`, `maxSurge: 1` và topology spread `DoNotSchedule`. Khi rolling
update, hoặc khi node còn lại hết CPU, chuyện gì xảy ra?

**B1.13** `INDEX_REQUIRE_PINNED`, `INDEX_EXPECTED_VERSION` và `INDEX_UPDATE_LATEST=false` mỗi biến chặn lỗi gì? Đã có
`INDEX_UPDATE_LATEST=false` rồi thì vì sao còn cần `Deny` trong IAM?

### B2. Values và Application

**B2.1** Vì sao phải đặt trong dấu nháy những chuỗi trông giống số, như index version hay account ID?

**B2.2** `managedNamespaceMetadata` gắn `enforce-version: latest` và `warn-version: latest`. Điều đó có rủi ro gì khi nâng cấp
Kubernetes, và nên ghim thế nào?

**B2.3** Dev ở wave 1, prod ở wave 2. Thứ tự này có tác dụng lúc nào, và không có tác dụng lúc nào?

**B2.4** Thứ tự của `common.yaml` và `<env>/values.yaml` trong `valueFiles` có quan trọng không? Vì sao đọc chúng qua source
thứ hai `$values`?

### B3. Health check Lua trong `deploy/argocd/values/argocd.yaml`

**B3.1** Vì sao nhánh `report-failed-sync` là opt-in theo label? Nếu đặt nó sau nhánh `Healthy` + `Synced` thì một lần sync
lỗi sau khi revert sẽ hiện ra thế nào trên `root`?

**B3.2** Vì sao xét cả `Error` lẫn `Failed`? Những trạng thái nào của Application con vẫn khiến `root` chờ mãi mà không báo lý
do, và nhánh nào chưa từng được thử trên cluster?

### B4. Terraform, Ansible và Makefile

**B4.1** `infra/terraform/shared/irsa.tf`: trust policy dùng `StringEquals` trên `aud` và `sub`; quyền `ListBucket` có điều
kiện prefix; builder bị `Deny` ghi vào `faiss/LATEST`. Mỗi điều để làm gì?

**B4.2** `irsa.tf` khai báo OIDC provider không có thumbprint; `oidc.tf` đặt `prevent_destroy` cho bucket, và bucket policy chỉ
cho đọc công khai đúng hai key (với `block_public_policy = false`). Mỗi lựa chọn chống lại rủi ro gì?

**B4.3** `kubeadm-config.yaml.j2`: vì sao có hai `service-account-issuer` và theo thứ tự đó, `service-account-jwks-uri` để làm
gì, và vì sao `api-audiences` được đặt tường minh mà không có `sts.amazonaws.com`?

**B4.4** Vì sao `make oidc-publish` từ chối ghi đè tài liệu đã có, và vì sao phải chạy `make oidc-check` sau mỗi lần dựng
lại?

**B4.5** `kubeadm_init/tasks/main.yml` so checksum `sa.key` trên node với `sa-signer` trong Secrets Manager và từ chối chạy
tiếp nếu khác. Vì sao cách sửa là dựng lại cluster chứ không thay file key?

### B5. Evidence

**B5.1** So 10 s Ready với khoảng 150 s trước đây có công bằng không? 320Mi và 640Mi được suy ra thế nào?

**B5.2** Evidence của phase này còn thiếu gì, và bạn sẽ thu thập nó thế nào?
