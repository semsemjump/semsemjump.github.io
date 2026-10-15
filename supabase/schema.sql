-- 셈셈 점프 학급 랭킹
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여 넣고 Run 을 한 번 누르세요.
-- 다시 실행해도 안전해요 (있는 것은 그대로 두고 함수만 새로 바꿔요).
--
-- 저장하는 것: 학급 코드, 선생님이 정한 학급 이름(선택), 별명, 레벨, 층수, 날짜.
-- 저장하지 않는 것: 실명, 학교, 이메일, 기기 정보, IP.
-- 게임 페이지는 테이블을 직접 읽거나 쓸 수 없고, 아래 함수만 부를 수 있어요.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.classes (
  code        text primary key check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  label       text not null default '' check (char_length(label) <= 20),
  pin_hash    text not null,
  allow_items boolean not null default true,
  fails       int not null default 0,
  locked_until timestamptz,
  created_at  timestamptz not null default now()
);

create table if not exists public.scores (
  class_code text not null references public.classes(code) on delete cascade,
  player_id  uuid not null,            -- random id made by the game for each player on a device
  nickname   text not null check (char_length(nickname) between 1 and 12),
  level      text not null check (level ~ '^([1-9]|1[0-9]|climb)$'),
  easy       boolean not null default false,
  items      boolean not null default false,
  floor      int not null check (floor between 1 and 999),
  hidden     boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (class_code, player_id, level, easy)
);
create index if not exists scores_board on public.scores (class_code, level, easy, floor desc);

-- tables are closed: row level security on, no policies, no grants
alter table public.classes enable row level security;
alter table public.scores  enable row level security;
revoke all on public.classes, public.scores from anon, authenticated;

-- ---------- helpers (not callable from the game) ----------

-- scores disappear 30 days after their last update; classes after 180 days
create or replace function public.ranking_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from scores  where updated_at < now() - interval '30 days';
  delete from classes where created_at < now() - interval '180 days';
$$;

create or replace function public.bad_nickname(p text) returns boolean
language sql immutable set search_path = public as $$
  select lower(p) ~ '(씨발|시발|병신|개새|좆|존나|지랄|새끼|fuck|shit)';
$$;

