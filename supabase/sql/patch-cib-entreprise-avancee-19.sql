-- ============================================================
-- patch-cib-entreprise-avancee-19.sql
-- À exécuter après patch-cib-entreprise-avancee-18.sql. Additif et rejouable.
--
-- Corrige : la fenêtre de gestion d'une banque affichait TOUJOURS les
-- outils "banque à conseil" (investir en capital), même pour une banque
-- à fructification, quel que soit le type réellement cliqué. La fonction
-- liste_banques() ne renvoyait d'ailleurs la trésorerie que pour le type
-- conseil, donc le front-end n'avait aucun moyen de distinguer.
--
-- Ajoute les outils PROPRIÉTAIRE propres à une banque à fructification :
--  - Ajouter des fonds de sa poche dans la réserve de la banque (le champ
--    "tresorerie", jusqu'ici inutilisé pour ce type).
--  - Voir le pourcentage que cette réserve représente par rapport au total
--    des comptes (« combien de % de plus » la réserve couvre).
--  - Retirer de cette réserve directement vers le compte d'un membre
--    précis (par nom d'utilisateur), par exemple pour verser un bonus.
-- ============================================================

create or replace function liste_banques()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'nom', b.nom, 'type', b.type, 'proprietaire', c.username, 'conseiller', cc.username,
    'publique', b.publique, 'degre_gouvernemental', b.degre_gouvernemental, 'description', b.description,
    'tresorerie', b.tresorerie,
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

-- Le propriétaire ajoute des fonds personnels dans la réserve de la banque.
create or replace function banque_fructification_ajouter_fonds(p_banque_id uuid, p_montant numeric)
returns banques_privees language plpgsql security definer set search_path = public as $$
declare b banques_privees; v_dispo numeric; v_row banques_privees;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null then raise exception 'Banque introuvable.'; end if;
  if b.type <> 'fructification' then raise exception 'Réservé aux banques à fructification.'; end if;
  if b.proprietaire_id <> auth.uid() then raise exception 'Réservé au propriétaire.'; end if;
  v_dispo := _ma_tresorerie();
  if v_dispo < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  perform _debiter_ma_tresorerie(p_montant);
  update banques_privees set tresorerie = tresorerie + p_montant where id = p_banque_id returning * into v_row;
  return v_row;
end; $$;
grant execute on function banque_fructification_ajouter_fonds(uuid, numeric) to authenticated;

-- Le propriétaire retire de la réserve vers le compte d'un membre précis (par username).
create or replace function banque_fructification_retirer_vers(p_banque_id uuid, p_destinataire_username text, p_montant numeric)
returns void language plpgsql security definer set search_path = public as $$
declare b banques_privees; v_dest uuid; bc banques_comptes; v_inflation numeric;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into b from banques_privees where id = p_banque_id;
  if b.id is null then raise exception 'Banque introuvable.'; end if;
  if b.type <> 'fructification' then raise exception 'Réservé aux banques à fructification.'; end if;
  if b.proprietaire_id <> auth.uid() then raise exception 'Réservé au propriétaire.'; end if;
  if b.tresorerie < p_montant then raise exception 'Réserve insuffisante (disponible : % R$).', b.tresorerie; end if;
  select id into v_dest from citoyens where lower(username) = lower(trim(p_destinataire_username));
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;

  v_inflation := inflation_pourcentage();
  select * into bc from banques_comptes where banque_id = p_banque_id and citoyen_id = v_dest for update;
  if bc.id is null then
    insert into banques_comptes (banque_id, citoyen_id, solde, inflation_base) values (p_banque_id, v_dest, p_montant, v_inflation);
  else
    update banques_comptes set solde = _valeur_compte_banque(bc.id) + p_montant, inflation_base = v_inflation where id = bc.id;
  end if;
  update banques_privees set tresorerie = tresorerie - p_montant where id = p_banque_id;
end; $$;
grant execute on function banque_fructification_retirer_vers(uuid, text, numeric) to authenticated;
