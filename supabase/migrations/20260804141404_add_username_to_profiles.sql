alter table profiles
  add column username text
    constraint profiles_username_format check (username ~ '^[a-z0-9_]{3,20}$');

-- Case-insensitive uniqueness: "RiderX" and "riderx" can't both exist.
create unique index profiles_username_lower_idx on profiles (lower(username));
