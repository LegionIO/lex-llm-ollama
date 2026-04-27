# lex-llm-ollama

LegionIO LLM provider extension for Ollama.

This gem lives under `Legion::Extensions::Llm::Ollama` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

## What It Provides

- `LexLLM::Provider` registration as `:ollama`
- Ollama-native chat requests through `POST /api/chat`
- streaming chat support
- model discovery through `GET /api/tags`
- running model inspection through `GET /api/ps`
- model details through `POST /api/show`
- model download helper through `POST /api/pull`
- embeddings through `POST /api/embed`
- shared fleet/default settings via `Legion::Extensions::Llm.provider_settings`

## Defaults

```ruby
Legion::Extensions::Llm::Ollama.default_settings
# {
#   provider_family: :ollama,
#   instances: {
#     default: {
#       endpoint: "http://localhost:11434",
#       tier: :local,
#       transport: :http,
#       usage: { inference: true, embedding: true },
#       limits: { concurrency: 1 }
#     }
#   }
# }
```

## Configuration

```ruby
LexLLM.configure do |config|
  config.ollama_api_base = "http://localhost:11434"
  config.default_model = "qwen3.6:27b"
  config.default_embedding_model = "nomic-embed-text:latest"
end
```
