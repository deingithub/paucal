module Models
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
