module Member
  # This is the closure backing a single Member bot. It awaits a new order from
  # the Parent bot, executes it, then yields until it gets a new one.
  def self.run(tube : Channel(Models::MemberRequest), system_discord_id : Discord::Snowflake, client : Discord::Client)
    loop do
      begin
        command, data = tube.receive
        case command
        when Models::Command::Initialize
          spawn client.run
        when Models::Command::Post
          data = data.as({Discord::Snowflake, Discord::Snowflake | String}) # this hits a bug with type coercion. really annoying.
          m = client.create_message(data[0], data[1].as(String))
          LastSystemMessageIDs[system_discord_id] = m.id
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
          image_data = HTTP::Client.get(data)
          data_str = "data:"
          data_str += (image_data.content_type || raise "no content type").downcase
          data_str += ";base64,"
          data_str += Base64.strict_encode(image_data.body)
          client.modify_current_user(avatar: data_str)
        when Models::Command::UpdateNick
          data = data.as({Discord::Snowflake, Discord::Snowflake | String}) # this hits a bug with type coercion. really annoying.
          client.modify_current_user_nick(data[0].to_u64, data[1].as(String))
        when Models::Command::Delete
          data = data.as({Discord::Snowflake, Discord::Snowflake | String}) # this hits a bug with type coercion. really annoying.
          client.delete_message(data[0], data[1].as(Discord::Snowflake))
        end
      rescue ex
        Log.error(exception: ex) { "Exception: #{ex}" }
      end
    end
  end
end
