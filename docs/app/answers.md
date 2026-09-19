# Đáp án phase App

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Phần A mở đầu bằng **Ý chính**: câu nói thành tiếng, ngôi thứ
nhất, thường là đủ. *Nếu được hỏi thêm* dùng khi người phỏng vấn đào sâu; tham chiếu như `(B1.2)` là để bạn tra, không đọc
ra. Dòng **Mẹo** là lời nhắc cho bạn, không nói ra. Đường dẫn tính từ gốc repo. Tham chiếu dạng `Common A5.2` trỏ tới
[`../common/answers.md`](../common/answers.md), tương tự với `GitOps`, `Terraform`, `Ansible`, `AWS`.

Chỗ `[điền: …]` là số liệu phải lấy từ lần chạy thật; đừng nói điều chưa đo. Ghi chú **[kiểm chứng]** là hành vi của công cụ
cần xác nhận (trên cluster hoặc trong tài liệu chính thức) trước khi nói chắc. Số thập phân viết bằng dấu chấm, như các bộ
khác.

**Số liệu đã có** ([`docs/evidence/app.md`](../evidence/app.md), 19/09/2026):

- **Index `cc759ae1a093`:** Job của dev build trong **149.1 s** (759 trang, 7079 chunk). Hai lần chạy sau đó, một ở dev và
  một ở prod, đều log `already exists, skipping build`.
- **Readiness:** một pod dev từ lúc tạo tới Ready mất **10 s**, tính cả lúc tải index. Trước phase này mỗi pod tự build index
  khi khởi động; việc build đó mất 149.1 s trên cluster và 150.7 s ở local.
- **Câu trả lời:** mười câu hỏi liên tiếp vào dev, mỗi câu **1.41–2.91 s**, trung vị 1.74 s, đo từ một client.
- **Tài nguyên (Prometheus, không có metrics-server):** app 276.9 MiB sau mười câu hỏi, CPU trung bình 5 phút 1.1m. Đặt
  **320Mi request / 640Mi limit / 50m CPU**. Job đỉnh 320.8 MiB, đặt **384Mi / 1Gi**. Ba pod app giờ giữ 960Mi thay vì
  2304Mi, 150m CPU thay vì 300m.
- **CVE của image:** 4 CRITICAL (1 `openssl`, 3 `perl`), 14 HIGH, 8 MEDIUM. Đây là mốc "trước".
- **Quyền tối thiểu (dev):** từ container app, IMDS timeout và lời gọi AWS báo `NoCredentialsError`.
- **Prod:** hai pod trên hai node khác nhau; PDB `disruptionsAllowed` 1; `/` trả `200`, `/metrics` trả `404`.
- **Test làm hỏng build:** `Failed Healthy`, `root` `Degraded` với message `… (retried 5 times)`; pod cũ vẫn `1/1 Running`,
  0 restart.
- **Ba sự cố:** Argo CD tự retry 5 lần; `000000000000` thành số `0`; commit của bước ServiceMonitor bị push nhầm sang nhánh
  `app/step-18`.

**Cần điền hoặc xác nhận:**

- Dòng `rag_index_info` trên `/metrics`: lần kiểm đó `grep` không in gì và chưa kiểm lại (A6.3).
- Query `[15m]` chạy lại sau mười câu hỏi (B5.2).
- Thời gian từ lúc push tới `Failed` trong test hỏng build: chỉ biết lần retry thứ năm được lên lịch 7 phút sau lúc tạo commit
  (A7.1).
- ARN role và kiểm tra IMDS trong *prod*: evidence chỉ có của dev (A2.8).
- CPU burst ngắn: trung bình 5 phút che mất chúng (A4.6).
- Số request rớt khi rolling update: chưa đo (A4.4).
- Số CVE "sau": phase Jenkins (A10.6).

**Nếu bạn sửa code trước khi nộp CV, sửa cả đáp án:** các đáp án dưới đây mô tả đúng code hiện tại, kể cả điểm yếu đã biết.

| Điểm yếu trong code | Câu liên quan |
|---|---|
| App chỉ chạy HTTP | A5.3, A5.4 |
| Egress 443 của app mở ra mọi địa chỉ, trừ IMDS | A2.8, A8.5 |
| Pod nền tảng, kể cả ingress-nginx, vẫn dùng role của node | A2.1, A10.5 |
| Signing key đi qua transfer bucket mà node role đọc được | A2.4, A8.3 |
| Account ID nằm trong Git; hai môi trường dùng chung API key của model | A9.5 |
| Image có 4 CRITICAL; image build trên workstation | A10.6, A1.2, A3.5 |
| Không có HPA, không có metrics-server | A9.2 |
| Không có alert cho sync lỗi, chỉ nhìn `root` | A6.1 |
| Index là file pickle | A8.5 |
| Rate limit theo IP | A4.7 |

---

## Phần A — Phỏng vấn

### A1. Tổng quan

**A1.1** **Ý chính:** "Phase này đưa chatbot RAG lên cluster tôi tự dựng trên EC2, bằng GitOps. Có bốn việc. Một: pod của app
có IAM role riêng, qua một issuer OIDC tôi tự host trên S3, nên pod xử lý dữ liệu người dùng gửi vào không còn mang quyền của
node. Hai: image và index là artifact, build một lần rồi pin bằng digest và version. Ba: một Helm chart được Argo CD deploy ra
dev và prod, mỗi môi trường một hostname. Bốn: request và limit đặt từ số đo Prometheus. Kết quả: pod Ready sau 10 giây thay
vì phải build index gần 150 giây, và một bản build hỏng không bao giờ thay các pod đang chạy."

*Nếu được hỏi thêm:*

- Lý do cần danh tính riêng: A2.1. Luồng một release: A1.2.
- Ba câu chuyện sự cố: A7.

**Mẹo:** kết bằng một con số và một sự cố. Người phỏng vấn thường hỏi tiếp vào đúng chỗ đó.

**A1.2** **Ý chính:** "Tôi sửa `image.tag` hoặc `index.version` trong `deploy/envs/dev/values.yaml` rồi push lên `main`. Argo
CD refresh, render chart với `common.yaml` và values của dev, rồi sync theo ba wave. Wave 0 là ServiceAccount, ExternalSecret
và NetworkPolicy. Wave 1 là Job build index: nếu version đó đã có trên S3 thì nó dừng sau vài giây. Wave 2 là Deployment và
phần còn lại: pod mới dùng init container tải đúng version đã pin, Ready rồi mới thay pod cũ. Lên prod là cùng thay đổi đó
trong `envs/prod/values.yaml`."

*Nếu được hỏi thêm:*

- Sơ đồ: `docs/app/README.md` §5, và `docs/gitops/argocd-explained.md`.
- Chưa có Jenkins, nên hiện tôi build image trên workstation bằng `make image` (A3.5).

**A1.3** **Ý chính:** "Hai môi trường khác nhau ở vài giá trị: số replica, host, tên secret. Tôi chọn Helm vì hai thứ: một
template duy nhất cho cả hai môi trường, và `required`, làm render thất bại ngay khi thiếu một giá trị bắt buộc như account ID
hay host. Kustomize làm được phần khác nhau bằng overlay, kể cả chỉ đưa PDB vào overlay của prod, nhưng không có cách báo lỗi
thiếu giá trị như vậy. Còn ApplicationSet đáng dùng khi số môi trường nhiều hoặc thay đổi thường xuyên. Với hai môi trường cố
định, hai file Application viết tay dễ đọc và dễ review hơn."

*Nếu được hỏi thêm:*

- Argo CD không cài Helm release: nó chạy `helm template` rồi apply (`GitOps A1.3`). Vì vậy `helm list` không thấy gì.
- Khi có mười team, tôi sẽ cân nhắc ApplicationSet với generator theo thư mục (A9.4).

**A1.4** **Ý chính:** "Lúc thiết kế, project chưa có domain nên kế hoạch là `/dev` và `/` trên tên DNS của NLB. Khi đã có
`recruitai.io.vn`, tôi đổi sang `dev.` và `app.` vì ba lý do. App không phải xử lý tiền tố URL. Cookie `session` của hai môi
trường không dùng chung, vì cookie gắn theo host. Và probe, `/metrics` giống hệt nhau ở hai môi trường."

