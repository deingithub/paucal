require "log"

class ParentBot
  Log = ::Log.for("parent")

  def initialize(@client : Discord::Client)
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
      {% for command in %w(help whoarewe sync register edit ed delete nick del signup front autoproxy ap disable enable tags switch) %}
      if msg.content.starts_with?(";;#{{{command}}}")
        Log.info{"Executing #{{{command}}} (\"#{msg.content}\") for #{msg.author.id}"}
        {{command.id}}(msg)
        return
      end
    {% end %}
    rescue ex : PaucalError
      Log.error(exception: ex) { "Anticipated error trying to execute command" }
      @client.create_message(
        msg.channel_id,
        ":x: #{ex.message}"
      )
    rescue ex
      Log.error(exception: ex) { "Internal error trying to execute command" }
      @client.create_message(
        msg.channel_id,
        ":x: There was an internal error trying to execute your command: `#{ex}`"
      )
    end
  end

  def proxy(msg)
    pk_system = get_system?(msg.author.id) || return

    mb = Members.find { |bot|
      pk_data = bot.db_data.data
      tags = bot.db_data.local_tags || pk_data.proxy_tags

      bot.db_data.system_discord_id == msg.author.id &&
        !bot.db_data.disabled &&
        tags.any? { |pt| pt.matches?(msg.content) }
    }

    if !mb && pk_system.autoproxy_enable && pk_system.autoproxy_member
      mb = Members.find { |bot| bot.db_data.pk_member_id == pk_system.autoproxy_member }
    elsif !mb && pk_system.autoproxy_enable && pk_system.current_fronter_pk_id
      mb = Members.find { |bot| bot.db_data.pk_member_id == pk_system.current_fronter_pk_id }
    elsif !mb && pk_system.autoproxy_latch && pk_system
      mb = Members.find { |bot| bot.db_data.pk_member_id == pk_system.latch }
    end

    if mb
      pk_data = mb.db_data.data
      tags = mb.db_data.local_tags || pk_data.proxy_tags
      proxy_tag = tags.find { |pt| pt.matches?(msg.content) }

      mb.post(msg, proxy_tag)
      @recently_proxied << msg
      @client.delete_message(msg.channel_id, msg.id)
      if pk_system.autoproxy_latch
        pk_system.latch = mb.db_data.pk_member_id
        Database.exec("update systems set latch = ? where pk_system_id = ?", mb.db_data.pk_member_id, pk_system.pk_system_id)
      end
    end
  end

  def pings(msg)
    return if msg.author.id == @client.client_id
    return if Members.any? { |mb| mb.bot_id == msg.author.id }

    accumulated_pings = [] of String
    msg.mentions.each do |user|
      mb = Members.find { |mb| mb.bot_id == user.id } || next
      next if mb.db_data.system_discord_id == msg.author.id

      accumulated_pings << "<@#{mb.db_data.system_discord_id}>"
    end

    @client.create_message(
      msg.channel_id,
      "Don't mind me #{msg.author.tag}, just pinging the relevant accounts: #{accumulated_pings.join(", ")}"
    ) unless accumulated_pings.empty?
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
      `;;signup` Sign up for Paucal.

      *System Commands: To use these, your system needs to be registered first with `;;signup`.*
      `;;sync` Synchronize the data of Paucal-registered members with the PluralKit API.
      `;;register <pk member id>` Register `<pk member id>` with Paucal to make them proxyable with the bot.
      `;;whoarewe` Show which members are already registered with Paucal.
      `;;autoproxy <mode/@member>`, `;;ap` Set auto-proxying to `front`, `off`, `latch` or a mentioned system member.
      `;;switch <@member>` Switch the current fronter to the mentioned member. This has little effect until you set `;;ap` to `front`.

      *Member Commands*
      `;;nick <@member> <nick>` Update the mentioned member's nick on the server to `<nick>`.
      `;;disable <@member>` Temporarily disable the mentioned members. No messages will be proxied for them.
      `;;enable <@member>` Re-enable the mentioned members that have been disabled previously.
      `;;tags <@member> <proxy tags>` Set the Paucal-only proxy tags for the member. The list must be space-separated, with prefix and suffix around `text`, e.g.: `[text] Atext textA` for three proxy tags, one with prefix and suffix and one with each prefix and suffix only. If these are enabled, messages won't be proxied with the PluralKit tags anymore.

      *Message Commands: These only work on messages that have been proxied for your account. Reply to the messages you want to edit or delete. If you don't reply to a message, the last proxied message for your system will be affected.*
      `;;edit <text>`, `;;ed` Update the replied-to or last proxied message to contain `<text>`.
      `;;delete`, `;;del` Delete the replied-to or last proxied message.
      HELP
    )
  end

  def signup(msg)
    if get_system?(msg.author.id)
      anticipate(
        "You're already signed up with Paucal. If there's an issue with your system data, please contact the bot operator."
      )
    end
    if msg.content == ";;signup"
      channel = @client.create_dm(msg.author.id)
      @client.create_message(
        channel.id,
        <<-TEXT
        Hi! Thanks for your interest in Paucal. To sign up, you'll need your **PluralKit token**. You can find out what it is using `pk;token`.
        It should be a long string of characters that allows Paucal access to your profile data even if it's set to private.
        Paucal will only ever perform reads on your system data, and only if you explicitly request them.
        However, If you use ;;switch with Paucal, it will also update your PluralKit switch history with the new fronter.
        If you want to, you can reset your token after you have registered all members you want to, using `pk;token refresh`.

        *Once you've found your token, come back to* ***this DM channel*** *and type* `;;signup <Token>`.
        TEXT
      )
    else
      token = msg.content.lchop(";;signup").strip

      system_response = HTTP::Client.get(
        "https://api.pluralkit.me/v2/systems/@me",
        headers: HTTP::Headers{
          "Authorization" => token,
        }
      )
      anticipate("Your token doesn't seem to be valid.") if system_response.status_code == 401
      pk_system = Hash(String, String?).from_json(system_response.body)

      Database.exec(
        "insert into systems(discord_id, pk_system_id, pk_token) values(?,?,?)",
        msg.author.id.to_i64, pk_system["id"], token
      )

      @client.create_message(
        msg.channel_id,
        "Your system is now signed up. Use `;;register <Member ID>` to register individual members with Paucal."
      )
    end
  end

  def sync(msg)
    pk_system = get_system?(msg.author.id) || anticipate(
      "You're not signed up with Paucal yet. Please type `;;signup` to do that."
    )

    # iterate over all members and replace their pk_data with new data from
    # the API (can throw every time, wrapping it in a transaction ensures
    # consistency between different states in the system)
    Database.transaction do |trans|
      get_members(pk_system).each do |member|
        http_data = HTTP::Client.get(
          "https://api.pluralkit.me/v2/systems/@me/members/#{member.pk_member_id}",
          headers: HTTP::Headers{
            "Authorization" => pk_system.pk_token,
          }
        ).body
        pk_data = PKMemberData.from_json(http_data)

        trans.connection.exec(
          "update members set pk_data=? where pk_member_id=?",
          pk_data.not_nil!.to_json, member.pk_member_id
        )
      end
    end

    get_members(pk_system).each do |member|
      bot = Members.find { |m| m.db_data.pk_member_id == member.pk_member_id }.not_nil!
      bot.db_data = member
      begin
        bot.sync_db_to_discord
      rescue ex
        anticipate(
          "Failed to push updates for <@#{bot.bot_id}> to Discord, most likely due to a rate limit. Try again later."
        )
      end
    end

    @client.create_message(msg.channel_id, "Successfully pulled in all recent changes to your members.")
  end

  def register(msg)
    pk_system = get_system?(msg.author.id) || anticipate(
      "You're not signed up with Paucal yet. Please type `;;signup` to do that."
    )

    pk_member_id = msg.content.lchop(";;register").strip
    anticipate("You need to supply a five-character member ID.") unless pk_member_id.size == 5

    pk_data = Array(PKMemberData).from_json(
      HTTP::Client.get(
        "https://api.pluralkit.me/v2/systems/@me/members",
        headers: HTTP::Headers{
          "Authorization" => pk_system.pk_token,
        }
      ).body
    )
    new_member_data = pk_data.find { |m| m.id == pk_member_id } || anticipate(
      "Couldn't find that member ID among your system members."
    )

    Database.transaction do |trans|
      free_token = trans.connection.query_all(
        "select * from bots where not exists (select members.token from members where members.token = bots.token)",
        as: Bot
      )[0]? || anticipate("No free slots at the moment. Contact the bot operator.")

      trans.connection.exec(
        "insert into members (pk_member_id, system_discord_id, token, pk_data) values (?,?,?,?)",
        new_member_data.id, pk_system.discord_id.to_i64, free_token.token, new_member_data.to_json
      )
      new_member = trans.connection.query_all(
        "select * from members where pk_member_id=?",
        new_member_data.id,
        as: PKMember
      )[0]

      auto_sync_client = Discord::Client.new(
        token: "Bot #{free_token.token}",
        zlib_buffer_size: 10*1024,
        intents: Discord::Gateway::Intents::None
      )
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
        Log.info { "Added Member #{pk_member_id} to system #{pk_system.discord_id}" }
        @client.create_message(msg.channel_id, "Successfully added member `#{pk_member_id}`: #{payload.user.mention}.")
      end

      Members << new_bot
      new_bot.start
    end
  end

  def edit(msg)
    the_message =
      begin
        if reference = msg.referenced_message
          @client.get_channel_message(
            reference.message_reference.channel_id.not_nil!,
            reference.message_reference.message_id.not_nil!
          )
        else
          @client.get_channel_message(
            msg.channel_id,
            LastSystemMessageIDs[msg.author.id]? || anticipate("No recently proxied message in memory.")
          )
        end
      end

    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.edit(the_message, msg.content.lchop(";;edit").lchop(";;ed"))
      @client.delete_message(msg.channel_id, msg.id)
      return
    end
    anticipate("Couldn't edit message.")
  end

  def ed(msg)
    edit(msg)
  end

  def delete(msg)
    the_message =
      begin
        if reference = msg.referenced_message
          @client.get_channel_message(
            reference.message_reference.channel_id.not_nil!,
            reference.message_reference.message_id.not_nil!
          )
        else
          @client.get_channel_message(
            msg.channel_id,
            LastSystemMessageIDs[msg.author.id]? || anticipate("No recently proxied message in memory.")
          )
        end
      end

    # only work on messages from our system account's members
    get_members(get_system(msg.author.id)).each do |member|
      bot = get_bot(member)
      next unless bot.bot_id == the_message.author.id
      bot.delete(the_message)
      @client.delete_message(msg.channel_id, msg.id)
      return
    end
    anticipate("Couldn't delete message.")
  end

  def del(msg)
    delete(msg)
  end

  def nick(msg)
    args = msg.content.lchop(";;nick").strip.split(" ")

    mention =
      begin
        Discord::Snowflake.new(args.shift.delete { |x| !x.ascii_number? })
      rescue ex
        anticipate("That doesn't look like a mention.")
      end

    name = args.join(" ")
    anticipate("That name is too long (#{name.size}/32)") unless name.size <= 32

    member_bot = Members.find { |mb|
      mention == mb.bot_id && mb.db_data.system_discord_id == msg.author.id
    } || anticipate("That doesn't seem to be one of your members.")
    member_bot.update_nick(msg.guild_id.not_nil!, name)
  end

  def whoarewe(msg)
    system = get_system?(msg.author.id) || anticipate("You're not signed up with Paucal yet. Please type `;;signup` to do that.")
    members = get_members(system)
    members_str = members.map { |m|
      s = "- <@#{get_bot(m).bot_id}>: **PluralKit ID**: `#{m.pk_member_id}`, "
      if local_tags = m.local_tags
        s += "**Paucal Tags:** #{local_tags.join(", ")} "
      else
        s += "**Tags:** #{m.data.proxy_tags.join(", ")} "
      end
      s += "(**Proxying Disabled**)" if m.disabled
      s
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

  def tags(msg)
    args = msg.content.lchop(";;tags ").split(" ")
    args.shift
    mb = Members.find { |mb| msg.mentions.any? { |u| u.id == mb.bot_id } && mb.db_data.system_discord_id == msg.author.id } || anticipate("You need to mention a member whose tags to set.")
    if args.empty?
      Database.exec(
        "update members set local_tags = null where pk_member_id = ?",
        mb.db_data.pk_member_id
      )
      mb.db_data.local_tags = nil
      @client.create_message(
        msg.channel_id,
        "Deleted Paucal-specific tags for <@#{mb.bot_id}>. Proxying will now work with PluralKit tags again."
      )
    else
      tag_error = "Tags need to look like this: `[text]` or `alice:text` or `text#bob`."
      tags = args.map { |arg|
        p arg
        anticipate(tag_error) unless arg.includes? "text"
        list = arg.split("text")
        if list.size == 2
          PKProxyTag.new(prefix: list[0], suffix: list[1])
        elsif list.size == 1
          if arg.lchop(list[0]) == "text"
            PKProxyTag.new(
              prefix: list[0],
              suffix: nil
            )
          else
            PKProxyTag.new(
              prefix: nil,
              suffix: list[0]
            )
          end
        else
          anticipate(tag_error)
        end
      }
      Database.exec(
        "update members set local_tags = ? where pk_member_id = ?",
        tags.to_json, mb.db_data.pk_member_id
      )
      mb.db_data.local_tags = tags
      @client.create_message(
        msg.channel_id,
        "Set Paucal-specific tags for <@#{mb.bot_id}>. Proxying will no longer work with PluralKit tags."
      )
    end
  end

  def front(msg)
  end

  def autoproxy(msg)
    case msg.content.lchop(";;ap ").lchop(";;autoproxy ")
    when "off"
      Database.exec(
        "update systems set autoproxy_member = null, autoproxy_enable = false, autoproxy_latch = false, latch = null where discord_id = ?",
        msg.author.id.to_i64
      )
      @client.create_message(
        msg.channel_id,
        "Disabled autoproxy."
      )
    when "front"
      Database.exec(
        "update systems set autoproxy_member = null, autoproxy_enable = true, autoproxy_latch = false, latch = null where discord_id = ?",
        msg.author.id.to_i64
      )

      message = "Autoproxy set to current fronter"

      current_system = get_system(msg.author.id)
      if fronter = current_system.current_fronter_pk_id
        member = get_members(current_system).find { |m| m.pk_member_id == fronter }.not_nil!
        message += " (<@#{get_bot(member).bot_id}>)."
      else
        message += ". Set the current fronter with `;;switch <@member>`."
      end

      @client.create_message(
        msg.channel_id,
        message
      )
    when "latch"
      Database.exec(
        "update systems set autoproxy_member = null, autoproxy_enable = false, autoproxy_latch = true, latch = null where discord_id = ?",
        msg.author.id.to_i64
      )

      @client.create_message(
        msg.channel_id,
        "Autoproxy set to latch."
      )
    else
      bot = Members.find { |mb|
        mb.db_data.system_discord_id == msg.author.id && msg.mentions.any? { |u| u.id == mb.bot_id }
      } || anticipate("I don't know that member.")

      Database.exec(
        "update systems set autoproxy_member = ?, autoproxy_enable = true, autoproxy_latch = false, latch = null where discord_id = ?",
        bot.db_data.pk_member_id, msg.author.id.to_i64
      )
      @client.create_message(msg.channel_id, "Set autoproxy to <@#{bot.bot_id}>.")
    end
  end

  def switch(msg)
    pk_system = get_system?(msg.author.id) || anticipate(
      "You're not signed up with Paucal yet. Please type `;;signup` to do that."
    )

    bot = Members.find { |mb|
      mb.db_data.system_discord_id == msg.author.id &&
        msg.mentions.any? { |u| u.id == mb.bot_id }
    }

    if bot
      Database.exec(
        "update systems set current_fronter_pk_id = ? where discord_id = ?",
        bot.db_data.pk_member_id, msg.author.id.to_i64
      )

      HTTP::Client.post(
        "https://api.pluralkit.me/v2/systems/@me/switches",
        headers: HTTP::Headers{
          "Authorization" => pk_system.pk_token,
          "Content-Type"  => "application/json",
        },
        body: {"members": [bot.db_data.pk_member_id]}.to_json
      )
      @client.create_message(msg.channel_id, "Switched to <@#{bot.bot_id}>.")
    else
      Database.exec(
        "update systems set current_fronter_pk_id = null where discord_id = ?",
        msg.author.id.to_i64
      )
      HTTP::Client.post(
        "https://api.pluralkit.me/v2/systems/@me/switches",
        headers: HTTP::Headers{
          "Authorization" => pk_system.pk_token,
          "Content-Type"  => "application/json",
        },
        body: {"members": [] of String}.to_json
      )
      @client.create_message(msg.channel_id, "Switched out.")
    end
  end

  def ap(msg)
    autoproxy(msg)
  end

  def disable(msg)
    msg.mentions.each do |user|
      mb = Members.find { |mb| mb.bot_id == user.id && mb.db_data.system_discord_id == msg.author.id } || next
      Database.exec(
        "update members set disabled = true where pk_member_id = ?",
        mb.db_data.pk_member_id
      )
      mb.db_data.disabled = true
      @client.create_message(
        msg.channel_id,
        "Temporarily disabled proxying for <@#{mb.bot_id}>. You can re-enable it using `;;enable` at any time."
      )
    end
  end

  def enable(msg)
    msg.mentions.each do |user|
      mb = Members.find { |mb| mb.bot_id == user.id && mb.db_data.system_discord_id == msg.author.id } || next
      Database.exec(
        "update members set disabled = false where pk_member_id = ?",
        mb.db_data.pk_member_id
      )
      mb.db_data.disabled = false
      @client.create_message(
        msg.channel_id,
        "Re-enabled proxying for <@#{mb.bot_id}>."
      )
    end
  end
end
