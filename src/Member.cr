module Member
  # This is the closure backing a single Member bot. It awaits a new order from
  # the Parent bot, executes it, then yields until it gets a new one.
  def self.run(tube : Channel(Models::MemberRequest), client : Discord::Client)
    loop do
      begin
        command, data = tube.receive
        case command
        when Models::Command::Initialize
          spawn client.run
        when Models::Command::Post
          data = data.as({Discord::Snowflake, String})
          client.create_message(data[0], data[1])
        when Models::Command::Edit
          data = data.as({Discord::Snowflake, Discord::Snowflake, String})
          client.edit_message(data[0], data[1], data[2])
        when Models::Command::UpdateMemberPresence
          data = data.as(Discord::Snowflake)
          user = client.get_user(data)
          client.status_update("online", Discord::GamePlaying.new("#{user.username}##{user.discriminator}", :listening))
        when Models::Command::UpdateUsername
          data = data.as(String)
          client.modify_current_user(username: data)
        when Models::Command::UpdateAvatar
          data = data.as(String)
          client.modify_current_user(avatar: data)
        when Models::Command::UpdateNick
          data = data.as({Discord::Snowflake, String})
          client.modify_current_user_nick(data[0].to_u64, data[1])
        end
      rescue ex
        Log.error(exception: ex) { "Exception: #{ex}" }
      end
    end
  end
end
