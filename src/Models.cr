# monkeypatch snowflakes to be DB readable directly
module Discord
  struct Snowflake
    include DB::Mappable

    def self.new(rs : DB::ResultSet)
      self.new(rs.read(Int64).to_u64)
    end

    def to_i64
      self.to_u64.to_i64
    end
  end
end

# A pk system registered with Paucal.
class PKSystem
  include DB::Serializable

  property discord_id : Discord::Snowflake
  property pk_system_id : String
  property pk_token : String
  property current_fronter_pk_id : String?
  property autoproxy_enable : Bool
  property autoproxy_member : String?
end

# A member bot's login data.
class Bot
  include DB::Serializable

  property token : String
end

# A pk system member registered with Paucal.
class PKMember
  include DB::Serializable

  property pk_member_id : String
  property deleted : Bool
  property system_discord_id : Discord::Snowflake
  property token : String
  @[DB::Field(key: "pk_data")]
  property data : PKMemberData
  @[DB::Field(converter: ProxyTagListWhyMustICodeThisPleaseMakeThePainStop)]
  property local_tags : Array(PKProxyTag)?
  property disabled : Bool
end

class PKMemberData
  include JSON::Serializable
  include DB::Mappable

  def self.new(rs : DB::ResultSet)
    self.from_json(rs.read(String))
  end

  property id : String
  property name : String?
  property avatar_url : String?
  property proxy_tags : Array(PKProxyTag)
  property keep_proxy : Bool
end

class PKProxyTag
  include JSON::Serializable
  property prefix : String?
  property suffix : String?

  def to_s(io : IO)
    io << (@prefix || "") << "text" << (@suffix || "")
  end

  def initialize(@prefix, @suffix)
  end

  def matches?(content : String) : Bool
    starts_with = content.starts_with?(@prefix || "")
    ends_with = content.ends_with?(@suffix || "")
    return starts_with && ends_with if @prefix && @suffix
    return (@prefix && starts_with) || (@suffix && ends_with) || false
  end
end

class ProxyTagListWhyMustICodeThisPleaseMakeThePainStop
  def self.from_rs(rs)
    return Array(PKProxyTag).from_json(rs.read(String?) || return nil)
  end
end
