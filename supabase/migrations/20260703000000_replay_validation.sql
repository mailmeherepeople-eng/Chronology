-- ═══════════════════════════════════════════════════════════
--  Chronology: replay validation + RLS lockdown
--
--  What this migration does:
--   1. players.auth_uid column — links rows to Supabase anonymous auth
--   2. cards table — the server-side answer key (id + year), seeded below
--   3. RLS on every table, scoped to auth.uid()
--   4. claim_legacy_player()  — one-time migration of old anon_id rows
--   5. submit_session()       — replays a placement sequence server-side,
--                               computes the authoritative score, inserts
--                               the session, updates high_score
--   6. get_global_avg_score() — single aggregate for the game-over chip
--
--  PREREQUISITE: enable "Anonymous sign-ins" in
--  Dashboard -> Authentication -> Providers, or clients cannot connect.
-- ═══════════════════════════════════════════════════════════

-- ── 1. players: auth linkage ──
alter table public.players
  add column if not exists auth_uid uuid unique references auth.users (id) on delete set null;

-- game_sessions: mark rows that came through server replay
alter table public.game_sessions
  add column if not exists verified boolean not null default false;

-- ── 2. cards: the server-side answer key ──
create table if not exists public.cards (
  id    integer primary key,
  year  integer not null,
  label text
);

-- ── 3. helper: current player id from the auth JWT ──
create or replace function public.current_player_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select id from players where auth_uid = auth.uid();
$$;

-- ── 4. RLS ──
alter table public.players               enable row level security;
alter table public.player_cards          enable row level security;
alter table public.player_category_stats enable row level security;
alter table public.player_mistakes       enable row level security;
alter table public.game_sessions         enable row level security;
alter table public.cards                 enable row level security;
-- cards: no policies at all — clients can never read the answer key;
-- security-definer functions bypass RLS.

-- pre-signin role gets nothing
revoke all on public.players, public.player_cards, public.player_category_stats,
              public.player_mistakes, public.game_sessions, public.cards
  from anon;

drop policy if exists players_select_own on public.players;
create policy players_select_own on public.players
  for select using (auth_uid = auth.uid());
drop policy if exists players_insert_own on public.players;
create policy players_insert_own on public.players
  for insert with check (auth_uid = auth.uid());
drop policy if exists players_update_own on public.players;
create policy players_update_own on public.players
  for update using (auth_uid = auth.uid()) with check (auth_uid = auth.uid());

-- high_score is server-owned: clients may only touch auth_uid (upsert echo)
-- and native_user_id (ChronologyBridge.setUser)
revoke update on public.players from authenticated;
grant update (auth_uid, native_user_id) on public.players to authenticated;

drop policy if exists player_cards_own on public.player_cards;
create policy player_cards_own on public.player_cards
  for all using (player_id = public.current_player_id())
  with check (player_id = public.current_player_id());

drop policy if exists player_category_stats_own on public.player_category_stats;
create policy player_category_stats_own on public.player_category_stats
  for all using (player_id = public.current_player_id())
  with check (player_id = public.current_player_id());

drop policy if exists player_mistakes_own on public.player_mistakes;
create policy player_mistakes_own on public.player_mistakes
  for all using (player_id = public.current_player_id())
  with check (player_id = public.current_player_id());

-- game_sessions: read your own; writes only via submit_session()
drop policy if exists game_sessions_select_own on public.game_sessions;
create policy game_sessions_select_own on public.game_sessions
  for select using (player_id = public.current_player_id());
revoke insert, update, delete on public.game_sessions from authenticated;

-- ── 5. one-time legacy claim ──
-- Re-parents the row created by the old client-generated anon_id onto the
-- new auth identity. Only fires if this auth user has no player row yet and
-- the legacy row was never claimed.
create or replace function public.claim_legacy_player(p_anon_id text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from players where auth_uid = auth.uid()) then
    return;
  end if;
  update players
     set auth_uid = auth.uid()
   where anon_id = p_anon_id
     and auth_uid is null;
end;
$$;

