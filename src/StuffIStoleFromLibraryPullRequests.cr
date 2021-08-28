# The library is slow to update, so this is me monkeypatching in necessary
# stuff from MineBartekSA's Pull Requests that haven't been merged yet.

module Discord
  struct MessageReference
    include JSON::Serializable

    property message_id : Snowflake?
    property channel_id : Snowflake?
    property guild_id : Snowflake?
    property fail_if_not_exists : Bool?

    def initialize(@message_id = nil, @channel_id = nil, @guild_id = nil, @fail_if_not_exists = nil)
    end
  end

  struct Message
    property message_reference : MessageReference?
  end

  module REST
    def raw_request(route_key : Symbol, major_parameter : Snowflake | UInt64 | Nil, method : String, path : String, headers : HTTP::Headers, body : String | IO::Memory | Nil)
      mutexes = (@mutexes ||= Hash(RateLimitKey, Mutex).new)
      global_mutex = (@global_mutex ||= Mutex.new)

      headers["Authorization"] = @token
      headers["User-Agent"] = USER_AGENT

      request_done = false
      rate_limit_key = {route_key: route_key, major_parameter: major_parameter.try(&.to_u64)}

      until request_done
        mutexes[rate_limit_key] ||= Mutex.new

        # Make sure to catch up with existing mutexes - they may be locked from
        # another fiber.
        mutexes[rate_limit_key].synchronize { }
        global_mutex.synchronize { }

        Log.info { "[HTTP OUT] #{method} #{path} (#{body.try &.size || 0} bytes)" }
        Log.debug { "[HTTP OUT] BODY: #{body}" } if body.is_a?(String)

        body.rewind if body.is_a?(IO::Memory)

        response = HTTP::Client.exec(method: method, url: API_BASE + path, headers: headers, body: body, tls: SSL_CONTEXT)

        Log.info { "[HTTP IN] #{response.status_code} #{response.status_message} (#{response.body.size} bytes)" }
        Log.debug { "[HTTP IN] BODY: #{response.body}" }

        if response.status_code == 429 || response.headers["X-RateLimit-Remaining"]? == "0"
          retry_after_value = response.headers["X-RateLimit-Reset-After"]? || response.headers["Retry-After"]?
          retry_after = retry_after_value.not_nil!.to_f

          if response.headers["X-RateLimit-Global"]?
            Log.warn { "Global rate limit exceeded! Pausing all requests for #{retry_after}" }
            global_mutex.synchronize { sleep retry_after }
          else
            Log.warn { "Pausing requests for #{rate_limit_key[:route_key]} in #{rate_limit_key[:major_parameter]} for #{retry_after}" }
            mutexes[rate_limit_key].synchronize { sleep retry_after }
          end

          # If we actually got a 429, i. e. the request failed, we need to
          # retry it.
          request_done = true unless response.status_code == 429
        else
          request_done = true
        end
      end

      response.not_nil!
    end

    def request(route_key : Symbol, major_parameter : Snowflake | UInt64 | Nil, method : String, path : String, headers : HTTP::Headers, body : String | IO::Memory | Nil)
      response = raw_request(route_key, major_parameter, method, path, headers, body)

      unless response.success?
        raise StatusException.new(response) unless response.content_type == "application/json"

        begin
          error = APIError.from_json(response.body)
        rescue
          raise StatusException.new(response)
        end
        raise CodeException.new(response, error)
      end

      response
    end

    private def send_file(old_body : String, file : String | IO | Nil, filename : String?) : {IO::Memory, String}
      file = File.open(file) if file.is_a?(String)
      filename = (file.is_a?(File) ? File.basename(file.path) : "") unless filename
      builder = HTTP::FormData::Builder.new((io = IO::Memory.new))
      builder.field("payload_json", old_body, HTTP::Headers{"Content-Type" => "application/json"})
      builder.file("file", file, HTTP::FormData::FileMetadata.new(filename: filename))
      builder.finish
      {io, builder.content_type}
    end

    def create_message(channel_id : UInt64 | Snowflake, content : String? = nil, embeds : Array(Embed)? = nil, file : String | IO | Nil = nil,
                       filename : String? = nil, tts : Bool = false,
                       message_reference : MessageReference? = nil,
                       nonce : Int64 | String? = nil)
      body = encode_tuple(
        content: content,
        tts: tts,
        embeds: embeds,
        message_reference: message_reference,
        nonce: nonce,
      )

      content_type = "application/json"
      body, content_type = send_file(body, file, filename) if file

      response = request(
        :channels_cid_messages,
        channel_id,
        "POST",
        "/channels/#{channel_id}/messages",
        HTTP::Headers{"Content-Type" => content_type},
        body
      )

      Message.from_json(response.body)
    end
  end
end
