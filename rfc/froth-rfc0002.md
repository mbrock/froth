# FROTH-RFC-0002: Multimodal LLM Layer

Status: DRAFT
Author: Charlie (@charliebuddybot)
Date: 2026-03-22

## Situation

We have a unified text LLM layer (Froth.LLM) that streams
completions across three providers: Anthropic, OpenAICompat,
and XAI Responses. The abstraction is clean — Request in,
stream of Edits out, Provider behaviour mediates the wire
format. This works.

We also generate images. This happens through Froth.Replicate:
start a prediction, poll until it finishes, download the URL.
This is fine for Replicate-native models (Flux, SDXL, custom
fine-tunes) but absurd for models that have their own APIs.
Tonight we discovered that Google's Nano Banana 2 and Imagen 4
are available through the Gemini generateContent endpoint —
one HTTP call, image back as base64 inline, no prediction ID,
no polling, no cold start. We are paying Replicate to be a
middleman for a model Google serves for free.

Meanwhile the frontier is moving fast. Gemini returns images
in generateContent responses. Anthropic is adding image output.
GPT-4o generates images inline. The line between "text model"
and "image model" is dissolving. A multimodal request is just
a request whose messages contain parts of different MIME types,
and a multimodal response is just a response whose content
blocks include images alongside text.

The LLM layer needs to handle this. Not as a separate module.
As an extension of what already exists.

## Design Principles

1. NATIVE OVER COMPAT. Use each vendor's native API when it
   offers capabilities the compatibility layer lacks. The
   OpenAI-compatible endpoint at Google does not support image
   generation. The native generateContent endpoint does. Use
   the native one. The compatibility layer is a convenience,
   not a commitment.

2. MIME TYPES AS THE UNIVERSAL. A message part is a MIME type
   and a value. text/plain is a string. image/jpeg is binary
   or a URL. audio/mp3 is binary or a URL. The provider maps
   these to its wire format (Anthropic's content blocks,
   Gemini's parts, OpenAI's multimodal content arrays). The
   caller never thinks about wire format.

3. RESPONSE MODALITIES ARE REQUESTED, NOT ASSUMED. The caller
   says what it wants back: text, image, audio, or any
   combination. The provider translates this to its native
   mechanism (Gemini: responseModalities, Anthropic: TBD,
   OpenAI: modalities). If the provider can't deliver a
   requested modality, it fails fast.

4. IMAGES ARE CONTENT, NOT SIDE EFFECTS. An image in a
   response is an Edit with a binary or URL value, not a
   separate prediction to poll. The streaming layer delivers
   image blocks the same way it delivers text deltas — as
   edits to a store. For models that return base64 inline
   (Gemini), the image arrives in one edit. For models that
   return URLs (Replicate), the image arrives as a URL edit
   after the prediction completes. Same interface.

5. REPLICATE REMAINS FOR REPLICATE-NATIVE MODELS. Flux, SDXL,
   custom fine-tunes, WhisperX, minimax TTS — these only
   exist on Replicate. Froth.Replicate stays. But for any
   model that has a native vendor API (Google Imagen, Google
   Nano Banana, Anthropic image output), the native path is
   preferred.

## Proposed Changes

### 1. Message Parts

Current Request.messages is `list(map())` where each map is a
provider-specific message. Replace with a structured format:

    %Froth.LLM.Message{
      role: :user | :assistant | :system,
      parts: [
        %{type: "text/plain", value: "Describe this image"},
        %{type: "image/jpeg", value: {:url, "https://..."}},
        %{type: "image/jpeg", value: {:binary, <<...>>}},
        %{type: "audio/mp3", value: {:url, "https://..."}}
      ]
    }

The Provider.build_request/1 callback maps these to the
vendor's wire format. Anthropic gets content blocks with
source.type "base64" or "url". Gemini gets parts with
inlineData or fileData. OpenAI gets the multimodal content
array.

### 2. Response Modalities

Add to Request:

    response_modalities: [:text, :image]

The provider maps these:
- Gemini: responseModalities in generationConfig
- Anthropic: (when available) content type hints
- OpenAI: modalities array

### 3. Gemini Native Provider

New provider module: Froth.LLM.Providers.GeminiNative

Uses the generateContent endpoint directly (not the OpenAI
compat layer). Handles:
- Image generation via responseModalities: ["IMAGE"]
- Image+text via responseModalities: ["IMAGE", "TEXT"]
- Streaming text via streamGenerateContent
- Image input via inlineData parts

This replaces the current Froth.Gemini module for cases
where native capabilities are needed.

### 4. Image Generation Convenience

    Froth.ImageGen.generate(prompt, opts)

    opts:
      model: "nano-banana-2" | "imagen-4" | "flux-2-pro"
      aspect_ratio: "9:16" | "1:1" | "16:9"
      provider: :gemini | :replicate  (auto-detected from model)
      count: 1

    Returns: {:ok, [%{mime: "image/jpeg", data: binary}]}

This wraps the multimodal LLM call for the common case.
For Gemini models, it's one generateContent call. For
Replicate models, it's start + await. Same return format.

### 5. Edit Extensions

New edit types for non-text content:

    %Edit{op: :set, resource: ["message"], path: ["image", 0],
          value: {:binary, "image/jpeg", <<...>>}}

    %Edit{op: :set, resource: ["message"], path: ["image", 0],
          value: {:url, "image/jpeg", "https://..."}}

The Store accumulates these alongside text. The caller's
on_event callback receives them as they arrive.

## Migration

Phase 1: Add Froth.ImageGen with Gemini native backend.
         One module, one function, handles Nano Banana and
         Imagen 4 via generateContent. No changes to existing
         Froth.LLM. Ship tonight.

Phase 2: Add Message struct with typed parts. Update
         Provider.build_request to accept it alongside the
         current raw maps (backward compatible). Update
         Gemini and Anthropic providers.

Phase 3: Add response modality support. Extend Edit for
         non-text content. Update Store. This is the full
         multimodal streaming layer.

Phase 4: Deprecate raw Replicate calls for models that have
         native vendor APIs. Froth.Replicate stays for
         Replicate-only models.

## Models Available via Native APIs (as of 2026-03-22)

Google (via generateContent):
- nano-banana-2 (image generation)
- nano-banana-pro-preview (image generation)  
- imagen-4 (image generation)
- gemini-2.0-flash-exp (text + image output)
- gemini-3-flash-preview (text)

Anthropic (via messages):
- claude-sonnet-4-20250514 (text, tools)
- claude-opus-4-20250514 (text, tools, extended thinking)

OpenAI (via chat/completions):
- gpt-4o (text + image output)

xAI (via responses):
- grok-4-1-fast-reasoning (text, tools, web search)

## Open Questions

1. Should image generation go through the streaming layer
   at all? Gemini's generateContent returns the full image
   in one response, not streamed. The streaming abstraction
   adds complexity for a non-streaming operation. Counter:
   consistency. Counter-counter: YAGNI.

2. How to handle aspect ratio, safety filters, and other
   image-specific params that don't map to the LLM request
   abstraction? Provider options map? Dedicated config?

3. Should we cache generated images locally? Replicate URLs
   expire. Gemini returns ephemeral base64. Both need to be
   saved somewhere if they're going into a compose pipeline.

4. Audio input/output (Gemini supports it). Same pattern?
   Or does audio streaming need its own transport?
