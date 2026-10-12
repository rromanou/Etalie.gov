-- ============================================================
-- patch-cib-entreprise-avancee-20.sql
-- À exécuter après patch-cib-entreprise-avancee-19.sql. Additif et rejouable.
--
-- COMMISSARIATS + HIÉRARCHIE POLICIÈRE.
--
-- HYPOTHÈSES (le message original s'est coupé avant la fin de la
-- description militaire, et plusieurs détails n'étaient pas chiffrés) :
--  - 15 grades, ordre fixe ci-dessous (_grades_police()). Chaque grade a
--    3 sous-grades cosmétiques (3e/2e/1re classe) qui NE CHEVAUCHENT PAS
--    entre deux grades différents : le rang total comparable est
--    grade*10 + sous_grade (ex. grade 2 / 1re classe = 23, toujours
--    inférieur à grade 3 / 3e classe = 31).
--  - Permissions cumulatives simples : un membre de grade G peut
--    dresser des infractions jusqu'au palier floor((G-1)/3)+1 (palier 6
--    atteint au grade 15, réservé en pratique aux types de commissariat
--    autorisés — voir patch 21), et peut promouvoir/rétrograder/renvoyer
--    uniquement des membres strictement en dessous de son propre rang
--    total, jamais à un grade égal ou supérieur au sien.
--  - Le Directeur (directeur_id du commissariat) a toute autorité sur
--    son commissariat, peu importe son propre grade. Un commissariat de
--    type "royal" a autorité de supervision sur TOUS les commissariats
--    (promotion/rétrogradation/renvoi partout), cohérent avec le fait
--    que les infractions de palier 6 ("royales") lui sont réservées.
--  - Le matricule (7 chiffres) est attribué une seule fois par citoyen,
--    de façon permanente, même après un renvoi ou un transfert — stocké
--    à part (matricules_policiers) pour ne jamais être perdu ni réutilisé.
--  - Transfert entre commissariats : l'agent demande, le Directeur du
--    commissariat de destination accepte ou refuse ; le matricule et le
--    grade sont conservés tels quels.
--  - Seul le gouvernement (est_admin_actuel()) crée un commissariat et
--    nomme son premier Directeur.
-- ============================================================

create table if not exists comisseriats (
  id          uuid primary key default gen_random_uuid(),
  nom         text not null,
  type        text not null check (type in ('police','police_royale_militaire','police_militaire','royal')),
  directeur_id uuid references auth.users(id),
  adresse     text,
  statut      text not null default 'actif' check (statut in ('actif','ferme')),
  cree_le     timestamptz not null default now()
);
alter table comisseriats enable row level security;
drop policy if exists "Lecture publique des commissariats" on comisseriats;
create policy "Lecture publique des commissariats" on comisseriats for select using (true);

create table if not exists matricules_policiers (
  citoyen_id uuid primary key references auth.users(id),
  matricule  text not null unique,
  cree_le    timestamptz not null default now()
);
alter table matricules_policiers enable row level security;
drop policy if exists "Lecture publique des matricules" on matricules_policiers;
create policy "Lecture publique des matricules" on matricules_policiers for select using (true);