-- ── 6. replay validation ──
-- The client submits { seed card, [ {card_id, drop_index}, ... ] }.
-- Correctness is recomputed here against cards.year using the same rule as
-- the client: keep placed cards sorted ascending; a drop at index i is
-- correct when sorted[i-1].year <= y and sorted[i].year >= y.
-- Scoring mirrors the client: streak multiplier 1/2/3/4/5 at 0/3/5/8/10.
create or replace function public.submit_session(
  p_seed_card_id integer,
  p_placements   jsonb
)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_player      uuid;
  v_years       integer[];
  v_seen        integer[];
  v_total_cards integer;
  v_recent      integer;
  v_placement   jsonb;
  v_card_id     integer;
  v_drop_idx    integer;
  v_year        integer;
  v_ok          boolean;
  v_lives       integer := 3;
  v_score       integer := 0;
  v_streak      integer := 0;
  v_max_streak  integer := 0;
  v_correct     integer := 0;
  v_wrong       integer := 0;
  v_mult        integer;
begin
  select id into v_player from players where auth_uid = auth.uid();
  if v_player is null then
    raise exception 'no player row for this user';
  end if;

  -- crude rate limit: a human cannot finish 60 games in an hour
  select count(*) into v_recent
    from game_sessions
   where player_id = v_player
     and ended_at > now() - interval '1 hour';
  if v_recent >= 60 then
    raise exception 'rate limit exceeded';
  end if;

  if p_placements is null or jsonb_typeof(p_placements) <> 'array' then
    raise exception 'placements must be a json array';
  end if;

  select count(*) into v_total_cards from cards;
  if jsonb_array_length(p_placements) > v_total_cards - 1 then
    raise exception 'too many placements';
  end if;

  select year into v_year from cards where id = p_seed_card_id;
  if v_year is null then
    raise exception 'unknown seed card %', p_seed_card_id;
  end if;
  v_years := array[v_year];
  v_seen  := array[p_seed_card_id];

  for v_placement in select * from jsonb_array_elements(p_placements) loop
    if v_lives <= 0 then
      raise exception 'placement after game over';
    end if;

    v_card_id  := (v_placement->>'card_id')::integer;
    v_drop_idx := (v_placement->>'drop_index')::integer;
    if v_card_id is null or v_drop_idx is null then
      raise exception 'malformed placement %', v_placement;
    end if;
    if v_card_id = any(v_seen) then
      raise exception 'card % placed twice', v_card_id;
    end if;

    select year into v_year from cards where id = v_card_id;
    if v_year is null then
      raise exception 'unknown card %', v_card_id;
    end if;
    if v_drop_idx < 0 or v_drop_idx > cardinality(v_years) then
      raise exception 'drop index % out of range', v_drop_idx;
    end if;

    -- postgres arrays are 1-based: client sorted[dropIdx-1] = v_years[drop_idx]
    v_ok := (v_drop_idx = 0                   or v_years[v_drop_idx]     <= v_year)
        and (v_drop_idx = cardinality(v_years) or v_years[v_drop_idx + 1] >= v_year);

    if v_ok then
      v_streak := v_streak + 1;
      v_max_streak := greatest(v_max_streak, v_streak);
      v_mult := case
        when v_streak >= 10 then 5
        when v_streak >= 8  then 4
        when v_streak >= 5  then 3
        when v_streak >= 3  then 2
        else 1
      end;
      v_score   := v_score + v_mult;
      v_correct := v_correct + 1;
    else
      v_streak := 0;
      v_lives  := v_lives - 1;
      v_wrong  := v_wrong + 1;
    end if;

    v_seen  := v_seen || v_card_id;
    v_years := (select array_agg(y order by y) from unnest(v_years || v_year) as y);
  end loop;

  insert into game_sessions
    (player_id, score, correct_count, wrong_count, max_streak,
     ended_at, completed, category_filter, played_at, verified)
  values
    (v_player, v_score, v_correct, v_wrong, v_max_streak,
     now(), (v_lives > 0 and cardinality(v_years) = v_total_cards), 'all', now(), true);

  update players
     set high_score = greatest(coalesce(high_score, 0), v_score)
   where id = v_player;

  return jsonb_build_object(
    'score', v_score,
    'correct', v_correct,
    'wrong', v_wrong,
    'max_streak', v_max_streak,
    'verified', true
  );
end;
$$;

-- ── 7. global average for the game-over chip ──
create or replace function public.get_global_avg_score()
returns numeric
language sql stable security definer
set search_path = public
as $$
  select coalesce(round(avg(score), 2), 0) from game_sessions where verified;
