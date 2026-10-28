-- ============================================================
--  CHOK BÉTON — SERVEUR SUPABASE
--  Version s3.3 (la fonction chok.version() fait foi)
--
--  À COLLER EN UNE SEULE FOIS dans : Supabase → SQL Editor → New query
--  puis cliquer sur « Run ». Le script est REJOUABLE sans risque :
--  il ne détruit aucune donnée existante.
--
--  ------------------------------------------------------------
--  PRINCIPE DE SÉCURITÉ
--  ------------------------------------------------------------
--  1. Toutes les tables vivent dans le schéma « chok », qui n'est PAS
--     exposé par l'API. La clé publique présente dans l'application ne
--     peut donc ni les lire ni les écrire, même en connaissant leur nom.
--  2. RLS est activée sur chaque table SANS aucune politique : même en
--     cas d'exposition accidentelle du schéma, l'accès direct reste nul.
--  3. Un SEUL point d'entrée est publié : public.chok_api(p jsonb).
--     Il vérifie le code personnel, crée un jeton de session, et ne
--     renvoie à chacun que ce qui le concerne.
--  4. chok_api est en SECURITY DEFINER — c'est indispensable pour qu'il
--     puisse lire les tables verrouillées — mais il revérifie SYSTÉMA-
--     TIQUEMENT l'identité de l'appelant. Aucune branche ne renvoie de
--     données sans jeton valide, hormis la liste des noms (sans code).
-- ============================================================

-- ============================================================
--  GARDE-FOU : LES ACCENTS SONT-ILS ARRIVÉS INTACTS ?
--
--  Un copier-coller mal encodé change « é » en « √© » ou « Ã© ». Le
--  script tournait quand même, avec des libellés faux : le 30/09/2026,
--  « Chef d'équipe » et « Manœuvre » ne se reconnaissaient plus, et les
--  31 salariés sont passés « Manœuvre » d'un coup. Désormais, au moindre
--  accent abîmé, le script s'arrête AVANT d'avoir rien touché.
-- ============================================================
do $$
begin
  if 'é' <> chr(233) or 'œ' <> chr(339) then
    raise exception 'ACCENTS ABÎMÉS AU COLLAGE — rien n''a été modifié. Recopiez le fichier depuis un éditeur de texte (TextEdit), pas depuis un aperçu.';
  end if;
end $$;

create schema if not exists chok;

-- ============================================================
--  1. TABLES
--  Les noms de colonnes reprennent EXACTEMENT ceux de l'application.
--  C'est volontaire : toute traduction camelCase / snake_case est une
--  source d'écritures perdues en silence. Ici, ce qui part du téléphone
--  est ce qui arrive dans la base, au caractère près.
-- ============================================================

create table if not exists chok.salaries (
  id       text primary key,
  nom      text default '',
  poste    text default '',
  equipe   text default '',
  interne  boolean default true,
  code     text default '0000',
  conges   numeric default 30,
  -- Une personne qui quitte l'entreprise est ARCHIVÉE, pas supprimée :
  -- ses heures passées doivent rester sur les rapports de paie.
  actif    boolean default true
);

create table if not exists chok.interimaires (
  id                text primary key,
  nom               text default '',
  poste             text default '',
  agence            text default '',
  "accesPlateforme" boolean default false,
  code              text default '0000',
  chef              text default '',
  -- Idem : un intérimaire dont la mission est finie est archivé.
  actif             boolean default true
);

create table if not exists chok.chantiers (
  id      text primary key,
  nom     text default '',
  ville   text default '',
  client  text default '',
  couleur text default '',
  actif   boolean default true,
  chef    text default ''
);

create table if not exists chok.pointages (
  id                     text primary key,
  salarie                text default '',
  chantier               text default '',
  date                   text default '',   -- 'AAAA-MM-JJ' en texte : aucun décalage de fuseau possible
  debut                  text default '',
  fin                    text default '',
  pause                  numeric default 0,
  commentaire            text default '',
  deplacement            boolean default false,
  valide                 boolean default false,
  interim                boolean default false,
  "valideParInterimaire" boolean default false,
  "horodatageValidation" text default '',
  "chefNom"              text default '',
  "creePar"              text default '',
  "modifiePar"           text default '',
  "modifieLe"            text default '',
  -- Pourquoi ma journée diffère de celle déclarée par le collègue.
  -- Exigé par le serveur dès qu'on s'écarte d'une saisie d'équipe :
  -- un écart sans explication est indiscernable d'une erreur de frappe,
  -- et c'est la direction qui tranche à l'aveugle en fin de mois.
  "motifEcart"           text default ''
);
alter table chok.pointages add column if not exists "motifEcart" text default '';
-- Mois de paie d'une régularisation (« 2026-10 »). Vide = le mois de la
-- date, comme toujours. Rempli par la direction quand elle rattrape une
-- journée d'un mois déjà clos : le samedi de septembre oublié est payé
-- sur octobre, sans rouvrir le rapport de septembre déjà transmis.
alter table chok.pointages add column if not exists "moisPaie" text default '';
-- Panier repas (salariés). Vide = automatique : tout jour travaillé donne
-- un panier. « non » = retiré par la direction (repas fourni, etc.).
alter table chok.pointages add column if not exists panier text default '';
create index if not exists idx_pointages_date    on chok.pointages(date);
create index if not exists idx_pointages_salarie on chok.pointages(salarie);

create table if not exists chok.absences (
  id            text primary key,
  salarie       text default '',
  "dateDebut"   text default '',
  "dateFin"     text default '',
  type          text default '',
  "typeLabel"   text default '',
  "typeIcone"   text default '',
  commentaire   text default '',
  "saisieParRH" boolean default false,
  "saisieDate"  text default ''
);
create index if not exists idx_absences_salarie on chok.absences(salarie);

-- Bases installées avant l'archivage : la colonne est ajoutée, tout le
-- monde reste actif. Aucune donnée n'est touchée.
alter table chok.salaries     add column if not exists actif boolean default true;
alter table chok.interimaires add column if not exists actif boolean default true;
update chok.salaries     set actif = true where actif is null;
-- Pense-bête de la direction sur chaque personne. Il ne quitte jamais la
-- direction : retiré de tout ce qu'un chef ou un salarié reçoit.
alter table chok.salaries     add column if not exists note text default '';
alter table chok.interimaires add column if not exists note text default '';
-- ÉTAT DE PAIE MENSUEL : matricule saisi par la direction, et les montants
-- tapés à la main chaque mois (prime, acomptes, prêts, Navigo…), rangés par
-- mois : {"2026-10": {"prime": "150", …}}. Réservé à la direction.
alter table chok.salaries add column if not exists matricule text default '';
alter table chok.salaries add column if not exists paie jsonb default '{}'::jsonb;
update chok.interimaires set actif = true where actif is null;

create table if not exists chok.config (
  cle    text primary key,
  valeur text default ''
);

create table if not exists chok.journal (
  id         bigserial primary key,
  horodatage timestamptz default now(),
  action     text,
  role       text,
  personne   text,
  cible      text,
  details    text
);
create index if not exists idx_journal_horodatage on chok.journal(horodatage desc);

-- Sessions : remplace le cache de jetons d'Apps Script.
create table if not exists chok.sessions (
  jeton        uuid primary key,
  role         text not null,
  "personneId" text default '',
  cree         timestamptz default now(),
  expire       timestamptz not null
);

-- Blocage après codes erronés répétés.
create table if not exists chok.blocages (
  cle    text primary key,
  echecs integer default 0,
  jusqua timestamptz
);
-- Mémoire des échecs, distincte de la fin du blocage. Les codes sont des
-- années de naissance : une soixantaine de valeurs possibles. Si le
-- compteur repartait de zéro à la fin de chaque blocage, il suffirait
-- d'essayer 4 années toutes les 15 minutes pour tomber sur la bonne dans
-- la journée. Le compteur est donc gardé 30 jours après le dernier échec,
-- et chaque nouvel échec double la durée du blocage.
alter table chok.blocages add column if not exists oubli timestamptz;

-- Sauvegardes internes : une copie complète, en base, indépendante des
-- sauvegardes de l'hébergeur. C'est le filet qui garantit qu'aucune
-- remise à zéro ni fausse manœuvre ne peut faire disparaître un mois.
create table if not exists chok.sauvegardes (
  id      bigserial primary key,
  cree    timestamptz default now(),
  motif   text,
  lignes  integer,
  contenu jsonb
);

-- ============================================================
--  2. VERROUILLAGE
--  RLS active, aucune politique : personne n'accède aux tables
--  autrement que par les fonctions ci-dessous.
-- ============================================================

-- Note : on active RLS sans « FORCE ». FORCE l'appliquerait aussi au
-- propriétaire des tables, donc à chok_api lui-même, qui ne pourrait plus
-- rien lire. La protection recherchée porte sur la clé publique de
-- l'application, qui n'est pas propriétaire : ENABLE suffit et la bloque.
do $$
declare t text;
begin
  foreach t in array array['salaries','interimaires','chantiers','pointages','absences',
                           'config','journal','sessions','blocages','sauvegardes']
  loop
    execute format('alter table chok.%I enable row level security', t);
  end loop;
end $$;

revoke all on schema chok from public, anon, authenticated;
revoke all on all tables    in schema chok from public, anon, authenticated;
revoke all on all sequences in schema chok from public, anon, authenticated;
revoke all on all functions in schema chok from public, anon, authenticated;

-- ============================================================
--  3. OUTILS INTERNES
-- ============================================================

/* Numéro du script installé.
   Il DOIT changer à chaque version du fichier. Figé à « s1.0 » depuis le
   début, il ne permettait pas de savoir si un script relancé était bien
   arrivé — on a cherché longtemps une panne de serveur alors que la
   question était « quelle version tourne, au juste ? ». */
create or replace function chok.version() returns text
language sql immutable as $$ select 's3.3'::text $$;

/* Conversion tolérante vers un vrai booléen.
   Reprend la règle du serveur précédent : toute valeur inattendue vaut
   « non ». Sans cela, la chaîne "false" est considérée comme vraie et
   tout le monde apparaît logé, tous les pointages validés. */
