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

last_migration_number = 0
begin
  last_migration_number = Database.query_one(
    "SELECT * FROM applied_migrations ORDER BY number DESC LIMIT 1;",
    as: Int64
  )
rescue
end
Dir.open(Dir.current + "/migrations") do |dir|
  dir.children.sort.each do |filename|
    number = filename.rchop(".sql").to_i
    content = File.open("migrations/" + filename) { |f| f.gets_to_end }
    if number > last_migration_number
      Database.transaction do |trans|
        content.split(";").each do |statement|
          trans.connection.exec(statement) unless statement.blank?
        end
        trans.connection.exec("INSERT INTO applied_migrations VALUES(?)", number)
      end
      Log.info { "Applied migration #{number}" }
    end
  end
end

Database.query_all("select * from members where deleted = false", as: PKMember).each do |member|
  Members << MemberBot.new(
    member,
    Discord::Client.new(
      token: "Bot #{member.token}",
      zlib_buffer_size: 10*1024,
      intents: Discord::Gateway::Intents::None
    )
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
