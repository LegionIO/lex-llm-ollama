# lex-llm-ollama

LegionIO LLM provider extension for [Ollama](https://ollama.ai).

This gem lives under `Legion::Extensions::Llm::Ollama` and depends on `lex-llm >= 0.4.3` for shared provider-neutral routing, response normalization, fleet envelopes, responder execution, transport, and registry primitives. It does not carry a runtime `legion-llm` dependency; `legion-llm` owns higher-level routing and discovers this provider through normal extension loading.

Load it with `require 'legion/extensions/llm/ollama'`.

## What It Provides

| Feature | Endpoint | Provider Method |
|---------|----------|----------------|
| Chat completion | `POST /api/chat` | Inherited from `Lex-llm` base provider |
| Streaming chat | `POST /api/chat` | `stream_response` |
| List models | `GET /api/tags` | `list_models` |
| Running models | `GET /api/ps` | `list_running_models` |
| Model details | `POST /api/show` | `show_model`, `fetch_model_detail` |
| Pull models | `POST /api/pull` | `pull_model` |
| Embeddings | `POST /api/embed` | Inherited from `Lex-llm` base provider |
| Readiness check | `GET /api/version` | `readiness(live: false)` |

All responses pass through the shared `Lex-llm` normalization layer: `Message`, `Chunk`, `Embedding`, and `Model::Info`.

## File Index

```
lib/
  legion/extensions/llm/ollama.rb              # Extension entry point, instance discovery, default settings
  legion/extensions/llm/ollama/provider.rb     # Provider — chat, stream, embed, models, offerings
  legion/extensions/llm/ollama/version.rb      # VERSION constant
  legion/extensions/llm/ollama/actors/
    discovery_refresh.rb                       # Periodic model discovery actor (Every, 30min default)
    fleet_worker.rb                            # Fleet request subscription actor (Subscription)
  legion/extensions/llm/ollama/runners/
    fleet_worker.rb                            # Fleet request execution runner (delegates to lex-llm)
```

## Architecture

```
Legion::Extensions::Llm::Ollama
├── Provider                          # Ollama provider implementation
│   ├── Capabilities                  # Capability predicates (chat, streaming, vision, functions, embeddings)
│   ├── #render_payload               # Build Ollama chat payload from messages, tools, schema
│   ├── #stream_response              # NDJSON streaming via Faraday on_data
│   ├── #discover_offerings           # Build ModelOffering array from live/cached models
│   ├── #fetch_model_detail           # Call /api/show, extract context_window + capabilities
│   ├── #render_embedding_payload     # Build Ollama embedding payload
│   └── (inherited from lex-llm)      # Chat, embedding, connection, registry helpers
├── Actor::DiscoveryRefresh           # Every actor; refreshes model list, repopulates auto rules
├── Actor::FleetWorker                # Subscription actor; gates on respond_to_requests
└── Runners::FleetWorker              # Module function; delegates to ProviderResponder.call

Shared from lex-llm:
├── Fleet::ProviderResponder          # Fleet request execution harness
├── RegistryPublisher                 # Publishes readiness + model events to llm.registry
├── RegistryEventBuilder              # Builds registry event payloads
├── AutoRegistration                  # Self-registers discovered instances
└── CredentialSources                 # Socket probing + setting lookup for instance discovery
```

## Key Classes

### `Legion::Extensions::Llm::Ollama` (module)

- **`default_settings`** — Returns the full settings schema via `Lex-llm.provider_settings`.
- **`provider_class`** — Returns `Provider`.
- **`discover_instances`** — Probes `127.0.0.1:11434` socket + reads configured instances from settings.
- **`normalize_instance_config(config)`** — Normalizes `endpoint`/`api_base`/`ollama_api_base` aliases to `base_url`.
- **`registry_publisher`** — Lazily instantiated `RegistryPublisher` for the `:ollama` family.

### `Provider`

Extends `Legion::Extensions::Llm::Provider`. Implements the Ollama-specific contract:

| Method | Purpose |
|--------|---------|
| `api_base` | Resolves base URL from `resolve_base_url`, settings, or default `127.0.0.1:11434` |
| `completion_url` | `/api/chat` |
| `stream_url` | `/api/chat` |
| `models_url` | `/api/tags` |
| `running_models_url` | `/api/ps` |
| `show_model_url` | `/api/show` |
| `embedding_url` | `/api/embed` |
| `pull_url` | `/api/pull` |
| `version_url` | `/api/version` |
| `list_running_models` | GET `/api/ps`, returns array of running model hashes |
| `readiness(live:)` | Checks Ollama version endpoint; publishes readiness event when `live: true` |
| `list_models` | GET `/api/tags`, parses and publishes model events via registry |
| `show_model(model)` | POST `/api/show`, returns raw model detail hash |
| `fetch_model_detail(model)` | Wraps `show_model`; extracts `context_window` and `capabilities` |
| `pull_model(model, stream:)` | POST `/api/pull` to download a model |
| `discover_offerings(live:)` | Builds `ModelOffering` array from live or cached models |
| `render_payload(...)` | Converts Legion messages/tools to Ollama NDJSON format |
| `stream_response(conn, payload)` | Posts with Faraday `on_data` handler for NDJSON streaming |
| `parse_completion_response(resp)` | Normalizes Ollama chat response to `Legion::Extensions::Llm::Message` |
| `build_chunk(data)` | Normalizes a stream NDJSON line to `Legion::Extensions::Llm::Chunk` |
| `render_embedding_payload(text, model:, dimensions:)` | Builds embedding request body |
| `parse_embedding_response(resp, ...)` | Normalizes embedding response to `Legion::Extensions::Llm::Embedding` |

### `Capabilities` (module inside Provider)

Module functions providing capability predicates used during offering construction:

| Method | Always Returns |
|--------|---------------|
| `chat?(model)` | `true` |
| `streaming?(model)` | `true` |
| `vision?(model)` | `true` |
| `functions?(model)` | `true` |
| `embeddings?(model)` | `true` |

### `CONTEXT_WINDOWS` (constant)

Static fallback map keyed by model name prefix (e.g., `'qwen3' => 128_000`). Used when `/api/show` is unavailable to infer context window. Covers qwen, llama, gemma, mistral, deepseek, phi, command-r, codellama, and embedding families.

### `Actor::DiscoveryRefresh`

An `Every` actor that runs every 30 minutes (configurable via `settings[:extensions][:llm][:ollama][:discovery_interval]`). On each tick:

1. Calls `Legion::LLM::Discovery.refresh_discovered_models!(provider: :ollama)`
2. Repopulates auto routing rules if `Legion::LLM::Router` is available
3. Invalidates the offerings cache if `Legion::LLM::Inventory` is available

### `Actor::FleetWorker`

A `Subscription` actor that starts only when at least one instance has `fleet.respond_to_requests: true`. Routes messages to the fleet worker runner.

### `Runners::FleetWorker`

A module with `handle_fleet_request(payload, delivery:, properties:)`. Delegates to `Legion::Extensions::Llm::Fleet::ProviderResponder.call` with the Ollama provider family, provider class, and instance discovery lambda.

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

### Instance Discovery

`discover_instances` auto-detects a local instance when the socket at `127.0.0.1:11434` is reachable. Additional instances can be defined in settings using any of the recognized endpoint aliases (`base_url`, `endpoint`, `api_base`, `ollama_api_base`); the extension normalizes all to `base_url`.

```yaml
extensions:
  llm:
    ollama:
      discovery_interval: 1800          # DiscoveryRefresh actor interval (seconds)
      instances:
        lab:
          base_url: http://ollama-lab:11434
          default_model: qwen3.5:latest
```

### Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The fleet actor only starts when at least one instance enables `respond_to_requests`, and the runner delegates execution to the shared `lex-llm` responder helper.

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

## Ollama API Surface

| Legion Method | Ollama Route | HTTP Verb |
|---------------|-------------|-----------|
| Chat | `/api/chat` | POST |
| Stream chat | `/api/chat` | POST |
| List models | `/api/tags` | GET |
| Running models | `/api/ps` | GET |
| Model details | `/api/show` | POST |
| Pull model | `/api/pull` | POST |
| Embeddings | `/api/embed` | POST |
| Readiness | `/api/version` | GET |

## Error Handling

Every rescue block uses `handle_exception` from `Legion::Logging::Helper` with explicit `level`, `handled:`, and `operation:` parameters. Connection failures during `discover_offerings` produce a warn-level log and return an empty array (never raise).

## Usage

```ruby
require 'legion/extensions/llm/ollama'

# Access the module
Legion::Extensions::Llm::Ollama.discover_instances
Legion::Extensions::Llm::Ollama.default_settings

# Create a provider instance (usually done by lex-llm routing)
provider = Legion::Extensions::Llm::Ollama::Provider.new(config:)

# Discover offerings
provider.discover_offerings(live: true)

# Chat
result = provider.chat(messages: [...], model: 'llama3', temperature: 0.7)

# Stream chat
provider.stream_chat(messages: [...], model: 'llama3') do |chunk|
  print chunk.content
end

# Embeddings
embeddings = provider.embed(text: "Hello world", model: 'nomic-embed-text')
```

## Dependencies

| Gem | Minimum Version | Purpose |
|-----|----------------|---------|
| `lex-llm` | `>= 0.4.3` | Base provider contract, routing, fleet responder, registry, credential sources |
| `legion-transport` | `>= 1.4.14` | Faraday connection management |
| `legion-json` | — | JSON serialization (`Legion::JSON`) |
| `legion-logging` | — | Structured logging (`Legion::Logging::Helper`) |
| `legion-settings` | — | Configuration access |
| `legion-extensions` | — | Extension framework (`Core`, `Actors::Every`, `Actors::Subscription`) |

## Development

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ollama
bundle install

# Run specs
bundle exec rspec

# Lint (auto-correct)
bundle exec rubocop -A
```

Spec count: 52 examples across 7 spec files.

## License

MIT
