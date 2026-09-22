# Câu hỏi về phase drills

Phase này chứng minh ba kiểm soát bằng cách cố ý gây ra chuyện xấu: xoá một namespace rồi khôi phục etcd, đưa một
image chưa ký lên prod, và nâng cấp Kubernetes trong lúc app đang chạy. Kèm theo là các phép đo cho CV: một lần
dựng lại cả nền tảng có bấm giờ, và một build cố ý làm cổng Trivy đỏ. Bộ câu hỏi kiểm xem bạn giải thích được mỗi
con số được đo thế nào, nó có thể pass sai theo cách nào, và cái gì *không* được chứng minh.

Đáp án nằm ở [`answers.md`](answers.md), cùng số thứ tự.

| Phần | Kiểm tra điều gì |
|---|---|
| **A. Phỏng vấn** (ưu tiên) | Bạn kể được ba drill và kết quả của chúng, vì sao mỗi con số đáng tin, các sự cố của phase, và giới hạn còn lại |
| **B. Chi tiết** | Bạn biết vì sao từng khối trong CronJob snapshot, lệnh restore, policy Kyverno, `upgrade.yml` và `timed-rebuild.sh` được viết như vậy |

Bộ liên quan: [tổng quan project](../common/questions.md), [Jenkins](../jenkins/questions.md),
[GitOps](../gitops/questions.md), [Ansible](../ansible/questions.md), [Terraform](../terraform/questions.md),
[AWS](../aws/questions.md). Tham chiếu dạng `Common A7.2` trỏ tới bộ tương ứng. Ý tưởng của phase:
[README](README.md) · [concepts](concepts.md) · [guide](guide.md). Số đo: [`../evidence/drills.md`](../evidence/drills.md).

**Cách dùng.** Trả lời thành tiếng trước khi mở đáp án. Phần A là thứ bạn nói ra. Với mỗi con số, tự hỏi thêm: "đo
từ lúc nào tới lúc nào, và nó có thể sai theo cách nào?" — đó là câu người phỏng vấn sẽ hỏi tiếp.

---

## Phần A — Phỏng vấn

### A1. Tổng quan

**A1.1** Trình bày phase drills trong một tới hai phút.

**A1.2** Phase này nhận ba tiêu chí #12, #13, #14. Mỗi tiêu chí đòi bằng chứng gì, và kết quả ra sao?

**A1.3** Vì sao mỗi kiểm soát phải đi kèm một drill? Cấu hình xong rồi chẳng phải là đủ sao?

**A1.4** Trước khi drill, bạn phải dựng lại cluster. Bạn đã đổi gì trước khi dựng, và vì sao lại là lúc đó?

### A2. Backup và khôi phục etcd (#12)

**A2.1** CronJob snapshot hoạt động thế nào? Vì sao nó có ba container?

**A2.2** Vì sao phải chạy `etcdutl snapshot status` trước khi upload? Nó bắt được gì, và không bắt được gì?

**A2.3** CronJob lấy quyền ghi S3 từ đâu? Rủi ro của cách đó là gì?

**A2.4** Kể lại bài drill khôi phục, từng bước.

**A2.5** Vì sao phải khôi phục cả ba member cùng lúc, chứ không từng node một?

**A2.6** `--bump-revision` và `--mark-compacted` dùng để làm gì? Bỏ chúng đi thì sao?

**A2.7** RTO đo từ lúc nào tới lúc nào? Nó có thể pass sai theo cách nào, và bạn chặn điều đó ra sao?

**A2.8** Làm sao bạn biết *dữ liệu* thật sự quay về, chứ không chỉ cluster sống lại?

**A2.9** RTO 7 phút gồm những gì? RPO là bao nhiêu?

**A2.10** Bạn đã đổi lịch snapshot sang 15 phút một lần để chứng minh nhanh. Điều đó có làm drill kém trung thực không?

**A2.11** Cái gì bị mất khi khôi phục? Và có gì lạ xảy ra không?

**A2.12** Snapshot có dùng được trên một cluster vừa dựng lại không?

**A2.13** Một lần backup hỏng thì bạn biết bằng cách nào? "RPO tối đa 6 giờ" đúng trong điều kiện nào?

### A3. Kyverno và image chưa ký (#13)

**A3.1** Kyverno chặn cái gì, và bạn chứng minh điều đó thế nào?

**A3.2** Vì sao dùng `ImageValidatingPolicy`, chứ không dùng `ClusterPolicy` với `verifyImages`?

**A3.3** Vì sao pin chart 3.8.2 mà không dùng bản mới nhất?

**A3.4** Pattern image được chọn thế nào? Vì sao không viết `medical-rag*` cho gọn?

**A3.5** Vì sao chạy `Audit` trước `Deny`? Lần `Audit` đầu tiên cho kết quả gì?

**A3.6** Policy dev và prod khác nhau ở `failurePolicy`. Vì sao?

**A3.7** Kyverno làm cluster dễ vỡ hơn ở đâu, và bạn giảm rủi ro đó thế nào?

