-- Applied to live DB 2026-08-05 via MCP, after an adversarial review.
-- Three parts: (1) constraints that bound what a client can write into its
-- own rows, (2) least-privilege grants, (3) anti-poison + throttles on RPCs.

-- ─────────────────────────────────────────────────────────────
-- 1. Stat-table integrity
-- The FKs are the important part: card_id must exist in `cards`, so a player
-- can never hold more than one row per real card (398) no matter what they
-- POST directly to PostgREST. Length/range checks stop huge text payloads.
-- ─────────────────────────────────────────────────────────────
delete from player_mistakes m
 where not exists (select 1 from cards c where c.id = m.card_id);
delete from player_cards p
 where not exists (select 1 from cards c where c.id = p.card_id);

alter table player_mistakes
  add constraint player_mistakes_card_fk
    foreign key (card_id) references cards(id) on delete cascade,
  add constraint player_mistakes_label_len   check (label is null or length(label) <= 120),
  add constraint player_mistakes_cat_len     check (category is null or length(category) <= 40),
  add constraint player_mistakes_year_range  check (year is null or year between -10000 and 10000),
  add constraint player_mistakes_count_range check (count is null or (count >= 0 and count <= 100000));

alter table player_cards
  add constraint player_cards_card_fk
    foreign key (card_id) references cards(id) on delete cascade;

-- Closed set: one row per category per player (10 max). If a new category is
-- ever added to the deck, extend this list in the same migration.
alter table player_category_stats
  add constraint player_category_stats_known_cat check (category in (
    'Ancient India','Medieval India','Colonial India','Post-Independence',
    'World History','Science & Tech','Personalities','Social Reform',
    'Constitutional','Meta')),
  add constraint player_category_stats_ranges check (
    attempts >= 0 and attempts <= 1000000 and correct >= 0 and correct <= 1000000);

-- ─────────────────────────────────────────────────────────────
-- 2. Least-privilege grants
-- Supabase's default template grants ALL on every public table to
-- anon+authenticated; RLS was the only thing holding the line. Strip
-- everything, re-grant exactly what the game performs.
-- Removed everywhere: DELETE, TRUNCATE, TRIGGER, REFERENCES. TRUNCATE
-- matters most - RLS does NOT apply to TRUNCATE.
-- `cards` and `match_decks` end with zero client privileges: the answer key
-- and the shuffled deck are server-only.
-- ─────────────────────────────────────────────────────────────
revoke all privileges on all tables in schema public from anon, authenticated;

grant select on public.matches       to authenticated;  -- match state + realtime
grant select on public.game_sessions to authenticated;  -- own history
grant select on public.players       to authenticated;  -- own row

-- Player bootstrap: upsert({auth_uid}) on first load
grant insert (auth_uid, anon_id) on public.players to authenticated;
grant update (auth_uid)          on public.players to authenticated;
-- Cosmetic self-service flags only. high_score stays server-authoritative:
-- writable ONLY by submit_session, which computes it from cards.year.
grant update (tutorial_done, native_user_id, dark_mode) on public.players to authenticated;

grant select, insert, update on public.player_cards          to authenticated;
grant select, insert, update on public.player_category_stats to authenticated;
grant select, insert, update on public.player_mistakes       to authenticated;

-- anon (not signed in) keeps nothing at all.

-- ─────────────────────────────────────────────────────────────
-- 3. RPC anti-poison + throttles
-- Aggregates now count only players with a verified session and only rank
-- cards that exist (a junk card_id previously made the client's
-- EVENTS.find() miss, hiding the widget for every player).
-- heartbeat keeps its jsonb reply but skips the WRITE within 5s, so a call
-- loop no longer broadcasts over Realtime to the opponent.
-- expire_turn raised 30s -> 33s so it cannot fire inside submit_move's own
-- grace window and steal a life from a slow connection.
-- ─────────────────────────────────────────────────────────────

create or replace function public.get_most_feared_card()
returns table(card_id integer, pct numeric)
language sql
stable security definer
set search_path to 'public'
as $$
  with real_players as (
    select distinct player_id from game_sessions where verified
  ),
  total as (
    select count(*)::numeric as n from real_players
  )
  select m.card_id,
         round(count(distinct m.player_id) * 100.0 / t.n, 1) as pct
    from player_mistakes m
    join real_players rp on rp.player_id = m.player_id
    join cards c        on c.id = m.card_id and not coalesce(c.is_meta, false)
    cross join total t
   where t.n >= 5
   group by m.card_id, t.n
   order by count(distinct m.player_id) desc, m.card_id
   limit 1;
$$;

create or replace function public.get_my_rarest_card()
returns table(card_id integer, pct numeric)
language sql
stable security definer
set search_path to 'public'
as $$
  with me as (
    select id from players where auth_uid = auth.uid()
  ),
  real_players as (
    select distinct player_id from game_sessions where verified
  ),
  total as (
    select count(*)::numeric as n from real_players
  ),
  owned as (
    select pc.card_id
      from player_cards pc
      join me on pc.player_id = me.id
      join cards c on c.id = pc.card_id and not coalesce(c.is_meta, false)
  ),
  counts as (
    select p2.card_id, count(distinct p2.player_id)::numeric as n_own
      from player_cards p2
      join real_players rp on rp.player_id = p2.player_id
     where p2.card_id in (select card_id from owned)
     group by p2.card_id
  )
  select counts.card_id,
         round(counts.n_own * 100.0 / t.n, 1) as pct
    from counts
    cross join total t
   where t.n >= 5
   order by counts.n_own asc, counts.card_id
   limit 1;
$$;

create or replace function public.heartbeat(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_m    matches%rowtype;
  v_idx  int;
  v_last timestamptz;
begin
  select * into v_m from matches where id = p_match_id;
  if v_m.id is null then raise exception 'match not found'; end if;
  v_idx := _my_match_idx(v_m);
  if v_idx is null then raise exception 'not your match'; end if;

  v_last := case when v_idx = 0 then v_m.last_seen_0 else v_m.last_seen_1 end;
  if v_last is null or v_last <= now() - interval '5 seconds' then
    if v_idx = 0 then update matches set last_seen_0 = now() where id = v_m.id;
    else              update matches set last_seen_1 = now() where id = v_m.id;
    end if;
  end if;

  return jsonb_build_object(
    'now', now(),
    'opponent_last_seen', case when v_idx = 0 then v_m.last_seen_1 else v_m.last_seen_0 end,
    'status', v_m.status);
end;
$function$;

create or replace function public.expire_turn(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_m   matches%rowtype;
  v_idx int;
begin
  select * into v_m from matches where id = p_match_id for update;
  if v_m.id is null then raise exception 'match not found'; end if;
  v_idx := _my_match_idx(v_m);
  if v_idx is null then raise exception 'not your match'; end if;
  if v_m.status <> 'active' then return _match_row(v_m.id); end if;
  if v_m.turn_started > now() - interval '33 seconds' then
    return _match_row(v_m.id); -- not expired yet (or already flipped): no-op
  end if;
  return _apply_result(v_m, false, true);
end;
$function$;

-- NOTE for future migrations: _apply_result(matches, boolean, boolean) and
-- _match_row(uuid) have NO authorization checks by design and are safe only
-- because EXECUTE is not granted to authenticated/anon. Never add a blanket
-- GRANT EXECUTE ON ALL FUNCTIONS sweep - it would let any player rewrite any
-- match's score, turn, and winner.
