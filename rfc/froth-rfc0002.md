# FROTH-RFC-0002: Native Multimodal LLM Layer

Status: PARTIALLY IMPLEMENTED
Author: Charlie (@charliebuddybot)
Date: 2026-03-22

## Situation

`Froth.LLM` already has the right high-level shape: a request goes
in, a provider builds a transport request, SSE payloads become
`Edit`s, and callers consume a stream of semantic events. That part
works.

But the provider layer is still uneven. Anthropic already speaks its
native API. xAI has a native Responses path when built-in tools are
needed. `Froth.OpenAI` and `Froth.Gemini`, however, still route
through `Froth.LLM.Providers.OpenAICompat`. That made it easy to get
text streaming and tool calls working across multiple vendors, but it
also pushed the abstraction in the wrong direction: toward "chat
completion compatibility" instead of "native multimodal model
interfaces".

That starts to hurt as soon as the vendors differ in meaningful ways:

- Gemini uses native parts and supports image/audio IO on its own API.
- OpenAI has its own multimodal content format and modality controls.
- Anthropic has content blocks, thinking blocks, tool blocks, and its
  own streaming event taxonomy.
- xAI has a native Responses API that does not cleanly collapse into a
  chat-completions-shaped wire format.

Compatibility endpoints flatten those differences. They hide
capabilities, force lowest-common-denominator request shapes, and make
multimodal support feel like a bolt-on. The result is a core layer
that is more "OpenAI-ish text chat" than "native multimodal LLM".

That is backwards. `Froth.LLM` should be the semantic layer. The
vendor APIs should be adapters beneath it.

## Goal

Turn `Froth.LLM` into a native multimodal abstraction that speaks
OpenAI's API, Gemini's API, Anthropic's API, xAI's API, and similar
vendor APIs directly, while presenting one coherent request,
response, and streaming edit model to the rest of Froth.

## Non-Goals

- This RFC is not primarily about image generation as a separate
  subsystem.
- This RFC is not about pretending the vendor APIs are identical.
- This RFC is not about removing provider-specific options entirely.
- This RFC does not replace `Froth.Replicate` for Replicate-native
  models.

## Design Principles

1. NATIVE PROVIDERS FIRST. `Froth.OpenAI` should talk to OpenAI.
   `Froth.Gemini` should talk to Gemini. `Froth.Anthropic` should talk
   to Anthropic. Compatibility layers are transitional helpers, not
   the architecture.

2. ONE SEMANTIC CORE, MANY ADAPTERS. The caller should construct a
   Froth request in Froth terms. Each provider translates that request
   to its own wire format and translates streamed payloads back into
   Froth edits.

3. MULTIMODAL IS FUNDAMENTAL. Text, images, audio, files, tool calls,
   and tool results are all first-class content. The core request model
   should assume mixed-modality content is normal.

4. NORMALIZE SEMANTICS, NOT WIRE FORMATS. We should align on concepts
   like roles, content blocks, tools, tool results, response
   modalities, usage, and stop reasons. We should not align on one
   vendor's JSON layout.

5. CAPABILITY MISMATCH SHOULD FAIL FAST. If the caller requests image
   output, audio input, JSON schema output, or some tool mode a vendor
   cannot satisfy, the provider should say so explicitly rather than
   silently degrading.

6. PROVIDER OPTIONS ARE AN ESCAPE HATCH. Vendor-specific options still
   matter, but they should sit in `provider_options` around the edges
   of a shared semantic model, not define the core abstraction.

## Proposed Changes

### 1. Define a native Froth message/content model

Today `Request.messages` is effectively `list(map())` containing
provider-shaped payloads. Replace that with a semantic Froth format.

Example:

    %Froth.LLM.Message{
      role: :user,
      content: [
        %{type: :text, text: "Describe this image"},
        %{type: :image, mime: "image/jpeg", source: {:url, "https://..."}},
        %{type: :audio, mime: "audio/mpeg", source: {:binary, <<...>>}},
        %{type: :file, mime: "application/pdf", source: {:url, "https://..."}},
        %{type: :tool_result, tool_use_id: "toolu_123", content: [
          %{type: :text, text: "42"}
        ]}
      ]
    }

The important distinction is:

- content blocks are typed in Froth terms
- media blocks carry MIME metadata
- tools remain semantic, not transport-specific
- providers map Froth blocks to their native request shapes

During migration, providers may accept both the current raw maps and
the new semantic structs.

### 2. Make response modalities explicit

Add request-level fields that describe what the caller wants back, for
example:

    response_modalities: [:text, :image]

and, where needed:

    response_format: %{type: :json_schema, schema: %{...}}

The provider translates these to the native API:

- OpenAI: modalities / response format controls
- Gemini: response modality and generation config fields
- Anthropic: native equivalents when available
- xAI: native responses fields