*Nếu được hỏi thêm:*

- Ingress chọn backend theo header `Host`, nên một NLB phục vụ được cả hai host (A5.1).

**A1.5** **Ý chính:** "Hiện promote là tay: dev chạy ổn thì tôi chép đúng `image.tag` và `index.version` sang
`envs/prod/values.yaml`, commit, push. Job của prod thấy index đã có và bỏ qua build. Khi có Jenkins, pipeline sẽ build, scan,
ký image, tự commit giá trị mới vào values của dev, rồi mở pull request cho prod. Con người vẫn là người duyệt bước lên prod."

*Nếu được hỏi thêm:*

- Vì sao Jenkins ghi vào Git mà không `kubectl apply`: `Common A5.2`.
- Prod không đợi dev: khi file đã lên `main`, `medical-rag-prod` tự sync. Wave 2 của prod chỉ có tác dụng khi chính `root`
  sync, như lúc dựng cluster mới (B2.3).

**A1.6** **Ý chính:** "Đã chứng minh trên cluster thật: pod của app nhận role riêng qua token, còn container app không gọi được
IMDS và không có credential nào; index build một lần rồi các lần sau bỏ qua; pod Ready trong 10 giây; một bản build hỏng làm
`root` chuyển `Degraded` mà pod đang chạy không bị thay; prod có hai pod trên hai node. Còn là giả định: rolling update không
rớt request, vì tôi chưa đo; hành vi dưới tải thật, vì tôi chỉ hỏi mười câu liên tiếp; và kiểm tra IMDS ở prod, vì evidence
mới có của dev."

**Mẹo:** tự nói ra phần "chưa chứng minh" trước khi bị hỏi. Người phỏng vấn đánh giá cao việc bạn biết giới hạn của mình.

### A2. Danh tính AWS cho pod

**A2.1** **Ý chính:** "Cluster chạy trên EC2 không có tích hợp AWS, nên mọi process trên node, kể cả pod, đều hỏi được IMDS ở
`169.254.169.254` để lấy credential của node role. Node role có nhiều quyền: đọc tám secret, trong đó có private key của hai
certificate; tạo bản ghi TXT `_acme-challenge`; đọc ghi nhiều bucket; ký bằng KMS. Chatbot là pod ứng dụng duy nhất xử lý dữ
liệu người dùng gửi vào, lại load một file pickle. Nếu nó bị chiếm, tất cả những quyền đó lọt ra ngoài."

*Nếu được hỏi thêm:*

- NetworkPolicy chặn được IMDS, nhưng cho cả pod. Trước đây pod cần IMDS để tải index, nên không chặn được. Có role riêng
  qua token thì mới chặn IMDS được (A2.8).
- Hop limit 2 trên node là thứ cho phép pod với tới IMDS. Nó vẫn phải để 2 vì pod nền tảng còn cần (A10.5).
- Vì sao node role cần đọc private key của certificate: cert-manager và External Secrets dùng nó để sao lưu và khôi phục
  certificate (`GitOps A5`).

**A2.2** **Ý chính:** "API server ký cho pod một token có audience `sts.amazonaws.com` và issuer là địa chỉ bucket S3 của tôi.
AWS SDK trong pod gửi token đó cho STS bằng `AssumeRoleWithWebIdentity`. STS tải discovery document và key set công khai từ
bucket, kiểm chữ ký, kiểm issuer đã được đăng ký làm OIDC provider, kiểm `aud` và `sub` trong trust policy của role. Khớp thì
trả credential tạm thời, mặc định sống một giờ. SDK tự làm lại trước khi hết hạn."

*Nếu được hỏi thêm:*

- Lời gọi này không cần credential AWS nào: chính token là bằng chứng.
- Sơ đồ tuần tự: `docs/app/README.md` §2.

**A2.3** **Ý chính:** "Trên EKS, một mutating webhook sửa mọi pod dùng ServiceAccount có annotation
`eks.amazonaws.com/role-arn`: thêm volume token và các biến `AWS_*`. Tôi viết đúng mấy dòng đó vào chart, trong
`_helpers.tpl`. Chỉ chart của tôi cần, nên không cần webhook. Điểm an toàn hơn: theo tôi đọc, webhook của upstream để
`failurePolicy: Ignore`, nên khi webhook chết, pod vẫn khởi động mà không có token, và lặng lẽ rơi về role của node. Với cách
của tôi, token nằm ngay trong manifest, không có chuyện đó."

*Nếu được hỏi thêm:*

- `failurePolicy: Ignore` của upstream: **[kiểm chứng]** theo repo `amazon-eks-pod-identity-webhook` trước khi nói chắc.
- Giá phải trả: thêm một workload cần AWS thì phải tự thêm các biến và volume vào chart của nó (A10.5).

**A2.4** **Ý chính:** "AWS tin các token được ký bằng một key cụ thể, qua key set tôi công bố trên S3. Nếu kubeadm sinh key mới
mỗi lần dựng lại, AWS sẽ từ chối mọi token mới. Nên key nằm trong Secrets Manager (`medical-rag/sa-signer`). Ansible đọc nó
trên workstation và đặt vào node 1 trước `kubeadm init`, và kubeadm dùng lại key có sẵn thay vì sinh mới. Node role *không*
đọc được secret này, vì ai có key là ký được token cho bất kỳ ServiceAccount nào."

*Nếu được hỏi thêm:*

- Ansible từ chối chạy tiếp nếu `sa.key` trên node khác với secret: cách sửa là dựng lại, không phải thay key dưới API server
  đang chạy (B4.5).
- Điểm yếu đã biết: bản copy đi qua SSM transfer bucket mà node role đọc được. Nó diễn ra lúc `make cluster`, trước khi có pod
  nào, và object hết hạn sau một ngày (A8.3).

**A2.5** **Ý chính:** "Có. OIDC được thiết kế để công khai: AWS tải hai tài liệu đó mà không cần credential. Trong bucket chỉ
có discovery document và *public* key. Thứ phải bảo vệ là ba thứ khác: private key, vì ai có nó thì mint được token; quyền ghi
vào bucket, vì ai đổi được key set là khiến AWS tin key của họ; và chính bucket: nó có `prevent_destroy`, vì bucket bị xoá thì
người khác tạo được bucket cùng tên và công bố key của họ."

*Nếu được hỏi thêm:*

- Bucket policy chỉ cho đọc đúng hai key; ACL vẫn bị chặn; có versioning để khôi phục key set lỡ bị ghi đè (B4.2).

**A2.6** **Ý chính:** "Ba thứ: token đến từ đúng OIDC provider của tôi; `aud` bằng `sts.amazonaws.com`, tức token được mint
cho AWS chứ không phải token thường dùng với API server; và `sub` bằng đúng `system:serviceaccount:<namespace>:<name>`. Bỏ `sub`
thì *mọi* ServiceAccount trong cluster xin được token cho AWS đều assume được role đó, kể cả một pod trong namespace khác."

*Nếu được hỏi thêm:*

- Dùng `StringEquals`, không dùng `StringLike` với wildcard (B4.1).
- Role builder chấp nhận đúng hai `sub`, ServiceAccount `medical-rag-index-builder` trong dev và trong prod.

**A2.7** **Ý chính:** "`api-audiences` là danh sách audience mà API server chấp nhận. Nếu có `sts.amazonaws.com` trong đó, một
token mint cho AWS cũng dùng được để gọi chính API server. Để nó ngoài danh sách thì token cho AWS vô dụng với cluster, và
ngược lại token thường không dùng được với AWS vì sai `aud`. Mỗi token chỉ mở đúng một cửa."

*Nếu được hỏi thêm:*

- Tôi đặt `api-audiences` tường minh. Nếu để trống, nó mặc định là issuer đầu tiên, và client nào hỏi audience cũ sẽ bị từ
  chối (B4.3).

