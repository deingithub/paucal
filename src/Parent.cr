require "log"

class ParentBot
  def initialize(@client : Discord::Client)
    @log = ::Log.for("parent")
    @recently_proxied = LimitedQueue(Discord::Message).new(20)
    @client.on_message_create do |msg|
      delete_delete_log(msg)
      pings(msg)
      unless msg.author.bot
        commands(msg)
        proxy(msg)
      end
    end

    client.on_presence_update do |payload|
      next unless payload.user.username || payload.user.discriminator
      get_members(get_system?(payload.user.id) || next).each do |member|
        get_bot(member).update_member_presence
      end
    end

    spawn @client.run
  end

  def commands(msg)
    begin
      {% for command in %w(help whoami sync register unregister edit ed delete nick del explode) %}
      if msg.content.starts_with?(";;#{{{command}}}")
        @log.info{"Executing #{{{command}}} (\"#{msg.content}\") for #{msg.author.id}"}
        {{command.id}}(msg)
        return
      end
    {% end %}
    rescue ex : PaucalError
      @log.info(exception: ex) { "User error trying to execute command" }
      @client.create_message(
        msg.channel_id,
        ":x: #{ex.message}"
      )
    rescue ex
      @log.error(exception: ex) { "Internal error trying to execute command" }
      @client.create_message(
        msg.channel_id,
        ":x: There was an internal error trying to execute your command: `#{ex}`"
      )
    end
  end

  def explode(msg)
    user_error("this isn't supposed to work")
  end

  def proxy(msg)
    Members.to_a.each do |member|
      next unless member.db_data.system_discord_id == msg.author.id

      # grab the pk data
      pk_data = member.db_data.data
      # for all proxy tag sets:
      pk_data.proxy_tags.each do |pt|
        # skip unless only prefix is set and present in the message or
        next unless contains_tag?(msg.content, pt)

        # delete proxy tags if needed
        content = msg.content
        unless pk_data.keep_proxy
          content = content.lchop(pt.prefix || "").rchop(pt.suffix || "")
        end
        @client.delete_message(msg.channel_id, msg.id)
        @recently_proxied << msg
        member.post(msg.channel_id, content)
        return
      end
    end
  end

  def pings(msg)
    return if msg.author.id == @client.client_id

    accumulated_pings = [] of String
    msg.content.scan(/<@!?([0-9]+)>/).each do |match|
      mention = Discord::Snowflake.new(match[1])
      Members.each do |member|
        if member.bot_id == mention
          accumulated_pings << "<@#{member.db_data.system_discord_id}>"
        end
      end
    end
    accumulated_pings.reject!(msg.author.mention)
    unless accumulated_pings.empty?
      @client.create_message(
        msg.channel_id,
        "Don't mind me #{msg.author.tag}, just pinging the relevant accounts: #{accumulated_pings.join(", ")}"
      )
    end
  end

  def delete_delete_log(msg)
    return unless msg.channel_id == Discord::Snowflake.new(ENV["DELETE_LOGS_CHANNEL"])
    return unless msg.author.id == Discord::Snowflake.new(ENV["DELETE_LOGS_USER"])
    embed = msg.embeds[0]? || return
    desc = embed.description || return
    return unless @recently_proxied.any? { |oldmsg| desc.includes?(oldmsg.id.to_s) }
    @client.delete_message(msg.channel_id, msg.id)
  end

  def help(msg)
    @client.create_message(
      msg.channel_id,
      <<-HELP
      **Paucal** is a prototype PluralKit supplement bot. 
      `;;help` Display all of this.

      *System Commands: To use these, your system needs to be manually registered first — ask a bot admin for this.*
      `;;sync` Synchronize the data of Paucal-registered members with the PluralKit API.
      `;;register <pk member id>` Register `<pk member id>` with Paucal to make them proxyable with the bot.
      `;;unregister <pk member id>` Irreversibly unregister `<pk member id>` from Paucal.
      `;;whoami` Show which members are already registered with Paucal.

      *Member Commands*
      ~~`;;role <@member> <rolename>` Toggle the presence of `<rolename>` on the mentioned member.~~
      `;;nick <@member> <nick>` Update the mentioned member's nick on the server to `<nick>`.

      *Message Commands: These only work on messages that have been proxied for your account. To obtain message IDs, enable developer mode and right-click/long tap the relevant message.*
      `;;edit <message id> <text>` Update `<message id>` to contain `<text>`.
      `;;delete <message id>` Delete `<message id>`.
      `;;ed <text>` Update the last-proxied message to contain `<text>`.
      `;;del` Delete the last-proxied message.
      HELP
    )
  end

  def sync(msg)
    system = get_system?(msg.author.id) || user_error("Your system isn't registered with Paucal yet.")

    # iterate over all members and replace their pk_data with new data from
    # the API (can throw every time, wrapping it in a transaction ensures
    # consistency between different states in the system)
    Database.transaction do |trans|
      get_members(system).each do |member|
        pk_data =
          begin
            http_data = HTTP::Client.get(
              "https://api.pluralkit.me/v1/m/#{member.pk_member_id}",
              headers: HTTP::Headers{
                "Authorization" => system.pk_token,
              }
            ).body
            Models::PKMemberData.from_json(http_data)
          rescue ex
            user_error("No well-formed API response for `#{member.pk_member_id}`.")
          end

        trans.connection.exec(
          "update members set pk_data=? where pk_member_id=?",
          pk_data.to_json, member.pk_member_id
        )
      end
    end

    get_members(system).each do |db_member|
      bot = Members.find { |m| m.db_data.pk_member_id == db_member.pk_member_id }.not_nil!
      bot.db_data = db_member
      begin
        bot.sync_db_to_discord
      rescue ex
        user_error("Failed to push updates for <@#{get_bot(db_member).bot_id}> to Discord, most likely due to a rate limit. Try again later.")
      end
    end

    @client.create_message(msg.channel_id, "Successfully pulled in all recent changes to your members.")
  end

  def register(msg)
    system = get_system?(msg.author.id) || user_error("Your system isn't registered with Paucal yet.")

    pk_member_id = msg.content.lchop(";;register").strip
    user_error("You need to supply a five-character member ID.") unless pk_member_id.size == 5

    pk_data = Array(Models::PKMemberData).from_json(
      HTTP::Client.get(
        "https://api.pluralkit.me/v1/s/#{system.pk_system_id}/members",
        headers: HTTP::Headers{
          "Authorization" => system.pk_token,
        }
      ).body
    )
    new_member_data = pk_data.find { |m| m.id == pk_member_id } || user_error("Couldn't find that member ID among your system members.")
    Database.transaction do |trans|
      free_token = trans.connection.query_all(
        "select * from bots where not exists (select members.token from members where members.token = bots.token)",
        as: Models::Bot
      )[0]? || user_error("No free slots at the moment. Contact a moderator.")

      trans.connection.exec(
        "insert into members (pk_member_id, system_discord_id, token, pk_data) values (?,?,?,?)",
        new_member_data.id, system.discord_id.to_u64.to_i64, free_token.token, new_member_data.to_json
      )
      new_member = trans.connection.query_all(
        "select * from members where pk_member_id=?",
        new_member_data.id,
        as: Models::Member
      )[0]

      auto_sync_client = Discord::Client.new(token: "Bot #{free_token.token}")
      new_bot = MemberBot.new(
        new_member,
        auto_sync_client
      )
      auto_sync_client.on_ready do |payload|
        new_bot.sync_db_to_discord
        new_bot.update_nick(
          (msg.guild_id || raise "not in a guild"),
          new_member_data.name || new_member_data.id
        )
        @log.info { "Added Member #{pk_member_id} to system #{system.discord_id}" }
        @client.create_message(msg.channel_id, "Successfully added member `#{pk_member_id}`: #{payload.user.mention}.")
      end

      Members << new_bot
      new_bot.start
    end
  end

  def unregister(msg)
    pk_member_id = msg.content.lchop(";;unregister").strip
    user_error("You need to supply a five-character member ID.") unless pk_member_id.size == 5

    Database.exec(
      "update members set deleted=true,pk_data='' where system_discord_id=? and pk_member_id=?",
      msg.author.id.to_u64.to_i64, pk_member_id
    )

    check_it_worked = Database.query_all(
      "select * from members where deleted=true and pk_member_id=?",
      pk_member_id,
      as: Models::Member
    )[0]?
    user_error("No such member in your system.") unless check_it_worked

    Members.find { |m| m.db_data.pk_member_id == pk_member_id }.not_nil!.stop
    Members.reject! { |m| m.db_data.pk_member_id == pk_member_id }
    @log.info { "Deleted member #{pk_member_id} from system #{msg.author.id}" }
    @client.create_message(msg.channel_id, "Successfully unregistered member.")
  end

  def edit(msg)
    args = msg.content.lchop(";;edit").strip.split(" ")

    the_message =
      begin
        id = Discord::Snowflake.new(args.shift)
        @client.get_channel_message(msg.channel_id, id)
      rescue ex
        user_error("No message with that ID.")
      end

    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.edit(the_message, args.join(" "))
      @client.delete_message(msg.channel_id, msg.id)
      return
    end
    user_error("Couldn't edit message.")
  end

  def ed(msg)
    text = msg.content.lchop(";;ed").strip
    the_message = @client.get_channel_message(
      msg.channel_id,
      LastSystemMessageIDs[msg.author.id]? || user_error("No recently proxied message in memory.")
    )

    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.edit(the_message, text)
      @client.delete_message(msg.channel_id, msg.id)
      return
    end
    user_error("Couldn't edit message.")
  end

  def delete(msg)
    args = msg.content.lchop(";;delete").strip.split(" ")

    the_message =
      begin
        id = Discord::Snowflake.new(args.shift)
        @client.get_channel_message(msg.channel_id, id)
      rescue ex
        user_error("No message with that ID.")
      end

    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.delete(the_message)
      @client.delete_message(msg.channel_id, msg.id)
      return
    end
    user_error("Couldn't delete message.")
  end

  def del(msg)
    the_message = @client.get_channel_message(
      msg.channel_id,
      LastSystemMessageIDs[msg.author.id]? || user_error("No recently proxied message in memory.")
    )

    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.delete(the_message)
      LastSystemMessageIDs.delete(msg.author.id)
      @client.delete_message(msg.channel_id, msg.id)
      return
    end
    user_error("Couldn't delete message.")
  end

  def nick(msg)
    args = msg.content.lchop(";;nick").strip.split(" ")

    mention =
      begin
        Discord::Snowflake.new(args.shift.delete { |x| !x.ascii_number? })
      rescue ex
        user_error("That doesn't look like a mention.")
      end

    name = args.join(" ")
    user_error("That name is too long (#{name.size}/32)") unless name.size <= 32

    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      if bot.bot_id == mention
        bot.update_nick(msg.guild_id || user_error("You're not in a guild."), name)
        return
      end
    end
    user_error("Couldn't update this user's nick.")
  end

  def whoami(msg)
    system = get_system?(msg.author.id) || user_error("Your system isn't registered with Paucal yet.")
    members = get_members(system)
    members_str = members.map { |m|
      "- `#{m.pk_member_id}` <@#{get_bot(m).bot_id}> (#{m.data.proxy_tags.join(", ")})"
    }.join("\n")
    if members.empty?
      members_str = "- None at all."
    end
    @client.create_message(
      msg.channel_id,
      <<-YOU
      You are system `#{system.pk_system_id}`. #{members.size} Members are registered with Paucal, namely:
      #{members_str}
      YOU
    )
  end
end
