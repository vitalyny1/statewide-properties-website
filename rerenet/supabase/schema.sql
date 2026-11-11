-- ReReNet consolidated Supabase schema
-- Apply once in Supabase SQL Editor. Safe to re-run (uses IF NOT EXISTS / replace).
-- Auth users are the source of truth for login credentials. Never store passwords here.

create extension if not exists pgcrypto;

-- 1) Agent public profile. Private contact information lives in agent_contacts.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  brokerage text,
  license_number text,
  home_zip text,
  service_areas text[] not null default '{}',
  account_type text not null default 'agent' check (account_type in ('agent','service_provider','admin')),
  is_verified boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 2) Private agent contact details. Not exposed until an accepted referral is unlocked.
create table if not exists public.agent_contacts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  email text,
  phone text,
  updated_at timestamptz not null default now()
);

-- 3) Referral opportunities posted by agents.
create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.profiles(id) on delete cascade,
  referral_type text not null check (referral_type in ('Buyer','Seller','Tenant')),
  title text not null,
  description text,
  city text,
  state text,
  zip_code text,
  latitude double precision,
  longitude double precision,
  status text not null default 'active' check (status in ('active','paused','matched','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 4) Agent 2's request to Agent 1. A request is free; Agent 1 accepts/declines it.
create table if not exists public.referral_interests (
  id uuid primary key default gen_random_uuid(),
  referral_id uuid not null references public.referrals(id) on delete cascade,
  agent_id uuid not null references public.profiles(id) on delete cascade,
  message text,
  proposed_referral_fee numeric(5,2),
  status text not null default 'pending' check (status in ('pending','accepted','declined','withdrawn')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (referral_id, agent_id)
);

-- 5) $5 unlock record. A trusted server/Stripe webhook must set status='paid';
-- clients cannot create or mark payments paid directly.
create table if not exists public.referral_payments (
  id uuid primary key default gen_random_uuid(),
  interest_id uuid not null unique references public.referral_interests(id) on delete cascade,
  payer_id uuid not null references public.profiles(id),
  recipient_id uuid not null references public.profiles(id),
  amount_cents integer not null default 500 check (amount_cents > 0),
  currency text not null default 'usd',
  provider text not null default 'stripe',
  checkout_session_id text unique,
  payment_intent_id text unique,
  status text not null default 'pending' check (status in ('pending','paid','failed','refunded')),
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

-- 6) Private messages between the two agents, available after the $5 unlock.
create table if not exists public.referral_messages (
  id uuid primary key default gen_random_uuid(),
  interest_id uuid not null references public.referral_interests(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (length(trim(body)) between 1 and 5000),
  created_at timestamptz not null default now()
);

-- 7) Brokerage-to-brokerage referral agreement record.
-- Actual signatures/document storage can be added after the MVP workflow is tested.
create table if not exists public.referral_agreements (
  id uuid primary key default gen_random_uuid(),
  interest_id uuid not null unique references public.referral_interests(id) on delete cascade,
  referring_brokerage text,
  receiving_brokerage text,
  referral_percentage numeric(5,2) check (referral_percentage >= 0 and referral_percentage <= 100),
  payment_condition text,
  status text not null default 'draft' check (status in ('draft','sent','partially_signed','executed','cancelled')),
  agreement_text text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 8) Audit trail for opportunity/request status changes.
create table if not exists public.referral_status_history (
  id uuid primary key default gen_random_uuid(),
  referral_id uuid references public.referrals(id) on delete cascade,
  interest_id uuid references public.referral_interests(id) on delete cascade,
  changed_by uuid references public.profiles(id),
  old_status text,
  new_status text not null,
  note text,
  created_at timestamptz not null default now(),
  check (referral_id is not null or interest_id is not null)
);

create index if not exists referrals_status_created_idx on public.referrals(status, created_at desc);
create index if not exists referrals_zip_idx on public.referrals(zip_code);
create index if not exists referrals_agent_idx on public.referrals(agent_id);
create index if not exists interests_referral_idx on public.referral_interests(referral_id, status);
create index if not exists interests_agent_idx on public.referral_interests(agent_id);
create index if not exists messages_interest_created_idx on public.referral_messages(interest_id, created_at);
create index if not exists history_referral_created_idx on public.referral_status_history(referral_id, created_at);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists referrals_set_updated_at on public.referrals;
create trigger referrals_set_updated_at before update on public.referrals for each row execute function public.set_updated_at();
drop trigger if exists interests_set_updated_at on public.referral_interests;
create trigger interests_set_updated_at before update on public.referral_interests for each row execute function public.set_updated_at();
drop trigger if exists agreements_set_updated_at on public.referral_agreements;
create trigger agreements_set_updated_at before update on public.referral_agreements for each row execute function public.set_updated_at();

-- Automatically create the profile and private contact row for every new Auth user.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, brokerage, home_zip)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'brokerage', ''),
    nullif(new.raw_user_meta_data ->> 'zip_code', '')
  )
  on conflict (id) do nothing;

  insert into public.agent_contacts (user_id, email, phone)
  values (
    new.id,
    new.email,
    nullif(new.raw_user_meta_data ->> 'phone', '')
  )
  on conflict (user_id) do update
    set email = excluded.email,
        phone = coalesce(excluded.phone, public.agent_contacts.phone);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_rerenet on auth.users;