**A2.8** **Ý chính:** "Chặn bằng NetworkPolicy `default` của namespace: egress chỉ cho DNS và TCP 443, và 443 thì trừ
`169.254.169.254/32`. Tôi chứng minh từ chính container app trên cluster: kết nối tới IMDS timeout, và gọi AWS báo
`NoCredentialsError`. Chỗ hở: egress 443 vẫn mở ra mọi địa chỉ khác, nên pod bị chiếm vẫn gửi dữ liệu ra ngoài được. Muốn chặt
hơn thì cần egress theo tên miền, việc mà NetworkPolicy chuẩn không làm được."

*Nếu được hỏi thêm:*

- Egress theo tên miền cần CNI hỗ trợ (Cilium, hoặc Calico bản enterprise) hoặc một egress proxy **[kiểm chứng]** tính năng
  của bản Calico đang dùng.
- Bằng chứng ở prod: `[điền: IMDS và NoCredentialsError từ container app của prod]`.

### A3. Image và index là artifact

**A3.1** **Ý chính:** "Trước đây mỗi pod tự embed toàn bộ corpus khi khởi động: gần 150 giây, và tốn quota Hugging Face cho
mỗi pod, mỗi lần restart. Giờ index được build một lần thành một version trên S3, và pod chỉ tải về. Build lần đầu mất 149.1
giây trên cluster. Pod từ lúc tạo tới Ready mất 10 giây."

*Nếu được hỏi thêm:*

- So 10 s với 150 s là so hai việc khác nhau: 150 s là thời gian build, không phải thời gian Ready của pod cũ (B5.1).
- Version là 12 ký tự đầu của sha256 trên tên file, nội dung file, chunk size, overlap và model embedding. Cùng đầu vào thì
  cùng version.

**A3.2** **Ý chính:** "PreSync hook chạy trước mọi resource thường, nên ở lần sync đầu tiên, ServiceAccount của nó và
ExternalSecret giữ API key đều chưa tồn tại. Tôi đặt Job là Sync hook ở wave 1: wave 0 đã apply xong và healthy, Argo CD chờ
ExternalSecret sẵn sàng, rồi mới chạy Job. Deployment ở wave 2, nên pod chỉ khởi động khi version đã có trên S3."

*Nếu được hỏi thêm:*

- Trên cluster: Secret được tạo lúc 13:59:58, pod của Job lúc 14:00:00.
- Job xong và Deployment được tạo cùng giây 14:14:35. Timestamp chỉ chính xác tới giây nên không tự chứng minh thứ tự; thứ
  tự đến từ việc Argo CD chờ hook xong mới sang wave sau.

**A3.3** **Ý chính:** "Job chạy ở mọi lần sync. Nó tải corpus, băm ra version, rồi xem version đó đã có trên S3 chưa. Có rồi
thì log `already exists, skipping build` và dừng, không gọi Hugging Face. Prod dùng cùng version với dev, nên khi dev đã build
trước, Job của prod chỉ việc thấy nó."

*Nếu được hỏi thêm:*

- Role builder được ghi `faiss/*` nhưng không được xoá. Một lần ghi đè vẫn còn bản cũ nhờ versioning của bucket (B4.1).

**A3.4** **Ý chính:** "Job dừng ngay, trước lời gọi embedding nào, với lỗi `The corpus builds version X, but Y was expected`.
Values là nơi quyết định version nào được deploy, nên Job không được tự ý build ra version khác rồi để pod tải một thứ không ai
duyệt. Nó thất bại to và sớm, và vì Deployment ở wave 2 nên pod đang chạy không bị đụng tới."

*Nếu được hỏi thêm:*

- Đúng hành vi này đã được test có chủ đích trên cluster (A7.5).

**A3.5** **Ý chính:** "Tag là 12 ký tự của commit, để người đọc biết image build từ code nào. Digest là hash nội dung, để
máy chắc chắn đúng image đó. `make image` từ chối khi working tree còn thay đổi chưa commit, khi `HEAD` khác `origin/main`, và
khi tag đã có trong ECR, vì tag trong ECR là immutable. Nó chạy test trước, build, push, rồi in digest."

*Nếu được hỏi thêm:*

- Vì sao cần digest: `Common A5.4`. Khi có cả tag và digest, runtime kéo theo digest.
- `--provenance=false --sbom=false` để có một manifest đơn, digest in ra chính là digest chart pin.

**A3.6** **Ý chính:** "Rollback là `git revert` commit đã đổi values, rồi push. Image cũ vẫn trong ECR, version index cũ vẫn trên
S3, nên không phải build lại gì. Chỗ cần biết: nếu lần sync trước *thất bại*, ví dụ Job lỗi, thì sau khi revert, Git lại khớp
với cluster, app hiện `Synced`, và automated sync không có gì để làm. Nhưng trạng thái sync cuối vẫn là `Failed` và `root` vẫn
`Degraded`, nên tôi phải chạy một lần sync bằng tay."

*Nếu được hỏi thêm:*

- Chi tiết: A7.2, và sơ đồ ở `docs/gitops/argocd-explained.md` §4.

### A4. Hình dạng deployment, bảo mật và tài nguyên

**A4.1** **Ý chính:** "`restricted` đòi pod chạy non-root, không leo thang quyền, bỏ mọi capability, và dùng seccomp
`RuntimeDefault`. Chart của tôi đặt đủ các thứ đó, cộng root filesystem read-only. Chỗ dễ bị bất ngờ: `enforce` chỉ kiểm *Pod*.
Một Deployment vi phạm vẫn được tạo, rồi ReplicaSet không tạo được pod, và lỗi chỉ nằm trong event. `warn` kiểm cả Deployment
và Job, nên dry run trước khi lên `main` in ra cảnh báo ngay."

*Nếu được hỏi thêm:*

- Nhãn namespace do Argo CD gắn qua `managedNamespaceMetadata` (B2.2).

**A4.2** **Ý chính:** "Container app không bao giờ gọi AWS: nó chỉ đọc index mà init container đã tải vào `/tmp/index`. Nên chỉ
init container mount token. Container app, thứ trả lời người dùng, không có credential AWS nào. Bị chiếm thì nó cũng không đọc
được S3."

*Nếu được hỏi thêm:*

- Pod đặt `automountServiceAccountToken: false`, nên container app cũng không có token Kubernetes (B1.3).

**A4.3** **Ý chính:** "`DoNotSchedule` với `maxSkew: 1` bảo đảm hai replica không bao giờ nằm chung một node, nên mất một node
không mất cả prod. `ScheduleAnyway` cho phép đặt tạm chung node, và bản tạm thường thành vĩnh viễn. PDB `minAvailable: 1` giữ
một pod khi `kubectl drain`. Nhưng với một replica, PDB đó sẽ chặn *mọi* lần drain, nên chart chỉ render PDB khi có hơn một
replica."

*Nếu được hỏi thêm:*

- Đổi lại: nếu không còn node nào đủ chỗ mà chưa có pod prod, replica đó `Pending` thay vì chen chung (A8.4).
- Bằng chứng: hai pod prod trên hai node, `disruptionsAllowed` là 1.

**A4.4** **Ý chính:** "Tôi chưa đo, nên chưa dám nói là không. Thiết kế có bốn lớp cho việc đó. `maxUnavailable: 0` và
`maxSurge: 1`: pod mới Ready rồi mới dừng pod cũ. Readiness probe: chỉ pod đã build xong chain mới nhận traffic. `preStop: sleep
5`: cho ingress-nginx vài giây ngừng gửi tới pod sắp dừng. `terminationGracePeriodSeconds: 45`: đủ cho gunicorn hoàn tất trong
`graceful_timeout` 30 giây."

*Nếu được hỏi thêm:*

- Cách đo: chạy vòng `curl` liên tục vào `app.` trong khi đổi image, đếm mã khác 2xx/3xx. `[điền: số request rớt]`.

