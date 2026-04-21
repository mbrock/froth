# Codex Open-Source Prompts and Tool Semantics

This note is based on the local clone at:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex`

## 1. Where the "real prompts" come from

For the currently shipped GPT-5 Codex-family models, the strongest source of truth is not the standalone markdown prompt files under `codex-rs/core/`. It is the model registry in:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/models-manager/models.json`

In particular:

- `gpt-5.4` has `base_instructions` plus `model_messages.instructions_template`
- `gpt-5.4-mini` has `model_messages.instructions_template`
- `gpt-5.3-codex` has `model_messages.instructions_template`
- `codex-auto-review` has `model_messages.instructions_template`

The selection logic is:

1. `config.base_instructions`
2. conversation history `session_meta.base_instructions`
3. current model's `get_model_instructions(config.personality)`

Code:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/session/mod.rs:555`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/protocol/src/openai_models.rs:329`

`get_model_instructions()` uses `model_messages.instructions_template` when present, substituting `{{ personality }}` from `instructions_variables`. If there is no template, it falls back to `base_instructions`.

That means the "real prompt" for a current GPT-5.4 Codex session is effectively:

- `gpt-5.4.instructions_template.md`
- with `{{ personality }}` replaced by one of:
  - `gpt-5.4.personality_default.md`
  - `gpt-5.4.personality_friendly.md`
  - `gpt-5.4.personality_pragmatic.md`

## 2. Extracted prompt files

I extracted the exact shipped strings from `models.json` into:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/codex-prompt-extracts/gpt-5.4.base_instructions.md`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/codex-prompt-extracts/gpt-5.4.instructions_template.md`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/codex-prompt-extracts/gpt-5.4.personality_default.md`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/codex-prompt-extracts/gpt-5.4.personality_friendly.md`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/codex-prompt-extracts/gpt-5.4.personality_pragmatic.md`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/codex-prompt-extracts/gpt-5.4-mini.instructions_template.md`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/codex-prompt-extracts/gpt-5.3-codex.instructions_template.md`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/codex-prompt-extracts/codex-auto-review.instructions_template.md`

## 3. Prompt layering after base instructions

Even after the model prompt is selected, Codex appends more developer-side context. The important layered pieces are assembled in:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/session/mod.rs:2497`

That developer bundle can include:

- collaboration mode instructions
- realtime update instructions
- personality instructions if the model template did not already bake them in
- apps instructions
- skills instructions
- memories instructions

So the exact runtime prompt is:

1. selected base/model instructions
2. plus extra developer sections appended by session setup

## 4. Which shell tool current models actually use

The model config has a `shell_type` field in `models.json`.

For the current GPT-5.4-family Codex configs I checked, the shell type is:

- `gpt-5.4` -> `shell_command`
- `gpt-5.4-mini` -> `shell_command`
- `gpt-5.3-codex` -> `shell_command`

Tool exposure is decided in:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/tools/src/tool_registry_plan.rs:138`

Important consequence:

- `shell_command` is the main shell-like tool for those models
- `shell` exists as another tool definition, but it is not the default current shell surface for those configs
- `exec_command` and `write_stdin` are used when the model config selects `unified_exec`

## 5. Core shell tool differences

### `shell_command`

Definition:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/tools/src/local_tool.rs:199`

Shape:

- one shell script string: `command`
- optional `workdir`
- optional `timeout_ms`
- optional `login`
- optional approval fields

Semantics:

- handler converts the script string into the user's actual shell argv with `derive_exec_args()`
- for Bash/Zsh that generally means something like `shell -lc "<script>"`
- it is a one-shot command, not a persistent session
- output is buffered and returned once the command exits or times out

Code:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/tools/handlers/shell.rs:104`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/tools/handlers/shell.rs:473`

### `shell`

Definition:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/tools/src/local_tool.rs:121`

Shape:

- argv array: `command: string[]`
- optional `workdir`
- optional `timeout_ms`
- optional approval fields

Semantics:

- command is passed as argv, not as one shell script string
- the description explicitly says most commands should be prefixed with `["bash", "-lc"]`
- still one-shot, not interactive

### `exec_command` + `write_stdin`

Definitions:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/tools/src/local_tool.rs:17`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/tools/src/local_tool.rs:92`

Semantics:

- this is the interactive PTY/unified-exec path
- first call may return a live `session_id`
- later calls use `write_stdin` to send input or poll for more output
- `tty: true` is required if you want stdin interaction

