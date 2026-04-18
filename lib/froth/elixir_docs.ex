defmodule Froth.ElixirDocs do
  @moduledoc false

  alias Froth.Context.Block

  @type target ::
          %{kind: :module, module: module(), original: String.t()}
          | %{
              kind: :function,
              module: module(),
              function: String.t(),
              arity: non_neg_integer() | nil,
              original: String.t()
            }

  @spec query(map()) :: {:ok, [Block.t()]} | {:error, String.t()}
  def query(input) when is_map(input) do
    include_source = parse_boolean(input["include_source"], false)
    include_ast = parse_boolean(input["include_ast"], false)

    case normalize_targets(input) do
      {:ok, []} ->
        {:ok, [overview_block()]}

      {:ok, targets} ->
        {:ok, Enum.flat_map(targets, &target_blocks(&1, include_source, include_ast))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp overview_block do
    modules =
      :froth
      |> Application.spec(:modules)
      |> List.wrap()
      |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.Froth"))
      |> Enum.sort()

    Block.new(
      [kind: "module_overview", app: "froth", modules: length(modules)],
      modules |> hierarchy_lines() |> Enum.join("\n")
    )
  end

  defp target_blocks(
         %{kind: :module, module: module, original: original},
         include_source,
         include_ast
       ) do
    case module_detail(module) do
      {:ok, detail} ->
        [module_block(detail, original, include_source, include_ast)]

      {:error, reason} ->
        [error_block(original, reason)]
    end
  end

  defp target_blocks(
         %{kind: :function, module: module, function: function, arity: arity, original: original},
         include_source,
         include_ast
       ) do
    case module_detail(module) do
      {:ok, detail} ->
        matches = matching_functions(detail, function, arity)

        if matches == [] do
          [error_block(original, "No matching function found in #{inspect(module)}.")]
        else
          Enum.map(matches, &function_block(detail, &1, original, include_source, include_ast))
        end

      {:error, reason} ->
        [error_block(original, reason)]
    end
  end

  defp module_block(detail, original, include_source, include_ast) do
    attrs = [
      kind: "module",
      module: inspect(detail.module),
      file: detail.source_path,
      functions: length(detail.public_functions)
    ]

    children =
      []
      |> maybe_append(include_source, module_source_block(detail))
      |> maybe_append(include_ast, module_ast_block(detail))

    Block.new(attrs, module_body(detail, original), children)
  end

  defp function_block(detail, function_detail, original, include_source, include_ast) do
    attrs = [
      kind: "function",
      module: inspect(detail.module),
      function: "#{function_detail.name}/#{function_detail.arity}",
      file: detail.source_path,
      line: function_detail.line
    ]

    children =
      []
      |> maybe_append(include_source, function_source_block(detail, function_detail))
      |> maybe_append(include_ast, function_ast_block(detail, function_detail))

    Block.new(attrs, function_body(detail, function_detail, original), children)
  end

  defp error_block(target, reason) when is_binary(target) and is_binary(reason) do
    Block.new([kind: "lookup_error", target: target], reason)
  end

  defp module_body(detail, original) do
    [
      "# #{inspect(detail.module)}",
      "",
      "Requested as: #{original}",
      "Source: #{detail.source_path || "(unknown)"}",
      "Public functions: #{length(detail.public_functions)}",
      detail.module_doc != nil && "",
      detail.module_doc,
      detail.public_functions != [] && "",
      detail.public_functions != [] && "Public API",
      detail.public_functions != [] &&
        Enum.map(detail.public_functions, fn function ->
          "- #{function.signature || "#{function.name}/#{function.arity}"}"
        end)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp function_body(detail, function_detail, original) do
    [
      "# #{inspect(detail.module)}.#{function_detail.name}/#{function_detail.arity}",
      "",
      "Requested as: #{original}",
      function_detail.signature && "Signature: #{function_detail.signature}",
      function_detail.args != [] && "Args: #{Enum.join(function_detail.args, ", ")}",
      "Source: #{detail.source_path || "(unknown)"}:#{function_detail.line || 0}",
      function_detail.doc != nil && "",
      function_detail.doc
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp module_source_block(detail) do
    case detail.source_range do
      nil ->
        Block.new(
          [kind: "source_code", target: inspect(detail.module), available: false],
          "(source unavailable)"
        )

      {from_line, to_line, text} ->
        Block.new(
          [
            kind: "source_code",
            target: inspect(detail.module),
            file: detail.source_path,
            from_line: from_line,
            to_line: to_line
          ],
          text
        )
    end
  end

  defp module_ast_block(detail) do
    case detail.module_ast do
      nil ->
        Block.new(
          [kind: "ast", target: inspect(detail.module), available: false],
          "(ast unavailable)"
        )

      ast ->
        Block.new([kind: "ast", target: inspect(detail.module)], inspect_ast(ast))
    end
  end

  defp function_source_block(detail, function_detail) do
    case function_detail.source_range do
      nil ->
        Block.new(
          [
            kind: "source_code",
            target: "#{inspect(detail.module)}.#{function_detail.name}/#{function_detail.arity}",
            available: false
          ],
          "(source unavailable)"
        )

      {from_line, to_line, text} ->
        Block.new(
          [
            kind: "source_code",
            target: "#{inspect(detail.module)}.#{function_detail.name}/#{function_detail.arity}",
            file: detail.source_path,
            from_line: from_line,
            to_line: to_line
          ],
          text
        )
    end
  end

  defp function_ast_block(detail, function_detail) do
    case function_detail.ast do
      nil ->
        Block.new(
          [
            kind: "ast",
            target: "#{inspect(detail.module)}.#{function_detail.name}/#{function_detail.arity}",
            available: false
          ],
          "(ast unavailable)"
        )

      ast ->
        Block.new(
          [
            kind: "ast",
            target: "#{inspect(detail.module)}.#{function_detail.name}/#{function_detail.arity}"
          ],
          inspect_ast(ast)
        )
    end
  end

  defp module_detail(module) when is_atom(module) do
    with {:ok, docs} <- fetch_docs(module) do
      source_path =
        case source_path(module, docs) do
          {:ok, path} -> path
          {:error, _reason} -> nil
        end

      source_context =
        case source_path do
          path when is_binary(path) ->
            case source_context(path) do
              {:ok, context} -> context
              {:error, _reason} -> nil
            end

          _ ->
            nil
        end

      detail = %{
        module: module,
        source_path: source_path,
        module_doc: module_doc_text(docs.module_doc),
        public_functions: public_functions(docs.fun_docs),
        source_range: module_source_range(source_context, module),
        module_ast: module_ast(source_context, module) || debug_module_ast(module),
        source_context: source_context
      }

      {:ok, %{detail | public_functions: enrich_functions(detail, docs.fun_docs)}}
    else
      {:error, :docs_unavailable} ->
        {:error, "No docs available for #{inspect(module)}."}
    end
  end

  defp fetch_docs(module) when is_atom(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, module_doc, metadata, fun_docs} ->
        {:ok, %{module_doc: module_doc, metadata: metadata, fun_docs: fun_docs}}

      {:error, _reason} ->
        {:error, :docs_unavailable}
    end
  end

  defp source_path(module, docs) when is_atom(module) and is_map(docs) do
    docs_path =
      docs.metadata[:source_path]
      |> normalize_path()

    compile_path =
      module
      |> module_compile_source()
      |> normalize_path()

    case docs_path || compile_path do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :source_unavailable}
    end
  end

  defp source_context(path) when is_binary(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast, comments} <-
           Code.string_to_quoted_with_comments(source, columns: true, token_metadata: true) do
      lines = String.split(source, "\n")
      modules = collect_modules(ast)

      {:ok,
       %{path: path, source: source, lines: lines, ast: ast, comments: comments, modules: modules}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp module_doc_text(%{"en" => text}) when is_binary(text), do: String.trim(text)
  defp module_doc_text(_), do: nil

  defp public_functions(fun_docs) when is_list(fun_docs) do
    fun_docs
    |> Enum.flat_map(fn
      {{:function, _name, _arity}, _line, _signatures, :hidden, _metadata} ->
        []

      {{:function, name, arity}, line, signatures, doc, metadata} ->
        [
          %{
            name: Atom.to_string(name),
            arity: arity,
            line: line,
            signature: List.first(signatures),
            signatures: signatures,
            doc: function_doc_text(doc),
            metadata: metadata
          }
        ]

      _ ->
        []
    end)
    |> Enum.sort_by(&{&1.name, &1.arity})
  end

  defp function_doc_text(%{"en" => text}) when is_binary(text), do: String.trim(text)
  defp function_doc_text(:none), do: nil
  defp function_doc_text(_), do: nil

  defp enrich_functions(detail, fun_docs) do
    source_functions =
      detail.source_context
      |> function_nodes(detail.module)
      |> Enum.sort_by(&{&1.name, &1.arity})

    doc_functions = public_functions(fun_docs)

    Enum.map(doc_functions, fn function ->
      case Enum.find(source_functions, &(&1.name == function.name and &1.arity == function.arity)) do
        nil ->
          Map.merge(function, %{
            args: [],
            source_range: nil,
            ast: debug_function_ast(detail.module, function.name, function.arity)
          })

        source_function ->
          Map.merge(function, source_function)
      end
    end)
  end

  defp matching_functions(detail, function_name, nil) do
    Enum.filter(detail.public_functions, &(&1.name == function_name))
  end

  defp matching_functions(detail, function_name, arity) when is_integer(arity) do
    Enum.filter(detail.public_functions, &(&1.name == function_name and &1.arity == arity))
  end

  defp module_source_range(nil, _module), do: nil

  defp module_source_range(source_context, module) do
    with %{line: line} <- find_module_node(source_context, module),
         start_line when is_integer(start_line) <- max(line, 1),
         end_line <- next_module_start(source_context, module, start_line) - 1 do
      source_range(source_context.lines, start_line, max(end_line, start_line))
    else
      _ -> nil
    end
  end

  defp module_ast(nil, _module), do: nil

  defp module_ast(source_context, module) do
    case find_module_node(source_context, module) do
      %{ast: ast} -> ast
      _ -> nil
    end
  end

  defp function_nodes(nil, _module), do: []

  defp function_nodes(source_context, module) do
    case find_module_node(source_context, module) do
      nil ->
        []

      %{body: body} ->
        forms = block_forms(body)

        forms
        |> Enum.with_index()
        |> Enum.flat_map(fn {form, index} ->
          case function_form(form) do
            nil ->
              []

            function ->
              next_line =
                forms
                |> Enum.drop(index + 1)
                |> Enum.find_value(length(source_context.lines) + 1, fn next_form ->
                  next_form
                  |> form_line()
                  |> case do
                    line when is_integer(line) and line > 0 -> line
                    _ -> nil
                  end
                end)

              source_start = decorated_start_line(source_context.lines, function.line)
              source_end = max(next_line - 1, source_start)

              [
                %{
                  name: function.name,
                  arity: function.arity,
                  line: function.line,
                  args: function.args,
                  source_range: source_range(source_context.lines, source_start, source_end),
                  ast: form
                }
              ]
          end
        end)
    end
  end

  defp function_form({kind, meta, [_head | _rest]} = form)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    with {name, arity, args} <- signature_from_definition(form) do
      %{name: name, arity: arity, args: args, line: line_from_meta(meta)}
    end
  end

  defp function_form(_), do: nil

  defp signature_from_definition({_, _, [head | _]}) do
    case unwrap_when(head) do
      {name, _meta, args} when is_atom(name) and is_list(args) ->
        {Atom.to_string(name), length(args), Enum.map(args, &arg_name/1)}

      {name, _meta, nil} when is_atom(name) ->
        {Atom.to_string(name), 0, []}

      _ ->
        nil
    end
  end

  defp unwrap_when({:when, _, [head | _guards]}), do: unwrap_when(head)
  defp unwrap_when(other), do: other

  defp arg_name({:\\, _, [lhs, _rhs]}), do: arg_name(lhs)

  defp arg_name({name, _, context}) when is_atom(name) and (is_atom(context) or is_nil(context)),
    do: Atom.to_string(name)

  defp arg_name(other), do: Macro.to_string(other)

  defp source_range(lines, from_line, to_line) when is_list(lines) do
    excerpt =
      lines
      |> Enum.slice(max(from_line - 1, 0), max(to_line - from_line + 1, 0))
      |> Enum.join("\n")

    {from_line, to_line, excerpt}
  end

  defp decorated_start_line(lines, line) when is_list(lines) and is_integer(line) and line > 1 do
    line
    |> Kernel.-(1)
    |> do_decorated_start_line(lines)
  end

  defp decorated_start_line(_lines, line), do: line

  defp do_decorated_start_line(index, lines) when index > 0 do
    previous = Enum.at(lines, index - 1, "")

    if previous =~ ~r/^\s*(@[a-zA-Z_]\w*|#.*)?\s*$/ do
      do_decorated_start_line(index - 1, lines)
    else
      index + 1
    end
  end

  defp do_decorated_start_line(0, _lines), do: 1

  defp collect_modules(ast), do: collect_modules(ast, [])

  defp collect_modules(ast, prefix) do
    ast
    |> block_forms()
    |> Enum.flat_map(fn
      {:defmodule, meta, [name_ast, [do: body]]} = node ->
        segments = alias_segments(name_ast)
        full_segments = full_segments(prefix, segments)
        module = Module.concat(full_segments)

        [%{module: module, line: line_from_meta(meta), ast: node, body: body}] ++
          collect_modules(body, full_segments)

      _ ->
        []
    end)
  end

  defp block_forms({:__block__, _, forms}) when is_list(forms), do: forms
  defp block_forms(nil), do: []
  defp block_forms(form), do: [form]

  defp alias_segments({:__aliases__, _, segments}) when is_list(segments),
    do: Enum.map(segments, &Atom.to_string/1)

  defp alias_segments(atom) when is_atom(atom), do: [Atom.to_string(atom)]
  defp alias_segments(_), do: []

  defp full_segments(_prefix, ["Elixir" | rest]), do: rest
  defp full_segments(prefix, segments) when prefix == [], do: segments
  defp full_segments(_prefix, ["Froth" | _] = segments), do: segments
  defp full_segments(prefix, segments), do: prefix ++ segments

  defp find_module_node(nil, _module), do: nil

  defp find_module_node(%{modules: modules}, module) do
    Enum.find(modules, &(&1.module == module))
  end

  defp form_line({_, meta, _}) when is_list(meta), do: meta[:line]
  defp form_line(_), do: nil

  defp next_module_start(%{modules: modules, lines: lines}, module, current_line) do
    modules
    |> Enum.filter(&(&1.module != module and is_integer(&1.line) and &1.line > current_line))
    |> Enum.map(& &1.line)
    |> Enum.min(fn -> length(lines) + 1 end)
  end

  defp line_from_meta(meta) when is_list(meta), do: meta[:line]
  defp line_from_meta(_), do: nil

  defp debug_module_ast(module) do
    case debug_info(module) do
      {:ok, %{definitions: definitions}} -> definitions
      _ -> nil
    end
  end

  defp debug_function_ast(module, function_name, arity)
       when is_binary(function_name) and is_integer(arity) do
    case debug_info(module) do
      {:ok, %{definitions: definitions}} ->
        Enum.find_value(definitions, fn
          {{name, definition_arity}, _, _meta, clauses} when definition_arity == arity ->
            if Atom.to_string(name) == function_name, do: clauses, else: nil

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  defp debug_info(module) when is_atom(module) do
    with beam when beam != :non_existing <- :code.which(module),
         {:ok, {_, [{:debug_info, {:debug_info_v1, :elixir_erl, {:elixir_v1, metadata, _}}}]}} <-
           :beam_lib.chunks(beam, [:debug_info]) do
      {:ok, metadata}
    else
      _ -> {:error, :debug_unavailable}
    end
  end

  defp inspect_ast(ast) do
    inspect(ast, pretty: true, limit: :infinity, printable_limit: :infinity)
  end

  defp maybe_append(list, true, value), do: list ++ [value]
  defp maybe_append(list, false, _value), do: list

  defp normalize_targets(input) when is_map(input) do
    input
    |> Map.get("targets", Map.get(input, "target"))
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) -> [String.trim(value)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      case parse_target(target) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_target(target) when is_binary(target) do
    module_pattern = ~r/\A(?<module>(?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\z/

    function_pattern =
      ~r/\A(?<module>(?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.(?<function>[a-z_][A-Za-z0-9_!?]*)(?:\/(?<arity>\d+))?\z/

    cond do
      captures = Regex.named_captures(function_pattern, target) ->
        with {:ok, module} <- resolve_module(captures["module"]) do
          {:ok,
           %{
             kind: :function,
             module: module,
             function: captures["function"],
             arity: parse_arity(captures["arity"]),
             original: target
           }}
        end

      Regex.match?(module_pattern, target) ->
        with {:ok, module} <- resolve_module(target) do
          {:ok, %{kind: :module, module: module, original: target}}
        end

      true ->
        {:error, "Invalid docs target: #{inspect(target)}"}
    end
  end

  defp resolve_module(name) when is_binary(name) do
    candidates =
      [name]
      |> maybe_prefix_elixir()

    Enum.find_value(candidates, {:error, "Unknown module: #{name}"}, fn candidate ->
      try do
        module = String.to_existing_atom(candidate)

        if Code.ensure_loaded?(module) do
          {:ok, module}
        else
          nil
        end
      rescue
        ArgumentError -> nil
      end
    end)
  end

  defp maybe_prefix_elixir([<<"Elixir.", _::binary>> = name]), do: [name]
  defp maybe_prefix_elixir([name]), do: ["Elixir." <> name, name]

  defp parse_arity(value) when is_binary(value) and value != "" do
    case Integer.parse(value) do
      {arity, ""} when arity >= 0 -> arity
      _ -> nil
    end
  end

  defp parse_arity(_), do: nil

  defp parse_boolean(value, default) when is_boolean(default) do
    cond do
      is_boolean(value) -> value
      is_binary(value) -> String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
      true -> default
    end
  end

  defp normalize_path(path) when is_binary(path), do: path
  defp normalize_path(path) when is_list(path), do: List.to_string(path)
  defp normalize_path(_), do: nil

  defp module_compile_source(module) when is_atom(module) do
    module
    |> module.module_info(:compile)
    |> Keyword.get(:source)
  rescue
    _ -> nil
  end

  defp hierarchy_lines(modules) when is_list(modules) do
    tree =
      Enum.reduce(modules, %{}, fn module, acc ->
        segments =
          module
          |> Atom.to_string()
          |> String.replace_prefix("Elixir.", "")
          |> String.split(".")

        put_in_tree(acc, segments)
      end)

    ["Froth module hierarchy", "", render_tree(tree, 0)]
    |> List.flatten()
  end

  defp put_in_tree(tree, []), do: tree

  defp put_in_tree(tree, [segment | rest]) do
    Map.update(tree, segment, put_in_tree(%{}, rest), &put_in_tree(&1, rest))
  end

  defp render_tree(tree, _depth) when tree == %{}, do: []

  defp render_tree(tree, depth) when is_map(tree) do
    tree
    |> Enum.sort_by(fn {segment, _children} -> segment end)
    |> Enum.flat_map(fn {segment, children} ->
      indent = String.duplicate("  ", depth)
      count = count_leaves(children)

      line =
        if children == %{} do
          "#{indent}- #{segment}"
        else
          "#{indent}- #{segment} (#{count})"
        end

      [line | render_tree(children, depth + 1)]
    end)
  end

  defp count_leaves(children) when children == %{}, do: 1

  defp count_leaves(children) when is_map(children) do
    Enum.reduce(children, 0, fn {_segment, nested}, acc -> acc + count_leaves(nested) end)
  end
end
