create table if not exists "chat_message"
(
    id text not null primary key,
    role text not null,
    content text not null,
    conversation_id text not null,
    parent_message_id text,
    created_at integer not null,
    updated_at integer not null
);