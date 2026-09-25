# Điều kiện đo

Trang tra cứu, đọc **trước** khi nói bất kỳ con số nào của project này.

Project này **không có bộ nhãn chế độ đo** kiểu `real` / `fake` như project Anime. Ở đây mọi phép đo chạy trên
thứ thật: Hugging Face thật, Gemini thật, cụm thật. Cái quyết định một con số có nghĩa đúng như nó nói hay
không là **điều kiện** nó được đo trong đó — và điều kiện được viết thành lời ngay cạnh con số, không thành
nhãn.

Nên câu trả lời cho "anh đo cái đó thế nào" ở project này có hai phần: **trạng thái** của phép đo, và **trục**
mà điều kiện nằm trên.

---

## 0. Sáu con số nói được ngay

Mở trang này để **kiểm điều kiện**, không phải để mất tự tin.

| Đo được | Giá trị | Điều kiện, một câu |
|---|---|---|
| RTO khôi phục etcd | **7 m 02 s** | tới mọi Application `Synced`+`Healthy`; một lần; có thời gian gõ ở trong |
| Rebuild cả nền tảng | **21 m 47 s** | treo tường, unattended, 17 Application, `CertificateRequest` = 0 |
| Chạy lại playbook | `changed=0` trong **2 m 56 s** | lần thứ hai trên cùng cụm |
| Pod created → Ready | **10 s** | thay cho 149 s build index; một pod; chính xác một giây |
| Memory request | **320 Mi** mỗi pod | từ đỉnh 276.9 MiB đo bằng Prometheus |
| CRITICAL sau đổi base | **5 → 0** | công của việc đổi sang Debian 13, không phải công của gate |

Ba phần còn lại của trang là **điều kiện** của những con số này — không phải một danh sách lỗi.

---

## 1. Trạng thái phép đo — năm giá trị

Đây là thứ gần nhất với một bộ nhãn có kiểm soát trong repo. Ba giá trị đầu nằm ở bảng đầu
[`evidence/drills.md`](../evidence/drills.md); `Pending` được định nghĩa ở `drills.md:11`; còn `Inferred` **không có trong
`drills.md`** — nó là chữ tôi dùng ở `jenkins.md:57`, `:197`, `:1116` và `gitops.md:72`.

| Trạng thái | Nghĩa | Ví dụ thật |
|---|---|---|
| **Measured** | Có số, đo được, điều kiện ghi rõ | RTO khôi phục etcd **7 m 02 s** |
| **Partially measured** | Đo được một nửa của điều tiêu chí đòi | Mức **tốt nhất** tiêu chí **#14** có thể đạt — repo tự ghi *"the best outcome here is partially measured"*, vì drill chỉ có đường patch, không có minor. Thực tế nó không đạt tới mức đó (dòng dưới) |
| **Not measured** | Chạy tới nơi rồi mà không có số, và biết vì sao | Tiêu chí #14: `1.36.4` đã là patch mới nhất, *"there is no patch to move to"*, nên playbook không chạy và #14 là **Not measured**. (Tiêu chí #13 Kyverno thì là **Measured**, nửa chữ ký.) |
| **Pending** | Chưa lấy, còn để trống có tên | Sau phase drills không còn ô nào: ô nào lấy được thì đã lấp, ô nào thuộc về cụm đã xoá (`PLAY RECAP` của lần rebuild 22/09) thì đổi thành *not recorded*, vì không lấy lại được nữa |
| **Inferred** | Suy ra, không đọc từ đâu cả — **phải nói là suy ra** | Memory allocatable ~7.8 GiB *"is **inferred** from the requests and their percentages"*; khoảng 48 s giải thích lần cấp lại chứng chỉ 18/09 là *"a derived figure, not one read off a clock"* |

**Câu nên nói:** *"Trong repo tôi tách năm trạng thái, và một con số suy ra thì tôi gọi nó là suy ra."* Đó là
lời mở đầu tốt cho mọi câu hỏi về số liệu, vì nó đặt trước cái khung mà người phỏng vấn sẽ dùng để chấm.

---

## 2. Mười trục điều kiện

Mỗi trục là một câu hỏi mà nếu không trả lời thì con số bị đọc sai.

**1 · Có người gõ trong lúc bấm giờ?** RTO 7 m 02 s — *"operator typing included"*. Rebuild 21 m 47 s —
*"unattended … no human prompt inside T"*. (`drills.md:24`, `:272`)

