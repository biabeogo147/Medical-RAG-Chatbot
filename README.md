> **Source & Credits**: Based on [https://github.com/data-guru0/RAG-MEDICAL-CHATBOT], customized for this project.


```bash
kubectl create secret generic medical-rag-chatbot-secret \
  --from-literal=GOOGLE_API_KEY="$GOOGLE_API_KEY" \
  --from-literal=HUGGINGFACEHUB_API_TOKEN="$HUGGINGFACEHUB_API_TOKEN" \
  -n medical-rag-chatbot \
  --dry-run=client -o yaml | kubectl apply -f -
```