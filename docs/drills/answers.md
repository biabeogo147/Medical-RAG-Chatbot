# Đáp án phase drills

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Phần A mở đầu bằng **Ý chính**: câu nói thành tiếng,
ngôi thứ nhất, thường là đủ. *Nếu được hỏi thêm* dùng khi người phỏng vấn đào sâu; tham chiếu như `(B2.1)` là để bạn
tra, không đọc ra. Dòng **Mẹo** là lời nhắc cho bạn, không nói ra. Tham chiếu dạng `Common A7.2` trỏ tới
[`../common/answers.md`](../common/answers.md), tương tự với `Jenkins`, `GitOps`, `Ansible`, `Terraform`, `AWS`.

Mọi con số dưới đây lấy từ [`../evidence/drills.md`](../evidence/drills.md), đo ngày 22/09/2026. Số thập phân viết
bằng dấu chấm, như các bộ khác.

**Số liệu đã có:**

- **#12 khôi phục etcd:** RTO **7 m 02 s**, từ lúc xoá namespace (04:51:04Z) tới khi mọi Application `Synced Healthy`
  và Lease của cả ba node mới (04:58:06Z). RPO của lần drill 6 m 01 s; theo lịch là tối đa 6 giờ.
- **Snapshot đầu tiên:** revision 134191, 2434 key, 62 MB (62,402,592 byte), 8 giây; chạy dưới một lịch tạm `*/15`.
- **#13 Kyverno:** prod từ chối image chưa ký với lỗi admission nguyên văn; pod dùng image đã ký vẫn được tạo.
- **#14 nâng cấp:** **không đo được**. 1.36.4 là bản vá mới nhất của 1.36; `upgrade.yml` có nhưng chưa chạy.
- **Dựng lại có bấm giờ:** **21 m 47 s** từ cluster stack trống tới 17 Application `Synced Healthy`, không cần người.
- **Positive control của cổng Trivy:** build 2 đỏ với `Fixable, any severity: 6`.

| Điểm yếu còn lại | Câu liên quan |
|---|---|
| Nâng cấp chưa chạy; kể cả khi chạy cũng chỉ là đường patch | A4.1, A4.4 |
| Khôi phục snapshot lên một cluster dựng lại (PKI mới) chưa thử | A2.12 |
| Role của node đọc, ghi và xoá được bucket backup; bucket không versioning | A2.3 |
| Chưa đo xem Kyverno có gọi ra Sigstore công khai lúc admission không | A3.7 |
| Chưa quan sát được một job do chính lịch `0 */6` tạo ra | A2.10 |
| Kyverno chỉ kiểm image của app ở hai namespace app | A3.8 |
| Không có cảnh báo khi một job snapshot hỏng | A2.13 |
| `failurePolicy: Fail` là cấu hình; hành vi khi Kyverno sập chưa được thử | A3.6 |

---

## Phần A — Phỏng vấn

### A1. Tổng quan

**A1.1** **Ý chính:** "Phase này chứng minh ba kiểm soát bằng cách cố ý làm chuyện xấu xảy ra. Tôi xoá một namespace
rồi khôi phục etcd trên cả ba node, đo được RTO 7 phút. Tôi đưa một image chưa ký lên prod, và Kyverno từ chối nó ngay
lúc tạo pod. Còn nâng cấp Kubernetes thì tôi nói thật là không đo được: 1.36.4 đã là bản vá mới nhất, nên không có gì
để nâng. Kèm theo, tôi đo lại cả nền tảng: dựng từ stack trống tới 17 Application khoẻ trong 21 phút 47 giây, không
cần ai gõ lệnh. Điều tôi học nhiều nhất là cách một phép đo có thể pass sai: phase này có hai lần như vậy, và một
lần tôi chặn được trước khi nó xảy ra."

*Nếu được hỏi thêm:* hai lần là lệnh chờ `root` chỉ đọc health, và một câu trong guide bảo "xoá một pod là an toàn"
trong khi lệnh đó xoá cả hai pod prod (A3.11). Lần chặn trước là trạng thái cũ mà snapshot khôi phục lại (A2.7). Cả ba
ở A6.1.

**A1.2** **Ý chính:** "#12 đòi một con số RTO: có, 7 phút 02 giây. #13 đòi chính lỗi admission khi đưa image chưa ký
lên prod: có, nguyên văn. #14 đòi số request lỗi trong lúc nâng cấp: không có, vì không có bản đích."

*Nếu được hỏi thêm:*

| # | Bằng chứng đòi hỏi | Kết quả |
|---|---|---|
| 12 | RTO của một lần khôi phục thật | **7 m 02 s**, canary quay về đúng giá trị |
| 13 | Lỗi admission khi deploy image chưa ký lên prod | Có, nguyên văn (A3.1). Chỉ nửa về chữ ký; nửa Pod Security baseline chưa làm |
| 14 | Số request lỗi khi nâng cấp | **Không đo được**: không có bản 1.36 nào mới hơn 1.36.4 |

**A1.3** **Ý chính:** "Vì một kiểm soát chưa từng bị thử thì chỉ là một giả định. Backup chưa từng khôi phục thì không
biết có dùng được không; một policy không chặn gì trông giống hệt một policy không khớp gì. Nên mỗi kiểm soát đi kèm
một lần gây ra đúng chuyện nó phải chặn, và kết quả là một con số hoặc một thông báo lỗi."

*Nếu được hỏi thêm:* ví dụ rõ nhất là lần `Audit` đầu của Kyverno: policy khớp đúng 5 pod, nhưng báo `fail` cả 5, trên
image đã ký. Không chạy thử thì bật `Deny` sẽ chặn luôn prod (A3.5).

**A1.4** **Ý chính:** "Tôi chuyển bucket backup etcd từ stack cluster sang stack `shared` trước khi dựng lại. Trước đó
nó nằm trong stack cluster với `force_destroy`, nên mỗi `make down` xoá sạch mọi snapshot. Phải làm lúc cluster đang
bị xoá, vì khi đó bucket không tồn tại ở đâu cả, nên việc chuyển chỉ là tạo mới, không phải di chuyển state."

*Nếu được hỏi thêm:*

- Năm file Terraform: bỏ bucket khỏi map của cluster, thêm nó vào `shared` (không `force_destroy`), thêm output, thêm
  một `data` lookup theo tên ở stack cluster, và thêm ARN đó vào hai statement S3 của node role.
