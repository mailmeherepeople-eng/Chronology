-- Remove the legacy USING(true) policies. Permissive policies are OR'd,
-- so leaving them in place would keep every table wide open despite the
-- auth-scoped policies added by the replay-validation migration.
-- (Applied to remote 2026-08-03 as drop_legacy_permissive_policies.)
drop policy if exists "Players manage own row" on public.players;
drop policy if exists "Sessions by player"     on public.game_sessions;
drop policy if exists "Cards by player"        on public.player_cards;
drop policy if exists "Cat stats by player"    on public.player_category_stats;
drop policy if exists "Mistakes by player"     on public.player_mistakes;

-- rls_auto_enable is an event-trigger helper; it should never be callable
-- via the REST RPC surface.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
