# Đáp án Jenkins

Đáp án cho [`questions.md`](questions.md), cùng số thứ tự. Phần A mở đầu bằng **Ý chính**: câu nói thành tiếng,
ngôi thứ nhất, thường là đủ. *Nếu được hỏi thêm* dùng khi người phỏng vấn đào sâu; tham chiếu như `(B1.4)` là để
bạn tra, không đọc ra. Dòng **Mẹo** là lời nhắc cho bạn, không nói ra. Đường dẫn tính từ gốc repo, trừ khi ghi
khác. Tham chiếu dạng `Common A2.3` trỏ tới [`../common/answers.md`](../common/answers.md), tương tự với
`GitOps`, `App`, `Terraform`, `AWS`.

Chỗ `[điền: …]` là số liệu phải lấy từ lần chạy thật trước khi dùng; đừng nói con số bạn chưa đo. Ghi chú
**[kiểm chứng]** là hành vi của công cụ cần xác nhận trước khi nói chắc. Số thập phân viết bằng dấu chấm, như
các bộ khác.

**Số liệu đã có** ([`../evidence/jenkins.md`](../evidence/jenkins.md)):

- Commit tới pod dev chạy bản mới: **19 m 08 s** — 14 m 20 s trong pipeline, 4 m 48 s qua Argo CD.
- Build trên nhánh: **1 m 32 s**, đo ở bước 15, khi pipeline còn ít stage hơn hôm nay.
- Trivy trên image prod: **5 CRITICAL / 55 HIGH** trước, **0 CRITICAL / 44 HIGH** sau khi đổi base sang Debian 13;
  tổng phát hiện 269 → 158.
- CPU ba node **chưa hứa cho pod nào**, trước phase: **560m / 775m / 720m** — là request, không phải mức dùng
  thật; cluster không có metrics-server. Controller xin 250m, build pod xin 500m.
- Mười tag cùng trỏ vào một digest `sha256:f5b6789a…`.
- Skip guard đọc được **0 byte** tên file trên một merge commit.
- 23 khiếm khuyết được ghi lại, tất cả trừ một nằm ở guide; 15 thuộc năm dạng.

**Cần điền hoặc xác nhận:**

- Chi phí riêng của phase (A7.6) — EBS của Jenkins, lưu trữ ECR, giờ CPU của build pod.
- Số build của lần `NullPointerException` (A8.1) — log đã bị xoay mất nên không truy lại được.
- Lifecycle policy giữ được image `release-*` hay không — chưa đủ 30 image có tag để preview chứng minh (B4.6).
- Cổng chặn *đúng* một CRITICAL có bản sửa — chưa từng xảy ra. Cơ chế chặn thì đã được chứng minh bằng positive
  control ở phase drills (A5.2).

**Nếu bạn sửa code trước khi nộp CV, sửa cả đáp án:** các đáp án dưới đây mô tả đúng code hiện tại, kể cả điểm
yếu đã biết.

| Điểm yếu trong code | Câu liên quan |
|---|---|
| Kyverno chỉ chặn ở prod (dev chỉ ghi `Audit`); image addon không được kiểm | A5.6 |
| Chữ ký chứng minh key, không chứng minh pipeline: digest cũ đã ký vẫn qua | A5.6, A9.2 |
| Cổng chưa từng bắt được một CRITICAL thật; chỉ positive control làm nó đỏ | A5.2, B5.1 |
| Token của bot push thẳng được lên `main`, kể cả values prod | A6.6, A9.2, A9.3 |
| Chưa có commit nào chạy hết pipeline trên một cụm vừa dựng lại | A1.5, A9.2, B6.4 |
| Trivy tải lại 114.8 MiB database mỗi build | A7.4 |
| Namespace build pod ở mức Pod Security `privileged` | A4.3, B3.2 |

---

## Phần A — Phỏng vấn

### A1. Tổng quan

**A1.1** **Ý chính:** "Phase này dựng một pipeline CI chạy bên trong chính cluster tôi tự quản: một commit lên
`main` được test, build bằng BuildKit rootless, quét bằng Trivy, ký bằng key KMS, rồi bot ghi digest vào values
của dev và mở pull request cho prod. Argo CD vẫn là thứ duy nhất chạm vào cluster — Jenkins không cầm credential
nào của cluster cả. Điểm tôi quan tâm nhất không phải là nó chạy được, mà là build pod có danh tính AWS riêng:
quyền push ECR và quyền ký KMS giờ chỉ còn ở vai trò CI, tôi đã gỡ hẳn hai quyền đó khỏi vai trò của node. Đo
được 19 phút từ commit tới pod dev chạy bản mới. Và sự cố tốn nhất là một bộ plugin lệch phiên bản: nó nạp
không báo lỗi gì, rồi build sau chết với `NullPointerException`."

*Nếu được hỏi thêm:*

- Một release đi thế nào: A1.2. Số đo và chỗ yếu của nó: A1.4.
- Ba sự cố đáng kể: A8.1, A8.2, A8.3.

**Mẹo:** kết bằng một con số và một sự cố — đó là hai chỗ người phỏng vấn hỏi tiếp.

**A1.2** **Ý chính:** "Tôi push lên `main`. Jenkins poll thấy sau tối đa 2 phút, dựng một build pod, chạy test
trong BuildKit khi chưa có credential nào, rồi mới đăng nhập ECR, build và push image theo git SHA. Trivy quét
một lần ra báo cáo, cổng chặn đếm báo cáo đó. Trên `main` thì cosign ký digest và gắn SBOM. Sau đó bot ghi
`tag@digest` vào values dev và mở pull request sửa values prod. Argo CD thấy Git đổi, cập nhật dev. Tôi duyệt và
merge PR thì prod đổi theo."

*Nếu được hỏi thêm:* commit merge đó chỉ đụng `deploy/`, nên skip guard dừng build ngay sau khi stage đầu gắn
tag `release-` cho digest prod vừa nhận (A6.3).

**A1.3** **Ý chính:** "Trước phase này, dev và prod đã chạy bằng Helm chart qua Argo CD, nhưng image thì tôi build
bằng tay bằng `make image` và tự sửa file values. Nghĩa là không có gì bảo đảm thứ chạy trên prod đã được quét
hay được ai duyệt. Phase này thay đoạn thủ công đó."

*Nếu được hỏi thêm:* prod trước đó chạy image `c10cd57e…` do tôi đặt tay từ phase app; tới bước 17 mới đổi sang
digest mà cả chuỗi pipeline đồng ý.

**A1.4** **Ý chính:** "19 phút 8 giây từ commit tới pod dev Ready, đo **một lần**: 14 phút 20 trong pipeline, 4
phút 48 qua Argo CD. Nửa sau tôi có nhúng tay vào nên nó không phải con số của một release tự chạy."

*Nếu được hỏi thêm:*

- **Nửa sau có nhúng tay:** tôi annotate `refresh=normal` bằng tay trong lúc chờ, rất có thể chính nó kích hoạt
  sync. Nên 4 m 48 s không phải số một release nhận khi không ai ngồi canh.
- **Nửa đầu chưa tách được:** 14 m 20 s so với 1 m 32 s của một build nhánh. Ba stage chỉ chạy trên `main`, và
  `containerCap: 1` nghĩa là build có thể xếp hàng sau build khác. Bao nhiêu trong 14 phút là *chờ* chứ không
  phải *chạy* thì tôi chưa tách; Stage View tách được nhưng tôi không chụp lại.

**Mẹo:** đưa con số trước, rào sau. Một ứng viên đưa số mà không biết số đó yếu ở đâu thì dễ bị bắt bài.