Main runtime:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/unified_exec/process_manager.rs`

## 6. Timeout semantics

### Classic `shell` / `shell_command`

Runtime:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/exec.rs`

Behavior:

- default timeout is `10000 ms`
- `timeout_ms` overrides it
- on timeout it kills the entire child process group
- then it waits up to `2000 ms` for stdout/stderr drain tasks before aborting them
- timeout is surfaced as `timed_out = true`
- final public exit code is normalized to `124`

Relevant code:

- `DEFAULT_EXEC_COMMAND_TIMEOUT_MS = 10_000`
- `IO_DRAIN_TIMEOUT_MS = 2_000`
- `EXEC_TIMEOUT_EXIT_CODE = 124`
- `consume_output()` does the timeout select and kill

References:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/exec.rs:50`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/exec.rs:1260`

### Unified exec

This is different:

- `exec_command` does not use one global "kill after N ms" process lifetime in the same way
- `yield_time_ms` is the time to wait before returning output for this call
- if the process is still alive after that window, Codex returns a `session_id` and keeps the process around

The yield window is clamped:

- minimum `250 ms`
- maximum `30000 ms`

Empty `write_stdin` polls are treated specially:

- minimum empty-poll wait is `5000 ms`
- default max background terminal timeout is `300000 ms`

References:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/unified_exec/mod.rs:57`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/unified_exec/process_manager.rs:453`

## 7. Output capping and garbage handling

### Classic `shell` / `shell_command`

Behavior:

- stdout and stderr are each read continuously to EOF
- each buffer is capped in-memory
- live delta events are capped at `10000` chunks per exec call
- aggregation still continues, but retained bytes are capped
- if the command never stops producing output, retained output stops growing after the cap

Important constants:

- `EXEC_OUTPUT_MAX_BYTES = DEFAULT_OUTPUT_BYTES_CAP`
- `MAX_EXEC_OUTPUT_DELTAS_PER_CALL = 10_000`

References:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/exec.rs:63`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/exec.rs:1352`

Model-facing formatting for freeform shell output is:

- `Exit code: ...`
- `Wall time: ...`
- optional `Total output lines: ...`
- `Output:`

Reference:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/tools/mod.rs:62`

### Unified exec

Unified exec uses a different strategy:

- in-memory retained output cap is `1 MiB`
- it uses a head/tail buffer, preserving the beginning and end while dropping the middle
- model-facing response is truncated again by token budget
- default `max_output_tokens` is `10000`

References:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/unified_exec/mod.rs:64`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/unified_exec/head_tail_buffer.rs:4`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/tools/context.rs:423`

### Binary / weird-encoding output

Codex does not just do naive UTF-8 replacement. It uses encoding detection:

- tries UTF-8 first
- otherwise uses `chardetng` + `encoding_rs`
- special-cases some Windows CP1252 vs IBM866 punctuation confusion
- finally falls back to lossy UTF-8 if decoding still fails

Reference:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/protocol/src/exec_output.rs:1`

## 8. `apply_patch` semantics

Definition:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/tools/src/apply_patch_tool.rs`
- grammar:
  - `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/tools/src/tool_apply_patch.lark`

Important behavior:

- freeform grammar tool for modern GPT-5 models
- JSON wrapper version exists mainly for models that do not support the freeform grammar flow
- patch is reparsed and verified before execution
- if the model tries to smuggle `apply_patch` through `shell` or `exec_command`, Codex intercepts it and routes it through the dedicated patch logic
- patch permissions are computed from the touched file paths
- runtime writes through the turn environment filesystem, not by shelling out to `patch`

References:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/tools/handlers/apply_patch.rs:320`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/tools/handlers/apply_patch.rs:425`
- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/tools/runtimes/apply_patch.rs:182`

Return shape:

- the public tool output is plain text, not a rich JSON payload
- event stream carries richer patch begin/update/end events

Reference:

- `/Users/mbrock/Documents/Codex/2026-04-21-i-have-the-amp-extension-installed/openai-codex/codex-rs/core/src/tools/context.rs:279`

## 9. Short practical take

If you want the most accurate mental model:

- current GPT-5 Codex models ship with prompts embedded in `models.json`
- those models currently prefer `shell_command`, not unified exec
- classic shell tools are one-shot with a real timeout and capped buffered output
- unified exec is the persistent PTY/session model with `session_id` + polling
- `apply_patch` is a first-class structured edit primitive with separate parsing, safety, approval, and runtime paths
