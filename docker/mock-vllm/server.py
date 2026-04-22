from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="mock-vllm")


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    model: str
    messages: list[ChatMessage]
    temperature: float | None = None
    max_tokens: int | None = None


@app.get("/v1/models")
def models():
    return {"data": [{"id": "qwen-coder", "object": "model"}], "object": "list"}


@app.post("/v1/chat/completions")
def chat(req: ChatRequest):
    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "model": req.model,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "Mock response from offline e2e vLLM replacement.",
                },
                "finish_reason": "stop",
            }
        ],
    }
