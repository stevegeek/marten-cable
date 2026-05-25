module MartenCable
  # Reopens `Cable::Connection#receive` to enforce
  # `MartenCable.configuration.max_message_size`. Cable's handler routes
  # every incoming `socket.on_message` payload through this single method
  # (`lib/cable/src/cable/connection.cr#receive`), so it's the one
  # chokepoint where we can apply a size cap without forking Cable.
  #
  # The cap is checked *after* the WebSocket framing layer has decoded the
  # message into a Crystal `String`. The stdlib `HTTP::WebSocket` doesn't
  # expose a streaming frame-size hook, so the bytes are already in memory
  # by the time we see them — operators wanting to prevent the allocation
  # entirely should also configure a reverse-proxy frame-size limit ahead
  # of the Marten process.
  #
  # When the limit is exceeded:
  #   - The socket is closed with WS close code 1009 ("Message Too Big").
  #   - The connection is removed from `Cable.server`.
  #   - The message is dropped (never reaches Cable's command dispatch).
  module ConnectionMessageLimit
  end
end

class Cable::Connection
  # Wraps the original `Cable::Connection#receive` (aliased below as
  # `receive_without_size_check`) with a size guard sourced from
  # `MartenCable.configuration.max_message_size`.
  def receive(message : String)
    limit = ::MartenCable.configuration.max_message_size
    if message.bytesize > limit
      ::Cable::Logger.warn do
        "Cable message dropped (#{message.bytesize} bytes > #{limit} byte limit); closing connection"
      end
      socket.close(::HTTP::WebSocket::CloseCode::MessageTooBig, "Message too big")
      ::Cable.server.remove_connection(connection_identifier)
      return
    end

    receive_without_size_check(message)
  end

  # Original implementation, transcribed from
  # `lib/cable/src/cable/connection.cr#receive`. Kept as a separate method
  # so the size-check wrapper above stays a thin shim. The trailing
  # `return`s of the upstream version (`return subscribe(...) if ...`)
  # are flagged by `ameba`'s `Style/RedundantReturn` and have been
  # rewritten as a `case` to keep the dispatch logic intact while
  # keeping `script/cr run lib/ameba/bin/ameba.cr -- src/` clean.
  def receive_without_size_check(message : String)
    return unless message.presence
    payload = Cable::Payload.from_json(message)

    case payload.command
    when "subscribe"   then subscribe(payload)
    when "unsubscribe" then unsubscribe(payload)
    when "message"     then message(payload)
    end
  end
end