**A1.5** **Ý chính:** "Ba thứ tôi chứng minh được trên cluster thật. Một commit đi tới pod dev mà tôi không gõ
lệnh nào trong pipeline. Image prod đã quét, đã ký, và `cosign verify` nhận. Và vai trò của node không còn quyền
push ECR hay ký KMS — cái này tôi đo bằng simulator rồi kiểm lại bằng một pod thật ở namespace khác. Sau phase này,
hai thứ trước đây là giả định đã có bằng chứng: cổng làm build đỏ được (một build positive control), và hai
Application `jenkins-platform`, `jenkins` về `Synced Healthy` sau một lần dựng lại cả cụm. Còn lại là giả định: lifecycle giữ được image prod, và một commit chạy hết
pipeline trên cụm vừa dựng lại."

*Nếu được hỏi thêm:* bảng "chứng minh được / mới là giả định" nằm ở `docs/jenkins/README.md` §14.

### A2. Vì sao Jenkins, và vì sao đặt trong cluster

**A2.1** **Ý chính:** "CI tạo ra một image đáng tin; CD đưa trạng thái mô tả trong Git vào cluster. Tách ra thì
Jenkins không cần credential nào của cluster, và Git là nơi duy nhất nói cái gì nên chạy. Jenkins chỉ sửa file
values rồi commit."

*Nếu được hỏi thêm:*

| | Push: Jenkins `kubectl apply` | Pull: Argo CD |
|---|---|---|
| Credential cluster | Jenkins phải giữ credential mạnh | Argo CD chạy trong cluster, không ai bên ngoài cần |
| Ai đó sửa tay trên cluster | Không ai biết | Argo CD báo `OutOfSync`; `selfHeal` bật ở cả dev lẫn prod nên nó tự kéo về đúng Git |
| Jenkins sập | Không deploy được | Thứ đang chạy không bị ảnh hưởng |

Git là trạng thái *mong muốn*; muốn biết trạng thái *thật* vẫn phải xem Argo CD hoặc cluster.

**A2.2** **Ý chính:** "Vì project này là bài tập tự quản lý hạ tầng, nên tôi muốn tự vận hành luôn cả hệ CI, kể cả
phần khó: controller trong cluster, agent là pod tạm, danh tính AWS không dùng access key. Project EKS của tôi
dùng GitHub Actions, nên hai project cho thấy hai cách. Ở công ty, nếu code đã nằm trên GitHub thì GitHub Actions
với OIDC tới AWS đơn giản hơn nhiều."

*Nếu được hỏi thêm:* cái Jenkins bắt tôi phải tự làm — và vì thế tôi học được — là vòng đời agent, ghim plugin,
và cấu hình bằng JCasC. Ba thứ đó ở GitHub Actions thì nhà cung cấp lo hộ.

**A2.3** **Ý chính:** "Được: không phải trả tiền runner, agent dùng chung network và IAM của cluster, và tôi chứng
minh được một pod trong cluster có thể có danh tính AWS riêng. Mất: pipeline ăn vào đúng phần CPU mà app đang
dùng, và nếu cluster hỏng thì tôi mất luôn công cụ để sửa nó."

*Nếu được hỏi thêm:* vì CPU chật nên `containerCap: 1`, chỉ một build pod tại một thời điểm, và build pod chỉ
lên được hai trong ba node (A7.1).

**A2.4** **Ý chính:** "Vì Jenkins chỉ mở qua WireGuard, nên GitHub không gọi vào được. Poll là cách duy nhất còn
lại. Giá phải trả là độ trễ tới 2 phút, nằm trong chặng 14 phút 20 giây."

*Nếu được hỏi thêm:* cách sửa nếu cần là một relay nhận webhook ở ngoài rồi gọi vào qua VPN, hoặc GitHub App.
Cả hai đều thêm một thành phần phải vận hành, nên với một người dùng thì poll đáng giá hơn.

**A2.5** **Ý chính:** "Vì một Argo CD Application chỉ render được một loại nguồn. Chart Jenkins là chart từ xa,
còn namespace, RBAC, NetworkPolicy, admission policy và credential là manifest trong repo này — hai loại khác
nhau nên phải hai Application. Được thêm một cái nữa: gỡ cài lại chart không làm mất credential và admission policy,
vì chỉ Application của chart sở hữu volume."

*Nếu được hỏi thêm:* `jenkins-platform` ở wave 3, `jenkins` ở wave 4, vì chart mount secret và ServiceAccount do
wave 3 tạo.

### A3. Danh tính và quyền của build pod

**A3.1** **Ý chính:** "Pod được gắn một projected ServiceAccount token, audience `sts.amazonaws.com`, hạn một giờ.
Container `tools` đưa token đó cho STS qua `AssumeRoleWithWebIdentity`. STS kiểm chữ ký token bằng bộ khoá công
khai mà tôi tự host trên S3 — chính là issuer OIDC dựng từ phase app. Khớp thì STS trả credential tạm của vai trò
`medical-rag-ci`. Không có access key nào ở đâu cả."

*Nếu được hỏi thêm:*

- Trust policy tin đúng một chủ thể: `system:serviceaccount:jenkins-agents:jenkins-agent` (B4.1).
- Đúng cơ chế mà pod app dùng, chỉ khác vai trò — `App A2`.
- `automountServiceAccountToken: false` ở cấp pod, token được mount thủ công và chỉ vào `tools` (B1.6).

**A3.2** **Ý chính:** "Được: push và pull trên repository `medical-rag`, xin KMS ký bằng đúng một key, đọc
object dưới `corpus/`, cộng `ecr:GetAuthorizationToken` trên `*` vì AWS không scope action đó theo repository
được. Hết. Cố ý không được: đọc secret nào, ghi vào bucket artifacts, đụng `etcd-backups`. Token
GitHub tới Jenkins qua External Secrets chứ không qua vai trò này."

*Nếu được hỏi thêm:*

- Quyền đọc `corpus/` là để stage so checksum corpus với PDF trong Git, không phải để build.
- Image `medical-rag-ci` chứa container `tools` do **kubelet** kéo bằng vai trò node, không phải vai trò này —
  nên vai trò CI không cần quyền đọc repository đó.
- Nói thẳng: tôi chạy simulator cho chiều *vai trò node bị từ chối*, chưa chạy cho chiều *vai trò CI không đọc
  được secret*. Cái sau tôi suy ra từ policy chứ chưa đo.

**A3.3** **Ý chính:** "Chỉ `tools`. Bốn container là `jnlp` nói chuyện với controller, `buildkit` chạy test rồi
build, `trivy` quét và sinh SBOM, `tools` làm phần còn lại. Token chỉ mount vào `tools`, nên một bài test chạy
trong `buildkit` không ký được gì."

*Nếu được hỏi thêm:* `buildkit` vẫn cần đăng nhập ECR để push, nên `tools` ghi `config.json` vào workspace dùng
chung — đó là giới hạn thật: login đi qua ranh giới container, còn token thì không.

**A3.4** **Ý chính:** "Vì test là code của repo — ai push được code thì quyết định được test chạy cái gì. Nên tôi
xếp test chạy trước, lúc trong pod chưa có đăng nhập ECR nào cả; đăng nhập là việc ngay sau đó. Nói cho chính xác
thì stage đầu tiên có gọi AWS, nhưng nó chỉ chạy trên commit merge prod, mà commit đó thì skip guard đã dừng từ
trước khi tới test."

*Nếu được hỏi thêm:* giới hạn thật nằm ở chỗ khác — các bước `RUN` trong Dockerfile cũng là code của repo, và
chúng chạy **sau** khi đăng nhập, trong cùng một worker không có process sandbox, với `config.json` nằm trong
workspace dùng chung. Tôi chưa có gì chặn một `RUN` đọc file đó.