create or replace function chok.vers_bool(v jsonb) returns boolean
language plpgsql immutable as $$
declare s text;
begin
  if v is null or jsonb_typeof(v) = 'null' then return false; end if;
  if jsonb_typeof(v) = 'boolean' then return (v)::text = 'true'; end if;
  if jsonb_typeof(v) = 'number'  then return (v#>>'{}')::numeric <> 0; end if;
  s := lower(trim(v #>> '{}'));
  if s in ('true','vrai','1','oui','yes') then return true; end if;
  return false;
end $$;

/* Comparaison de codes : STRICTE.
   L'ancien serveur tolérait la perte du zéro initial, parce que Google
   Sheets transformait « 010126 » en 10126. Ce défaut n'existe plus ici :
   les codes sont du texte et restent intacts.
   Cette tolérance est devenue dangereuse depuis que les codes peuvent
   faire 4 à 8 chiffres : comparés comme des nombres, « 00001234 » et
   « 1234 » valent la même chose, et un code long n'offrirait aucune
   protection supplémentaire. */
create or replace function chok.meme_code(saisi text, attendu text) returns boolean
language plpgsql immutable as $$
declare a text := trim(coalesce(saisi,'')); b text := trim(coalesce(attendu,''));
begin
  if a = '' or b = '' then return false; end if;
  return a = b;
end $$;

create or replace function chok.config_lire(k text) returns text
language sql stable as $$ select valeur from chok.config where cle = k $$;

create or replace function chok.config_ecrire(k text, v text) returns void
language sql as $$
  insert into chok.config(cle, valeur) values (k, v)
  on conflict (cle) do update set valeur = excluded.valeur;
$$;

create or replace function chok.noter(p_action text, p_role text, p_personne text,
                                      p_cible text, p_details text) returns void
language sql as $$
  insert into chok.journal(action, role, personne, cible, details)
  values (p_action, p_role, p_personne, p_cible, p_details);
$$;

/* Date du jour à Paris, moins N jours, au format 'AAAA-MM-JJ'. */
create or replace function chok.iso_il_y_a(n integer) returns text
language sql stable as $$
  select to_char((timezone('Europe/Paris', now()))::date - n, 'YYYY-MM-DD');
$$;

/* Clé de comparaison d'un nom : insensible aux accents, à la casse et aux
   espaces multiples. Indispensable — « ADOU Stéphane » saisi dans Word et
   dans l'application n'ont pas le même codage d'accent. */
create or replace function chok.cle_nom(nom text) returns text
language sql immutable as $$
  select upper(regexp_replace(
    translate(coalesce(nom,''),
      'àáâãäåèéêëìíîïòóôõöùúûüýÿñçÀÁÂÃÄÅÈÉÊËÌÍÎÏÒÓÔÕÖÙÚÛÜÝÑÇ',
      'aaaaaaeeeeiiiiooooouuuuyyncAAAAAAEEEEIIIIOOOOOUUUUYNC'),
    '\s+', ' ', 'g'));
$$;

/* Une personne est « chef d'équipe » d'après son poste. */
create or replace function chok.est_chef(poste text) returns boolean
language sql immutable as $$ select position('chef' in lower(coalesce(poste,''))) > 0 $$;

/* Fiche d'une personne, salarié ou intérimaire. */
/* Un chef peut-il déclarer les heures de cette personne ?
   Trois cas : lui-même, n'importe quel salarié de l'entreprise (les équipes
   se mélangent sur les chantiers), et les intérimaires qui lui sont
   rattachés ou qui ne le sont à personne. Jamais l'intérimaire d'un autre.

   Écrite ici plutôt que recopiée : la règle était énoncée à trois endroits,
   et l'un d'eux lisait la personne au mauvais endroit. */
/* RÈGLE DU 06/10/2026 : chaque chef remplit SA feuille d'heures, et n'y
   ajoute que SES intérimaires. Il ne déclare plus les heures d'un autre
   salarié : deux chefs arrivés à des heures différentes avaient une seule
   feuille pour deux, et les doubles saisies se payaient en double. */
create or replace function chok.chef_peut_declarer(p_chef text, p_personne text)
returns boolean language sql stable as $$
  select p_personne is null            -- rien à vérifier : ligne inconnue
      or p_personne = p_chef
      or exists (select 1 from chok.interimaires i
                  where i.id = p_personne
                    -- RATTACHÉ À CE CHEF, et à lui seul. Un intérimaire sans
                    -- chef n'apparaissait auparavant chez tout le monde :
                    -- trente et un chefs pouvaient déclarer les mêmes heures.
                    and i.chef = p_chef
                    -- Un intérimaire lui-même CHEF D'ÉQUIPE déclare ses
                    -- propres heures depuis son téléphone. Le proposer à un
                    -- autre chef, c'est inviter à la double déclaration.
                    and not chok.est_chef(i.poste));
$$;

/* Deux plages horaires d'un même jour se chevauchent-elles ? Une fin
   inférieure ou égale au début est un poste de nuit (ou de 24 h). */
create or replace function chok.chevauche(d1 text, f1 text, d2 text, f2 text)
returns boolean language plpgsql immutable as $$
declare a1 int; b1 int; a2 int; b2 int;
begin
  if coalesce(d1,'') !~ '^\d{1,2}:\d{2}$' or coalesce(f1,'') !~ '^\d{1,2}:\d{2}$'
     or coalesce(d2,'') !~ '^\d{1,2}:\d{2}$' or coalesce(f2,'') !~ '^\d{1,2}:\d{2}$' then
    return true;                       -- horaires illisibles : on considère que oui
  end if;
  a1 := split_part(d1,':',1)::int*60 + split_part(d1,':',2)::int;
  b1 := split_part(f1,':',1)::int*60 + split_part(f1,':',2)::int;
  a2 := split_part(d2,':',1)::int*60 + split_part(d2,':',2)::int;
  b2 := split_part(f2,':',1)::int*60 + split_part(f2,':',2)::int;
  if b1 <= a1 then b1 := b1 + 1440; end if;
  if b2 <= a2 then b2 := b2 + 1440; end if;
  -- Un poste de nuit déborde sur le lendemain matin : on compare aussi
  -- chaque plage décalée d'une journée.
  return (a1 < b2 and a2 < b1)
      or (a1 < b2 + 1440 and a2 + 1440 < b1)
      or (a1 + 1440 < b2 and a2 < b1 + 1440);
end $$;

create or replace function chok.trouver_personne(pid text) returns jsonb
language plpgsql stable as $$
declare r jsonb;
begin
  if coalesce(pid,'') = '' then return null; end if;
  select to_jsonb(t) into r from chok.salaries t where t.id = pid;
  if r is not null then return r; end if;
  select to_jsonb(t) into r from chok.interimaires t where t.id = pid;
  return r;
end $$;

/* Contenu complet d'une table, en tableau JSON. */
create or replace function chok.lire(t text) returns jsonb
language plpgsql stable as $$
declare r jsonb;
begin
  if t not in ('salaries','interimaires','chantiers','pointages','absences') then
    raise exception 'Table non autorisée : %', t;
  end if;
  -- Les listes de personnes et de chantiers sortent dans l'ordre alphabétique.
  if t in ('salaries','interimaires','chantiers') then
    execute format('select coalesce(jsonb_agg(to_jsonb(x) order by chok.cle_nom(x.nom)),'
                   ' ''[]''::jsonb) from chok.%I x', t) into r;
  else
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from chok.%I x', t) into r;
  end if;
  return r;
end $$;

/* Normalise un objet reçu du téléphone : booléens et nombres sûrs.
   Une case décochée arrive parfois en "" ou "false" ; sans cette étape
   l'insertion échoue ou enregistre l'inverse de ce qui a été saisi. */
create or replace function chok.normaliser(t text, o jsonb) returns jsonb
language plpgsql stable as $$
declare
  bools text[] := case t
    when 'salaries'     then array['interne','actif']
    when 'interimaires' then array['accesPlateforme','actif']
    when 'chantiers'    then array['actif']
    when 'pointages'    then array['deplacement','valide','interim','valideParInterimaire']
    when 'absences'     then array['saisieParRH']
    else array[]::text[] end;
  nums text[] := case t
    when 'salaries' then array['conges']
    when 'pointages' then array['pause']
    else array[]::text[] end;
  c text; r jsonb := o; v_def boolean;
begin
  -- Ce qui est fourni est converti sans ambiguïté : la chaîne « false »
  -- vaut non, et non pas oui.
  foreach c in array bools loop
    if r ? c then r := jsonb_set(r, array[c], to_jsonb(chok.vers_bool(r->c))); end if;
  end loop;

  -- Ce qui est ABSENT reçoit le défaut déclaré sur la colonne elle-même.
  -- L'écriture passe par jsonb_populate_record : toute clé manquante y
  -- devient un vide EXPLICITE, qui court-circuite le défaut de la table.
  -- Une case non cochée se rangeait donc en base comme « on ne sait pas »
  -- au lieu de « non » — deux choses très différentes au moment de compter
  -- les déplacements ou de savoir qui est encore actif.
  foreach c in array bools loop
    if not (r ? c) then
      select pg_get_expr(d.adbin, d.adrelid) = 'true' into v_def
        from pg_attribute a
        join pg_attrdef  d on d.adrelid = a.attrelid and d.adnum = a.attnum
       where a.attrelid = ('chok.' || quote_ident(t))::regclass
         and a.attname  = c;
      r := jsonb_set(r, array[c], to_jsonb(coalesce(v_def, false)));
    end if;
  end loop;
  foreach c in array nums loop
    if r ? c then
      r := jsonb_set(r, array[c],
             to_jsonb(coalesce(nullif(trim(r->>c), '')::numeric, 0)));
    end if;
  end loop;
  return r;
end $$;

/* Écriture d'une ligne : fusion avec l'existant.
   Seules les colonnes réellement envoyées sont modifiées — une saisie
   partielle ne peut pas effacer le reste de la ligne par omission. */
create or replace function chok.ecrire_ligne(t text, o jsonb) returns text
language plpgsql as $$
declare ex jsonb; fusion jsonb; vid text := o->>'id';
begin
  if coalesce(vid,'') = '' then return 'ignore'; end if;
  execute format('select to_jsonb(x) from chok.%I x where x.id = $1', t) into ex using vid;
  fusion := chok.normaliser(t, coalesce(ex, '{}'::jsonb) || o);
  if ex is null then
    execute format('insert into chok.%I select * from jsonb_populate_record(null::chok.%I, $1)', t, t)
      using fusion;
    return 'ajout';
  else
    execute format('delete from chok.%I where id = $1', t) using vid;
    execute format('insert into chok.%I select * from jsonb_populate_record(null::chok.%I, $1)', t, t)
      using fusion;
    return 'maj';
  end if;
end $$;

/* Copie complète de toutes les données métier.
   Le paramètre s'appelle p_motif et non motif : une table de cette fonction
   possède une colonne « motif », et PostgreSQL refuse de deviner lequel des
   deux on désigne. */
create or replace function chok.sauvegarde_complete(p_motif text) returns text
language plpgsql as $$
declare v_contenu jsonb; n integer; etiquette text;
begin
  v_contenu := jsonb_build_object(
    'salaries',     chok.lire('salaries'),
    'interimaires', chok.lire('interimaires'),
    'chantiers',    chok.lire('chantiers'),
    'pointages',    chok.lire('pointages'),
    'absences',     chok.lire('absences'));
  n := jsonb_array_length(v_contenu->'pointages') + jsonb_array_length(v_contenu->'absences')
     + jsonb_array_length(v_contenu->'salaries')  + jsonb_array_length(v_contenu->'interimaires')
     + jsonb_array_length(v_contenu->'chantiers');
  insert into chok.sauvegardes(motif, lignes, contenu) values (p_motif, n, v_contenu);
  etiquette := to_char(timezone('Europe/Paris', now()), 'YYYY-MM-DD HH24:MI') || ' (' || n || ' lignes)';
  -- On conserve les 60 dernières sauvegardes quotidiennes ; celles créées
  -- avant une remise à zéro ne sont jamais purgées.
  delete from chok.sauvegardes s
   where s.motif = 'quotidienne'
     and s.id not in (select x.id from chok.sauvegardes x where x.motif = 'quotidienne'
                      order by x.cree desc limit 60);
  -- Une copie « installation » est faite à chaque passage du script : sans
  -- limite, la table grossissait d'une copie complète par relance.
  delete from chok.sauvegardes s
   where s.motif = 'installation'
     and s.id not in (select x.id from chok.sauvegardes x where x.motif = 'installation'
                      order by x.cree desc limit 5);
  return etiquette;
end $$;

create or replace function chok.nb_taches() returns integer
language plpgsql stable as $$
declare n integer;
begin
  execute $q$ select count(*) from cron.job where jobname like 'chok_%' $q$ into n;
  return coalesce(n, 0);
exception when others then
  return 0;   -- pg_cron absent : ce n'est pas une erreur, c'est un réglage
end $$;

create or replace function chok.menage() returns void
language sql as $$
  delete from chok.sessions where expire < now();
  delete from chok.blocages where coalesce(oubli, jusqua) < now();
  delete from chok.journal  where horodatage < now() - interval '400 days';
$$;

-- Reliquat d'une piste abandonnée : les fiches de paie. Si la table existe
-- et qu'elle est vide, on la retire pour ne rien laisser traîner. Si elle
-- contient quelque chose, on n'y touche pas et on le signale.
do $$
declare n integer;
begin
  -- La table n'existe pas sur une base neuve : on sort sans bruit.
  if to_regclass('chok.fiches') is null then return; end if;

  execute 'select count(*) from chok.fiches' into n;
  if n > 0 then
    raise warning 'Table chok.fiches CONSERVÉE : elle contient % ligne(s). Videz-la puis relancez ce script.', n;
    return;
  end if;
  -- « cascade » : la table porte des index et une contrainte, un drop nu
  -- pouvait échouer et l'échec était avalé sans que rien ne le signale.
  drop table chok.fiches cascade;
  raise notice 'Table chok.fiches retirée (elle était vide).';
end $$;

-- ============================================================
--  4. LECTURE CLOISONNÉE
--  Chacun ne reçoit que ce qui le concerne. Le filtrage est fait ICI,
--  côté base : le téléphone ne reçoit jamais les données des autres,
--  donc il ne peut pas les afficher, même modifié.
-- ============================================================

create or replace function chok.charger(v_role text, v_pid text, p jsonb) returns jsonb
language plpgsql stable as $$
declare
  v_tout boolean := chok.vers_bool(p->'tout');
  v_depuis text;
  v_total integer;
  v_pointages jsonb; v_absences jsonb; v_chantiers jsonb;
  v_salaries jsonb; v_interim jsonb;
  v_meta jsonb; v_moi jsonb; v_est_interim boolean;
begin
  select count(*) into v_total from chok.pointages;

  if v_tout then
    v_depuis := null;
  else
    v_depuis := coalesce(nullif(p->>'depuis',''), chok.iso_il_y_a(90));
  end if;

  -- ---- DIRECTION : tout, y compris les codes d'accès ----
  if v_role = 'rh' then
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_pointages
      from chok.pointages x where v_depuis is null or x.date >= v_depuis;
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_absences
      from chok.absences x where v_depuis is null
        or coalesce(nullif(x."dateFin",''), x."dateDebut") >= v_depuis;
    v_meta := jsonb_build_object('depuis', v_depuis, 'tout', v_tout,
                'pointagesCharges', jsonb_array_length(v_pointages), 'pointagesTotal', v_total);
    return jsonb_build_object('ok', true, 'role', v_role, 'meta', v_meta,
      'donnees', jsonb_build_object(
        'salaries',     chok.lire('salaries'),
        'interimaires', chok.lire('interimaires'),
        'chantiers',    chok.lire('chantiers'),
        'pointages',    v_pointages,
        'absences',     v_absences));
  end if;

  -- ---- CHEF D'ÉQUIPE ----
  if v_role = 'chef' then
    -- Ses intérimaires : CEUX QUI LUI SONT RATTACHÉS, et eux seuls.
    select coalesce(jsonb_agg(to_jsonb(x) - 'code' - 'note' order by chok.cle_nom(x.nom)),'[]'::jsonb)
      into v_interim
      from chok.interimaires x
     -- « x.id = v_pid » : un chef d'équipe INTÉRIMAIRE doit toujours recevoir
     -- sa propre fiche. Sans elle, l'application ne saurait pas qu'il est
     -- intérimaire et rangerait ses heures parmi celles des salariés.
     where x.id = v_pid
        or (chok.chef_peut_declarer(v_pid, x.id) and coalesce(x.actif, true));

    -- Ses lignes : les siennes, celles de ses intérimaires, et celles
    -- qu'il a saisies pour un collègue — tant que ce collègue ne les a
    -- pas reprises. Une fois que l'intéressé a corrigé SA journée, elle
    -- cesse d'apparaître chez l'auteur : c'est la sienne, et seule la
    -- direction a besoin de savoir qu'elle a bougé.
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_pointages
      from chok.pointages x
     where (v_depuis is null or x.date >= v_depuis)
       and ( x.salarie = v_pid
             -- « RH » reste visible : une correction de la direction ne doit
             -- pas faire disparaître la ligne de l'écran du chef, qui la
             -- croirait perdue et la ressaisirait.
             or ( coalesce(x."creePar",'') = v_pid
                  and coalesce(x."modifiePar",'') in ('', v_pid, 'RH') )
             or exists (select 1 from chok.interimaires i
                         where i.id = x.salarie
                           and chok.chef_peut_declarer(v_pid, i.id)) );

    -- Les chantiers qu'il voit : les communs, les siens, ET CEUX OÙ IL A
    -- DES HEURES.
    --
    -- C'est ce dernier point qui manquait. Quand un chef déclarait un
    -- collègue sur son chantier, le collègue recevait bien ses heures,
    -- mais pas le chantier : il voyait une journée sans savoir où. Le
    -- lendemain, ne le trouvant pas dans sa liste, il le recréait — d'où
    -- deux fiches pour une seule adresse, orthographiées différemment,
    -- et un rapport impossible à totaliser par site.
    --
    -- Rien à cocher, rien à partager à la main : travailler quelque part
    -- suffit à le voir.
    select coalesce(jsonb_agg(to_jsonb(x) order by chok.cle_nom(x.nom)),'[]'::jsonb)
      into v_chantiers
      from chok.chantiers x
     where coalesce(x.chef,'') = ''
        or x.chef = v_pid
        or exists (select 1 from chok.pointages p
                    where p.chantier = x.id
                      and (p.salarie = v_pid or coalesce(p."creePar",'') = v_pid));

    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_absences
      from chok.absences x where x.salarie = v_pid
        and (v_depuis is null or coalesce(nullif(x."dateFin",''), x."dateDebut") >= v_depuis);

    -- Liste des collègues : nom et poste seulement, pour composer l'équipe.
    -- Aucun code, aucune heure, aucun solde de congés.
    select coalesce(jsonb_agg(
             case when x.id = v_pid then to_jsonb(x) - 'code' - 'note' - 'paie'
                  else jsonb_build_object('id', x.id, 'nom', x.nom,
                                          'poste', x.poste, 'interne', true) end
             order by chok.cle_nom(x.nom)
           ),'[]'::jsonb) into v_salaries from chok.salaries x
     -- Les personnes archivées ne sont plus proposées dans l'équipe. Le chef
     -- garde en revanche les lignes qu'il a saisies pour elles.
     where coalesce(x.actif, true) or x.id = v_pid;

    v_meta := jsonb_build_object('depuis', v_depuis, 'tout', v_tout,
                'pointagesCharges', jsonb_array_length(v_pointages), 'pointagesTotal', v_total);
    return jsonb_build_object('ok', true, 'role', v_role, 'meta', v_meta,
      'donnees', jsonb_build_object(
        'salaries', v_salaries, 'interimaires', v_interim, 'chantiers', v_chantiers,
        'pointages', v_pointages, 'absences', v_absences));
  end if;

  -- ---- SALARIÉ : strictement ses propres données ----
  v_est_interim := exists (select 1 from chok.interimaires where id = v_pid);
  v_moi := chok.trouver_personne(v_pid);
  if v_moi is not null then v_moi := v_moi - 'code' - 'note' - 'paie'; end if;

  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_pointages
    from chok.pointages x where x.salarie = v_pid
      and (v_depuis is null or x.date >= v_depuis);
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_absences
    from chok.absences x where x.salarie = v_pid
      and (v_depuis is null or coalesce(nullif(x."dateFin",''), x."dateDebut") >= v_depuis);

  v_meta := jsonb_build_object('depuis', v_depuis, 'tout', v_tout,
              'pointagesCharges', jsonb_array_length(v_pointages), 'pointagesTotal', v_total);
  return jsonb_build_object('ok', true, 'role', v_role, 'meta', v_meta,
    'donnees', jsonb_build_object(
      'salaries',     case when v_est_interim or v_moi is null then '[]'::jsonb
                          else jsonb_build_array(v_moi) end,
      'interimaires', case when v_est_interim and v_moi is not null then jsonb_build_array(v_moi)
                          else '[]'::jsonb end,
      -- SEULEMENT les chantiers où il a lui-même travaillé.
      -- On lui envoyait la liste ENTIÈRE, alors qu'il n'en a besoin que
      -- pour lire le nom du chantier en face de ses propres heures. Il
      -- voyait donc où travaillent les autres équipes, et les chantiers
      -- créés par des chefs qui ne le concernent pas — une fuite muette,
      -- que rien à l'écran ne laissait deviner.
      'chantiers',    (select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb)
                         from chok.chantiers c
                        where c.id in (select distinct x.chantier
                                         from chok.pointages x
                                        where x.salarie = v_pid
                                          and coalesce(x.chantier,'') <> '')),
      'pointages',    v_pointages,
      'absences',     v_absences));
end $$;

-- ============================================================
--  5. ÉCRITURE — droits, double déclaration, garde anti-suppression
-- ============================================================

create or replace function chok.enregistrer(v_role text, v_pid text, p jsonb) returns jsonb
language plpgsql as $$
declare
  v_table   text  := coalesce(p->>'table','');
  v_upserts jsonb := coalesce(p->'upserts','[]'::jsonb);
  v_suppr   jsonb := coalesce(p->'suppressions','[]'::jsonb);
  v_peut_ecrire   boolean;
  v_peut_supprimer boolean;
  v_existantes integer;
  v_nb_suppr integer := jsonb_array_length(v_suppr);
  v_o jsonb; v_ex jsonb; v_id text; v_res text;
  v_ajout integer := 0; v_maj integer := 0; v_del integer := 0;
  v_qui text; v_dej jsonb; v_cible text;
  v_nouv jsonb := '[]'::jsonb;
  v_revoquer text[] := '{}';
begin
  if v_table not in ('salaries','interimaires','chantiers','pointages','absences') then
    return jsonb_build_object('ok', false, 'erreur', 'Table non autorisée : ' || v_table);
  end if;

  v_peut_ecrire := case v_role
    when 'rh'   then true
    when 'chef' then v_table in ('pointages','chantiers','interimaires')
    else false end;
  v_peut_supprimer := v_role in ('rh','chef');

  if not v_peut_ecrire then
    perform chok.noter('refus_ecriture', v_role, v_pid, v_table, 'Droit insuffisant');
    return jsonb_build_object('ok', false,
      'erreur', 'Votre profil ne peut pas modifier « ' || v_table || ' ».');
  end if;
  if v_nb_suppr > 0 and not v_peut_supprimer then
    return jsonb_build_object('ok', false, 'erreur', 'Votre profil ne peut pas supprimer.');
  end if;

  -- Verrou : deux chefs qui envoient au même instant ne s'écrasent pas.
  perform pg_advisory_xact_lock(hashtext('chok:' || v_table)::bigint);

  execute format('select count(*) from chok.%I', v_table) into v_existantes;

  -- ---- GARDE ANTI-PERTE DE DONNÉES ----
  if v_nb_suppr > 10 and v_nb_suppr > v_existantes * 0.5
     and not chok.vers_bool(p->'confirmerSuppressionMassive') then
    perform chok.noter('suppression_refusee', v_role, v_pid, v_table,
                       v_nb_suppr || ' lignes demandées sur ' || v_existantes);
    return jsonb_build_object('ok', false, 'codeErreur', 'SUPPRESSION_MASSIVE',
      'erreur', 'Suppression de ' || v_nb_suppr || ' lignes sur ' || v_existantes ||
                ' refusée par sécurité. Confirmation explicite requise.');
  end if;

  -- ============================================================
  --  UNE CORRECTION DE LA DIRECTION LAISSE SA MARQUE
  --
  --  L'écran RH posait lui-même « modifiePar : RH ». Une correction
  --  arrivée par un autre chemin — file d'attente, outil de diagnostic,
  --  reprise après incident — restait donc anonyme, et la ligne semblait
  --  n'avoir jamais été touchée. C'est le serveur qui doit en décider.
  -- ============================================================
  if v_role = 'rh' and v_table = 'pointages' then
    v_nouv := '[]'::jsonb;
    for v_o in select * from jsonb_array_elements(v_upserts) loop
      v_nouv := v_nouv || jsonb_build_array(
        case when exists (select 1 from chok.pointages x where x.id = v_o->>'id')
             then v_o || jsonb_build_object(
                    'modifiePar', 'RH',
                    'modifieLe', to_char(timezone('Europe/Paris', now()),
                                         'YYYY-MM-DD"T"HH24:MI:SS'))
             else v_o end);
    end loop;
    v_upserts := v_nouv;
  end if;

  -- ============================================================
  --  UN ACCÈS RETIRÉ L'EST TOUT DE SUITE
  --
  --  Changer le code d'une personne, son poste, l'archiver ou lui retirer
  --  l'accès ne servait à rien tant qu'elle restait connectée : sa session
  --  valait encore sept jours, avec ses anciens droits. On coupe donc ses
  --  sessions ouvertes. On efface aussi son blocage éventuel : donner un
  --  nouveau code à quelqu'un qui s'est bloqué, c'est le débloquer.
  -- ============================================================
  if v_role = 'rh' and v_table in ('salaries','interimaires') then
    for v_o in select * from jsonb_array_elements(v_upserts) loop
      execute format('select to_jsonb(x) from chok.%I x where x.id = $1', v_table)
        into v_dej using v_o->>'id';
      if v_dej is not null and (
           (v_o ? 'code'  and coalesce(v_o->>'code','')  <> coalesce(v_dej->>'code',''))
        or (v_o ? 'poste' and coalesce(v_o->>'poste','') <> coalesce(v_dej->>'poste',''))
        or (v_o ? 'actif' and chok.vers_bool(v_o->'actif') <> chok.vers_bool(v_dej->'actif'))
        or (v_o ? 'accesPlateforme'
            and chok.vers_bool(v_o->'accesPlateforme') <> chok.vers_bool(v_dej->'accesPlateforme'))
      ) then
        v_revoquer := v_revoquer || (v_o->>'id');
      end if;
    end loop;
    v_revoquer := v_revoquer || array(select jsonb_array_elements_text(v_suppr));
  end if;

  -- ============================================================
  --  CLOISONNEMENT EN ÉCRITURE POUR LES CHEFS
  -- ============================================================
  if v_role = 'chef' then

    if v_table = 'pointages' then
      -- Un chef déclare : ses heures, celles de ses intérimaires, et celles
      -- des salariés avec qui il travaille. Jamais l'intérimaire d'un autre.
      for v_o in select * from jsonb_array_elements(v_upserts) loop
        -- La personne visée n'est pas toujours dans l'envoi : une CORRECTION
        -- ne répète que le champ modifié. Ne lire que l'envoi revenait à
        -- croire que la ligne ne concernait personne, et à refuser au chef
        -- de corriger sa propre saisie — « heures de l'intérimaire d'un
        -- autre chef » alors qu'il rectifiait la sienne.
        select x.salarie into v_cible from chok.pointages x where x.id = v_o->>'id';
        v_cible := coalesce(nullif(v_o->>'salarie',''), v_cible);

        -- On vérifie AUSSI la personne déjà inscrite quand l'envoi en désigne
        -- une autre : sans cela, un chef pourrait s'approprier la ligne d'un
        -- collègue en la réécrivant à un nom qu'il a le droit de déclarer.
        if not chok.chef_peut_declarer(v_pid, v_cible)
           or not chok.chef_peut_declarer(v_pid,
                    (select x.salarie from chok.pointages x where x.id = v_o->>'id')) then
          perform chok.noter('refus_ecriture', v_role, v_pid, v_table,
                             'Pointage au nom d''une personne non rattachée');
          return jsonb_build_object('ok', false, 'codeErreur', 'PERSONNE_NON_RATTACHEE',
            'erreur', 'Vous ne pouvez pas déclarer les heures de l''intérimaire d''un autre chef.');
        end if;
      end loop;

      -- ---- LA RÈGLE DES 3 JOURS ----
      -- Le navigateur la fait déjà respecter, mais un contrôle qui ne vit
      -- que dans le navigateur n'est pas un contrôle : il suffit d'ouvrir
      -- les outils de développement pour le contourner. Le serveur tranche.
      --
      -- La tolérance est plus large que les 3 jours de l'écran (7 jours) :
      -- une saisie faite hors réseau sur un chantier peut rester plusieurs
      -- jours dans la file d'attente du téléphone. La refuser à son arrivée
      -- ferait perdre des heures réellement travaillées, ce qui est pire
      -- que le mal qu'on cherche à éviter.
      declare
        v_limite text := to_char((timezone('Europe/Paris', now()))::date
                                 - (coalesce(nullif(chok.config_lire('joursSaisieServeur'),'')::integer, 7)),
                                 'YYYY-MM-DD');
        v_demain text := to_char((timezone('Europe/Paris', now()))::date + 1, 'YYYY-MM-DD');
      begin
        for v_o in select * from jsonb_array_elements(v_upserts) loop
          -- On ne bloque que les CRÉATIONS : corriger une ligne ancienne
          -- déjà en base reste possible tant qu'elle n'est pas validée.
          if not exists (select 1 from chok.pointages where id = v_o->>'id') then
            if coalesce(v_o->>'date','') < v_limite then
              perform chok.noter('refus_date', v_role, v_pid, v_table,
                                 'Saisie trop ancienne : ' || coalesce(v_o->>'date','?'));
              return jsonb_build_object('ok', false, 'codeErreur', 'TROP_ANCIEN',
                'erreur', 'Les heures du ' || coalesce(v_o->>'date','?') ||
                          ' ne peuvent plus être saisies : la période est close. ' ||
                          'Contactez la direction, elle seule peut encore les enregistrer.');
            end if;
            if coalesce(v_o->>'date','') > v_demain then
              return jsonb_build_object('ok', false, 'codeErreur', 'DATE_FUTURE',
                'erreur', 'On ne déclare pas des heures qui n''ont pas encore été faites.');
            end if;
          end if;
        end loop;
      end;

      -- ============================================================
      --  UNE JOURNÉE, UNE SEULE DÉCLARATION
      --
      --  Deux salariés d'une même équipe ouvrent l'application le même
      --  soir. Chacun croit devoir saisir la journée. Les heures partent
      --  en double, et elles sont PAYÉES en double — l'erreur ne se voit
      --  qu'au moment du virement, quand il est trop tard.
      --
      --  Le refus est donc SEC : si quelqu'un d'autre a déjà déclaré
      --  cette personne ce jour-là, on n'écrit pas. Pas de confirmation
      --  possible : une confirmation, sur un chantier, se clique.
      --
      --  Le chantier n'entre pas dans la comparaison. Ce qui compte est
      --  « cette personne, ce jour » : si un collègue a déjà rempli la
      --  journée, elle est remplie, quel que soit le chantier inscrit.
      --  Une journée sur deux chantiers se déclare par celui qui a
      --  commencé — ou se corrige auprès de la direction.
      -- ============================================================
      for v_o in select * from jsonb_array_elements(v_upserts) loop
        select x.id, coalesce(nullif(x."chefNom",''), 'un collègue'), x.date
          into v_id, v_qui, v_res
          from chok.pointages x
         where x.id <> coalesce(v_o->>'id','')
           and x.salarie = coalesce(nullif(v_o->>'salarie',''),
                                    (select y.salarie from chok.pointages y
                                      where y.id = v_o->>'id'))
           and x.date = coalesce(nullif(v_o->>'date',''),
                                 (select y.date from chok.pointages y
                                   where y.id = v_o->>'id'))
           and coalesce(x."creePar",'') <> ''
           and coalesce(x."creePar",'') <> v_pid
         limit 1;
        if v_id is not null then
          perform chok.noter('doublon_refuse', v_role, v_pid, v_table,
                             'Journée déjà déclarée par ' || v_qui);
          return jsonb_build_object('ok', false, 'codeErreur', 'DEJA_DECLARE',
            'declarePar', v_qui, 'jour', v_res,
            'erreur', 'Ces heures ont déjà été enregistrées par ' || v_qui || '.' ||
                      chr(10) || chr(10) ||
                      'Une journée ne se déclare qu''une seule fois, par une ' ||
                      'seule personne de l''équipe. Si un chiffre est faux, ' ||
                      'demandez-lui de le corriger, ou appelez la direction.');
        end if;
      end loop;

      -- ============================================================
      --  DEUX FOIS LA MÊME HEURE, JAMAIS
      --
      --  Un chef qui avait oublié son intérimaire refaisait un rapport
      --  complet : ses propres heures repartaient avec, une deuxième puis
      --  une troisième fois (13 lignes en trop entre le 14/09 et le 05/10).
      --  Le contrôle précédent ne regardait que les saisies d'un AUTRE.
      --  Désormais, toute NOUVELLE ligne qui chevauche une ligne déjà
      --  enregistrée pour la même personne le même jour est refusée, quel
      --  qu'en soit l'auteur. Une journée coupée en deux créneaux distincts
      --  (matin sur un chantier, après-midi sur un autre) reste possible.
      -- ============================================================
      for v_o in select * from jsonb_array_elements(v_upserts) loop
        if not exists (select 1 from chok.pointages where id = v_o->>'id') then
          select x.debut || '–' || x.fin into v_qui
            from chok.pointages x
           where x.salarie = v_o->>'salarie' and x.date = v_o->>'date'
             and chok.chevauche(x.debut, x.fin, v_o->>'debut', v_o->>'fin')
           limit 1;
          if v_qui is not null then
            perform chok.noter('doublon_refuse', v_role, v_pid, v_table,
                               'Créneau déjà enregistré : ' || v_qui);
            return jsonb_build_object('ok', false, 'codeErreur', 'DEJA_DECLARE',
              'erreur', 'Ces heures sont déjà enregistrées pour ce jour (' || v_qui || '). ' ||
                        'Rien n''a été renvoyé. Pour les corriger, utilisez « Mes derniers envois ».');
          end if;
        end if;
      end loop;

      -- Auteur fixé à la CRÉATION et jamais réécrit : corriger une ligne
      -- ne doit pas en transférer la propriété.
      v_nouv := '[]'::jsonb;
      for v_o in select * from jsonb_array_elements(v_upserts) loop
        select to_jsonb(x) into v_dej from chok.pointages x where x.id = v_o->>'id';

        if v_dej is not null and coalesce((v_dej->>'valide'),'false') = 'true' then
          perform chok.noter('refus_ecriture', v_role, v_pid, v_table,
                             'Modification d''un pointage validé');
          -- Le message ne dit pas que la direction a « validé » : ce qu'elle
          -- a pointé ou non est son travail de contrôle, et le chef n'a pas
          -- à en suivre l'avancement. Il a seulement besoin de savoir que
          -- cette journée est close et par qui elle peut encore bouger.
          return jsonb_build_object('ok', false, 'codeErreur', 'DEJA_VALIDE',
            'erreur', 'Cette journée est close : elle n''est plus modifiable. ' ||
                      'Appelez la direction pour toute correction.');
        end if;

        -- Modifier : réservé à l'auteur, à la personne concernée, ou au
        -- chef de l'intérimaire concerné.
        if v_dej is not null
           and coalesce(v_dej->>'creePar','') <> v_pid
           and coalesce(v_dej->>'salarie','') <> v_pid
           and not exists (select 1 from chok.interimaires i
                            where i.id = v_dej->>'salarie'
                              and i.chef = v_pid) then
          perform chok.noter('refus_ecriture', v_role, v_pid, v_table,
                             'Modification de la saisie d''un autre chef');
          return jsonb_build_object('ok', false, 'codeErreur', 'SAISIE_AUTRUI',
            'erreur', 'Cette ligne a été saisie par quelqu''un d''autre : vous ne pouvez pas la modifier.');
        end if;

        -- ---- S'ÉCARTER D'UNE JOURNÉE DÉCLARÉE EN ÉQUIPE ----
        --
        -- Un collègue a saisi ma journée ; la mienne a été différente
        -- (passé au dépôt, resté finir, arrivé plus tard). Je peux la
        -- corriger — c'est MA journée — mais je dois dire pourquoi.
        --
        -- Sans motif, un écart est indiscernable d'une faute de frappe,
        -- et c'est la direction qui tranche à l'aveugle en fin de mois,
        -- entre deux versions d'une même journée, sans savoir laquelle
        -- croire.
        --
        -- Corriger SA PROPRE saisie ne demande rien : il n'y a pas deux
        -- versions, juste une correction.
        if v_dej is not null
           and coalesce(v_dej->>'creePar','') <> ''
           and coalesce(v_dej->>'creePar','') <> v_pid
           and coalesce(v_dej->>'salarie','') = v_pid
           and ( (v_o ? 'debut'  and coalesce(v_o->>'debut','')  <> coalesce(v_dej->>'debut',''))
              or (v_o ? 'fin'    and coalesce(v_o->>'fin','')    <> coalesce(v_dej->>'fin',''))
              or (v_o ? 'pause'  and coalesce(v_o->>'pause','')  <> coalesce(v_dej->>'pause',''))
              or (v_o ? 'chantier' and coalesce(v_o->>'chantier','') <> coalesce(v_dej->>'chantier','')) )
           and coalesce(nullif(trim(coalesce(v_o->>'motifEcart',
                                             v_dej->>'motifEcart','')),''), '') = '' then
          return jsonb_build_object('ok', false, 'codeErreur', 'MOTIF_REQUIS',
            'declarePar', coalesce(nullif(v_dej->>'chefNom',''), 'un collègue'),
            'erreur', 'Ces heures ont été saisies par ' ||
                      coalesce(nullif(v_dej->>'chefNom',''), 'un collègue') ||
                      '. Vous pouvez les corriger, mais dites pourquoi votre ' ||
                      'journée a été différente.');
        end if;

        -- Ces champs appartiennent à la direction et au serveur, pas au
        -- téléphone d'un chef : un envoi fabriqué pouvait se déclarer
        -- « validé », ou se donner un autre auteur que son expéditeur.
        v_nouv := v_nouv || jsonb_build_array(
          (v_o - 'valide' - 'creePar' - 'modifiePar' - 'modifieLe' - 'moisPaie' - 'panier')
          || jsonb_build_object('creePar',
               case when v_dej is not null then coalesce(nullif(v_dej->>'creePar',''), v_pid)
                    else v_pid end)
          -- Qui a touché la ligne d'un AUTRE, et quand. Sans cette trace, la
          -- direction voit une journée d'équipe dont une feuille diffère,
          -- sans savoir qui l'a changée ni à quel moment.
          --
          -- Se corriger soi-même ne laisse rien : sinon chaque faute de
          -- frappe rattrapée le soir même allumerait un signal, et la
          -- direction apprendrait à ne plus les regarder.
          || case
               when v_dej is null then '{}'::jsonb
               when coalesce(v_dej->>'creePar','') <> '' and v_dej->>'creePar' <> v_pid
                 then jsonb_build_object(
                      'modifiePar', v_pid,
                      'modifieLe', to_char(timezone('Europe/Paris', now()),
                                           'YYYY-MM-DD"T"HH24:MI:SS'))
               else '{}'::jsonb end);
      end loop;
      v_upserts := v_nouv;

      -- SUPPRIMER est plus strict que MODIFIER : réservé à l'auteur de la
      -- ligne, et seulement tant que la direction ne l'a pas validée.
      for v_id in select jsonb_array_elements_text(v_suppr) loop
        select to_jsonb(x) into v_dej from chok.pointages x where x.id = v_id;
        if v_dej is null
           or coalesce((v_dej->>'valide'),'false') = 'true'
           or ( case when coalesce(v_dej->>'creePar','') <> ''
                     then coalesce(v_dej->>'creePar','') <> v_pid
                     else coalesce(v_dej->>'salarie','') <> v_pid
                          and not exists (select 1 from chok.interimaires i
                                           where i.id = v_dej->>'salarie'
                                             and i.chef = v_pid)
                end ) then
          perform chok.noter('refus_ecriture', v_role, v_pid, v_table, 'Suppression non autorisée');
          return jsonb_build_object('ok', false, 'codeErreur', 'SAISIE_AUTRUI',
            'erreur', 'Vous ne pouvez supprimer que les lignes que vous avez saisies, ' ||
                      'et non encore validées.');
        end if;
      end loop;
    end if;

    if v_table = 'chantiers' then
      v_nouv := '[]'::jsonb;
      for v_o in select * from jsonb_array_elements(v_upserts) loop
        select to_jsonb(x) into v_dej from chok.chantiers x where x.id = v_o->>'id';
        if v_dej is null then
          -- Création : le chantier est à celui qui le crée.
          v_nouv := v_nouv || jsonb_build_array(v_o || jsonb_build_object('chef', v_pid));
        elsif coalesce(v_dej->>'chef','') = v_pid then
          -- Son propre chantier : il le corrige, sans pouvoir le donner à un autre.
          v_nouv := v_nouv || jsonb_build_array(v_o || jsonb_build_object('chef', v_pid));
        else
          -- Chantier commun ou d'un autre chef : un chef peut en corriger le
          -- CLIENT (case « Client » de son écran), rien d'autre. Il ne s'en
          -- approprie pas non plus : un chantier commun le reste.
          if v_o ? 'client' then
            v_nouv := v_nouv || jsonb_build_array(
              jsonb_build_object('id', v_o->>'id', 'client', v_o->'client'));
          end if;
        end if;
      end loop;
      v_upserts := v_nouv;
    end if;

    if v_table = 'interimaires' then
      v_nouv := '[]'::jsonb;
      for v_o in select * from jsonb_array_elements(v_upserts) loop
        select to_jsonb(x) into v_dej from chok.interimaires x where x.id = v_o->>'id';
        if v_dej is not null and coalesce(v_dej->>'chef','') <> v_pid then
          perform chok.noter('refus_ecriture', v_role, v_pid, v_table, 'Intérimaire d''un autre chef');
          return jsonb_build_object('ok', false,
            'erreur', 'Cet intérimaire est rattaché à un autre chef d''équipe.');
        end if;
        -- Un chef ajoute un intérimaire à SON équipe, pour déclarer ses
        -- heures — il ne lui ouvre pas de compte. Le code, l'accès à
        -- l'application et le poste de chef ne se donnent qu'à la direction :
        -- sans cette règle, un chef pouvait se fabriquer un second compte
        -- chef, avec le code de son choix.
        v_nouv := v_nouv || jsonb_build_array(
          (v_o - 'code' - 'accesPlateforme' - 'chef' - 'note')
          || jsonb_build_object('chef', v_pid)
          -- Nouvelle fiche : code « 0000 » explicite (= pas encore de code).
          -- Une clé absente deviendrait un vide, pas le défaut de la colonne.
          || case when v_dej is null then '{"code":"0000"}'::jsonb else '{}'::jsonb end
          || case when chok.est_chef(v_o->>'poste')
                  then jsonb_build_object('poste',
                         coalesce(nullif(v_dej->>'poste',''), 'Manœuvre'))
                  else '{}'::jsonb end);
      end loop;
      v_upserts := v_nouv;
    end if;
  end if;

  -- ---- ÉCRITURE RÉELLE ----
  for v_o in select * from jsonb_array_elements(v_upserts) loop
    v_res := chok.ecrire_ligne(v_table, v_o);
    if v_res = 'ajout' then v_ajout := v_ajout + 1;
    elsif v_res = 'maj' then v_maj := v_maj + 1; end if;
  end loop;

  -- Plus de dix lignes à effacer d'un coup : copie complète d'abord. La
  -- garde ci-dessus peut être levée par une confirmation, ou contournée par
  -- des envois de dix ; la copie, elle, ne dépend de rien de tout cela.
  if v_nb_suppr > 10 then
    perform chok.sauvegarde_complete('avant suppression');
  end if;

  for v_id in select jsonb_array_elements_text(v_suppr) loop
    execute format('delete from chok.%I where id = $1', v_table) using v_id;
    if found then v_del := v_del + 1; end if;
  end loop;

  if array_length(v_revoquer, 1) is not null then
    delete from chok.sessions where "personneId" = any(v_revoquer);
    delete from chok.blocages where cle = any(
      array(select 'blocage_p_' || x from unnest(v_revoquer) x));
  end if;

  perform chok.noter('enregistrement', v_role, v_pid, v_table,
    v_ajout || ' ajout(s), ' || v_maj || ' modif(s), ' || v_del || ' suppr.');

  execute format('select count(*) from chok.%I', v_table) into v_existantes;
  return jsonb_build_object('ok', true, 'total', v_existantes,
    'resultat', jsonb_build_object('ajoutees', v_ajout, 'majs', v_maj, 'supprimees', v_del));
end $$;

-- ============================================================
--  6. POINT D'ENTRÉE UNIQUE
--  C'est la SEULE fonction visible depuis l'application.
-- ============================================================

create or replace function public.chok_api(p jsonb) returns jsonb
language plpgsql security definer
-- pg_catalog EN PREMIER : placé en dernier, un objet du même nom créé dans
-- « public » passerait avant les fonctions système de PostgreSQL.
set search_path = pg_catalog, chok, public
-- Supabase coupe les requêtes de la clé publique au bout de 3 SECONDES.
-- C'est bien pour une lecture, mais insuffisant pour une remise à zéro, qui
-- fait une copie complète des données AVANT d'effacer. La requête était tuée
-- en plein travail, et le navigateur ne voyait qu'un serveur muet.
--
-- Ce réglage ne vaut QUE pour cette fonction : le reste de la base garde la
-- protection d'origine contre les requêtes qui s'éternisent.
set statement_timeout = '120s'
as $$
declare
  v_action text := coalesce(p->>'action','');
  v_jeton  text := coalesce(p->>'jeton','');
  v_role text; v_pid text;
  v_pin text; v_pid_demande text; v_attendu text; v_role_eff text;
  v_personne jsonb; v_cle text; v_echecs integer; v_bloque_jusqua timestamptz;
  v_nouveau uuid; v_rep jsonb; v_donnees jsonb;
  v_liste jsonb; v_tables text[]; v_t text; v_detail jsonb := '{}'::jsonb;
  v_n integer; v_sauv text; v_mail text; v_faits text[] := '{}';
  v_d jsonb; v_o jsonb;
begin
  -- ---------- 1. Actions publiques (aucune donnée personnelle) ----------
  if v_action = 'ping' then
    return jsonb_build_object('ok', true, 'version', chok.version(), 'service', 'CHOK BÉTON');
  end if;

  if v_action = 'etat' then
    return jsonb_build_object('ok', true, 'version', chok.version(),
      'installe', chok.config_lire('pinRH') is not null,
      'codeRHDefini', coalesce(chok.config_lire('pinRH'),'') <> '',
      'lignes', jsonb_build_object(
        'salaries',     (select count(*) from chok.salaries),
        'interimaires', (select count(*) from chok.interimaires),
        'chantiers',    (select count(*) from chok.chantiers),
        'pointages',    (select count(*) from chok.pointages),
        'absences',     (select count(*) from chok.absences)),
      'sauvegardes', (select count(*) from chok.sauvegardes),
      'derniereSauvegarde', (select to_char(max(cree),'YYYY-MM-DD HH24:MI') from chok.sauvegardes),
      'diagnostic', case when coalesce(chok.config_lire('pinRH'),'') = ''
                         then 'Installation incomplète : relancez le script SQL.'
                         else 'Serveur prêt.' end);
  end if;

  -- Liste des noms pour l'écran de connexion. Ne contient QUE le nom et le
  -- poste : aucun code, aucune heure. C'est le strict nécessaire pour que
  -- chacun puisse se désigner avant de saisir son code.
  if v_action = 'listePersonnes' then
    -- Ordre alphabétique, accents ignorés : « É » se range avec « E ».
    -- Le tri se place DANS jsonb_agg. Placé après la sous-requête, il portait
    -- sur une colonne absente du regroupement : PostgreSQL refusait toute la
    -- requête, et la liste des noms ne se chargeait jamais. Les téléphones se
    -- rabattaient alors en silence sur d'anciennes données, d'où des chefs
    -- « introuvables » alors qu'ils étaient bien en base.
    select coalesce(jsonb_agg(q.x order by chok.cle_nom(q.x->>'nom')),'[]'::jsonb)
      into v_liste from (
      select jsonb_build_object('id', s.id, 'nom', s.nom, 'poste', s.poste, 'type', 'interne') as x
        from chok.salaries s where coalesce(s.actif, true)
      union all
      select jsonb_build_object('id', i.id, 'nom', i.nom, 'poste', i.poste,
                                'agence', i.agence, 'type', 'interim') as x
        from chok.interimaires i
       -- Un intérimaire apparaît s'il est CHEF D'ÉQUIPE — le désigner chef
       -- suffit, sans avoir à cocher en plus « accès plateforme ». Les autres
       -- n'apparaissent que si on leur a explicitement ouvert l'accès.
       where coalesce(i.actif, true)
         and (chok.est_chef(i.poste) or i."accesPlateforme" = true)
    ) q;
    return jsonb_build_object('ok', true, 'personnes', v_liste, 'version', chok.version());
  end if;

  -- ---------- 2. Connexion ----------
  if v_action = 'connexion' then
    perform chok.menage();
    v_pin := coalesce(p->>'pin','');
    v_pid_demande := coalesce(p->>'personneId','');
    -- ============================================================
    --  LE COMPTEUR D'ÉCHECS SUIT LA PERSONNE VISÉE, ET RIEN D'AUTRE
    --
    --  La clé mêlait le « rôle » envoyé par le téléphone : il suffisait
    --  d'y mettre une valeur différente à chaque essai pour disposer d'un
    --  compteur neuf, et essayer toutes les années de naissance d'affilée.
    --  Pour la direction, l'identifiant de personne était libre : même
    --  effet. La clé ne dépend plus que de ce que le serveur vérifie.
    -- ============================================================
    v_cle := case when coalesce(p->>'role','') = 'rh' then 'blocage_rh'
                  else 'blocage_p_' || v_pid_demande end;

    select echecs, jusqua into v_echecs, v_bloque_jusqua from chok.blocages
     where cle = v_cle and jusqua > now();
    if v_bloque_jusqua is not null then
      perform chok.noter('connexion_bloquee', coalesce(p->>'role',''),
                         coalesce(nullif(v_pid_demande,''),'-'), '-', 'Trop de codes erronés');
      return jsonb_build_object('ok', false, 'codeErreur', 'BLOQUE',
        'erreur', 'Trop de codes erronés. Réessayez après ' ||
                  to_char(timezone('Europe/Paris', v_bloque_jusqua),
                          case when v_bloque_jusqua < now() + interval '20 hours'
                               then 'HH24"h"MI' else 'DD/MM à HH24"h"MI' end) ||
                  ', ou demandez à la direction de vous redonner votre code.');
    end if;

    if coalesce(p->>'role','') = 'rh' then
      v_attendu := chok.config_lire('pinRH');
      if coalesce(v_attendu,'') = '' then
        return jsonb_build_object('ok', false, 'codeErreur', 'NON_INSTALLE',
          'erreur', 'Le serveur n''est pas encore installé : aucun code n''est enregistré. ' ||
                    'Relancez le script SQL dans Supabase.');
      end if;
      v_role_eff := 'rh';
      v_pid := '';
    else
      if v_pid_demande = '' then
        return jsonb_build_object('ok', false, 'erreur', 'Sélectionnez votre nom.');
      end if;
      v_personne := chok.trouver_personne(v_pid_demande);
      if v_personne is null then
        -- Le téléphone a envoyé un identifiant que la base ne connaît pas :
        -- sa liste de noms date d'avant une réinstallation, ou d'un import.
        -- Le code d'erreur permet à l'application de se réparer seule —
        -- vider sa liste, la redemander — au lieu de renvoyer chacun vers
        -- la RH pour un problème qui se règle en deux secondes.
        return jsonb_build_object('ok', false, 'codeErreur', 'PERSONNE_INCONNUE',
          'erreur', 'Votre fiche n''a pas été trouvée sur le serveur. ' ||
                    'La liste des noms de cet appareil est périmée : elle va être actualisée.');
      end if;
      -- Une personne archivée, ou un intérimaire à qui l'accès n'a pas été
      -- ouvert, n'apparaît pas dans la liste des noms — mais son identifiant
      -- suffisait à se connecter. Même règle que la liste, ici aussi.
      if not coalesce((v_personne->>'actif')::boolean, true)
         or (exists (select 1 from chok.interimaires where id = v_pid_demande)
             and not chok.est_chef(v_personne->>'poste')
             and not coalesce((v_personne->>'accesPlateforme')::boolean, false)) then
        perform chok.noter('connexion_refusee', '-', v_pid_demande, '-', 'Accès fermé');
        return jsonb_build_object('ok', false, 'codeErreur', 'ACCES_FERME',
          'erreur', 'Votre accès à l''application n''est pas ouvert. Voyez la direction.');
      end if;
      -- « 0000 » est le code posé par défaut à la création d'une fiche : il
      -- ne protège rien, puisque tout le monde le connaît. Tant que la
      -- direction n'a pas donné un vrai code, la connexion est refusée.
      v_attendu := coalesce(nullif(v_personne->>'code',''), '0000');
      if v_attendu = '0000' then
        perform chok.noter('connexion_refusee', '-', v_pid_demande, '-', 'Code par défaut');
        return jsonb_build_object('ok', false, 'codeErreur', 'CODE_NON_DEFINI',
          'erreur', 'Aucun code personnel ne vous a encore été attribué. Voyez la direction.');
      end if;
      v_role_eff := case when chok.est_chef(v_personne->>'poste') then 'chef' else 'salarie' end;
      v_pid := v_pid_demande;
    end if;

    if not chok.meme_code(v_pin, v_attendu) then
      -- 5 essais libres, puis blocage : 15 min, 30 min, 1 h, 2 h… jusqu'à
      -- 64 h par essai. Une personne qui se trompe deux fois n'est pas
      -- gênée ; essayer soixante années prendrait des mois.
      insert into chok.blocages(cle, echecs, jusqua, oubli)
        values (v_cle, 1, null, now() + interval '30 days')
        on conflict (cle) do update
          set echecs = blocages.echecs + 1,
              oubli  = now() + interval '30 days',
              jusqua = case when blocages.echecs + 1 >= 5
                            then now() + interval '15 minutes'
                                       * power(2, least(blocages.echecs + 1 - 5, 8))
                            else null end;
      perform chok.noter('connexion_echec', v_role_eff,
                         coalesce(nullif(v_pid_demande,''),'-'), '-', 'Code incorrect');
      return jsonb_build_object('ok', false, 'erreur', 'Code incorrect.');
    end if;

    delete from chok.blocages where cle = v_cle;
    v_nouveau := gen_random_uuid();
    -- Direction : 12 h. Elle a accès à tout, codes compris ; une session
    -- oubliée ouverte sur un ordinateur partagé ne doit pas durer une semaine.
    insert into chok.sessions(jeton, role, "personneId", expire)
      values (v_nouveau, v_role_eff, v_pid,
              now() + case when v_role_eff = 'rh' then interval '12 hours'
                           else interval '7 days' end);
    perform chok.noter('connexion', v_role_eff,
                       coalesce(nullif(v_pid,''),'-'), '-', 'Connexion réussie');

    -- Les données partent AVEC la connexion : un seul aller-retour.
    v_donnees := chok.charger(v_role_eff, v_pid, p);
    return jsonb_build_object('ok', true, 'jeton', v_nouveau::text,
      'role', v_role_eff, 'personneId', v_pid,
      'nom', coalesce(v_personne->>'nom', 'Direction'),
      'version', chok.version(),
      'donnees', v_donnees->'donnees', 'meta', v_donnees->'meta');
  end if;

  -- ---------- EXPORT COMPLET POUR SAUVEGARDE HORS BASE ----------
  -- Réservé au robot de sauvegarde, qui s'identifie par une clé dédiée.
  -- Cette clé ne figure PAS dans l'application : elle vit uniquement dans
  -- votre script Google Drive, qui est privé. Elle donne un accès en
  -- LECTURE SEULE, et rien d'autre.
  if v_action = 'exporter' then
    -- Pas de blocage après échecs ici. La clé fait 64 caractères aléatoires :
    -- on ne la devine pas. Un compteur commun, en revanche, permettait à
    -- n'importe qui d'envoyer cinq fausses clés et de priver la direction
    -- de sa sauvegarde de nuit. Les refus restent notés au journal.
    v_attendu := coalesce(chok.config_lire('cleExport'), '');
    if v_attendu = '' or coalesce(p->>'cleExport','') <> v_attendu then
      perform chok.noter('export_refuse','robot','-','-','Clé d''export incorrecte');
      return jsonb_build_object('ok', false, 'erreur', 'Clé d''export incorrecte.');
    end if;

    perform chok.noter('export','robot','-','toutes','Sauvegarde hors base');
    -- LES CODES D'ACCÈS NE SORTENT PAS. Cette sauvegarde part chez un
    -- autre hébergeur : y joindre les codes des trente et un salariés
    -- reviendrait à déposer chaque nuit un double des clés de la maison
    -- dans un autre nuage. Les heures, elles, ne valent rien pour un
    -- inconnu ; un code d'accès, si.
    --
    -- Une restauration complète repose donc les codes par un second
    -- geste : relancer CHOK_BETON_CODES.sql. Dix secondes, et le
    -- fichier ne quitte jamais l'ordinateur de la direction.
    return jsonb_build_object('ok', true,
      'genere', to_char(timezone('Europe/Paris', now()), 'YYYY-MM-DD"T"HH24:MI:SS'),
      'version', chok.version(),
      'sansCodes', true,
      'donnees', jsonb_build_object(
        'salaries',     (select coalesce(jsonb_agg(x - 'code'),'[]'::jsonb)
                           from jsonb_array_elements(chok.lire('salaries')) x),
        'interimaires', (select coalesce(jsonb_agg(x - 'code'),'[]'::jsonb)
                           from jsonb_array_elements(chok.lire('interimaires')) x),
        'chantiers',    chok.lire('chantiers'),
        'pointages',    chok.lire('pointages'),
        'absences',     chok.lire('absences')));
  end if;

  -- ---------- 3. Toutes les autres actions exigent un jeton valide ----------
  if v_jeton = '' then
    return jsonb_build_object('ok', false, 'erreur', 'Session absente. Reconnectez-vous.');
  end if;
  begin
    select s.role, s."personneId" into v_role, v_pid
      from chok.sessions s where s.jeton = v_jeton::uuid and s.expire > now();
  exception when others then
    v_role := null;
  end;
  if v_role is null then
    return jsonb_build_object('ok', false, 'expire', true,
      'erreur', 'Session expirée. Reconnectez-vous.');
  end if;

  -- Se déconnecter supprime la session sur le serveur, et pas seulement
  -- sur le téléphone : un jeton recopié ne sert plus à rien.
  if v_action = 'deconnexion' then
    delete from chok.sessions where jeton = v_jeton::uuid;
    return jsonb_build_object('ok', true);
  end if;

  if v_action = 'charger' then
    return chok.charger(v_role, v_pid, p);
  end if;

  if v_action = 'enregistrer' then
    return chok.enregistrer(v_role, v_pid, p);
  end if;

  -- ---------- 4. Actions réservées à la direction ----------
  if v_role <> 'rh' then
    return jsonb_build_object('ok', false, 'erreur', 'Réservé à la direction.');
  end if;

  if v_action = 'reglages' then
    if chok.vers_bool(p->'lire') then
      return jsonb_build_object('ok', true, 'reglages',
        jsonb_build_object('emailRH',    coalesce(chok.config_lire('emailRH'),'')));
    end if;
    if p ? 'emailRH' then
      v_mail := trim(coalesce(p->>'emailRH',''));
      if v_mail <> '' and v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
        return jsonb_build_object('ok', false, 'erreur', 'Adresse e-mail invalide.');
      end if;
      perform chok.config_ecrire('emailRH', v_mail);
      v_faits := v_faits || case when v_mail <> '' then 'adresse mail enregistrée'
                                 else 'adresse mail effacée' end;
    end if;
    if p ? 'pinRH' then
      v_pin := trim(coalesce(p->>'pinRH',''));
      -- 6 chiffres au moins : ce code ouvre TOUT, codes des salariés compris.
      if v_pin !~ '^\d{6,8}$' then
        return jsonb_build_object('ok', false, 'erreur', 'Le code direction doit comporter 6 à 8 chiffres.');
      end if;
      perform chok.config_ecrire('pinRH', v_pin);
      -- Les autres sessions direction ouvertes avec l'ancien code sont
      -- coupées ; celle qui vient de le changer continue.
      delete from chok.sessions where role = 'rh' and jeton <> v_jeton::uuid;
      delete from chok.blocages where cle = 'blocage_rh';
      v_faits := v_faits || 'code direction mis à jour';
    end if;
    perform chok.noter('reglages', v_role, '-', 'config', array_to_string(v_faits,', '));
    return jsonb_build_object('ok', true,
      'message', coalesce(nullif(array_to_string(v_faits,' · '),''), 'Aucun changement.'));
  end if;

  if v_action = 'sauvegarder' then
    -- Le motif n'est pas libre : seules deux valeurs connues sont acceptées,
    -- pour qu'aucun texte venu d'un téléphone n'entre dans la base.
    v_sauv := chok.sauvegarde_complete(
      case when coalesce(p->>'motif','') = 'avant remise à zéro'
           then 'avant remise à zéro' else 'manuelle' end);
    return jsonb_build_object('ok', true, 'sauvegarde', v_sauv,
      'message', 'Sauvegarde créée : ' || v_sauv);
  end if;

  if v_action = 'reinitialiser' then
    -- Une sauvegarde complète existe AVANT tout effacement. Sans elle,
    -- rien n'est effacé : on ne détruit jamais sans filet.
    --
    -- L'application procède désormais en DEUX appels courts — sauvegarder,
    -- puis effacer — au lieu d'un seul appel long. Une remise à zéro peut
    -- porter sur des années d'historique ; en un seul appel, la requête
    -- pouvait dépasser le temps accordé et le téléphone ne recevait alors
    -- aucune réponse : impossible de savoir si l'effacement avait eu lieu.
    --
    -- Le filet reste garanti PAR LA BASE et non par le téléphone : quand
    -- celui-ci annonce avoir déjà fait la sauvegarde, on exige d'en trouver
    -- une de moins de dix minutes, sinon on refuse d'effacer.
    if chok.vers_bool(p->'sauvegardeFaite') then
      select to_char(timezone('Europe/Paris', s.cree), 'YYYY-MM-DD HH24:MI')
               || ' (' || s.lignes || ' lignes)'
        into v_sauv
        from chok.sauvegardes s
       where s.cree > now() - interval '10 minutes'
         -- Une copie faite EXPRÈS pour cette remise à zéro, pas la
         -- quotidienne ou une manuelle qui passerait par là.
         and s.motif = 'avant remise à zéro'
       order by s.cree desc limit 1;
      if v_sauv is null then
        return jsonb_build_object('ok', false,
          'erreur', 'Aucune sauvegarde récente trouvée. Aucune donnée n''a été effacée.');
      end if;
    else
      v_sauv := chok.sauvegarde_complete('avant remise à zéro');
    end if;
    if v_sauv is null then
      return jsonb_build_object('ok', false,
        'erreur', 'Sauvegarde impossible. Aucune donnée n''a été effacée.');
    end if;
    v_tables := array(select x from jsonb_array_elements_text(
                        coalesce(p->'tables','["pointages","absences"]'::jsonb)) x
                       where x in ('pointages','absences','chantiers','interimaires'));
    if array_length(v_tables,1) is null then
      return jsonb_build_object('ok', false, 'erreur', 'Aucune table valide à réinitialiser.');
    end if;
    foreach v_t in array v_tables loop
      execute format('select count(*) from chok.%I', v_t) into v_n;
      -- « where true » n'est pas une coquetterie : Supabase charge l'extension
      -- pg_safeupdate sur le rôle qui sert l'API, et celle-ci REFUSE tout
      -- DELETE sans clause WHERE — « DELETE requires a WHERE clause ».
      -- Le garde-fou est bon (il évite d'effacer une table entière par
      -- distraction) ; ici l'effacement total est justement ce qu'on veut,
      -- et on le dit explicitement.
      execute format('delete from chok.%I where true', v_t);
      v_detail := v_detail || jsonb_build_object(v_t, v_n);
    end loop;
    perform chok.noter('remise_a_zero', v_role, '-', array_to_string(v_tables,','), v_detail::text);
    return jsonb_build_object('ok', true, 'efface', v_detail, 'sauvegarde', v_sauv,
      'message', 'Remise à zéro effectuée. Sauvegarde créée : ' || v_sauv);
  end if;

  if v_action = 'importerTout' then
    v_d := coalesce(p->'donnees','{}'::jsonb);
    -- Une reprise « remplacer » réécrit des lignes existantes : elle obéit
    -- à la même règle que la remise à zéro — copie complète d'abord.
    if chok.vers_bool(p->'remplacer') then
      v_sauv := chok.sauvegarde_complete('avant reprise');
    end if;
    foreach v_t in array array['salaries','interimaires','chantiers','pointages','absences'] loop
      execute format('select count(*) from chok.%I', v_t) into v_n;
      if v_n = 0 or chok.vers_bool(p->'remplacer') then
        for v_o in select * from jsonb_array_elements(coalesce(v_d->v_t,'[]'::jsonb)) loop
          perform chok.ecrire_ligne(v_t, v_o);
        end loop;
      end if;
      execute format('select count(*) from chok.%I', v_t) into v_n;
      v_detail := v_detail || jsonb_build_object(v_t, v_n);
    end loop;
    -- Le code direction d'un fichier n'est repris que s'il est valable : un
    -- code court ou abîmé ne doit pas remplacer en silence le bon.
    if trim(coalesce(p->>'pinRH','')) ~ '^\d{6,8}$' then
      perform chok.config_ecrire('pinRH', trim(p->>'pinRH'));
    end if;
    perform chok.noter('import', v_role, '-', 'toutes', v_detail::text);
    return jsonb_build_object('ok', true, 'total', v_detail,
      'message', 'Reprise effectuée.' ||
                 case when v_sauv is not null then ' Sauvegarde préalable : ' || v_sauv else '' end);
  end if;

  return jsonb_build_object('ok', false, 'erreur', 'Action inconnue : ' || v_action);

exception when others then
  -- Le message technique reste dans le journal ; l'utilisateur reçoit une
  -- phrase compréhensible et sa saisie est conservée sur son téléphone.
  begin
    perform chok.noter('erreur_serveur', coalesce(v_role,'?'), coalesce(v_pid,'-'),
                       v_action, sqlerrm);
  exception when others then null; end;
  return jsonb_build_object('ok', false,
    'erreur', 'Le serveur a rencontré une difficulté sur cette opération. ' ||
              'Votre saisie est conservée. Signalez-le à la direction. (' || sqlerrm || ')');
end $$;

-- Seul chok_api est appelable depuis l'application.
--
-- Les deux lignes de retrait sont répétées ICI, après la création de toutes
-- les fonctions internes : PostgreSQL accorde par défaut le droit d'exécution
-- à tout le monde sur une fonction qui vient d'être créée. Le retrait fait en
-- section 2 ne concernait que ce qui existait à ce moment-là.
revoke all on all functions in schema chok from public, anon, authenticated;
revoke all on function public.chok_api(jsonb) from public;
grant execute on function public.chok_api(jsonb) to anon, authenticated;

-- ============================================================
--  7. DONNÉES INITIALES
--  Rejouable : une fiche déjà présente est conservée telle quelle
--  (même identifiant, même code, même solde) — les heures déjà
--  saisies restent donc rattachées à la bonne personne.
-- ============================================================

do $$
declare
  noms text[] := array[
    'ADOU Stéphane','BAKAYOKO Moussa','BAVESA Mayala','CAMARA Mady Oualy',
    'CISSE Souleymane','COLPIN Maxence','COULIBALY Koniba',
    'DE JESUS VIEIRA ALVES Marcos Lezito','DIABATE Siriman',
    'DUARTE MENDES Evileno Ulisses','GARCIA Gomes Cumbuessana','KONATE Zan',
    'LEROY David','LOURENCO BULHA Nelson Daniel','MABELA MANGITUKA Didier',
    'MAKALOU Ibrahim Kalilou','MALUNGILA Jhonny Lunsona','MAMBI SIBAMONEKA Roger',
    'MAYALA MAKENGA Elvis','MBIDI SEMBO André','MPAKA Mayela','NDOBE Ernest',
    'ONAMBELE Junior','PANEL Bertrand','SENCIER Laurent','SISSOKO Fily',
    'SOUKOUNA Hamara','SOUKOUNA Mahamadou','TISSIR OMAR','TRAORE Aly','TRAORE Garaba'];
  n text; i integer := 0;
begin
  foreach n in array noms loop
    i := i + 1;
    if not exists (
      select 1 from chok.salaries s where chok.cle_nom(s.nom) = chok.cle_nom(n)
    ) then
      insert into chok.salaries(id, nom, poste, equipe, interne, code, conges)
      values ('S-' || lpad(i::text, 3, '0'), n, 'Manœuvre', '', true, '0000', 30)
      on conflict (id) do nothing;
    end if;
  end loop;
end $$;

-- RÉPARATION DU 30/09/2026 : un collage aux accents abîmés a réécrit le
-- poste des 31 salariés en « Man≈ìuvre ». Tous les salariés CHOK'BÉTON
-- sont chefs d'équipe : on leur rend ce poste. Sans effet sur une base saine.
update chok.salaries set poste = 'Chef d''équipe'
 where poste like '%' || chr(8776) || '%' or poste like '%' || chr(195) || '%';

-- La ligne qui ramenait ici tout libellé inconnu à « Manœuvre » est retirée :
-- c'est elle qui, avec des accents abîmés, a rétrogradé tout le monde. Un
-- poste ne change plus que depuis l'application.

-- ------------------------------------------------------------
--  CHEFS D'ÉQUIPE
--  ⚠ SEUL un chef d'équipe dispose de l'écran de saisie des heures.
--
--  Les postes se règlent dans l'application : Direction → Salariés →
--  Modifier. Le script n'y touche plus. Il passait auparavant TOUT LE
--  MONDE chef d'équipe à chaque exécution : un choix fait dans
--  l'application était annulé à la relance suivante, et le moindre code
--  deviné donnait les droits d'un chef.
--
--  Variante nominative, pour une base neuve seulement : retirez les --
--  devant les noms voulus.
-- ------------------------------------------------------------
update chok.salaries set poste = 'Chef d''équipe'
 where chok.cle_nom(nom) in (
--   chok.cle_nom('ADOU Stéphane'),
--   chok.cle_nom('LEROY David'),
--   chok.cle_nom('PANEL Bertrand'),
--   chok.cle_nom('SENCIER Laurent'),
     null
 );

-- Clé du robot de sauvegarde : engendrée une seule fois, puis conservée.
-- Pour la relire : select chok.config_lire('cleExport');
insert into chok.config(cle, valeur)
values ('cleExport', replace(gen_random_uuid()::text,'-','') ||
                     replace(gen_random_uuid()::text,'-',''))
  on conflict (cle) do nothing;

-- Code direction : 010126, choix de la direction. Conservé s'il existe
-- déjà ; se change dans l'application (Direction → Paramètres).
insert into chok.config(cle, valeur) values ('pinRH', '010126')
  on conflict (cle) do nothing;
insert into chok.config(cle, valeur) values ('emailRH', '')
  on conflict (cle) do nothing;

-- Ancienneté maximale acceptée par le SERVEUR pour une nouvelle saisie.
-- L'écran, lui, n'en propose que 3 (aujourd'hui, hier, avant-hier). L'écart
-- absorbe les saisies restées en file d'attente faute de réseau.
insert into chok.config(cle, valeur) values ('joursSaisieServeur', '9')
  on conflict (cle) do nothing;
-- L'écran autorise désormais 5 jours en arrière (contre 2) : la marge du
-- serveur passe de 7 à 9 jours, pour qu'une saisie restée hors réseau ne
-- soit pas refusée à son arrivée. Une valeur réglée à la main est conservée.
update chok.config set valeur = '9' where cle = 'joursSaisieServeur' and valeur = '7';


-- ============================================================
--  7 bis. ENVOI D'E-MAILS
--
--  Le serveur Google savait envoyer du courrier tout seul. Une base
--  PostgreSQL, non : il lui faut un service d'envoi.
--
--  Tant qu'aucune clé d'envoi n'est enregistrée, ces fonctions ne font
--  RIEN et ne provoquent aucune erreur. Le reste marche sans elles.
--
--  POUR ACTIVER :
--    1. créer un compte sur resend.com (gratuit : 3 000 mails / mois)
--    2. y créer une clé d'API (commence par « re_ »)
--    3. exécuter ici, une seule fois :
--         select chok.config_ecrire('cleEmail', 're_votre_cle');
--         select chok.config_ecrire('emailRH', 'direction@chokbeton.fr');
--    4. contrôler : select chok.recap_hebdomadaire();
--
--  L'adresse d'expédition par défaut n'exige aucune configuration de
--  domaine. Pour écrire depuis @chokbeton.fr, il faut valider le domaine
--  chez Resend, puis :
--    select chok.config_ecrire('expediteurEmail', 'rapport@chokbeton.fr');
-- ============================================================

/* Heures travaillées d'un pointage. Même règle que l'application, y
   compris le poste de 24 h (même heure de début et de fin). */
create or replace function chok.heures(p_debut text, p_fin text, p_pause numeric)
returns numeric language plpgsql immutable as $$
declare m integer;
begin
  if p_debut !~ '^\d{1,2}:\d{2}$' or p_fin !~ '^\d{1,2}:\d{2}$' then return 0; end if;
  m := (split_part(p_fin,':',1)::int * 60 + split_part(p_fin,':',2)::int)
     - (split_part(p_debut,':',1)::int * 60 + split_part(p_debut,':',2)::int);
  if m <= 0 then m := m + 1440; end if;          -- poste de nuit, ou 24 h
  m := m - coalesce(p_pause,0)::int;
  return greatest(0, m::numeric / 60);   -- exact : l'arrondi se fait sur le total affiché
end $$;

create or replace function chok.envoyer_mail(p_sujet text, p_corps text)
returns text language plpgsql as $$
declare v_cle text; v_dest text; v_exp text; v_id bigint;
begin
  v_cle  := coalesce(chok.config_lire('cleEmail'), '');
  v_dest := coalesce(chok.config_lire('emailRH'), '');
  v_exp  := coalesce(nullif(chok.config_lire('expediteurEmail'),''), 'onboarding@resend.dev');
  if v_cle = '' or v_dest = '' then
    return 'Envoi ignoré : clé d''envoi ou adresse de la direction non renseignée.';
  end if;
  select net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || v_cle),
    body    := jsonb_build_object('from', v_exp, 'to', jsonb_build_array(v_dest),
                                  'subject', p_sujet, 'text', p_corps)
  ) into v_id;
  perform chok.noter('email','systeme','-',p_sujet,'demande no ' || v_id);
  return 'Envoi demandé (no ' || v_id || ').';
exception when others then
  perform chok.noter('email_echec','systeme','-',p_sujet, sqlerrm);
  return 'Envoi impossible : ' || sqlerrm;
end $$;

/* Récapitulatif de la semaine écoulée, envoyé le lundi matin. */
create or replace function chok.recap_hebdomadaire() returns text
language plpgsql as $$
declare
  v_lundi date := (timezone('Europe/Paris', now()))::date
                  - extract(isodow from (timezone('Europe/Paris', now()))::date)::int - 6;
  v_dim   date := v_lundi + 6;
  v_corps text; v_total numeric; v_nb int; v_attente int; v_log int; v_l record;
begin
  select coalesce(sum(chok.heures(p.debut, p.fin, p.pause)),0), count(*)
    into v_total, v_nb
    from chok.pointages p
   where p.date between v_lundi::text and v_dim::text;

  select count(*) into v_attente from chok.pointages p
   where p.date between v_lundi::text and v_dim::text and coalesce(p.valide,false) = false;
  select count(*) into v_log from chok.pointages p
   where p.date between v_lundi::text and v_dim::text and coalesce(p.deplacement,false) = true;

  v_corps := 'CHOK BÉTON — semaine du ' || to_char(v_lundi,'DD/MM/YYYY')
          || ' au ' || to_char(v_dim,'DD/MM/YYYY') || chr(10)
          || '===========================================' || chr(10) || chr(10)
          || 'Total des heures    : ' || to_char(v_total,'FM999990.00') || ' h' || chr(10)
          || 'Pointages saisis    : ' || v_nb || chr(10)
          || 'En attente de valid.: ' || v_attente || chr(10)
          || 'Journées avec logement : ' || v_log || chr(10) || chr(10)
          || 'DÉTAIL PAR PERSONNE' || chr(10)
          || '-------------------' || chr(10);

  for v_l in
    select coalesce(s.nom, i.nom, p.salarie) as qui,
           sum(chok.heures(p.debut, p.fin, p.pause)) as h,
           count(*) as j
      from chok.pointages p
      left join chok.salaries s     on s.id = p.salarie
      left join chok.interimaires i on i.id = p.salarie
     where p.date between v_lundi::text and v_dim::text
     group by 1 order by 2 desc
  loop
    v_corps := v_corps || rpad(v_l.qui, 34) || lpad(to_char(v_l.h,'FM999990.00') || ' h', 9)
            || '   (' || v_l.j || ' j)' || chr(10);
  end loop;

  if v_nb = 0 then
    v_corps := v_corps || '(aucune heure déclarée cette semaine)' || chr(10);
  end if;

  v_corps := v_corps || chr(10) || 'Dernière sauvegarde : '
          || coalesce((select to_char(max(cree),'DD/MM/YYYY à HH24:MI') from chok.sauvegardes),
                      'aucune') || chr(10);

  return chok.envoyer_mail('CHOK BÉTON — récapitulatif du ' || to_char(v_lundi,'DD/MM'), v_corps);
end $$;

/* Vérifie qu'une sauvegarde a bien eu lieu dans les dernières 36 h.
   Sinon, prévient la direction — c'est l'alerte que faisait Google. */
create or replace function chok.verifier_sauvegarde() returns text
language plpgsql as $$
declare v_derniere timestamptz;
begin
  -- Seules les copies AUTOMATIQUES comptent : une sauvegarde faite à la main
  -- depuis l'application masquait une tâche de nuit tombée en panne.
  select max(cree) into v_derniere from chok.sauvegardes
   where motif in ('quotidienne', 'mensuelle');
  if v_derniere is null or v_derniere < now() - interval '36 hours' then
    return chok.envoyer_mail('⚠ CHOK BÉTON — sauvegarde en défaut',
      'Aucune sauvegarde depuis ' ||
      coalesce(to_char(v_derniere,'DD/MM/YYYY à HH24:MI'), 'toujours') || '.' || chr(10) ||
      'Vérifiez que l''extension pg_cron est bien activée dans Supabase ' ||
      '(Database → Extensions), puis relancez le script d''installation.');
  end if;
  return 'Sauvegarde à jour (' || to_char(v_derniere,'DD/MM/YYYY HH24:MI') || ').';
end $$;

-- ============================================================
--  8. SAUVEGARDE AUTOMATIQUE QUOTIDIENNE
--  Si l'extension pg_cron est disponible, une copie complète est
--  faite chaque nuit à 2 h. Sinon le script continue sans échouer :
--  la sauvegarde manuelle (Paramètres) reste disponible.
-- ============================================================

do $$
begin
  create extension if not exists pg_cron;
  create extension if not exists pg_net;
  perform cron.unschedule('chok_sauvegarde') where exists (
    select 1 from cron.job where jobname = 'chok_sauvegarde');
  perform cron.schedule('chok_sauvegarde', '0 2 * * *',
                        $c$ select chok.sauvegarde_complete('quotidienne'); $c$);
  -- Sauvegarde MENSUELLE, conservée indéfiniment : aucun mois ne disparaît,
  -- même après un an. Les quotidiennes, elles, tournent sur 60 jours.
  perform cron.unschedule('chok_sauvegarde_mois') where exists (
    select 1 from cron.job where jobname = 'chok_sauvegarde_mois');
  perform cron.schedule('chok_sauvegarde_mois', '15 2 1 * *',
                        $c$ select chok.sauvegarde_complete('mensuelle'); $c$);
  -- Récapitulatif du lundi 7 h, et contrôle quotidien des sauvegardes.
  -- Sans clé d'envoi enregistrée, ces deux tâches ne font rien.
  perform cron.unschedule('chok_recap') where exists (
    select 1 from cron.job where jobname = 'chok_recap');
  perform cron.schedule('chok_recap', '0 7 * * 1', $c$ select chok.recap_hebdomadaire(); $c$);
  perform cron.unschedule('chok_veille_sauvegarde') where exists (
    select 1 from cron.job where jobname = 'chok_veille_sauvegarde');
  perform cron.schedule('chok_veille_sauvegarde', '0 8 * * *',
                        $c$ select chok.verifier_sauvegarde(); $c$);
  perform cron.unschedule('chok_menage') where exists (
    select 1 from cron.job where jobname = 'chok_menage');
  perform cron.schedule('chok_menage', '30 2 * * *', $c$ select chok.menage(); $c$);
exception when others then
  raise notice 'pg_cron indisponible : sauvegarde automatique non programmée (%).', sqlerrm;
end $$;

-- Première sauvegarde immédiate.
select chok.sauvegarde_complete('installation') as sauvegarde_initiale;

-- ============================================================
--  9. CONTRÔLE FINAL
--
--  L'éditeur Supabase n'affiche que le résultat de la DERNIÈRE
--  instruction : tout est donc réuni ici, en une seule table.
--  Lisez la colonne « état » de haut en bas.
-- ============================================================
with controles(n, quoi, valeur, attendu, bon) as (
  select 1, 'Version du serveur',
         chok.version(), 's3.3',
         chok.version() = 's3.3'
  union all
  select 2, 'Tables verrouillées (RLS active)',
         -- On affiche la LISTE et non un simple nombre : un écart se
         -- diagnostique alors d'un coup d'œil, sans requête supplémentaire.
         (select count(*)::text || ' — ' || string_agg(c.relname, ', ' order by c.relname)
            from pg_class c
            join pg_namespace nsp on nsp.oid = c.relnamespace
           where nsp.nspname = 'chok' and c.relkind = 'r' and c.relrowsecurity),
         '10 : absences, blocages, chantiers, config, interimaires, journal, ' ||
         'pointages, salaries, sauvegardes, sessions',
         (select count(*) from pg_class c
            join pg_namespace nsp on nsp.oid = c.relnamespace
           where nsp.nspname = 'chok' and c.relkind = 'r' and c.relrowsecurity) = 10
  union all
  select 3, 'Ouvertures accordées sur les tables',
         (select count(*)::text from pg_policies where schemaname = 'chok'),
         '0  (aucune : tout passe par chok_api)',
         (select count(*) from pg_policies where schemaname = 'chok') = 0
  union all
  select 4, 'Fonctions ouvertes à la clé publique',
         (select count(*)::text from pg_proc p
            join pg_namespace nsp on nsp.oid = p.pronamespace
           where nsp.nspname = 'public' and p.proname = 'chok_api'),
         '1  (chok_api, et elle seule)',
         (select count(*) from pg_proc p
            join pg_namespace nsp on nsp.oid = p.pronamespace
           where nsp.nspname = 'public' and p.proname = 'chok_api') = 1
  union all
  select 5, 'Salariés enregistrés',
         (select count(*)::text from chok.salaries), '31 ou plus',
         (select count(*) from chok.salaries) >= 31
  union all
  select 6, 'Chefs d''équipe désignés',
         (select count(*)::text from chok.salaries where chok.est_chef(poste)),
         'au moins 1 — SINON PERSONNE NE PEUT SAISIR',
         (select count(*) from chok.salaries where chok.est_chef(poste)) > 0
  union all
  select 7, 'Heures enregistrées',
         (select count(*)::text from chok.pointages), 'inchangé', true
  union all
  select 8, 'Sauvegardes en base',
         (select count(*)::text from chok.sauvegardes), 'au moins 1',
         (select count(*) from chok.sauvegardes) > 0
  union all
  select 9, 'Tâches de nuit programmées (pg_cron)',
         chok.nb_taches()::text,
         '5  — si 0, activez pg_cron dans Database → Extensions',
         chok.nb_taches() > 0
  union all
  select 10, 'Délai accordé aux opérations lourdes',
         case when exists (select 1 from pg_proc p
                             join pg_namespace n on n.oid = p.pronamespace
                            where n.nspname = 'public' and p.proname = 'chok_api'
                              and 'statement_timeout=120s' = any(coalesce(p.proconfig, '{}')))
              then '120 s' else 'ABSENT (3 s par défaut)' end,
         '120 s — sinon la remise à zéro est coupée en plein travail',
         exists (select 1 from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'chok_api'
                    and 'statement_timeout=120s' = any(coalesce(p.proconfig, '{}')))
  union all
  select 11, 'Remise à zéro en deux temps (sauvegarde exigée avant effacement)',
         case when pg_get_functiondef('public.chok_api(jsonb)'::regprocedure)
                   like '%sauvegardeFaite%' then 'en place' else 'ANCIENNE VERSION' end,
         'en place — sinon l''ancien script est encore actif',
         pg_get_functiondef('public.chok_api(jsonb)'::regprocedure) like '%sauvegardeFaite%'
  union all
  select 12, 'Code direction',
         case when coalesce(chok.config_lire('pinRH'),'') = '' then 'ABSENT'
              when length(chok.config_lire('pinRH')) < 6 then 'TROP COURT (moins de 6 chiffres)'
              else 'défini' end,
         'défini, 6 à 8 chiffres',
         coalesce(chok.config_lire('pinRH'),'') ~ '^\d{6,8}$'
  union all
  -- La clé n'est plus affichée ici : ce tableau reste dans l'historique de
  -- l'éditeur SQL. Pour la lire : select chok.config_lire('cleExport');
  select 13, 'Clé du robot de sauvegarde',
         case when coalesce(chok.config_lire('cleExport'),'') <> '' then 'définie' else 'ABSENTE' end,
         'définie — la lire avec : select chok.config_lire(''cleExport'');',
         coalesce(chok.config_lire('cleExport'),'') <> ''
  union all
  select 14, 'Personnes actives SANS CODE (ne peuvent pas se connecter)',
         coalesce((select count(*)::text || ' — ' || string_agg(x.nom, ', ' order by x.nom)
                     from (select s.nom, s.code from chok.salaries s where coalesce(s.actif, true)
                           union all
                           select i.nom, i.code from chok.interimaires i
                            where coalesce(i.actif, true)
                              and (chok.est_chef(i.poste) or i."accesPlateforme")) x
                    where coalesce(nullif(x.code,''),'0000') = '0000'
                   having count(*) > 0), '0'),
         '0 — sinon donner un code dans Direction → Salariés / Intérimaires',
         not exists (select 1 from chok.salaries s
                      where coalesce(s.actif, true) and coalesce(nullif(s.code,''),'0000') = '0000')
         and not exists (select 1 from chok.interimaires i
                          where coalesce(i.actif, true)
                            and (chok.est_chef(i.poste) or i."accesPlateforme")
                            and coalesce(nullif(i.code,''),'0000') = '0000')
)
select n as "n°",
       case when bon then '✅' else '❌ À VOIR' end as "état",
       quoi as "contrôle", valeur as "valeur", attendu as "attendu"
  from controles
union all
select 99,
       case when (select bool_and(bon) from controles) then '✅' else '❌' end,
       case when (select bool_and(bon) from controles)
            then 'INSTALLATION TERMINÉE — passez à CHOK_BETON_TESTS.sql'
            else 'UN POINT AU MOINS EST À REGARDER (voir les lignes ❌ ci-dessus)' end,
       '', ''
order by 1;
