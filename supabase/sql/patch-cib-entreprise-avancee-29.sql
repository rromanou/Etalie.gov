-- ============================================================
-- patch-cib-entreprise-avancee-29.sql
-- À exécuter après patch-cib-entreprise-avancee-28.sql. Additif et rejouable.
--
-- CONTENU
--  1. CORRECTIF création de carte : "function digest(text, unknown) does
--     not exist" (pgcrypto est dans le schéma "extensions" sur Supabase,
--     et les fonctions security definer n'y avaient pas accès).
--  2. CORRECTIF suppression d'entreprise : toutes les clés étrangères qui
--     pointent vers entreprises / entreprises_membres / entreprises_roles
--     deviennent "on delete cascade" (ou "set null"), quelles qu'elles
--     soient dans ta base. Les règles "pas de suppression s'il reste des
--     heures, des dettes ou un emprunt" sont conservées et complétées.
--  3. NUMÉROS DE SUIVI au lieu des UUID : banques (B-000001),
--     commissariats (C-000001), et resoudre_code() pour traduire un
--     numéro / nom d'utilisateur / numéro de carte en identifiant interne.
--  4. BANQUES : liste_banques() renvoie le numéro de suivi et si tu es
--     propriétaire / gestionnaire (le bouton « Gérer » n'apparaît plus
--     pour les autres) ; le gouvernement peut octroyer le titre
--     gouvernemental (banque publique sans les 10 000 000 R$) ou déclarer
--     une banque publique.
--  5. CARTES refaites : conditions affichées, intérêt sur le prix net
--     seulement (jamais sur les taxes, ni fixe ni graduel), plafond de
--     dette, remboursement de la dette (l'intérêt va à la banque), NIP
--     enregistré optionnel, carte expirée détectée, liste des cartes
--     émises pour la banque.
--  6. CIB d'envoi d'entreprise enregistrables sur le compte.
--  7. PAIEMENTS : toute dépense d'un citoyen passe par une carte ou un CIB
--     d'envoi d'entreprise (carte enregistrée ou CIB enregistré sans
--     retaper le NIP). Seul le gouvernement paie directement avec ses
--     trésoreries (publique puis privée). Convertis : marché public,
--     permis, constats, versements Albatros, accès illimité aux virements
--     considérables, achat de capital à un tiers. Les anciennes versions
--     qui débitaient directement la trésorerie sont supprimées.
--  8. Taxe des Récoltes (4,95 %) : seulement pour une famille autochtone
--     enregistrée (résidence Tonawa, Bushard Bay, Pruxe, Milela,
--     Gibaltage), aussi sur les permis.
--  9. PREUVES (casier) : bucket Storage + droits de lecture des policiers.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------
-- 1) hash du NIP : chemin de recherche incluant "extensions"
-- ------------------------------------------------------------
create or replace function _hash_nip(p_nip text)
returns text language sql immutable set search_path = public, extensions as $$
  select encode(digest(convert_to(trim(p_nip), 'UTF8'), 'sha256'), 'hex');
$$;

-- ------------------------------------------------------------
-- 2) Suppression d'entreprise : normalisation de TOUTES les clés étrangères
-- ------------------------------------------------------------
do $$
declare r record; v_def text; v_regle text;
begin
  for r in
    select c.conrelid::regclass::text as tbl, c.conname, pg_get_constraintdef(c.oid) as def,
           c.confrelid::regclass::text as ref, c.conrelid, c.conkey
    from pg_constraint c
    where c.contype = 'f' and c.confdeltype in ('a', 'r')
      and c.confrelid in ('public.entreprises'::regclass, 'public.entreprises_membres'::regclass, 'public.entreprises_roles'::regclass)
  loop
    begin
      -- colonne facultative (ex. role_id) : on la vide ; sinon on supprime en cascade.
      v_regle := case when exists (
          select 1 from pg_attribute a
          where a.attrelid = r.conrelid and a.attnum = any (r.conkey) and not a.attnotnull
        ) then 'ON DELETE SET NULL' else 'ON DELETE CASCADE' end;
      v_def := regexp_replace(r.def, '\s+ON DELETE (NO ACTION|RESTRICT|CASCADE|SET NULL|SET DEFAULT)', '', 'gi');
      v_def := regexp_replace(v_def, '(REFERENCES\s+\S+\([^)]*\))', '\1 ' || v_regle);
      execute format('alter table %s drop constraint %I', r.tbl, r.conname);
      execute format('alter table %s add constraint %I %s', r.tbl, r.conname, v_def);
    exception when others then
      raise notice 'Clé étrangère % sur % non modifiée : %', r.conname, r.tbl, sqlerrm;
    end;
  end loop;
end $$;

-- Les historiques qui doivent survivre (déjà "set null" au patch 28) restent tels quels.
-- Règles de suppression : heures impayées, dettes, emprunts actifs.
create or replace function entreprise_supprimer(p_entreprise_id uuid, p_nom text, p_mdp text)
returns void language plpgsql security definer set search_path = public as $$
declare v_role text; v_e entreprises;
begin
  select role into v_role from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_role is distinct from 'pdg' then raise exception 'Réservé au PDG.'; end if;
  select * into v_e from entreprises where id = p_entreprise_id;
  if v_e.id is null then raise exception 'Entreprise introuvable.'; end if;
  if lower(trim(p_nom)) <> lower(v_e.nom) then raise exception 'Le nom de l''entreprise ne correspond pas.'; end if;
  if not _verifier_mdp(p_mdp) then raise exception 'Mot de passe incorrect.'; end if;

  if coalesce(v_e.dette_salariale_gouv, 0) > 0 or coalesce(v_e.dette_salariale_employes, 0) > 0 then
    raise exception 'Impossible : il reste des dettes salariales (gouvernement : % R$, employés : % R$).', v_e.dette_salariale_gouv, v_e.dette_salariale_employes;
  end if;
  if exists (select 1 from entreprises_membres_heures where entreprise_id = p_entreprise_id and heures > 0) then
    raise exception 'Impossible : il reste des heures accumulées à payer.';
  end if;
  if exists (select 1 from entreprises_emprunts_gouv where entreprise_id = p_entreprise_id and statut = 'acceptee' and coalesce(montant_du, 0) > 0) then
    raise exception 'Impossible : il reste un emprunt gouvernemental à rembourser.';
  end if;

  delete from entreprises where id = p_entreprise_id;