**A3.5** **Ý chính:** "Ba phép đo. `simulate-principal-policy` trên vai trò node trả `ecr:PutImage implicitDeny`
và `kms:Sign implicitDeny`, còn ba quyền đọc vẫn `allowed` — kể cả một quyền trên repository thứ hai mà guide
không bảo tôi thử (A8.7). Rồi tôi chạy một pod ở namespace `default` — nơi
không chặn IMDS — nó thật sự mượn được vai trò node rồi bị KMS từ chối. Cuối cùng build tiếp theo trên `main` vẫn
xanh, nghĩa là đường qua vai trò CI còn nguyên."

*Nếu được hỏi thêm:* tôi nói rõ điều build đó **không** chứng minh: NetworkPolicy đã chặn IMDS từ bước 6, nên
build không thể đỏ *vì* bước 18. Cái bước 18 đổi là mọi pod *khác* trong cluster — và đó đúng là thứ phép kiểm tra ở
`default` đo được.

**Mẹo:** câu "điều này không chứng minh gì" thường ghi điểm hơn cả phép đo.

**A3.6** **Ý chính:** "Thì mọi pod trong hai namespace Jenkins lại với tới được vai trò node qua metadata service.
Trước bước 18 thì đó là push ECR và ký KMS; sau bước 18 thì vẫn còn đọc 8 secret và ghi bản sao lưu chứng chỉ.
Hop limit để 2 nên IMDS *đến được*; thứ chặn thật là NetworkPolicy, không phải IMDSv2."

*Nếu được hỏi thêm:* tôi đo bằng `curl` từ trong container: IMDS timeout, `exit=28`. Các namespace nền tảng
(`argocd`, `cert-manager`, `external-secrets`, `monitoring`) **không** có NetworkPolicy, nên ở đó pod vẫn với tới
vai trò node — đó là giới hạn còn lại, ghi trong `GitOps` §12.

### A4. Build image không cần root

**A4.1** **Ý chính:** "BuildKit ở chế độ rootless, trong một container của build pod, không có daemon và không có
root trên host. Nó build trong user namespace của chính nó."

**A4.2** **Ý chính:** "Mount socket của node thì ai điều khiển daemon đó coi như có root trên node — một bài test
độc hại là đủ. Docker-in-Docker cần container privileged, tức là vẫn đúng quyền ấy, chỉ gọi tên khác. Kaniko từng là
câu trả lời quen thuộc nhưng đã bị archive upstream, tôi không muốn đặt supply chain lên một dự án không còn ai
bảo trì."

*Nếu được hỏi thêm:* tôi không tin BuildKit rootless chạy được trên Ubuntu 24.04 chỉ vì tài liệu nói thế —
`apparmor_restrict_unprivileged_userns=1` là mặc định. Bước 1 chạy thử chính ví dụ của BuildKit trên node thật
trước khi xây bất cứ thứ gì lên trên. Nó chạy, nên không node nào bị sửa.

**A4.3** **Ý chính:** "Nó cần seccomp và AppArmor `Unconfined`, mà mức Pod Security `baseline` thì từ chối. Nên
namespace `jenkins-agents` phải ở mức `privileged`. Tôi bù lại bằng một ValidatingAdmissionPolicy hẹp hơn: cấm
hostPath, host network và container privileged — ba thứ BuildKit không cần."

*Nếu được hỏi thêm:* đây là đánh đổi tôi chủ động nhận chứ không phải bỏ sót, và tôi ghi nó vào mục giới hạn.
Mới thử được một trong bảy luật của policy (B3.3).

**A4.4** **Ý chính:** "Nó chạy trong BuildKit, mà BuildKit chạy với `--oci-worker-no-process-sandbox`, nghĩa là
chia process space với các bước build. Nên nó thấy được gì BuildKit thấy. Vì thế test phải chạy khi pod chưa có
đăng nhập registry nào, và chỉ build trên `main` mới ghi vào cache dùng chung."

*Nếu được hỏi thêm:* nó **không** ký được image, vì token AWS không nằm trong container đó.

**A4.5** **Ý chính:** "Cache nằm trên chính ECR, dưới tag `buildcache`. Stage build kéo cache ở mọi nhánh; chỉ
`main` mới đẩy. Nếu nhánh cũng đẩy thì một nhánh bất kỳ có thể đầu độc thứ mà `main` build ra."

*Nếu được hỏi thêm:*

- Điều này chỉ được kiểm chứng ở bước 12, khi build đầu tiên của phase chạy hết pipeline trên nhánh — trước đó
  builds 11 tới 17 đều chạy trên `main`, nơi việc đẩy cache luôn xảy ra, nên không có ca âm tính nào.
- Stage `Test` cũng có `--import-cache`, nhưng nó chạy **trước** khi đăng nhập ECR nên lần nào cũng `401` và
  BuildKit build lại từ đầu. Dòng đó chết ở đúng chỗ nó đang đứng; tôi ghi lại chứ chưa sửa.
- Và phải nói nốt: lớp bảo vệ này dựa vào "chỉ `main` được đẩy cache", mà ai push được lên `main` thì hiện không
  có gì chặn (A6.6). Nên nó là một lớp, không phải một hàng rào.

### A5. Supply chain: quét, SBOM, chữ ký

**A5.1** **Ý chính:** "Build đỏ khi có lỗ hổng CRITICAL *đã có bản sửa*. Trivy quét một lần ra `trivy-report.json`,
rồi tôi đếm báo cáo đó bằng `jq`: những mục `Severity == CRITICAL` và có `FixedVersion`. Quét trước, chặn sau là
thứ tự duy nhất giữ được báo cáo kể cả khi cổng đỏ."

*Nếu được hỏi thêm:* vì sao không dùng cờ — `trivy convert` không có `--ignore-unfixed`, cờ đó thuộc các lệnh
quét; còn `--severity` cộng `--exit-code` sẽ đánh trượt mọi build vì những lỗ hổng không ai vá được. Một cổng
không bao giờ qua được là một cổng người ta tắt đi.

**A5.2** **Ý chính:** "Với một CRITICAL thật thì chưa bao giờ: cả năm CRITICAL của image gốc đều không có bản vá, nên
cổng trả 0 cả trước lẫn sau khi đổi base sang Debian 13. Vì vậy tôi chạy một **positive control**: trên một branch tạm,
nới cổng ra để đếm finding có bản sửa ở mọi mức. Build đó đỏ ở stage Scan với `Fixable, any severity: 6`. Nó chứng
minh cơ chế chặn hoạt động; nó không chứng minh cổng từng bắt được một CRITICAL."

*Nếu được hỏi thêm:*

- **Con số khớp trước khi chạy:** report của build `main` gần nhất có 6 finding sửa được, 5 MEDIUM và 1 LOW, nên tôi
  biết trước build phải đỏ. Build 2 của branch `jenkins/step-gate-control` ra đúng 6, rồi `[ 6 -eq 0 ]` và
  `Finished: FAILURE`: build đỏ ở lệnh cuối của gate trong stage Scan. Các dòng đánh dấu stage trong log thì không bắt
  được, nên tôi không khẳng định bằng mắt rằng stage sau không chạy; theo cách pipeline khai báo chạy, một stage fail
  thì các stage sau bị bỏ.
- **Lần thử đầu không thử được gì:** build 1 kết thúc `NOT_BUILT`. Tôi chưa sửa `Jenkinsfile` nên commit rỗng, push
  đẩy lên đúng commit docs của `main`, và skip guard bỏ qua nó một cách hợp lệ. Bây giờ bước đó kiểm `git diff --stat`
  trước khi commit.
- **Branch phải khớp `jenkins/step-*`:** Jenkins chỉ phát hiện `main` và mẫu đó.
- Evidence: `../evidence/drills.md`, mục "Measured for the CV", M4.

**Mẹo:** phân biệt ba điều: "không chặn nhầm", "cơ chế chặn được" (positive control), và "đã bắt được một CRITICAL
thật" (chưa). Đây là chỗ nhiều người nói quá.

