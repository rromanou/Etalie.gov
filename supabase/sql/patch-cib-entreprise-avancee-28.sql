-- ============================================================
-- patch-cib-entreprise-avancee-28.sql
-- À exécuter après patch-cib-entreprise-avancee-27.sql (même si ce dernier
-- a échoué ou a été annulé). Additif et rejouable.
--
-- POURQUOI : le patch 27 s'arrêtait à son instruction 6 avec
--   "function gouv_creer_comisseriat(text, text, text) does not exist"
-- (le grant visait 3 paramètres alors que la fonction en a 4). Comme un
-- script SQL est annulé en bloc à la première erreur, RIEN du patch 27
-- n'était appliqué : ni les 21 grades, ni le correctif qui rend possible
-- la suppression d'une entreprise (violation de clé étrangère).
-- De plus, sa version de comisseriat_promouvoir changeait le type de
-- retour (void -> comisseriats_membres, erreur "cannot change return
-- type of existing function") et supprimait la règle de rang du patch 24.
--
-- CE PATCH :
--  1. Reprend tout le patch 27, corrigé (grant à 4 paramètres).
--  2. comisseriat_promouvoir : retour void (comme avant), règle de rang du
--     patch 24 conservée, bornes élargies à 1-21.
--  3. Recharge le cache de schéma de l'API (PostgREST).
-- ============================================================

-- 1) Contrainte de grade : 1-15 -> 1-21.
alter table comisseriats_membres drop constraint if exists comisseriats_membres_grade_check;
alter table comisseriats_membres add constraint comisseriats_membres_grade_check check (grade between 1 and 21);

-- 2) Les 21 noms de grade officiels (Impérats), ordre croissant.
create or replace function _grades_police()
returns text[] language sql immutable as $$
  select array['Recrues','Milites','Caporal','Caporal-À-Vous','Haut-Caporal','Adsistan','Capitaine',
    'Capitaine-de-base','Grand-Capitaine-Assistant','Grand-Capitaine','Sous-Major-Assistant','Major',
    'Lieutenant','Général','Lieutenant-Général','Noble-Major','Lieutenant-Général-Major','Sous-Majest',
    'Majesté','Majest','Impérialis'];
$$;

create or replace function _nom_grade(p_grade int)
returns text language sql immutable as $$
  select (_grades_police())[greatest(1, least(21, p_grade))];
$$;

-- 3) Un directeur de commissariat démarre au grade maximal (21).
--    CORRECTIF : le grant porte sur la vraie signature (4 paramètres).
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
  perform _embaucher_policier(v_row.id, v_directeur, 21, 3);
  return v_row;
end; $$;
grant execute on function gouv_creer_comisseriat(text, text, text, text) to authenticated;

-- 4) Promotion : bornes 1-21, retour void, règle de rang du patch 24 conservée
--    (un policier ne promeut que sous son propre rang ; directeur, superviseur
--    royal et administrateur : autorité totale).
drop function if exists comisseriat_promouvoir(uuid, int, int);
create function comisseriat_promouvoir(p_membre_id uuid, p_grade int, p_sous_grade int)
returns void language plpgsql security definer set search_path = public as $$
declare m comisseriats_membres; v_mon_rang int; v_nouveau_rang int;
begin
  if p_grade not between 1 and 21 or p_sous_grade not between 1 and 3 then raise exception 'Grade ou sous-grade invalide.'; end if;
  select * into m from comisseriats_membres where id = p_membre_id and statut = 'actif';
  if m.id is null then raise exception 'Membre introuvable ou inactif.'; end if;
  v_nouveau_rang := _rang_total(p_grade, p_sous_grade);
  if _est_directeur(m.comisseriat_id) or _est_superviseur_royal() or est_admin_actuel() then
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

-- ============================================================
-- 5) Suppression d'une entreprise impossible (violation de clé étrangère
--    sur des tables ajoutées après le patch 15) : "on delete cascade" pour
--    les données sans objet sans l'entreprise, "on delete set null" pour les
--    historiques qui doivent survivre (annonces, achats, virements).
--    (Reprise du patch 27, qui n'avait jamais pu s'exécuter.)
-- ============================================================
alter table bureau_poste_affiliations drop constraint if exists bureau_poste_affiliations_entreprise_cible_id_fkey;
alter table bureau_poste_affiliations add constraint bureau_poste_affiliations_entreprise_cible_id_fkey
  foreign key (entreprise_cible_id) references entreprises(id) on delete cascade;

alter table marche_achats drop constraint if exists marche_achats_bureau_poste_id_fkey;
alter table marche_achats add constraint marche_achats_bureau_poste_id_fkey
  foreign key (bureau_poste_id) references entreprises(id) on delete set null;

alter table marche_annonces drop constraint if exists marche_annonces_entreprise_vendeuse_id_fkey;
alter table marche_annonces add constraint marche_annonces_entreprise_vendeuse_id_fkey
  foreign key (entreprise_vendeuse_id) references entreprises(id) on delete set null;

alter table demandes_changement_cib drop constraint if exists demandes_changement_cib_entreprise_id_fkey;
alter table demandes_changement_cib add constraint demandes_changement_cib_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table transferts drop constraint if exists transferts_entreprise_expediteur_id_fkey;
alter table transferts add constraint transferts_entreprise_expediteur_id_fkey
  foreign key (entreprise_expediteur_id) references entreprises(id) on delete set null;

alter table transferts drop constraint if exists transferts_entreprise_destinataire_id_fkey;
alter table transferts add constraint transferts_entreprise_destinataire_id_fkey
  foreign key (entreprise_destinataire_id) references entreprises(id) on delete set null;

alter table capital_retraits_historique drop constraint if exists capital_retraits_historique_entreprise_id_fkey;
alter table capital_retraits_historique add constraint capital_retraits_historique_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table brevets_detenteurs drop constraint if exists brevets_detenteurs_entreprise_id_fkey;
alter table brevets_detenteurs add constraint brevets_detenteurs_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

alter table brevets_autorisations drop constraint if exists brevets_autorisations_entreprise_id_fkey;
alter table brevets_autorisations add constraint brevets_autorisations_entreprise_id_fkey
  foreign key (entreprise_id) references entreprises(id) on delete cascade;

-- 6) Recharge le cache de schéma de l'API pour que les fonctions soient vues tout de suite.
notify pgrst, 'reload schema';
