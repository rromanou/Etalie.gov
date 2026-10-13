-- ============================================================
-- patch-cib-entreprise-avancee-26.sql
-- À exécuter après patch-cib-entreprise-avancee-25.sql. Additif et rejouable.
--
-- Suite de la migration vers le système de cartes/CIB (patch 25) :
-- paiement des constats (amendes) et achat des permis. Même principe
-- que marche_acheter : la trésorerie personnelle n'est plus débitée
-- directement, le citoyen doit fournir une carte (numéro + NIP) ou un
-- CIB d'envoi d'entreprise.
--
-- HYPOTHÈSE : l'amende/le permis n'a pas de « net vs taxes » distincts
-- comme un achat du marché public — tout le montant est traité comme
-- le « net » pour le calcul d'intérêt d'une carte à emprunt (donc
-- empruntable avec intérêt, comme n'importe quelle dépense).
--
-- Reste encore à migrer (hors de cette passe) : signer_emprunt /
-- emprunts classiques entre citoyens — mécanique différente (prêt
-- pair-à-pair avec échéancier déjà existant), qui mériterait son propre
-- examen plutôt qu'un copier-coller de ce patron.
-- ============================================================

create or replace function payer_constat(p_id uuid, p_moyen text, p_carte_numero text default null, p_carte_nip text default null, p_cib text default null)
returns constats_infraction language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction;
begin
  if p_moyen not in ('carte','cib') then raise exception 'Moyen de paiement invalide (carte ou cib).'; end if;
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat.id is null then raise exception 'Constat introuvable.'; end if;
  if v_constat.paye then raise exception 'Ce constat a déjà été payé.'; end if;
  if v_constat.annule then raise exception 'Ce constat a été annulé (contestation acceptée).'; end if;
  if exists (select 1 from constats_contestations where constat_id = p_id and statut = 'en_attente') then
    raise exception 'Une contestation est en attente pour ce constat : paiement bloqué jusqu''à la décision.';
  end if;

  perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_constat.prix_total, 0);
  update tresor_public set solde_prive = solde_prive + v_constat.prix_total where id = 1;
  update constats_infraction set paye = true, paye_le = now() where id = p_id returning * into v_constat;
  insert into paiements_historique (citoyen_id, type, montant, reference_id) values (auth.uid(), 'constat', v_constat.prix_total, p_id);
  return v_constat;
end; $$;
grant execute on function payer_constat(uuid, text, text, text, text) to authenticated;

create or replace function acheter_permis(p_type text, p_moyen text, p_carte_numero text default null, p_carte_nip text default null, p_cib text default null)
returns permis_citoyens language plpgsql security definer set search_path = public as $$
declare
  v_base numeric; v_total numeric; v_expire date; v_row permis_citoyens;
begin
  if p_type not in ('peche','chasse','travail') then raise exception 'Type de permis invalide.'; end if;
  if p_moyen not in ('carte','cib') then raise exception 'Moyen de paiement invalide (carte ou cib).'; end if;

  if exists (
    select 1 from permis_citoyens
    where citoyen_id = auth.uid() and type = p_type and (expire_le is null or expire_le >= current_date)
  ) then
    raise exception 'Vous détenez déjà un permis de ce type, encore valide.';
  end if;

  v_base := case p_type when 'peche' then 65.59 when 'chasse' then 178.59 else 0 end;
  v_total := round(v_base * 1.15, 2);
  v_expire := case when p_type = 'travail' then null else (current_date + interval '1 year')::date end;

  if v_total > 0 then
    perform _debiter_moyen_paiement(p_moyen, p_carte_numero, p_carte_nip, p_cib, v_total, 0);
    update tresor_public set solde = solde + v_total where id = 1;
  end if;

  insert into permis_citoyens (citoyen_id, type, prix_paye, expire_le)
  values (auth.uid(), p_type, v_total, v_expire)
  returning * into v_row;

  return v_row;
end; $$;
grant execute on function acheter_permis(text, text, text, text, text) to authenticated;