**A4.5** **Ý chính:** "Không có metrics-server thì `kubectl top` không chạy, nhưng Prometheus đã scrape cAdvisor qua kubelet.
Tôi query `container_memory_working_set_bytes` và `rate(container_cpu_usage_seconds_total[5m])` cho container app, lúc rảnh và
sau mười câu hỏi. App dùng 276.9 MiB, nên request 320Mi, làm tròn lên bội 64, và limit gấp đôi là 640Mi. Job đỉnh 320.8 MiB,
nên 384Mi và limit tối thiểu 1Gi, vì bị OOM giữa chừng là mất toàn bộ lượt gọi embedding."

*Nếu được hỏi thêm:*

- Đỉnh bộ nhớ của Job phải đo ngay sau khi build, vì Prometheus chỉ giữ 24 giờ. Prometheus lấy mẫu theo chu kỳ nên có thể bỏ
  lỡ một đỉnh ngắn; đỉnh thật có thể cao hơn.
- Vì sao limit gấp đôi: mười câu hỏi tuần tự không phải tải thật, khoảng dư là phần che cho tải đó. Vì sao Job 1Gi chứ không
  sát hơn: một lần OOM giữa lúc build tốn cả quota lẫn thời gian, rẻ hơn nhiều so với vài trăm MiB RAM.

**A4.6** **Ý chính:** "1.1m là trung bình 5 phút. App gần như chỉ chờ Hugging Face và Gemini, nên CPU rất thấp, nhưng các đợt
tăng ngắn bị trung bình che mất. 50m là mức sàn: đủ để scheduler tính đúng, và không đè thêm lên các node vốn đã bị request
57–68% CPU. Tôi không đặt CPU limit vì vượt limit CPU thì bị throttle, làm chậm đúng lúc app bận nhất, trong khi node còn CPU
rảnh. Không có limit, pod vượt request thì chỉ lấy phần CPU đang rảnh."

*Nếu được hỏi thêm:*

- Bộ nhớ thì khác: có limit, vì vượt bộ nhớ không throttle được mà làm cả node thiếu (A4.5).
- CPU burst thật: `[điền: đo bằng rate trên cửa sổ ngắn hơn, ví dụ [1m], trong lúc có tải]`.

**A4.7** **Ý chính:** "Path `Exact` nghĩa là chỉ trang chat và `/clear` đi ra internet. `/metrics`, `/healthz`, `/readyz` là
cho Kubernetes và Prometheus, từ ngoài vào sẽ nhận `404`. Rate limit theo IP bảo vệ quota Gemini và Hugging Face, vì mỗi câu
hỏi tốn tiền. Giới hạn của nó: tính theo IP, nên người dùng sau cùng một NAT chia chung hạn mức, còn kẻ có nhiều IP thì vượt
được. Và có thể mỗi bản ingress-nginx đếm riêng, nên với ba node, giới hạn thật có thể cao hơn."

*Nếu được hỏi thêm:*

- Con số chính xác: `limit-rpm: 30` cộng hệ số burst mặc định của ingress-nginx, và việc mỗi replica đếm riêng, là
  **[kiểm chứng]** theo tài liệu annotation.
- Muốn chặt hơn: đăng nhập và hạn mức theo người dùng, hoặc WAF ở biên (A10.2).

### A5. Ingress, load balancer và HTTPS

**A5.1** **Ý chính:** "Ingress object chỉ là luật định tuyến bằng YAML: host này, path này, đi tới Service nào. Ingress
controller, ở đây là ingress-nginx, là proxy tầng 7 chạy như pod trên cả ba node, đọc các luật đó và chia request ra pod theo
`Host` và path. NLB của AWS là load balancer tầng 4, nằm ngoài cluster. Vẫn cần NLB vì ba lý do: các node ở private subnet,
không có IP public; cần một địa chỉ cố định không phụ thuộc node nào còn sống; và phải có thứ gì đó chia kết nối cho chính ba
bản nginx, có health check từng node."

*Nếu được hỏi thêm:*

- Luồng: internet → NLB, chọn node → NodePort 30080 → nginx, chọn pod → pod.
- On-prem thì vai của NLB do MetalLB, keepalived + HAProxy hoặc F5 đảm nhận.

**A5.2** **Ý chính:** "Service `type: LoadBalancer` cần một cloud controller để gọi API AWS tạo NLB. Cluster kubeadm của tôi
không cài AWS cloud controller, nên Service đó sẽ `Pending` mãi. Nên Terraform tạo sẵn hai NLB, trỏ vào các cổng cố định
30080 và 30443 trên mọi node, còn ingress-nginx mở đúng các cổng đó bằng `NodePort`."

*Nếu được hỏi thêm:*

- Ưu điểm phụ: load balancer nằm trong Terraform cùng security group, DNS và target group, không bị Kubernetes tạo ra ngoài
  state.

**A5.3** **Ý chính:** "Vì 30443 là cổng HTTPS của *cùng một* ingress-nginx đang phục vụ các UI nội bộ như Argo CD và Grafana.
nginx chọn backend theo header `Host`, không theo việc request đến từ NLB nào. Mở public 443 vào đó thì ai trên internet cũng
gửi được `Host: argocd.recruitai.io.vn`. Khi đó chỉ còn allowlist IP đứng chặn, mà allowlist lại phụ thuộc một dòng cấu hình
`externalTrafficPolicy: Local`. Và Prometheus, Alertmanager không có đăng nhập."

*Nếu được hỏi thêm:*

- Nó cũng phá tiêu chí của design: không có rule 443 public nào.
- Lý do lịch sử HTTPS bị để ngoài phạm vi: lúc đầu app chạy trên tên `amazonaws.com` của NLB, không xin được certificate.

**A5.4** **Ý chính:** "Tôi cho NLB tự giải mã TLS. Tạo certificate ACM cho `dev.` và `app.recruitai.io.vn` trong stack `shared`,
xác thực qua Route 53. Thêm listener TLS 443 trên public NLB dùng certificate đó, và chuyển tiếp tới NodePort 30080 bằng HTTP
như hiện nay. Public NLB vẫn không bao giờ chạm 30443, nên đường nội bộ giữ nguyên. Certificate ACM miễn phí, tự gia hạn,
private key không vào cluster hay Terraform state."

*Nếu được hỏi thêm:*

- Chỗ cần xử lý thêm: nginx nhận HTTP nên không biết client đã dùng HTTPS; muốn tự redirect thì cần thêm cấu hình. Lần đầu
  có thể giữ cả 80 và 443.
- Cách "doanh nghiệp" hơn: hai ingress controller, public và internal (A10.2).
- NLB listener TLS với target kiểu instance vẫn giữ IP client **[kiểm chứng]** theo tài liệu NLB.

**A5.5** **Ý chính:** "Có, với traffic của app. Target group HTTP của public NLB giữ nguyên IP nguồn, và
`externalTrafficPolicy: Local` đưa kết nối tới nginx trên chính node nó đến, không để kube-proxy thay IP nguồn bằng IP của
node. Nên rate limit tính theo từng người dùng. Cũng vì vậy, một request từ internet mang `Host` của UI nội bộ vẫn mang IP
internet, và allowlist `10.10.0.0/16` từ chối nó."

*Nếu được hỏi thêm:*

- Đường nội bộ thì khác: target group 443 đặt `preserve_client_ip = false` để tránh lỗi NAT loopback khi Rancher agent gọi
  ngược qua NLB, nên nginx thấy IP của NLB nội bộ.
- Cái giá của `Local`: node nào không có nginx sẽ fail health check. Vì vậy ingress-nginx chạy dạng DaemonSet, mỗi node một
  bản (`Common B1.2`).

### A6. Quan sát và vận hành

**A6.1** **Ý chính:** "`root` chuyển `Degraded`, kèm message của lần sync lỗi, và tôi thấy trên trang đầu của Argo CD. Nhưng
chỉ sau khi Argo CD retry xong năm lần, tức vài phút sau. Log của Job cho biết lý do. Và đó là tôi phải *nhìn*: hiện chưa có
alert đẩy tới tôi. Bước tiếp theo là một alert Prometheus trên metric sync của Argo CD, hoặc Argo CD Notifications."

*Nếu được hỏi thêm:*

- Metric như `argocd_app_info` có nhãn health và sync **[kiểm chứng]** tên metric và nhãn trên bản 3.5.
- Trong lúc Argo CD đang retry, `root` hiện `Progressing`, chưa phải `Degraded` (A7.1).