create trigger on_auth_user_created_rerenet
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- RLS: enable on all application tables.
alter table public.profiles enable row level security;
alter table public.agent_contacts enable row level security;
alter table public.referrals enable row level security;
alter table public.referral_interests enable row level security;
alter table public.referral_payments enable row level security;
alter table public.referral_messages enable row level security;
alter table public.referral_agreements enable row level security;
alter table public.referral_status_history enable row level security;

-- Profiles expose business identity, not private email/phone.
drop policy if exists "profiles readable by signed in agents" on public.profiles;
create policy "profiles readable by signed in agents" on public.profiles
  for select to authenticated using (true);
drop policy if exists "agents update own profile" on public.profiles;
create policy "agents update own profile" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists "agents insert own profile" on public.profiles;
create policy "agents insert own profile" on public.profiles
  for insert to authenticated with check (auth.uid() = id);

-- Contacts are private until the request is accepted and the $5 unlock is paid.
drop policy if exists "own contact or paid referral connection" on public.agent_contacts;
create policy "own contact or paid referral connection" on public.agent_contacts
  for select to authenticated using (
    user_id = auth.uid()
    or exists (
      select 1
      from public.referral_interests i
      join public.referrals r on r.id = i.referral_id
      join public.referral_payments p on p.interest_id = i.id
      where i.status = 'accepted'
        and p.status = 'paid'
        and (
          (i.agent_id = auth.uid() and r.agent_id = agent_contacts.user_id)
          or (r.agent_id = auth.uid() and i.agent_id = agent_contacts.user_id)
        )
    )
  );
drop policy if exists "agents insert own contact" on public.agent_contacts;
create policy "agents insert own contact" on public.agent_contacts
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "agents update own contact" on public.agent_contacts;
create policy "agents update own contact" on public.agent_contacts
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Active referrals can be browsed by signed-in agents; owners manage their own.
drop policy if exists "signed in agents browse active referrals" on public.referrals;
create policy "signed in agents browse active referrals" on public.referrals
  for select to authenticated using (status = 'active' or agent_id = auth.uid());
drop policy if exists "agents create own referrals" on public.referrals;
create policy "agents create own referrals" on public.referrals
  for insert to authenticated with check (agent_id = auth.uid());
drop policy if exists "owners update own referrals" on public.referrals;
create policy "owners update own referrals" on public.referrals
  for update to authenticated using (agent_id = auth.uid()) with check (agent_id = auth.uid());
drop policy if exists "owners delete own referrals" on public.referrals;
create policy "owners delete own referrals" on public.referrals
  for delete to authenticated using (agent_id = auth.uid());

-- Agent 2 creates their own interest; Agent 1 can review requests on their referrals.
drop policy if exists "participants read interests" on public.referral_interests;
create policy "participants read interests" on public.referral_interests
  for select to authenticated using (
    agent_id = auth.uid()
    or exists (select 1 from public.referrals r where r.id = referral_id and r.agent_id = auth.uid())
  );
drop policy if exists "agents create own interest" on public.referral_interests;
create policy "agents create own interest" on public.referral_interests
  for insert to authenticated with check (
    agent_id = auth.uid()
    and exists (select 1 from public.referrals r where r.id = referral_id and r.agent_id <> auth.uid() and r.status = 'active')
  );
