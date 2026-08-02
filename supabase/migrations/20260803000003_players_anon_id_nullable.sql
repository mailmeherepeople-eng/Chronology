-- Legacy column: the auth-based flow identifies players by auth_uid and
-- never writes anon_id. Keep the column for old rows, drop the constraint.
-- (Applied to remote 2026-08-03 as players_anon_id_nullable.)
alter table public.players alter column anon_id drop not null;