- Hai statement cuối là chỗ dễ sót: policy của node lặp qua *các bucket của chính stack cluster*, nên bỏ bucket khỏi map
  là node mất quyền ghi mà không báo gì. Tôi đọc lại policy từ AWS bằng `get-role-policy` sau khi dựng: đủ cả hai ARN.
- `make shared` cùng lúc apply một thay đổi còn nợ: repository `medical-rag-ci` chuyển sang `IMMUTABLE`.

### A2. Backup và khôi phục etcd (#12)

**A2.1** **Ý chính:** "Mỗi sáu giờ, một pod chạy trên node control plane: một container chụp snapshot, một container
kiểm snapshot đó đọc được, rồi một container upload lên S3. Ba container vì không image nào có đủ công cụ: image etcd
có `etcdctl` và `etcdutl` nhưng không có AWS CLI, và nó là distroless nên không có shell để nối hai lệnh."

*Nếu được hỏi thêm:*

- Hai container đầu là initContainer, nên upload chỉ chạy khi cả hai đã thành công.
- Upload dùng image tools của pipeline, vốn đã có AWS CLI, đã nằm trong ECR, và node đã kéo được nó.
- Key trên S3 có dạng `snapshots/<giờ UTC>-<node>.db`.
- Lần chạy đầu: 8 giây, 62 MB, trên `medical-rag-node-3` (B1.1–B1.4).

**A2.2** **Ý chính:** "Vì một file hỏng hay bị cắt ngang vẫn upload rất vui vẻ. `etcdutl snapshot status` từ chối file
nó không đọc được, và in ra hash, revision, số key, kích thước. Nó không bắt được một snapshot đọc được nhưng rỗng: con
số đó tôi phải tự đọc."

*Nếu được hỏi thêm:* lần đầu in hash `65062525`, revision 134191, 2434 key, 62 MB. Revision 0 hay 0 key thì nghĩa là
snapshot rỗng, và bước kiểm tự động vẫn cho qua. Vì vậy trên CV tôi viết "checked with `etcdutl snapshot status`",
không viết "integrity check".

**A2.3** **Ý chính:** "Từ role của node, qua metadata service; không cấu hình credential nào. Rủi ro là role đó có
nhiều hơn CronJob cần: tám secret, bản ghi TXT của ACME, và cả quyền xoá object trong chính bucket backup, mà bucket lại
không bật versioning. Nên một pod bất kỳ lấy được credential của node là xoá được backup."

*Nếu được hỏi thêm:* cách sửa là một role IRSA riêng chỉ có `PutObject`, cộng versioning hoặc Object Lock cho bucket.
Tôi chọn đường đơn giản và ghi nó vào danh sách giới hạn, không giấu đi.

**A2.4** **Ý chính:** "Tạo một namespace không nằm trong Git, có một ConfigMap ghi giờ tạo, trước lần chụp snapshot.
Chờ snapshot theo lịch. Xoá namespace, bấm giờ. Dừng etcd và API server trên cả ba node, dời dữ liệu cũ sang chỗ khác,
khôi phục từ cùng một file trên cả ba, đưa manifest về, rồi chờ tới khi mọi thứ reconcile xong."

*Nếu được hỏi thêm*, theo thứ tự:

1. Canary `restore-drill/canary`, `written-at=2026-09-22T04:14:20Z`.
2. Snapshot 04:45:03Z, tải về workstation, copy lên cả ba node (cùng checksum `ded1f327…`).
3. Pre-check: trên mỗi node, `--name` và peer URL trong manifest trùng với giá trị restore sẽ dùng.
4. t1 = 04:51:04Z, `kubectl delete namespace restore-drill`.
5. Phase 1 tới 5, mỗi phase xong trên cả ba node rồi mới sang phase sau (B2.1). Phase 0, tải và copy snapshot, đã chạy
   trước t1.
6. t2 = 04:58:06Z; canary quay về đúng `04:14:20Z`.

**A2.5** **Ý chính:** "Vì một member đã khôi phục mà nhập lại vào một quorum hai member đang chạy thì hoặc bị từ chối,
hoặc âm thầm mất dữ liệu. Nên control plane phải ngừng hẳn: cả ba dừng, cả ba khôi phục từ cùng một file với cùng danh
sách member và cùng token, rồi cả ba mới khởi động."

*Nếu được hỏi thêm:* bằng chứng là cả ba node ra cùng cluster-id `9ed3a0fb6a89e03e` và cùng ba member. Cái giá là API
ngừng hoàn toàn trong lúc khôi phục; đó là lý do RTO tính cả khoảng đó.

**A2.6** **Ý chính:** "Snapshot lùi revision của etcd về lúc chụp, trong khi mọi controller và kubelet đang cầm
resourceVersion mới hơn. Không đẩy revision lên thì các lần ghi mới sẽ dùng lại những revision chúng đã thấy, và watch có
thể bỏ sót sự kiện. `--bump-revision` cộng một khoảng lớn vào revision, còn `--mark-compacted` đánh dấu phần cũ là đã
compact để client phải list lại."

*Nếu được hỏi thêm:* lần này revision đi từ 134191 lên 1000134191. Tôi không có một lần chạy *không* bump để so, nên
phần "bỏ đi thì watch lỗi" là theo tài liệu của etcd và Kubernetes, không phải điều tôi đã quan sát.

**A2.7** **Ý chính:** "Từ lúc xoá namespace tới khi mọi Application `Synced Healthy`. Nhưng snapshot khôi phục cả
*status* cũ của lúc chụp, khi mọi thứ đang khoẻ, nên một vòng chờ chỉ đọc health có thể dừng ngay khi API vừa trả lời.
Tôi chỉ dừng đồng hồ khi `reconciledAt` của từng Application và Lease của từng node mới hơn t1, và không pod nào nằm
ngoài Running hay Completed."

*Nếu được hỏi thêm:*

- Lúc API trả lời lần đầu (04:56:35Z), 2 trong 17 Application còn chưa reconcile sau t1. Không có điều kiện đó thì RTO
  đã ngắn hơn thực tế.