**A6.2** **Ý chính:** "Job build index là hook, và Argo CD không tính hook vào health của Application. Job lỗi thì sync `Failed`,
nhưng Application vẫn `Healthy`. `root` đọc health của các Application con, nên không có luật này thì `root` hiện `Progressing`,
chờ mãi mà không nói vì sao. Luật mới: con nào có label `medical-rag/report-failed-sync` mà lần sync cuối `Failed` hoặc
`Error` thì báo `Degraded`, kèm message."

*Nếu được hỏi thêm:*

- Chỉ Application của app mang label, nên nền tảng vẫn được đánh giá như trước (B3.1).
- Toàn bộ bảng "`root` hiện gì": `docs/gitops/argocd-explained.md` §4.

**A6.3** **Ý chính:** "Chart có một ServiceMonitor, và Prometheus Operator biến nó thành target scrape `/metrics` của Service
mỗi 30 giây. NetworkPolicy chỉ cho pod Prometheus trong namespace `monitoring` vào cổng 8000. `/metrics` không ra internet vì
Ingress chỉ route `/` và `/clear`. App chạy hai worker gunicorn nên metric dùng chế độ multiprocess, cộng dồn qua các worker."

*Nếu được hỏi thêm:*

- Bằng chứng: `up{namespace="medical-rag-dev"}` bằng 1, `http_requests_total` cho `/` bằng 11.
- `rag_index_info{version="cc759ae1a093"}` trên `/metrics`: `[điền: lần kiểm trước không in gì, chưa kiểm lại]`.

**A6.4** **Ý chính:** "10 giây lấy từ timestamp của cluster: lúc pod được tạo và lúc điều kiện Ready chuyển true. 1.41–2.91
giây là `time_total` của `curl`, mười câu hỏi liên tiếp từ workstation. Chúng không nói về tải: một client, câu hỏi tuần tự,
không có đồng thời. Thời gian đó còn tính cả redirect `302` sau khi trả lời. Và chúng không nói gì về p95 hay p99 dưới tải
thật."

*Nếu được hỏi thêm:*

- Đo đúng hơn: `histogram_quantile` trên `http_request_duration_seconds` trong Prometheus, cộng một công cụ tạo tải như k6.

**A6.5** **Ý chính:** "Tôi ghi giá trị mới vào `medical-rag/app-prod` bằng `put-secret-value`, giữ nguyên hai key còn lại.
ExternalSecret refresh mỗi giờ nên Secret trong cluster đổi trong vòng một giờ. Nhưng pod đọc secret qua biến môi trường, và
biến môi trường chỉ đọc lúc khởi động, nên pod không tự nhận giá trị mới. Phải khởi động lại pod. Đổi key Flask cũng làm mọi
người dùng mất lịch sử chat, vì session là cookie ký bằng key đó."

*Nếu được hỏi thêm:*

- Tôi thay key Flask của prod *trước* khi dựng prod, để không session prod nào từng được ký bằng key của dev.
- `kubectl rollout restart` thêm một annotation vào pod template. Argo CD có coi đó là drift không là **[kiểm chứng]**. Cách
  GitOps hơn: một checksum annotation, hoặc Reloader (A10.3).

**A6.6** **Ý chính:** "Laptop chỉ để sửa code và push. Việc kiểm tra chạy trên ops workstation, một EC2 có sẵn `helm` và
`kubectl`. Tôi push commit lên một nhánh tạm `app/step-N`; trên workstation, tôi checkout nhánh đó, chạy `helm lint` và `helm
template … | kubectl apply --dry-run=server`. Dry run phía server đi qua cả admission: webhook của ingress-nginx và cảnh báo
Pod Security. Qua hết mới đẩy chính commit đó lên `main`, rồi xoá nhánh tạm. Argo CD chỉ đọc `main`, nên nhánh tạm không bao
giờ được apply."

*Nếu được hỏi thêm:*

- Dry run bỏ Job ra, vì Job đã chạy thì immutable, dry run sẽ báo lỗi giả.
- Đây là thay thế tạm cho CI. Khi có Jenkins, bước này thành một stage của pull request.

### A7. Sự cố và bài học

**A7.1** **Ý chính:** "Tôi pin một version không tồn tại để xem hệ thống phản ứng, và chờ `root` chuyển `Degraded` ngay, vì
guide của tôi nói automated sync không retry. Nhưng nó đứng `Progressing` nhiều phút. Tôi đo trước khi đoán: spec không khai
báo retry, nhưng operation đang chạy lại có retry limit 5, do automated sync tự gắn. Đọc source Argo CD thì đúng vậy: không khai
báo thì mặc định năm lần. Bài học: tôi sửa guide, và test giờ chờ tới trạng thái `Failed` chứ không kiểm ngay."

*Nếu được hỏi thêm:*

- Trong lúc retry, phase là `Running`, và `root` hiện `Progressing` vì app còn `OutOfSync`. Chỉ sau lần retry thứ năm mới
  `Failed` rồi `Degraded`.
- Tôi giữ mặc định: retry giúp qua lỗi ngắn như webhook chưa sẵn sàng. Đổi lại, lỗi hiện lên chậm vài phút.
- Tổng thời gian: `[điền: từ lúc push tới Failed]`. Lần retry thứ năm được lên lịch 7 phút sau lúc tạo commit.

**Mẹo:** kể theo thứ tự triệu chứng → đo → nguyên nhân gốc → sửa → bài học. Câu "đo trước khi đoán" là điểm chính.

**A7.2** **Ý chính:** "Revert xong, app đã `Synced` mà `root` vẫn `Degraded`. Lý do: lần sync lỗi dừng trước wave 2, nên sau
khi revert, Git lại khớp với cluster, và automated sync không có gì để chạy. Nhưng trạng thái sync cuối vẫn là `Failed`, và luật
`report-failed-sync` đọc đúng trường đó. Tôi chạy một lần sync bằng tay, và lần thành công đó thay trạng thái `Failed`. Bài
học: Git đúng chưa có nghĩa là trạng thái đã sạch."

*Nếu được hỏi thêm:*

- Sync tay bằng cách patch `operation` vào Application, hoặc bấm Sync trong UI.
- Tôi thêm trường hợp này vào troubleshooting và sơ đồ.

**A7.3** **Ý chính:** "Log báo `0 was expected` thay vì mười hai số 0. Tôi đã viết `version: 000000000000` không có dấu nháy,
và YAML đọc nó thành số nguyên `0`; template quote lại thành chuỗi `"0"`. Test vẫn hỏng như dự tính, chỉ message sai. Bài học:
chuỗi nào trông giống số, như version hex, account ID, tag toàn chữ số, phải để trong dấu nháy. Từ đó tôi quote mọi index
version trong values."

*Nếu được hỏi thêm:*

- Nguy hiểm hơn: một account ID không quote có thể bị in thành `2.42834061265e+11` trong tên image và ARN. Render vẫn qua,
  chỉ lỗi lúc chạy (B2.1).

**A7.4** **Ý chính:** "Hai query Prometheus trả rỗng, và `up` rỗng chứ không phải `0`, nghĩa là Prometheus không hề có target.
Tôi kiểm từng lớp: script query của tôi vẫn chạy với namespace khác; Application vẫn đứng ở commit trước; ServiceMonitor không
tồn tại trên cluster. So với `git ls-remote` thì thấy commit mới nằm trên một nhánh tạm gõ nhầm tên, và `main` chưa được cập
nhật. Argo CD không sai, nó chỉ đọc `main`. Bài học: sau khi đẩy lên `main`, tôi kiểm commit trên `main` rồi mới chờ sync của
đúng commit đó."

*Nếu được hỏi thêm:*

- Lệnh chờ đầu tiên tôi viết cũng sai: `sync.revisions` đổi ngay khi refresh, trước khi apply. Đúng phải là
  `operationState.syncResult.revisions`.

