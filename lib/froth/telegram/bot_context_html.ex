defmodule Froth.Telegram.BotContextHTML do
  @moduledoc """
  Phoenix function components for rendering Telegram bot context as XML-like markup.

  Instead of manually building strings, these components use HEEx templates
  to produce the pseudo-XML used in LLM prompts.

  The top-level `context/1` component renders a full `%Context{}` view model.
  `render_to_parts/1` splits rendered markup into cacheable content parts.
  """

  use Phoenix.Component
  @part_break <<31>>
  @entity_like_ampersand_regex ~r/&([0-9A-Za-z]+);/

  defmodule Context do
    @moduledoc """
    View model for a complete bot context prompt.
    """
    defstruct summaries: [],
              chat_context: nil,
              recent_messages: []

    @type summary :: %{date: String.t(), text: String.t()}
    @type participant :: %{id: integer() | String.t(), label: String.t()}
    @type analysis :: %{id: integer() | String.t(), type: String.t(), text: String.t()}
    @type chat_context :: %{
            chat_id: integer() | String.t(),
            chat_name: String.t(),
            participants: [participant()],
            omitted_count: non_neg_integer()
          }
    @type recent_message :: %{
            date: integer() | nil,
            sender: String.t(),
            message_id: integer(),
            text: String.t(),
            type: String.t(),
            analyses: [analysis()],
            cycles: [cycle_trace()]
          }
    @type cycle_entry ::
            %{kind: :call, tool: String.t(), input_json: String.t()}
            | %{kind: :return, text: String.t()}
    @type cycle_trace :: %{cycle_id: String.t(), inserted_at: any(), entries: [cycle_entry()]}

    @type t :: %__MODULE__{
            summaries: [summary()],
            chat_context: chat_context() | nil,
            recent_messages: [recent_message()]
          }
  end

  # ── top-level ──────────────────────────────────────────────────────

  attr :ctx, Context, required: true

  def context(assigns) do
    ~H"""
    <%= for {summary, idx} <- Enum.with_index(@ctx.summaries) do %>
      <%= if idx > 0 do %>
        <.page_break />
      <% end %>
      <.summary date={summary.date} text={summary.text} />
    <% end %>
    <%= if @ctx.recent_messages != [] do %>
      <.page_break />
      <%= if @ctx.chat_context do %>
        <.chat_context chat_context={@ctx.chat_context} />
        <.page_break />
      <% end %>
      <%= for {m, idx} <- Enum.with_index(@ctx.recent_messages) do %>
        <%= if idx > 0 do %>
          <.page_break />
        <% end %>
        <.recent_message
          date={m.date}
          sender={m.sender}
          message_id={m.message_id}
          type={Map.get(m, :type, "messageText")}
          text={m.text}
          analyses={Map.get(m, :analyses, [])}
          cycles={Map.get(m, :cycles, [])}
        />
      <% end %>
    <% end %>
    """
  end

  # ── summaries ──────────────────────────────────────────────────────

  attr :date, :string, required: true
  attr :text, :string, required: true

  def summary(assigns) do
    ~H"""
    <summary date={@date}>
      {@text}
    </summary>
    """
  end

  def page_break(assigns) do
    assigns = Map.put(assigns, :marker, @part_break)

    ~H"""
    {@marker}
    """
  end

  attr :chat_context, :map, required: true

  def chat_context(assigns) do
    assigns =
      assigns
      |> Map.put(:participants, Map.get(assigns.chat_context, :participants, []))
      |> Map.put(:omitted_count, Map.get(assigns.chat_context, :omitted_count, 0))

    ~H"""
    <chat_context>
      chat_id={to_string(@chat_context.chat_id)} chat_name={@chat_context.chat_name} participants_in_recent_window:
      <%= if @participants == [] and @omitted_count == 0 do %>
        - none
      <% else %>
        <%= for participant <- @participants do %>
          - {participant.label} [id={participant.id}]
        <% end %>
        <%= if @omitted_count > 0 do %>
          - ... {@omitted_count} more participants omitted
        <% end %>
      <% end %>
    </chat_context>
    """
  end

  # ── recent transcript ──────────────────────────────────────────────

  attr :messages, :list, required: true

  def recent(assigns) do
    ~H"""
    <.recent_message
      :for={m <- @messages}
      date={m.date}
      sender={m.sender}
      message_id={m.message_id}
      type={Map.get(m, :type, "messageText")}
      text={m.text}
      analyses={Map.get(m, :analyses, [])}
      cycles={Map.get(m, :cycles, [])}
    />
    """
  end

  attr :date, :integer, required: true
  attr :sender, :string, required: true
  attr :message_id, :any, required: true
  attr :type, :string, default: "messageText"
  attr :text, :string, required: true
  attr :analyses, :list, default: []
  attr :cycles, :list, default: []

  def recent_message(assigns) do
    ~H"""
    <msg message_id={to_string(@message_id)} sender={@sender} time={format_time(@date)} type={@type}>
      {@text}
      <.analysis :for={a <- @analyses} id={a.id} type={a.type} text={a.text} />
      <.cycle_trace
        :for={cycle <- @cycles}
        cycle_id={cycle.cycle_id}
        inserted_at={cycle.inserted_at}
        entries={cycle.entries}
      />
    </msg>
    """
  end

  attr :id, :any, required: true
  attr :type, :string, required: true
  attr :text, :string, required: true

  def analysis(assigns) do
    ~H"""
    <analysis id={to_string(@id)} type={@type}>
      {@text}
    </analysis>
    """
  end

  attr :cycle_id, :string, required: true
  attr :inserted_at, :any, required: true
  attr :entries, :list, required: true

  def cycle_trace(assigns) do
    ~H"""
    <cycle cycle_id={@cycle_id} at={format_datetime(@inserted_at)}>
      <.trace_entry :for={entry <- @entries} entry={entry} />
    </cycle>
    """
  end

  attr :entry, :map, required: true

  def trace_entry(%{entry: %{kind: :call, tool: tool, input_json: input_json}} = assigns) do
    assigns = assign(assigns, tool: tool, input_json: input_json)

    ~H"""
    <.call tool={@tool} input_json={@input_json} />
    """
  end

  def trace_entry(%{entry: %{kind: :return, text: text}} = assigns) do
    assigns = assign(assigns, text: text)

    ~H"""
    <.cycle_return text={@text} />
    """
  end

  def trace_entry(assigns) do
    fallback = inspect(assigns.entry, limit: 10, printable_limit: 500)
    assigns = assign(assigns, fallback: fallback)

    ~H"""
    <unknown_entry>
      {@fallback}
    </unknown_entry>
    """
  end

  attr :tool, :string, required: true
  attr :input_json, :string, required: true

  def call(assigns) do
    ~H"""
    <call tool={@tool}>
      {@input_json}
    </call>
    """
  end

  attr :text, :string, required: true

  def cycle_return(assigns) do
    ~H"""
    <return>
      {String.slice(@text, 0, 500)}
    </return>
    """
  end

  # ── rendering ──────────────────────────────────────────────────────

  def render_to_string(rendered) do
    rendered
    |> render_raw()
    |> sanitize_markup(true)
    |> String.replace(@part_break, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  def render_to_parts(rendered) do
    rendered
    |> render_raw()
    |> sanitize_markup(true)
    |> String.split(@part_break, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp render_raw(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp sanitize_markup(markup, pretty?) when is_binary(markup) and is_boolean(pretty?) do
    ensure_fast_html_started()

    try do
      case Floki.parse_fragment(markup) do
        {:ok, fragment} ->
          fragment
          |> drop_phx_attrs()
          |> render_nodes(pretty?)
          |> IO.iodata_to_binary()

        {:error, _reason} ->
          markup
      end
    catch
      :exit, _reason ->
        markup
    end
  end

  defp drop_phx_attrs(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&drop_phx_attrs/1)
    |> Enum.reject(&is_nil/1)
  end

  defp drop_phx_attrs({tag, attrs, children}) when is_list(attrs) and is_list(children) do
    clean_attrs =
      Enum.reject(attrs, fn {name, _value} ->
        String.starts_with?(name, "phx-") or String.starts_with?(name, "data-phx-")
      end)

    {tag, clean_attrs, drop_phx_attrs(children)}
  end

  defp drop_phx_attrs({:comment, _text}), do: nil

  defp drop_phx_attrs(text) when is_binary(text) do
    normalized =
      text
      |> normalize_part_break_whitespace()
      |> trim_template_boundary_whitespace()

    trimmed = String.trim(normalized)

    if trimmed == "", do: nil, else: trimmed
  end

  defp drop_phx_attrs(other), do: other

  defp normalize_part_break_whitespace(text) when is_binary(text) do
    part_break = Regex.escape(@part_break)
    Regex.replace(~r/\s*#{part_break}\s*/, text, @part_break)
  end

  defp trim_template_boundary_whitespace(text) when is_binary(text) do
    text
    |> String.replace(~r/\A[ \t\r]*\n[ \t]*/, "")
    |> String.replace(~r/[ \t\r]*\n[ \t]*\z/, "")
    |> String.trim_trailing()
  end

  defp render_nodes(nodes, pretty?) when is_list(nodes) do
    {iodata, _prev} =
      Enum.reduce(nodes, {[], nil}, fn node, {acc, prev} ->
        separator =
          if pretty? and not is_nil(prev), do: ["\n"], else: []

        {[acc, separator, render_node(node, pretty?)], node}
      end)

    iodata
  end

  defp render_node({tag, attrs, children}, pretty?) do
    open = ["<", tag, render_attrs(attrs), ">"]

    cond do
      void_tag?(tag) and children == [] ->
        open

      children == [] ->
        if pretty? do
          [open, "\n", "</", tag, ">"]
        else
          [open, "</", tag, ">"]
        end

      true ->
        leading_newline = if pretty?, do: "\n", else: ""
        trailing_newline = if pretty?, do: "\n", else: ""

        [
          open,
          leading_newline,
          render_nodes(children, pretty?),
          trailing_newline,
          "</",
          tag,
          ">"
        ]
    end
  end

  defp render_node(text, _pretty?) when is_binary(text), do: escape_text(text)
  defp render_node(other, _pretty?), do: to_string(other)

  defp render_attrs(attrs) when is_list(attrs) do
    Enum.map(attrs, fn {name, value} ->
      [" ", name, "=\"", escape_attr(value), "\""]
    end)
  end

  defp escape_text(text) when is_binary(text) do
    text
    |> escape_entity_like_ampersands()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attr(value) when is_binary(value) do
    value
    |> escape_entity_like_ampersands()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_attr(value), do: value |> to_string() |> escape_attr()

  defp escape_entity_like_ampersands(text) when is_binary(text) do
    Regex.replace(@entity_like_ampersand_regex, text, "&amp;\\1;")
  end

  defp ensure_fast_html_started do
    if Application.get_env(:floki, :html_parser) == Floki.HTMLParser.FastHtml do
      _ = Application.ensure_all_started(:fast_html)
    end

    :ok
  end

  defp void_tag?(tag),
    do:
      tag in [
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr"
      ]

  # ── formatting helpers ────────────────────────────────────────────

  defp format_time(unix) when is_integer(unix) do
    DateTime.from_unix!(unix) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp format_time(_), do: "unknown"

  defp format_datetime(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_datetime(other), do: to_string(other)

  # ── sample view model ─────────────────────────────────────────────

  def sample_context do
    %Context{
      summaries: [
        %{
          date: "2026-03-04",
          text:
            "The group spent the morning debugging a memory leak in the OTP supervisor tree. " <>
              "Mikkel traced it to an unbounded ETS table in the telegram session cache. " <>
              "By afternoon the conversation shifted to whether LLM-generated summaries " <>
              "should preserve exact quotes or paraphrase."
        },
        %{
          date: "2026-03-05",
          text:
            "A quieter day. Brief discussion about adding voice transcription support. " <>
              "Charlie deployed a fix for the ETS leak and confirmed memory usage stabilized."
        }
      ],
      recent_messages: [
        %{
          date: 1_741_252_320,
          sender: "@mikkel",
          message_id: 4401,
          text: "morning, checking the logs now",
          cycles: [
            %{
              cycle_id: "01JNWXYZ",
              inserted_at: ~U[2026-03-06 08:41:03Z],
              entries: [
                %{
                  kind: :call,
                  tool: "search",
                  input_json: ~s({"query":["context","builder"]})
                },
                %{kind: :return, text: "found 3 relevant log entries"},
                %{
                  kind: :call,
                  tool: "read_log",
                  input_json: ~s({"from_date":"2026-03-06","to_date":"2026-03-06"})
                },
                %{
                  kind: :return,
                  text: "2026-03-06 08:41 summarizer completed chat -100123 (47 messages)"
                }
              ]
            }
          ]
        },
        %{
          date: 1_741_252_500,
          sender: "@charlie",
          message_id: 4402,
          text: "the summarizer ran overnight, looks clean",
          analyses: [
            %{
              id: 91_003,
              type: "xpost",
              text: "GitHub issue reference and fix details extracted from linked commit."
            }
          ]
        },
        %{
          date: 1_741_252_680,
          sender: "@mikkel",
          message_id: 4403,
          text: "nice. i want to rework the context builder today",
          analyses: [
            %{
              id: 91_004,
              type: "vision",
              text: "Screenshot shows missing newline separators between XML blocks."
            }
          ],
          cycles: [
            %{
              cycle_id: "01JNWABC",
              inserted_at: ~U[2026-03-06 09:08:52Z],
              entries: [
                %{
                  kind: :call,
                  tool: "look",
                  input_json: ~s({"message_id":"4401"})
                },
                %{
                  kind: :return,
                  text: "message 4401: \"morning, checking the logs now\" from @mikkel"
                }
              ]
            }
          ]
        },
        %{
          date: 1_741_252_920,
          sender: "@luna",
          message_id: 4404,
          text: "can we look at the voice pipeline too?"
        },
        %{
          date: 1_741_253_040,
          sender: "user:42",
          message_id: 4405,
          text: "what does the context look like right now?"
        }
      ]
    }
  end
end