**A5.3** **Ý chính:** "Cosign ký **digest**, bằng key bất đối xứng trong KMS, alias `medical-rag-cosign`. Key
private không bao giờ rời KMS; pipeline chỉ được xin nó ký. Ký digest vì tag có thể bị trỏ sang image khác, còn
digest là hash của chính nội dung — ký digest thì thứ đã quét và thứ được ký chắc chắn là một."

*Nếu được hỏi thêm:* `cosign attest --type spdxjson` gắn thêm SBOM do Trivy sinh, cũng bằng key đó.

**A5.4** **Ý chính:** "Cosign v3 lưu chữ ký và attestation dạng OCI referrer **không có tag**, nằm cạnh image
trong cùng repository. Vì thế lifecycle policy của tôi chỉ đếm image *có tag* — đếm cả image không tag sẽ xoá
chữ ký của image đang chạy."

*Nếu được hỏi thêm:* hệ quả ngược là manifest cache cũ cũng không tag và cũng không bao giờ bị dọn, nên chúng
tích lại. Cách sửa là một repository riêng cho cache, có rule riêng.

**A5.5** **Ý chính:** "Vì image là private. Đẩy lên Rekor là đưa digest, tên repository và account id vào một log
công khai, mà chẳng đổi lại được gì: ở đây việc verify dùng chính key, không cần log minh bạch."

*Nếu được hỏi thêm:* cosign v3 đã bỏ các cờ từng nói điều đó — `--tlog-upload=false` bị deprecated trên `sign`
và biến mất hẳn khỏi `attest`, cùng `--rekor-url` và `--offline`. Thay thế là một signing config không liệt kê
service nào, sinh ngay trong stage. Nếu image là public thì tôi sẽ bật Rekor, vì khi đó log công khai có giá trị.

**A5.6** **Ý chính:** "Kyverno, ở lúc admission. Ở phase này thì chưa ai kiểm cả, và đó là lỗ hổng lớn nhất khi đóng
phase: một digest sửa tay trong values prod đi vòng qua cả pipeline, vì skip guard bỏ qua commit chỉ đụng `deploy/`.
Phase drills đóng một nửa lỗ đó: prod giờ từ chối image chưa ký ngay lúc tạo pod. Nửa còn lại vẫn mở: một digest
sửa tay trỏ vào một image cũ *đã ký* vẫn qua, vì chữ ký chứng minh key chứ không chứng minh commit."

*Nếu được hỏi thêm:*

- **Cách làm:** `ImageValidatingPolicy` với public key cosign (lưu trong Git, nên admission không gọi KMS; còn chưa đo
  xem nó có gọi ra Sigstore công khai không), `Deny` ở prod và
  `Audit` ở dev. Không dùng `ClusterPolicy` với `verifyImages`, vì cosign v3 lưu chữ ký dưới dạng OCI referrer
  (A5.4), không có tag `.sig`.
- **Bằng chứng:** image `1eaa43bf3512` từ phase app, chưa từng được ký, bị từ chối với
  `admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-images-prod" denied the request: Policy verify-images-prod failed: the image is not signed with the medical-rag cosign key`.
  Pod dùng image đã ký vẫn được tạo ngay sau đó.
- **Giới hạn:** chỉ hai namespace app được kiểm; image của addon thì không. Chi tiết: `../drills/answers.md`.

**Mẹo:** đây gần như chắc chắn là câu hỏi tiếp theo sau khi bạn khoe ký bằng KMS. Trả lời thẳng: cái gì đã làm ở
phase nào, và cái gì vẫn chưa được kiểm.

### A6. Promotion qua Git

**A6.1** **Ý chính:** "Dev thì bot commit thẳng lên `main`, sửa `deploy/envs/dev/values.yaml`. Prod thì bot mở một
pull request sửa `deploy/envs/prod/values.yaml`, kèm digest và tóm tắt Trivy, rồi tôi đọc và merge. Cả hai đều chỉ
là thay đổi trong Git; Argo CD làm phần còn lại."

*Nếu được hỏi thêm:* bot commit với `git pull --rebase` và thử tối đa ba lần, vì giữa lúc build và lúc push có
thể có commit khác chen vào.

**A6.2** **Ý chính:** "Stage thứ hai là một skip guard: nếu tác giả commit mới nhất là `jenkins-bot`, hoặc mọi
file thay đổi đều nằm trong `deploy/`, `docs/` hoặc kết thúc bằng `.md`, thì build kết thúc ngay với kết quả
`NOT_BUILT`. Không có nó thì bot commit, Jenkins thấy commit mới, build lại, commit tiếp — vô hạn."

*Nếu được hỏi thêm:* điều tinh tế là **hai commit đó bị bắt bởi hai điều kiện khác nhau** (A6.3).

**A6.3** **Ý chính:** "Ba lần, và chỉ lần đầu là xanh hết — đó là thiết kế đúng chứ không phải triệu chứng. Lần
đầu là commit của tôi, chạy **chín** trên mười stage — stage gắn tag `release-` chỉ chạy khi commit đụng values
prod. Lần hai là commit `dev:` của bot, bị chặn bởi phép kiểm tra *tác giả*. Lần
ba là lúc tôi merge pull request prod, bị chặn bởi phép kiểm tra *file*, vì squash merge do người bấm nút đứng tên —
phép kiểm tra tác giả không bao giờ bắt được một lần merge prod."

*Nếu được hỏi thêm:*

- Cả hai lần skip đều in ra cùng một dòng, **có tên tác giả trong đó**:
  `Nothing to build: author=…, only docs or deploy files changed`. Đọc cái tên mới biết phép kiểm tra nào đã chặn;
  việc dòng đó in ra một cái tên không phải bằng chứng rằng phép kiểm tra tác giả là thứ đã chặn.
- `NOT_BUILT` là kết quả riêng của Jenkins, hiển thị **xám** chứ không đỏ.
- Một commit code bình thường chỉ cho **hai** build; build thứ ba tới khi tôi động vào pull request.
- Build trên nhánh `jenkins/step-N` là loại thứ tư: xanh, nhưng cố ý chỉ chạy sáu trên mười stage.

**A6.4** **Ý chính:** "Tag có thể bị trỏ sang image khác; digest là hash của nội dung. Values ghi
`tag@sha256:…` — tag để người đọc hiểu, digest để máy dùng. Khi có cả hai, runtime kéo theo digest."

*Nếu được hỏi thêm:* một chuyện tôi đo được và ban đầu thấy lạ: mười tag cùng trỏ vào một digest. Mọi commit
**kể từ khi đổi base sang Debian 13** mà đi tới được stage build đều chỉ đụng file ngoài runtime image, nên
BuildKit dựng lại nội dung y hệt. Hệ quả: **tag cho biết commit nào *dựng* image, không phải commit nào *đổi*
nó**.

**A6.5** **Ý chính:** "`git revert` commit đã đổi version, Argo CD sync về image cũ. Không cần quyền vào cluster,
và mọi lần đổi prod đều nằm trong lịch sử Git."

*Nếu được hỏi thêm:* bẫy là lifecycle policy của ECR. Nếu image cũ đã bị dọn thì revert xong pod sẽ
`ImagePullBackOff`. Vì thế có rule ưu tiên 1 giữ 10 image gắn tag `release-*`, và stage đầu tiên của pipeline gắn
tag đó cho đúng digest mà prod nhận. Rule đó **chưa được kiểm chứng** vì repository chưa đủ 30 image có tag.

**A6.6** **Ý chính:** "Bằng quy ước, không phải bằng GitHub. Token của bot là token của tôi, nên về kỹ thuật nó
push thẳng lên `main` được, kể cả values prod. Repo một người thì không tách được người mở PR và người duyệt."

*Nếu được hỏi thêm:* cách sửa là một tài khoản bot riêng hoặc GitHub App, cộng một ruleset yêu cầu code owner cho
`deploy/envs/prod/`. Tôi ghi nó vào giới hạn chứ không nói là đã có.