end; $$;
grant execute on function entreprise_supprimer(uuid, text, text) to authenticated;

-- ------------------------------------------------------------
-- 3) Numéros de suivi (banques, commissariats) + résolution
-- ------------------------------------------------------------
alter table banques_privees add column if not exists code text;
create sequence if not exists banques_code_seq;
update banques_privees set code = 'B-' || lpad(nextval('banques_code_seq')::text, 6, '0') where code is null;
create unique index if not exists banques_privees_code_uniq on banques_privees (code);
create or replace function _banque_code_defaut() returns trigger language plpgsql as $$
begin
  if new.code is null then new.code := 'B-' || lpad(nextval('banques_code_seq')::text, 6, '0'); end if;
  return new;
end; $$;
drop trigger if exists banques_code_defaut on banques_privees;
create trigger banques_code_defaut before insert on banques_privees for each row execute function _banque_code_defaut();

alter table comisseriats add column if not exists code text;
create sequence if not exists comisseriats_code_seq;
update comisseriats set code = 'C-' || lpad(nextval('comisseriats_code_seq')::text, 6, '0') where code is null;
create unique index if not exists comisseriats_code_uniq on comisseriats (code);
create or replace function _comisseriat_code_defaut() returns trigger language plpgsql as $$
begin
  if new.code is null then new.code := 'C-' || lpad(nextval('comisseriats_code_seq')::text, 6, '0'); end if;
  return new;
end; $$;
drop trigger if exists comisseriats_code_defaut on comisseriats;
create trigger comisseriats_code_defaut before insert on comisseriats for each row execute function _comisseriat_code_defaut();

create or replace function resoudre_code(p_type text, p_valeur text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid; t text := trim(coalesce(p_valeur, ''));
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if t = '' then raise exception 'Valeur requise.'; end if;
  if p_type = 'entreprise' then select id into v from entreprises where upper(code) = upper(t);
  elsif p_type = 'banque' then select id into v from banques_privees where upper(code) = upper(t);
  elsif p_type = 'commissariat' then select id into v from comisseriats where upper(code) = upper(t);
  elsif p_type = 'citoyen' then select id into v from citoyens where lower(username) = lower(ltrim(t, '@'));
  elsif p_type = 'carte' then select id into v from cartes where numero = regexp_replace(t, '\s', '', 'g');
  else raise exception 'Type inconnu.';
  end if;
  if v is null then raise exception 'Introuvable : %', t; end if;
  return v;
end; $$;
grant execute on function resoudre_code(text, text) to authenticated;

-- ------------------------------------------------------------
-- 4) Banques : liste enrichie, titre gouvernemental
-- ------------------------------------------------------------
create or replace function liste_banques()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'code', b.code, 'nom', b.nom, 'type', b.type, 'proprietaire', c.username, 'conseiller', cc.username,
    'publique', b.publique, 'degre_gouvernemental', b.degre_gouvernemental, 'description', b.description,
    'tresorerie', b.tresorerie,
    'moi_proprietaire', b.proprietaire_id = auth.uid(),
    'moi_gestionnaire', (b.proprietaire_id = auth.uid() or b.conseiller_id = auth.uid() or est_admin_actuel()),
    'total_fructification', case when b.type = 'fructification' then (select coalesce(sum(_valeur_compte_banque(bc.id)), 0) from banques_comptes bc where bc.banque_id = b.id) end
  ) order by b.nom), '[]'::jsonb)
  from banques_privees b join citoyens c on c.id = b.proprietaire_id left join citoyens cc on cc.id = b.conseiller_id
  where b.publique
    or b.proprietaire_id = auth.uid()
    or b.conseiller_id = auth.uid()
    or est_admin_actuel()
    or exists (select 1 from banques_comptes bc where bc.banque_id = b.id and bc.citoyen_id = auth.uid());
$$;
grant execute on function liste_banques() to authenticated, anon;