**A7.5** **Ý chính:** "Tôi muốn chứng minh hai điều mà thiết kế chỉ hứa: một bản build hỏng không thay pod đang chạy, và nó hiện
lên ở chỗ tôi nhìn đầu tiên. Kết quả: Job lỗi, wave 2 không được apply, pod cũ vẫn `1/1 Running` với 0 restart, và `root`
chuyển `Degraded` với message của lần sync. Bài test còn làm lộ ra hai điều tôi không biết: retry mặc định, và việc revert không
tự xoá trạng thái `Failed`."

**Mẹo:** "cố ý làm hỏng để kiểm chứng" là câu trả lời mạnh cho câu "bạn test hệ thống thế nào".

### A8. Tình huống

**A8.1** **Ý chính:** "Init container là `index-pull`, nên tôi đọc log của nó trước: `kubectl logs <pod> -c index-pull`. Ba
trường hợp hay gặp. `InvalidIdentityToken`: key set trên S3 không khớp key của cluster, chạy `make oidc-check`. `AccessDenied`
trên `AssumeRoleWithWebIdentity`: ServiceAccount hoặc namespace không khớp `sub` trong trust policy. `FileNotFoundError … not
found`: version chưa có trên S3, thường vì Job chưa chạy hoặc đã lỗi."

*Nếu được hỏi thêm:*

- Sau đó mới tới `describe pod` (event, OOMKilled, Evicted vì vượt `sizeLimit`) và trạng thái sync của Application.

**A8.2** **Ý chính:** "Người dùng không thấy gì: Job ở wave 1 lỗi thì wave 2 không được apply, pod đang chạy giữ version cũ.
Client embedding đã tự retry từng batch, và `backoffLimit: 0` chặn Job tự chạy lại toàn bộ. Nhưng Argo CD vẫn retry cả sync tối
đa năm lần, mỗi lần chạy lại Job và đốt thêm quota. Nên với lỗi quota, tôi dừng operation đang retry, chờ quota hồi, rồi mới
sync bằng tay."

*Nếu được hỏi thêm:*

- Lưu ý: app vẫn `OutOfSync`, nên bất kỳ commit nào lên `main` trong lúc đó cũng làm automated sync chạy lại Job. Tôi không
  push gì cho tới khi quota hồi.

**A8.3** **Ý chính:** "Key bị lộ: ai có nó mint được token cho bất kỳ ServiceAccount nào, với thời hạn tuỳ ý, rồi assume mọi role
IRSA. Việc đầu tiên là gỡ public key cũ khỏi key set trên S3, để STS thôi tin token ký bằng nó. Credential STS đã cấp vẫn dùng
được tới khi hết hạn, mặc định một giờ. Rồi sinh key mới, dựng lại cluster, công bố key set mới. Bucket bị xoá: mọi lần đổi
token lấy credential đều thất bại, pod mới không tải được index. `prevent_destroy` chặn Terraform xoá, và versioning giữ bản cũ
nếu chỉ bị ghi đè."

*Nếu được hỏi thêm:*

- `oidc-publish` từ chối ghi đè key set đã có, nên thay key phải có chủ ý (B4.4).
- Điểm yếu đã biết: key đi qua transfer bucket mà node role đọc được, trong lúc `make cluster` (`docs/app/README.md` §7).
- STS cache key set bao lâu, và quy trình thay key không downtime (công bố cả hai key trong một thời gian): **[kiểm chứng]**,
  tôi chưa làm thử.

**A8.4** **Ý chính:** "Nếu node mất không có pod prod thì không có gì phải di chuyển. Nếu có, Kubernetes đợi khoảng năm phút rồi
mới evict pod trên node chết, và pod mới vào node còn lại chưa có pod prod, vì `maxSkew: 1` cho phép. Nó chỉ `Pending` khi node
đó không còn đủ CPU chưa bị request, vì `DoNotSchedule` cấm chen chung node với pod kia. Trong lúc đó prod chạy bằng một pod.
CPU là tài nguyên chật nhất, nên tôi cố ý để request của app nhỏ, 50m."

*Nếu được hỏi thêm:*

- Năm phút là `tolerationSeconds: 300` mặc định cho taint `not-ready`/`unreachable` (`Common B3.4`).

**A8.5** **Ý chính:** "Trước phase này: pod gọi IMDS và nhận role của node, gồm secret, private key của certificate, DNS, KMS.
Giờ container app không có token Kubernetes, không có credential AWS, và IMDS bị NetworkPolicy chặn. Những gì họ vẫn có: API
key của Gemini và Hugging Face trong biến môi trường, key Flask, và egress 443 ra internet. Pod chạy non-root, root filesystem
read-only, không capability."

*Nếu được hỏi thêm:*

- Index là pickle: ai ghi được vào `faiss/` là chạy code trong pod. Role của app chỉ đọc, builder chỉ ghi `faiss/*`, và Job chỉ
  chạy khi sync.
- Bước tiếp theo: egress theo tên miền, và API key riêng cho từng môi trường (A9.5).

### A9. Đánh đổi và quy mô

**A9.1** **Ý chính:** "Ba việc. Làm HTTPS ngay từ đầu, bằng ACM trên NLB. Đo rolling update và tải từ sớm, thay vì chỉ mười câu
hỏi. Và viết quy trình kiểm trên nhánh tạm thành script, vì lỗi push nhầm nhánh là lỗi thao tác tay. Thiết kế lõi thì tôi giữ:
role riêng qua token, index là artifact, Job ở wave giữa."

**A9.2** **Ý chính:** "HPA theo CPU là vô nghĩa ở đây, vì app gần như chỉ chờ API bên ngoài. Tín hiệu đúng là số request đồng
thời hoặc độ trễ. Prometheus đã có `http_requests_total` và histogram độ trễ, nên tôi sẽ dùng Prometheus Adapter hoặc KEDA để
scale theo request mỗi giây. Nhưng trần thật là quota của Gemini và Hugging Face: thêm pod không làm quota tăng lên."

*Nếu được hỏi thêm:*

- Khi quota là trần: cache câu trả lời cho câu hỏi lặp lại, xếp hàng request thay vì gọi đồng thời, và xin tăng quota hoặc
  chuyển gói trả phí.
- Cài metrics-server vẫn nên làm, cho `kubectl top` và HPA theo bộ nhớ.

**A9.3** **Ý chính:** "Không ổn lắm. Mỗi pod tải toàn bộ index lúc khởi động làm chậm Ready và tốn băng thông S3, và giữ cả index
trong RAM làm tăng request bộ nhớ của mỗi pod. Lúc đó tôi tách vector store thành một dịch vụ riêng: OpenSearch, pgvector hoặc
một vector database có sẵn. Pod app chỉ còn là client."

**A9.4** **Ý chính:** "Mỗi team một namespace và một AppProject giới hạn repo, namespace đích và loại resource được tạo. Role IAM
theo từng ServiceAccount của từng team, cùng issuer. Application sinh ra bằng ApplicationSet thay vì viết tay. Và quyền Git trở
thành lớp bảo vệ chính: branch protection, CODEOWNERS cho `deploy/`."

*Nếu được hỏi thêm:*

- Hiện mọi Application dùng AppProject `default` (`GitOps A6.3`).

**A9.5** **Ý chính:** "Account ID: chấp nhận được. AWS coi nó là định danh, không phải secret, và tên image cùng ARN của role cần
nó. API key dùng chung: đó là điểm yếu tôi biết. Hậu quả: dev dùng hết quota thì prod cũng chết theo, và lộ key của dev là lộ
key của prod. Mỗi môi trường đã có secret riêng trong Secrets Manager, nên tách được ngay bằng `put-secret-value`. Tôi mới tách
key Flask cho prod, còn API key của model thì chưa."

### A10. Doanh nghiệp làm thế nào

**A10.1** **Ý chính:** "Trên EKS tôi sẽ chọn EKS Pod Identity cho workload mới: không cần OIDC provider cho từng cluster, và
trust policy đơn giản hơn. IRSA vẫn phổ biến và chạy được ở mọi nơi. Cách tự dựng như project của tôi chỉ hợp với cluster không
phải EKS: kubeadm trên EC2, hoặc on-prem gọi AWS. Nó chứng minh tôi hiểu cơ chế bên dưới, nhưng ở công ty tôi sẽ chọn dịch vụ
được quản lý."

