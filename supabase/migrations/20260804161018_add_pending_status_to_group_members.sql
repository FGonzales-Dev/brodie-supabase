alter table group_members drop constraint ride_group_members_status_check;
alter table group_members add constraint ride_group_members_status_check
  check (status in ('pending', 'joined', 'left', 'fell_behind'));