**2 · Thời gian chạy lệnh, hay treo tường?** 9 m 57 s là **cộng** hai giá trị `real`, và khoảng chờ SSM agent
*"was not timed"*. T = 21 m 47 s là **một** số treo tường. (`ansible.md:93–95` so với `guide-measurements.md:229`)

**3 · Cấu hình thật, hay cấu hình tạm?** Snapshot duy nhất từng chạy dưới cron **tạm** `*/15 * * * *`, không phải
`0 */6`. (`drills.md:103–105`, còn mở ở `:325–327`)

**4 · Positive control, hay pass thường?** Gate Trivy xanh **mọi lần từ đầu đến giờ** cũng không chứng minh nó biết
đỏ. Một lần **cố ý** làm nó đỏ thì mới chứng minh. (`guide-measurements.md:91–92`)

**5 · Request, hay mức dùng thật?** *"requests not yet promised, not idle capacity: there is no metrics-server"*.
(`jenkins.md:13`, `app.md:31`)

**6 · Lần đầu, hay lần chạy lại?** `make cluster` lần hai `changed=0` trong **2 m 56 s**, *"less than half the first
run"*. (`ansible.md:95`)

**7 · Local, hay trong cụm?** Build index **149.1 s** trong cụm so với **150.7 s** trên laptop — ở project này hai
bên **được phép** so, và evidence so thẳng. (`app.md:15`)

**8 · Trước, hay sau?** Supply chain: 4 CRITICAL / 14 HIGH / 8 MEDIUM là *"before"*; phần *"after"* nằm ở phase
Jenkins. (`app.md:17`)

**9 · Một lần, hay nhiều lần?** RTO 7 m 02 s: **một** lần. `changed=0` trên mọi host: **một** lần — lần 22/09 thì
`PLAY RECAP` còn *pending*. "Empty → Ready": một số đo, hai số cộng tay. (`drills.md`, `ansible.md`)

**10 · Cửa sổ quan sát nào?** Bảng memory có cột `Window`: *"last hour, before the questions"* so với *"last 30
minutes, including the ten questions"*. (`app.md:116–121`)

---

## 3. Bốn con số, và nghĩa đúng của chúng

Bốn con số này đều có thật. Mỗi cái đo **một thứ hẹp hơn** cái tên nó gợi ra — nói đúng phạm vi thì chúng là bằng
chứng, nói rộng ra một chữ thì chúng thành lỗ. Mỗi mục: đo được gì, không đo được gì, và câu nói.

### 3.1 `1 m 18 s` — con số của một phép kiểm pass sai

Lần rebuild Part 0 ngày 22/09, bước 5: vòng chờ trả về sau **1 m 18 s**. Con số đó **vô giá trị**, và evidence
nói thẳng vì sao:

> **The wait passed falsely**: `root` read `Healthy` for a moment before its waves ran, and the wait caught that
> moment. … **The rebuild time for step 5 was therefore not measured on this run**; the 1 m 18 s is when the wait
> returned, not when the platform was up.
> — `drills.md:55–67`

**Nói:** *"Phép kiểm ấy pass sai, nên lần đó tôi không có số — và chính chỗ đó dẫn tới việc sửa health check
thành đòi cả `Healthy` và `Synced`."* Đây là điều kiện hợp lệ **đã trượt**, và nói ra nó là điểm mạnh: nó là
nguồn gốc của một bản sửa thật.

### 3.2 `14 m 11 s` — không so với 22 phút

> Not comparable with the 14 m 11 s of 2026-09-18, which had 9 Applications and a health-only wait
> — `drills.md:272`

Lần 18/09 có **9** Application, không có Jenkins, không có app, và vòng chờ chỉ đọc health nên trả về sớm. Nếu
ai đọc repo thấy 14 m 11 s rồi thấy 22 phút trên CV thì CV **trông tệ hơn**, không tốt hơn.

Và lý do thứ tư, thuộc đúng trục 2 ở trên: **14 m 11 s là tổng bốn thời gian lệnh** (`gitops.md:20`), còn
21 m 47 s là **một** số treo tường. Hai loại số khác nhau — nên còn không so được về mặt đơn vị, chưa nói tới phạm vi.

**Nói:** *"14 phút đó là cụm khác, và còn là loại số khác: nó là tổng bốn thời gian lệnh, ít Application hơn, chưa có
Jenkins, và vòng chờ trả về sớm. Số so được là 21 m 47 s treo tường."*

### 3.3 "Gate Trivy đã bắt được một CRITICAL" — chưa bao giờ

> **Trap:** this proves the gate's **mechanism** fails a build. It does not show a CRITICAL was ever caught.
> — `guide-measurements.md:91–92`

