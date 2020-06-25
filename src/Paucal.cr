require "db"
require "discordcr"
require "dotenv"
require "sqlite3"

require "log"
require "./Utils"

Dotenv.load
Log.setup_from_env
Database = DB.open("sqlite3://#{ENV["DATABASE_PATH"]}")
Database.exec("pragma foreign_keys = on")

Members              = [] of MemberBot
LastSystemMessageIDs = {} of Discord::Snowflake => Discord::Snowflake

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
