# Changelog

## [0.3.2] - 2026-08-13

### Fixed
- **§1 settings access via .dig:** `api_base` now reads `settings[:instances][:default][:endpoint]` using bracket notation instead of the prohibited `.dig` form.
- **§9 default model substitution removed:** `translator.rb` `render_request` no longer falls back to `'default'` when model is absent from request metadata; the field is omitted (compacted) so the exact selected model must be provided by the executor.
- **§1 swallowed rescue fixed:** `extract_host_port` in the discovery actor now calls `handle_exception` and re-raises on `URI::InvalidURIError` instead of silently returning `'unknown:0'`.
- **§1 swallowed rescue fixed:** `check_readiness` rescues now call `handle_exception` (with `handled: true`) before constructing the `ReadinessResult`, preserving the log audit trail.
- **§1 cop strictness reverted:** `RSpec/MultipleMemoizedHelpers: Max: 7` removed from `.rubocop.yml`; conformance spec refactored to comply with the default maximum of 5 memoized helpers per context.

## [0.3.1] - 2026-08-13

### Fixed
- **§8 health firewall:** Connection failures, timeouts, and 5xx errors stay request-local and never map to `:instance_unavailable`. Only an explicit flat service-unavailable wire signal maps to that outcome.
- **§9 no `:default` substitution:** `offering_from_model` derives a stable `instance_id` from the configured endpoint URL (`host:port`) instead of substituting the `:default` symbol.
- **§1 rubocop:disable removed:** All `rubocop:disable` comments removed from source and spec files; underlying causes fixed.
- **§1 swallowed rescue fixed:** `coordinator.finish_probe` failure now logged with `handle_exception` rather than silently swallowed.
- **§1 settings path corrected:** `api_base` reads `settings.dig(:instances, :default, :endpoint)` instead of the non-existent top-level `settings[:endpoint]`, preventing invalid base URL construction.
- **§2/§5 second publication engine removed:** `readiness` and `discover_live_offerings` no longer call `registry_publisher.publish_readiness_async` or `publish_models_async`; the SSOT v3 actor is the sole publication path.
- **Provider capabilities corrected:** `vision?`, `functions?`, `embedding?` return `false` (not `true`) as the static predicate; evidence-based values are derived per-model by the discovery actor.
- **Settings `embedding: true` removed:** Blanket embedding capability removed from usage defaults; embedding is declared per-model by the discovery actor based on `/api/tags` family evidence.

## [0.3.0] - 2026-08-13

### Changed
- **SSOT v3 provider migration.** Replace legacy `ScopedRefresher`/`Legion::LLM::Call::Registry` discovery with direct `Inventory::Publisher` claim/activate/replace lifecycle using the lex-llm 0.7.0 runtime contract.
- Discovery actor now claims exact Ollama instances, builds complete `OfferingDraft` snapshots from `/api/tags` and `/api/show`, and probes readiness via `/api/tags` (non-inference, no model load).
- Per-model operation evidence: chat/stream_chat always supported, embed supported only for embedding models, image/transcribe/translate/speak/moderate unsupported, count_tokens unknown.
- Per-model capability evidence from `/api/show` response (tools, thinking, vision) with honest unknown when unavailable.
- Remove `default_model: 'qwen3.5:latest'` from settings. Omitted model reaches the router unconstrained; provider invocation receives the exact selected model.
- Stable InstanceKey derivation: `host:port` from the configured endpoint URL.
- Normalized dispatch errors: connection failure stays `connection_failure`, 503 stays `overloaded`, timeouts stay `timeout`. No raw status code produces `instance_unavailable`.
- Graceful shutdown removes all claimed instances.
- Raise gemspec floor to `lex-llm >= 0.7.0`.

### Added
- `OllamaCallable` wrapper implementing `disconnect` and `normalize_dispatch_error(error:)` for the SSOT callable contract.
- SSOT v3 conformance spec exercising shared provider examples.

## [0.2.25] - 2026-08-04

### Changed
- Prepare the Ollama provider baseline for a patch release.

## [0.2.24] - 2026-07-24