create table if not exists comisseriats_membres (
  id             uuid primary key default gen_random_uuid(),
  comisseriat_id uuid not null references comisseriats(id) on delete cascade,
  citoyen_id     uuid not null references auth.users(id),
  matricule      text not null,
  grade          int not null default 1 check (grade between 1 and 15),
  sous_grade     int not null default 1 check (sous_grade between 1 and 3),
  statut         text not null default 'actif' check (statut in ('actif','renvoye')),
  cree_le        timestamptz not null default now()
);
-- Un seul poste actif à la fois par citoyen (il doit être renvoyé/transféré avant d'en reprendre un autre).
create unique index if not exists comisseriats_membres_actif_unique on comisseriats_membres (citoyen_id) where statut = 'actif';
alter table comisseriats_membres enable row level security;
drop policy if exists "Lecture publique des membres de commissariat" on comisseriats_membres;
create policy "Lecture publique des membres de commissariat" on comisseriats_membres for select using (true);

create or replace function _grades_police()
returns text[] language sql immutable as $$
  select array['Cadet','Agent','Agent principal','Caporal','Caporal-chef','Brigadier','Brigadier-chef',
    'Sergent','Sergent-chef','Lieutenant','Capitaine','Commandant','Inspecteur','Inspecteur-chef','Directeur-adjoint'];
$$;

create or replace function _nom_grade(p_grade int)
returns text language sql immutable as $$
  select (_grades_police())[greatest(1, least(15, p_grade))];
$$;

create or replace function _rang_total(p_grade int, p_sous_grade int)
returns int language sql immutable as $$ select p_grade * 10 + p_sous_grade; $$;

-- Rang total du citoyen dans SON commissariat actuel (0 s'il n'est pas policier).
create or replace function _mon_rang_police()
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select _rang_total(grade, sous_grade) from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif'), 0);
$$;
grant execute on function _mon_rang_police() to authenticated;

create or replace function _est_directeur(p_comisseriat_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from comisseriats where id = p_comisseriat_id and directeur_id = auth.uid());
$$;

create or replace function _est_superviseur_royal()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from comisseriats_membres m join comisseriats c on c.id = m.comisseriat_id
    where m.citoyen_id = auth.uid() and m.statut = 'actif' and c.type = 'royal')
    or exists (select 1 from comisseriats where type = 'royal' and directeur_id = auth.uid());
$$;
grant execute on function _est_superviseur_royal() to authenticated;

create or replace function _generer_matricule()
returns text language plpgsql as $$
declare v text;
begin
  loop
    v := lpad((floor(random() * 10000000))::text, 7, '0');
    exit when not exists (select 1 from matricules_policiers where matricule = v);
  end loop;
  return v;
end; $$;

create or replace function gouv_creer_comisseriat(p_nom text, p_type text, p_directeur_username text, p_adresse text default null)
returns comisseriats language plpgsql security definer set search_path = public as $$
declare v_row comisseriats; v_directeur uuid;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_type not in ('police','police_royale_militaire','police_militaire','royal') then raise exception 'Type invalide.'; end if;
  if p_nom is null or char_length(trim(p_nom)) = 0 then raise exception 'Nom requis.'; end if;
  select id into v_directeur from citoyens where lower(username) = lower(trim(p_directeur_username));
  if v_directeur is null then raise exception 'Directeur introuvable.'; end if;
  insert into comisseriats (nom, type, directeur_id, adresse) values (trim(p_nom), p_type, v_directeur, p_adresse) returning * into v_row;
  perform _embaucher_policier(v_row.id, v_directeur, 15, 3);
  return v_row;
end; $$;
grant execute on function gouv_creer_comisseriat(text, text, text) to authenticated;

create or replace function _embaucher_policier(p_comisseriat_id uuid, p_citoyen_id uuid, p_grade int default 1, p_sous_grade int default 1)
returns comisseriats_membres language plpgsql security definer set search_path = public as $$
declare v_matricule text; v_row comisseriats_membres;
begin
  if exists (select 1 from comisseriats_membres where citoyen_id = p_citoyen_id and statut = 'actif') then
    raise exception 'Ce citoyen occupe déjà un poste actif dans un commissariat.';
  end if;
  select matricule into v_matricule from matricules_policiers where citoyen_id = p_citoyen_id;
  if v_matricule is null then
    v_matricule := _generer_matricule();
    insert into matricules_policiers (citoyen_id, matricule) values (p_citoyen_id, v_matricule);
  end if;
  insert into comisseriats_membres (comisseriat_id, citoyen_id, matricule, grade, sous_grade)
    values (p_comisseriat_id, p_citoyen_id, v_matricule, p_grade, p_sous_grade) returning * into v_row;
  return v_row;
end; $$;

