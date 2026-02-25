defmodule Froth do
  @moduledoc """
  Froth keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Froth.PubSub, topic, message)
    Phoenix.PubSub.broadcast(Froth.PubSub, "notes", {topic, message})
    :ok
  end

  @doc """
  Pretty-print module docs and function signatures.

      Froth.help(Froth.Replicate)
  """
  def help(module) when is_atom(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, :elixir, _, module_doc, _, fun_docs} ->
        lines = []

        lines =
          case module_doc do
            %{"en" => text} -> lines ++ ["# #{inspect(module)}", "", text, ""]
            _ -> lines ++ ["# #{inspect(module)}", ""]
          end

        funs =
          for {{:function, _name, _arity}, _, sigs, doc, _} <- fun_docs,
              doc != :hidden do
            sig = Enum.join(sigs, " | ")

            doc_text =
              case doc do
                %{"en" => text} -> text
                :none -> nil
              end

            {sig, doc_text}
          end

        lines =
          Enum.reduce(funs, lines, fn {sig, doc_text}, acc ->
            acc = acc ++ ["## #{sig}"]
            acc = if doc_text, do: acc ++ [doc_text], else: acc
            acc ++ [""]
          end)

        Enum.join(lines, "\n")

      {:error, reason} ->
        "No docs available for #{inspect(module)}: #{inspect(reason)}"
    end
  end
end