create or replace function gouv_octroyer_titre_banque(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update banques_privees set degre_gouvernemental = true where upper(code) = upper(trim(p_code));
  if not found then raise exception 'Banque introuvable (numéro de suivi : %).', p_code; end if;
end; $$;
grant execute on function gouv_octroyer_titre_banque(text) to authenticated;

create or replace function gouv_declarer_banque_publique(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  update banques_privees set degre_gouvernemental = true, publique = true where upper(code) = upper(trim(p_code));
  if not found then raise exception 'Banque introuvable (numéro de suivi : %).', p_code; end if;
end; $$;
grant execute on function gouv_declarer_banque_publique(text) to authenticated;

-- ------------------------------------------------------------
-- 5) CARTES
-- ------------------------------------------------------------
alter table cartes_config add column if not exists conditions text;
alter table cartes_config add column if not exists conditions_renouvellement text;
alter table cartes add column if not exists dette_taxes numeric not null default 0;
alter table cartes add column if not exists interets_dus numeric not null default 0;

drop function if exists banque_configurer_carte(uuid, text, int, numeric, numeric, numeric, boolean, numeric, numeric, text, numeric);
create or replace function banque_configurer_carte(
  p_banque_id uuid, p_type text, p_jours_expiration int, p_prix_premiere numeric,
  p_prix_renouvellement numeric, p_age_minimum numeric, p_achat_autorise boolean,
  p_taux_interet numeric default null, p_taux_periodique numeric default null,
  p_periode_taux text default null, p_montant_max numeric default null,
  p_conditions text default null, p_conditions_renouvellement text default null
) returns cartes_config language plpgsql security definer set search_path = public as $$
declare b banques_privees; v_row cartes_config;
begin
  if p_type not in ('tresorerie', 'emprunt') then raise exception 'Type de carte invalide.'; end if;
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null then raise exception 'Banque introuvable.'; end if;
  if b.proprietaire_id <> auth.uid() and not est_admin_actuel() then raise exception 'Réservé au propriétaire de la banque.'; end if;
  if not b.publique then raise exception 'Seules les banques publiques peuvent émettre des cartes.'; end if;
  if coalesce(p_jours_expiration, 0) <= 0 then raise exception 'La durée avant expiration doit être positive (en jours).'; end if;
  if coalesce(p_prix_premiere, 0) < 0 or coalesce(p_prix_renouvellement, 0) < 0 or coalesce(p_age_minimum, 0) < 0 then
    raise exception 'Prix et âge minimum ne peuvent pas être négatifs.';
  end if;
  if p_type = 'emprunt' then
    if coalesce(p_montant_max, 0) <= 0 then raise exception 'Le prêt maximum d''une carte d''emprunt doit être positif.'; end if;
    if p_taux_periodique is not null and p_taux_interet is not null then
      raise exception 'Choisissez soit un pourcentage fixe par dépense, soit un pourcentage graduel (jour/semaine/mois) — pas les deux.';
    end if;
    if p_taux_periodique is not null and p_periode_taux not in ('jour', 'semaine', 'mois') then
      raise exception 'Période de taux invalide (jour, semaine ou mois).';
    end if;
    if coalesce(p_taux_interet, 0) < 0 or coalesce(p_taux_periodique, 0) < 0 then raise exception 'Un taux ne peut pas être négatif.'; end if;
  end if;
  insert into cartes_config (
    banque_id, type, jours_expiration, prix_premiere, prix_renouvellement, age_minimum, achat_autorise,
    taux_interet, taux_periodique, periode_taux, montant_max, conditions, conditions_renouvellement
  ) values (
    p_banque_id, p_type, p_jours_expiration, coalesce(p_prix_premiere, 0), coalesce(p_prix_renouvellement, 0),
    coalesce(p_age_minimum, 0), coalesce(p_achat_autorise, true),
    case when p_type = 'emprunt' then p_taux_interet end, case when p_type = 'emprunt' then p_taux_periodique end,
    case when p_type = 'emprunt' then p_periode_taux end, case when p_type = 'emprunt' then p_montant_max end,
    nullif(trim(p_conditions), ''), nullif(trim(p_conditions_renouvellement), '')
  )
  on conflict (banque_id, type) do update set
    jours_expiration = excluded.jours_expiration, prix_premiere = excluded.prix_premiere,
    prix_renouvellement = excluded.prix_renouvellement, age_minimum = excluded.age_minimum,
    achat_autorise = excluded.achat_autorise, taux_interet = excluded.taux_interet,
    taux_periodique = excluded.taux_periodique, periode_taux = excluded.periode_taux,
    montant_max = excluded.montant_max, conditions = excluded.conditions,
    conditions_renouvellement = excluded.conditions_renouvellement, maj_le = now()
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function banque_configurer_carte(uuid, text, int, numeric, numeric, numeric, boolean, numeric, numeric, text, numeric, text, text) to authenticated;

create or replace function banque_cartes_config(p_banque_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', type, 'jours_expiration', jours_expiration,
    'prix_premiere', prix_premiere, 'prix_renouvellement', prix_renouvellement,
    'age_minimum', age_minimum, 'achat_autorise', achat_autorise,
    'taux_interet', taux_interet, 'taux_periodique', taux_periodique,
    'periode_taux', periode_taux, 'montant_max', montant_max,
    'conditions', conditions, 'conditions_renouvellement', conditions_renouvellement
  ) order by type), '[]'::jsonb)
  from cartes_config where banque_id = p_banque_id;
$$;
grant execute on function banque_cartes_config(uuid) to authenticated, anon;

-- Ma banque publique et ce qu'elle offre (pour la demande de carte).
create or replace function ma_banque_publique_cartes()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'banque_id', b.id, 'banque', b.nom, 'banque_code', b.code, 'cartes', banque_cartes_config(b.id)
  )), '[]'::jsonb)
  from banques_comptes bc join banques_privees b on b.id = bc.banque_id
  where bc.citoyen_id = auth.uid() and b.publique;
$$;
grant execute on function ma_banque_publique_cartes() to authenticated;

create or replace function citoyen_demander_carte(p_banque_id uuid, p_type text, p_nip text)
returns cartes language plpgsql security definer set search_path = public as $$
declare cfg cartes_config; v_naissance date; v_row cartes;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if p_nip is null or p_nip !~ '^[0-9]{6}$' then raise exception 'Le NIP doit comporter exactement 6 chiffres.'; end if;
  if not exists (select 1 from banques_privees where id = p_banque_id and publique) then raise exception 'Cette banque n''est pas publique.'; end if;
  if not exists (select 1 from banques_comptes where banque_id = p_banque_id and citoyen_id = auth.uid()) then
    raise exception 'Réservé aux membres (titulaires d''un compte) de cette banque publique.';
  end if;
  select * into cfg from cartes_config where banque_id = p_banque_id and type = p_type;
  if cfg.id is null or not cfg.achat_autorise then raise exception 'Cette banque n''offre pas (ou plus) ce type de carte.'; end if;
  select date_naissance into v_naissance from citoyens where id = auth.uid();
  if age_toutouien(v_naissance) < cfg.age_minimum then raise exception 'Âge minimum non atteint (% ans toutouïens requis).', cfg.age_minimum; end if;
  if exists (select 1 from cartes where banque_id = p_banque_id and citoyen_id = auth.uid() and type = p_type
             and statut = 'active' and date_expiration >= current_date) then
    raise exception 'Vous avez déjà une carte active de ce type à cette banque.';
  end if;
  if exists (select 1 from cartes where banque_id = p_banque_id and citoyen_id = auth.uid() and type = p_type
             and statut = 'active' and date_expiration < current_date) then
    raise exception 'Vous avez une carte de ce type expirée : renouvelez-la (frais de renouvellement) au lieu d''en demander une nouvelle.';
  end if;
  if cfg.prix_premiere > 0 then
    if _ma_tresorerie() < cfg.prix_premiere then raise exception 'Trésorerie insuffisante pour les frais d''émission (% R$).', cfg.prix_premiere; end if;
    perform _debiter_ma_tresorerie(cfg.prix_premiere);
    update banques_privees set tresorerie = tresorerie + cfg.prix_premiere where id = p_banque_id;
  end if;
  insert into cartes (
    banque_id, citoyen_id, type, numero, nip_hash, date_expiration,
    taux_interet, taux_periodique, periode_taux, montant_max
  ) values (
    p_banque_id, auth.uid(), p_type, _generer_numero_carte(), _hash_nip(p_nip),
    current_date + cfg.jours_expiration,
    case when p_type = 'emprunt' then cfg.taux_interet end,
    case when p_type = 'emprunt' then cfg.taux_periodique end,
    case when p_type = 'emprunt' then cfg.periode_taux end,
    case when p_type = 'emprunt' then coalesce(cfg.montant_max, 0) end
  ) returning * into v_row;
  return v_row;