**A3.8** Có những gì Kyverno *không* chặn được?

**A3.9** Sau khi cài, Application `kyverno` đọc `OutOfSync` mãi. Bạn tìm ra nguyên nhân thế nào?

**A3.10** Bản sửa cho lỗi đó đã có trong Git, nhưng không tới được cluster. Chuyện gì xảy ra, và bạn gỡ thế nào?

**A3.11** Guide bảo "xoá một pod prod để thấy nó quay lại, an toàn vì có PDB". Thực tế đã xảy ra gì?

### A4. Nâng cấp Kubernetes (#14)

**A4.1** Tiêu chí nâng cấp đã đo được chưa? Nếu chưa thì vì sao?

**A4.2** `upgrade.yml` được thiết kế thế nào?

**A4.3** Vì sao không nâng cấp bằng cách đổi pin phiên bản rồi chạy lại `make cluster`?

**A4.4** Muốn đo tiêu chí này thật thì làm thế nào? Kết quả đó chứng minh gì, và không chứng minh gì?

### A5. Các phép đo cho CV

**A5.1** "Dựng lại cả nền tảng trong 22 phút": đo thế nào? Vì sao không so với con số 14 phút 11 giây của phase GitOps?

**A5.2** Script dựng lại chạy không cần người. Nó xử lý những rủi ro gì mà người ngồi gõ lệnh vẫn tự xử lý?

**A5.3** "Cổng Trivy được kiểm bằng một build positive control": nghĩa là gì, và nó chứng minh tới đâu?

**A5.4** Lần thử positive control đầu tiên không thử được gì. Vì sao?

### A6. Sự cố và bài học

**A6.1** Kể các lần một phép kiểm "pass" trong khi thứ nó canh không đúng như vậy.

**A6.2** Sự cố nào của phase này bạn thấy đáng kể nhất?

### A7. Nhìn lại

**A7.1** Sau phase này, cái gì vẫn chưa được chứng minh?

**A7.2** Ở một công ty thật, bạn sẽ làm khác những gì?

---

## Phần B — Chi tiết

Đáp án ngắn, để tự kiểm. Căn cứ chính: `deploy/argocd/manifests/etcd-backup/cronjob.yaml`,
`deploy/argocd/manifests/kyverno-policies/verify-images.yaml`, `deploy/argocd/apps/kyverno*.yaml`,
`deploy/argocd/values/kyverno.yaml`, `infra/ansible/upgrade.yml`, `infra/scripts/timed-rebuild.sh`,
`docs/evidence/guide-measurements.md` và `docs/evidence/drills.md`.

### B1. CronJob snapshot

**B1.1** Giải thích `schedule`, `timeZone`, `concurrencyPolicy` và `startingDeadlineSeconds` trong CronJob.

**B1.2** Vì sao pod cần `hostNetwork`, và vì sao chỉ mount ba file chứng chỉ chứ không mount cả thư mục?

**B1.3** Image etcd được chọn và pin thế nào?

**B1.4** Vì sao container upload chạy bằng root? Vì sao `emptyDir` có `sizeLimit`?

### B2. Lệnh khôi phục

**B2.1** Kể sáu phase của lần khôi phục, và điều kiện để chuyển từ phase này sang phase kia.

**B2.2** Node không có `etcdutl`. Bạn chạy nó bằng cách nào?

**B2.3** `--name`, `--initial-advertise-peer-urls` và `--initial-cluster` lấy giá trị từ đâu? Pre-check kiểm cái gì?

**B2.4** Phase 2 hoặc phase 3 hỏng giữa chừng thì rollback thế nào?

### B3. Cài Kyverno

**B3.1** Values của chart đặt những gì, và vì sao?

**B3.2** Vì sao hai Application của Kyverno có cả `ServerSideApply=true` lẫn `ServerSideDiff=true`?

**B3.3** Vì sao cài controller và policy bằng hai commit riêng?

### B4. Policy

**B4.1** Kể các trường chính của `verify-images-prod` và tác dụng của từng trường.

**B4.2** Biểu thức CEL trong `validations` kiểm những image nào?

**B4.3** Đọc kết quả `Audit` ở đâu, và vì sao report mà không có dòng nào lại là kết quả nguy hiểm nhất?

### B5. `upgrade.yml`

**B5.1** Kể bốn play và việc của từng play.

**B5.2** Giữa hai node, playbook chờ những gì trước khi đi tiếp?

### B6. `timed-rebuild.sh`

**B6.1** Script kiểm tra những gì trước khi bắt đầu tính giờ, và trước khi apply?

**B6.2** Kể các pha được tính giờ, và điều kiện dừng đồng hồ.

**B6.3** `VERDICT PASS` đòi những gì? Khi script fail, nó báo gì cho người vận hành?

---

[Đáp án](answers.md) · [README](README.md) · [Concepts](concepts.md) · [Guide](guide.md) ·
[Evidence](../evidence/drills.md)
