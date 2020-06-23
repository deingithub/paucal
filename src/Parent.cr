require "log"

module Parent
  def self.run(client : Discord::Client)
    client.on_message_create do |msg|
      next if msg.author.bot
      mess = msg.content
      if mess.starts_with?(";;help")
        client.create_message(
          msg.channel_id,
          <<-HELP
        **Paucal** is a prototype PluralKit supplement bot. 
        `;;help` Display all of this.

        *System Commands: To use these, your system needs to be manually registered first — ask a bot admin for this.*
        `;;sync` Synchronize the data of Paucal-registered members with the PluralKit API.
        `;;register <pk member id>` Register `<pk member id>` with Paucal to make them proxyable with the bot.
        ~~`;;unregister <pk member id>` Irreversibly unregister `<pk member id>` from Paucal.~~
        ~~`;;whoami` Show which members are already registered with Paucal.~~

        *Member Commands*
        ~~`;;role <@member> <rolename>` Toggle the presence of `<rolename>` on the mentioned member.~~
        `;;nick <@member> <nick>` Update the mentioned member's nick on the server to `<nick>`.

        *Message Commands: These only work on messages that have been proxied for your account. To obtain message IDs, enable developer mode and right-click/long tap the relevant message.*
        ~~`;;edit <message id> <text>` Update `<message id>` to contain `<text>`.~~
        ~~`;;delete <message id>` Delete `<message id>`.~~
        ~~`;;ed <text>` Update the last-proxied message to contain `<text>`.~~
        ~~`;;del` Delete the last-proxied message.~~
        HELP
        )
      elsif mess.starts_with?(";;sync")
        # get this system (throws if not registered, that's fine for mvp)
        system = Database.query_all(
          "select * from systems where discord_id=?",
          msg.author.id.to_u64.to_i64,
          as: Models::System
        )[0]

        # iterate over all members and replace their pk_data with new data from
        # the API (can throw every time, wrapping it in a transaction ensures
        # consistency between different states in the system)
        Database.transaction do |trans|
          Database.query_all(
            "select * from members where system_discord_id=?",
            system.discord_id.to_u64.to_i64,
            as: Models::Member
          ).each do |member|
            # get member from pk (may throw)
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

        # push all updates to discord
        Database.query_all(
          "select * from members where system_discord_id=?",
          system.discord_id.to_u64.to_i64,
          as: Models::Member
        ).each do |member|
          Members[member.pk_member_id].pk_data = member.pk_data
          data = Models::PKMemberData.from_json(member.pk_data)
          channel = Bots[member.pk_member_id]
          channel.send({Models::Command::UpdateUsername, data.name})
          channel.send({Models::Command::UpdateAvatar, data.avatar_url})
        end

        client.create_message(msg.channel_id, "Successfully pulled in all recent changes to your members.")
      elsif mess.starts_with?(";;register")
        # get argument
        pk_member_id = mess.lchop(";;register").strip
        # get this system (throws if not registered, that's fine for mvp)
        system = Database.query_all(
          "select * from systems where discord_id=?",
          msg.author.id.to_u64.to_i64,
          as: Models::System
        )[0]

        # get all system members from pk (may throw)
        pk_data = Array(Models::PKMemberData).from_json(
          HTTP::Client.get(
            "https://api.pluralkit.me/v1/s/#{system.pk_system_id}/members",
            headers: HTTP::Headers{
              "Authorization" => system.pk_token,
            }
          ).body
        )
        # get the one we're interested in (throws if not found)
        new_member_data = pk_data.select { |m| m.id == pk_member_id }[0]
        Database.transaction do |trans|
          # get a free token (throws if not found)
          free_token = trans.connection.query_all(
            "select * from bots where not exists (select members.token from members where members.token = bots.token)",
            as: Models::Bot
          )[0]
          # insert found token into the member set and commit
          trans.connection.exec(
            "insert into members (pk_member_id, system_discord_id, token, pk_data) values (?,?,?,?)",
            new_member_data.id, system.discord_id.to_u64.to_i64, free_token.token, new_member_data.to_json
          )
        end

        # find new bot in the database and boot it, code is adapted(tm) from
        # overall initialization in src/Paucal.cr
        new_member = Database.query_all(
          "select * from members where pk_member_id=?",
          pk_member_id,
          as: Models::Member
        )[0]
        new_channel = Channel(Models::MemberRequest).new
        new_client = Discord::Client.new(token: "Bot #{new_member.token}")
        Members[new_member.pk_member_id] = new_member
        Bots[new_member.pk_member_id] = new_channel

        spawn Member.run(new_channel, new_client)
        new_channel.send({Models::Command::Initialize, nil})
        new_channel.send({Models::Command::UpdateUsername, new_member_data.name})
        new_channel.send({Models::Command::UpdateAvatar, new_member_data.avatar_url})
        new_channel.send({Models::Command::UpdateMemberPresence, msg.author.id})

        log(client, "Added member #{pk_member_id} to #{system.discord_id}")
        client.create_message(msg.channel_id, "Successfully added member `#{pk_member_id}` (#{new_member_data.name}).")
      elsif mess.starts_with?(";;edit")
      elsif mess.starts_with?(";;remove")
      elsif mess.starts_with?(";;nick")
        args = mess.lchop(";;nick").strip.split(" ")
        mention = args.shift
        mention = Discord::Snowflake.new(mention.delete { |x| !x.ascii_number? })
        name = args.join(" ")
        member_id = BotIDs.to_a.select { |key, val| val == mention }[0][0]
        Bots[member_id].send({Models::Command::UpdateNick, {msg.guild_id.not_nil!, name}})
      elsif mess.starts_with?(";;whoami")
        system = Systems.select { |s| s.discord_id == msg.author.id }[0]? || next
        members = Members.to_a.select { |id, m| m.system_discord_id == msg.author.id }
        members_str = members.map { |id, m|
          "- `#{id}` <@#{BotIDs[id]}> #{Models::PKMemberData.from_json(m.pk_data).name}"
        }.join("\n")
        if members.empty?
          members_str = "- None at all."
        end
        client.create_message(
          msg.channel_id,
          <<-YOU
          You are system `#{system.pk_system_id}`. #{members.size} Members are registered with Paucal, namely:
          #{members_str}
          YOU
        )
      end
      # now, go through all members and see if we should proxy this message
      # this variable is for early bailout and to prevent accidential doubleposts
      already_proxied_message = false
      Members.to_a.each do |member_id, member_data|
        next if already_proxied_message
        next unless member_data.system_discord_id == msg.author.id

        # grab the pk data
        pk_data = Models::PKMemberData.from_json(member_data.pk_data)
        # for all proxy tag sets:
        pk_data.proxy_tags.each do |pt|
          next if already_proxied_message
          # skip unless only prefix is set and present in the message or
          next unless (pt.prefix && !pt.suffix && mess.starts_with?(pt.prefix.not_nil!)) ||
                      # only suffix is set and present in the message or
                      (pt.suffix && !pt.prefix && mess.ends_with?(pt.suffix.not_nil!)) ||
                      # prefix and suffix are set and both present in the message
                      (pt.prefix && pt.suffix && mess.starts_with?(pt.prefix.not_nil!) && mess.ends_with?(pt.suffix.not_nil!))

          # delete proxy tags if needed
          content = mess
          unless pk_data.keep_proxy
            content = content.lchop(pt.prefix || "").rchop(pt.suffix || "")
          end

          already_proxied_message = true
          client.delete_message(msg.channel_id, msg.id)
          Bots[member_id].send({Models::Command::Post, {msg.channel_id, content}})
        end
      end
    end

    client.on_presence_update do |payload|
      next unless payload.user.username || payload.user.discriminator
      members = Members.to_a.select { |_, m| m.system_discord_id == payload.user.id }
      members.each do |member_id, _|
        Bots[member_id].send({Models::Command::UpdateMemberPresence, payload.user.id})
      end
    end

    client.run
  end

  def self.log(client : Discord::Client, info : String)
    Log.info { info }
    client.create_message(ENV["LOG_CHANNEL"].to_u64, info)
  end
end