end; $$;
grant execute on function citoyen_demander_carte(uuid, text, text) to authenticated;

create or replace function citoyen_renouveler_carte(p_carte_id uuid)
returns cartes language plpgsql security definer set search_path = public as $$
declare c cartes; cfg cartes_config; v_row cartes;
begin
  select * into c from cartes where id = p_carte_id and citoyen_id = auth.uid() for update;
  if c.id is null then raise exception 'Carte introuvable.'; end if;
  if c.statut = 'bloquee' then raise exception 'Carte bloquée.'; end if;
  if c.date_expiration >= current_date then raise exception 'Cette carte n''est pas expirée (expire le %).', c.date_expiration; end if;
  select * into cfg from cartes_config where banque_id = c.banque_id and type = c.type;
  if cfg.id is null then raise exception 'Cette banque n''offre plus ce type de carte.'; end if;
  if cfg.prix_renouvellement > 0 then
    if _ma_tresorerie() < cfg.prix_renouvellement then raise exception 'Trésorerie insuffisante pour le renouvellement (% R$).', cfg.prix_renouvellement; end if;
    perform _debiter_ma_tresorerie(cfg.prix_renouvellement);
    update banques_privees set tresorerie = tresorerie + cfg.prix_renouvellement where id = c.banque_id;
  end if;
  update cartes set statut = 'active', date_expiration = current_date + cfg.jours_expiration
  where id = c.id returning * into v_row;
  return v_row;
end; $$;
grant execute on function citoyen_renouveler_carte(uuid) to authenticated;

-- Cartes émises par ma banque (pour proposer un changement de conditions).
create or replace function banque_cartes_emises(p_banque_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b banques_privees;
begin
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null then raise exception 'Banque introuvable.'; end if;
  if b.proprietaire_id <> auth.uid() and not est_admin_actuel() then raise exception 'Réservé au propriétaire de la banque.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'numero', c.numero, 'type', c.type, 'titulaire', ct.username,
      'statut', case when c.statut = 'active' and c.date_expiration < current_date then 'expiree' else c.statut end,
      'date_expiration', c.date_expiration, 'dette_actuelle', c.dette_actuelle, 'montant_max', c.montant_max,
      'taux_interet', c.taux_interet, 'taux_periodique', c.taux_periodique, 'periode_taux', c.periode_taux
    ) order by c.numero)
    from cartes c join citoyens ct on ct.id = c.citoyen_id where c.banque_id = p_banque_id
  ), '[]'::jsonb);
end; $$;
grant execute on function banque_cartes_emises(uuid) to authenticated;

-- Mes cartes (les miennes + celles associées à mon compte), sans doublon.
create or replace function mes_cartes()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by proprietaire desc, numero), '[]'::jsonb)
  from (
    select true as proprietaire, c.id, c.numero, c.type,
      case when c.statut = 'active' and c.date_expiration < current_date then 'expiree' else c.statut end as statut,
      c.date_expiration, c.dette_actuelle, c.montant_max, c.taux_interet, c.taux_periodique, c.periode_taux,
      greatest(0, coalesce(c.montant_max, 0) - c.dette_actuelle) as disponible,
      b.nom as banque, b.code as banque_code, ct.username as titulaire,
      ca.nip as nip_sauvegarde, (ca.id is not null) as sauvegardee
    from cartes c join banques_privees b on b.id = c.banque_id join citoyens ct on ct.id = c.citoyen_id
    left join cartes_associees ca on ca.carte_id = c.id and ca.citoyen_id = auth.uid()
    where c.citoyen_id = auth.uid()
    union all
    select false, c.id, c.numero, c.type,
      case when c.statut = 'active' and c.date_expiration < current_date then 'expiree' else c.statut end,
      c.date_expiration, c.dette_actuelle, c.montant_max, c.taux_interet, c.taux_periodique, c.periode_taux,
      greatest(0, coalesce(c.montant_max, 0) - c.dette_actuelle),
      b.nom, b.code, ct.username, ca.nip, true
    from cartes_associees ca join cartes c on c.id = ca.carte_id
    join banques_privees b on b.id = c.banque_id join citoyens ct on ct.id = c.citoyen_id
    where ca.citoyen_id = auth.uid() and c.citoyen_id <> auth.uid()
  ) x;
$$;
grant execute on function mes_cartes() to authenticated;

