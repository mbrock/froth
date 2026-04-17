defmodule Froth.Telegram.BotContextHTML do
  @moduledoc """
  Phoenix function components for rendering Telegram bot context as XML-like markup.

  Instead of manually building strings, these components use HEEx templates
  to produce the pseudo-XML used in LLM prompts.

  The top-level `context/1` component renders a full `%Context{}` view model.
  `render_to_parts/1` splits rendered markup into cacheable content parts.
  """

  use Phoenix.Component

  alias Froth.Context.Block
  alias Froth.Context.BlockHTML

  @part_break <<31>>
  @entity_like_ampersand_regex ~r/&([0-9A-Za-z]+);/

  defmodule Context do
    @moduledoc """
    View model for a complete bot context prompt.
    """
    defstruct chapters: [],
              chat_context: nil,
              recent_messages: []

    @type chapter :: %{name: String.t(), text: String.t()}
    @type participant :: %{id: integer() | String.t(), label: String.t()}
    @type analysis :: %{
            :id => integer() | String.t(),
            :type => String.t(),
            :text => String.t(),
            optional(:blob_id) => String.t() | nil
          }
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
            %{
              :kind => :call,
              :tool => String.t(),
              :input => map(),
              optional(:narration) => String.t() | nil
            }
            | %{:kind => :return, :outcome => tool_outcome()}
            | %{:kind => :intervention, optional(:data) => map(), optional(:text) => String.t()}

    @type tool_outcome ::
            {:ok, [Froth.Context.Block.t()] | String.t() | term()}
            | {:error, String.t()}
            | {:await, map()}
            | {:yield, String.t()}
    @type cycle_trace :: %{cycle_id: String.t(), inserted_at: any(), entries: [cycle_entry()]}

    @type t :: %__MODULE__{
            chapters: [chapter()],
            chat_context: chat_context() | nil,
            recent_messages: [recent_message()]
          }
  end

  # ── top-level ──────────────────────────────────────────────────────

  attr :ctx, Context, required: true

  def context(assigns) do
    ~H"""
    <%= for {chapter, idx} <- Enum.with_index(@ctx.chapters) do %>
      <%= if idx > 0 do %>
        <.page_break />
      <% end %>
      <.chapter name={chapter.name} text={chapter.text} />
    <% end %>
    <%= if @ctx.recent_messages != [] do %>
      <%= for {m, idx} <- Enum.with_index(@ctx.recent_messages) do %>
        <.page_break />
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
    <%= if @ctx.chat_context do %>
      <.page_break />
      <.chat_context chat_context={@ctx.chat_context} />
    <% end %>
    """
  end

  # ── chapters ──────────────────────────────────────────────────────

  attr :name, :string, required: true
  attr :text, :string, required: true

  def chapter(assigns) do
    ~H"""
    <chapter name={@name}>
      {@text}
    </chapter>
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
    participants =
      assigns.chat_context
      |> Map.get(:participants, [])
      |> Enum.sort_by(& &1.latest_date, :desc)

    now = DateTime.utc_now()
    latvia = DateTime.shift_zone!(now, "Europe/Riga")
    thailand = DateTime.shift_zone!(now, "Asia/Bangkok")

    assigns =
      assigns
      |> Map.put(:participants, participants)
      |> Map.put(:now_utc, Calendar.strftime(now, "%Y-%m-%d %H:%M UTC"))
      |> Map.put(:now_latvia, Calendar.strftime(latvia, "%Y-%m-%d %H:%M %Z"))
      |> Map.put(:now_thailand, Calendar.strftime(thailand, "%Y-%m-%d %H:%M %Z"))

    ~H"""
    <info>
      chat: {@chat_context.chat_name} (id {@chat_context.chat_id})
      now: {@now_utc} / {@now_latvia} / {@now_thailand}
      <%= for p <- @participants do %>
        {p.label} (id {p.id}) latest message {format_time(p.latest_date)}
      <% end %>
    </info>
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
      <.analysis
        :for={a <- @analyses}
        id={a.id}
        type={a.type}
        text={a.text}
        blob_id={Map.get(a, :blob_id)}
      />
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
  attr :blob_id, :string, default: nil

  def analysis(assigns) do
    ~H"""
    <analysis id={to_string(@id)} type={@type} blob={analysis_blob_attr(@blob_id)}>
      {@text}
    </analysis>
    """
  end

  defp analysis_blob_attr(nil), do: nil
  defp analysis_blob_attr(""), do: nil
  defp analysis_blob_attr(id) when is_binary(id), do: id

  attr :cycle_id, :string, required: true
  attr :inserted_at, :any, required: true
  attr :entries, :list, required: true

  def cycle_trace(assigns) do
    ~H"""
    <cycle cycle_id={@cycle_id} time={format_datetime(@inserted_at)}>
      <.trace_entry :for={entry <- @entries} entry={entry} />
    </cycle>
    """
  end

  attr :entry, :map, required: true

  def trace_entry(%{entry: %{kind: :call} = entry} = assigns) do
    assigns =
      assign(assigns,
        tool: Map.fetch!(entry, :tool),
        input: Map.get(entry, :input, %{})
      )

    ~H"""
    <.call tool={@tool} input={@input} />
    """
  end

  def trace_entry(%{entry: %{kind: :return, outcome: outcome}} = assigns) do
    assigns = assign(assigns, outcome: outcome)

    ~H"""
    <.tool_return outcome={@outcome} />
    """
  end

  def trace_entry(%{entry: %{kind: :intervention} = entry} = assigns) do
    assigns = assign(assigns, data: Map.get(entry, :data, %{}), text: Map.get(entry, :text))

    ~H"""
    <.intervention data={@data} text={@text} />
    """
  end

  def trace_entry(assigns) do
    assigns = assign(assigns, fallback: inspect(assigns.entry, limit: 10, printable_limit: 500))

    ~H"""
    <unknown_entry>{@fallback}</unknown_entry>
    """
  end

  # ── call ──────────────────────────────────────────────────────────

  # Render `<call tool="X">` by showing every input field, with no
  # per-tool cases. Rules, applied at every level (top-level input
  # and any nested map):
  #
  #   * Scalar values (string / number / boolean / nil) short enough
  #     to fit on one line become *attributes* of the enclosing tag.
  #   * Anything else (long strings, lists, nested maps) becomes a
  #     child element named after its key. Lists repeat the same tag
  #     once per item.
  attr :tool, :string, required: true
  attr :input, :map, default: %{}

  def call(assigns) do
    {attr_pairs, body_pairs} = split_fields(assigns.input)

    assigns =
      assign(assigns,
        attr_pairs: to_attr_list(attr_pairs),
        body_pairs: body_pairs
      )

    ~H"""
    <call tool={@tool} {@attr_pairs}>
      <.input_field :for={{k, v} <- @body_pairs} name={to_string(k)} value={v} />
    </call>
    """
  end

  attr :name, :string, required: true
  attr :value, :any, required: true

  def input_field(%{value: v} = assigns) when is_binary(v) do
    ~H"""
    <.field_tag name={@name}>{@value}</.field_tag>
    """
  end

  def input_field(%{value: v} = assigns) when is_number(v) or is_boolean(v) do
    assigns = assign(assigns, text: to_string(v))

    ~H"""
    <.field_tag name={@name}>{@text}</.field_tag>
    """
  end

  def input_field(%{value: nil} = assigns) do
    ~H"""
    <.field_tag name={@name} />
    """
  end

  def input_field(%{value: v} = assigns) when is_list(v) do
    # Lists always render as repeated child tags — attrs can't repeat
    # a key, so `{query: ["foo", "bar"]}` renders as two `<query>`
    # elements, not one `query="foo,bar"` attr.
    assigns = assign(assigns, items: v)

    ~H"""
    <.input_field :for={item <- @items} name={@name} value={item} />
    """
  end

  def input_field(%{value: v} = assigns) when is_map(v) do
    {attr_pairs, body_pairs} = split_fields(v)

    assigns =
      assign(assigns, attr_pairs: to_attr_list(attr_pairs), body_pairs: body_pairs)

    ~H"""
    <.field_tag name={@name} extra={@attr_pairs}>
      <.input_field :for={{k, val} <- @body_pairs} name={to_string(k)} value={val} />
    </.field_tag>
    """
  end

  def input_field(%{value: v} = assigns) do
    assigns = assign(assigns, text: inspect(v))

    ~H"""
    <.field_tag name={@name}>{@text}</.field_tag>
    """
  end

  # One place to pick a tag name. The key itself becomes the tag when
  # it's a safe identifier and not an HTML void tag; otherwise we
  # fall back to `<field name="...">` so the key is still visible.
  attr :name, :string, required: true
  attr :extra, :list, default: []
  slot :inner_block

  def field_tag(assigns) do
    assigns = assign(assigns, tag: safe_field_tag(assigns.name))

    ~H"""
    <.dynamic_tag :if={@tag != "field"} tag_name={@tag} {@extra}>{render_slot(@inner_block)}</.dynamic_tag>
    <.dynamic_tag :if={@tag == "field"} tag_name="field" name={@name} {@extra}>{render_slot(@inner_block)}</.dynamic_tag>
    """
  end

  # HTML void tags can't have content under HEEx; unsafe identifiers
  # can't be tag names at all. Fall back to `<field name="…">` in
  # either case.
  @void_tags ~w(head input command meta link base br hr img source track col embed wbr param)

  defp safe_field_tag(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name) and name not in @void_tags do
      name
    else
      "field"
    end
  end

  # A scalar is eligible to become an attribute when it fits on one
  # line within this cap. Anything with a newline or over the cap
  # stays a child element so multi-line bodies don't get mangled
  # into attribute syntax.
  @short_attr_cap 60

  defp split_fields(map) when is_map(map) do
    map
    |> sorted_pairs()
    |> Enum.split_with(fn {_k, v} -> scalar_attr?(v) end)
  end

  defp split_fields(_), do: {[], []}

  defp scalar_attr?(v) when is_binary(v) do
    not String.contains?(v, "\n") and byte_size(v) <= @short_attr_cap
  end

  defp scalar_attr?(v) when is_number(v) or is_boolean(v), do: true
  defp scalar_attr?(nil), do: true
  defp scalar_attr?(_), do: false

  defp to_attr_list(pairs) do
    Enum.map(pairs, fn {k, v} -> {to_string(k), attr_to_string(v)} end)
  end

  defp attr_to_string(nil), do: ""
  defp attr_to_string(v) when is_binary(v), do: v
  defp attr_to_string(v), do: to_string(v)

  defp sorted_pairs(map) when is_map(map) do
    Enum.sort_by(map, fn {k, _} -> to_string(k) end)
  end

  defp sorted_pairs(_), do: []

  # ── return ────────────────────────────────────────────────────────

  attr :outcome, :any, required: true

  def tool_return(%{outcome: {:ok, [%Block{} | _] = blocks}} = assigns) do
    assigns = assign(assigns, blocks: blocks)

    ~H"""
    <BlockHTML.trace blocks={@blocks} />
    """
  end

  def tool_return(%{outcome: {:ok, value}} = assigns) when is_binary(value) do
    assigns = assign(assigns, value: value)

    ~H"""
    <return>{@value}</return>
    """
  end

  def tool_return(%{outcome: {:ok, value}} = assigns) do
    assigns = assign(assigns, value: inspect(value, limit: 20, printable_limit: 500))

    ~H"""
    <return>{@value}</return>
    """
  end

  def tool_return(%{outcome: {:error, message}} = assigns) do
    assigns = assign(assigns, message: to_string(message))

    ~H"""
    <return is_error="true">{@message}</return>
    """
  end

  def tool_return(%{outcome: {:await, _data}} = assigns) do
    ~H"""
    <return kind="await">awaiting user input</return>
    """
  end

  def tool_return(%{outcome: {:yield, reason}} = assigns) do
    assigns = assign(assigns, reason: to_string(reason))

    ~H"""
    <return kind="yield">{@reason}</return>
    """
  end

  def tool_return(assigns) do
    assigns = assign(assigns, fallback: inspect(assigns.outcome, limit: 10, printable_limit: 500))

    ~H"""
    <return>{@fallback}</return>
    """
  end

  # ── intervention ──────────────────────────────────────────────────

  attr :data, :map, default: %{}
  attr :text, :string, default: nil

  def intervention(%{data: %{"designation" => _}} = assigns) do
    assigns =
      assign(assigns,
        designation: Map.get(assigns.data, "designation"),
        reason: Map.get(assigns.data, "reason"),
        pending_ask_id: Map.get(assigns.data, "pending_ask_id")
      )

    ~H"""
    <intervention designation={@designation} reason={@reason} pending_ask={@pending_ask_id}>
      awaiting user decision on failure intervention
    </intervention>
    """
  end

  def intervention(%{text: text} = assigns) when is_binary(text) do
    assigns = assign(assigns, text: text)

    ~H"""
    <intervention>{@text}</intervention>
    """
  end

  def intervention(assigns) do
    ~H"""
    <intervention />
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
                  input: %{"query" => ["context", "builder"]}
                },
                %{kind: :return, outcome: {:ok, "found 3 relevant log entries"}},
                %{
                  kind: :call,
                  tool: "read_log",
                  input: %{"from_date" => "2026-03-06", "to_date" => "2026-03-06"}
                },
                %{
                  kind: :return,
                  outcome:
                    {:ok, "2026-03-06 08:41 summarizer completed chat -100123 (47 messages)"}
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
                  input: %{"message_id" => "4401"}
                },
                %{
                  kind: :return,
                  outcome: {:ok, "message 4401: \"morning, checking the logs now\" from @mikkel"}
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
