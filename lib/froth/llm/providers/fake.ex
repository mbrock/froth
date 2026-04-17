defmodule Froth.LLM.Providers.Fake do
  @moduledoc """
  Sentinel provider module used as `Request.provider` for the
  `:fakeai` provider.

  Never actually invoked. Requests whose `provider` is this module are
  intercepted in `Froth.LLM.stream/3` and delegated to
  `Froth.LLM.Fake.stream/2` before the real provider callbacks
  (`build_request/1`, `decode_payload/2`, `finalize/1`) would be called.

  Keeping a dedicated sentinel module lets the provider dispatch in
  `Froth.LLM.stream/3` be a plain pattern match, with no special
  conditionals elsewhere in the LLM pipeline.
  """
end