-- Intérêt graduel : appliqué seulement à la part "prix net" de la dette (jamais aux taxes).
create or replace function _appliquer_interet_periodique_carte(p_carte_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c cartes; v_unites int; v_intervalle interval; v_base numeric; v_ajout numeric;
begin
  select * into c from cartes where id = p_carte_id for update;
  if c.id is null or c.type <> 'emprunt' or c.taux_periodique is null
     or c.taux_periodique <= 0 or c.dette_actuelle <= 0 then return; end if;
  v_intervalle := case c.periode_taux when 'jour' then interval '1 day' when 'semaine' then interval '1 week' else interval '1 month' end;
  v_unites := floor(extract(epoch from (now() - coalesce(c.derniere_application_periodique, c.cree_le))) / extract(epoch from v_intervalle));
  if v_unites <= 0 then return; end if;
  v_base := greatest(0, c.dette_actuelle - c.dette_taxes);
  v_ajout := round(v_base * (power(1 + c.taux_periodique / 100.0, v_unites) - 1), 2);
  update cartes set dette_actuelle = dette_actuelle + v_ajout, interets_dus = interets_dus + v_ajout,
      derniere_application_periodique = coalesce(c.derniere_application_periodique, c.cree_le) + (v_unites * v_intervalle)
  where id = c.id;
end; $$;

-- Débit d'une carte. NIP vide = NIP enregistré sur mon compte.
create or replace function _debiter_carte(
  p_numero text, p_nip text, p_montant_net numeric, p_montant_taxes numeric
) returns void language plpgsql security definer set search_path = public as $$
declare c cartes; v_nip text; v_interet numeric := 0; v_ajout numeric;
begin
  if p_montant_net < 0 or p_montant_taxes < 0 then raise exception 'Montant invalide.'; end if;
  select * into c from cartes where numero = regexp_replace(coalesce(p_numero, ''), '\s', '', 'g') for update;
  if c.id is null then raise exception 'Carte introuvable.'; end if;
  if c.citoyen_id <> auth.uid() and not exists (
    select 1 from cartes_associees ca where ca.carte_id = c.id and ca.citoyen_id = auth.uid()
  ) then raise exception 'Cette carte n''est pas associée à votre compte.'; end if;
  if c.statut = 'bloquee' then raise exception 'Carte bloquée.'; end if;
  if c.date_expiration < current_date or c.statut = 'expiree' then raise exception 'Carte expirée : renouvelez-la.'; end if;
  if c.statut <> 'active' then raise exception 'Carte inactive.'; end if;

  v_nip := nullif(trim(coalesce(p_nip, '')), '');
  if v_nip is null then
    select nip into v_nip from cartes_associees where carte_id = c.id and citoyen_id = auth.uid();
    if v_nip is null then raise exception 'NIP de la carte requis.'; end if;
  end if;
  if c.nip_hash <> _hash_nip(v_nip) then raise exception 'NIP incorrect.'; end if;

  if c.type = 'tresorerie' then
    if (select tresorerie from citoyens where id = c.citoyen_id) < (p_montant_net + p_montant_taxes) then
      raise exception 'Trésorerie insuffisante sur cette carte (la carte dépense la trésorerie de son titulaire).';
    end if;
    update citoyens set tresorerie = tresorerie - (p_montant_net + p_montant_taxes) where id = c.citoyen_id;
  else
    perform _appliquer_interet_periodique_carte(c.id);
    select * into c from cartes where id = c.id;
    if c.dette_actuelle >= coalesce(c.montant_max, 0) then
      raise exception 'Plafond d''emprunt atteint (% R$) : remboursez la dette de la carte avant de dépenser.', c.montant_max;
    end if;
    -- Intérêt fixe : seulement sur le prix NET (jamais sur les taxes).
    if c.taux_interet is not null and c.taux_interet > 0 then
      v_interet := round(p_montant_net * c.taux_interet / 100.0, 2);
    end if;
    v_ajout := p_montant_net + v_interet + p_montant_taxes;
    if c.dette_actuelle + v_ajout > c.montant_max then
      raise exception 'Cet achat dépasse le prêt maximum de la carte (disponible : % R$, achat avec intérêt et taxes : % R$).',
        greatest(0, c.montant_max - c.dette_actuelle), v_ajout;
    end if;
    update cartes set dette_actuelle = dette_actuelle + v_ajout, dette_taxes = dette_taxes + p_montant_taxes,
      interets_dus = interets_dus + v_interet where id = c.id;
  end if;
end; $$;
grant execute on function _debiter_carte(text, text, numeric, numeric) to authenticated;

-- Remboursement de la dette d'une carte d'emprunt (l'intérêt payé va à la banque).
create or replace function citoyen_rembourser_carte(p_numero text, p_montant numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c cartes; v_paye numeric; v_facteur numeric; v_part_interet numeric; v_part_taxes numeric;
begin
  if p_montant is null or p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into c from cartes where numero = regexp_replace(coalesce(p_numero, ''), '\s', '', 'g') for update;
  if c.id is null then raise exception 'Carte introuvable.'; end if;
  if c.type <> 'emprunt' then raise exception 'Seule une carte d''emprunt a une dette.'; end if;
  if c.citoyen_id <> auth.uid() and not exists (select 1 from cartes_associees ca where ca.carte_id = c.id and ca.citoyen_id = auth.uid()) then
    raise exception 'Cette carte n''est pas associée à votre compte.';
  end if;
  perform _appliquer_interet_periodique_carte(c.id);
  select * into c from cartes where id = c.id;
  if c.dette_actuelle <= 0 then raise exception 'Cette carte n''a aucune dette.'; end if;
  v_paye := least(round(p_montant, 2), c.dette_actuelle);
  if _ma_tresorerie() < v_paye then raise exception 'Trésorerie insuffisante (% R$ requis).', v_paye; end if;
  perform _debiter_ma_tresorerie(v_paye);
  v_facteur := v_paye / c.dette_actuelle;
  v_part_interet := round(c.interets_dus * v_facteur, 2);
  v_part_taxes := round(c.dette_taxes * v_facteur, 2);
  update cartes set dette_actuelle = dette_actuelle - v_paye,
    interets_dus = greatest(0, interets_dus - v_part_interet),
    dette_taxes = greatest(0, dette_taxes - v_part_taxes)
  where id = c.id;
  update banques_privees set tresorerie = tresorerie + v_part_interet where id = c.banque_id;
  return jsonb_build_object('paye', v_paye, 'interets_verses_banque', v_part_interet,
    'dette_restante', (select dette_actuelle from cartes where id = c.id));
end; $$;
grant execute on function citoyen_rembourser_carte(text, numeric) to authenticated;

-- ------------------------------------------------------------
-- 6) CIB d'envoi d'entreprise enregistrés sur le compte
-- ------------------------------------------------------------
create table if not exists cib_enregistres (
  id uuid primary key default gen_random_uuid(),
  citoyen_id uuid not null references auth.users(id) on delete cascade,
  cib text not null,
  libelle text,
  cree_le timestamptz not null default now(),
  unique (citoyen_id, cib)
);
alter table cib_enregistres enable row level security;
drop policy if exists "Voir ses CIB enregistrés" on cib_enregistres;
create policy "Voir ses CIB enregistrés" on cib_enregistres for select using (citoyen_id = auth.uid());

create or replace function citoyen_enregistrer_cib(p_cib text, p_libelle text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if not exists (select 1 from entreprises_cib where cib_envoi = trim(p_cib)) then raise exception 'CIB d''envoi introuvable.'; end if;
  insert into cib_enregistres (citoyen_id, cib, libelle) values (auth.uid(), trim(p_cib), nullif(trim(p_libelle), ''))
  on conflict (citoyen_id, cib) do update set libelle = excluded.libelle;
end; $$;
grant execute on function citoyen_enregistrer_cib(text, text) to authenticated;

create or replace function citoyen_retirer_cib(p_cib text)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from cib_enregistres where citoyen_id = auth.uid() and cib = trim(p_cib);
end; $$;
grant execute on function citoyen_retirer_cib(text) to authenticated;

create or replace function mes_cib_enregistres()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'cib', ce.cib, 'libelle', ce.libelle, 'entreprise', e.nom, 'entreprise_code', e.code
  ) order by ce.cree_le), '[]'::jsonb)
  from cib_enregistres ce
  left join entreprises_cib ec on ec.cib_envoi = ce.cib
  left join entreprises e on e.id = ec.entreprise_id
  where ce.citoyen_id = auth.uid();