create or replace function comisseriat_embaucher(p_comisseriat_id uuid, p_username text)
returns comisseriats_membres language plpgsql security definer set search_path = public as $$
declare v_citoyen uuid;
begin
  if not (_est_directeur(p_comisseriat_id) or _est_superviseur_royal()) then raise exception 'Réservé au Directeur du commissariat.'; end if;
  select id into v_citoyen from citoyens where lower(username) = lower(trim(p_username));
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;
  return _embaucher_policier(p_comisseriat_id, v_citoyen, 1, 1);
end; $$;
grant execute on function comisseriat_embaucher(uuid, text) to authenticated;

create or replace function comisseriat_promouvoir(p_membre_id uuid, p_grade int, p_sous_grade int)
returns void language plpgsql security definer set search_path = public as $$
declare m comisseriats_membres; v_mon_rang int; v_nouveau_rang int;
begin
  if p_grade not between 1 and 15 or p_sous_grade not between 1 and 3 then raise exception 'Grade ou sous-grade invalide.'; end if;
  select * into m from comisseriats_membres where id = p_membre_id and statut = 'actif';
  if m.id is null then raise exception 'Membre introuvable ou inactif.'; end if;
  v_nouveau_rang := _rang_total(p_grade, p_sous_grade);
  if _est_directeur(m.comisseriat_id) or _est_superviseur_royal() then
    -- Autorité totale, aucune contrainte de rang.
    null;
  else
    v_mon_rang := _mon_rang_police();
    if v_mon_rang = 0 then raise exception 'Accès refusé.'; end if;
    if v_nouveau_rang >= v_mon_rang then raise exception 'Vous ne pouvez promouvoir quelqu''un à un rang égal ou supérieur au vôtre.'; end if;
    if _rang_total(m.grade, m.sous_grade) >= v_mon_rang then raise exception 'Vous ne pouvez agir que sur des membres strictement en dessous de votre rang.'; end if;
  end if;
  update comisseriats_membres set grade = p_grade, sous_grade = p_sous_grade where id = p_membre_id;
end; $$;
grant execute on function comisseriat_promouvoir(uuid, int, int) to authenticated;

create or replace function comisseriat_renvoyer(p_membre_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m comisseriats_membres; v_mon_rang int;
begin
  select * into m from comisseriats_membres where id = p_membre_id and statut = 'actif';
  if m.id is null then raise exception 'Membre introuvable ou inactif.'; end if;
  if not (_est_directeur(m.comisseriat_id) or _est_superviseur_royal()) then
    v_mon_rang := _mon_rang_police();
    if v_mon_rang = 0 or _rang_total(m.grade, m.sous_grade) >= v_mon_rang then raise exception 'Accès refusé.'; end if;
  end if;
  update comisseriats_membres set statut = 'renvoye' where id = p_membre_id;
end; $$;
grant execute on function comisseriat_renvoyer(uuid) to authenticated;

create table if not exists comisseriats_transferts (
  id                 uuid primary key default gen_random_uuid(),
  citoyen_id         uuid not null references auth.users(id),
  comisseriat_source uuid not null references comisseriats(id),
  comisseriat_dest   uuid not null references comisseriats(id),
  statut             text not null default 'en_attente' check (statut in ('en_attente','acceptee','refusee')),
  cree_le            timestamptz not null default now()
);
alter table comisseriats_transferts enable row level security;
drop policy if exists "Voir ses transferts ou ceux de son commissariat" on comisseriats_transferts;
create policy "Voir ses transferts ou ceux de son commissariat" on comisseriats_transferts for select
  using (citoyen_id = auth.uid() or est_admin_actuel()
    or exists (select 1 from comisseriats c where c.id = comisseriats_transferts.comisseriat_dest and c.directeur_id = auth.uid())
    or exists (select 1 from comisseriats c where c.id = comisseriats_transferts.comisseriat_source and c.directeur_id = auth.uid()));

create or replace function comisseriat_demander_transfert(p_comisseriat_dest uuid)
returns comisseriats_transferts language plpgsql security definer set search_path = public as $$
declare m comisseriats_membres; v_row comisseriats_transferts;
begin
  select * into m from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif';
  if m.id is null then raise exception 'Vous n''occupez aucun poste actif.'; end if;
  if m.comisseriat_id = p_comisseriat_dest then raise exception 'Vous êtes déjà dans ce commissariat.'; end if;
  insert into comisseriats_transferts (citoyen_id, comisseriat_source, comisseriat_dest) values (auth.uid(), m.comisseriat_id, p_comisseriat_dest) returning * into v_row;
  return v_row;
end; $$;
grant execute on function comisseriat_demander_transfert(uuid) to authenticated;

create or replace function comisseriat_traiter_transfert(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare t comisseriats_transferts; m comisseriats_membres;
begin
  select * into t from comisseriats_transferts where id = p_id and statut = 'en_attente';
  if t.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if not (_est_directeur(t.comisseriat_dest) or _est_superviseur_royal()) then raise exception 'Réservé au Directeur du commissariat de destination.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  update comisseriats_transferts set statut = p_decision where id = p_id;
  if p_decision = 'acceptee' then
    select * into m from comisseriats_membres where citoyen_id = t.citoyen_id and statut = 'actif';
    update comisseriats_membres set comisseriat_id = t.comisseriat_dest where id = m.id;
  end if;
end; $$;
grant execute on function comisseriat_traiter_transfert(uuid, text) to authenticated;

-- ---- Lecture ----
create or replace function liste_comisseriats()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'nom', c.nom, 'type', c.type, 'directeur', d.username, 'adresse', c.adresse, 'statut', c.statut,
    'effectif', (select count(*) from comisseriats_membres m where m.comisseriat_id = c.id and m.statut = 'actif')
  ) order by c.nom), '[]'::jsonb)
  from comisseriats c left join citoyens d on d.id = c.directeur_id;
