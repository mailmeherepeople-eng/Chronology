-- Debloat: purge anonymous users (and their game data) after 20 days of
-- inactivity. Activity = player row created/updated, or any game session.
-- Runs daily at 03:30 UTC via pg_cron.
-- (Applied to remote 2026-08-03 as anon_user_cleanup.)
create extension if not exists pg_cron;

create or replace function public.cleanup_stale_anonymous_users()
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  -- 1. player rows (children cascade) whose owner is anonymous (or unlinked
  --    legacy) with no activity in 20 days
  delete from players p
  where greatest(
          p.created_at,
          p.updated_at,
          coalesce((select max(s.ended_at) from game_sessions s where s.player_id = p.id),
                   '-infinity'::timestamptz)
        ) < now() - interval '20 days'
    and (p.auth_uid is null
         or exists (select 1 from auth.users u
                     where u.id = p.auth_uid and u.is_anonymous));

  -- 2. anonymous auth users older than 20 days with no player row
  --    (drive-by visits, plus users orphaned by step 1)
  delete from auth.users u
  where u.is_anonymous
    and u.created_at < now() - interval '20 days'
    and greatest(u.created_at, coalesce(u.last_sign_in_at, '-infinity'::timestamptz))
        < now() - interval '20 days'
    and not exists (select 1 from players p where p.auth_uid = u.id);
end;
$$;

revoke all on function public.cleanup_stale_anonymous_users() from public, anon, authenticated;

select cron.schedule(
  'cleanup-stale-anon-users',
  '30 3 * * *',
  $$select public.cleanup_stale_anonymous_users()$$
);