$$;
grant execute on function mes_cib_enregistres() to authenticated;

-- ------------------------------------------------------------
-- 7) Moyen de paiement unique pour tous les achats
--    'carte' | 'cib' (CIB d'envoi d'entreprise) | 'gouvernement' (admin seulement)
-- ------------------------------------------------------------
create or replace function _debiter_moyen_paiement(
  p_moyen text, p_carte_numero text, p_carte_nip text, p_cib text,
  p_montant_net numeric, p_montant_taxes numeric
) returns void language plpgsql security definer set search_path = public as $$
declare v_ent_id uuid; v_total numeric := coalesce(p_montant_net, 0) + coalesce(p_montant_taxes, 0);
        v_pub numeric; v_priv numeric; v_pris_pub numeric;
begin
  if v_total < 0 then raise exception 'Montant invalide.'; end if;
  if p_moyen = 'carte' then
    if nullif(trim(coalesce(p_carte_numero, '')), '') is null then raise exception 'Numéro de carte requis.'; end if;
    perform _debiter_carte(p_carte_numero, p_carte_nip, p_montant_net, p_montant_taxes);
  elsif p_moyen = 'cib' then
    if nullif(trim(coalesce(p_cib, '')), '') is null then raise exception 'CIB d''envoi requis.'; end if;
    select entreprise_id into v_ent_id from entreprises_cib where cib_envoi = trim(p_cib);
    if v_ent_id is null then raise exception 'CIB d''envoi introuvable.'; end if;
    if not exists (select 1 from entreprises where id = v_ent_id and statut = 'acceptee') then raise exception 'Entreprise inactive.'; end if;
    if (select tresorerie from entreprises where id = v_ent_id) < v_total then
      raise exception 'Trésorerie de l''entreprise insuffisante.';
    end if;
    update entreprises set tresorerie = tresorerie - v_total where id = v_ent_id;
  elsif p_moyen = 'gouvernement' then
    if not est_admin_actuel() then raise exception 'Seul le gouvernement peut payer directement avec ses trésoreries : utilisez une carte ou un CIB d''envoi.'; end if;
    select solde, solde_prive into v_pub, v_priv from tresor_public where id = 1 for update;
    if coalesce(v_pub, 0) + coalesce(v_priv, 0) < v_total then raise exception 'Trésoreries du gouvernement insuffisantes.'; end if;
    v_pris_pub := least(coalesce(v_pub, 0), v_total);
    update tresor_public set solde = solde - v_pris_pub, solde_prive = solde_prive - (v_total - v_pris_pub) where id = 1;
  else
    raise exception 'Moyen de paiement invalide (carte, cib ou gouvernement).';
  end if;
end; $$;
grant execute on function _debiter_moyen_paiement(text, text, text, text, numeric, numeric) to authenticated;

-- Taxe des Récoltes : familles autochtones enregistrées, résidant dans les 5 provinces.
create or replace function _taux_tr_citoyen(p_citoyen uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select case when c.autochtone and _province_courte(c.province_residence) in ('Tonawa', 'Bushard Bay', 'Pruxe', 'Milela', 'Gibaltage')
              then 0.0495 else 0 end
  from citoyens c where c.id = p_citoyen;
$$;

-- ------------------------------------------------------------
-- 8) Achats convertis
-- ------------------------------------------------------------
drop function if exists acheter_permis(text);
drop function if exists acheter_permis(text, text);
create or replace function acheter_permis(
  p_type text, p_moyen text, p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns permis_citoyens language plpgsql security definer set search_path = public as $$
declare v_base numeric; v_taxe numeric; v_tr numeric; v_expire date; v_row permis_citoyens;
begin
  if p_type not in ('peche', 'chasse', 'travail') then raise exception 'Type de permis invalide.'; end if;
  if exists (select 1 from permis_citoyens where citoyen_id = auth.uid() and type = p_type and (expire_le is null or expire_le >= current_date)) then
    raise exception 'Vous détenez déjà un permis de ce type, encore valide.';
  end if;
  v_base := case p_type when 'peche' then 65.59 when 'chasse' then 178.59 else 0 end;
  v_taxe := round(v_base * 0.15, 2);
  v_tr := round(v_base * _taux_tr_citoyen(auth.uid()), 2);
  v_expire := case when p_type = 'travail' then null else (current_date + interval '1 year')::date end;
  if v_base > 0 then
    -- Intérêt éventuel seulement sur le prix net ; taxes (15 % + TR) sans intérêt.
    perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_base, v_taxe + v_tr);
    update tresor_public set solde = solde + v_base + v_taxe, solde_prive = solde_prive + v_tr where id = 1;
  end if;
  insert into permis_citoyens (citoyen_id, type, prix_paye, expire_le)
  values (auth.uid(), p_type, v_base + v_taxe + v_tr, v_expire) returning * into v_row;
  return v_row;
end; $$;
grant execute on function acheter_permis(text, text, text, text, text) to authenticated;

