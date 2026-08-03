-- 49 new cards (world history + science expansion) for the replay-validation answer key,
-- plus meta-card support: ultra-rare cards are excluded from online match decks.

insert into cards (id, year, label) values
  (352, -3200, 'Cuneiform'),
  (353, -2560, 'Pyramids of Giza'),
  (354, -1754, 'Hammurabi'),
  (355, -1200, 'Trojan War'),
  (356, -753, 'Rome'),
  (357, -550, 'Persian Empire'),
  (358, -508, 'Athenian Democracy'),
  (359, -334, 'Alexander'),
  (360, -221, 'Qin Shi Huang'),
  (361, -44, 'Julius Caesar'),
  (362, 476, 'Western Rome'),
  (363, 622, 'Muhammad'),
  (364, 800, 'Charlemagne'),
  (365, 830, 'Islamic Golden Age'),
  (366, 1206, 'Genghis Khan'),
  (367, 1347, 'Black Death'),
  (368, 1543, 'Heliocentric Model'),
  (369, 1687, 'Newton'),
  (370, 1769, 'Watt'),
  (371, 1843, 'Ada Lovelace'),
  (372, 1854, 'Cholera Traced to Water'),
  (373, 1858, 'Emmeline Pankhurst'),
  (374, 1859, 'Darwin'),
  (375, 1865, 'American Civil War'),
  (376, 1869, 'Periodic Table'),
  (377, 1898, 'Marie Curie'),
  (378, 1905, 'Einstein'),
  (379, 1927, 'Big Bang Theory'),
  (380, 1928, 'Penicillin'),
  (381, 1949, 'Chinese Communist Revolution'),
  (382, 1952, 'Rosalind Franklin'),
  (383, 1953, 'DNA Double Helix'),
  (384, 1955, 'Rosa Parks'),
  (385, 1962, 'Rachel Carson'),
  (386, 1963, 'Sylvia Plath'),
  (387, 1963, 'Valentina Tereshkova'),
  (388, 1969, 'ARPANET'),
  (389, 1977, 'Apple II'),
  (390, 1989, 'World Wide Web'),
  (391, 1990, 'Hubble Space Telescope'),
  (392, 1996, 'Dolly the Sheep'),
  (393, 1998, 'Google'),
  (394, 2003, 'Human Genome Project'),
  (395, 2004, 'Wangari Maathai'),
  (396, 2007, 'Apple iPhone'),
  (397, 2012, 'CRISPR Gene Editing'),
  (398, 2020, 'COVID-19 Pandemic'),
  (399, 2022, 'ChatGPT'),
  (400, 2025, 'Chronology')
on conflict (id) do nothing;

alter table cards add column if not exists is_meta boolean not null default false;
update cards set is_meta = true where id = 400;

create or replace function public.create_match(p_name text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
