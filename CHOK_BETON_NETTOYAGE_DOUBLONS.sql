-- ============================================================
--  CHOK BÉTON — NETTOYAGE DES HEURES EN DOUBLE (à lancer UNE fois)
--
--  Entre le 14/09 et le 05/10/2026, des chefs ont renvoyé leur rapport
--  (pour ajouter un intérimaire oublié, ou croyant que l'envoi n'était pas
--  passé) : 13 lignes en trop, mêmes personne, jour et horaires.
--
--  Ce script :
--   1. fait une sauvegarde complète AVANT de toucher à quoi que ce soit ;
--   2. pour chaque groupe de copies EXACTES (même personne, même jour, mêmes
--      début, fin et pause), garde UNE ligne — la validée s'il y en a une —
--      et retire les copies NON VALIDÉES ;
--   3. n'efface jamais une ligne validée : s'il reste plusieurs copies
--      validées, elles sont listées à la fin, à retirer à la main (✕ dans
--      Direction → Pointages) ;
--   4. affiche ce qu'il a retiré.
--  Une journée réellement coupée en deux créneaux n'est pas concernée.
-- ============================================================
do $$
begin
  if 'é' <> chr(233) then
    raise exception 'ACCENTS ABÎMÉS AU COLLAGE — rien n''a été modifié.';
  end if;
end $$;

select chok.sauvegarde_complete('avant suppression') as sauvegarde_prealable;

with copies as (
  select p.id, coalesce(p.valide, false) as valide,
         row_number() over (partition by p.salarie, p.date, p.debut, p.fin, coalesce(p.pause,0)
                            order by coalesce(p.valide, false) desc, p.id) as rang
    from chok.pointages p
), retirees as (
  delete from chok.pointages p
   using copies c
   where c.id = p.id and c.rang > 1 and not c.valide
  returning p.id, p.salarie, p.date, p.debut, p.fin, p."chefNom"
)
select 'RETIRÉE' as action, r.date, coalesce(s.nom, i.nom, r.salarie) as personne, r.debut || '–' || r.fin as horaires,
       r."chefNom" as saisi_par, r.id as ligne
  from retirees r
  left join chok.salaries s on s.id = r.salarie
  left join chok.interimaires i on i.id = r.salarie
union all
-- Copies VALIDÉES en double : jamais effacées automatiquement.
select 'À VÉRIFIER (validée en double)', c.date, coalesce(s.nom, i.nom, c.salarie), c.debut || '–' || c.fin,
       c."chefNom", c.id
  from (select p.*, row_number() over (partition by p.salarie, p.date, p.debut, p.fin, coalesce(p.pause,0)
                                       order by p.id) as rang,
               count(*) over (partition by p.salarie, p.date, p.debut, p.fin, coalesce(p.pause,0)) as nb
          from chok.pointages p where coalesce(p.valide,false)) c
  left join chok.salaries s on s.id = c.salarie
  left join chok.interimaires i on i.id = c.salarie
 where c.nb > 1 and c.rang > 1
 order by 2 desc, 3;
