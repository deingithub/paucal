class MemberBot
  def initialize(@db_data : PKMember, @client : Discord::Client)
    @bot_id = Discord::Snowflake.new(0)
    @log = ::Log.for("member.#{@db_data.pk_member_id}")
  end

  property bot_id, db_data, client

  def start
    @client.on_ready do |payload|
      @bot_id = payload.user.id
      update_member_presence
      @log.info { "Member bot #{@bot_id} started" }
    end

    spawn @client.run
  end

  def stop
    @client.stop
    @log.info { "Member bot #{@bot_id} shutting down" }
  end

  def post(message : Discord::Message, pt : PKProxyTag)
    proxied = nil

    reference = message.referenced_message.not_nil!.message_reference if message.referenced_message

    content = message.content
    content = content.lchop(pt.prefix || "").rchop(pt.suffix || "") unless @db_data.data.keep_proxy

    proxied = @client.create_message(message.channel_id, content, message_reference: reference) if message.attachments.empty?

    first_attachment = true
    message.attachments.each do |attachment|
      HTTP::Client.get(attachment.url) do |resp|
        content = nil if !first_attachment || (content || "").empty?
        buffer = Bytes.new(attachment.size)
        resp.body_io.read_fully(buffer)

        msg = @client.upload_file(
          message.channel_id,
          content,
          file: IO::Memory.new(buffer),
          filename: attachment.filename,
          message_reference: reference
        )
        proxied = msg if first_attachment
      end

      first_attachment = false
    end

    LastSystemMessageIDs[@db_data.system_discord_id] = proxied.not_nil!.id
  end

  def edit(message : Discord::Message, text : String)
    @client.edit_message(message.channel_id, message.id, text)
  end

  def delete(message : Discord::Message)
    @client.delete_message(message.channel_id, message.id)
  end

  def update_member_presence
    user = @client.get_user(@db_data.system_discord_id)
    @client.status_update(
      "online",
      Discord::GamePlaying.new(user.tag, :listening)
    )
  end

  def update_avatar
    return if @db_data.data.avatar_url.nil?
    image_data = HTTP::Client.get(@db_data.data.avatar_url.not_nil!)
    data_uri = "data:"
    data_uri += (image_data.content_type.not_nil!).downcase
    data_uri += ";base64,"
    data_uri += Base64.strict_encode(image_data.body)
    @client.modify_current_user(avatar: data_uri)
  end

  def update_username
    @client.modify_current_user(username: "paucal.#{@db_data.pk_member_id}")
  end

  def sync_db_to_discord
    update_username
    update_avatar
  end

  def update_nick(guild_id : Discord::Snowflake, nick : String)
    @client.modify_current_user_nick(guild_id.to_u64, nick)
  end
end
