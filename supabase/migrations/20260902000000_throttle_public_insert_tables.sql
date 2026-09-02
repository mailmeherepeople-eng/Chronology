-- Applied to live DB 2026-09-02 via MCP as throttle_public_insert_tables.
-- Global insert throttle for the two tables a client can write without a
-- per-identity bound (visits: anon, category_runs: authenticated). A public
-- anon key plus PostgREST has no request rate limit, so a script could bloat
-- these until the free-tier disk cap stops writes for real players.
-- Rule: reject an insert once more than N rows landed in the last minute.
-- Real traffic never gets near N; an attack stalls at N rows/minute.
-- Also pins the timestamp column to now() so a backdated row cannot dodge
-- the window. Client impact: none. A throttled visits insert releases the
-- session guard and retries next load; category_runs failures are logged only.

create or replace function public._throttle_inserts()
returns trigger
language plpgsql
security definer            -- anon has no SELECT on these tables; the count must run as owner
set search_path = public
as $$
declare
  v_col   text := tg_argv[0];
  v_limit int  := tg_argv[1]::int;
  v_n     int;
begin
  -- Pin the window column server-side (client-supplied values are ignored)
  new := jsonb_populate_record(new, jsonb_build_object(v_col, now()));

  execute format(
    'select count(*) from %I.%I where %I > now() - interval ''1 minute''',
    tg_table_schema, tg_table_name, v_col
  ) into v_n;

  if v_n >= v_limit then
    raise exception 'insert throttled: % rows/minute cap on %', v_limit, tg_table_name
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

revoke execute on function public._throttle_inserts() from public, anon, authenticated;

create index if not exists visits_visited_at_idx        on public.visits (visited_at);
create index if not exists category_runs_created_at_idx on public.category_runs (created_at);

drop trigger if exists visits_throttle on public.visits;
create trigger visits_throttle
  before insert on public.visits
  for each row execute function public._throttle_inserts('visited_at', '200');

drop trigger if exists category_runs_throttle on public.category_runs;
create trigger category_runs_throttle
  before insert on public.category_runs
  for each row execute function public._throttle_inserts('created_at', '200');

notify pgrst, 'reload schema';