### A7. Vận hành và số đo

**A7.1** **Ý chính:** "Trước phase, ba node còn **chưa hứa cho pod nào** 560m, 775m và 720m CPU — đó là request,
không phải mức dùng thật, vì cluster không có metrics-server. Controller xin 250m và rơi vào node
1, để lại 310m ở đó — không đủ cho build pod xin 500m. Nên build pod chỉ lên được node 2 và node 3, và tôi đặt
`containerCap: 1`."

*Nếu được hỏi thêm:* 500m là 300m `buildkit`, 50m `tools`, 50m `trivy`, cộng 100m của container `jnlp` mà plugin
tự thêm — con số cuối tôi phải đọc từ Prometheus vì `Jenkinsfile` không khai nó.

**A7.2** **Ý chính:** "External Secrets sinh nó **trong cluster**, bằng generator `Password`, và chart chỉ mount
secret đó. Nghĩa là nó khác sau mỗi lần dựng lại cluster, và không có bản sao nào ngoài cluster."

*Nếu được hỏi thêm:* đọc bằng
`kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d`.
`refreshInterval: "0"` nên nó sinh một lần rồi thôi, không đổi dưới chân controller đang chạy.

**A7.3** **Ý chính:** "Toàn bộ nằm trong `deploy/argocd/values/jenkins.yaml`: danh sách plugin, job Multibranch
viết bằng JCasC, credential, và cap của pod template. Không có gì được click ra cả. Dựng lại thì Argo CD apply
file đó, nên controller quay lại giống hệt — trừ mật khẩu admin, vốn được sinh mới."

*Nếu được hỏi thêm:* ở phase drills, một lần dựng lại cả cụm từ stack trống, bấm giờ bằng script, đưa cả 17
Application về `Synced` và `Healthy` trong 21 m 47 s, kể cả `jenkins-platform` ở wave 3 và `jenkins` ở wave 4
(`../evidence/drills.md`, M3). Đó mới là Application khoẻ: chưa ai đăng nhập, chưa có job nào được quét lại hay build
nào chạy, và chưa có commit nào được đẩy qua pipeline trên cụm vừa dựng. Con số 14 m 11 s của phase GitOps không so
được: cụm đó chỉ có 9 Application và không có Jenkins.

**A7.4** **Ý chính:** "Prometheus đã có sẵn từ phase GitOps nên tôi đọc **request** CPU của build pod từ đó —
300m `buildkit` cộng 100m `jnlp` ở bước 10. Mức dùng thật của CPU và bộ nhớ thì tôi chưa đo. Thời gian thì lấy
từ dấu thời gian của commit và của pod. Tôi không dựng dashboard riêng cho pipeline."

*Nếu được hỏi thêm:* một số đo có ích: `TRIVY_CACHE_DIR` nằm trên `emptyDir` của pod, nên Trivy tải lại 114.8 MiB
database **mỗi build** — 13 trong 23 giây của stage quét, ở build tôi bấm giờ.

**A7.5** **Ý chính:** "Đọc console của đúng stage đỏ trước khi đụng vào gì. Nếu là `NOT_BUILT` thì không phải lỗi,
đọc tên tác giả trong dòng skip guard. Nếu là lỗi thật thì phần lớn thời gian nằm ở việc tách 'lệnh sai' khỏi
'quyền thiếu' — và tôi có một bảng triệu chứng trong `guide/troubleshooting.md`."

*Nếu được hỏi thêm:* bài học lớn nhất của phase là một lỗi có thể **im lặng**: bộ plugin lệch phiên bản nạp không
báo gì rồi mới chết lúc chạy (A8.1).

**A7.6** **Ý chính:** "Phần thêm của phase là volume EBS cho Jenkins home, dung lượng ECR của image và cache, và
giờ CPU của build pod — build pod chỉ sống trong lúc build nên phần này nhỏ. `[điền: số tiền thật mỗi tháng]`."

*Nếu được hỏi thêm:* KMS key và secret đã tính vào phần nền tảng, không phải phát sinh của phase này.

### A8. Sự cố và bài học

**A8.1** **Ý chính:** "Bốn plugin của bộ Declarative — ba cái `pipeline-model-*` cộng
`pipeline-stage-tags-metadata` — ra cùng một repository và phải chung một chuỗi phiên bản. Trình phân giải phụ
thuộc của Jenkins giữ hai cái ở 2.2218 còn hai cái kia lên 2.2277. Bộ plugin lệch nhau đó **vẫn nạp bình thường,
không báo lỗi gì**, rồi build sau chết với `NullPointerException: Cannot invoke method call() on null object`.
Tốn bốn build và hai lần tôi chẩn đoán sai."

**Mẹo:** đừng mở đầu bằng "tốn bốn build". Mở đầu bằng *kiểu* hỏng: một bộ plugin nạp sạch sẽ rồi chết lúc
chạy. Phần "liên hệ là suy ra" để dành cho câu hỏi tiếp.

*Nếu được hỏi thêm:*

- Nguyên nhân gốc là `installLatestPlugins: false`: mỗi phụ thuộc được phân giải về **mức cao nhất trong các mức
  tối thiểu mà những cái phụ thuộc nó đòi**, chứ không phải bản mới nhất. Nên danh sách plugin là một tập *sàn*,
  không phải một tập phiên bản.
- Liên hệ giữa bộ plugin lệch nhau và đúng cái NPE đó là **suy ra** từ kiểu triệu chứng và từ việc bản vá có tác dụng —
  log chứa stack trace đã bị xoay mất khi pod restart trước khi tôi kịp lưu.

**A8.2** **Ý chính:** "Token ECR bị in nguyên văn vào log build. Jenkins chạy mọi bước `sh` bằng `/bin/sh -xe`,
tức là echo từng dòng lệnh với biến đã được thay giá trị. Khối đăng nhập ECR gán mật khẩu vào biến, nên cả mật
khẩu lẫn chuỗi base64 đều nằm trong console. Token sống 12 giờ và cho phép push lẫn pull trên cả registry."

*Nếu được hỏi thêm:*

- Sửa bằng `set +x` ở đầu khối, chặn phần trace mà vẫn giữ stdout, nên dòng in danh tính vẫn chạy.
- Guide không hề nhắc tới shell tracing; câu duy nhất nó nói về che giấu là về `withCredentials`, một cơ chế
  khác, xuất hiện năm bước sau.
- Phơi nhiễm đóng lại **bằng thời gian** chứ không phải bằng hành động: token hết hạn sau 12 giờ. Bản ghi thì vẫn
  nằm trên PVC của Jenkins cho tới khi build bị xoá.

**Mẹo:** nói rõ "đóng bằng thời gian, không phải bằng hành động". Đó là sự khác biệt giữa kể sự cố và hiểu nó.

**A8.3** **Ý chính:** "Ví dụ gọn nhất: quy tắc 5 của guide bảo `grep` tìm placeholder còn sót trong file bạn vừa
điền. Nó bỏ sót `<aws-cli version>` vì character class của nó không có dấu cách. Và trớ trêu là quy tắc đó được
thêm vào để sửa đúng một khiếm khuyết cùng dạng trước đó."

*Nếu được hỏi thêm:* bốn cái còn lại là secret rỗng, policy chưa compile, placeholder chưa điền, và phép kiểm
readiness ở bước 16 nhận một pod chưa sẵn sàng. Kết luận tôi rút ra: **một phép kiểm tra không thể đỏ thì tệ hơn
không có phép kiểm**.

**A8.4** **Ý chính:** "Có, năm lệnh — và guide là do chính tôi viết trước khi chạy, như một cách bắt mình thiết
kế xong mới thực thi, nên đó là khiếm khuyết của chính tôi. Ví dụ rõ nhất là `trivy convert --ignore-unfixed`:
cờ đó thuộc các lệnh quét, không thuộc `convert`, nên cổng chặn không bao giờ qua được — trên bất kỳ image nào,
ở bất kỳ cluster nào."

