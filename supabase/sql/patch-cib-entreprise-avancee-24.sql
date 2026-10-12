-- ============================================================
-- patch-cib-entreprise-avancee-24.sql
-- À exécuter après patch-cib-entreprise-avancee-23.sql. Additif et rejouable.
--
-- CORRECTIFS DEMANDÉS :
--  1) Faille de sécurité : « Agent de la paix » (recherche de citoyens,
--     messages tagués, constats, gel économie/messages) était autorisé à
--     quiconque avait le simple drapeau legacy est_agent_paix (provenant
--     de num_CAS.txt), sans aucun lien avec la VRAIE hiérarchie policière
--     des commissariats (patch 20). est_agent_actuel() et
--     _est_agent_ou_gouv() exigent maintenant un poste actif RÉEL dans un
--     commissariat (ou l'administration) — le drapeau num_CAS.txt reste
--     affiché à titre informatif sur la fiche du citoyen mais ne donne
--     plus accès à rien par lui-même.
--  2) entreprise_avancer_paiement_auto plantait encore (400) en boucle :
--     la fonction appelée en cas de trésorerie insuffisante levait une
--     exception dès que l'entreprise était en mode défaillance "4"
--     (manuel uniquement, sans option de couverture). Le paiement
--     automatique échoue maintenant silencieusement dans ce cas (il n'y
--     a simplement pas de paiement ce tick-là) au lieu de lever.
--  3) Les fonds ajoutés par le propriétaire d'une banque à fructification
--     (banque_fructification_ajouter_fonds, patch 19) tombent dans la
--     réserve de la banque (colonne tresorerie) — mais le total vu par
--     l'administration et le prélèvement gouvernemental ne regardaient
--     que les comptes membres (banques_comptes), jamais cette réserve.
--     Les deux fonctions incluent maintenant la réserve.
--  4) HYPOTHÈSE : « les propriétaires de commissariat ne peuvent pas
--     gérer » — le code de gestion (embaucher/promouvoir/renvoyer/
--     transferts) n'autorisait que le Directeur du commissariat ou un
--     superviseur royal, sans jamais de dérogation admin — contrairement
--     à presque toutes les autres fonctions gouvernementales du site qui
--     acceptent systématiquement est_admin_actuel() comme autorité de
--     secours. Ajouté ici pour la cohérence et pour permettre au
--     gouvernement de dépanner n'importe quel commissariat.
--  5) Ajout, dans l'esprit demandé, d'un octroi ADMIN direct d'accès à
--     une banque publique (banques_privees.publique = true) : ajoute le
--     citoyen comme titulaire d'un compte dans cette banque sans passer
--     par la demande d'adhésion / l'approbation du propriétaire.
-- ============================================================

-- 1) Faille agent de la paix — accès réel aux fonctions d'agent.
create or replace function est_agent_actuel()
returns boolean language sql stable security definer set search_path = public as $$
  select est_admin_actuel() or coalesce(_mon_rang_police(), 0) > 0;
$$;

create or replace function _est_agent_ou_gouv()
returns boolean language sql stable security definer set search_path = public as $$
  select est_admin_actuel() or coalesce(_mon_rang_police(), 0) > 0;
$$;

-- 2) entreprise_avancer_paiement_auto : plus de 400 en boucle en mode manuel.
create or replace function entreprise_avancer_paiement_auto(p_entreprise_id uuid, p_secondes numeric default 1)
returns void language plpgsql security definer set search_path = public as $$
declare v_taux numeric; v_mode text; v_montant numeric; v_tresor numeric; v_option int;
begin
  select mode_paiement into v_mode from entreprises where id = p_entreprise_id;
  if v_mode is distinct from 'automatique' then return; end if;
  select salaire_horaire into v_taux from entreprises_membres where entreprise_id = p_entreprise_id and citoyen_id = auth.uid();
  if v_taux is null then return; end if;

  v_montant := (v_taux / 60.0) * p_secondes;
  select tresorerie into v_tresor from entreprises where id = p_entreprise_id for update;
  if v_tresor >= v_montant then
    update entreprises set tresorerie = tresorerie - v_montant where id = p_entreprise_id;
    update citoyens set tresorerie = tresorerie + v_montant where id = auth.uid();
    perform _entreprise_log(p_entreprise_id, 'paiement_employe',
      jsonb_build_object('citoyen_id', auth.uid(), 'montant', v_montant, 'secondes', p_secondes, 'taux', v_taux));
    return;
  end if;

  select option_defaillance into v_option from entreprises where id = p_entreprise_id;
  if v_option not in (1, 2, 3) then
    -- Mode manuel uniquement (ou non configuré) : pas de paiement ce
    -- tick-ci, silencieusement — le PDG doit payer manuellement.
    return;
  end if;

  perform _entreprise_gerer_manque_paie(p_entreprise_id, auth.uid(), v_montant, v_taux);
  perform _entreprise_log(p_entreprise_id, 'paiement_employe',
    jsonb_build_object('citoyen_id', auth.uid(), 'montant', v_montant, 'secondes', p_secondes, 'taux', v_taux, 'defaillance', true));
end; $$;
grant execute on function entreprise_avancer_paiement_auto(uuid, numeric) to authenticated;

-- 3) Totaux / prélèvement des banques à fructification : inclure la réserve (tresorerie).
create or replace function gouv_total_banques_privees()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not est_admin_actuel() then '{}'::jsonb else jsonb_build_object(
    'total_fructification',
      (select coalesce(sum(_valeur_compte_banque(bc.id)), 0) from banques_comptes bc join banques_privees b on b.id = bc.banque_id where b.type = 'fructification')
      + (select coalesce(sum(tresorerie), 0) from banques_privees where type = 'fructification'),
    'total_conseil', (select coalesce(sum(tresorerie), 0) from banques_privees where type = 'conseil'),
    'nb_banques', (select count(*) from banques_privees)
  ) end;