drop function if exists payer_constat(uuid);
create or replace function payer_constat(
  p_id uuid, p_moyen text, p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns constats_infraction language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_taxes numeric;
begin
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat.id is null then raise exception 'Constat introuvable.'; end if;
  if v_constat.paye then raise exception 'Ce constat a déjà été payé.'; end if;
  if v_constat.annule then raise exception 'Ce constat a été annulé (contestation acceptée).'; end if;
  if exists (select 1 from constats_contestations where constat_id = p_id and statut = 'en_attente') then
    raise exception 'Une contestation est en attente pour ce constat : paiement bloqué jusqu''à la décision.';
  end if;
  v_taxes := least(coalesce(v_constat.prix_taxes, 0), v_constat.prix_total);
  perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_constat.prix_total - v_taxes, v_taxes);
  update tresor_public set solde_prive = solde_prive + v_constat.prix_total where id = 1;
  update constats_infraction set paye = true, paye_le = now() where id = p_id returning * into v_constat;
  insert into paiements_historique (citoyen_id, type, montant, reference_id) values (auth.uid(), 'constat', v_constat.prix_total, p_id);
  return v_constat;
end; $$;
grant execute on function payer_constat(uuid, text, text, text, text) to authenticated;

drop function if exists marche_acheter(uuid, int, text);
create or replace function marche_acheter(
  p_annonce_id uuid, p_quantite int, p_mode_paiement text, p_moyen text,
  p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns marche_achats language plpgsql security definer set search_path = public as $$
declare
  a marche_annonces; v_cat marche_categories; v_montant_objet numeric;
  v_taxe_tp numeric; v_taxe_tap numeric; v_taxe_tan numeric; v_taxe_tr numeric;
  v_montant_taxes numeric; v_montant_objet_majore numeric; v_total_du_maintenant numeric;
  v_row marche_achats; v_tan numeric;
begin
  if p_mode_paiement not in ('comptant', 'albatros') then raise exception 'Mode de paiement invalide.'; end if;
  select * into a from marche_annonces where id = p_annonce_id and statut = 'active' for update;
  if a.id is null then raise exception 'Annonce introuvable ou retirée.'; end if;
  if p_quantite <= 0 or p_quantite > a.quantite_disponible then
    raise exception 'Quantité indisponible (reste : %).', a.quantite_disponible;
  end if;
  if a.vendeur_id = auth.uid() then raise exception 'Impossible d''acheter sa propre annonce.'; end if;
  if p_mode_paiement = 'albatros' and not a.albatros then
    raise exception 'Le paiement Albatros n''est pas proposé pour cette annonce.';
  end if;

  select * into v_cat from marche_categories where code = a.categorie_tp;
  v_montant_objet := a.prix_unitaire * p_quantite;
  v_taxe_tp := round(v_montant_objet * v_cat.taux / 100.0, 2);
  if a.categorie_tp = 'TP-TAE' and a.importe then
    v_taxe_tp := v_taxe_tp + round(v_montant_objet * 0.10, 2);
  end if;

  if v_cat.taux > 0 then
    v_taxe_tap := 0; v_taxe_tan := 0;
  else
    select taux_tap into v_taxe_tap from provinces_taxation where province = a.province_vente;
    v_taxe_tap := round(v_montant_objet * coalesce(v_taxe_tap, 0) / 100.0, 2);
    v_tan := taux_tan_province(a.province_vente);
    v_taxe_tan := round(v_montant_objet * coalesce(v_tan, 0) / 100.0, 2);
  end if;

  v_taxe_tr := round(v_montant_objet * _taux_tr_citoyen(auth.uid()), 2);
  v_montant_taxes := v_taxe_tp + v_taxe_tap + v_taxe_tan + v_taxe_tr;

  if p_mode_paiement = 'albatros' then
    v_montant_objet_majore := round(v_montant_objet * 1.20, 2);
    v_total_du_maintenant := v_montant_taxes;
    perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, 0, v_total_du_maintenant);
    update tresor_public set solde = solde + v_taxe_tp + v_taxe_tap + v_taxe_tan, solde_prive = solde_prive + v_taxe_tr where id = 1;

    insert into marche_achats (
      annonce_id, acheteur_id, vendeur_id, titre, quantite, prix_unitaire,
      montant_objet, taxe_tp, taxe_tap, taxe_tan, taxe_tr, montant_total, mode_paiement
    ) values (
      p_annonce_id, auth.uid(), a.vendeur_id, a.titre, p_quantite, a.prix_unitaire,
      v_montant_objet, v_taxe_tp, v_taxe_tap, v_taxe_tan, v_taxe_tr,
      v_montant_objet_majore + v_montant_taxes, 'albatros'
    ) returning * into v_row;

    insert into albatros_factures (achat_id, mois_total, montant_mensuel)
    values (v_row.id, a.albatros_mois, round(v_montant_objet_majore / a.albatros_mois, 2));
  else
    v_total_du_maintenant := v_montant_objet + v_montant_taxes;
    perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_montant_objet, v_montant_taxes);
    if a.entreprise_vendeuse_id is not null then
      update entreprises set tresorerie = tresorerie + v_montant_objet where id = a.entreprise_vendeuse_id;
    else
      update citoyens set tresorerie = tresorerie + v_montant_objet where id = a.vendeur_id;
    end if;
    update tresor_public set solde = solde + v_taxe_tp + v_taxe_tap + v_taxe_tan, solde_prive = solde_prive + v_taxe_tr where id = 1;

    insert into marche_achats (
      annonce_id, acheteur_id, vendeur_id, titre, quantite, prix_unitaire,
      montant_objet, taxe_tp, taxe_tap, taxe_tan, taxe_tr, montant_total, mode_paiement
    ) values (
      p_annonce_id, auth.uid(), a.vendeur_id, a.titre, p_quantite, a.prix_unitaire,
      v_montant_objet, v_taxe_tp, v_taxe_tap, v_taxe_tan, v_taxe_tr,
      v_total_du_maintenant, 'comptant'
    ) returning * into v_row;
  end if;

  update marche_annonces set quantite_disponible = quantite_disponible - p_quantite where id = p_annonce_id;
  return v_row;
end; $$;
grant execute on function marche_acheter(uuid, int, text, text, text, text, text) to authenticated;

drop function if exists payer_virements_illimites();
create or replace function payer_virements_illimites(
  p_moyen text, p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, 50000000, 0);
  update citoyens set virements_illimites_jusqua = now() + interval '60 days' where id = auth.uid();
  update tresor_public set solde_prive = solde_prive + 50000000 where id = 1;
  perform gouv_distribuer_argent_attendu();
