-- Online rematch: either player of a finished match taps Rematch; the first
-- tap creates a linked rematch room (names carried over, fresh deck), the
-- second tap joins it. The finished match row broadcasts the offer to the
-- other player via rematch_id/rematch_by over the existing realtime channel.
-- Deliberate deviation from create_match: no "abandon my other waiting rooms"
-- sweep, so an unrelated open invite room survives a rematch.

alter table public.matches
  add column if not exists rematch_id uuid references public.matches(id),
  add column if not exists rematch_by uuid;

create or replace function public.rematch_match(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_uid    uuid := auth.uid();
  v_old    matches%rowtype;
  v_new    matches%rowtype;
  v_deck   int[];
  v_code   text;
  v_tries  int := 0;
  v_recent int;
  v_name   text;
  v_new_id uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  select * into v_old from matches where id = p_match_id for update;
  if v_old.id is null then raise exception 'match not found'; end if;
  if v_uid <> v_old.host_id and (v_old.guest_id is null or v_uid <> v_old.guest_id) then
    raise exception 'not your match';
  end if;
  if v_old.status <> 'finished' then raise exception 'match not finished'; end if;

  v_name := coalesce(
    case when v_uid = v_old.host_id then v_old.players->0->>'name'
         else v_old.players->1->>'name' end, 'Player');

  -- Second tap: the rematch room already exists; join it. Re-taps by the
  -- creator and taps after activation just return the current row.
  if v_old.rematch_id is not null then
    select * into v_new from matches where id = v_old.rematch_id for update;
    if v_new.id is null then raise exception 'rematch not found'; end if;
    if v_new.host_id = v_uid or v_new.status <> 'waiting' then
      return _match_row(v_new.id);
    end if;
    if v_new.created_at < now() - interval '15 minutes' then
      update matches set status='abandoned', end_reason='expired' where id = v_new.id;
      raise exception 'room expired';
    end if;
    update matches set
      guest_id     = v_uid,
      players      = jsonb_set(players, '{1,name}', to_jsonb(left(v_name,12))),
      status       = 'active',
      turn         = 0,
      turn_started = now(),
      last_seen_1  = now()
    where id = v_new.id;
    return _match_row(v_new.id);
  end if;

  -- First tap: create the rematch room, same limits and dealing as create_match
  select count(*) into v_recent
    from matches
   where host_id = v_uid and created_at > now() - interval '1 hour';
  if v_recent >= 20 then raise exception 'rate limit exceeded'; end if;

  select array_agg(id order by random()) into v_deck from cards where not is_meta;
  if v_deck is null or cardinality(v_deck) < 3 then
    raise exception 'card table not seeded';
  end if;

  loop
    v_code := (select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789',
                (floor(random()*31)+1)::int, 1), '')
               from generate_series(1,6));
    exit when not exists (select 1 from matches where code = v_code and status in ('waiting','active'));
    v_tries := v_tries + 1;
    if v_tries > 20 then raise exception 'could not allocate code'; end if;
  end loop;

  insert into matches (code, host_id, players, timeline, current_card_id, deck_pos)
  values (
    v_code, v_uid,
    jsonb_build_array(
      jsonb_build_object('name', left(v_name,12), 'lives', 3, 'score', 0, 'streak', 0, 'maxStreak', 0),
      jsonb_build_object('name', null,            'lives', 3, 'score', 0, 'streak', 0, 'maxStreak', 0)),
    jsonb_build_array(jsonb_build_object('card_id', v_deck[1], 'wrong', false)),
    v_deck[2], 2
  )
  returning id into v_new_id;

  insert into match_decks (match_id, deck) values (v_new_id, v_deck);

  update matches set rematch_id = v_new_id, rematch_by = v_uid where id = v_old.id;

  return _match_row(v_new_id);
end;
$$;

revoke all on function public.rematch_match(uuid) from public;
revoke execute on function public.rematch_match(uuid) from anon;
grant execute on function public.rematch_match(uuid) to authenticated, service_role;