$$;
grant execute on function liste_comisseriats() to authenticated, anon;

create or replace function comisseriat_membres(p_comisseriat_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'citoyen_id', m.citoyen_id, 'username', c.username, 'matricule', m.matricule,
    'grade', m.grade, 'nom_grade', _nom_grade(m.grade), 'sous_grade', m.sous_grade
  ) order by m.grade desc, m.sous_grade desc), '[]'::jsonb)
  from comisseriats_membres m join citoyens c on c.id = m.citoyen_id
  where m.comisseriat_id = p_comisseriat_id and m.statut = 'actif';
$$;
grant execute on function comisseriat_membres(uuid) to authenticated, anon;

create or replace function mon_poste_police()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when m.id is null then null else jsonb_build_object(
    'membre_id', m.id, 'comisseriat_id', m.comisseriat_id, 'comisseriat_nom', c.nom, 'comisseriat_type', c.type,
    'matricule', m.matricule, 'grade', m.grade, 'nom_grade', _nom_grade(m.grade), 'sous_grade', m.sous_grade,
    'est_directeur', c.directeur_id = auth.uid(), 'rang_total', _rang_total(m.grade, m.sous_grade)
  ) end
  from comisseriats_membres m join comisseriats c on c.id = m.comisseriat_id
  where m.citoyen_id = auth.uid() and m.statut = 'actif';
$$;
grant execute on function mon_poste_police() to authenticated;

create or replace function mes_demandes_transfert_recues()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_com uuid;
begin
  select comisseriat_id into v_com from comisseriats_membres where citoyen_id = auth.uid() and statut = 'actif';
  if v_com is null then return '[]'::jsonb; end if;
  if not (_est_directeur(v_com) or _est_superviseur_royal()) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', t.id, 'citoyen', c.username, 'comisseriat_source', cs.nom, 'cree_le', t.cree_le
  ) order by t.cree_le) from comisseriats_transferts t join citoyens c on c.id = t.citoyen_id join comisseriats cs on cs.id = t.comisseriat_source
    where t.comisseriat_dest = v_com and t.statut = 'en_attente'), '[]'::jsonb);
end; $$;
grant execute on function mes_demandes_transfert_recues() to authenticated;
