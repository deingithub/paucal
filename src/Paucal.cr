require "db"
require "discordcr"
require "dotenv"
require "sqlite3"

require "log"

Dotenv.load
Log.setup_from_env

Database = DB.open("sqlite3://#{ENV["DATABASE_PATH"]}")
Database.exec("pragma foreign_keys = on")

Members = {} of String => Models::Member
Bots    = {} of String => Channel(Models::MemberRequest)
BotIDs  = {} of String => Discord::Snowflake
Systems = Database.query_all("select * from systems", as: Model::System)

require "./Member"
require "./Models"
require "./Parent"

Log.info { "Starting Paucal." }

Database.query_all("select * from members where deleted = false", as: Models::Member).each do |member|
  channel = Channel(Models::MemberRequest).new
  client = Discord::Client.new(token: "Bot #{member.token}")
  client.on_ready do |payload|
    channel.send({Models::Command::UpdateMemberPresence, member.system_discord_id})
    BotIDs[member.pk_member_id] = payload.user.id
  end
  Members[member.pk_member_id] = member
  Bots[member.pk_member_id] = channel

  spawn Member.run(channel, client)
end

Log.info { "Have #{Bots.size} member bots, booting them." }
Bots.values.each do |val|
  val.send({Models::Command::Initialize, nil})
  sleep 0.25
end

Log.info { "Booting Parent." }

spawn Parent.run(Discord::Client.new(token: "Bot #{ENV["PARENT_TOKEN"]}"))

Log.info { "Handing over the stick." }

sleep
