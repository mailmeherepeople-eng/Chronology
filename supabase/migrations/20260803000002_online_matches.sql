-- ═══════════════════════════════════════════════════════════
--  Online two-player: friend rooms (Stage 1)
--  Server-authoritative matches. Clients read their own match row and
--  write ONLY through the RPCs below. The deck lives in match_decks,
--  which has no select policy — upcoming cards are never exposed.
--  (Applied to remote 2026-08-03 as online_matches.)
-- ═══════════════════════════════════════════════════════════

create table public.matches (
  id              uuid primary key default gen_random_uuid(),
  code            text unique not null,
  host_id         uuid not null references auth.users (id) on delete cascade,
  guest_id        uuid references auth.users (id) on delete set null,
  players         jsonb not null,
  timeline        jsonb not null default '[]'::jsonb,
  turn            int not null default 0,          -- 0 host, 1 guest
  current_card_id int,
  deck_pos        int not null default 2,          -- 1-based index of current card in deck
  turn_started    timestamptz,
  last_seen_0     timestamptz not null default now(),
  last_seen_1     timestamptz,
  status          text not null default 'waiting', -- waiting|active|finished|abandoned
  winner          int,                             -- 0|1|null (tie)
  end_reason      text,                            -- lives|deck|timeout_claim|resign
  created_at      timestamptz not null default now()
);

create table public.match_decks (
  match_id uuid primary key references public.matches (id) on delete cascade,
  deck     int[] not null
);

alter table public.matches     enable row level security;
alter table public.match_decks enable row level security;
revoke all on public.matches, public.match_decks from anon;
revoke insert, update, delete on public.matches from authenticated;
revoke all on public.match_decks from authenticated;

create policy matches_select_own on public.matches
  for select using (auth.uid() in (host_id, guest_id));
-- match_decks: no policies — never client-readable

alter publication supabase_realtime add table public.matches;

create or replace function public._match_row(p_id uuid)
returns jsonb language sql stable security definer set search_path = public
as $$ select to_jsonb(m) from matches m where m.id = p_id; $$;

create or replace function public._my_match_idx(m public.matches)
returns int language sql stable
as $$ select case when m.host_id = auth.uid() then 0
                  when m.guest_id = auth.uid() then 1
                  else null end; $$;