*Nếu được hỏi thêm:*

- Khác biệt chi tiết giữa Pod Identity và IRSA: **[kiểm chứng]** theo tài liệu EKS hiện hành.

**A10.2** **Ý chính:** "Họ tách hai phía từ gốc, chứ không dựa vào allowlist. Hai ingress controller với hai IngressClass,
public và internal, mỗi cái có load balancer riêng. Ingress của Argo CD mang class internal, nên controller public không hề có
route tới nó. TLS được giải mã ở biên bằng ACM trên ALB hoặc NLB, hoặc ở CDN, thường kèm WAF. Công cụ nội bộ thì đi qua VPN
hoặc proxy kiểu Zero Trust có SSO."

*Nếu được hỏi thêm:*

- Trên EKS, AWS Load Balancer Controller làm việc này bằng annotation `scheme: internet-facing` hoặc `internal` cho từng Ingress.
- Project của tôi tách bằng *cổng* (80 public, 443 nội bộ) trên một controller. Đủ dùng ở quy mô này, cho tới khi cần HTTPS
  public (A5.3).

**A10.3** **Ý chính:** "External Secrets khi nguồn là secret manager của cloud và muốn có Secret Kubernetes thường, như ở đây.
Vault khi cần secret động, như credential database sinh theo yêu cầu, hoặc chạy đa cloud. Secrets Store CSI khi không muốn secret
nằm trong etcd. Để pod nhận giá trị mới, hoặc đọc từ file mount vì file tự cập nhật, hoặc dùng Reloader, hoặc một checksum
annotation khiến Deployment rollout khi secret đổi."

**A10.4** **Ý chính:** "Metrics-server cho số liệu tức thời, VPA ở chế độ recommender để có đề xuất dựa trên lịch sử, và
request đặt theo p95 hoặc p99 qua một tuần có tải thật, chứ không phải mười câu hỏi. Limit bộ nhớ có khoảng dư, CPU thường không
đặt limit. Xem lại định kỳ hoặc sau mỗi thay đổi lớn."

*Nếu được hỏi thêm:*

- Số của tôi là điểm khởi đầu có căn cứ, không phải số cuối cùng (B5.1).

**A10.5** **Ý chính:** "Dùng lại đúng issuer và OIDC provider đã có. Mỗi component một role riêng với trust policy theo `sub` của
ServiceAccount của nó, và thêm token cùng các biến `AWS_*`, phần lớn chart upstream có sẵn value cho việc đó. Khi mọi pod đã có
role riêng, hạ hop limit IMDS xuống 1 để pod không với tới IMDS nữa."

*Nếu được hỏi thêm:*

- Thứ tự tôi sẽ làm: External Secrets trước, vì nó đọc được mọi secret; rồi cert-manager, EBS CSI.

**A10.6** **Ý chính:** "Scan ở CI và chặn theo mức độ, có ngoại lệ được ghi lại và có hạn. Base image tối thiểu để bớt package
không dùng: image của tôi đã là `python:3.12-slim-bookworm`, mà ba lỗi CRITICAL vẫn nằm ở `perl`, nên bước tiếp là distroless.
Rebuild định kỳ để lấy bản vá, và theo dõi CVE của image *đang chạy*, không chỉ lúc build. 4 CRITICAL là mốc 'trước'; phase
Jenkins đo lại."

*Nếu được hỏi thêm:*

- `perl` hay `perl-base`: **[kiểm chứng]** trong báo cáo scan. `perl-base` là package bắt buộc của Debian, bản slim không bỏ
  được nó.
- Cổng Trivy của pipeline: `Common A6.2`. Số "sau": `[điền]`.

---

## Phần B — Chi tiết code

### B1. Chart `deploy/charts/medical-rag/`

**B1.1** `AWS_ROLE_ARN` là role cần assume. `AWS_WEB_IDENTITY_TOKEN_FILE` là đường dẫn token (`/var/run/secrets/aws/token`).
`AWS_REGION` là vùng. `AWS_STS_REGIONAL_ENDPOINTS=regional` cho SDK gọi STS của vùng thay vì endpoint toàn cục. SDK thấy hai biến
đầu thì dùng `AssumeRoleWithWebIdentity` trước khi thử IMDS. Token là `serviceAccountToken` được chiếu vào pod, audience
`sts.amazonaws.com`, `expirationSeconds: 3600`, và kubelet tự làm mới. Bỏ biến regional thì bản SDK cũ có thể gọi endpoint toàn
cục, phụ thuộc thêm một vùng. Mặc định của botocore trong image: **[kiểm chứng]**.

**B1.2** `backoffLimit: 0`: không chạy lại cả lần build, vì client đã retry từng batch và chạy lại là tốn quota gấp đôi.
`activeDeadlineSeconds: 1200`: build treo thì bị giết sau 20 phút thay vì giữ sync mãi. `BeforeHookCreation`: xoá Job cũ ngay
trước khi tạo Job mới, nên log của lần trước đọc được tới lần sync sau, và không bị lỗi tên trùng.

**B1.3** `automountServiceAccountToken: false` tắt token *Kubernetes* mặc định, loại có audience API server. Token AWS là volume
chiếu riêng, audience `sts.amazonaws.com`, và API server không chấp nhận nó (A2.7). Chỉ init container `index-pull` mount token
AWS, vì chỉ nó gọi S3; container `app` không mount token nào (A4.2).

**B1.4** Startup probe cho tới 5 phút (30 × 10 s) để chain RAG build xong mà liveness không giết pod. Ở local mất khoảng 6 s.
Liveness gọi `/healthz` với timeout 5 s mỗi 20 s, ba lần mới tính hỏng, nên một pod đang bận gọi LLM chậm không bị restart.
`preStop: sleep 5` cho ingress-nginx kịp gỡ pod khỏi danh sách. Grace 45 s lớn hơn 5 s preStop cộng 30 s `graceful_timeout` của
gunicorn.

**B1.5** Mọi thứ app ghi đều vào `/tmp`, một `emptyDir`: init container ghi index vào `/tmp/index`, app ghi heartbeat của
gunicorn, file multiprocess của Prometheus và cache Hugging Face. Job có `sizeLimit` 512Mi, lớn hơn 256Mi của app, vì nó giữ bản
copy corpus 12 MB và index mới trước khi upload. Vượt giới hạn thì kubelet evict pod.

**B1.6** NetworkPolicy cộng dồn: một pod được phép nếu *bất kỳ* policy nào cho phép. `default` chọn mọi pod, chặn mọi ingress, và
egress chỉ DNS và 443 trừ IMDS. `allow-from-ingress-nginx` và `allow-from-prometheus` mỗi cái mở đúng một nguồn vào cổng 8000.
Thêm nguồn mới là thêm một policy, `default` giữ nguyên, nên không có nguy cơ vô tình nới rộng nó.

**B1.7** `pathType: Exact` với hai path `/` và `/clear`: `/metrics`, `/healthz`, `/readyz` và mọi path khác không khớp Ingress
nào, nên nginx trả `404` từ ngoài. `Prefix` với `/` sẽ khớp mọi thứ. `proxy-read-timeout: "120"` vì một câu trả lời có thể quá
60 s, mặc định của nginx: embedding retry, rồi tới hai lần gọi LLM mỗi lần 30 s.

**B1.8** Render PDB `minAvailable: 1` cho một replica thì không pod nào được phép bị evict, nên `kubectl drain` treo vô hạn
(`Common B3.3`). `int` vì Helm đọc số từ file values thành float64, và template Go báo lỗi khi so float với số nguyên `1`.

**B1.9** Năm giá trị: `environment`, `aws.accountId`, `image.tag`, `index.version`, `ingress.host`. Thiếu một trong số đó thì
render thất bại ngay ở `helm lint`, thay vì tạo ra tên image hỏng hay role sai. `required` không bắt được giá trị *sai*: ví dụ
`environment: staging` vẫn render, rồi pod chọn role `medical-rag-app-staging` không tồn tại và secret `app-staging` không có.

