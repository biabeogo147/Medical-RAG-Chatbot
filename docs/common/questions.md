# Câu hỏi tổng quan về project

Bộ câu hỏi để giải thích project cho người phỏng vấn ở mức tổng quan: project làm gì, vì sao thiết kế như
vậy, kết quả ra sao và còn giới hạn gì. Câu hỏi không gói trong một công cụ. Đáp án nằm ở
[`answers.md`](answers.md), cùng số thứ tự.

Muốn đào sâu phần hạ tầng thì dùng bộ câu hỏi riêng của Terraform:
[`../terraform/questions.md`](../terraform/questions.md).

**Cách dùng.** Trả lời thành tiếng trong khoảng một phút mỗi câu, rồi so với đáp án. Các nhóm đi từ tổng quan
tới chi tiết, cuối cùng là khó khăn và bài học. Người phỏng vấn có thể nhảy cóc, nên mỗi đáp án tự đứng được.

---

## 1. Giới thiệu

**1.1** Giới thiệu project trong một phút.

**1.2** App này làm gì cho người dùng, và bên trong nó trả lời một câu hỏi như thế nào?

**1.3** Phần việc chính của bạn trong project là gì?

**1.4** Vì sao bạn làm project này, và bạn muốn chứng minh điều gì?

**1.5** Project gồm những phase nào, và bạn làm theo thứ tự nào?

**1.6** Bạn làm một mình hay theo nhóm? Mất bao lâu?

**1.7** Phần code app có phải bạn viết từ đầu không?

## 2. Kiến trúc tổng thể

**2.1** Mô tả kiến trúc tổng thể: có những thành phần nào và chúng nối với nhau ra sao?

**2.2** Một người dùng gõ câu hỏi. Request đi qua những đâu cho tới khi có câu trả lời?

**2.3** Terraform, Ansible, Argo CD và Jenkins mỗi công cụ lo phần nào? Vì sao phải chia ranh giới rõ như
vậy?

**2.4** Vì sao tự dựng Kubernetes bằng kubeadm trên EC2 mà không dùng EKS?

**2.5** App nhỏ như vậy có cần Kubernetes không?

**2.6** Môi trường dev và prod được tách ra thế nào?

## 3. Ứng dụng và dữ liệu

**3.1** Bản app ban đầu có những vấn đề gì khi đem ra chạy thật?

**3.2** FAISS index được tạo và quản lý thế nào? Muốn quay về index cũ thì làm sao?

**3.3** `/healthz` và `/readyz` khác nhau thế nào, và vì sao cần cả hai?

**3.4** App phụ thuộc Hugging Face và Gemini. Khi các API đó lỗi hoặc giới hạn tốc độ thì chuyện gì xảy ra?

**3.5** Bạn đã làm gì với Docker image, và kết quả đo được là gì?

**3.6** Vì sao dùng RAG mà không fine-tune model?

**3.7** Làm sao biết câu trả lời của chatbot là đúng? Có đánh giá chất lượng không?

**3.8** Dữ liệu y tế có vấn đề riêng tư không? Câu hỏi của người dùng có bị lưu hay gửi ra ngoài không?

## 4. Hạ tầng và cluster

**4.1** Nói ngắn gọn: hạ tầng trên AWS gồm những gì?

**4.2** Vì sao bạn xoá cluster khi không dùng, và dựng lại nhanh bằng cách nào?

**4.3** Bạn vào máy chủ và vào Kubernetes API bằng cách nào, khi không có SSH?

**4.4** Cluster chịu lỗi thế nào? Mất một node thì sao?

**4.5** Rancher được truy cập thế nào, và vì sao không mở nó ra internet?

**4.6** Traffic tăng gấp 10 lần thì hệ thống chịu thế nào? Scale ở đâu, nghẽn ở đâu?

## 5. CI/CD và GitOps

**5.1** Từ lúc push code tới lúc chạy trên prod, chuyện gì xảy ra?

**5.2** Vì sao tách CI (Jenkins) và CD (Argo CD)? Sao Jenkins không `kubectl apply` luôn?

**5.3** Bản mới trên prod bị lỗi thì rollback thế nào?

**5.4** Vì sao image được ghi bằng digest chứ không chỉ bằng tag?

**5.5** Jenkins chạy trong cluster thì build Docker image bằng cách nào?

**5.6** Jenkins commit ngược vào Git. Làm sao nó không tự chạy lại thành vòng lặp vô hạn?

**5.7** Vì sao chọn Jenkins mà không phải GitHub Actions hay GitLab CI?

**5.8** Đã có Argo CD và kubectl, sao còn cần Rancher?

## 6. Bảo mật

**6.1** Secret như API key đi từ đâu tới pod, và làm sao nó không lọt vào Git?

**6.2** Làm sao bạn chắc image đang chạy trên prod đúng là image đã được build, quét và ký?

**6.3** Những gì đang mở ra internet, và nguyên tắc bảo mật chung của project là gì?

**6.4** Project còn những điểm yếu bảo mật nào mà bạn biết?

## 7. Vận hành ngày 2 và quan sát

**7.1** Bạn theo dõi app và cluster thế nào? App xuất ra những metric gì?

**7.2** Backup và khôi phục cluster thế nào?

**7.3** Nâng cấp phiên bản Kubernetes thế nào mà không làm app ngừng?

**7.4** Làm sao chứng minh những gì bạn kể là đã chạy thật?

**7.5** App lỗi lúc 2 giờ sáng thì bạn biết bằng cách nào? Có alert không?

## 8. Chi phí và ràng buộc

**8.1** Project tốn bao nhiêu tiền, và bạn kiểm soát chi phí thế nào?

**8.2** Những ràng buộc nào đã định hình thiết kế?

## 9. Khó khăn và bài học

**9.1** Kể về vấn đề khó nhất bạn gặp và cách bạn tìm ra nguyên nhân.

**9.2** Nếu làm lại hoặc có thêm thời gian, bạn sẽ thay đổi gì?

**9.3** Project này khác gì so với một hệ thống production thật ở công ty?

**9.4** Bạn học được gì từ project này?