create or replace function public.create_match(p_name text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_code  text;
  v_deck  int[];
  v_id    uuid;
  v_name  text := coalesce(nullif(trim(p_name), ''), 'Player 1');
  v_tries int := 0;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  update matches set status='abandoned', end_reason='replaced'
   where host_id = v_uid and status = 'waiting';

  select array_agg(id order by random()) into v_deck from cards;
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
  returning id into v_id;

  insert into match_decks (match_id, deck) values (v_id, v_deck);
  return _match_row(v_id);
end;
$$;

create or replace function public.join_match(p_code text, p_name text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_m    matches%rowtype;
  v_name text := coalesce(nullif(trim(p_name), ''), 'Player 2');
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select * into v_m from matches
   where code = upper(trim(p_code)) and status = 'waiting'
   for update;
  if v_m.id is null then raise exception 'room not found'; end if;
  if v_m.host_id = v_uid then raise exception 'cannot join your own room'; end if;

  update matches set
    guest_id     = v_uid,
    players      = jsonb_set(players, '{1,name}', to_jsonb(left(v_name,12))),
    status       = 'active',
    turn         = 0,
    turn_started = now(),
    last_seen_1  = now()
  where id = v_m.id;
  return _match_row(v_m.id);
end;
$$;

create or replace function public._apply_result(
  v_m matches, v_ok boolean, v_expired boolean)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_p          jsonb;
  v_players    jsonb;
  v_streak     int;
  v_lives      int;
  v_score      int;
  v_max        int;
  v_mult       int;
  v_deck       int[];
  v_next       int;
  v_new_status text := 'active';
  v_winner     int  := null;
  v_reason     text := null;
  v_next_turn  int;
begin
  v_players := v_m.players;
  v_p := v_players -> v_m.turn;
  v_streak := (v_p->>'streak')::int;
  v_lives  := (v_p->>'lives')::int;
  v_score  := (v_p->>'score')::int;
  v_max    := (v_p->>'maxStreak')::int;

  if v_ok then
    v_streak := v_streak + 1;
    v_max := greatest(v_max, v_streak);
    v_mult := case when v_streak >= 10 then 5 when v_streak >= 8 then 4
                   when v_streak >= 5 then 3 when v_streak >= 3 then 2 else 1 end;
    v_score := v_score + v_mult;
  else
    v_streak := 0;
    v_lives := v_lives - 1;
  end if;

  v_players := jsonb_set(v_players, array[v_m.turn::text],
    jsonb_build_object('name', v_p->>'name', 'lives', v_lives, 'score', v_score,
                       'streak', v_streak, 'maxStreak', v_max));

  select deck into v_deck from match_decks where match_id = v_m.id;
  v_next := case when v_m.deck_pos + 1 > cardinality(v_deck) then null
                 else v_deck[v_m.deck_pos + 1] end;

  v_next_turn := 1 - v_m.turn;
  if v_lives <= 0 then
    v_new_status := 'finished';
    v_winner := 1 - v_m.turn;
    v_reason := 'lives';
  elsif v_next is null then
    v_new_status := 'finished';
    v_reason := 'deck';
    v_winner := case
      when (v_players->0->>'score')::int > (v_players->1->>'score')::int then 0
      when (v_players->1->>'score')::int > (v_players->0->>'score')::int then 1
      else null end;
  end if;

  update matches set
    players         = v_players,
    timeline        = timeline || jsonb_build_object(
                        'card_id', current_card_id, 'wrong', not v_ok,
                        'by', v_m.turn, 'expired', v_expired),
    current_card_id = case when v_new_status = 'active' then v_next else null end,
    deck_pos        = deck_pos + 1,
    turn            = case when v_new_status = 'active' then v_next_turn else turn end,
    turn_started    = case when v_new_status = 'active' then now() else null end,
    status          = v_new_status,
    winner          = v_winner,
    end_reason      = v_reason
  where id = v_m.id;

  return _match_row(v_m.id);
end;
$$;

create or replace function public.submit_move(p_match_id uuid, p_drop_index int)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_m     matches%rowtype;
  v_idx   int;
  v_years int[];
  v_year  int;
  v_ok    boolean;
begin
  select * into v_m from matches where id = p_match_id for update;
  if v_m.id is null then raise exception 'match not found'; end if;
  v_idx := _my_match_idx(v_m);
  if v_idx is null then raise exception 'not your match'; end if;
  if v_m.status <> 'active' then raise exception 'match not active'; end if;
  if v_m.turn <> v_idx then raise exception 'not your turn'; end if;

  if v_m.turn_started < now() - interval '33 seconds' then
    return _apply_result(v_m, false, true);
  end if;

  select array_agg(c.year order by c.year) into v_years
    from jsonb_array_elements(v_m.timeline) t
    join cards c on c.id = (t->>'card_id')::int;
  select year into v_year from cards where id = v_m.current_card_id;

  if p_drop_index is null or p_drop_index < 0 or p_drop_index > cardinality(v_years) then
    raise exception 'drop index out of range';
  end if;

  v_ok := (p_drop_index = 0                    or v_years[p_drop_index]     <= v_year)
      and (p_drop_index = cardinality(v_years) or v_years[p_drop_index + 1] >= v_year);

  if v_idx = 0 then update matches set last_seen_0 = now() where id = v_m.id;
  else               update matches set last_seen_1 = now() where id = v_m.id;
  end if;

  return _apply_result(v_m, v_ok, false);
end;
$$;

create or replace function public.expire_turn(p_match_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_m   matches%rowtype;
  v_idx int;
begin
  select * into v_m from matches where id = p_match_id for update;
  if v_m.id is null then raise exception 'match not found'; end if;
  v_idx := _my_match_idx(v_m);
  if v_idx is null then raise exception 'not your match'; end if;
  if v_m.status <> 'active' then return _match_row(v_m.id); end if;
  if v_m.turn_started > now() - interval '30 seconds' then
    return _match_row(v_m.id);
  end if;
  return _apply_result(v_m, false, true);
end;
$$;

create or replace function public.heartbeat(p_match_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_m   matches%rowtype;
  v_idx int;
begin
  select * into v_m from matches where id = p_match_id;
  if v_m.id is null then raise exception 'match not found'; end if;
  v_idx := _my_match_idx(v_m);
  if v_idx is null then raise exception 'not your match'; end if;
  if v_idx = 0 then update matches set last_seen_0 = now() where id = v_m.id;
  else              update matches set last_seen_1 = now() where id = v_m.id;
  end if;
  return jsonb_build_object(
    'now', now(),
    'opponent_last_seen', case when v_idx = 0 then v_m.last_seen_1 else v_m.last_seen_0 end,
    'status', v_m.status);
end;
$$;

create or replace function public.claim_timeout(p_match_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_m    matches%rowtype;
  v_idx  int;
  v_seen timestamptz;
begin
  select * into v_m from matches where id = p_match_id for update;
  if v_m.id is null then raise exception 'match not found'; end if;
  v_idx := _my_match_idx(v_m);
  if v_idx is null then raise exception 'not your match'; end if;
  if v_m.status <> 'active' then return _match_row(v_m.id); end if;
  v_seen := case when v_idx = 0 then v_m.last_seen_1 else v_m.last_seen_0 end;
  if v_seen is null or v_seen < now() - interval '60 seconds' then
    update matches set status='finished', winner=v_idx, end_reason='timeout_claim',
                       turn_started=null
     where id = v_m.id;
  end if;
  return _match_row(v_m.id);
end;
$$;

create or replace function public.resign_match(p_match_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_m   matches%rowtype;
  v_idx int;
begin
  select * into v_m from matches where id = p_match_id for update;
  if v_m.id is null then raise exception 'match not found'; end if;
  v_idx := _my_match_idx(v_m);
  if v_idx is null then raise exception 'not your match'; end if;
  if v_m.status = 'active' then
    update matches set status='finished', winner=1-v_idx, end_reason='resign',
                       turn_started=null
     where id = v_m.id;
  elsif v_m.status = 'waiting' and v_idx = 0 then
    update matches set status='abandoned', end_reason='cancelled' where id = v_m.id;
  end if;
  return _match_row(v_m.id);
end;
$$;

create or replace function public.my_open_match()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select to_jsonb(m) from matches m
   where auth.uid() in (m.host_id, m.guest_id)
     and m.status in ('waiting','active')
   order by m.created_at desc
   limit 1;
$$;

revoke all on function public.create_match(text)            from public, anon;
revoke all on function public.join_match(text, text)        from public, anon;
revoke all on function public.submit_move(uuid, int)        from public, anon;
revoke all on function public.expire_turn(uuid)             from public, anon;
revoke all on function public.heartbeat(uuid)               from public, anon;
revoke all on function public.claim_timeout(uuid)           from public, anon;
revoke all on function public.resign_match(uuid)            from public, anon;
revoke all on function public.my_open_match()               from public, anon;
revoke all on function public._match_row(uuid)              from public, anon, authenticated;
revoke all on function public._apply_result(matches, boolean, boolean) from public, anon, authenticated;
grant execute on function public.create_match(text)     to authenticated;
grant execute on function public.join_match(text, text) to authenticated;
grant execute on function public.submit_move(uuid, int) to authenticated;
grant execute on function public.expire_turn(uuid)      to authenticated;
grant execute on function public.heartbeat(uuid)        to authenticated;
grant execute on function public.claim_timeout(uuid)    to authenticated;
grant execute on function public.resign_match(uuid)     to authenticated;
grant execute on function public.my_open_match()        to authenticated;
