from app.config.config import *
from app.common.logger import get_logger
from app.common.custom_exception import CustomException
from langchain_huggingface import HuggingFaceEndpointEmbeddings

logger = get_logger(__name__)


def get_embedding_model():
    try:
        logger.info("Initializing our Huggingface embedding model")

        model = HuggingFaceEndpointEmbeddings(
            repo_id=EMBEDDING_MODEL_NAME,
            huggingfacehub_api_token=HUGGINGFACEHUB_API_TOKEN,
        )

        logger.info("Huggingface embedding model loaded successfully....")

        return model
    
    except Exception as e:
        error_message=CustomException("Error occurred while loading embedding model", e)
        logger.error(str(error_message))
        raise error_message