$$;

create or replace function gouv_piger_banques_fructification(p_montant_demande numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_total numeric; v_pourcentage numeric; v_preleve numeric := 0; bc record; b record; v_part numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  if p_montant_demande <= 0 then raise exception 'Montant invalide.'; end if;

  select coalesce(sum(_valeur_compte_banque(bc2.id)), 0) into v_total
    from banques_comptes bc2 join banques_privees bp on bp.id = bc2.banque_id where bp.type = 'fructification';
  v_total := v_total + coalesce((select sum(tresorerie) from banques_privees where type = 'fructification'), 0);
  if v_total <= 0 then return jsonb_build_object('preleve', 0, 'pourcentage', 0); end if;

  v_pourcentage := least(1, p_montant_demande / v_total);

  for bc in select bc2.id, _valeur_compte_banque(bc2.id) as valeur from banques_comptes bc2
      join banques_privees bp on bp.id = bc2.banque_id where bp.type = 'fructification' loop
    v_part := round(bc.valeur * v_pourcentage, 4);
    update banques_comptes set solde = bc.valeur - v_part, inflation_base = inflation_pourcentage() where id = bc.id;
    v_preleve := v_preleve + v_part;
  end loop;

  for b in select id, tresorerie from banques_privees where type = 'fructification' and tresorerie > 0 loop
    v_part := round(b.tresorerie * v_pourcentage, 4);
    update banques_privees set tresorerie = tresorerie - v_part where id = b.id;
    v_preleve := v_preleve + v_part;
  end loop;

  update tresor_public set solde = solde + v_preleve where id = 1;
  return jsonb_build_object('preleve', round(v_preleve, 2), 'pourcentage', round(v_pourcentage * 100, 4));
end; $$;
grant execute on function gouv_piger_banques_fructification(numeric) to authenticated;

-- 4) Dérogation admin sur la gestion d'un commissariat (comme ailleurs sur le site).
create or replace function comisseriat_embaucher(p_comisseriat_id uuid, p_username text)
returns comisseriats_membres language plpgsql security definer set search_path = public as $$
declare v_citoyen uuid;
begin
  if not (_est_directeur(p_comisseriat_id) or _est_superviseur_royal() or est_admin_actuel()) then raise exception 'Réservé au Directeur du commissariat.'; end if;
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

create or replace function comisseriat_renvoyer(p_membre_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m comisseriats_membres; v_mon_rang int;
begin
  select * into m from comisseriats_membres where id = p_membre_id and statut = 'actif';
  if m.id is null then raise exception 'Membre introuvable ou inactif.'; end if;
  if not (_est_directeur(m.comisseriat_id) or _est_superviseur_royal() or est_admin_actuel()) then
    v_mon_rang := _mon_rang_police();
    if v_mon_rang = 0 or _rang_total(m.grade, m.sous_grade) >= v_mon_rang then raise exception 'Accès refusé.'; end if;
  end if;
  update comisseriats_membres set statut = 'renvoye' where id = p_membre_id;
end; $$;
grant execute on function comisseriat_renvoyer(uuid) to authenticated;

create or replace function comisseriat_traiter_transfert(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
declare t comisseriats_transferts; m comisseriats_membres;
begin
  select * into t from comisseriats_transferts where id = p_id and statut = 'en_attente';
  if t.id is null then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if not (_est_directeur(t.comisseriat_dest) or _est_superviseur_royal() or est_admin_actuel()) then raise exception 'Réservé au Directeur du commissariat de destination.'; end if;
  if p_decision not in ('acceptee','refusee') then raise exception 'Décision invalide.'; end if;
  update comisseriats_transferts set statut = p_decision where id = p_id;
  if p_decision = 'acceptee' then
    select * into m from comisseriats_membres where citoyen_id = t.citoyen_id and statut = 'actif';
    update comisseriats_membres set comisseriat_id = t.comisseriat_dest where id = m.id;
  end if;
end; $$;
grant execute on function comisseriat_traiter_transfert(uuid, text) to authenticated;

-- 5) Octroi ADMIN direct d'un accès (compte) à une banque publique.
create or replace function gouv_accorder_acces_banque_publique(p_username text, p_banque_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_citoyen uuid; b banques_privees; v_inflation numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  select id into v_citoyen from citoyens where lower(username) = lower(trim(p_username));
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null then raise exception 'Banque introuvable.'; end if;
  if not b.publique then raise exception 'Réservé aux banques déclarées publiques.'; end if;
  if exists (select 1 from banques_comptes where banque_id = p_banque_id and citoyen_id = v_citoyen) then
    return; -- déjà titulaire, rien à faire
  end if;
  v_inflation := inflation_pourcentage();
  insert into banques_comptes (banque_id, citoyen_id, solde, inflation_base) values (p_banque_id, v_citoyen, 0, v_inflation);
end; $$;
grant execute on function gouv_accorder_acces_banque_publique(text, uuid) to authenticated;

create or replace function gouv_retirer_acces_banque_publique(p_username text, p_banque_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_citoyen uuid;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  select id into v_citoyen from citoyens where lower(username) = lower(trim(p_username));
  if v_citoyen is null then raise exception 'Citoyen introuvable.'; end if;
  delete from banques_comptes where banque_id = p_banque_id and citoyen_id = v_citoyen;
end; $$;
grant execute on function gouv_retirer_acces_banque_publique(text, uuid) to authenticated;

-- Liste des banques publiques, pour peupler le sélecteur admin.
create or replace function liste_banques_publiques()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'type', type) order by nom), '[]'::jsonb)
  from banques_privees where publique;
$$;
grant execute on function liste_banques_publiques() to authenticated;
