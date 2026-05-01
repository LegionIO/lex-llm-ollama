# Changelog

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
