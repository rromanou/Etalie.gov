-- ============================================================
-- patch-cib-entreprise-avancee-27.sql
-- À exécuter après patch-cib-entreprise-avancee-26.sql. Additif et rejouable.
--
-- Remplace la liste de grades inventée (15 grades génériques) par la
-- vraie hiérarchie officielle du pays, trouvée dans hierarchie.html /
-- hierarchie.json / assets/documents/hierarchie.pdf / assets/donnees/CAS/salaire
-- ("Grades militaires (Impérats)") : 21 grades, ordre croissant.
--
-- HYPOTHÈSE : c'est la seule hiérarchie graduée présente dans le projet,
-- et les types de commissariat existants (police, police_militaire,
-- police_royale_militaire, royal) confirment que police et militaire sont
-- déjà fusionnés dans ce pays. Appliquée ici aux commissariats.
-- ============================================================

-- 1) Élargir la contrainte de grade (1-15 -> 1-21). Nom de contrainte
--    auto-généré par Postgres pour un "check" inline sur la colonne.
alter table comisseriats_membres drop constraint if exists comisseriats_membres_grade_check;
alter table comisseriats_membres add constraint comisseriats_membres_grade_check check (grade between 1 and 21);

-- 2) Les 21 vrais noms de grade, ordre croissant (Impérats).
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

-- 3) Un directeur de commissariat démarre désormais au nouveau grade maximal (21, au lieu de 15).
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
grant execute on function gouv_creer_comisseriat(text, text, text) to authenticated;

-- 4) Élargir la validation de grade/sous-grade dans la promotion (1-15 -> 1-21).
create or replace function comisseriat_promouvoir(p_membre_id uuid, p_grade int, p_sous_grade int)
returns comisseriats_membres language plpgsql security definer set search_path = public as $$
declare v_membre comisseriats_membres; v_comisseriat_id uuid;
begin
  if p_grade not between 1 and 21 or p_sous_grade not between 1 and 3 then raise exception 'Grade ou sous-grade invalide.'; end if;
  select * into v_membre from comisseriats_membres where id = p_membre_id and statut = 'actif';
  if v_membre.id is null then raise exception 'Membre introuvable.'; end if;
  v_comisseriat_id := v_membre.comisseriat_id;
  if not (_est_directeur(v_comisseriat_id) or _est_superviseur_royal() or est_admin_actuel()) then
    raise exception 'Accès refusé.';
  end if;
  update comisseriats_membres set grade = p_grade, sous_grade = p_sous_grade where id = p_membre_id returning * into v_membre;
  return v_membre;
end; $$;
grant execute on function comisseriat_promouvoir(uuid, int, int) to authenticated;


-- ============================================================
-- 5) CORRECTIF : suppression d'entreprise impossible (violation de clé
--    étrangère sur des tables ajoutées APRÈS le correctif du patch 15 :
--    bureau_poste_affiliations, marche_achats, marche_annonces,
--    demandes_changement_cib, transferts, capital_retraits_historique,
--    brevets_detenteurs, brevets_autorisations). Même logique que le
--    patch 15 : "on delete cascade" pour les données qui n'ont plus de
--    sens sans l'entreprise, "on delete set null" pour les historiques
--    qui doivent survivre (annonces, achats, virements).
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