$$;

-- function grants
revoke all on function public.claim_legacy_player(text)            from public, anon;
revoke all on function public.submit_session(integer, jsonb)       from public, anon;
revoke all on function public.get_global_avg_score()               from public, anon;
revoke all on function public.current_player_id()                  from public, anon;
grant execute on function public.claim_legacy_player(text)      to authenticated;
grant execute on function public.submit_session(integer, jsonb) to authenticated;
grant execute on function public.get_global_avg_score()         to authenticated;
grant execute on function public.current_player_id()            to authenticated;

-- ── 8. answer-key seed (349 cards) ──
-- Regenerate when data/chronology_game.json changes:
--   id/year pairs must always match the shipped JSON.
insert into public.cards (id, year, label) values
  (1, -3300, 'Indus Valley Civilization'),
  (2, -2600, 'Harappan city of Mohenjo-daro'),
  (3, -1900, 'Indus Valley Civilization'),
  (4, -1500, 'Rigveda'),
  (5, -1000, 'Later Vedic period'),
  (6, -900, 'Vedic settlements reach Ganges plain'),
  (7, -600, 'Mahajanapada period'),
  (8, -600, 'Second Urbanisation in Gangetic plains'),
  (9, -528, 'Buddhism'),
  (10, -527, 'Jainism'),
  (11, -492, 'Ajatashatru expanded Magadha'),
  (12, -326, 'Battle of Hydaspes'),
  (13, -322, 'Maurya Empire'),
  (14, -305, 'Treaty of Indus with Seleucus'),
  (15, -302, 'Megasthenes visited Pataliputra'),
  (16, -300, 'Chanakya''s Arthashastra'),
  (17, -300, 'Sangam literature period'),
  (18, -261, 'Ashoka''s Kalinga War'),
  (19, -185, 'Maurya Empire'),
  (20, 100, 'Fourth Buddhist Council'),
  (21, 275, 'Pallava dynasty at Kanchipuram'),
  (22, 320, 'Gupta Empire'),
  (23, 350, 'Samudragupta''s conquests'),
  (24, 380, 'Vakataka dynasty and Gupta alliance'),
  (25, 400, 'Kalidasa''s Shakuntalam'),
  (26, 405, 'Fa Hien visited India'),
  (27, 415, 'Meghadutam'),
  (28, 427, 'Nalanda University'),
  (29, 455, 'Huna invasions and Gupta decline'),
  (30, 499, 'Aryabhatta''s Aryabhatiya'),
  (31, 543, 'Chalukya dynasty'),
  (32, 606, 'Harshavardhana''s reign'),
  (33, 629, 'Hieun Tsang''s visit to India'),
  (34, 630, 'Pallava dynasty at its peak'),
  (35, 712, 'Conquest of Sindh by Muhammad bin Qasim'),
  (36, 757, 'Rashtrakuta dynasty'),
  (37, 788, 'Adi Shankaracharya''s Advaita Vedanta'),
  (38, 850, 'Chola dynasty'),
  (39, 1025, 'Rajendra Chola''s naval expedition'),
  (40, 1149, 'Prithviraj Chauhan'),
  (41, 1191, 'First Battle of Tarain'),
  (42, 1192, 'Second Battle of Tarain'),
  (43, 1193, 'Qutb Minar'),
  (44, 1206, 'Delhi Sultanate'),
  (45, 1215, 'Magna Carta'),
  (46, 1229, 'Iltutmish consolidated Delhi Sultanate'),
  (47, 1236, 'Razia Sultana'),
  (48, 1266, 'Ghiyasuddin Balban''s reign'),
  (49, 1296, 'Alauddin Khilji''s reign'),
  (50, 1300, 'Market reforms of Alauddin Khilji'),
  (51, 1327, 'Muhammad bin Tughlaq shifted capital'),
  (52, 1333, 'Ibn Battuta''s visit to India'),
  (53, 1336, 'Vijayanagara Empire'),
  (54, 1351, 'Firuz Shah Tughlaq''s reign'),
  (55, 1398, 'Timur''s invasion of India'),
  (56, 1400, 'Renaissance in Florence'),
  (57, 1440, 'Bhakti movement'),
  (58, 1440, 'Gutenberg''s Printing Press'),
  (59, 1469, 'Guru Nanak Dev Ji'),
  (60, 1492, 'Columbus reached the Americas'),
  (61, 1498, 'Vasco da Gama arrived in India'),
  (62, 1502, 'Vasco da Gama''s second voyage to India'),
  (63, 1509, 'Vijayanagara Empire'),
  (64, 1510, 'Portuguese captured Goa'),
  (65, 1517, 'Protestant Reformation'),
  (66, 1526, 'First Battle of Panipat'),
  (67, 1526, 'Mughal Empire'),
  (68, 1527, 'Battle of Khanwa'),
  (69, 1539, 'Battle of Chausa'),
  (70, 1540, 'Grand Trunk Road'),
  (71, 1540, 'Sher Shah Suri''s revenue reforms'),
  (72, 1555, 'Humayun'),
  (73, 1556, 'Second Battle of Panipat'),
  (74, 1564, 'Jizya tax'),
  (75, 1565, 'Battle of Talikota'),
  (76, 1576, 'Battle of Haldighati'),
  (77, 1582, 'Akbar''s Din-i-Ilahi'),
  (78, 1598, 'Ain-i-Akbari'),
  (79, 1600, 'East India Company'),
  (80, 1606, 'Guru Arjan Dev martyrdom'),
  (81, 1608, 'East India Company''s first trading post'),
  (82, 1630, 'Shivaji'),
  (83, 1648, 'Thirty Years War'),
  (84, 1653, 'Taj Mahal'),
  (85, 1674, 'Shivaji crowned Chhatrapati'),
  (86, 1679, 'Aurangzeb reimposed Jizya tax'),
  (87, 1681, 'Aurangzeb''s Deccan campaigns'),
  (88, 1720, 'Maratha Confederacy'),
  (89, 1724, 'Hyderabad state'),
  (90, 1739, 'Nadir Shah''s invasion of Delhi'),
  (91, 1757, 'Battle of Plassey'),
  (93, 1760, 'Industrial Revolution in Britain'),
  (94, 1761, 'Third Battle of Panipat'),
  (95, 1764, 'Battle of Buxar'),
  (96, 1772, 'Raja Ram Mohan Roy'),
  (97, 1773, 'Regulating Act'),
  (98, 1776, 'American Declaration of Independence'),
  (99, 1784, 'Pitt''s India Act'),
  (100, 1789, 'French Revolution'),
  (101, 1793, 'Permanent Settlement of Bengal'),
  (102, 1798, 'Subsidiary Alliance system'),
  (103, 1799, 'Fourth Anglo-Mysore War'),
  (104, 1803, 'Second Anglo-Maratha War'),
  (105, 1804, 'Napoleon became Emperor of France'),
  (106, 1804, 'Haitian Revolution'),
  (107, 1813, 'Charter Act'),
  (108, 1815, 'Battle of Waterloo'),
  (109, 1824, 'Swami Dayananda Saraswati'),
  (110, 1828, 'Brahmo Samaj'),
  (111, 1829, 'Sati Abolition Act'),
  (112, 1836, 'Ramakrishna Paramahamsa'),
  (113, 1839, 'Opium Wars between Britain and China'),
  (114, 1848, 'Doctrine of Lapse'),
  (115, 1848, 'Communist Manifesto'),
  (116, 1848, 'First girls'' school in India'),
  (117, 1856, 'Bal Gangadhar Tilak'),
  (118, 1856, 'Widow Remarriage Act'),
  (119, 1857, 'First War of Independence'),
  (120, 1858, 'British Crown took over from EIC'),
  (121, 1858, 'Bipin Chandra Pal'),
  (122, 1858, 'Government of India Act'),
  (123, 1861, 'Indian Councils Act'),
  (124, 1861, 'Rabindranath Tagore'),
  (125, 1863, 'Swami Vivekananda'),
  (126, 1865, 'Lala Lajpat Rai'),
  (127, 1867, 'Dadabhai Naoroji''s Drain Theory'),
  (128, 1869, 'Suez Canal'),
  (129, 1869, 'Mahatma Gandhi'),
  (130, 1871, 'Unification of Germany'),
  (131, 1873, 'Satyashodhak Samaj'),
  (132, 1875, 'Sardar Vallabhbhai Patel'),
  (133, 1875, 'Arya Samaj'),
  (134, 1875, 'Aligarh Muslim University'),
  (135, 1876, 'Muhammad Ali Jinnah'),
  (136, 1878, 'Vernacular Press Act'),
  (137, 1878, 'Arms Act'),
  (138, 1882, 'Hunter Commission on education'),
  (139, 1883, 'Ilbert Bill controversy'),
  (140, 1884, 'Berlin Conference: Africa partitioned'),
  (141, 1885, 'Indian National Congress'),
  (142, 1888, 'Sudharak'),
  (143, 1888, 'Maulana Abul Kalam Azad'),
  (144, 1889, 'Jawaharlal Nehru'),
  (145, 1891, 'Age of Consent Act'),
  (146, 1891, 'B.R. Ambedkar'),
  (147, 1893, 'Swami Vivekananda''s Chicago speech'),
  (148, 1897, 'Subhas Chandra Bose'),
  (149, 1897, 'Ramakrishna Mission'),
  (150, 1905, 'Partition of Bengal'),
  (151, 1905, 'Swadeshi Movement'),
  (152, 1905, 'Servants of India Society'),
  (153, 1906, 'Muslim League'),
  (154, 1907, 'Bhagat Singh'),
  (155, 1908, 'Bal Gangadhar Tilak'),
  (156, 1909, 'Morley-Minto Reforms'),
  (157, 1911, 'Capital shifted from Calcutta to Delhi'),
  (158, 1911, 'Curzon''s Bengal Partition'),
  (159, 1913, 'Rabindranath Tagore won Nobel Prize in Literature'),
  (160, 1914, 'First World War'),
  (161, 1914, 'Scramble for Africa'),
  (162, 1916, 'Lucknow Pact'),
  (163, 1916, 'Home Rule League'),
  (164, 1917, 'Balfour Declaration'),
  (165, 1917, 'Russian Revolution'),
  (166, 1917, 'Champaran Satyagraha'),
  (167, 1918, 'Kheda Satyagraha'),
  (168, 1919, 'Montagu-Chelmsford Reforms'),
  (169, 1919, 'Rowlatt Act'),
  (170, 1919, 'Jallianwala Bagh Massacre'),
  (171, 1919, 'Khilafat Movement'),
  (172, 1919, 'Treaty of Versailles'),
  (174, 1920, 'Non-Cooperation Movement'),
  (175, 1920, 'League of Nations'),
  (176, 1922, 'Chauri Chaura incident'),
  (177, 1925, 'Self-Respect Movement'),
  (178, 1925, 'Sarojini Naidu, Congress president'),
  (179, 1927, 'Ambedkar''s Mahad Satyagraha'),
  (180, 1928, 'Simon Commission'),
  (181, 1928, 'Nehru Report'),
  (182, 1928, 'Raman Effect'),
  (183, 1929, 'Purna Swaraj Declaration'),
  (184, 1929, 'Great Depression'),
  (185, 1929, 'Child Marriage Restraint Act'),
  (186, 1930, 'Dandi March / Salt Satyagraha'),
  (187, 1930, 'First Round Table Conference'),
  (188, 1931, 'Gandhi-Irwin Pact'),
  (189, 1931, 'APJ Abdul Kalam'),
  (190, 1931, 'Chandrashekhar Azad'),
  (191, 1932, 'Poona Pact'),
  (192, 1933, 'Hitler'),
  (193, 1935, 'Government of India Act'),
  (194, 1937, 'Congress wins provincial elections'),
  (195, 1939, 'Second World War'),
  (196, 1942, 'Cripps Mission'),
  (197, 1942, 'Quit India Movement'),
  (198, 1943, 'Indian National Army'),
  (199, 1943, 'Bengal famine'),
  (200, 1945, 'INA trials at Red Fort'),
  (201, 1945, 'Hiroshima atomic bombing'),
  (202, 1945, 'United Nations'),
  (203, 1945, 'Wavell Plan and Simla Conference'),
  (204, 1945, 'TIFR'),
  (205, 1946, 'Cabinet Mission Plan'),
  (206, 1946, 'Direct Action Day'),
  (207, 1946, 'Constituent Assembly first met'),
  (208, 1946, 'Royal Indian Navy Mutiny'),
  (209, 1947, 'Mountbatten Plan'),
  (210, 1947, 'Indian Independence'),
  (211, 1947, 'Devadasi system'),
  (212, 1947, 'Indian Independence Act'),
  (213, 1947, 'B.R. Ambedkar became Law Minister'),
  (214, 1947, 'Nehru''s Tryst with Destiny speech'),
  (215, 1947, 'Marshall Plan'),
  (216, 1948, 'Operation Polo'),
  (217, 1948, 'Mahatma Gandhi'),
  (218, 1948, 'Universal Declaration of Human Rights'),
  (219, 1948, 'Junagadh accession to India'),
  (220, 1949, 'Constitution of India'),
  (221, 1949, 'NATO'),
  (222, 1950, 'Constitution of India'),
  (223, 1950, 'Planning Commission'),
  (224, 1950, 'Korean War'),
  (225, 1950, 'First Republic Day parade'),
  (226, 1950, 'Hindi declared official language'),
  (227, 1950, 'Supreme Court of India'),
  (228, 1951, 'First Five-Year Plan'),
  (229, 1951, 'First General Elections of India'),
  (230, 1951, 'Vinoba Bhave''s Bhoodan Movement'),
  (231, 1951, 'IIT Kharagpur'),
  (232, 1951, 'First Amendment to Indian Constitution'),
  (233, 1952, 'Community Development Programme'),
  (234, 1954, 'Special Marriage Act'),
  (235, 1955, 'Hindu Code Bills'),
  (236, 1955, 'Untouchability Offences Act'),
  (237, 1956, 'States Reorganisation Act'),
  (238, 1956, 'India''s first nuclear reactor Apsara'),
  (239, 1956, 'First Five-Year Plan completed'),
  (240, 1956, 'B.R. Ambedkar converted to Buddhism'),
  (241, 1956, 'AIIMS established in New Delhi'),
  (242, 1957, 'Sputnik: first artificial satellite'),
  (243, 1958, 'India''s First Commonwealth gold'),
  (244, 1958, 'DRDO'),
  (245, 1960, 'India''s first computer TIFRAC'),
  (246, 1960, 'Decolonisation wave in Africa'),
  (247, 1960, 'Maharashtra and Gujarat created'),
  (248, 1961, 'Non-Aligned Movement'),
  (249, 1961, 'Goa liberation'),
  (250, 1961, 'Dowry Prohibition Act'),
  (251, 1962, 'Sino-Indian War'),
  (252, 1962, 'Cuban Missile Crisis'),
  (253, 1962, 'Cuban Missile Crisis'),
  (254, 1964, 'Lal Bahadur Shastri'),
  (255, 1965, 'Indo-Pak War'),
  (256, 1966, 'Green Revolution in India'),
  (257, 1966, 'Indira Gandhi'),
  (258, 1966, 'India''s Green Revolution wheat variety'),
  (259, 1966, 'M.S. Swaminathan Green Revolution'),
  (260, 1969, 'Bank Nationalisation'),
  (261, 1969, 'Moon landing (Apollo 11)'),
  (262, 1969, 'ISRO'),
  (263, 1970, 'Operation Flood (White Revolution)'),
  (264, 1971, 'Bangladesh Liberation War'),
  (265, 1971, 'Privy Purses'),
  (266, 1972, 'Simla Agreement'),
  (267, 1972, 'SEWA'),
  (268, 1972, 'Dalit Panthers'),
  (269, 1973, 'Project Tiger'),
  (270, 1973, 'Kesavananda Bharati judgment'),
  (271, 1974, 'India''s first nuclear test (Pokhran-I)'),
  (272, 1974, 'Jayaprakash Narayan''s Total Revolution'),
  (273, 1975, 'Emergency in India'),
  (274, 1975, 'Vietnam War'),
  (275, 1975, 'India''s first satellite Aryabhata'),
  (276, 1976, '42nd Constitutional Amendment'),
  (277, 1978, '44th Constitutional Amendment'),
  (278, 1978, 'Menaka Gandhi judgment'),
  (279, 1978, 'Right to Property'),
  (280, 1979, 'Mother Teresa won Nobel Peace Prize'),
  (281, 1979, 'Iran hostage crisis'),
  (282, 1980, 'India''s first SLV-3 rocket launch'),
  (283, 1980, 'Mandal Commission Report'),
  (284, 1981, 'APPLE satellite by India'),
  (285, 1983, 'INSAT-1B, India''s first weather satellite'),
  (286, 1984, 'Operation Blue Star'),
  (287, 1984, 'Bhopal Gas Tragedy'),
  (288, 1984, 'Indira Gandhi'),
  (289, 1984, 'Rajiv Gandhi'),
  (290, 1984, 'Indian Airlines hijacking to Lahore'),
  (291, 1985, '52nd Amendment: Anti-Defection Law'),
  (292, 1989, 'Berlin Wall'),
  (293, 1990, 'Mandal Commission report'),
  (294, 1991, 'Liberalisation Reforms (LPG)'),
  (295, 1991, 'Soviet Union'),
  (296, 1991, 'Narasimha Rao'),
  (297, 1991, 'Rajiv Gandhi'),
  (298, 1991, 'Ratan Tata modernised Tata Group'),
  (299, 1991, 'Param supercomputer developed'),
  (300, 1992, 'Babri Masjid'),
  (301, 1992, '73rd Amendment: Panchayati Raj'),
  (302, 1992, '74th Amendment: Urban Local Bodies'),
  (303, 1994, 'PSLV first successful flight'),
  (304, 1994, 'Apartheid in South Africa'),
  (305, 1994, 'SR Bommai judgment'),
  (306, 1995, 'World Trade Organization'),
  (307, 1997, 'Kyoto Protocol'),
  (308, 1997, 'Vishaka Guidelines on sexual harassment'),
  (309, 1998, 'Pokhran-II (Operation Shakti)'),
  (310, 1998, 'Amartya Sen won Nobel Prize in Economics'),
  (311, 1999, 'Kargil War'),
  (312, 1999, 'Atal Bihari Vajpayee'),
  (313, 2001, 'Parliament of India'),
  (314, 2001, '9/11 attacks on USA'),
  (315, 2001, 'Right to Food campaign and NFSA'),
  (316, 2002, '86th Amendment: Right to Education'),
  (317, 2004, 'Indian Ocean Tsunami'),
  (318, 2005, 'Right to Information Act'),
  (319, 2005, 'MNREGA'),
  (320, 2005, 'National Rural Health Mission'),
  (321, 2005, 'Domestic Violence Act'),
  (322, 2008, '26/11 Mumbai Attacks'),
  (323, 2008, 'Global Financial Crisis'),
  (324, 2008, 'Chandrayaan-1'),
  (325, 2009, 'Right to Education Act'),
  (326, 2009, 'Aadhaar'),
  (327, 2012, 'Agni-V missile tested'),
  (328, 2013, 'Mangalyaan (Mars Orbiter Mission)'),
  (329, 2013, 'National Food Security Act'),
  (330, 2013, 'Lokpal and Lokayukta Act'),
  (331, 2014, 'Jan Dhan Yojana'),
  (332, 2014, 'Polio eradication in India'),
  (333, 2014, 'NALSA judgment on transgender rights'),
  (334, 2015, 'Paris Climate Agreement'),
  (335, 2015, 'Digital India'),
  (336, 2015, 'NJAC Act'),
  (337, 2016, 'Surgical Strikes across LoC'),
  (338, 2016, 'Demonetisation'),
  (339, 2017, 'Goods and Services Tax'),
  (340, 2017, 'GSLV Mk-III first flight'),
  (341, 2017, 'Maternity Benefit Amendment Act'),
  (342, 2017, 'Right to privacy declared Fundamental'),
  (343, 2018, 'Section 377 decriminalised'),
  (344, 2019, 'Balakot airstrike'),
  (345, 2019, 'Article 370'),
  (346, 2019, 'Chandrayaan-2'),
  (347, 2020, 'COVID-19 first case in India'),
  (348, 2020, 'Cyclone Amphan devastated Bengal'),
  (349, 2021, 'India''s COVID vaccination programme'),
  (350, 2023, 'Chandrayaan-3'),
  (351, 2023, 'Aditya-L1 solar mission')
on conflict (id) do update set year = excluded.year, label = excluded.label;

-- remove cards that no longer exist in the deck (dedup removed 92 and 173)
delete from public.cards where id in (92, 173);