*Nếu được hỏi thêm:* chúng chỉ lộ khi chạy thật vì guide được viết trước khi chạy, và không phép kiểm tra tĩnh nào
biết một cờ có tồn tại trên một lệnh con hay không. Chỉ **một** trong năm là do công cụ bỏ cờ sau khi guide
được viết (cosign v3); bốn cái kia là cờ chưa bao giờ có, một cờ bị bỏ qua mà không báo gì, file không nằm ở
chỗ bước đó tìm, và
một `ENTRYPOINT` không được tính đến.

**A8.5** **Ý chính:** "Tôi từng kết luận cloud Kubernetes của Jenkins không tồn tại, dựa trên việc build pod
không xuất hiện. Sai — tôi đọc lại cấu hình bốn lần và nó vẫn ở đó. Cái làm tôi nhận ra là tôi không
có phép đo nào cho tuyên bố đó, chỉ có một suy luận từ triệu chứng."

*Nếu được hỏi thêm:* sau lần đó tôi đổi cách làm: trước khi nói "cái X không tồn tại", phải có một lệnh đọc X ra.

**A8.6** **Ý chính:** "Vì không có cách nào thử một `Jenkinsfile` ngoài việc push nó và đợi poll. Pipeline chỉ
chạy được trong Jenkins, và Jenkins chỉ lấy code từ Git. Nên các bước 10 tới 18 phần lớn là pipeline tự lặp trên
chính nó."

*Nếu được hỏi thêm:* tệ hơn là builds 11 tới 17 đều chạy thẳng trên `main`, trái với chính hướng dẫn của guide là
đẩy lên nhánh `jenkins/step-N` trước. Build đầu tiên chạy trên nhánh là ở bước 12 — và đó cũng là lần đầu tiên
kiểm chứng được tuyên bố "nhánh không bao giờ đẩy cache".

**A8.7** **Ý chính:** "Cuối phase tôi thu hẹp quyền ECR của vai trò node xuống đúng repository của app. Nhưng
trước đó vài hôm tôi đã thêm một repository thứ hai vào chính policy ấy, để kubelet kéo được image công cụ của
build pod. Thu hẹp đúng như kế hoạch ban đầu là đẩy build pod vào `ImagePullBackOff` ngay."

*Nếu được hỏi thêm:* bài học là hai thay đổi lên cùng một policy, cách nhau vài hôm, mà không có gì nối chúng
lại. Giờ tôi luôn đọc policy **đang chạy** trước khi thay, chứ không thay theo bản nháp viết từ trước. Tôi giữ
cả hai ARN và chứng minh bằng một lệnh simulator mà kế hoạch không yêu cầu: `ecr:BatchGetImage` trên
`medical-rag-ci` trả `allowed`.

### A9. Nhìn lại

**A9.1** **Ý chính:** "Đẩy Kyverno lên cùng phase. Tôi xây cả một chuỗi ký mà tới cuối phase vẫn chưa ai kiểm chữ ký,
nên phần đắt nhất — KMS, cosign, attestation — phải đợi tới phase drills mới đổi được thành quyền kiểm soát."

*Nếu được hỏi thêm:* thứ hai là ghim phiên bản plugin theo cả bộ thay vì theo từng cái, vì đó là sự cố tốn nhất.

**A9.2** **Ý chính:** "Chữ ký chỉ chứng minh 'ký bằng key này', không chứng minh 'đã qua pipeline của `main`': ai
chiếm được pod build là ký được. Và token của bot push thẳng được lên `main`, nên 'prod chỉ đổi qua PR' mới là quy
ước."

*Nếu được hỏi thêm:* hai điểm yếu tôi từng nêu ở đây đã được đóng ở phase drills: Kyverno giờ kiểm chữ ký ở prod
(A5.6), và cổng đã đỏ trong một positive control (A5.2). Thứ còn lại là chưa có commit nào chạy hết pipeline trên một
cụm vừa dựng lại.

**A9.3** **Ý chính:** "Ba thứ. Tách tài khoản bot khỏi tài khoản người, để 'prod chỉ qua PR' là luật chứ không
phải quy ước. Đẩy build ra khỏi node của ứng dụng, vì hiện pipeline ăn vào chính CPU mà app dùng. Và có người
trực: hiện nếu cluster hỏng thì tôi mất luôn công cụ để sửa nó."

*Nếu được hỏi thêm:* ở quy mô công ty tôi cũng sẽ cân nhắc bỏ Jenkins cho GitHub Actions, vì phần lớn công tôi bỏ
ra ở đây là vận hành chính Jenkins chứ không phải pipeline.

**A9.4** **Ý chính:** "Hai thứ. Một là cho build pod danh tính AWS riêng rồi tước quyền push và ký khỏi vai trò
node — đó là phần tốn công nhất và cũng là phần tôi thấy đáng nhất, vì nó biến 'pipeline được phép làm việc này'
từ một mặc định thành một quyết định. Hai là thói quen ghi lại cả những phép đo *không* chứng minh điều tôi
tưởng; nhờ nó mà tôi bắt được mấy chỗ phép kiểm tra vẫn xanh trong khi thứ nó canh thì hỏng."

*Nếu được hỏi thêm:* thứ tôi sẽ bỏ là việc viết guide chi tiết trước khi chạy lần nào. Nó buộc tôi thiết kế
trước, nhưng cái giá là 23 khiếm khuyết chỉ lộ ra khi chạy thật (A8.4).

---

## Phần B — Chi tiết

Đáp án ngắn, để tự kiểm.

### B1. `Jenkinsfile`

**B1.1** Mười stage: `Tag the image prod runs` → `Skip guard` → `Test` → `Log in to ECR` → `Build and push` →
`Scan` → `SBOM and signature` → `Index version` → `Promote to dev` → `Prod pull request`.

Cổng chặn có chủ đích là **`Test`** và **`Scan`**, cả hai đứng trước bước ký, nên một image lỗi không bao giờ
được ký hay lên Git. **`Index version`** là cổng thứ ba, ít ai để ý: nó dừng pipeline nếu PDF trong Git khác
corpus trên S3.

*Ở đâu:* `Jenkinsfile`, các khối `stage(...)`.

**B1.2** Chỉ trên `main`: `SBOM and signature`, `Promote to dev`, `Prod pull request` (`when { branch 'main' }`),
và `Tag the image prod runs` (`branch 'main'` **và** `changeset "deploy/envs/prod/values.yaml"`). Một build trên
nhánh chạy **sáu** trên mười, và mất 1 m 32 s so với 14 m 20 s.

*Ở đâu:* `Jenkinsfile`, các khối `when`.

**B1.3** Vì commit merge một pull request prod chỉ đụng `deploy/envs/prod/values.yaml`, nên skip guard sẽ dừng
build đó. Nếu stage gắn tag đứng dưới guard thì tag `release-` không bao giờ được viết — mà tag đó chính là thứ
bảo vệ image prod khỏi lifecycle policy. Mọi stage khác xếp theo phụ thuộc; riêng stage này xếp theo guard.

*Ở đâu:* `Jenkinsfile`, stage đầu tiên, trên `stage('Skip guard')`.

**B1.4** Dừng nếu tác giả commit mới nhất là `jenkins-bot`, **hoặc** mọi file thay đổi đều nằm trong `deploy/`,
`docs/`, hoặc kết thúc bằng `.md`.

Danh sách rỗng được coi là **phải build**: `files && files.split(…)`, chuỗi rỗng là falsy trong Groovy. Lý do:
trên một tập rỗng thì "mọi file đều thuộc `deploy/`" luôn đúng, nên bỏ qua khi nghi ngờ là giấu mất thay đổi.
Danh sách rỗng xảy ra thật — `git show --pretty= --name-only HEAD` trả **0 byte** trên merge commit, nên guard chỉ
bỏ qua được commit một cha.