### Fixed
- **Translator propagates `done_reason` and usage through content chunks.** When ollama sends `done: true` on a chunk that also has content, the stop_reason and usage were previously lost. Now extracts them before branching and passes through to whatever chunk type is emitted.

## [0.2.23] - 2026-07-05

### Changed
- Stop_reason mapping now uses the shared `Legion::Extensions::Llm::StopReasonMapping` mixin from lex-llm (>= 0.6.9) instead of a local `OLLAMA_STOP_REASON_MAP` (a copy of the same drifting 3-entry map vLLM carried). The shared vocabulary maps `tool_calls`/`tool_use`/`function_call` to `:tool_use` (plus `stop`/`end_turn`/`eos`, `length`/`max_tokens`, `stop_sequence`, `content_filter`) and is inherited by every provider so it no longer drifts per gem. Ollama's `done_reason`-to-stop_reason resolution is unchanged in behavior.

## [0.2.22] - 2026-06-20

### Fixed
- Stub shared registry publishing through `RegistryPublisher#schedule` in specs so async availability-event coverage stays stable after the shared publisher moved off raw `Thread.new`.

## [0.2.21] - 2026-06-20

### Fixed
- Stop bulk-publishing Ollama model availability from `list_models`; discovery now emits one registry event per seen model from the shared `lex-llm` policy-filter path so blocked models stay observable without duplicate publishes.

## [0.2.20] - 2026-06-20

### Changed
- Slow the live discovery refresh cadence from 60 seconds to 300 seconds for Ollama instances; `extensions.llm.ollama.discovery_interval` still overrides the default.

## [0.2.19] - 2026-06-20

### Fixed
- Route Ollama capability overrides through the shared `lex-llm` provider contract and preserve the canonical singular `:embedding` capability on embedding offerings.

## [0.2.18] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.2.17 - 2026-06-16

- dependency updates, code quality improvements

## 0.2.16 - 2026-06-15

- **CapabilityPolicy integration** — Optional capabilities default false; API-provided capabilities tagged as `:model_metadata`. Settings overrides at provider/instance/model level supported.

## 0.2.15 - 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **Canonical tool support** — Use `ToolSchema.extract`, add `:tools` capability, canonical normalization for tool parameter schemas.
- 147 examples, 0 failures; 17 files, 0 rubocop offenses.

## 0.2.14 - 2026-06-05

- Verified specs and RuboCop compliance (52 examples, 0 failures; 15 files, 0 offenses)
- Updated README with comprehensive extension index covering architecture, classes, configuration, and usage

## 0.2.13 - 2026-06-02

- **Scope discovery refresh to Ollama only** — `DiscoveryRefresh#manual` now calls `Discovery.refresh_discovered_models!(provider: :ollama)` instead of `Discovery.run`, which previously triggered model discovery for all registered providers (anthropic, bedrock, etc.) and caused cross-provider coupling

## 0.2.12 - 2026-05-21

- Add `default_transport`/`default_tier` class declarations, remove duplicate instance methods
- Add `model_allowed?` filtering in `discover_offerings`
- Add `DiscoveryRefresh` actor (Every, 30min, run_now) for non-blocking model discovery
- Identity headers included via base provider
- api_base reads from settings[:endpoint] fallback


## 0.2.10 - 2026-05-16

- Stop assuming every non-embedding Ollama model supports tools; fallback chat discovery now advertises completion, streaming, and vision only.
- Add canonical Ollama capability normalization so reported `tools`/function-calling metadata is preserved and streaming is inferred for chat/completion models.
- Include reported capability metadata from `/api/show` model detail responses.

## 0.2.9 - 2026-05-13

- Add `fetch_model_detail` — calls POST `/api/show` to retrieve the real context window from Ollama.
- Add `resolve_context_window` — tries live model detail cache first, falls back to static prefix map.
- Add `extract_context_window` — parses `num_ctx` from `model_info` hash or `parameters` string in the `/api/show` response.
- Add `CONTEXT_WINDOWS` static fallback map covering common Ollama model families.
- Add `rescue Faraday::ConnectionFailed` in `discover_offerings` with a concise warn log instead of an unhandled exception.
- Add `show_model_url` endpoint helper returning `/api/show`.

