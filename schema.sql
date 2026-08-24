-- ============================================================
-- RA Beauty — قاعدة البيانات (Supabase)
-- شغّلي هذا الملف كامل مرة وحدة في: Supabase ← SQL Editor ← New query ← Run
-- ============================================================

-- 1) ملفات المستخدمين (مربوطة بحسابات الدخول)
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default '',
  username   text unique,
  title      text default '',
  role       text not null default 'staff' check (role in ('owner','staff')),
  color      text default '#6B2E5F',
  created_at timestamptz default now()
);

-- 2) كل بيانات النظام (حجوزات، مخزون، فواتير، مصروفات...) في جدول واحد
create table if not exists public.records (
  id         text primary key,
  kind       text not null,
  data       jsonb not null,
  updated_at timestamptz default now(),
  updated_by uuid default auth.uid()
);
create index if not exists records_kind_idx on public.records(kind);

alter table public.profiles enable row level security;
alter table public.records  enable row level security;

-- 3) دالة تتحقق إذا المستخدمة مالكة
create or replace function public.is_owner()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'owner');
$$;

-- 4) قواعد الوصول: لا أحد يقرأ أو يكتب إلا أعضاء الفريق المسجّلين دخول
drop policy if exists "team reads profiles"    on public.profiles;
drop policy if exists "owners manage profiles" on public.profiles;
create policy "team reads profiles"    on public.profiles for select to authenticated using (true);
create policy "owners manage profiles" on public.profiles for all    to authenticated using (public.is_owner()) with check (public.is_owner());

drop policy if exists "team reads records"  on public.records;
drop policy if exists "team adds records"   on public.records;
drop policy if exists "team edits records"  on public.records;
drop policy if exists "owners delete records" on public.records;
create policy "team reads records"    on public.records for select to authenticated using (true);
create policy "team adds records"     on public.records for insert to authenticated with check (true);
create policy "team edits records"    on public.records for update to authenticated using (true) with check (true);
create policy "owners delete records" on public.records for delete to authenticated using (public.is_owner());

-- 5) إنشاء ملف المستخدم تلقائياً مع كل حساب دخول جديد
--    أول حساب يُنشأ يصير "مالكة" تلقائياً
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, username, title, role, color)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
    split_part(new.email,'@',1),
    coalesce(new.raw_user_meta_data->>'title',''),
    case when (select count(*) from public.profiles) = 0 then 'owner'
         else coalesce(new.raw_user_meta_data->>'role','staff') end,
    coalesce(new.raw_user_meta_data->>'color','#6B2E5F')
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