The point is not that every vendor uses the same names. The point is
that Froth asks for the semantic outcome and the adapter performs the
translation.

### 3. Replace compatibility-backed providers with native ones

Introduce or evolve provider modules so each vendor has a native
adapter:

- `Froth.LLM.Providers.OpenAI`
- `Froth.LLM.Providers.Gemini`
- `Froth.LLM.Providers.Anthropic`
- `Froth.LLM.Providers.XAIResponses`

Concretely:

- `Froth.OpenAI` should stop setting `provider: OpenAICompat` and
  instead build requests for a native OpenAI provider.
- `Froth.Gemini` should stop using the Google OpenAI-compatible
  endpoint and instead speak Gemini's native API directly.
- `Froth.LLM.Providers.Anthropic` remains native, but should adopt the
  shared Froth multimodal request model instead of accepting only
  Anthropic-shaped message maps.
- `Froth.LLM.Providers.OpenAICompat` becomes a migration shim and can
  eventually be removed.

### 4. Extend `Request` around shared semantics

`Froth.LLM.Request` should carry the shared semantic fields needed by
all providers. Likely additions include:

- semantic `messages`
- `response_modalities`
- `response_format`
- provider capability hints

Existing fields like `thinking`, `output_config`, and
`cache_control` should be reconsidered in this light:

- if they represent shared semantics, promote them into clearer
  provider-neutral fields
- if they are truly vendor-specific, keep them in
  `provider_options`

The goal is to reduce the amount of vendor vocabulary that leaks into
the core request struct.

### 5. Extend the edit/store model to carry multimodal output

`Edit` already gives Froth a nice streaming abstraction. Keep that,
but generalize it beyond text deltas and tool-call JSON fragments.

Examples:

    %Edit{op: :append, resource: ["message", "blocks", 0], path: ["text"], value: "hello"}

    %Edit{
      op: :set,
      resource: ["message", "blocks", 1],
      path: ["image"],
      value: {:binary, "image/jpeg", <<...>>}
    }

    %Edit{
      op: :set,
      resource: ["message", "blocks", 2],
      path: ["audio"],
      value: {:url, "audio/mpeg", "https://..."}
    }

The store then accumulates a final multimodal message, and
`project_event/1` can continue to emit convenient events like
`{:text_delta, ...}`, `{:tool_use_start, ...}`, plus new image/audio
events where useful.

### 6. Convenience APIs become thin wrappers on top

If Froth wants helpers like:

    Froth.ImageGen.generate(prompt, opts)

that is fine, but those helpers should sit on top of the multimodal
`Froth.LLM` layer rather than define a separate abstraction. The core
change in this RFC is the native multimodal provider layer itself.

## Migration Plan

Phase 1: Add native provider modules for OpenAI and Gemini and route
         `Froth.OpenAI` / `Froth.Gemini` through them instead of
         `OpenAICompat`.

Phase 2: Introduce Froth-native message/content structs and teach each
         provider to accept them while remaining backward compatible
         with today's raw message maps.

Phase 3: Add response modality and response format fields to
         `Froth.LLM.Request`.

Phase 4: Extend `Froth.LLM.Edit` and `Froth.LLM.Store` to accumulate
         multimodal output blocks, not just text and tool calls.

Phase 5: Update call sites to construct semantic Froth messages rather
         than provider-shaped payloads. Deprecate `OpenAICompat`.

Phase 6: Add thin convenience APIs on top where they are useful
         (`ImageGen`, structured-output helpers, audio helpers, etc.).

## Consequences

### Benefits

- Froth gets direct access to each vendor's actual capabilities.
- Multimodal support lives in one place instead of leaking into
  provider-specific calling code.
- The request model becomes more stable because it is based on Froth
  semantics rather than whichever vendor wire format was easiest first.
- Adding a new provider becomes "write an adapter" instead of
  "contort everything into chat completions".

### Costs

- More provider-specific translation code.
- More explicit capability handling.
- More care needed around binary payloads, file references, and event
  projection.
- Migration complexity while both raw maps and semantic messages are
  temporarily supported.

## Open Questions

1. What is the right Froth-native shape for content blocks? Pure MIME
   blocks are elegant for media, but tools and thinking likely need a
   richer typed structure than MIME alone.

2. Which fields truly belong in `Request`, and which should remain
   vendor-specific options? `thinking`, `output_config`, and
   `cache_control` are the obvious pressure points.

3. Should all providers project the same small event vocabulary
   (`:text_delta`, `:tool_use_start`, `:usage`, etc.), or should Froth
   also expose richer block-level events for image/audio output?

4. How should binary outputs be persisted? Some vendors return inline
   bytes, some return URLs, some return file references. Froth likely
   needs a consistent storage story above the provider layer.

5. Do we want a capability registry per model/provider pair so callers
   can discover what is supported before making a request?