## 0.2.8 - 2026-05-12

- Include `Legion::Logging::Helper` directly in Ollama provider, actor, and fleet runner runtime surfaces.
- Add sanitized debug logging for provider discovery, payload rendering, tool formatting, embeddings, offerings, and fleet handoff.

## 0.2.7 - 2026-05-07

- Render Ollama embedding payloads with the canonical model id when callers pass `Model::Info` objects.

## 0.2.6 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical Ollama provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Preserve configured transport and tier metadata when Ollama builds routing offerings.
- Gate release publishing on the shared security workflow.

## 0.2.5 - 2026-05-06

- Mark cached offering discovery fallback exceptions as handled.
- Refresh README provider contract, fleet responder, development gate, and license details.

## 0.2.4 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.

## 0.2.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

## 0.2.2 - 2026-05-06

- Add provider contract specs for the shared keyword-only `lex-llm` provider API.
- Move Ollama defaults back to `Legion::Extensions::Llm.provider_settings` with instance-level fleet responder settings.
- Serve non-live Ollama offering reads from cached live model discovery instead of probing the configured endpoint.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.2.1 - 2026-05-03

- Normalize configured Ollama instance endpoint aliases to `base_url`.
- Use instance `base_url` config before provider defaults.

## 0.2.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## 0.1.7 - 2026-04-30

- Provider contract overhaul: adopt lex-llm >= 0.1.9 base contract.
- Replace `default_settings` with full schema (enabled, base_url, default_model, whitelist/blacklist, model_cache_ttl, tls, instances).
- Remove `Provider.register` call; providers are now discovered via the extension registry.
- Delete local `RegistryPublisher`, `RegistryEventBuilder`, and `Transport/` directory; use shared classes from lex-llm base.
- Replace `config.ollama_api_base` with `resolve_base_url` multi-host resolution from the base provider contract.
- Enrich `parse_list_models_response` to infer embedding capabilities and modalities from model name and family.
- Add `settings` and `config_base_url` accessors to the provider for whitelist/blacklist and base URL resolution support.

## 0.1.6 - 2026-04-30

- Add `Legion::Logging::Helper` to Ollama module, RegistryPublisher, and RegistryEventBuilder.
- Replace all bare rescue blocks with `handle_exception` calls including level, handled, and operation.
- Add info-level action logging to Provider key actions: list_running_models, readiness, list_models, show_model, pull_model.
- Add info-level logging to RegistryPublisher publish methods.
- Add rescue-with-handle_exception to Provider#list_running_models, show_model, and pull_model.
- Update README to reflect current architecture and file layout.

## 0.1.5 - 2026-04-28

- Publish best-effort provider/model availability events to `llm.registry` from Ollama readiness and model discovery.

## 0.1.4 - 2026-04-28

- Require current shared Legion JSON, logging, settings, and LLM extension gems.

## 0.1.3 - 2026-04-28

- Remove the leftover compatibility entrypoint outside the Legion namespace.
- Load specs through the canonical `legion/extensions/llm/ollama` namespace path.
- Keep provider gemspec dependencies scoped to the shared `lex-llm` base gem.

## 0.1.2 - 2026-04-28

- Replace fork-era namespace references with the standard Legion::Extensions::Llm provider contract.
- Remove GitHub-based lex-llm Gemfile fallback so test installs use only a guarded local path or released gem dependency.
- Require lex-llm >= 0.1.3 for the cleaned Legion-native base extension.

## 0.1.1 - 2026-04-27

- Add the Ollama Legion::Extensions::Llm provider class with chat, streaming, model listing, running-model inspection, model details, pulls, and embeddings helpers.
- Use shared `Legion::Extensions::Llm.provider_settings` defaults from `lex-llm`.
- Remove the committed `Gemfile.lock`.

## 0.1.0 - 2026-04-26

- Initial Legion LLM Ollama provider extension scaffold.
