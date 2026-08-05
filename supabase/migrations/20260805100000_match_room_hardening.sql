-- Room hardening (applied to live DB 2026-08-05 via MCP).
-- 1. create_match: rate limit 20 rooms/hour/host, plus an opportunistic
--    sweep that expires ANY waiting room older than 15 minutes.
-- 2. join_match: refuses (and expires) waiting rooms older than 15 minutes.
-- 3. my_open_match: never offers a stale waiting room for resume.
-- Bodies otherwise identical to the previous live definitions.

-- See live DB for canonical state; this file records the change. Full
-- function bodies as applied:

create or replace function public.create_match(p_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_code   text;
  v_deck   int[];
  v_id     uuid;
  v_name   text := coalesce(nullif(trim(p_name), ''), 'Player 1');
  v_tries  int := 0;
  v_recent int;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  -- Rate limit: 20 rooms per hour per host
  select count(*) into v_recent
    from matches
   where host_id = v_uid and created_at > now() - interval '1 hour';
  if v_recent >= 20 then
    raise exception 'rate limit exceeded';
  end if;

  -- Sweep: stale waiting rooms (any host) die here opportunistically
  update matches set status='abandoned', end_reason='expired'
   where status = 'waiting' and created_at < now() - interval '15 minutes';

  update matches set status='abandoned', end_reason='replaced'
   where host_id = v_uid and status = 'waiting';

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
  returning id into v_id;

  insert into match_decks (match_id, deck) values (v_id, v_deck);
  return _match_row(v_id);
end;
$function$;

create or replace function public.join_match(p_code text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  -- Waiting rooms expire after 15 minutes
  if v_m.created_at < now() - interval '15 minutes' then
    update matches set status='abandoned', end_reason='expired' where id = v_m.id;
    raise exception 'room expired';
  end if;

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
$function$;

create or replace function public.my_open_match()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select to_jsonb(m) from matches m
   where auth.uid() in (m.host_id, m.guest_id)
     and m.status in ('waiting','active')
     -- a stale waiting room is dead; never offer it for resume
     and not (m.status = 'waiting' and m.created_at < now() - interval '15 minutes')
   order by m.created_at desc
   limit 1;
$function$;
