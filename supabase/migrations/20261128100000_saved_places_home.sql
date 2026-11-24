-- A rider can mark one saved place as home, to ride there in one tap. Home is
-- its own row (kind = 'home'), separate from the places they starred; setting
-- a new home updates that row rather than adding another. Existing row-level
-- security already keeps it to its owner, and it counts toward the 50-place
-- limit like any saved place.

alter table saved_places
  add column kind text check (kind in ('home'));

create unique index saved_places_one_home_idx
  on saved_places (user_id)
  where kind = 'home';
