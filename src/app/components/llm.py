from langchain_google_genai import ChatGoogleGenerativeAI

from app.config.config import GOOGLE_API_KEY, LLM_TIMEOUT_S, MODEL_NAME


def load_llm(model_name: str = MODEL_NAME, api_key: str | None = GOOGLE_API_KEY):
    if not api_key:
        raise RuntimeError("GOOGLE_API_KEY is not set")
    return ChatGoogleGenerativeAI(
        model=model_name,
        google_api_key=api_key,
        timeout=LLM_TIMEOUT_S,
        max_retries=1,
    )