end; $$;
grant execute on function payer_virements_illimites(text, text, text, text) to authenticated;

drop function if exists payer_versement_albatros(uuid);
create or replace function payer_versement_albatros(
  p_facture_id uuid, p_moyen text, p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns void language plpgsql security definer set search_path = public as $$
declare f albatros_factures; m marche_achats; v_part_gouv numeric; v_part_vendeur numeric;
begin
  select * into f from albatros_factures where id = p_facture_id and statut = 'active' for update;
  if f.id is null then raise exception 'Facture introuvable ou déjà complétée.'; end if;
  select * into m from marche_achats where id = f.achat_id;
  if m.acheteur_id <> auth.uid() then raise exception 'Réservé à l''acheteur.'; end if;
  if f.prochain_du > now() then raise exception 'Le prochain versement n''est pas encore dû (le %).', f.prochain_du; end if;

  perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, f.montant_mensuel, 0);

  v_part_gouv := round(f.montant_mensuel * 0.176, 2);
  v_part_vendeur := f.montant_mensuel - v_part_gouv;
  update tresor_public set solde = solde + v_part_gouv where id = 1;
  update citoyens set tresorerie = tresorerie + v_part_vendeur where id = m.vendeur_id;

  update albatros_factures set mois_payes = mois_payes + 1, prochain_du = prochain_du + interval '1 month',
    statut = case when mois_payes + 1 >= mois_total then 'complete' else 'active' end
  where id = p_facture_id;
end; $$;
grant execute on function payer_versement_albatros(uuid, text, text, text, text) to authenticated;

drop function if exists capital_acheter_tiers(uuid, numeric);
create or replace function capital_acheter_tiers(
  p_offre_id uuid, p_pourcentage numeric, p_moyen text,
  p_carte_numero text default null, p_carte_nip text default null, p_cib text default null
) returns void language plpgsql security definer set search_path = public as $$
declare o capital_offres_tiers; v_cout numeric; v_detenu_avant numeric;
  v_solde_avant numeric; v_all_time_avant numeric; v_part numeric; v_solde_transfere numeric; v_all_time_transfere numeric;
begin
  select * into o from capital_offres_tiers where id = p_offre_id for update;
  if o.id is null then raise exception 'Offre introuvable.'; end if;
  if o.vendeur_id = auth.uid() then raise exception 'Vous ne pouvez pas acheter votre propre offre.'; end if;
  if p_pourcentage <= 0 or round(p_pourcentage * 10) <> p_pourcentage * 10 then raise exception 'Le pourcentage doit être un multiple de 0,1 %%.'; end if;
  if p_pourcentage > o.pourcentage then raise exception 'Il ne reste que % %% en vente.', o.pourcentage; end if;

  v_cout := (p_pourcentage / 0.1) * o.prix_par_dixieme;

  select pourcentage, solde, solde_all_time into v_detenu_avant, v_solde_avant, v_all_time_avant
    from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id for update;
  v_part := case when coalesce(v_detenu_avant, 0) > 0 then p_pourcentage / v_detenu_avant else 0 end;
  v_solde_transfere := round(coalesce(v_solde_avant, 0) * v_part, 2);
  v_all_time_transfere := round(coalesce(v_all_time_avant, 0) * v_part, 2);

  perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_cout, 0);
  update citoyens set tresorerie = tresorerie + v_cout where id = o.vendeur_id;

  update entreprises_capital_detenteurs set
    pourcentage = pourcentage - p_pourcentage, solde = solde - v_solde_transfere, solde_all_time = solde_all_time - v_all_time_transfere
    where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id;
  delete from entreprises_capital_detenteurs where entreprise_id = o.entreprise_id and citoyen_id = o.vendeur_id and pourcentage <= 0;

  insert into entreprises_capital_detenteurs (entreprise_id, citoyen_id, pourcentage, solde, solde_all_time)
    values (o.entreprise_id, auth.uid(), p_pourcentage, v_solde_transfere, v_all_time_transfere)
  on conflict (entreprise_id, citoyen_id) do update set
    pourcentage = entreprises_capital_detenteurs.pourcentage + p_pourcentage,
    solde = entreprises_capital_detenteurs.solde + v_solde_transfere,
    solde_all_time = entreprises_capital_detenteurs.solde_all_time + v_all_time_transfere;

  if p_pourcentage >= o.pourcentage then delete from capital_offres_tiers where id = o.id;
  else update capital_offres_tiers set pourcentage = pourcentage - p_pourcentage where id = o.id; end if;
  perform _entreprise_maj_pdg_capital(o.entreprise_id);
end; $$;
grant execute on function capital_acheter_tiers(uuid, numeric, text, text, text, text) to authenticated;

-- ------------------------------------------------------------
-- 9) Preuves de casier : bucket + droits de lecture des policiers
-- ------------------------------------------------------------
do $$
begin
  insert into storage.buckets (id, name, public) values ('documents-citoyens', 'documents-citoyens', false)
  on conflict (id) do nothing;

  drop policy if exists "Déposer ses propres documents" on storage.objects;
  create policy "Déposer ses propres documents" on storage.objects for insert to authenticated
    with check (bucket_id = 'documents-citoyens' and (storage.foldername(name))[1] = auth.uid()::text);

  drop policy if exists "Voir ses propres documents ou tout si admin" on storage.objects;
  create policy "Voir ses propres documents ou tout si admin" on storage.objects for select to authenticated
    using (bucket_id = 'documents-citoyens' and ((storage.foldername(name))[1] = auth.uid()::text or est_admin_actuel()));

  drop policy if exists "Policiers lisent les preuves de casier" on storage.objects;
  create policy "Policiers lisent les preuves de casier" on storage.objects for select to authenticated
    using (bucket_id = 'documents-citoyens'
      and exists (select 1 from comisseriats_membres m where m.citoyen_id = auth.uid() and m.statut = 'actif')
      and exists (select 1 from casier_judiciaire cj where cj.preuves @> to_jsonb(storage.objects.name)));
exception when others then
  raise notice 'Stockage : politiques non modifiées (%). À créer dans Storage > Policies si les envois de fichiers échouent.', sqlerrm;
end $$;

notify pgrst, 'reload schema';
