-- ReLens backend schema (Supabase / Postgres)
-- Safe to run more than once: SQL Editor -> New query -> paste -> Run

create extension if not exists pgcrypto;

-- ---------- Staff ----------
create table if not exists public.staff (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.staff enable row level security; -- no policies: only the functions below can read it

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;

-- ---------- Customer profiles (for OTP login later) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text,
  phone text,
  created_at timestamptz not null default now()
);

-- ---------- Promo codes (checked on the server) ----------
create table if not exists public.promo_codes (
  code text primary key,
  kind text not null check (kind in ('percent','flat')),
  value numeric not null check (value > 0),
  requires_category text,            -- e.g. 'progressive'
  active boolean not null default true,
  expires_at timestamptz
);
insert into public.promo_codes (code, kind, value, requires_category) values
  ('RELENS10',     'percent', 10,  null),
  ('DOORSTEPFREE', 'flat',    200, null),
  ('PROG500',      'flat',    500, 'progressive')
on conflict (code) do nothing;

-- ---------- Orders / bookings ----------
create sequence if not exists public.order_seq start 1043;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text unique not null,
  user_id uuid references auth.users on delete set null,
  customer_name text not null,
  phone text not null,
  phone_norm text not null,          -- last 10 digits, used for tracking
  service text not null,
  appt_date date,
  appt_time text,
  items jsonb not null default '[]',
  subtotal numeric not null default 0,
  discount numeric not null default 0,
  total numeric not null default 0,
  promo_code text,
  rx jsonb,                          -- typed prescription values
  rx_file_path text,                 -- uploaded slip in the private 'prescriptions' bucket
  status text not null default 'booked'
    check (status in ('booked','inspection','edging','dispatch','delivered','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists orders_phone_idx on public.orders (phone_norm);

create table if not exists public.order_status_history (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders on delete cascade,
  status text not null,
  note text,
  created_at timestamptz not null default now()
);

-- ---------- Row level security ----------
alter table public.orders               enable row level security;
alter table public.order_status_history enable row level security;
alter table public.promo_codes          enable row level security;
alter table public.profiles             enable row level security;

drop policy if exists "own orders" on public.orders;
create policy "own orders"      on public.orders for select to authenticated using (user_id = auth.uid());
drop policy if exists "staff orders" on public.orders;
create policy "staff orders"    on public.orders for all    to authenticated using (public.is_staff()) with check (public.is_staff());
drop policy if exists "own history" on public.order_status_history;
create policy "own history"     on public.order_status_history for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()));
drop policy if exists "staff history" on public.order_status_history;
create policy "staff history"   on public.order_status_history for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
drop policy if exists "staff promos" on public.promo_codes;
create policy "staff promos"    on public.promo_codes for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
drop policy if exists "own profile" on public.profiles;
create policy "own profile"     on public.profiles for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Visitors (not logged in) never touch the tables directly; they only call the functions below.

-- ---------- Discount calculation ----------
create or replace function public.calc_discount(p_code text, p_items jsonb, p_subtotal numeric)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare pc public.promo_codes%rowtype; d numeric := 0;
begin
  if p_code is null or trim(p_code) = '' then return 0; end if;
  select * into pc from public.promo_codes
   where code = upper(trim(p_code)) and active and (expires_at is null or expires_at > now());
  if not found then return 0; end if;
  if pc.requires_category is not null and not exists (
       select 1 from jsonb_array_elements(p_items) i where i->>'category' = pc.requires_category
     ) then return 0; end if;
  d := case pc.kind when 'percent' then round(p_subtotal * pc.value / 100) else pc.value end;
  return least(d, p_subtotal);
end $$;

-- ---------- Create a booking (called from the website) ----------
create or replace function public.create_booking(
  p_name text, p_phone text, p_service text, p_date date, p_time text,
  p_items jsonb default '[]', p_promo text default null,
  p_rx jsonb default null, p_rx_path text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_phone text; v_sub numeric; v_disc numeric; v_code text; v_id uuid;
begin
  v_phone := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  if length(trim(coalesce(p_name, ''))) < 2 or length(v_phone) <> 10 then
    raise exception 'Enter a valid name and 10-digit WhatsApp number';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then p_items := '[]'::jsonb; end if;

  -- NOTE: prices come from the browser. Move prices into a catalog table before trusting totals.
  select coalesce(sum(greatest((i->>'price')::numeric, 0) * greatest(coalesce((i->>'qty')::numeric, 1), 1)), 0)
    into v_sub from jsonb_array_elements(p_items) i;
  v_disc := public.calc_discount(p_promo, p_items, v_sub);
  v_code := 'RL-' || extract(year from now() at time zone 'Asia/Kolkata')::int || '-' || nextval('public.order_seq');

  insert into public.orders (order_code, user_id, customer_name, phone, phone_norm, service,
                             appt_date, appt_time, items, subtotal, discount, total,
                             promo_code, rx, rx_file_path)
  values (v_code, auth.uid(), trim(p_name), p_phone, v_phone, p_service,
          p_date, p_time, p_items, v_sub, v_disc, v_sub - v_disc,
          nullif(upper(trim(coalesce(p_promo, ''))), ''), p_rx, p_rx_path)
  returning id into v_id;

  insert into public.order_status_history (order_id, status, note) values (v_id, 'booked', 'Booking received');

  return jsonb_build_object('order_code', v_code, 'subtotal', v_sub, 'discount', v_disc, 'total', v_sub - v_disc);
end $$;

-- ---------- Track an order (needs order ID + phone, so IDs can't be guessed) ----------
create or replace function public.track_order(p_code text, p_phone text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o public.orders%rowtype;
begin
  select * into o from public.orders
   where order_code = upper(trim(p_code))
     and phone_norm = right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  if not found then return null; end if;
  return jsonb_build_object(
    'order_code', o.order_code, 'status', o.status, 'service', o.service,
    'appt_date', o.appt_date, 'appt_time', o.appt_time, 'total', o.total,
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('status', h.status, 'note', h.note, 'at', h.created_at)
                                          order by h.created_at), '[]'::jsonb)
                   from public.order_status_history h where h.order_id = o.id));
end $$;

-- ---------- Staff: move an order to the next stage ----------
create or replace function public.update_order_status(p_code text, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  update public.orders set status = p_status, updated_at = now()
   where order_code = upper(trim(p_code)) returning id into v_id;
  if v_id is null then raise exception 'Order not found'; end if;
  insert into public.order_status_history (order_id, status, note) values (v_id, p_status, p_note);
end $$;

grant execute on function public.create_booking(text,text,text,date,text,jsonb,text,jsonb,text) to anon, authenticated;
grant execute on function public.track_order(text,text) to anon, authenticated;
grant execute on function public.calc_discount(text,jsonb,numeric) to anon, authenticated;
grant execute on function public.update_order_status(text,text,text) to authenticated;
grant execute on function public.is_staff() to authenticated;

-- ---------- Prescription slips: private bucket, 5 MB, images/PDF only ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('prescriptions', 'prescriptions', false, 5242880, array['image/png','image/jpeg','application/pdf'])
on conflict (id) do nothing;

drop policy if exists "rx upload" on storage.objects;
create policy "rx upload"     on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'prescriptions');
drop policy if exists "rx staff read" on storage.objects;
create policy "rx staff read" on storage.objects for select to authenticated
  using (bucket_id = 'prescriptions' and public.is_staff());

-- ---------- After you sign up once, make yourself staff ----------
-- Find your id under Authentication -> Users, then run:
-- insert into public.staff (user_id) values ('PASTE-YOUR-USER-ID');
