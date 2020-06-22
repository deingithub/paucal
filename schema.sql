create table if not exists systems (
    discord_id integer primary key not null,
    pk_system_id string not null,
    pk_token string not null
);

create table if not exists bots (
    token string primary key not null
);

create table if not exists members (
    pk_member_id string primary key not null,
    deleted boolean not null default false,
    system_discord_id integer not null,
    token string not null,
    pk_data string not null,
    foreign key (system_discord_id) references systems(discord_id),
    foreign key (token) references bots(token)
);