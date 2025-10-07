from app.config.config import *
from app.common.logger import get_logger
from app.common.custom_exception import CustomException
from langchain_google_genai import ChatGoogleGenerativeAI

logger = get_logger(__name__)


def load_llm(model_name: str = MODEL_NAME, api_key: str = GOOGLE_API_KEY):
    try:
        logger.info("Loading LLM from HuggingFace")

        llm = ChatGoogleGenerativeAI(model=model_name, google_api_key=api_key)

        logger.info("LLM loaded successfully...")

        return llm
    
    except Exception as e:
        error_message = CustomException("Failed to load a llm" , e)
        logger.error(str(error_message))