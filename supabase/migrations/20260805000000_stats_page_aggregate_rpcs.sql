-- Stats page aggregates (applied to live DB 2026-08-05 via MCP).
-- Aggregate-only reads: the caller learns one global fact (most feared card)
-- and one fact about their own collection (their rarest card). No other
-- player's rows are exposed. Both require a minimum population of 5 players
-- so early numbers are not absurd. Execute is revoked from anon to match the
-- project's function posture (clients are anonymously signed-in ->
-- authenticated role).

create or replace function public.get_most_feared_card()
returns table(card_id integer, pct numeric)
language sql
stable security definer
set search_path to 'public'
as $$
  with total as (
    select count(distinct player_id)::numeric as n from player_mistakes
  )
  select m.card_id,
         round(count(distinct m.player_id) * 100.0 / t.n, 1) as pct
    from player_mistakes m
    cross join total t
   where t.n >= 5
   group by m.card_id, t.n
   order by count(distinct m.player_id) desc, sum(m.count) desc
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
  total as (
    select count(distinct player_id)::numeric as n from player_cards
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

revoke execute on function public.get_most_feared_card() from public, anon;
revoke execute on function public.get_my_rarest_card() from public, anon;
grant execute on function public.get_most_feared_card() to authenticated;
grant execute on function public.get_my_rarest_card() to authenticated;