Đánh dấu bằng `currentBuild.result = 'NOT_BUILT'` rồi `error(…)` trong khối `script`.

*Ở đâu:* `Jenkinsfile`, `stage('Skip guard')`.

**B1.5** Vì `trivy convert` **không có** `--ignore-unfixed` — cờ đó thuộc các lệnh quét — và `--severity` cộng
`--exit-code` sẽ đánh trượt mọi build vì những lỗ hổng không có bản vá. Nên cổng đếm bằng `jq`: `Severity ==
"CRITICAL"` **và** `FixedVersion` khác rỗng, rồi `[ "$N" -eq 0 ]`. Nó cũng *in ra con số* trước khi so sánh, để
console nói được vì sao nó qua.

*Ở đâu:* `Jenkinsfile`, `stage('Scan')`, khối trong `container('tools')`.

**B1.6** Nó tắt token mặc định mà Kubernetes gắn vào **mọi** container của pod. Token AWS được mount thủ công,
qua một `projected` volume, và chỉ vào `tools`. Nếu để mặc định thì `buildkit` — nơi code của repository chạy —
cũng có một token, dù là token Kubernetes chứ không phải AWS.

*Ở đâu:* `Jenkinsfile`, `podTemplate`, và volume `aws-token`.

**B1.7** Jenkins chạy mọi bước `sh` bằng `/bin/sh -xe`, echo từng dòng với biến đã thay giá trị. Không có
`set +x` thì mật khẩu ECR và chuỗi base64 nằm nguyên trong console, sống 12 giờ. `set +x` chỉ tắt phần trace,
stdout vẫn chạy, nên dòng in danh tính vẫn hiện.

*Ở đâu:* `Jenkinsfile`, `stage('Log in to ECR')`.

**B1.8** Nó tính version index từ chính image (`--target indexversion-out`), rồi so với `.index.version` trong
values dev và prod. **Chỉ khi khác** mới so SHA-256 của PDF trong Git với checksum của `corpus/` trên S3, và dừng
nếu lệch. Nó **không** dựng index — việc đó do Job trong cluster ở wave 1 của chart app — và **không** tải corpus
lên S3.

*Ở đâu:* `Jenkinsfile`, `stage('Index version')`.

### B2. Chart và `values/jenkins.yaml`

**B2.1** Với `false`, mỗi phụ thuộc được phân giải về **mức cao nhất trong các mức tối thiểu mà những plugin phụ
thuộc nó đòi**, chứ không phải bản mới nhất. Danh sách plugin vì thế là một tập *sàn*. Ba plugin phải nâng tay vì
log khởi động đòi đích danh, và bốn plugin `pipeline-model-*` phải ghim cùng một phiên bản vì chúng ra cùng một
repository (A8.1).

*Ở đâu:* `deploy/argocd/values/jenkins.yaml`, `controller.installLatestPlugins` và `controller.installPlugins`.

**B2.2** Trong `controller.JCasC.configScripts`, viết bằng Configuration as Code. Nó theo dõi `main` và các nhánh
`jenkins/step-N`, poll mỗi 2 phút bằng `periodicFolderTrigger`.

*Ở đâu:* `deploy/argocd/values/jenkins.yaml`, khối `JCasC`.

**B2.3** `containerCap: 1` trong cấu hình cloud Kubernetes. Nó chặn số build pod đồng thời **trên toàn bộ các
branch**, không phải trên một job. Đặt ở cấp cloud vì một cài đặt ở cấp job vẫn cho hai branch build cùng lúc.

*Ở đâu:* `deploy/argocd/values/jenkins.yaml`.

**B2.4** Trỏ tới Secret `jenkins-admin` trong namespace `jenkins`. Secret đó do **External Secrets** sinh, bằng
generator `Password` với `refreshInterval: "0"`; chart chỉ *mount* nó chứ không sinh. Hệ quả: mật khẩu mới sau
mỗi lần dựng lại cluster, và không có bản sao nào ngoài cluster.

*Ở đâu:* `deploy/argocd/values/jenkins.yaml` và `deploy/argocd/manifests/jenkins/secrets.yaml`.

**B2.5** Để controller không tự chạy bước build nào. Mọi thứ chạy trong build pod tạm, ở namespace khác, với mức
Pod Security khác. Nếu controller có executor thì một `Jenkinsfile` có thể chạy lệnh ngay trên controller — nơi
có quyền tạo pod.

*Ở đâu:* `deploy/argocd/values/jenkins.yaml`, `controller.numExecutors`.

**B2.6** Chart `jenkins` **5.9.63**, ghim bằng `targetRevision`. Values không đặt tag image, nên chart dùng image
mặc định của nó; controller thực tế đang chạy là `jenkins/jenkins:2.568.3-jdk21`, đọc từ cluster.

*Ở đâu:* `deploy/argocd/apps/jenkins.yaml`; phiên bản core trong `../evidence/jenkins.md`.

### B3. `manifests/jenkins/`

**B3.1** Năm file: `namespaces.yaml` (hai namespace và mức Pod Security), `rbac.yaml` (ServiceAccount
`jenkins-agent`, Role và RoleBinding), `secrets.yaml` (mật khẩu admin sinh trong cluster, và token GitHub từ
Secrets Manager), `networkpolicies.yaml` (mặc định chặn hết, hai đường được mở, IMDS bị loại),
`admission-policy.yaml` (ValidatingAdmissionPolicy cho namespace `privileged`).

*Ở đâu:* `deploy/argocd/manifests/jenkins/`.

**B3.2** `jenkins`: `baseline` enforce, `restricted` warn và audit. `jenkins-agents`: `privileged` enforce,
`baseline` warn và audit. Khác nhau vì BuildKit rootless cần seccomp và AppArmor `Unconfined`, mà `baseline` từ
chối. Controller không cần gì đặc biệt, nhưng chart upstream không đặt seccomp profile cho mọi container nên
`restricted` cũng không enforce được — khoảng trống đó để ở mức warn cho nhìn thấy, thay vì giấu đi.

*Ở đâu:* `deploy/argocd/manifests/jenkins/namespaces.yaml`.

**B3.3** Nó chặn hostPath, host network, host PID/IPC và container privileged — những thứ BuildKit không cần,
trong một namespace buộc phải ở mức `privileged`. Mới thử được **một** trong bảy luật: một pod dùng `hostPath` bị
từ chối với `hostPath volumes are not allowed in jenkins-agents`. Sáu luật còn lại chưa có ca thử.

*Ở đâu:* `deploy/argocd/manifests/jenkins/admission-policy.yaml`.

**B3.4** Mặc định chặn hết, rồi mở: DNS trong cluster, và HTTPS ra ngoài — nhưng **loại trừ**
`169.254.169.254/32`, nên không container nào rơi về vai trò node. Cùng một khuôn ở cả hai namespace.

*Ở đâu:* `deploy/argocd/manifests/jenkins/networkpolicies.yaml`.

**B3.5** Từ Secrets Manager `medical-rag/github`, qua External Secrets, thành Secret `jenkins/jenkins-github`, rồi
JCasC đọc nó thành một credential của Jenkins. Vai trò `medical-rag-ci` **không** đọc secret nào — đường của token
GitHub hoàn toàn tách khỏi đường của danh tính AWS.

*Ở đâu:* `deploy/argocd/manifests/jenkins/secrets.yaml`.

**B3.6** Vì chart ở wave 4 mount Secret `jenkins-admin` và `jenkins-github`, và build pod của nó dùng
ServiceAccount `jenkins-agent` — cả ba đều do manifest ở wave 3 tạo. Argo CD chỉ bắt đầu một wave khi mọi
Application của wave trước đã `Synced` **và** `Healthy`.

