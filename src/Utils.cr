# Monkeypatch the User struct to have an easy to use method for getting a user's tag
module Discord
  struct User
    def tag
      "#{username}##{discriminator}"
    end
  end
end

# A data structure wrapping an Array that doesn't keep more than @capacity entries
class LimitedQueue(T)
  def initialize(@capacity : UInt64)
    @backing = Array(T).new(@capacity)
    @top = 0u64
  end

  def <<(value : T)
    push(value)
  end

  def push(value : T)
    if @top == @capacity
      @top = 0
    end
    if @top >= @backing.size
      @backing << value
    else
      @backing[@top] = value
    end
  end

  def [](index : UInt64)
    @backing[index]
  end

  def []?(index : UInt64)
    @backing[index]?
  end

  def any?(&block)
    @backing.each { |e| return true if yield e }
    false
  end
end

# get_system? but asserts that there is one
def get_system(id : Discord::Snowflake | String) : Models::System
  get_system?(id).not_nil!
end

# try to get a DB system either by its discord ID (snowflake arg)
# or its pk id (string arg)
def get_system?(id : Discord::Snowflake | String) : Models::System?
  if id.is_a?(Discord::Snowflake)
    Database.query_all(
      "select * from systems where discord_id=?",
      id.to_u64.to_i64,
      as: Models::System
    )[0]?
  elsif id.is_a?(String)
    Database.query_all(
      "select * from systems where pk_system_id=?",
      id,
      as: Models::System
    )[0]?
  else
    raise "Unreachable"
  end
end

# get all members of a DB system
def get_members(system : Models::System) : Array(Models::Member)
  Database.query_all(
    "select * from members where system_discord_id=? and deleted=false",
    system.discord_id.to_u64.to_i64,
    as: Models::Member
  )
end

# get the bot instance associated with a DB member
def get_bot(member : Models::Member) : MemberBot
  Members.select { |m| m.db_data.pk_member_id == member.pk_member_id }[0]
end

def contains_tag?(content : String, tag : Models::PKProxyTag) : Bool
  if tag.prefix && tag.suffix
    return content.starts_with?(tag.prefix.not_nil!) && content.ends_with?(tag.suffix.not_nil!)
  elsif tag.prefix
    return content.starts_with?(tag.prefix.not_nil!)
  elsif tag.suffix
    return content.ends_with?(tag.suffix.not_nil!)
  else
    return false
  end
end

# just a special type of exception for foreseen circumstances so that we can
# display a hopefully more helpful message than "Nil assertion failed"
class PaucalError < Exception
end

# Actually, not necessarily "user error", just "user-friendly error". Important
# distinction.
def user_error(msg : String)
  raise PaucalError.new(msg)
end
