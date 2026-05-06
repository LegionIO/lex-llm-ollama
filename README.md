# lex-llm-ollama

LegionIO LLM provider extension for [Ollama](https://ollama.ai).

This gem lives under `Legion::Extensions::Llm::Ollama` and depends on `lex-llm >= 0.4.3` for shared provider-neutral routing, response normalization, fleet envelopes, responder execution, transport, and registry primitives. It does not carry a runtime `legion-llm` dependency; `legion-llm` owns higher-level routing and can discover this provider through normal extension loading.

Load it with `require 'legion/extensions/llm/ollama'`.

## What It Provides

- Ollama-native chat requests through `POST /api/chat`
- Streaming chat support
- Model discovery through `GET /api/tags` with automatic embedding capability inference
- Running model inspection through `GET /api/ps`
- Model details through `POST /api/show`
- Model download helper through `POST /api/pull`
- Embeddings through `POST /api/embed`
- Best-effort `llm.registry` availability events via the shared `Legion::Extensions::Llm::RegistryPublisher`
- Local socket discovery plus configured instance discovery through the shared `lex-llm` credential sources
- Provider-owned fleet response handling through `Legion::Extensions::Llm::Fleet::ProviderResponder`
- Full `Legion::Logging::Helper` integration with structured `handle_exception` in every rescue block

## Architecture

```
Legion::Extensions::Llm::Ollama
├── Provider                   # Ollama provider (chat, stream, embed, models, readiness)
├── Actor::FleetWorker         # Optional provider-owned fleet subscription actor
├── Runners::FleetWorker       # Delegates fleet execution to lex-llm
└── (shared from lex-llm)
    ├── Fleet::ProviderResponder
    ├── RegistryPublisher
    ├── RegistryEventBuilder
    └── Transport/
```

## Defaults

```ruby
Legion::Extensions::Llm::Ollama.default_settings
# {
#   enabled: true,
#   provider_family: :ollama,
#   instances: {
#     default: {
#       endpoint: 'http://127.0.0.1:11434',
#       default_model: 'qwen3.5:latest',
#       tier: :local,
#       transport: :http,
#       credentials: {},
#       usage: { inference: true, embedding: true, image: false },
#       limits: { concurrency: 1 },
#       fleet: {
#         enabled: false,
#         respond_to_requests: false,
#         capabilities: %i[chat stream_chat embed],
#         lanes: [],
#         concurrency: 1,
#         queue_suffix: nil
#       }
#     }
#   }
# }
```

## Configuration

`discover_instances` returns a local `http://127.0.0.1:11434` instance when the Ollama socket is reachable. Additional instances can be supplied under the shared LLM extension configuration and may use `base_url`, `endpoint`, `api_base`, or `ollama_api_base`; the extension normalizes those aliases to `base_url`.

```yaml
extensions:
  llm:
    ollama:
      instances:
        lab:
          base_url: http://ollama-lab:11434
          default_model: qwen3.5:latest
```

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one discovered instance enables `respond_to_requests`, and the runner delegates execution to the shared `lex-llm` responder helper.

```yaml
extensions:
  llm:
    ollama:
      instances:
        local:
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
```

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

## License

MIT