Để tạo ra lần fail, gate bị **nới** từ chỉ-CRITICAL sang mọi severity, trên một nhánh bỏ đi. Và cái làm CRITICAL
từ 5 về 0 là **đổi base image sang Debian 13**, thứ mà gate về cấu trúc *không thể* làm được:

> **And the gate could never have done this.** It reported `0` both before and after, correctly: every one of the
> five had an empty `Fixed Version` *in Debian 12*.
> — `jenkins.md:576–580`

**Nói:** *"Gate được chứng minh là biết đỏ, bằng một positive control. Còn 5 về 0 thì là công của việc đổi base
— gate chỉ đếm lỗ hổng **có bản vá**, và năm cái đó không có bản vá nào trong Debian 12."* Volunteer chỗ này
thì nó thành hiểu biết, để bị hỏi ra thì thành lỗ.

### 3.4 Lịch 6 giờ — cấu hình đã đọc lại, lần nổ chưa quan sát

Snapshot duy nhất từng được quan sát đến từ cron **tạm** `*/15`. Chuỗi `0 */6 * * *` có trong Git và đã đọc lại
trên cụm, nhưng **chưa lần nào thấy nó nổ**:

> **A job created by the 6-hourly schedule itself.** The first proven run was under the temporary `*/15` string.
> — `drills.md:325–327`

**Nói:** *"'Mỗi 6 giờ' là cấu hình. Phép đo là: một snapshot theo lịch, kiểm toàn vẹn, upload, rồi restore
được."* Và RPO ≤ 6 h là **bound thiết kế** — chưa đối chiếu hai snapshot liên tiếp, vì chỉ có một.

---

## 4. Ba con số phải nói kèm điều kiện, không thì bị bắt

| Con số | Điều kiện phải nói kèm |
|---|---|
| **9 m 57 s** "empty → Ready" | Là **tổng hai thời gian lệnh**, không phải treo tường; khoảng chờ SSM agent bị loại ra. Và `guide-measurements.md:229` viết *"Do not sum the commands' own times"*. Hai lần sau **không có số "empty → Ready" nào được ghi**; cộng tay từ evidence ra **10 m 13 s** (`drills.md:47`) và **10 m 03 s** (`drills.md:272`) — cả hai là **số suy ra**, và phải nói là suy ra. Nói: *"chín năm mươi bảy là số đo; hai lần sau tôi cộng tay ra khoảng mười phút."* |
| **7 m 02 s** RTO | Đo tới **mọi Application `Synced`+`Healthy` với `reconciledAt > t1`, Lease của node đã gia hạn, và không pod nào ngoài Running/Completed** — cố ý không đo tới "etcd đã lên". Bao gồm thời gian gõ, và **tới ~3 phút trong đó có thể là một chu kỳ reconcile của Argo CD**. Một lần. |
| **960 Mi / 2 304 Mi** | Là **request**, không phải mức dùng. Và mốc 2 304 Mi là một **phỏng đoán** trước đó (*"Before, the guesses were 768Mi to 1,536Mi"*), không phải một phép đo. |

---

## 5. Hai giới hạn đã biết, nói trước khi bị hỏi

Hai chỗ này tôi tìm ra **khi chạy** và ghi ngay vào evidence. Nói trước thì chúng là bằng chứng rằng tôi đọc kết
quả của chính mình; để bị hỏi ra thì chúng thành lỗ.

- **`kubectl delete pod` không hỏi PodDisruptionBudget.** Chỉ eviction mới hỏi. Lệnh trong guide xoá **theo
  label** nên xoá cả hai pod prod cùng lúc, hai lần. *"The guide's claim that this is safe because of the budget
  is wrong. Whether prod actually refused requests in those seconds was not measured."* (`drills.md:224–229`).
  Guide đã sửa thành xoá **từng pod theo tên**.
- **Bước 18 không thể đỏ được từ chính nó.** Vai node đã ngoài tầm pod Jenkins từ trước, vì NetworkPolicy ở
  bước 6 đã chặn `169.254.169.254/32`. *"A green build shows the exchange still works; it could not have gone red
  from step 18 alone."* (`jenkins.md:1064–1068`). Cái bước 18 đổi là **mọi pod khác** trong cụm — và đó đúng là
  thứ phép kiểm ở namespace `default` đo.

---

[Dòng CV](cv-lines.md) · [Kiến trúc](architecture.md) · [Thuật ngữ](glossary.md) ·
[Bộ đề](../common/questions.md) · [Evidence](../evidence/)
