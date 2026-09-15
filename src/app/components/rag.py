import time
from dataclasses import dataclass, field

from langchain_core.language_models import BaseChatModel
from langchain_core.output_parsers import StrOutputParser
from langchain_core.prompts import PromptTemplate
from langchain_core.retrievers import BaseRetriever

PROMPT = PromptTemplate.from_template(
    """Answer the following medical question in 2-3 lines maximum
using only the information provided in the context.
If the context does not contain the answer, say you don't know.

Context:
{context}

Question:
{question}

Answer:
"""
)


@dataclass
class RagAnswer:
    text: str
    retrieval_s: float
    llm_s: float
    usage: dict = field(default_factory=dict)


class RagChain:
    """Retrieval and generation are timed separately so each shows up in metrics."""

    def __init__(self, retriever: BaseRetriever, llm: BaseChatModel):
        self.retriever = retriever
        self.llm = llm
        self.generate = PROMPT | llm

    def answer(self, question: str) -> RagAnswer:
        t0 = time.perf_counter()
        docs = self.retriever.invoke(question)
        t1 = time.perf_counter()
        message = self.generate.invoke(
            {"context": "\n\n".join(d.page_content for d in docs), "question": question}
        )
        t2 = time.perf_counter()
        return RagAnswer(
            text=StrOutputParser().invoke(message),
            retrieval_s=t1 - t0,
            llm_s=t2 - t1,
            usage=dict(getattr(message, "usage_metadata", None) or {}),
        )


def build_chain() -> RagChain:
    from app.components.embeddings import get_embedding_model
    from app.components.llm import load_llm
    from app.components.vector_store import load_vector_store
    from app.config.config import INDEX_DIR, RETRIEVER_K

    db = load_vector_store(INDEX_DIR, get_embedding_model())
    return RagChain(db.as_retriever(search_kwargs={"k": RETRIEVER_K}), load_llm())
