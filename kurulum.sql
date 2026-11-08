-- =====================================================================
--  VILLA DEFTERİ · Supabase veritabanı kurulumu (v1)
--  Supabase panelinde: SQL Editor → New query → bu dosyanın tamamını
--  yapıştırın → Run. Tek seferde çalıştırılır.
--
--  - Her tablo kullanıcıya bağlıdır (user_id) ve satır güvenliği (RLS)
--    açıktır: yalnızca giriş yapan hesap kendi verisini görür.
--  - Parasal alanların hiçbiri eksi olamaz (CHECK kuralları).
--  - Aynı villada çakışan rezervasyon ve çakışan fiyat dönemi
--    veritabanı seviyesinde engellenir (iptaller hariç).
-- =====================================================================

create extension if not exists btree_gist;

-- ---------- VİLLALAR ----------
create table public.villas (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name          text not null check (length(trim(name)) > 0),
  location      text not null default '',
  commission    numeric(5,2)  not null default 15 check (commission between 0 and 100),
  cleaning_cost numeric(12,2) not null default 0  check (cleaning_cost >= 0),   -- temizlikçiye ödenen
  cleaning_fee  numeric(12,2) not null default 0  check (cleaning_fee  >= 0),   -- misafirden alınan
  cleaning_under int not null default 7 check (cleaning_under >= 0),           -- bu gecenin altında temizlik ücreti misafire
  deposit       numeric(12,2) not null default 0  check (deposit       >= 0),
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);

-- ---------- KANALLAR (ajanslar / direkt) ----------
create table public.channels (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (length(trim(name)) > 0),
  commission  numeric(5,2) check (commission is null or commission between 0 and 100), -- null = villa varsayılanı
  is_direct   boolean not null default false,
  created_at  timestamptz not null default now(),
  unique (user_id, name)
);

-- ---------- GECELİK FİYAT DÖNEMLERİ ----------
create table public.rate_periods (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  villa_id      uuid not null references public.villas(id) on delete cascade,
  date_from     date not null,
  date_to       date not null,                       -- dahil
  nightly_price numeric(12,2) not null check (nightly_price > 0),
  created_at    timestamptz not null default now(),
  check (date_to >= date_from),
  constraint rate_periods_no_overlap exclude using gist (
    villa_id with =, daterange(date_from, date_to, '[]') with &&)
);

-- ---------- REZERVASYONLAR ----------
create table public.reservations (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  villa_id       uuid not null references public.villas(id) on delete cascade,
  channel_id     uuid references public.channels(id) on delete set null,
  status         text not null default 'kesin' check (status in ('kesin','opsiyon','iptal')),
  check_in       date not null,
  check_out      date not null,
  option_until   date,
  guest_name     text not null default '',
  guest_phone    text not null default '',
  guest_id_no    text not null default '',            -- TC / pasaport
  adults         int  check (adults   is null or adults   >= 0),
  children       int  check (children is null or children >= 0),
  price          numeric(12,2) not null default 0 check (price        >= 0),
  commission     numeric(5,2)  not null default 0 check (commission between 0 and 100),
  cleaning_charged boolean not null default false,   -- temizlik ücreti misafire yansıtıldı mı
  cleaning_fee   numeric(12,2) not null default 0 check (cleaning_fee >= 0),
  deposit        numeric(12,2) not null default 0 check (deposit      >= 0),
  deposit_status text not null default '' check (deposit_status in ('','alindi','iade','kesildi')),
  note           text not null default '',
  source         text not null default 'app',         -- app / telegram / import
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (check_out > check_in),
  constraint reservations_no_overlap exclude using gist (
    villa_id with =, daterange(check_in, check_out, '[)') with &&) where (status <> 'iptal')
);
create index on public.reservations (villa_id, check_in);

-- ---------- ÖDEMELER (tahsilatlar) ----------
create table public.payments (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  paid_on        date not null default current_date,
  amount         numeric(12,2) not null check (amount > 0),
  note           text not null default '',
  created_at     timestamptz not null default now()
);
create index on public.payments (reservation_id);

-- ---------- GİDERLER ----------
create table public.expenses (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  villa_id       uuid references public.villas(id) on delete set null,   -- null = genel gider
  reservation_id uuid references public.reservations(id) on delete set null,
  spent_on       date not null default current_date,
  category       text not null,
  amount         numeric(12,2) not null check (amount > 0),
  note           text not null default '',
  created_at     timestamptz not null default now()
);
create index on public.expenses (spent_on);

-- ---------- AYARLAR (kullanıcı başına tek satır) ----------
create table public.settings (
  user_id          uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  telegram_chat_id text not null default '',
  daily_report_at  time not null default '08:30',
  updated_at       timestamptz not null default now()
);

-- updated_at otomatik
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger reservations_touch before update on public.reservations
  for each row execute function public.touch_updated_at();

-- ---------- SATIR GÜVENLİĞİ (RLS) ----------
do $$
declare t text;
begin
  foreach t in array array['villas','channels','rate_periods','reservations','payments','expenses','settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format($p$create policy "kendi_verim" on public.%I for all to authenticated
                     using (user_id = auth.uid()) with check (user_id = auth.uid())$p$, t);
  end loop;
end $$;

-- ---------- CANLI SENKRON (diğer cihazlar anında güncellensin) ----------
alter publication supabase_realtime add table
  public.villas, public.channels, public.rate_periods, public.reservations, public.payments, public.expenses;
