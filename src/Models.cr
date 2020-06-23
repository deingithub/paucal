module Models
  # Requests sent to Member bots (via unidirectional channel)
  alias MemberRequest = {Command, Data}

  # All the data that can be attached to an MemberRequest
  alias Data = Nil |
               String |
               {Discord::Snowflake, String} |
               {Discord::Snowflake, Discord::Snowflake, String} |
               Discord::Snowflake |
               {Discord::Snowflake, Discord::Snowflake}

  # The different kinds of request to Member bots
  # Crystal sadly seems to lack tagged unions, the comments document what types
  # Member#run can expect to receive alongside this command.
  # Be nice to Member#run.
  enum Command
    # Log in to Discord. Expects Nil.
    Initialize
    # Update bot presence to the tag of User. Expects User : Discord::Snowflake.
    UpdateMemberPresence
    # Post Content in ChannelId. Expects {Content : String, ChannelId : Discord::Snowflake}.
    Post
    # Edit MessageId in ChannelId to Content. Expects {ChannelId : Discord::Snowflake, MessageId : Discord::Snowflake, Content : String}.
    Edit
    # Update username to Username. Expects Username : String.
    UpdateUsername
    # Update avatar image to the image pointed at by Url. Expects Url : String.
    UpdateAvatar
    # Update nick in GuildID to Val. Expects {GuildID : Discord::Snowflake, Val : String}
    UpdateNick
    # Delete own message MessageID in channel ChannelID. Expects {MessageID : Discord::Snowflake, ChannelID : Discord::Snowflake}.
    Delete
    # Shut down the member bot. Expects Nil.
    Shutdown
  end

  # Helper class to safely convert DB strings to Crystal strings without really
  # obnoxious edge cases. Trust me, this is good.
  class DBString
    def self.from_rs(rs)
      rs.read.to_s
    end
  end

  class DBSnowflake
    def self.from_rs(rs)
      Discord::Snowflake.new(rs.read(Int64).to_u64)
    end
  end

  # A pk system registered with Paucal.
  class System
    DB.mapping({
      discord_id:   {type: Discord::Snowflake, converter: DBSnowflake},
      pk_system_id: {type: String, converter: DBString},
      pk_token:     {type: String, converter: DBString},
    })
  end

  # A member bot's login data.
  class Bot
    DB.mapping({
      token: {type: String, converter: DBString},
    })
  end

  # A pk system member registered with Paucal.
  class Member
    DB.mapping({
      pk_member_id:      {type: String, converter: DBString},
      deleted:           Bool,
      system_discord_id: {type: Discord::Snowflake, converter: DBSnowflake},
      token:             {type: String, converter: DBString},
      pk_data:           {type: String, converter: DBString},
    })

    def data
      PKMemberData.from_json(@pk_data)
    end
  end

  class PKMemberData
    JSON.mapping({
      id:         String,
      name:       String?,
      avatar_url: String?,
      proxy_tags: Array(PKProxyTag),
      keep_proxy: Bool,
    })
  end

  class PKProxyTag
    JSON.mapping({
      prefix: String?,
      suffix: String?,
    })

    def to_s(io : IO)
      io << "#{@prefix || ""}text#{@suffix || ""}"
    end
  end
end