**B1.10** Không đặt thì Argo CD dùng tên Application làm release name, tức `medical-rag-dev`. Tên object trong chart là cố định
nên không đổi, nhưng nhãn `app.kubernetes.io/instance` đổi. Cố định `medical-rag` để `helm template medical-rag …` trên
workstation render đúng những gì Argo CD render, và hai môi trường có nhãn giống nhau.

**B1.11** Pod: `runAsNonRoot`, `runAsUser`/`runAsGroup`/`fsGroup` 10001, seccomp `RuntimeDefault`. Container:
`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`. `enforce` chỉ kiểm Pod, nên
Deployment vi phạm vẫn được tạo và lỗi chỉ nằm trong event của ReplicaSet. `warn` kiểm cả workload, nên dry run in ra cảnh báo
(A4.1).

**B1.12** Rolling update tạo pod thứ ba trước (`maxSurge: 1`). Với `maxSkew: 1` trên ba node, pod đó vào node còn lại, rồi một pod
cũ mới dừng. Nếu node còn lại không đủ CPU chưa bị request, pod surge `Pending`, và vì `maxUnavailable: 0` nên rollout dừng mà
không pod cũ nào bị tắt. Prod an toàn, nhưng bản mới không lên được cho tới khi có chỗ.

**B1.13** `INDEX_REQUIRE_PINNED=true` (init container): từ chối tải con trỏ `LATEST`, pod chỉ tải version cụ thể.
`INDEX_EXPECTED_VERSION` (Job): dừng trước khi embed nếu corpus băm ra version khác (A3.4). `INDEX_UPDATE_LATEST=false` (Job):
không dời con trỏ `LATEST`. Biến này chỉ là thiết lập, ai sửa chart là tắt được; `Deny` trong IAM biến nó thành luật (B4.1).

### B2. Values và Application

**B2.1** YAML đọc chuỗi trông giống số thành số: `000000000000` thành `0`, và một ID 12 chữ số có thể bị Helm in thành
`2.42834061265e+11`. Chart vẫn render, chỉ lỗi lúc chạy. Để trong dấu nháy thì luôn là chuỗi (A7.3).

**B2.2** `latest` nghĩa là chuẩn `restricted` của đúng phiên bản Kubernetes đang chạy. Khi nâng cấp, chuẩn có thể chặt thêm và
pod đang hợp lệ bỗng bị từ chối lúc tạo lại. Hiện cả `enforce` và `warn` đều để `latest`, nên chúng chặt thêm cùng lúc, không có
cảnh báo trước. Cách chuẩn: ghim `enforce-version` theo bản cluster đang chạy, và để `warn-version: latest`, để thấy trước những
gì bản mới sẽ chặn.

**B2.3** Có tác dụng khi `root` sync: trên cluster mới, dev ở wave 1 build index trước, prod ở wave 2 tìm thấy nó. Không có tác
dụng khi release bình thường: commit lên `main` thì mỗi Application tự sync theo `automated` của nó, prod không chờ dev.

**B2.4** Có: file sau ghi đè file trước, nên `common.yaml` đặt giá trị chung, còn file của môi trường ghi đè. Source `$values`
cho đường dẫn tính từ gốc repo, dễ đọc, và sau này tách values sang repo khác được mà không đổi chart. Đường dẫn tương đối
`../` trong cùng repo có lẽ cũng chạy **[kiểm chứng]**.

### B3. Health check Lua trong `deploy/argocd/values/argocd.yaml`

**B3.1** Opt-in để các Application nền tảng vẫn được đánh giá như trước; tôi chưa từng thử cho một Application nền tảng lỗi sync
làm `root` `Degraded` giữa lúc dựng lại. Nhánh này đứng trước nhánh `Healthy` + `Synced`, để bắt trường hợp sync `Failed` mà
resource đã khớp Git, như sau khi revert (A7.2). Nếu đứng sau, nhánh `Healthy` trả `Healthy` trước, và lỗi bị giấu. Đứng trước
nhánh `Degraded` để message là lỗi sync, tức nguyên nhân, chứ không phải health.

**B3.2** `Error` là phase khi sync không chạy được, khác với `Failed` là chạy rồi hỏng; cả hai đều là "lần sync cuối không thành
công". `root` vẫn chờ mãi không báo lý do khi một con `Healthy` mà `OutOfSync`, hoặc `Suspended`, `Missing`. Chưa từng được thử
trên cluster: nhánh `Error`, và nhánh "Application không có resource nào" (sai `path:`). Nhánh `Failed` đã được chứng minh (A7.5).

### B4. Terraform, Ansible và Makefile

**B4.1** `StringEquals` trên `aud` và `sub`: chỉ token cho AWS, và chỉ đúng ServiceAccount trong đúng namespace (A2.6).
`ListBucket` với điều kiện `s3:prefix` `faiss/*`: pod liệt kê được version index nhưng không thấy `corpus/`. `Deny` ghi
`faiss/LATEST`: cluster không bao giờ dời con trỏ đó, kể cả khi ai đó bật lại `INDEX_UPDATE_LATEST` (B1.13).

**B4.2** OIDC provider (`irsa.tf`) không có thumbprint: IAM kiểm certificate TLS của S3 bằng CA tin cậy của nó. Bucket
(`oidc.tf`) có `prevent_destroy`: bucket bị xoá thì người khác chiếm được tên và công bố key của họ (A2.5). Bucket policy chỉ cho
đọc công khai đúng hai key, còn `block_public_policy = false` để policy đó được phép: bucket không thành chỗ công khai bất kỳ
thứ gì được upload nhầm.

**B4.3** Issuer đầu tiên được ghi vào token mới: địa chỉ S3 mà AWS tin. Issuer thứ hai, `kubernetes.default.svc.cluster.local`,
vẫn được chấp nhận, nên token cũ và client dùng issuer nội bộ không bị gãy. `service-account-jwks-uri` để discovery document trỏ
AWS tới key set trên S3; không đặt thì nó trỏ vào địa chỉ private của API server. `api-audiences` đặt tường minh và cố ý không có
`sts.amazonaws.com`, để token cho AWS không dùng được với API server (A2.7).

**B4.4** Key set khác bản đã công bố nghĩa là key của cluster đã đổi. Ghi đè sẽ chuyển mọi role sang key mới mà không ai quyết
định, nên script báo `DIFFERENT` và dừng. `--if-none-match '*'` chặn cả trường hợp object vừa xuất hiện. `oidc-check` sau mỗi lần
dựng lại xác nhận cluster mới vẫn ký bằng key đã công bố. Nếu không khớp, mọi pod sẽ lỗi khi đổi token lấy credential.

**B4.5** AWS chỉ tin token ký bằng key đã công bố, nên key phải giống nhau qua mọi lần dựng lại (A2.4). Nếu `sa.key` trên node
khác secret, cluster đó đã được `kubeadm init` với key khác: issuer và key được chọn lúc init, nên thay file dưới API server
đang chạy không đủ, và token đã phát ra vẫn ký bằng key cũ. Cách sửa sạch là dựng lại cluster.

### B5. Evidence

**B5.1** Không hoàn toàn. 10 s là pod mới từ lúc tạo tới Ready. Khoảng 150 s là thời gian *build* index, việc mà pod cũ phải làm
lúc khởi động; thời gian Ready của pod cũ chưa từng được đo trên cluster. Nói đúng là: "việc 150 giây đó không còn nằm trên đường
khởi động". 320Mi là 276.9 MiB sau mười câu hỏi, làm tròn lên bội 64. 640Mi là gấp đôi request.

**B5.2** Còn thiếu:
- dòng `rag_index_info`;
- query `[15m]` chạy lại;
- thời gian từ lúc push tới `Failed`;
- ARN role và kiểm tra IMDS ở prod;
- CPU burst;
- số request rớt khi rolling update.

Phần lớn chỉ cần một lệnh Prometheus hoặc `kubectl exec` trên cluster đang chạy. Rolling update cần một vòng `curl` trong lúc
đổi image.