-- teacher PIN check with a lockout: five wrong PINs lock the class for ten minutes.
-- Returns 'ok' | 'pin' | 'locked' | 'none' instead of raising, so the failure count is kept.
create or replace function public.teacher_check(p_code text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare c classes;
begin
  select * into c from classes where code = upper(p_code) for update;
  if not found then return 'none'; end if;
  if c.locked_until is not null and c.locked_until > now() then return 'locked'; end if;
  if crypt(p_pin, c.pin_hash) = c.pin_hash then
    update classes set fails = 0, locked_until = null where code = c.code;
    return 'ok';
  end if;
  update classes set fails = c.fails + 1,
         locked_until = case when c.fails + 1 >= 5 then now() + interval '10 minutes' end
   where code = c.code;
  return 'pin';
end $$;

-- ---------- called by the game ----------

-- teacher: make a class, get its six-character code
create or replace function public.create_class(p_label text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_code text;
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- no 0/O, 1/I
begin
  if p_pin !~ '^[0-9]{4,8}$' then raise exception 'pin' using hint = '비밀번호는 숫자 4~8자리예요.'; end if;
  if char_length(coalesce(p_label, '')) > 20 then raise exception 'label' using hint = '학급 이름은 20자까지예요.'; end if;
  if (select count(*) from classes where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'busy' using hint = '잠시 뒤에 다시 만들어 주세요.';
  end if;
  perform ranking_cleanup();
  loop
    select string_agg(substr(alphabet, 1 + get_byte(b, i) % 32, 1), '')
      into v_code
      from (select gen_random_bytes(6) b) r, generate_series(0, 5) i;
    exit when not exists (select 1 from classes where code = v_code);
  end loop;
  insert into classes (code, label, pin_hash) values (v_code, coalesce(trim(p_label), ''), crypt(p_pin, gen_salt('bf')));
  return v_code;
end $$;

-- student: check a code before joining
create or replace function public.class_info(p_code text)
returns table (code text, label text, allow_items boolean)
language sql security definer set search_path = public as $$
  select c.code, c.label, c.allow_items from classes c where c.code = upper(p_code);
$$;

-- after a run: keep each player's best floor per level; returns the player's rank, or null if not recorded
create or replace function public.submit_score(p_code text, p_player uuid, p_nick text, p_level text,
                                               p_easy boolean, p_items boolean, p_floor int) returns int
language plpgsql security definer set search_path = public as $$
declare c classes; prev scores; v_floor int;
begin
  select * into c from classes where code = upper(p_code);
  if not found then raise exception 'no class' using hint = '학급 코드를 다시 확인해 주세요.'; end if;
  if p_items and not c.allow_items then return null; end if;           -- this class ranks only runs without items
  p_nick := trim(p_nick);
  if p_nick = '' or char_length(p_nick) > 12 or bad_nickname(p_nick) then raise exception 'nickname'; end if;
  if p_floor < 1 or p_floor > 999 then return null; end if;
  if random() < .02 then perform ranking_cleanup(); end if;              -- now and then, drop expired rows

  select * into prev from scores
   where class_code = c.code and player_id = p_player and level = p_level and easy = p_easy;
  if found and prev.updated_at > now() - interval '5 seconds' then return null; end if;   -- too fast, ignore

  insert into scores as s (class_code, player_id, nickname, level, easy, items, floor)
  values (c.code, p_player, p_nick, p_level, p_easy, p_items, p_floor)
  on conflict (class_code, player_id, level, easy) do update
     set nickname   = excluded.nickname,
         items      = case when excluded.floor > s.floor then excluded.items else s.items end,
         floor      = greatest(s.floor, excluded.floor),
         updated_at = now()
  returning floor into v_floor;

  return 1 + (select count(*) from scores
               where class_code = c.code and level = p_level and easy = p_easy and not hidden and floor > v_floor);
end $$;

-- the board for one level: top 20, plus the asking player's own row if it is lower down
create or replace function public.leaderboard(p_code text, p_level text, p_easy boolean, p_player uuid)
returns table (rank bigint, nickname text, floor int, items boolean, me boolean, updated_at timestamptz)
language sql security definer set search_path = public as $$
  with b as (
    select s.*, rank() over (order by s.floor desc) as r
      from scores s
     where s.class_code = upper(p_code) and s.level = p_level and s.easy = p_easy and not s.hidden
  )
  select r, b.nickname, b.floor, b.items, b.player_id = p_player, b.updated_at
    from b where r <= 20 or b.player_id = p_player
   order by r, b.updated_at
   limit 21;
$$;

-- teacher tools: each returns {"ok": true, ...} or {"ok": false, "error": "pin" | "locked" | "none"}
create or replace function public.teacher_board(p_code text, p_pin text, p_level text, p_easy boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st text := teacher_check(p_code, p_pin); c classes;
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  select * into c from classes where code = upper(p_code);
  return jsonb_build_object('ok', true, 'label', c.label, 'allow_items', c.allow_items, 'rows',
    coalesce((select jsonb_agg(jsonb_build_object('player_id', s.player_id, 'nickname', s.nickname, 'floor', s.floor,
                                                  'items', s.items, 'hidden', s.hidden, 'updated_at', s.updated_at)
                               order by s.floor desc)
                from scores s where s.class_code = c.code and s.level = p_level and s.easy = p_easy), '[]'::jsonb));
end $$;

create or replace function public.teacher_hide(p_code text, p_pin text, p_player uuid, p_hidden boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st text := teacher_check(p_code, p_pin);
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  update scores set hidden = p_hidden where class_code = upper(p_code) and player_id = p_player;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.teacher_delete(p_code text, p_pin text, p_player uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st text := teacher_check(p_code, p_pin);
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  delete from scores where class_code = upper(p_code) and player_id = p_player;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.teacher_settings(p_code text, p_pin text, p_allow_items boolean, p_label text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st text := teacher_check(p_code, p_pin);
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  if char_length(coalesce(p_label, '')) > 20 then return jsonb_build_object('ok', false, 'error', 'label'); end if;
  update classes set allow_items = p_allow_items, label = coalesce(trim(p_label), '') where code = upper(p_code);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.teacher_reset(p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st text := teacher_check(p_code, p_pin);
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  delete from scores where class_code = upper(p_code);
  return jsonb_build_object('ok', true);
end $$;

-- teacher: close the class for good (its scores go with it)
create or replace function public.teacher_close(p_code text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st text := teacher_check(p_code, p_pin);
begin
  if st <> 'ok' then return jsonb_build_object('ok', false, 'error', st); end if;
  delete from classes where code = upper(p_code);
  return jsonb_build_object('ok', true);
end $$;

-- only the game-facing functions are callable from the page
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.create_class(text, text),
  public.class_info(text),
  public.submit_score(text, uuid, text, text, boolean, boolean, int),
  public.leaderboard(text, text, boolean, uuid),
  public.teacher_board(text, text, text, boolean),
  public.teacher_hide(text, text, uuid, boolean),
  public.teacher_delete(text, text, uuid),
  public.teacher_settings(text, text, boolean, text),
  public.teacher_reset(text, text),
  public.teacher_close(text, text)
to anon;
