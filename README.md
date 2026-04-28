# lex-llm-ollama

LegionIO LLM provider extension for Ollama.

This gem lives under `Legion::Extensions::Llm::Ollama` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

Load it with `require 'legion/extensions/llm/ollama'`.

## What It Provides

- `Legion::Extensions::Llm::Provider` registration as `:ollama`
- Ollama-native chat requests through `POST /api/chat`
- streaming chat support
- model discovery through `GET /api/tags`
- running model inspection through `GET /api/ps`
- model details through `POST /api/show`
- model download helper through `POST /api/pull`
- embeddings through `POST /api/embed`
- best-effort `llm.registry` availability events from readiness and model discovery when Legion Transport is loaded
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
Legion::Extensions::Llm.configure do |config|
  config.ollama_api_base = "http://localhost:11434"
  config.default_model = "qwen3.6:27b"
  config.default_embedding_model = "nomic-embed-text:latest"
end
```
