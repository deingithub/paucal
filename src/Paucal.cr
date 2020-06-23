require "db"
require "discordcr"
require "dotenv"
require "sqlite3"

require "log"

Dotenv.load
Log.setup_from_env
Database = DB.open("sqlite3://#{ENV["DATABASE_PATH"]}")
Database.exec("pragma foreign_keys = on")

Members              = [] of MemberBot
Bots                 = {} of String => Channel(Models::MemberRequest)
BotIDs               = {} of String => Discord::Snowflake
LastSystemMessageIDs = {} of Discord::Snowflake => Discord::Snowflake
Systems              = Database.query_all("select * from systems", as: Models::System)

require "./Member"
require "./Models"
require "./Parent"

Log.info { "Starting Paucal." }

Database.query_all("select * from members where deleted = false", as: Models::Member).each do |member|
  Members << MemberBot.new(
    member,
    Discord::Client.new(token: "Bot #{member.token}")
  )
end

Log.info { "Have #{Members.size} member bots, booting them" }
Members.each do |m|
  m.start
  sleep 0.25
end

Log.info { "Booting Parent." }
parent = ParentBot.new(Discord::Client.new(token: "Bot #{ENV["PARENT_TOKEN"]}"))

sleep

def get_system(id : Discord::Snowflake | String)
  get_system?(id).not_nil!
end

def get_system?(id : Discord::Snowflake | String)
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

def get_members(system : Models::System)
  Database.query_all(
    "select * from members where system_discord_id=? and deleted=false",
    system.discord_id.to_u64.to_i64,
    as: Models::Member
  )
end

def get_bot(member : Models::Member)
  Members.select { |m| m.db_data.pk_member_id == member.pk_member_id }[0]
end