- Dùng Lease trong `kube-node-lease` chứ không dùng heartbeat trong status của node: kubelet gia hạn Lease khoảng 10
  giây một lần, còn status của node, theo mặc định của Kubernetes, chỉ được báo lại vài phút một lần khi không đổi, nên
  chờ nó sẽ thổi phồng RTO.
- Một phút sau t2, `make apps` vẫn cho thấy cả 17 khoẻ.

**A2.8** **Ý chính:** "Vì canary được tạo *trước* snapshot, không nằm trong Git nên Argo CD không tạo lại được, và sau
khi khôi phục nó trả về đúng timestamp đã ghi: `2026-09-22T04:14:20Z`. Một snapshot chụp trước khi có canary chỉ chứng
minh cluster sống lại; cái này chứng minh dữ liệu quay về."

**A2.9** **Ý chính:** "7 phút 02 giây, gồm cả thời gian tôi gõ lệnh: khoảng 30 giây để dừng các static pod, restore sau
3 phút 02 giây, API trả lời sau 5 phút 31 giây, Argo CD reconcile xong sau thêm 1 phút 16 giây, và 15 giây cuối là chờ
Lease của node và pod. RPO của lần drill là 6 phút, vì snapshot chụp 6 phút trước khi xoá; theo lịch 6 giờ thì RPO tối
đa là 6 giờ."

*Nếu được hỏi thêm:* RTO **không** gồm việc tải snapshot từ S3 và copy lên ba node, vì hai việc đó chạy trước t1; ở
một sự cố thật chúng nằm trong thời gian khôi phục, và tôi chưa bấm giờ riêng chúng. RTO này cũng là của một lần có
luyện tập, có guide và có người ngồi sẵn. Một sự cố thật lúc 3 giờ sáng
sẽ chậm hơn. Con số cũng gồm tối đa một chu kỳ reconcile của Argo CD, khoảng 3 phút.

**A2.10** **Ý chính:** "Không, với hai điều kiện tôi giữ. Job vẫn do CronJob controller tạo ra, không phải tôi tạo
bằng tay, nên đường lập lịch vẫn được thử; chỉ chuỗi cron là khác. Và lịch được đổi qua Git, rồi trả lại đúng từng byte
trước khi drill, vì hai lý do: lịch ghi trong Git phải là lịch thật mà tôi nói trên CV, và một lần chạy 15 phút có thể
rơi đúng lúc etcd đang tắt giữa lần khôi phục, để lại một pod lỗi làm kẹt vòng chờ đo RTO."

*Nếu được hỏi thêm:*

- Lịch tạm có hiệu lực lúc 04:38:40Z, lần chạy đầu 04:45:00Z pass, trả lại lúc 04:47:40Z; lịch tạm sinh đúng một job.
- Điều tôi chưa quan sát là một job do chính chuỗi `0 */6 * * *` tạo ra: cluster của drill bị xoá lúc khoảng 05:11Z,
  trước mốc 06:00 đầu tiên, và job 06:00 trên cluster dựng lại thì chưa ai đọc. Trên CV tôi vẫn ghi "6-hourly", vì đó
  là cấu hình cuối cùng.
- Snapshot được chọn và copy lên node trước t1, nên một lần chạy muộn hơn không thể thay chỗ snapshot có canary.

**A2.11** **Ý chính:** "Mọi thứ ghi sau lúc chụp, tức sau 04:45:03Z. Trong khoảng đó có đúng một thay đổi có ý nghĩa: việc trả
lịch snapshot về 6 giờ; ngoài ra chỉ là Lease, event và status được ghi liên tục. Snapshot chụp lúc lịch còn là 15 phút, nên CronJob quay lại `*/15`, và Argo CD tự sửa nó về theo
Git ở lần reconcile sau."

*Nếu được hỏi thêm:* chi tiết lạ là snapshot chụp đúng lúc chính Job của nó đang chạy dở. Sau khi khôi phục, job đó
hiện `DURATION 10m`, tính từ 04:45 tới khi controller đóng nó, trong khi lần chạy thật chỉ 8 giây.

**A2.12** **Ý chính:** "Chưa thử, và tôi nói rõ điều đó. Drill khôi phục trên chính cluster đã tạo ra snapshot. Một
cluster dựng lại có PKI mới; khôi phục snapshot cũ lên đó là một bài khác. Giữ snapshot qua teardown chỉ có giá trị
đầy đủ khi bài đó được chứng minh."

*Nếu được hỏi thêm:* khoá ký token service account thì được giữ nguyên qua mỗi lần dựng lại (lấy từ Secrets Manager),
nên phần IRSA sẽ không vỡ. Nhưng CA của cluster và certificate trong `/etc/kubernetes/pki` thì mới, và snapshot không
chứa chúng.

**A2.13** **Ý chính:** "Hiện tôi chỉ biết khi tự nhìn: không có cảnh báo nào cho một job snapshot hỏng. Nên 'RPO tối
đa 6 giờ' chỉ đúng khi mọi lần chạy đều thành công. Một lần hỏng thì lần kế tiếp mới có backup, tức RPO thành 12 giờ;
hai lần liền là 18 giờ, và không ai hay."

*Nếu được hỏi thêm:*

- Job có `backoffLimit: 1` và `startingDeadlineSeconds: 600`, nên một lần bị lỡ hay hỏng hai lần là mất lượt đó.
- Cách sửa: một rule Prometheus trên `kube_job_status_failed` của namespace `etcd-backup`, và một rule nữa khi tuổi
  của snapshot mới nhất trên S3 vượt quá khoảng 6 giờ 30 phút. Rule thứ hai bắt được cả trường hợp job không chạy
  chứ không chỉ chạy hỏng.
- Job giữ lại 3 lần lỗi gần nhất, nên khi biết thì vẫn đọc được log.

### A3. Kyverno và image chưa ký (#13)

**A3.1** **Ý chính:** "Kyverno chặn mọi pod ở namespace prod mà image của app không được ký bằng key cosign của
project. Tôi chứng minh bằng một image từ phase app, chưa từng được ký: tạo pod với nó ở prod thì bị từ chối ngay."

*Nếu được hỏi thêm:*

- Lỗi nguyên văn:
  `admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-images-prod" denied the request: Policy verify-images-prod failed: the image is not signed with the medical-rag cosign key`.
