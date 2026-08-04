create policy "Users can view their own vehicles"
  on vehicles for select
  using (auth.uid() = user_id);

create policy "Users can insert their own vehicles"
  on vehicles for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own vehicles"
  on vehicles for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users can delete their own vehicles"
  on vehicles for delete
  using (auth.uid() = user_id);
