defmodule WsProto do
  @moduledoc """
  Sans-I/O WebSocket protocol.

  Bytes in, events out. Bytes to send, iodata out.
  Never touches a socket.
  """

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defstruct [:host, :path, :key, :buffer, :state, :headers, :frag_opcode, :frag_parts]

  @type frame ::
          {:text, binary()}
          | {:binary, binary()}
          | {:ping, binary()}
          | {:pong, binary()}
          | {:close, non_neg_integer(), binary()}

  @type event :: :upgraded | frame

  # --- Init ---

  def new(uri) when is_binary(uri), do: new(URI.parse(uri))

  def new(%URI{host: host} = uri) do
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    key = :crypto.strong_rand_bytes(16) |> Base.encode64()

    %__MODULE__{
      host: host,
      path: path,
      key: key,
      buffer: <<>>,
      state: :init
    }
  end

  # --- Upgrade: returns bytes to send ---

  def upgrade(%__MODULE__{state: :init} = ws, extra_headers \\ []) do
    request = [
      "GET ",
      ws.path,
      " HTTP/1.1\r\n",
      "Host: ",
      ws.host,
      "\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: ",
      ws.key,
      "\r\n",
      "Sec-WebSocket-Version: 13\r\n",
      Enum.map(extra_headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]

    {%{ws | state: :upgrading}, request}
  end

  # --- Feed bytes in, get events out ---

  def receive(%__MODULE__{} = ws, bytes) do
    ws = %{ws | buffer: ws.buffer <> bytes}
    decode_loop(ws, [])
  end

  defp decode_loop(%{state: :upgrading} = ws, events) do
    case parse_upgrade_response(ws.buffer) do
      {:ok, status, headers, rest} ->
        accept = :crypto.hash(:sha, ws.key <> @ws_guid) |> Base.encode64()
        got = header(headers, "sec-websocket-accept")

        if status == 101 && accept == got do
          ws = %{ws | state: :open, headers: headers, buffer: rest}
          decode_loop(ws, [:upgraded | events])
        else
          {%{ws | state: :closed},
           [
             {:error, {:upgrade_failed, status, %{accept: accept, got: got, key: ws.key}}}
             | events
           ]
           |> Enum.reverse()}
        end

      :incomplete ->
        {ws, Enum.reverse(events)}
    end
  end

  defp decode_loop(%{state: :open} = ws, events) do
    case decode_frame(ws.buffer) do
      {:ok, fin, op, payload, rest} ->
        case assemble(%{ws | buffer: rest}, fin, op, payload) do
          {:frame, frame, ws} -> decode_loop(ws, [frame | events])
          {:continue, ws} -> decode_loop(ws, events)
        end

      :incomplete ->
        {ws, Enum.reverse(events)}
    end
  end

  defp decode_loop(ws, events), do: {ws, Enum.reverse(events)}

  # --- Encode a frame: returns iodata to send ---

  def send(%__MODULE__{state: :open} = ws, frame) do
    {ws, encode_frame(frame)}
  end

  def send(%__MODULE__{state: :closing} = ws, {:close, _, _} = frame) do
    {%{ws | state: :closed}, encode_frame(frame)}
  end

  # --- HTTP response parser (minimal) ---

  defp parse_upgrade_response(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        ["HTTP/1.1 " <> status_line | header_lines] = String.split(head, "\r\n")
        {status, _} = Integer.parse(status_line)

        headers =
          for line <- header_lines do
            [k, v] = String.split(line, ": ", parts: 2)
            {String.downcase(k), v}
          end

        {:ok, status, headers, rest}

      [_] ->
        :incomplete
    end
  end

  defp header(headers, key), do: List.keyfind(headers, key, 0, {nil, nil}) |> elem(1)

  # --- Frame decoder (server → client, unmasked) ---
  #
  # Handles fragmentation per RFC 6455 §5.4:
  #   FIN=1, op!=0  → complete single-frame message
  #   FIN=0, op!=0  → first fragment, start buffering
  #   FIN=0, op=0   → continuation fragment
  #   FIN=1, op=0   → final fragment, emit assembled message
  #
  # Control frames (ping/pong/close) are never fragmented
  # and may appear between data fragments.

  defp decode_frame(<<fin::1, _::3, op::4, 0::1, 127::7, len::64, d::binary>>)
       when byte_size(d) >= len,
       do: split(fin, op, len, d)

  defp decode_frame(<<fin::1, _::3, op::4, 0::1, 126::7, len::16, d::binary>>)
       when byte_size(d) >= len,
       do: split(fin, op, len, d)

  defp decode_frame(<<fin::1, _::3, op::4, 0::1, len::7, d::binary>>)
       when len < 126 and byte_size(d) >= len,
       do: split(fin, op, len, d)

  defp decode_frame(_), do: :incomplete

  defp split(fin, op, len, data) do
    <<payload::binary-size(len), rest::binary>> = data
    {:ok, fin, op, payload, rest}
  end

  # Assemble frames, accounting for fragmentation.

  defp assemble(ws, 1, op, payload) when op in [0x9, 0xA, 0x8] do
    {:frame, to_frame(op, payload), ws}
  end

  defp assemble(%{frag_opcode: nil} = ws, 1, op, payload) do
    {:frame, to_frame(op, payload), ws}
  end

  defp assemble(%{frag_opcode: nil} = ws, 0, op, payload) do
    {:continue, %{ws | frag_opcode: op, frag_parts: [payload]}}
  end

  defp assemble(%{frag_opcode: frag_op} = ws, 0, 0x0, payload) when frag_op != nil do
    {:continue, %{ws | frag_parts: [payload | ws.frag_parts]}}
  end

  defp assemble(%{frag_opcode: frag_op, frag_parts: parts} = ws, 1, 0x0, payload)
       when frag_op != nil do
    assembled = [payload | parts] |> Enum.reverse() |> IO.iodata_to_binary()
    ws = %{ws | frag_opcode: nil, frag_parts: nil}
    {:frame, to_frame(frag_op, assembled), ws}
  end

  defp to_frame(0x1, p), do: {:text, p}
  defp to_frame(0x2, p), do: {:binary, p}
  defp to_frame(0x9, p), do: {:ping, p}
  defp to_frame(0xA, p), do: {:pong, p}
  defp to_frame(0x8, <<code::16, r::binary>>), do: {:close, code, r}
  defp to_frame(0x8, <<>>), do: {:close, 1000, ""}

  # --- Frame encoder (client → server, masked) ---

  defp encode_frame({:text, p}), do: masked(0x1, p)
  defp encode_frame({:binary, p}), do: masked(0x2, p)
  defp encode_frame({:ping, p}), do: masked(0x9, p)
  defp encode_frame({:pong, p}), do: masked(0xA, p)
  defp encode_frame({:close, c, r}), do: masked(0x8, <<c::16, r::binary>>)

  defp masked(opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)

    header =
      case len do
        l when l < 126 -> <<1::1, 0::3, opcode::4, 1::1, l::7>>
        l when l < 65536 -> <<1::1, 0::3, opcode::4, 1::1, 126::7, l::16>>
        l -> <<1::1, 0::3, opcode::4, 1::1, 127::7, l::64>>
      end

    [header, mask, xor_mask(payload, mask)]
  end

  defp xor_mask(<<>>, _), do: <<>>

  defp xor_mask(data, key) do
    pad = :binary.copy(key, div(byte_size(data), 4) + 1)
    :crypto.exor(data, binary_part(pad, 0, byte_size(data)))
  end
end
