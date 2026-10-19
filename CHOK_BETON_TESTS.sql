-- ============================================================
--  CHOK BÉTON — CONTRÔLE DU SERVEUR
--
--  À exécuter APRÈS CHOK_BETON_SUPABASE.sql, dans le SQL Editor.
--  Durée : environ 2 secondes.
--
--  Ce script vérifie que le cloisonnement fonctionne réellement :
--  il crée des personnes et des heures fictives, se connecte sous
--  chaque rôle, et contrôle ce que chacun reçoit.
--
--  ------------------------------------------------------------
--  POURQUOI IL N'ABÎME RIEN
--  ------------------------------------------------------------
--  Tout se déroule à l'intérieur d'UNE SEULE fonction. Les essais
--  sont faits dans un sous-bloc qui se termine par une erreur
--  volontaire : PostgreSQL annule alors la totalité des écritures.
--
--  Les résultats, eux, sont gardés dans une variable — et une
--  variable ne fait pas partie de la base, donc elle survit à cette
--  annulation. On récupère ainsi le compte rendu sans laisser la
--  moindre trace.
--
--  C'est plus sûr qu'un simple BEGIN … ROLLBACK : l'éditeur Supabase
--  passe par un pool de connexions, où un ROLLBACK écrit à la fin
--  d'un script n'annule pas forcément ce qui précède.
--
--  ------------------------------------------------------------
--  À TOUT MOMENT, POUR REVÉRIFIER LE SERVEUR :
--      select * from chok.controle();
-- ============================================================

-- ============================================================
--  GARDE-FOU : LES ACCENTS SONT-ILS ARRIVÉS INTACTS ?
--
--  Un copier-coller mal encodé change « é » en « √© » ou « Ã© ». Le
--  script tournait quand même, avec des libellés faux : les contrôles
--  donneraient de faux échecs. Désormais, au moindre
--  accent abîmé, le script s'arrête AVANT d'avoir rien touché.
-- ============================================================
do $$
begin
  if 'é' <> chr(233) or 'œ' <> chr(339) then
    raise exception 'ACCENTS ABÎMÉS AU COLLAGE — rien n''a été modifié. Recopiez le fichier depuis un éditeur de texte (TextEdit), pas depuis un aperçu.';
  end if;
end $$;

-- ---- Petit outil : enregistre le résultat d'une vérification ----
create or replace function chok._v(res jsonb, p_libelle text, p_obtenu text, p_attendu text)
returns jsonb language sql immutable as $$
  select res || jsonb_build_object(
    'libelle', p_libelle, 'attendu', p_attendu, 'obtenu', p_obtenu,
    'ok', p_obtenu is not distinct from p_attendu);
$$;

create or replace function chok.controle()
returns table(n integer, resultat text, libelle text, attendu text, obtenu text)
language plpgsql as $$
declare
  res   jsonb := '[]'::jsonb;   -- survit à l'annulation : ce n'est pas de la base
  jchef text; jsal text; jrh text; r jsonb; d jsonb; k integer; n integer;
  -- Dates RELATIVES : avec des dates figées, ces contrôles auraient cessé
  -- de passer d'eux-mêmes au bout d'une semaine, à cause de la règle des
  -- 3 jours. Un test qui dépend du calendrier ne vaut rien.
  v_hier  text := to_char((timezone('Europe/Paris', now()))::date - 1, 'YYYY-MM-DD');
  v_avhier text := to_char((timezone('Europe/Paris', now()))::date - 2, 'YYYY-MM-DD');