- Tên webhook có `svc-fail`: đó là webhook fail-closed của Kyverno, không phải Pod Security. Pod thử được viết cho qua
  Pod Security `restricted`, để lỗi nếu có chỉ có thể đến từ Kyverno.
- Trước khi bật chặn, `cosign verify` xác nhận digest prod đang chạy có chữ ký. Sau khi bật, pod dùng image đã ký vẫn
  được tạo: `SuccessfulCreate`, không có `FailedCreate`.

**A3.2** **Ý chính:** "Vì chữ ký của tôi chỉ tồn tại dưới dạng OCI referrer. Pipeline ký bằng cosign v3, và cosign v3
lưu chữ ký thành một sigstore bundle gắn vào digest của image; không có tag `sha256-….sig` nào trong repository. Một
verifier chỉ biết tìm tag đó sẽ báo `fail` với mọi image đã ký."

*Nếu được hỏi thêm:* tôi đo điều này trước khi viết policy, bằng `cosign tree` trên digest prod: chỉ có referrer loại
`sigstore.dev/cosign/sign/v1` và `spdx.dev/Document`, và repository không có tag `sha256-*` nào. Guide ban
đầu viết `ClusterPolicy` với `verifyImages`; tôi đổi sau khi đo.

**A3.3** **Ý chính:** "Vì Kyverno 1.19.0 được báo lỗi đúng với trường hợp của tôi, và bản sửa chỉ có từ 1.19.2, nên
cả dòng chart 3.9.x đều bị loại: không verify được
image ký bằng key mà chữ ký chỉ nằm ở dạng bundle referrer (issue kyverno/kyverno#17363, dự kiến sửa ở 1.19.2). Bản
1.18.1 được báo là chạy đúng, nên tôi pin 3.8.2, tức Kyverno 1.18.2, rồi để lần `Audit` chứng minh nó chạy."

*Nếu được hỏi thêm:* tôi không thử 1.19. Lên 1.19 thì chỉ sau khi bản sửa đã ra, và chạy lại bước `Audit`.

**A3.4** **Ý chính:** "Hai glob: `*.dkr.ecr.*.amazonaws.com/medical-rag:*` và `…/medical-rag@*`, tức image của app
theo tag hoặc theo digest trần. Không dùng `medical-rag*`, vì nó khớp cả `medical-rag-ci`, image tools mà pipeline
không ký, và cả pod build lẫn CronJob etcd đều chạy image đó."

*Nếu được hỏi thêm:*

- Hiện hai policy chỉ chọn hai namespace app, nên glob lỏng hôm nay chưa chặn nhầm gì. Nó sẽ chặn nhầm vào ngày phạm vi
  policy được mở rộng; glob chặt giữ cho điều đó không phụ thuộc vào danh sách namespace.
- Glob thứ hai đóng một lối vòng: image tham chiếu bằng digest trần, không có tag, sẽ không khớp glob đầu và lọt qua.
- Thiết kế ban đầu viết pattern lỏng; tôi sửa cả thiết kế.

**A3.5** **Ý chính:** "Vì một policy chặn sai thì không báo lỗi to: nó chặn luôn app ở mọi lần dựng lại sau, kể cả lần
dựng để sửa nó. Lần `Audit` đầu cho thấy đúng điều đó: policy khớp đúng 5 pod, nhưng báo `fail` cả 5, trên image đã ký."

*Nếu được hỏi thêm:*

- Report chỉ ghi message của policy, nên tôi đọc log của admission controller: `failed to build cosign verification
  opts: getting Rekor public keys:  rekor URL must be provided`.
- Nghĩa là Kyverno 1.18.2 đòi `ctlog.url` ngay cả khi đã tắt kiểm transparency log. Thêm `url` vào, lần sau cả ba pod
  web mới đều `pass`.
- Log cũng cho thấy việc lấy chữ ký từ ECR vẫn chạy (dòng `verifying cosign image signature` đứng trước lỗi), nên
  nguyên nhân không phải credential, cũng không phải bug #17363.

**A3.6** **Ý chính:** "Dev chỉ ghi report, nên dev dùng `Ignore`: Kyverno có sập thì pod dev vẫn được tạo. Prod từ
chối thật, nên prod dùng `Fail`: Kyverno sập thì không pod prod nào được tạo, thay vì để một image chưa kiểm lọt vào."

*Nếu được hỏi thêm:* `validationActions` đặt theo từng policy, nên mỗi môi trường một policy; hai policy giống hệt nhau
trừ tên, `namespaceSelector` và `failurePolicy`. "Fail-closed" ở đây là cấu hình: tên webhook trong lỗi có `svc-fail`,
nhưng tôi chưa thử tắt Kyverno để xem prod thật sự từ chối pod.

**A3.7** **Ý chính:** "Ba chỗ. Kyverno ở wave -2, nên nó không lên thì mọi wave sau đứng lại ở mỗi lần dựng. Prod dùng
`Fail`, nên mất cả hai replica admission là không tạo được pod prod. Và tôi chưa đo được admission có gọi ra Sigstore
công khai không; nếu có thì một sự cố ở đó chặn được prod."

*Nếu được hỏi thêm:*

- **Hai replica admission, PDB `minAvailable: 1`:** drain một node không bao giờ lấy cả hai cùng lúc. Chart mặc định
  *tắt* PDB, ngược với điều guide từng viết; tôi bật nó trong values.
- Hai replica nằm trên node-2 và node-3. Values không đặt anti-affinity, nên đó là nhờ mặc định của chart.
- **Lối thoát khẩn cấp** ghi sẵn: tắt auto-sync của `kyverno-policies` rồi xoá policy prod. Sửa tay policy thì không
  giữ được, vì `selfHeal` đặt nó lại ở lần reconcile kế tiếp.

**A3.8** **Ý chính:** "Nó không bắt được một digest sửa tay trỏ vào một image cũ *đã ký*, vì chữ ký chứng minh 'ký
bằng key này', không chứng minh 'là commit mới nhất'. Nó không kiểm image của addon, và không kiểm image của app nếu chạy
ở namespace khác. Và phần Pod Security baseline mà thiết kế cũng đòi thì chưa làm."

*Nếu được hỏi thêm:*

- **Đổi tag giữa lúc kiểm và lúc pull:** Kyverno kiểm chữ ký của digest mà tag trỏ tới lúc admission; nếu ai đó trỏ tag
  sang image khác ngay sau đó, kubelet có thể pull thứ khác. Ở đây values của dev và prod ghi image dạng `tag@digest`,
  nên kubelet pull theo digest; và repository `medical-rag` là `IMMUTABLE_WITH_EXCLUSION`, chỉ tag `sha256-*` và
  `buildcache*` còn ghi đè được, mà values không bao giờ trỏ tới chúng.
- **"Signed pods admitted" chứng minh tới đâu:** sau khi bật `Deny`, ReplicaSet tạo lại pod prod với image đã ký, không
  có `FailedCreate`. Mạnh hơn là lần dựng lại có bấm giờ: policy ở wave 0, app ở wave 1 và 2, nên mọi pod prod của cụm
  mới được tạo *dưới* `Deny`, và cả 17 Application khoẻ. Chưa có lần nào rollout một image mới đã ký trong lúc `Deny`
  đang bật.
- Dev chỉ `Audit`, nên ở dev nó chỉ ghi lại chứ không từ chối. Namespace app đã enforce Pod Security
`restricted` qua nhãn, hai namespace Jenkins có nhãn và một `ValidatingAdmissionPolicy`; đó là lý do phần baseline bị
để lại.

**A3.9** **Ý chính:** "Đo từng lớp một. Lần sync cuối báo thành công, nên cluster đã được apply; vậy phải có cái gì đó
lệch *sau* đó. Tôi liệt kê resource `OutOfSync`: đúng 11 CRD nhóm `policies.kyverno.io`. Tôi loại trừ Job migrate của
chart (log ghi 'nothing to do') và mọi thành phần ghi vào `spec` ngoài Argo CD. Rồi diff một CRD, `imagevalidatingpolicies`,
render từ chart với bản trong cluster: chỉ khác một field `conversion: {strategy: None}`, giá trị mặc định do API server
tự thêm. Mười CRD kia tôi suy ra là cùng nguyên nhân, vì cùng nhóm và cùng hết lệch sau bản sửa."

*Nếu được hỏi thêm:*

- Câu quyết định: `kubectl diff --server-side` với CRD render ra thoát mã 0, tức API server thấy không có gì để đổi.
  Cluster khớp Git; chính phép so phía client của Argo CD đếm giá trị mặc định là thay đổi.
- Sửa bằng `ServerSideDiff=true` trên Application, như `platform-tls` đã dùng. Tôi không dùng `ignoreDifferences`, vì
  nó chỉ giấu triệu chứng, và sẽ giấu cả một thay đổi thật ở `conversion` sau này.
- Hệ quả nếu để nguyên: `kyverno` không bao giờ `Synced`, nên mọi lần dựng lại sau sẽ dừng ở wave -2 mà không có lỗi
  nào được báo.

**A3.10** **Ý chính:** "Deadlock của health gate. Lần sync của `root` bắt đầu từ commit trước, đang đứng chờ `kyverno`
khoẻ; Argo CD không mở lần sync mới khi lần cũ còn chạy; nên commit sửa `kyverno` chỉ được apply sau khi `kyverno` khoẻ,
mà `kyverno` chỉ khoẻ khi commit đó được apply. Chờ bao lâu cũng không hết."

*Nếu được hỏi thêm:*

- Bằng chứng: operation của `root` `Running` từ 01:42:37Z trên commit `41da7f0`, message `waiting for healthy state of
  argoproj.io/Application/kyverno`; annotation mới không có trên object thật.
- Gỡ bằng cách tự đặt annotation lên Application thật, đúng giá trị Git đã có. `kyverno` về `Synced` sau 10 giây,
  operation của `root` kết thúc `Succeeded`. Không lệch khỏi Git nên `selfHeal` không có gì để hoàn tác.
- Bài học chung: sửa một Application mà gate đang chờ thì phải sửa lên object thật, hoặc dừng operation của `root`
  trước. Ở lần dựng lại từ đầu, annotation có sẵn ngay khi Application được tạo, nên chuyện này không lặp lại.

**A3.11** **Ý chính:** "Lệnh đó xoá theo label, nên nó chọn *mọi* pod web của prod, và `kubectl delete pod` không hỏi
PodDisruptionBudget: chỉ eviction mới hỏi. Cả hai pod prod dừng trong cùng một giây, hai lần, và pod thay thế đầu tiên
được tạo 11 giây sau."

*Nếu được hỏi thêm:* tôi không đo xem trong mấy giây đó prod có từ chối request nào không, nên không nói là có hay
không. Từ đó mọi lệnh xoá pod đều xoá từng pod một, theo tên, và guide được sửa.

### A4. Nâng cấp Kubernetes (#14)

**A4.1** **Ý chính:** "Chưa. `apt-cache madison kubeadm` trên node chỉ có từ 1.36.0 tới 1.36.4, tức bản đang chạy đã
là bản mới nhất. Lên 1.37 thì chart Rancher 2.15.1 chặn (`kubeVersion: < 1.37.0-0`), phải nâng Rancher trước. Nên tôi
viết playbook, kiểm cú pháp, và ghi tiêu chí là không đo được."

**A4.2** **Ý chính:** "Bốn play. Play đầu kiểm tra trước khi đụng vào node nào. Play hai nâng kubeadm rồi chạy
`kubeadm upgrade apply` ở node 1. Play ba thay kubelet ở node 1. Play bốn làm hai node còn lại, từng node một."

*Nếu được hỏi thêm:*

- Play kiểm tra: bản đích phải là patch của cùng minor, ba node đều Ready, và đếm số Application để các vòng chờ sau
  biết phải chờ đủ bao nhiêu.
- Tách node 1 ra vì thứ tự của inventory không bảo đảm node 1 đi trước, mà chỉ node 1 chạy `upgrade apply`.
- Đã qua `--syntax-check`; `--list-hosts` cho ba play đầu chỉ có node 1, play bốn có node 2 và 3 (B5.1, B5.2).

**A4.3** **Ý chính:** "Vì role cài package cài bản pin với `allow_change_held_packages`. Đổi pin rồi chạy lại
`make cluster` sẽ cài kubelet mới lên cả ba node cùng lúc, dpkg tự restart nó, trong khi các static pod của control
plane vẫn chạy binary cũ. Kết quả là kubelet mới hơn API server, và file cấu hình thì báo là đã nâng. Chỉ
`kubeadm upgrade` mới nâng control plane."

**A4.4** **Ý chính:** "Đề xuất của tôi, chưa nằm trong guide: dựng cluster ở 1.36.3, rồi chạy playbook lên 1.36.4, trong lúc một vòng `curl` bắn vào prod và
đếm cả request lỗi lẫn tổng số request. Nó chứng minh đường *patch*: drain tôn trọng PDB, từng node một, không mất
dịch vụ. Nó không chứng minh nâng minor: đổi repository apt, API bị gỡ, tương thích addon, và nâng Rancher trước."

*Nếu được hỏi thêm:*

- Vòng `curl` nên nghỉ 3 giây giữa các lần, để dưới rate limit 30 request mỗi phút của Ingress; vì vậy sự cố ngắn hơn
  3 giây có thể lọt, và phải ghi điều đó cạnh con số.
- Muốn nói API cũng không gián đoạn thì cần thêm một vòng thứ hai gọi `/readyz` của API.

> **Mẹo:** không bao giờ nói "nâng cấp không downtime" mà thiếu chữ "patch".

### A5. Các phép đo cho CV

**A5.1** **Ý chính:** "Một script chạy một lần, không ai gõ gì: từ cluster stack trống, với stack `shared` giữ nguyên,
tới 17 Application `Synced Healthy` và không app nào đang giữa một lần sync. Đồng hồ tường ra 21 phút 47 giây. Con số
14 phút 11 giây cũ không so được: lần đó chỉ có 9 Application, và vòng chờ chỉ đọc health nên có thể dừng sớm."

*Nếu được hỏi thêm:*

| Pha | Thời gian |
|---|---|
| Terraform (86 resource, chỉ create) | 3 m 46 s |
| SSM đăng ký | 7 s, không phải reboot |
| `make cluster` | 6 m 17 s, 1 lần chạy |
| Tunnel và bootstrap | 57 s |
| Các wave của Argo CD | 10 m 40 s |

Sau đó: một phút sau vẫn 17/17 khoẻ, 0 CertificateRequest, `oidc-check` hai dòng `same`. Không có prompt `yes` nào
trong con số; polling có thể cộng thêm tối đa khoảng 35 giây.

**A5.2** **Ý chính:** "Những việc một người tự làm bằng mắt: kiểm plan trước khi gõ `yes`, ping lại khi một node chưa
lên, biết khi nào không được chạy lại một lệnh, và biết lúc nào thật sự xong. Script làm từng việc đó một cách tường
minh, và kết thúc bằng một phán quyết PASS hoặc FAIL chứ không chỉ in số."

*Nếu được hỏi thêm:*

- Chỉ apply khi plan là `0 to change, 0 to destroy`, và apply đúng file plan đó.
- Agent SSM đăng ký chậm thì chờ; sau 5 phút mà SSM *không có bản ghi nào* của node thì reboot nó một lần, đúng cách
  đã chữa ở phase Ansible. Lỗi gọi API không bao giờ bị hiểu thành "không có bản ghi". Lần chạy M3 không cần tới
  nhánh reboot, nên nhánh đó chưa được thử.
- `make cluster` chỉ được chạy lại tối đa một lần, khi log có `TargetNotConnected` **và** lần hỏng chưa chạm tới task
  kubeadm nào, vì role init coi `admin.conf` là dấu "đã xong" mà kubeadm lại ghi file đó từ sớm.
- Khi fail, nó in đang ở pha nào và phải dọn bằng lệnh gì (B6.3).

**A5.3** **Ý chính:** "Cổng Trivy chưa bao giờ đỏ, vì mọi CRITICAL trong image đều không có bản vá. Positive control là
làm cho nó *phải* đỏ: trên một branch tạm, tôi nới cổng ra đếm finding có bản vá ở mọi mức. Report của build main có 6
finding như vậy, và build branch đỏ với `Fixable, any severity: 6`. Nó chứng minh cơ chế chặn chạy; nó không chứng minh
cổng từng bắt được một CRITICAL."

*Nếu được hỏi thêm:* 6 gồm 5 MEDIUM và 1 LOW, đều trong `pip`; tôi đếm trước khi push nên biết trước build phải đỏ. Chi
tiết: `Jenkins A5.2`.

**A5.4** **Ý chính:** "Vì tôi chưa sửa `Jenkinsfile`. `git commit` không có gì để commit, lệnh push đẩy lên đúng commit
docs của `main`, và skip guard kết thúc build đó `NOT_BUILT` với lý do chỉ có file docs thay đổi. Build đó không thử gì
cả. Bây giờ bước đó kiểm `git diff --stat` trước khi commit."

*Nếu được hỏi thêm:* tên branch cũng phải khớp `jenkins/step-*`, vì Jenkins chỉ phát hiện `main` và mẫu đó; một review
bắt được điều này trước khi chạy.

### A6. Sự cố và bài học

**A6.1** **Ý chính:** "Hai lần pass sai và một lần tôi chặn được trước, cả ba cùng một hình dạng: đọc một thứ trông
giống 'xong' hay 'an toàn' nhưng không phải vậy."

*Nếu được hỏi thêm:*

1. **Lệnh chờ `root` Healthy** trả về sau 1 phút 18 giây, khi mới có 6 trong 14 Application, vì `root` đọc `Healthy`
   trong lúc các wave vẫn chạy. Sửa: chờ `Synced` trước rồi mới `Healthy`. Hệ quả: thời gian dựng lại lần đó không đo
   được, và tôi ghi như vậy.
2. **"Xoá một pod"** xoá cả hai pod prod (A3.11).
3. **Status cũ sau khi khôi phục** (A2.7). Cái này tôi chặn trước khi nó xảy ra, nhờ nghĩ trước khi đo.

**A6.2** **Ý chính:** "Deadlock của health gate (A3.10). Nó không báo lỗi gì, và cách sửa hiển nhiên là commit thêm thì
vô dụng. Tôi chỉ gỡ được khi đọc `operationState` của `root` và thấy nó đang chạy trên một commit cũ."

*Nếu được hỏi thêm:* nó cũng cho thấy giá của health gate. Gate đó được viết để các wave chờ nhau thật, sau lần tốn một
certificate Let's Encrypt ở phase GitOps. Nó làm đúng việc, và chính vì làm đúng mà nó có thể chờ mãi một thứ không bao
giờ tới.

### A7. Nhìn lại

**A7.1** **Ý chính:** "Năm thứ: nâng cấp chưa chạy; khôi phục lên một cluster dựng lại chưa thử; admission có phụ
thuộc Sigstore công khai không chưa đo; một job do chính lịch 6 giờ tạo ra chưa quan sát; và chưa có commit nào chạy hết
pipeline trên một cluster vừa dựng lại."

**A7.2** **Ý chính:** "Ba thứ. Backup có role riêng chỉ ghi được, versioning và Object Lock, và bản sao sang region
khác. Kyverno kiểm cả image addon, cộng policy Pod Security baseline. Và drill chạy định kỳ theo lịch, có cảnh báo khi
fail, chứ không phải một lần cho CV."

*Nếu được hỏi thêm:* ở quy mô công ty tôi cũng sẽ đo RTO của một lần khôi phục không có guide, do người trực chưa từng
làm, vì đó mới là con số của một sự cố thật.

---

## Phần B — Chi tiết

### B1. CronJob snapshot

**B1.1** `schedule: "0 */6 * * *"` với `timeZone: Etc/UTC` ghi thẳng ra, không thừa hưởng từ controller manager: chạy
lúc 00, 06, 12, 18 UTC. `concurrencyPolicy: Forbid`: hai snapshot cùng lúc chỉ tăng tải cho etcd.
`startingDeadlineSeconds: 600`: một lần bị lỡ quá 10 phút thì bỏ qua, không chạy muộn. Giữ 3 job thành công và 3 job
lỗi, để một lần lỗi còn đọc được sáng hôm sau.

*Ở đâu:* `deploy/argocd/manifests/etcd-backup/cronjob.yaml`.

**B1.2** etcd nghe client ở `127.0.0.1:2379`, địa chỉ chỉ tới được từ network namespace của node, nên cần
`hostNetwork`. Ba file `hostPath` chỉ đọc: `ca.crt`, `healthcheck-client.crt`, `healthcheck-client.key`. Không mount
cả `/etc/kubernetes/pki/etcd`, vì thư mục đó chứa `ca.key`, `server.key` và `peer.key`; một pod cầm `ca.key` tự cấp được
mọi danh tính etcd. Namespace có nhãn Pod Security `privileged`, vì `baseline` từ chối cả `hostNetwork` lẫn `hostPath`.

**B1.3** Đọc từ `imageID` của các pod etcd đang chạy, cùng một digest trên cả ba node:
`registry.k8s.io/etcd:3.6.8-0@sha256:3971…22e5`. Nhờ vậy công cụ khớp đúng phiên bản server. Image upload là image tools
của pipeline, pin theo digest như trong `Jenkinsfile`.

**B1.4** `etcdctl` ghi snapshot với quyền `0600` của root, nên user `ci` của image tools không đọc được; container upload
chạy `runAsUser: 0`. `emptyDir` có `sizeLimit: 2Gi` để một file chạy loạn không lấp đầy ổ của node; lần đầu thật là
62 MB.

### B2. Lệnh khôi phục

**B2.1**

| Phase | Việc | Điều kiện đi tiếp |
|---|---|---|
| 0 | Tải snapshot về workstation, copy lên cả ba node (trước t1, ngoài RTO) | Cả ba `CHANGED`, cùng checksum |
| 1 | Dời bốn manifest static pod ra `/root/`, chờ `crictl` không còn thấy etcd, API server, controller manager, scheduler | Cả ba `CHANGED`; `crictl` lỗi kết nối là lỗi, không phải "đã dừng" |
| 2 | `mv /var/lib/etcd /var/lib/etcd.old` | Cả ba `CHANGED` |
| 3 | `etcdutl snapshot restore` trên từng node | Cả ba `CHANGED`, cùng cluster-id |
| 4 | Trả bốn manifest về | Cả ba `CHANGED` |
| 5 | Mở lại tunnel | API trả lời |

Controller manager và scheduler cũng dừng, vì chúng giữ cache của sau lúc chụp.

**B2.2** Chạy từ chính image etcd đã có trên node, qua containerd:
`ctr -n k8s.io run --rm --mount type=bind,src=/var/lib,…,options=rbind:rw --mount …/tmp/snap.db… registry.k8s.io/etcd:3.6.8-0 restore-<node> /usr/local/bin/etcdutl snapshot restore …`.
Pre-check xác nhận tag đó có trong namespace `k8s.io` của containerd.

**B2.3** `--name` là `inventory_hostname`, vì role `common` đặt hostname của máy theo đúng tên đó và kubeadm lấy hostname
làm tên member. Peer URL là `https://<IP private>:2380`, IP lấy từ `private_ip_address` của inventory động.
`--initial-cluster` liệt kê cả ba từ `groups['nodes']`. Token (`medical-rag-restore`) và `--data-dir /var/lib/etcd`
giống nhau trên cả ba. Pre-check in giá trị trong manifest cạnh giá trị restore sẽ dùng, trên từng node, trước khi dừng
bất cứ thứ gì.

**B2.4** Trên cả ba node: `rm -rf /var/lib/etcd && mv /var/lib/etcd.old /var/lib/etcd`, rồi trả manifest về (phase 4).
Cluster quay về trạng thái lúc t1, trừ namespace đã xoá. Phase 2 kiểm `test ! -e /var/lib/etcd.old` trước khi dời, để
chạy lại không lồng thư mục cũ vào trong nó.

### B3. Cài Kyverno

**B3.1** `admissionController.replicas: 2` với `podDisruptionBudget: {enabled: true, minAvailable: 1}`; ba controller
còn lại mỗi cái một replica. Chart mặc định tắt PDB. Không có PDB thì drain có thể lấy cả hai replica cùng lúc; một
replica mà có PDB thì drain treo mãi.

*Ở đâu:* `deploy/argocd/values/kyverno.yaml`.

**B3.2** `ServerSideApply` vì CRD của Kyverno lớn hơn giới hạn annotation của client-side apply, giống
`kube-prometheus-stack`; lý do này theo comment trong chart và tài liệu, tôi không đo. Application của policy dùng
`ServerSideApply` để khớp với `ServerSideDiff`: diff phía server là mô phỏng một lần server-side apply.
`ServerSideDiff` vì 11 CRD `policies.kyverno.io` có giá trị mặc định do API server thêm vào, và diff phía client coi đó là
lệch (A3.9). Application của policy cũng có nó, như một biện pháp phòng ngừa: object của nó cũng có giá trị mặc định,
dù chỉ phần CRD là đã được đo. Cả hai có nhãn `medical-rag/report-failed-sync`, để một lần sync lỗi hiện thành
`Degraded` chứ không kẹt `Progressing`.

**B3.3** Trên một cluster đang chạy, `root` đã qua wave 0, nên cả hai Application mới sẽ sync cùng lúc, và Application
policy sẽ lỗi `no matches for kind "ImageValidatingPolicy"` vì CRD chưa có. Automated sync của Argo CD mặc định không
thử lại một revision đã lỗi. Đây là biện pháp phòng ngừa; lần chạy dùng hai commit nên chưa từng thử một commit. Ở lần
dựng lại từ đầu thì các wave tự xếp thứ tự.

### B4. Policy

**B4.1**

| Trường | Giá trị ở prod | Tác dụng |
|---|---|---|
| `validationActions` | `[Deny]` | Từ chối; dev là `[Audit]` |
| `failurePolicy` | `Fail` | Kyverno sập thì không tạo pod (A3.6) |
| `matchConstraints` | Pod, `CREATE` và `UPDATE`, `namespaceSelector` theo tên namespace | Chỉ namespace prod |
| `matchImageReferences` | Hai glob (A3.4) | Chỉ image của app |
| `credentials.providers` | `[amazon]` | Lấy chữ ký từ ECR bằng role của node; ghi rõ, không dựa vào mặc định |
| `validationConfigurations` | `mutateDigest: false`, `verifyDigest: false`, `required: true` | Không sửa pod; lỗi phải là về chữ ký, không phải về digest |
| `attestors[].cosign.key.data` | Public key cosign | Giống từng byte với `cosign.pub` trong Git |
| `ctlog` | `url` Rekor, `insecureIgnoreTlog`, `insecureIgnoreSCT` | Không có log nào để tra; `url` vẫn bắt buộc (A3.5) |
| `webhookConfiguration.timeoutSeconds` | 15 | Mỗi lần admission lấy chữ ký từ ECR |

*Ở đâu:* `deploy/argocd/manifests/kyverno-policies/verify-images.yaml`.

**B4.2** `images.containers` và `images.initContainers`, mỗi image phải có ít nhất một chữ ký hợp lệ. Mọi container của
pod app dùng cùng một image: container web, initContainer `index-pull`, và Job build index. Phần `initContainers` có
`has(...)` bảo vệ, để pod không có initContainer không làm biểu thức lỗi.

**B4.3** Trong `PolicyReport` ở namespace của pod, mỗi pod một dòng `pass` hoặc `fail`, sau một lần admission; lọc theo
tên pod web để bỏ các dòng cũ của Job đã xong. Report không có dòng nào nghĩa là pattern không khớp gì, mà một policy
không khớp gì thì cũng không chặn gì, và trông giống hệt một policy cho qua mọi thứ.

### B5. `upgrade.yml`

**B5.1**

1. `first_node`: kiểm tra — bản đích là patch của `kubernetes_minor` và khớp `kubernetes_apt_version`; ba node Ready;
   đếm Application.
2. `first_node`: nâng riêng `kubeadm` (giữ hold), `kubeadm upgrade plan`, `kubeadm upgrade apply -y`.
3. `first_node`: file task chung (B5.2).
4. `other_nodes`, `serial: 1`: nâng `kubeadm`, `kubeadm upgrade node`, rồi file task chung.

*Ở đâu:* `infra/ansible/upgrade.yml`, `infra/ansible/tasks/upgrade-kubelet.yml`.

**B5.2** Drain với `--timeout=10m`, để drain bị PDB chặn thì play lỗi chứ không treo. Nâng kubelet và kubectl, giữ hold,
restart kubelet. Chờ node `Ready` **trên đúng phiên bản mới**. Uncordon. Chờ các pod control plane của node đó Ready.
Rồi chờ mọi Application `Synced` và `Healthy` **và** số Application bằng con số đếm ở play 1: một danh sách rỗng cũng
không in dòng lỗi nào.

### B6. `timed-rebuild.sh`

**B6.1** Trước khi tính giờ: `make init`; `terraform state list` của stack cluster phải chạy được và rỗng; tắt tunnel
cũ, cả tiến trình `session-manager-plugin` giữ cổng, rồi kiểm cổng 6443 đã trống. Trước khi apply: `terraform plan -out`
thoát mã 0 và dòng `Plan:` có `0 to change, 0 to destroy`; apply đúng file plan đó rồi xoá nó.

*Ở đâu:* `infra/scripts/timed-rebuild.sh`.

**B6.2** Terraform → chờ SSM → `make cluster` (PLAY RECAP phải `failed=0` cho đủ ba node) → tunnel chạy nền trong
process group riêng, chờ `/readyz` → `make bootstrap` → chờ Application. Đồng hồ dừng khi có ít nhất 17 Application,
tất cả `Synced` và `Healthy`, và không cái nào có `operationState.phase` đang `Running`: hook như Job build index không
được tính vào health, nên thiếu điều kiện đó thì một app có thể đọc `Healthy` trong lúc hook còn chạy. Mọi lệnh
kubectl có timeout, và mỗi vòng chờ kiểm tunnel còn sống.

**B6.3** PASS khi: một phút sau vẫn đủ 17 Application và không cái nào lệch; 0 CertificateRequest, đọc từ một lệnh
kubectl chạy thành công; đúng hai dòng `same` từ `oidc-check`; ba node `Ready`. Khi fail, script in pha đang chạy, lý do,
đường dẫn log, và lệnh dọn: fail trước khi apply thì không có gì được tạo; fail trước khi có Argo CD thì
`make infra-destroy`, vì `make down` sẽ lỗi ở bước xoá Application; sau đó thì `make down`. Nếu tunnel đang chạy, nó in
thêm `kill -- -<PID>` để tắt cả process group.

---

[Câu hỏi](questions.md) · [README](README.md) · [Concepts](concepts.md) · [Guide](guide.md) ·
[Evidence](../evidence/drills.md)