drop policy if exists "owner reviews interests" on public.referral_interests;
create policy "owner reviews interests" on public.referral_interests
  for update to authenticated using (
    exists (select 1 from public.referrals r where r.id = referral_id and r.agent_id = auth.uid())
  ) with check (
    exists (select 1 from public.referrals r where r.id = referral_id and r.agent_id = auth.uid())
  );

-- Payment rows can be read by participants. Only service_role/server can write payment state.
drop policy if exists "participants read payment status" on public.referral_payments;
create policy "participants read payment status" on public.referral_payments
  for select to authenticated using (payer_id = auth.uid() or recipient_id = auth.uid());

-- Messaging is enabled only after accepted request and successful unlock.
drop policy if exists "paid participants read messages" on public.referral_messages;
create policy "paid participants read messages" on public.referral_messages
  for select to authenticated using (
    exists (
      select 1 from public.referral_interests i
      join public.referrals r on r.id = i.referral_id
      join public.referral_payments p on p.interest_id = i.id
      where i.id = interest_id and i.status = 'accepted' and p.status = 'paid'
        and (i.agent_id = auth.uid() or r.agent_id = auth.uid())
    )
  );
drop policy if exists "paid participants send messages" on public.referral_messages;
create policy "paid participants send messages" on public.referral_messages
  for insert to authenticated with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.referral_interests i
      join public.referrals r on r.id = i.referral_id
      join public.referral_payments p on p.interest_id = i.id
      where i.id = interest_id and i.status = 'accepted' and p.status = 'paid'
        and (i.agent_id = auth.uid() or r.agent_id = auth.uid())
    )
  );

-- Agreement records are visible only to the two agents on that referral request.
drop policy if exists "participants read agreements" on public.referral_agreements;
create policy "participants read agreements" on public.referral_agreements
  for select to authenticated using (
    exists (
      select 1 from public.referral_interests i
      join public.referrals r on r.id = i.referral_id
      where i.id = interest_id and (i.agent_id = auth.uid() or r.agent_id = auth.uid())
    )
  );
drop policy if exists "participants create agreements" on public.referral_agreements;
create policy "participants create agreements" on public.referral_agreements
  for insert to authenticated with check (
    created_by = auth.uid()
    and exists (
      select 1 from public.referral_interests i
      join public.referrals r on r.id = i.referral_id
      where i.id = interest_id and (i.agent_id = auth.uid() or r.agent_id = auth.uid())
    )
  );
drop policy if exists "participants update agreements" on public.referral_agreements;
create policy "participants update agreements" on public.referral_agreements
  for update to authenticated using (
    exists (
      select 1 from public.referral_interests i
      join public.referrals r on r.id = i.referral_id
      where i.id = interest_id and (i.agent_id = auth.uid() or r.agent_id = auth.uid())
    )
  ) with check (
    exists (
      select 1 from public.referral_interests i
      join public.referrals r on r.id = i.referral_id
      where i.id = interest_id and (i.agent_id = auth.uid() or r.agent_id = auth.uid())
    )
  );

-- Audit trail visible only to the owner of the referral or the requesting agent.
drop policy if exists "participants read status history" on public.referral_status_history;
create policy "participants read status history" on public.referral_status_history
  for select to authenticated using (
    (referral_id is not null and exists (select 1 from public.referrals r where r.id = referral_id and r.agent_id = auth.uid()))
    or
    (interest_id is not null and exists (
      select 1 from public.referral_interests i join public.referrals r on r.id = i.referral_id
      where i.id = interest_id and (i.agent_id = auth.uid() or r.agent_id = auth.uid())
    ))
  );

grant usage on schema public to anon, authenticated;
grant select on public.referrals to authenticated;
grant insert, update, delete on public.referrals to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update on public.agent_contacts to authenticated;
grant select, insert, update on public.referral_interests to authenticated;
grant select on public.referral_payments to authenticated;
grant select, insert on public.referral_messages to authenticated;
grant select, insert, update on public.referral_agreements to authenticated;
grant select on public.referral_status_history to authenticated;

-- Note: status-history rows and payment rows are written by trusted server functions/webhooks,
-- not by browser code. Never put the Supabase service-role key in the website.