begin
  begin   -- ======== sous-bloc : tout ce qui suit sera annulé ========

    -- ---------- Jeu d'essai ----------
    insert into chok.salaries(id,nom,poste,interne,code,conges) values
      ('T-CHEF','TEST Chef','Chef d''équipe',true,'1111',30),
      ('T-CHF2','TEST Chef 2','Chef d''équipe',true,'2222',30),
      ('T-SAL', 'TEST Ouvrier','Maçon',        true,'3333',30);
    insert into chok.interimaires(id,nom,poste,agence,"accesPlateforme",code,chef) values
      ('T-ITM','TEST Intérim','Manœuvre','AG',true,'4444','T-CHEF'),
      ('T-ITX','TEST Intérim autre','Manœuvre','AG',true,'5555','T-CHF2');
    insert into chok.chantiers(id,nom,ville,actif,chef) values
      ('T-CH1','TEST Chantier','Lyon',true,'T-CHEF'),
      ('T-CH2','TEST Chantier autre','Paris',true,'T-CHF2');

    -- ---------- 1. CONNEXION ----------
    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-CHEF','pin','0000'));
    res := chok._v(res,'Mauvais code refusé', r->>'erreur', 'Code incorrect.');

    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-CHEF','pin','1111'));
    res := chok._v(res,'Chef connecté', r->>'ok', 'true');
    res := chok._v(res,'Rôle déduit du poste', r->>'role', 'chef');
    res := chok._v(res,'Données livrées avec la connexion (un seul aller-retour)',
                       (r ? 'donnees')::text, 'true');
    jchef := r->>'jeton';

    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-SAL','pin','3333'));
    res := chok._v(res,'Ouvrier connecté en rôle salarié', r->>'role', 'salarie');
    jsal := r->>'jeton';

    r := public.chok_api(jsonb_build_object('action','connexion','role','rh',
                                            'pin', chok.config_lire('pinRH')));
    res := chok._v(res,'Direction connectée', r->>'role', 'rh');
    jrh := r->>'jeton';

    res := chok._v(res,'Jeton inventé rejeté',
      (public.chok_api(jsonb_build_object('action','charger','jeton',
        '00000000-0000-0000-0000-000000000000')))->>'expire', 'true');
    res := chok._v(res,'Jeton illisible rejeté sans planter',
      (public.chok_api(jsonb_build_object('action','charger','jeton','n''importe quoi')))->>'ok','false');
    res := chok._v(res,'Sans jeton, rien',
      (public.chok_api('{"action":"charger"}'::jsonb))->>'ok', 'false');

    -- ---------- 2. ÉCRITURE PAR LE CHEF ----------
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(
        jsonb_build_object('id','T-P1','salarie','T-CHEF','chantier','T-CH1','date',v_hier,
                           'debut','08:00','fin','16:00','pause',60,'chefNom','TEST Chef'),
        jsonb_build_object('id','T-P2','salarie','T-ITM','chantier','T-CH1','date',v_hier,
                           'debut','08:00','fin','16:00','pause',60,'chefNom','TEST Chef'))));
    res := chok._v(res,'Le chef déclare ses heures et celles de son intérimaire', r->>'ok','true');
    -- Règle du 06/10/2026 : chacun SA feuille. Plus de saisie pour un collègue.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-P3','salarie','T-SAL','chantier','T-CH1',
        'date',v_hier,'debut','08:00','fin','16:00','pause',60))));
    res := chok._v(res,'Un chef ne déclare plus les heures d''un autre salarié', r->>'codeErreur','PERSONNE_NON_RATTACHEE');
    -- Ligne d'avant la règle, saisie par le chef pour T-SAL : la suite des
    -- contrôles (lecture, validation) s'en sert.
    insert into chok.pointages(id,salarie,chantier,date,debut,fin,pause,"creePar","chefNom")
      values ('T-P3','T-SAL','T-CH1',v_hier,'08:00','16:00',60,'T-CHEF','TEST Chef');
    res := chok._v(res,'Auteur enregistré automatiquement',
      (select "creePar" from chok.pointages where id='T-P1'), 'T-CHEF');
    res := chok._v(res,'Pause enregistrée en nombre',
      (select pause from chok.pointages where id='T-P1')::text, '60');
    res := chok._v(res,'Case non cochée = non (et surtout pas « vrai »)',
      (select deplacement from chok.pointages where id='T-P1')::text, 'false');

    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-PX','salarie','T-ITX',
        'chantier','T-CH1','date',v_hier,'debut','08:00','fin','16:00'))));
    res := chok._v(res,'Intérimaire d''un autre chef refusé', r->>'ok', 'false');

    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jsal,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-PY','salarie','T-SAL','date',v_avhier))));
    res := chok._v(res,'Un salarié ne peut pas déclarer d''heures', r->>'ok', 'false');

    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','salaries',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-SAL','code','0000'))));
    res := chok._v(res,'Un chef ne peut pas toucher aux fiches du personnel', r->>'ok', 'false');

    -- ---------- 2 bis. LA RÈGLE DES 3 JOURS ----------
    -- Le navigateur limite déjà la saisie, mais un contrôle qui ne vit que
    -- dans le navigateur se contourne. C'est le serveur qui tranche.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-VIEUX2','salarie','T-CHEF',
        'chantier','T-CH1','date','2020-01-15','debut','08:00','fin','16:00'))));
    res := chok._v(res,'Une saisie trop ancienne est refusée', r->>'codeErreur','TROP_ANCIEN');

    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-FUTUR','salarie','T-CHEF',
        'chantier','T-CH1','date', to_char((now() + interval '10 days')::date,'YYYY-MM-DD'),
        'debut','08:00','fin','16:00'))));
    res := chok._v(res,'Une saisie dans le futur est refusée', r->>'codeErreur','DATE_FUTURE');

    -- Une saisie d'hier passe : c'est le cas courant.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-HIER','salarie','T-CHEF',
        'chantier','T-CH1','date', to_char((timezone('Europe/Paris',now()))::date - 1,'YYYY-MM-DD'),
        'debut','18:00','fin','20:00'))));
    res := chok._v(res,'Une saisie d''hier passe normalement', r->>'ok','true');

    -- Une saisie restée en file d'attente 5 jours passe aussi : sinon on
    -- perdrait des heures réellement travaillées, faute de réseau.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-FILE','salarie','T-CHEF',
        'chantier','T-CH1','date', to_char((timezone('Europe/Paris',now()))::date - 5,'YYYY-MM-DD'),
        'debut','08:00','fin','16:00'))));
    res := chok._v(res,'Une saisie hors réseau de 5 jours n''est pas perdue', r->>'ok','true');

    -- La direction, elle, n'est pas concernée par la règle.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jrh,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-RHVIEUX','salarie','T-SAL',
        'chantier','T-CH1','date','2020-01-15','debut','08:00','fin','16:00'))));
    res := chok._v(res,'La direction peut saisir une période close', r->>'ok','true');

    -- ---------- 2 ter. UN CHEF D'ÉQUIPE PEUT ÊTRE INTÉRIMAIRE ----------
    insert into chok.interimaires(id,nom,poste,agence,"accesPlateforme",code,chef)
      values ('T-ICHEF','TEST Chef intérim','Chef d''équipe','AG',false,'6666','');

    r := public.chok_api('{"action":"listePersonnes"}'::jsonb);
    res := chok._v(res,'Un intérimaire chef apparaît à la connexion',
      (select count(*) from jsonb_array_elements(r->'personnes') x
        where x->>'id'='T-ICHEF')::text,'1');
    res := chok._v(res,'Même sans « accès plateforme » coché',
      (select "accesPlateforme" from chok.interimaires where id='T-ICHEF')::text,'false');
    res := chok._v(res,'Un intérimaire à qui l''accès est ouvert apparaît',
      (select count(*) from jsonb_array_elements(r->'personnes') x
        where x->>'id'='T-ITX' )::text,'1');   -- celui-ci a accesPlateforme = true
    insert into chok.interimaires(id,nom,poste,agence,"accesPlateforme",code,chef)
      values ('T-INO','TEST Intérim sans accès','Manœuvre','AG',false,'8888','T-CHEF');
    r := public.chok_api('{"action":"listePersonnes"}'::jsonb);
    res := chok._v(res,'Mais un intérimaire ordinaire, sans accès, n''apparaît pas',
      (select count(*) from jsonb_array_elements(r->'personnes') x
        where x->>'id'='T-INO' )::text,'0');

    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-ICHEF','pin','6666'));
    res := chok._v(res,'Il se connecte en rôle CHEF', r->>'role','chef');
    res := chok._v(res,'Ses heures seront comptées comme intérimaire',
      (select count(*) from jsonb_array_elements((r->'donnees')->'interimaires') x
        where x->>'id'='T-ICHEF')::text,'1');
    res := chok._v(res,'Il ne figure PAS parmi les salariés',
      (select count(*) from jsonb_array_elements((r->'donnees')->'salaries') x
        where x->>'id'='T-ICHEF')::text,'0');

    -- Il déclare ses propres heures ET celles de l'intérimaire qui lui est
    -- rattaché — rattachement fait par la direction.
    insert into chok.interimaires(id,nom,poste,agence,code,chef)
      values ('T-IEQ','TEST Intérim du chef intérim','Manœuvre','AG','0000','T-ICHEF');
    d := public.chok_api(jsonb_build_object('action','enregistrer','jeton',r->>'jeton','table','pointages',
      'upserts', jsonb_build_array(
        jsonb_build_object('id','T-PIC1','salarie','T-ICHEF','chantier','T-CH1','date',v_avhier,
                           'debut','08:00','fin','16:00'),
        jsonb_build_object('id','T-PIC2','salarie','T-IEQ','chantier','T-CH1','date',v_avhier,
                           'debut','08:00','fin','16:00'))));
    res := chok._v(res,'Le chef intérimaire saisit ses heures et celles de son intérimaire',
      d->>'ok','true');
    d := public.chok_api(jsonb_build_object('action','enregistrer','jeton',r->>'jeton','table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-PIC3','salarie','T-ITM',
        'chantier','T-CH1','date',v_avhier,'debut','08:00','fin','16:00'))));
    res := chok._v(res,'Mais pas celles de l''intérimaire d''un autre chef', d->>'ok','false');

    -- ---------- 3. DOUBLE DÉCLARATION ----------
    -- Le chef renvoie SES heures déjà envoyées (cas réel du 05/10/2026 :
    -- trois fois la même journée). Refusé, même par lui-même.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-P1bis','salarie','T-CHEF',
        'chantier','T-CH1','date',v_hier,'debut','08:00','fin','16:00'))));
    res := chok._v(res,'Renvoyer ses propres heures du jour est REFUSÉ', r->>'codeErreur', 'DEJA_DECLARE');
    -- Aucune confirmation ne force le passage.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'confirmerDoublon', true,
      'upserts', jsonb_build_array(jsonb_build_object('id','T-P1ter','salarie','T-CHEF',
        'chantier','T-CH1','date',v_hier,'debut','09:00','fin','12:00'))));
    res := chok._v(res,'Même « confirmé », un créneau qui chevauche est refusé', r->>'ok', 'false');
    -- L'intérimaire aussi : le renvoyer avec le rapport suivant ne passe plus.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-P2bis','salarie','T-ITM',
        'chantier','T-CH1','date',v_hier,'debut','08:00','fin','16:00'))));
    res := chok._v(res,'Renvoyer son intérimaire du jour est refusé', r->>'codeErreur', 'DEJA_DECLARE');
    -- Un second créneau DISTINCT le même jour reste possible.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-P1soir','salarie','T-CHEF',
        'chantier','T-CH1','date',v_hier,'debut','16:30','fin','17:30'))));
    res := chok._v(res,'Un second créneau distinct le même jour est accepté', r->>'ok', 'true');
    res := chok._v(res,'Le serveur sait lire un poste de nuit',
      chok.chevauche('22:00','06:00','05:00','07:00')::text, 'true');

    -- ---------- 4. CLOISONNEMENT EN LECTURE ----------
    d := (public.chok_api(jsonb_build_object('action','charger','jeton',jsal,'tout',true)))->'donnees';
    res := chok._v(res,'Le salarié ne voit QUE ses heures',
      (select count(*) from jsonb_array_elements(d->'pointages') x
        where x->>'salarie' <> 'T-SAL')::text, '0');
    res := chok._v(res,'Le salarié ne voit qu''une fiche : la sienne',
      jsonb_array_length(d->'salaries')::text, '1');
    res := chok._v(res,'Aucun code d''accès ne lui est transmis',
      ((d->'salaries'->0) ? 'code')::text, 'false');

    d := (public.chok_api(jsonb_build_object('action','charger','jeton',jchef,'tout',true)))->'donnees';
    res := chok._v(res,'Le chef ne voit pas l''intérimaire d''un autre chef',
      (select count(*) from jsonb_array_elements(d->'interimaires') x where x->>'id'='T-ITX')::text,'0');
    res := chok._v(res,'Le chef ne voit pas le chantier d''un autre chef',
      (select count(*) from jsonb_array_elements(d->'chantiers') x where x->>'id'='T-CH2')::text,'0');
    res := chok._v(res,'Aucun code d''accès dans la liste des collègues',
      (select count(*) from jsonb_array_elements(d->'salaries') x where x ? 'code')::text,'0');
    res := chok._v(res,'Aucun solde de congés d''un collègue',
      (select count(*) from jsonb_array_elements(d->'salaries') x
        where x->>'id' <> 'T-CHEF' and x ? 'conges')::text,'0');
    res := chok._v(res,'Le chef voit tout de même sa propre fiche',
      (select count(*) from jsonb_array_elements(d->'salaries') x
        where x->>'id'='T-CHEF' and x ? 'conges')::text,'1');

    d := (public.chok_api(jsonb_build_object('action','charger','jeton',jrh,'tout',true)))->'donnees';
    res := chok._v(res,'La direction voit les 3 fiches de test',
      (select count(*) from jsonb_array_elements(d->'salaries') x where x->>'id' like 'T-%')::text,'3');
    res := chok._v(res,'La direction reçoit les codes (pour les gérer)',
      (select count(*) from jsonb_array_elements(d->'salaries') x
        where x->>'id'='T-CHEF' and x ? 'code')::text,'1');

    -- ---------- 5. LIMITATION DE PÉRIODE ----------
    insert into chok.pointages(id,salarie,chantier,date) values ('T-VIEUX','T-SAL','T-CH1','2020-01-01');
    d := (public.chok_api(jsonb_build_object('action','charger','jeton',jrh)))->'donnees';
    res := chok._v(res,'Par défaut, l''historique ancien n''est pas rechargé',
      (select count(*) from jsonb_array_elements(d->'pointages') x where x->>'id'='T-VIEUX')::text,'0');
    d := (public.chok_api(jsonb_build_object('action','charger','jeton',jrh,'tout',true)))->'donnees';
    res := chok._v(res,'Sur demande, tout l''historique revient',
      (select count(*) from jsonb_array_elements(d->'pointages') x where x->>'id'='T-VIEUX')::text,'1');

    -- ---------- 6. CORRECTION ET SUPPRESSION ----------
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-P1','fin','18:00'))));
    res := chok._v(res,'Le chef corrige sa ligne', r->>'ok','true');
    res := chok._v(res,'La correction est enregistrée',
      (select fin from chok.pointages where id='T-P1'), '18:00');
    res := chok._v(res,'Une correction partielle n''efface pas le reste de la ligne',
      (select debut from chok.pointages where id='T-P1'), '08:00');
    res := chok._v(res,'La correction ne change pas l''auteur',
      (select "creePar" from chok.pointages where id='T-P1'), 'T-CHEF');

    update chok.pointages set valide = true where id='T-P1';
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-P1','fin','19:00'))));
    res := chok._v(res,'Une ligne validée n''est plus modifiable', r->>'codeErreur','DEJA_VALIDE');
    update chok.pointages set valide = false where id='T-P1';

    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-CHF2','pin','2222'));
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',r->>'jeton','table','pointages',
      'suppressions', jsonb_build_array('T-P1')));
    res := chok._v(res,'On ne supprime pas la saisie d''un autre', r->>'codeErreur','SAISIE_AUTRUI');
    res := chok._v(res,'La ligne est toujours là',
      (select count(*) from chok.pointages where id='T-P1')::text,'1');

    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'suppressions', jsonb_build_array('T-P1')));
    res := chok._v(res,'Chacun supprime ce qu''il a saisi', r->>'ok','true');

    -- ---------- 7. GARDE ANTI-SUPPRESSION MASSIVE ----------
    delete from chok.absences;   -- annulé avec le reste
    insert into chok.absences(id,salarie,"dateDebut","dateFin",type)
      select 'T-A'||g, 'T-SAL', '2026-06-0'||(g%9+1), '2026-06-0'||(g%9+1), 'CP'
        from generate_series(1,20) g;
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jrh,'table','absences',
      'suppressions', (select jsonb_agg(id) from chok.absences)));
    res := chok._v(res,'Suppression massive bloquée', r->>'codeErreur','SUPPRESSION_MASSIVE');
    res := chok._v(res,'Rien n''a été supprimé',
      (select count(*) from chok.absences)::text,'20');

    -- ---------- 8. SAUVEGARDE AVANT REMISE À ZÉRO ----------
    r := public.chok_api(jsonb_build_object('action','reinitialiser','jeton',jrh,
                                            'tables', jsonb_build_array('absences')));
    res := chok._v(res,'Remise à zéro effectuée', r->>'ok','true');
    res := chok._v(res,'Une sauvegarde a été créée AVANT l''effacement',
      (select count(*) from chok.sauvegardes where motif='avant remise à zéro')::text,'1');
    res := chok._v(res,'La sauvegarde contient bien les lignes effacées',
      (select (jsonb_array_length(contenu->'absences') >= 20)::text from chok.sauvegardes
        where motif='avant remise à zéro' order by cree desc limit 1), 'true');
    res := chok._v(res,'Les absences sont bien effacées',
      (select count(*) from chok.absences)::text,'0');

    -- ---------- 8 bis. LE FILET NE DÉPEND PAS DU TÉLÉPHONE ----------
    -- L'application procède en deux appels courts : elle sauvegarde, puis
    -- demande l'effacement en annonçant « sauvegarde faite ». Un téléphone
    -- modifié pourrait mentir. La base doit donc REVÉRIFIER qu'une
    -- sauvegarde de moins de dix minutes existe — sinon elle refuse.
    insert into chok.absences(id,salarie,"dateDebut","dateFin",type)
      values ('T-A-FILET','T-SAL','2026-06-01','2026-06-01','CP');
    -- On vieillit artificiellement toutes les sauvegardes : plus aucune n'est
    -- récente. (Annulé avec le reste du test.)
    update chok.sauvegardes set cree = now() - interval '2 hours';
    r := public.chok_api(jsonb_build_object('action','reinitialiser','jeton',jrh,
           'tables', jsonb_build_array('absences'), 'sauvegardeFaite', true));
    res := chok._v(res,'Sans sauvegarde récente, l''effacement est REFUSÉ', r->>'ok','false');
    res := chok._v(res,'Et rien n''a été effacé',
      (select count(*) from chok.absences)::text,'1');

    -- Avec une vraie sauvegarde faite juste avant, il passe.
    r := public.chok_api(jsonb_build_object('action','sauvegarder','jeton',jrh,
                                            'motif','avant remise à zéro'));
    res := chok._v(res,'La sauvegarde séparée fonctionne', r->>'ok','true');
    r := public.chok_api(jsonb_build_object('action','reinitialiser','jeton',jrh,
           'tables', jsonb_build_array('absences'), 'sauvegardeFaite', true));
    res := chok._v(res,'Puis l''effacement est accepté', r->>'ok','true');
    res := chok._v(res,'Les absences sont effacées',
      (select count(*) from chok.absences)::text,'0');

    -- ---------- 9. RÉSERVÉ À LA DIRECTION ----------
    res := chok._v(res,'Un chef ne peut pas remettre à zéro',
      (public.chok_api(jsonb_build_object('action','reinitialiser','jeton',jchef)))->>'ok','false');
    res := chok._v(res,'Un chef ne peut pas lire les réglages',
      (public.chok_api(jsonb_build_object('action','reglages','jeton',jchef,'lire',true)))->>'ok','false');
    res := chok._v(res,'Un salarié ne peut pas changer le code direction',
      (public.chok_api(jsonb_build_object('action','reglages','jeton',jsal,'pinRH','9999')))->>'ok','false');

    -- ---------- 10. LISTE D'AVANT CONNEXION ----------
    r := public.chok_api('{"action":"listePersonnes"}'::jsonb);
    res := chok._v(res,'La liste des noms est accessible avant connexion', r->>'ok','true');
    res := chok._v(res,'Elle ne contient AUCUN code',
      (select count(*) from jsonb_array_elements(r->'personnes') x where x ? 'code')::text,'0');
    res := chok._v(res,'Elle ne contient aucune heure',
      (select count(*) from jsonb_array_elements(r->'personnes') x where x ? 'date')::text,'0');

    -- ---------- 11. ARCHIVAGE : L'INTÉRIMAIRE QUI PART EN COURS DE SEMAINE ----------
    -- Il a travaillé, on met fin à sa mission : il doit sortir des listes
    -- de saisie, mais ses heures doivent rester pour la paie et la facture.
    update chok.interimaires set actif = false where id = 'T-ITM';

    r := public.chok_api('{"action":"listePersonnes"}'::jsonb);
    res := chok._v(res,'Un intérimaire archivé disparaît de l''écran de connexion',
      (select count(*) from jsonb_array_elements(r->'personnes') x where x->>'id'='T-ITM')::text,'0');

    d := (public.chok_api(jsonb_build_object('action','charger','jeton',jchef,'tout',true)))->'donnees';
    res := chok._v(res,'Le chef ne peut plus le sélectionner',
      (select count(*) from jsonb_array_elements(d->'interimaires') x where x->>'id'='T-ITM')::text,'0');
    res := chok._v(res,'MAIS ses heures restent visibles pour la paie',
      (select count(*) from jsonb_array_elements(d->'pointages') x where x->>'salarie'='T-ITM')::text,'1');

    d := (public.chok_api(jsonb_build_object('action','charger','jeton',jrh,'tout',true)))->'donnees';
    res := chok._v(res,'La direction voit toujours sa fiche (pour le réactiver)',
      (select count(*) from jsonb_array_elements(d->'interimaires') x where x->>'id'='T-ITM')::text,'1');
    res := chok._v(res,'Et elle la voit marquée « archivée »',
      (select x->>'actif' from jsonb_array_elements(d->'interimaires') x where x->>'id'='T-ITM'),'false');
    res := chok._v(res,'Ses heures sont toujours dans le rapport de la direction',
      (select count(*) from jsonb_array_elements(d->'pointages') x where x->>'salarie'='T-ITM')::text,'1');

    -- Un salarié archivé n'est plus proposé comme collègue.
    update chok.salaries set actif = false where id = 'T-SAL';
    d := (public.chok_api(jsonb_build_object('action','charger','jeton',jchef,'tout',true)))->'donnees';
    res := chok._v(res,'Un salarié archivé n''est plus proposé dans l''équipe',
      (select count(*) from jsonb_array_elements(d->'salaries') x where x->>'id'='T-SAL')::text,'0');
    update chok.salaries set actif = true where id = 'T-SAL';
    update chok.interimaires set actif = true where id = 'T-ITM';

    -- ---------- 12. PORTE D'EXPORT (robot de sauvegarde Drive) ----------
    res := chok._v(res,'Sans clé, l''export est refusé',
      (public.chok_api('{"action":"exporter"}'::jsonb))->>'ok', 'false');
    res := chok._v(res,'Avec une fausse clé, il est refusé',
      (public.chok_api('{"action":"exporter","cleExport":"faux"}'::jsonb))->>'ok', 'false');
    res := chok._v(res,'Un jeton de direction ne suffit pas à exporter',
      (public.chok_api(jsonb_build_object('action','exporter','jeton',jrh)))->>'ok', 'false');

    r := public.chok_api(jsonb_build_object('action','exporter',
                          'cleExport', chok.config_lire('cleExport')));
    res := chok._v(res,'Avec la bonne clé, l''export passe', r->>'ok', 'true');
    res := chok._v(res,'Il contient bien les 5 tables',
      (select count(*) from jsonb_object_keys(r->'donnees'))::text, '5');
    res := chok._v(res,'Il ne contient ni réglages ni journal',
      ((r->'donnees') ? 'config' or (r->'donnees') ? 'journal')::text, 'false');
    res := chok._v(res,'La clé d''export n''est pas renvoyée dans la réponse',
      (position(chok.config_lire('cleExport') in r::text) > 0)::text, 'false');
    -- Des fausses clés en série ne privent plus la direction de sa
    -- sauvegarde de nuit : la bonne clé passe toujours.
    perform public.chok_api('{"action":"exporter","cleExport":"faux"}'::jsonb)
      from generate_series(1,6);
    res := chok._v(res,'Six fausses clés ne bloquent pas le robot de sauvegarde',
      (public.chok_api(jsonb_build_object('action','exporter',
         'cleExport', chok.config_lire('cleExport'))))->>'ok', 'true');

    -- ---------- 13. BLOCAGE APRÈS CODES ERRONÉS ----------
    perform public.chok_api(jsonb_build_object('action','connexion','personneId','T-SAL','pin','0001'))
      from generate_series(1,5);
    res := chok._v(res,'Blocage après 5 codes erronés',
      ((public.chok_api(jsonb_build_object('action','connexion','personneId','T-SAL','pin','3333')))->>'erreur'
        like 'Trop de codes%')::text, 'true');

    -- ---------- 13 bis. CHEFS QUI TRAVAILLENT ENSEMBLE ----------
    -- Règle du 06/10/2026 : même avec un autre chef, chacun sa feuille.
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-PCC','salarie','T-CHF2',
        'chantier','T-CH1','date',v_avhier,'debut','07:00','fin','15:00'))));
    res := chok._v(res,'Un chef ne saisit plus la journée d''un autre chef',
      r->>'codeErreur','PERSONNE_NON_RATTACHEE');
    -- Un intérimaire qui n'est pas chef ne saisit rien, même s'il se connecte.
    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-ITX','pin','5555'));
    res := chok._v(res,'Un intérimaire non chef n''a que la consultation', r->>'role','salarie');
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',r->>'jeton','table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-PIX','salarie','T-ITX',
        'chantier','T-CH1','date',v_avhier,'debut','07:00','fin','15:00'))));
    res := chok._v(res,'Il ne peut pas saisir d''heures', r->>'ok','false');

    -- ---------- 13 ter. CLIENT D'UN CHANTIER ----------
    -- Un chef corrige le client d'un chantier qui n'est pas le sien…
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','chantiers',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-CH2','nom','RENOMMÉ PAR UN AUTRE',
        'client','Eiffage','chef','T-CHEF'))));
    res := chok._v(res,'Un chef corrige le client du chantier d''un autre', 
      (select client from chok.chantiers where id='T-CH2'), 'Eiffage');
    res := chok._v(res,'Mais ne le renomme pas',
      (select nom from chok.chantiers where id='T-CH2'), 'TEST Chantier autre');
    res := chok._v(res,'Ni ne se l''approprie',
      (select chef from chok.chantiers where id='T-CH2'), 'T-CHF2');
    insert into chok.chantiers(id,nom,ville,actif,chef) values ('T-CHC','TEST Chantier commun','Paris',true,'');
    perform public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','chantiers',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-CHC','client','Vinci','chef',''))));
    res := chok._v(res,'Un chantier commun reste commun quand un chef change son client',
      (select coalesce(chef,'') || '/' || client from chok.chantiers where id='T-CHC'), '/Vinci');

    -- ---------- 13 quater. SAISIE SUR 5 JOURS ----------
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-J5','salarie','T-CHEF','chantier','T-CH1',
        'date', to_char((timezone('Europe/Paris',now()))::date - 5,'YYYY-MM-DD'),'debut','17:00','fin','19:00'))));
    res := chok._v(res,'Une saisie à J-5 est acceptée', r->>'ok', 'true');
    res := chok._v(res,'Le serveur garde 4 jours de marge pour le hors réseau (9 jours)',
      chok.config_lire('joursSaisieServeur'), '9');

    -- ---------- 14. LE BLOCAGE NE SE CONTOURNE PAS ----------
    -- Les codes sont des années de naissance : une soixantaine de valeurs.
    -- Changer le « rôle » envoyé à chaque essai donnait un compteur neuf.
    insert into chok.salaries(id,nom,poste,interne,code) values
      ('T-BRUT','TEST Force brute','Manœuvre',true,'1977');
    for k in 1..5 loop
      perform public.chok_api(jsonb_build_object('action','connexion','personneId','T-BRUT',
                                                 'role','x'||k,'pin','19'||(50+k)));
    end loop;
    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-BRUT','pin','1977'));
    res := chok._v(res,'Changer le « rôle » à chaque essai ne contourne plus le blocage',
      r->>'codeErreur', 'BLOQUE');
    -- Chaque nouvel échec double le blocage : 15 min, puis 30 min…
    update chok.blocages set jusqua = now() - interval '1 second' where cle = 'blocage_p_T-BRUT';
    perform public.chok_api(jsonb_build_object('action','connexion','personneId','T-BRUT','pin','1901'));
    res := chok._v(res,'Le 6e échec bloque 30 minutes (le double)',
      (select (jusqua between now() + interval '29 minutes' and now() + interval '31 minutes')::text
         from chok.blocages where cle = 'blocage_p_T-BRUT'), 'true');
    -- La fin d'un blocage n'efface pas la mémoire des échecs.
    update chok.blocages set jusqua = now() - interval '1 second' where cle = 'blocage_p_T-BRUT';
    perform chok.menage();
    res := chok._v(res,'Le compteur survit à la fin du blocage (30 jours)',
      (select echecs::text from chok.blocages where cle = 'blocage_p_T-BRUT'), '6');
    -- Un bon code remet le compteur à zéro.
    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-BRUT','pin','1977'));
    res := chok._v(res,'Le bon code, hors période de blocage, passe', r->>'ok', 'true');
    res := chok._v(res,'Et efface le compteur',
      (select count(*)::text from chok.blocages where cle = 'blocage_p_T-BRUT'), '0');

    -- ---------- 15. QUI PEUT SE CONNECTER ----------
    insert into chok.salaries(id,nom,poste,interne,code) values
      ('T-ZERO','TEST Sans code','Manœuvre',true,'0000');
    res := chok._v(res,'Le code « 0000 » posé par défaut n''ouvre rien',
      (public.chok_api(jsonb_build_object('action','connexion','personneId','T-ZERO','pin','0000')))->>'codeErreur',
      'CODE_NON_DEFINI');
    res := chok._v(res,'Un intérimaire sans accès ne se connecte pas, même avec son code',
      (public.chok_api(jsonb_build_object('action','connexion','personneId','T-INO','pin','8888')))->>'codeErreur',
      'ACCES_FERME');
    update chok.salaries set actif = false where id = 'T-BRUT';
    res := chok._v(res,'Une personne archivée ne se connecte plus',
      (public.chok_api(jsonb_build_object('action','connexion','personneId','T-BRUT','pin','1977')))->>'codeErreur',
      'ACCES_FERME');
    update chok.salaries set actif = true where id = 'T-BRUT';

    -- ---------- 16. CE QU'UN CHEF NE DÉCIDE PAS ----------
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-AUTO','salarie','T-CHEF',
        'chantier','T-CH1','date',v_avhier,'debut','08:00','fin','16:00',
        'valide',true,'creePar','T-CHF2','modifiePar','RH'))));
    res := chok._v(res,'Un chef ne peut pas valider lui-même ses heures',
      (select valide::text from chok.pointages where id='T-AUTO'), 'false');
    res := chok._v(res,'Ni se donner un autre auteur',
      (select "creePar" from chok.pointages where id='T-AUTO'), 'T-CHEF');
    res := chok._v(res,'Ni se faire passer pour la direction',
      (select coalesce("modifiePar",'') from chok.pointages where id='T-AUTO'), '');

    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','interimaires',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-FAUX','nom','TEST Faux chef',
        'poste','Chef d''équipe','agence','AG','code','1234','accesPlateforme',true,'chef','T-CHF2'))));
    res := chok._v(res,'Un chef peut ajouter un intérimaire à son équipe', r->>'ok', 'true');
    res := chok._v(res,'Mais pas lui donner un code',
      (select code from chok.interimaires where id='T-FAUX'), '0000');
    res := chok._v(res,'Ni lui ouvrir l''accès à l''application',
      (select "accesPlateforme"::text from chok.interimaires where id='T-FAUX'), 'false');
    res := chok._v(res,'Ni en faire un chef d''équipe',
      (select poste from chok.interimaires where id='T-FAUX'), 'Manœuvre');
    res := chok._v(res,'Il est rattaché à celui qui l''a créé',
      (select chef from chok.interimaires where id='T-FAUX'), 'T-CHEF');

    -- Un intérimaire sans chef : seules la direction et son futur chef y
    -- touchent, pas les trente autres.
    insert into chok.interimaires(id,nom,poste,agence,code,chef)
      values ('T-ILIB','TEST Intérim libre','Manœuvre','AG','0000','');
    insert into chok.pointages(id,salarie,chantier,date,debut,fin,"creePar")
      values ('T-PLIB','T-ILIB','T-CH1',v_hier,'08:00','16:00','');
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'suppressions', jsonb_build_array('T-PLIB')));
    res := chok._v(res,'Un chef ne supprime pas les heures d''un intérimaire sans chef',
      r->>'codeErreur', 'SAISIE_AUTRUI');

    -- ---------- 16 bis. PENSE-BÊTE ET MOIS DE PAIE (s3.1) ----------
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jrh,'table','interimaires',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-ITM','note','Rappeler l''agence'))));
    perform public.chok_api(jsonb_build_object('action','enregistrer','jeton',jrh,'table','salaries',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-CHEF','note','Visite médicale'))));
    res := chok._v(res,'La direction écrit un pense-bête',
      (select note from chok.interimaires where id='T-ITM') || ' / ' ||
      (select note from chok.salaries where id='T-CHEF'), 'Rappeler l''agence / Visite médicale');
    d := public.chok_api(jsonb_build_object('action','charger','jeton',jchef))->'donnees';
    res := chok._v(res,'Le chef ne reçoit aucun pense-bête (ni le sien, ni celui de ses intérimaires)',
      (position('"note"' in (d->'salaries')::text) + position('"note"' in (d->'interimaires')::text))::text, '0');
    d := public.chok_api(jsonb_build_object('action','charger','jeton',jsal));
    res := chok._v(res,'Le salarié ne reçoit pas de pense-bête',
      (d->>'ok') || ' ' || (position('"note"' in d::text))::text, 'true 0');
    perform public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','interimaires',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-ITM','nom','TEST Intérim','note','effacé'))));
    res := chok._v(res,'Un chef ne peut pas écrire ni effacer le pense-bête',
      (select note from chok.interimaires where id='T-ITM'), 'Rappeler l''agence');
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jchef,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-PMP','salarie','T-ITM','chantier','T-CH1',
        'date',v_avhier,'debut','05:00','fin','06:00','pause',0,'moisPaie','2099-01'))));
    res := chok._v(res,'Un chef ne choisit pas le mois de paie',
      coalesce((select '[' || coalesce("moisPaie",'') || ']' from chok.pointages where id='T-PMP'),
               '(ligne absente) '||r::text), '[]');
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jrh,'table','pointages',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-PMR','salarie','T-SAL','chantier','T-CH1',
        'date','2026-01-03','debut','08:00','fin','12:00','pause',0,'valide',true,
        'commentaire','Régularisation : oubli','moisPaie','2026-02'))));
    res := chok._v(res,'La direction régularise sur le mois de paie de son choix',
      coalesce((select "moisPaie" from chok.pointages where id='T-PMR'),'(absente) '||coalesce(r->>'erreur','')), '2026-02');

    -- ---------- 17. UN ACCÈS RETIRÉ L'EST TOUT DE SUITE ----------
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jrh,'table','salaries',
      'upserts', jsonb_build_array(jsonb_build_object('id','T-SAL','code','3334'))));
    res := chok._v(res,'Nouveau code : l''ancienne session du salarié est coupée',
      (public.chok_api(jsonb_build_object('action','charger','jeton',jsal)))->>'expire', 'true');
    -- T-SAL a été bloqué au § 13 : lui donner un code le débloque.
    res := chok._v(res,'Et son blocage est levé : il entre avec le nouveau code',
      (public.chok_api(jsonb_build_object('action','connexion','personneId','T-SAL','pin','3334')))->>'ok',
      'true');

    r := public.chok_api(jsonb_build_object('action','connexion','personneId','T-CHF2','pin','2222'));
    perform public.chok_api(jsonb_build_object('action','deconnexion','jeton',r->>'jeton'));
    res := chok._v(res,'DÉCONNEXION annule le jeton sur le serveur',
      (public.chok_api(jsonb_build_object('action','charger','jeton',r->>'jeton')))->>'expire', 'true');

    res := chok._v(res,'Une session direction dure 12 h, pas 7 jours',
      (select (expire < now() + interval '13 hours')::text from chok.sessions
        where jeton = jrh::uuid), 'true');

    -- ---------- 18. CODE DIRECTION ----------
    res := chok._v(res,'Code direction trop court refusé',
      (public.chok_api(jsonb_build_object('action','reglages','jeton',jrh,'pinRH','1234')))->>'ok', 'false');

    -- ---------- 19. COPIE AVANT TOUT EFFACEMENT ----------
    select count(*) into n from chok.sauvegardes where motif = 'avant reprise';
    r := public.chok_api(jsonb_build_object('action','importerTout','jeton',jrh,'remplacer',true,
      'pinRH','12',
      'donnees', jsonb_build_object('salaries', jsonb_build_array(
        jsonb_build_object('id','T-IMP','nom','TEST Import','code','4321')))));
    res := chok._v(res,'Une reprise « remplacer » fait une copie avant d''écrire',
      ((select count(*) from chok.sauvegardes where motif = 'avant reprise') = n + 1)::text, 'true');
    res := chok._v(res,'Et n''impose pas un code direction invalide',
      (chok.config_lire('pinRH') = '12')::text, 'false');

    insert into chok.absences(id,salarie,"dateDebut","dateFin",type)
      select 'T-B'||g, 'T-SAL', '2026-06-01', '2026-06-01', 'CP' from generate_series(1,12) g;
    select count(*) into n from chok.sauvegardes where motif = 'avant suppression';
    r := public.chok_api(jsonb_build_object('action','enregistrer','jeton',jrh,'table','absences',
      'confirmerSuppressionMassive', true,
      'suppressions', (select jsonb_agg(id) from chok.absences where id like 'T-B%')));
    res := chok._v(res,'Une suppression en masse, même confirmée, est précédée d''une copie',
      ((select count(*) from chok.sauvegardes where motif = 'avant suppression') = n + 1)::text, 'true');

    -- ---------- 20. BLOCAGE DIRECTION (en dernier : il ferme l'accès) ----------
    for k in 1..5 loop
      perform public.chok_api(jsonb_build_object('action','connexion','role','rh',
                                                 'personneId','X'||k,'pin','0000'||k));
    end loop;
    res := chok._v(res,'Changer d''identifiant ne contourne pas le blocage direction',
      (public.chok_api(jsonb_build_object('action','connexion','role','rh',
         'pin', chok.config_lire('pinRH'))))->>'codeErreur', 'BLOQUE');

    -- ======== annulation volontaire de TOUT ce qui précède ========
    raise exception '__CONTROLE_TERMINE__';

  exception when others then
    if sqlerrm <> '__CONTROLE_TERMINE__' then
      res := chok._v(res, 'INTERRUPTION : ' || sqlerrm, 'erreur', 'aucune erreur');
    end if;
  end;

  return query
    select (ord)::integer,
           case when (e->>'ok')::boolean then '✅' else '❌ ÉCHEC' end,
           e->>'libelle', e->>'attendu', e->>'obtenu'
      from jsonb_array_elements(res) with ordinality as q(e, ord);
end $$;

-- Ces deux fonctions de contrôle ne doivent être appelables par personne
-- d'autre que vous, depuis cet éditeur.
revoke all on function chok._v(jsonb,text,text,text) from public, anon, authenticated;
revoke all on function chok.controle() from public, anon, authenticated;

-- ============================================================
--  RÉSULTAT DÉTAILLÉ
-- ============================================================
select * from chok.controle();

-- ============================================================
--  VERDICT
-- ============================================================
select count(*) filter (where resultat = '✅')  as reussis,
       count(*) filter (where resultat <> '✅') as echecs,
       case when count(*) filter (where resultat <> '✅') = 0
            then '✅ Serveur conforme : cloisonnement, droits et sauvegardes vérifiés.'
            else '❌ ANOMALIE — ne mettez pas en service, signalez les lignes en échec.'
       end as verdict
  from chok.controle();

-- Contrôle que rien n'a survécu : ces trois nombres doivent être à 0.
select (select count(*) from chok.salaries     where id like 'T-%') as salaries_de_test,
       (select count(*) from chok.pointages    where id like 'T-%') as pointages_de_test,
       (select count(*) from chok.sauvegardes
         where motif = 'avant remise à zéro')                        as sauvegardes_de_test;