*Ở đâu:* `deploy/argocd/apps/jenkins-platform.yaml` và `apps/jenkins.yaml`.

### B4. IAM, ECR và KMS

**B4.1** Đúng một chủ thể: `system:serviceaccount:jenkins-agents:jenkins-agent`, với điều kiện trên cả `aud`
(`sts.amazonaws.com`) lẫn `sub`. Issuer là bucket OIDC tự host từ phase app. Đổi namespace hoặc đổi tên
ServiceAccount là mất quyền.

*Ở đâu:* `infra/terraform/shared/irsa.tf`.

**B4.2** `ecr:GetAuthorizationToken` trên `*` — action duy nhất AWS không scope theo repository được; tám action
push và pull trên **riêng** repository `medical-rag`; `kms:Sign`, `kms:GetPublicKey`, `kms:DescribeKey` trên key
cosign; và `s3:GetObject` trên `corpus/*`. Hết. Không secret, không `etcd-backups`, không quyền ghi bucket
artifacts.

*Ở đâu:* `infra/terraform/shared/irsa.tf`, `data "aws_iam_policy_document" "ci"`.

**B4.3** Chỉ còn đọc: năm action pull trên **cả hai** repository, cộng `ecr:GetAuthorizationToken`. Không còn
`PutImage` và không còn statement KMS nào. Bốn action upload và toàn bộ `CosignSign` bị xoá ở bước 18.

*Ở đâu:* `infra/terraform/cluster/iam.tf`.

**B4.4** Hai. `medical-rag`: scan khi push, tag immutable trừ hai ngoại lệ, rule 1 giữ 10 image tag `release-*`,
rule 2 giữ 30 image có tag. `medical-rag-ci` (image tools của pipeline): immutable hoàn toàn, giữ 5.

*Ở đâu:* `infra/terraform/shared/registry.tf`.

**B4.5** Hai ngoại lệ là `sha256-*` và `buildcache*`. Cần chúng vì cosign (định dạng tag cũ) và BuildKit phải ghi
đè được đúng những tag đó. Mọi tag khác — kể cả tag git SHA và `release-*` — thì không ghi đè được, nên thứ đã
quét và đã ký chính là thứ chạy.

*Ở đâu:* `infra/terraform/shared/registry.tf`, `image_tag_mutability_exclusion_filter`.

**B4.6** Đếm là **một**. Lifecycle policy đếm *image*, không đếm *tag*. Mười tag trên một digest ăn một trong ba
mươi chỗ. Điều này chưa được preview chứng minh vì repository chưa đủ 30 image có tag `[điền: kết quả preview khi
đủ]`.

*Ở đâu:* `infra/terraform/shared/registry.tf`; số mười tag trong `../evidence/jenkins.md`.

### B5. Cổng chặn và kiểm tra

**B5.1** Một lần, trong container `trivy`, ra `trivy-report.json` dạng JSON đầy đủ không lọc severity. Báo cáo
được `trivy convert --format table` in ra console cho người đọc, được `jq` đếm trong container `tools` cho cổng
chặn, và được `archiveArtifacts` lưu lại. Quét trước, chặn sau là thứ tự duy nhất giữ được báo cáo khi cổng đỏ.
Vì báo cáo không lọc severity nên số HIGH có sẵn trong đó, không cần quét lần hai. Cũng nhờ vậy mà positive control
chỉ cần sửa filter `jq` của gate, không cần quét lại (A5.2).

*Ở đâu:* `Jenkinsfile`, `stage('Scan')`.

**B5.2** `cosign verify --key awskms:///alias/medical-rag-cosign <IMAGE>@<digest>`. Nó nhận image pipeline vừa ký
và **từ chối** image cũ từ phase app với `Error: no signatures found`. Đó là ca âm tính của bước 14.

*Ở đâu:* bước 14 của guide; kết quả trong `../evidence/jenkins.md`.

**B5.3** So version index tính từ image với `.index.version` trong values dev và prod. Nếu khác, so tiếp SHA-256
của PDF trong Git với checksum của object `corpus/` trên S3, và dừng nếu lệch — vì Job trong cluster đọc corpus
từ S3, nên version mới chỉ được phép deploy khi S3 đã có đúng file PDF trong Git.

*Ở đâu:* `Jenkinsfile`, `stage('Index version')`.

**B5.4** Guide bảo `grep -cE "Failed Loading plugin|Failed to load:"`, neo vào dòng
`Jenkins is fully up and running`. Nó trả 0 — đúng. Nhưng nó đọc **mức tối thiểu được khai báo**, nên mù về mặt
cấu trúc với một bộ plugin mà các thành viên lệch phiên bản nhau: bộ lệch vẫn nạp sạch, chỉ chết lúc chạy. Phép
kiểm đúng là so phiên bản bốn plugin `pipeline-model-*` với nhau.

*Ở đâu:* bước 8 của guide; phân tích trong `../evidence/jenkins.md`.

**B5.5** Ba cách, mạnh dần. Trong build, `aws sts get-caller-identity` in ra ARN chứa `medical-rag-ci`. Ngoài
build, `simulate-principal-policy` trên vai trò node trả `implicitDeny` cho `ecr:PutImage` và `kms:Sign`. Và mạnh
nhất: chạy một pod ở namespace `default` — nơi không chặn IMDS — cho nó mượn vai trò node rồi xem KMS từ chối.
Lệnh đó cần `--command` trước `--`, vì image `aws-cli` có `ENTRYPOINT ["aws"]`.

*Ở đâu:* bước 9 và bước 18 của guide.

### B6. Evidence

**B6.1** #8: **19 m 08 s** commit tới pod dev Ready. #9: CRITICAL **5 → 0**, tổng 269 → 158, cộng `cosign verify`
nhận image đã ký và từ chối image chưa ký. #10: bot mở pull request kèm digest và tóm tắt Trivy, squash merge,
`release-` gắn đúng digest, và build sau merge `NOT_BUILT`.

*Ở đâu:* `../evidence/jenkins.md`.

**B6.2** Chặng Argo CD 4 m 48 s **có nhúng tay**: `refresh=normal` được annotate trong lúc chờ. Chặng pipeline
14 m 20 s **chưa tách** phần chờ khỏi phần chạy — `containerCap: 1` nghĩa là build có thể xếp hàng, và Stage View
tách được nhưng không được chụp lại.

*Ở đâu:* `../evidence/jenkins.md`, mục tiêu chí #8.

**B6.3** 23, trong đó 5 thuộc Part 2 và 18 thuộc Part 3, và **tất cả trừ một** nằm ở guide chứ không ở tài khoản
AWS. 15 thuộc năm dạng: phép kiểm tra đạt trong khi thứ nó canh hỏng (5), lệnh không làm được điều bước đó nói (5),
hỏng ồn ào nhưng chỉ sai hướng (2), một phép sửa phá một bước khác (1), một credential bị lộ (1). Số còn lại là
lẻ, phần lớn là một bước thiếu điều kiện tiên quyết hoặc ghi sai kết quả mong đợi của chính nó.

*Ở đâu:* `../evidence/jenkins.md`, mục "Problems found and fixed".

**B6.4** Nửa đầu của bước 19 đã có ở phase drills: dựng lại cả cụm từ Git, và hai Application của Jenkins về
`Synced Healthy` (21 m 47 s cho cả 17 Application). Nửa sau vẫn thiếu: đẩy một thay đổi code nhỏ và xem nó đi hết vòng trên cụm mới.
Ca dương tính cho cổng đã có (positive control, A5.2). Hai thứ nhỏ hơn: dung lượng repository và số image không tag,
và preview lifecycle khi đã quá 30 image có tag.

*Ở đâu:* `../evidence/drills.md`, M3 và M4; phần còn lại ở `../evidence/jenkins.md`, mục "Still to check" (mục đó viết trước phase drills).
