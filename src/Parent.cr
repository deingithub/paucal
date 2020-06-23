require "log"

class ParentBot
  def initialize(@client : Discord::Client)
    @log = ::Log.for("parent")
    @client.on_message_create do |msg|
      next if msg.author.bot
      {% for command in %w(help whoami sync register unregister edit ed delete del) %}
        if msg.content.starts_with?(";;#{{{command}}}")
          {{command.id}}(msg)
          next
        end
      {% end %}
      proxy(msg)
    end

    client.on_presence_update do |payload|
      next unless payload.user.username || payload.user.discriminator
      get_members(get_system?(payload.user.id) || next).each do |member|
        get_bot(member).update_member_presence
      end
    end

    spawn @client.run
  end

  def proxy(msg)
    Members.to_a.each do |member|
      next unless member.db_data.system_discord_id == msg.author.id

      # grab the pk data
      pk_data = member.db_data.data
      # for all proxy tag sets:
      pk_data.proxy_tags.each do |pt|
        # skip unless only prefix is set and present in the message or
        next unless (pt.prefix && !pt.suffix && msg.content.starts_with?(pt.prefix.not_nil!)) ||
                    # only suffix is set and present in the message or
                    (pt.suffix && !pt.prefix && msg.content.ends_with?(pt.suffix.not_nil!)) ||
                    # prefix and suffix are set and both present in the message
                    (pt.prefix && pt.suffix && msg.content.starts_with?(pt.prefix.not_nil!) && msg.content.ends_with?(pt.suffix.not_nil!))

        # delete proxy tags if needed
        content = msg.content
        unless pk_data.keep_proxy
          content = content.lchop(pt.prefix || "").rchop(pt.suffix || "")
        end
        @client.delete_message(msg.channel_id, msg.id)
        member.post(msg.channel_id, content)
        return
      end
    end
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
    system = get_system(msg.author.id)

    # iterate over all members and replace their pk_data with new data from
    # the API (can throw every time, wrapping it in a transaction ensures
    # consistency between different states in the system)
    Database.transaction do |trans|
      get_members(system).each do |member|
        pk_data = Models::PKMemberData.from_json(
          HTTP::Client.get(
            "https://api.pluralkit.me/v1/m/#{member.pk_member_id}",
            headers: HTTP::Headers{
              "Authorization" => system.pk_token,
            }
          ).body
        )

        trans.connection.exec(
          "update members set pk_data=? where pk_member_id=?",
          pk_data.to_json, member.pk_member_id
        )
      end
    end

    get_members(system).each do |db_member|
      bot = Members.find { |m| m.db_data.pk_member_id == db_member.pk_member_id }.not_nil!
      bot.db_data = db_member
      bot.sync_db_to_discord
    end

    @client.create_message(msg.channel_id, "Successfully pulled in all recent changes to your members.")
  end

  def register(msg)
    pk_member_id = msg.content.lchop(";;register").strip
    system = get_system(msg.author.id)
    pk_data = Array(Models::PKMemberData).from_json(
      HTTP::Client.get(
        "https://api.pluralkit.me/v1/s/#{system.pk_system_id}/members",
        headers: HTTP::Headers{
          "Authorization" => system.pk_token,
        }
      ).body
    )
    new_member_data = pk_data.find { |m| m.id == pk_member_id }.not_nil!
    Database.transaction do |trans|
      free_token = trans.connection.query_all(
        "select * from bots where not exists (select members.token from members where members.token = bots.token)",
        as: Models::Bot
      )[0]
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
      end

      Members << new_bot
      new_bot.start

      @log.info { "Added Member #{pk_member_id} to system #{system.discord_id}" }
      @client.create_message(msg.channel_id, "Successfully added member `#{pk_member_id}` (#{new_member_data.name}).")
    end
  end

  def unregister(msg)
    pk_member_id = msg.content.lchop(";;unregister").strip
    Database.exec(
      "update members set deleted=true,pk_data='' where system_discord_id=? and pk_member_id=?",
      msg.author.id.to_u64.to_i64, pk_member_id
    )
    check_it_worked = Database.query_all(
      "select * from members where deleted=true and pk_member_id=?",
      pk_member_id,
      as: Models::Member
    )[0]
    Members.find { |m| m.db_data.pk_member_id == pk_member_id }.not_nil!.stop
    Members.reject! { |m| m.db_data.pk_member_id == pk_member_id }
    @log.info { "Deleted member #{pk_member_id} from system #{msg.author.id}" }
    @client.create_message(msg.channel_id, "Successfully unregistered member.")
  end

  def edit(msg)
    args = msg.content.lchop(";;edit").strip.split(" ")

    # get the wanted message from the current channel (both of these can throw on bad args)
    id = Discord::Snowflake.new(args.shift)
    the_message = @client.get_channel_message(msg.channel_id, id)

    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.edit(the_message, args.join(" "))
    end
    @client.delete_message(msg.channel_id, msg.id)
  end

  def ed(msg)
    text = msg.content.lchop(";;ed").strip
    the_message = @client.get_channel_message(msg.channel_id, LastSystemMessageIDs[msg.author.id])
    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.edit(the_message, text)
    end
    @client.delete_message(msg.channel_id, msg.id)
  end

  def delete(msg)
    args = msg.content.lchop(";;delete").strip.split(" ")

    # get the wanted message from the current channel (both of these can throw on bad args)
    id = Discord::Snowflake.new(args.shift)
    the_message = @client.get_channel_message(msg.channel_id, id)

    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.delete(the_message)
    end
    @client.delete_message(msg.channel_id, msg.id)
  end

  def del(msg)
    the_message = @client.get_channel_message(msg.channel_id, LastSystemMessageIDs[msg.author.id])
    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.delete(the_message)
    end
    LastSystemMessageIDs.delete(msg.author.id)
    @client.delete_message(msg.channel_id, msg.id)
  end

  def nick(msg)
    args = msg.content.lchop(";;nick").strip.split(" ")
    mention = args.shift
    mention = Discord::Snowflake.new(mention.delete { |x| !x.ascii_number? })
    name = args.join(" ")
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      if bot.bot_id == mention
        bot.nick(name)
      end
    end
  end

  def whoami(msg)
    system = get_system(msg.author.id)
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
