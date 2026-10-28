# CHOK BÉTON — Guide d'utilisation et de maintenance

Application « Rapport Heure ». Données hébergées dans votre base Supabase privée.

---

# 1. Mise en service (à faire une fois)

## Étape 1 — Créer le projet

1. Aller sur **supabase.com**, se connecter, **New project**
2. Nom : `chok-beton` · Région : **West EU (Paris)** ou **Frankfurt**
3. Choisir un mot de passe de base de données et **le conserver**
4. Attendre environ 2 minutes que le projet soit prêt

## Étape 2 — Installer le serveur

1. Menu de gauche → **SQL Editor** → **New query**
2. Ouvrir `CHOK_BETON_SUPABASE.sql`, tout copier, tout coller
3. **Run**

En bas s'affiche un **tableau de 11 contrôles**, avec une colonne **état**.
Lisez-la de haut en bas : tout doit être ✅, et la dernière ligne doit dire
**« INSTALLATION TERMINÉE »**.

Deux lignes méritent votre attention :

- **« Ouvertures accordées sur les tables » = 0** est normal et voulu. Aucune
  ouverture n'est accordée : tout passe par `chok_api`.
- **« CLÉ DU ROBOT DE SAUVEGARDE »** : recopiez-la, elle sert à l'étape 8.

Si **« Tâches de nuit programmées » = 0**, activez l'extension **pg_cron**
(Database → Extensions), puis relancez le script.

Si **« Chefs d'équipe désignés » = 0**, voyez l'étape 6 : sans chef, personne
ne peut saisir d'heures.

## Étape 3 — Contrôler

Nouvelle requête, coller `CHOK_BETON_TESTS.sql`, **Run**.

Le verdict doit être : **« Serveur conforme »**. Sinon, ne mettez rien en
service et signalez les lignes en échec.

Il crée des personnes et des heures fictives, puis **annule tout** : les trois
derniers nombres affichés doivent être à **0**. C'est la preuve que rien n'a
survécu.

Par la suite, `select * from chok.controle();` revérifie le serveur en une ligne.

## Étape 4 — Relier l'application

Tableau de bord → **Project Settings** → **API** :

| À copier | Où le mettre |
|---|---|
| **Project URL** (`https://xxxx.supabase.co`) | `SUPABASE_URL_DEFAUT`, en haut de `index.source.html` |
| Clé **anon / public** | `SUPABASE_KEY_DEFAUT`, juste en dessous |

Puis reconstruire `index.html` (voir « Mettre à jour à distance ») et
déposer les fichiers chez l'hébergeur.

> **La clé « anon » est publique par conception.** Elle ne donne accès à
> rien : les tables sont verrouillées et elle ne permet que d'appeler
> `chok_api`, qui exige un code personnel. Ne copiez **jamais** la clé
> `service_role`, elle, qui donne tous les droits.

## Étape 5 — Première connexion

Ouvrir l'application → **🏢 ACCÈS DIRECTION** → code **010126**.
Il se change dans ⚙ Paramètres (6 à 8 chiffres).

## Étape 6 — Les chefs d'équipe

**Chez CHOK'BÉTON, tous les salariés sont chefs d'équipe** : chacun saisit
ses heures, et un chef peut saisir la journée d'un autre chef qui travaille
avec lui. Un nouveau salarié est créé « Chef d'équipe » par défaut.

Parmi les **intérimaires**, seuls ceux que la direction désigne « Chef
d'équipe » saisissent eux-mêmes leurs heures. Les autres sont rattachés à un
chef référent, qui les saisit pour eux.

Tout se règle dans l'application (Direction → Salariés / Intérimaires) ; le
script d'installation ne touche plus aux postes.

C'est le **poste** qui donne le droit de saisir : seul un « Chef d'équipe »
dispose de l'écran de saisie. Un bandeau rouge vous prévient si jamais plus
personne ne l'est.

Pour changer le poste d'une personne : Direction → **Salariés** → **Modifier**.

> **Ce que cela implique :** chacun peut déclarer ses heures, celles de ses
> intérimaires, et celles des collègues présents avec lui. C'est voulu — sur
> un chantier, celui qui a le téléphone saisit pour l'équipe. Le serveur
> refuse en revanche la **double déclaration** : si deux personnes saisissent
> le même collègue le même jour sur le même chantier, la seconde est bloquée
> et voit qui a déjà saisi. Et **on ne supprime que ce qu'on a soi-même saisi**.

## Étape 7 — Récapitulatif par e-mail (facultatif)

Une base PostgreSQL ne sait pas envoyer de courrier seule, contrairement au
serveur Google. Il faut lui adjoindre un service d'envoi.

1. Créer un compte sur **resend.com** (gratuit, 3 000 messages par mois)
2. Y créer une clé d'API (elle commence par `re_`)
3. Dans le SQL Editor, une seule fois :

```sql
select chok.config_ecrire('cleEmail', 're_votre_cle_ici');
select chok.config_ecrire('emailRH', 'direction@chokbeton.fr');
```

4. Contrôler tout de suite : `select chok.recap_hebdomadaire();`

Vous recevez alors le récapitulatif chaque **lundi à 7 h**, et une alerte si
une sauvegarde vient à manquer.

> La clé se met **uniquement en SQL**, jamais dans l'application : celle-ci est
> publique, tout le monde pourrait la lire. L'adresse de destination, elle, se
> règle normalement dans ⚙ Paramètres.

## Étape 8 — Sauvegarde sur Google Drive (recommandé)

Les sauvegardes de la base vivent **dans** la base. Elles vous protègent d'une
fausse manœuvre, pas de la perte du projet. Ce robot pose une copie ailleurs.

1. Dans Supabase, relever la clé du robot :

```sql
select chok.config_lire('cleExport');
```

2. Aller sur **script.google.com** → Nouveau projet, le nommer
   « CHOK BÉTON — Sauvegarde Drive »
3. Effacer le contenu, coller **`CHOK_BETON_DRIVE.gs`** en entier
4. Y recopier la clé relevée à l'étape 1 (ligne `CLE_EXPORT`)
5. Menu **Exécuter** → fonction **`installer`** → Exécuter
   (Google demande une autorisation la première fois : accepter)

Vous obtenez un dossier **CHOK BÉTON — Sauvegardes** dans votre Drive, alimenté
chaque nuit vers 3 h : **30 copies quotidiennes**, plus celle du 1er de chaque
mois, **conservée indéfiniment**.

Pour contrôler à tout moment : fonction **`verifier`** dans ce même projet.

> **La clé du robot donne accès à toutes les données en lecture.** Elle est à
> sa place dans ce projet Apps Script, qui est privé. Elle ne figure jamais
> dans l'application, qui est publique. Ne l'envoyez à personne.

En cas de panne — base injoignable, clé fausse, réponse vide — le robot vous
écrit et **n'écrase rien**.

---

# 2. Utilisation au quotidien

## Se connecter

Tout le monde passe par le même écran : **on touche son nom, puis on saisit
son code personnel à 4 chiffres**. Une recherche apparaît au-delà de 6 noms.

L'application s'adapte ensuite au **poste** inscrit sur la fiche :

| Poste | Ce que la personne peut faire |
|---|---|
| **Chef d'équipe** | Déclarer des heures (les siennes, celles de ses intérimaires, celles des collègues présents avec lui) |
| Tout autre poste | Consulter uniquement ses propres heures |

> **C'est le poste qui donne le droit de saisir.** Pour qu'une personne
> puisse déclarer des heures, mettez-lui « Chef d'équipe » dans l'onglet
> Salariés.

L'accès direction se fait par le bouton discret **🏢 ACCÈS DIRECTION** en bas.
La session reste ouverte **7 jours** : un rafraîchissement ne déconnecte pas.

## Saisir un rapport (chef d'équipe)

La saisie se fait **par étapes**, une à la fois ; la suivante ne s'ouvre que
si la précédente est remplie :

1. **Date** (aujourd'hui ou l'un des 5 jours précédents)
2. **Client**
3. **Adresse du chantier** — seuls les chantiers de ce client sont proposés
4. **Mes heures**
5. **Mes intérimaires** (facultatif)
6. **Vérifier et envoyer**

**Chaque chef remplit SA feuille** et n'y ajoute que ses intérimaires : il ne
déclare plus les heures d'un autre salarié (règle du 06/10/2026). Des heures
déjà envoyées ne repartent jamais : revenir sur une journée pour ajouter un
intérimaire n'envoie que l'intérimaire. Le serveur refuse toute ligne qui
chevauche une ligne déjà enregistrée pour la même personne le même jour.

Une étape faite se résume en une ligne ; un toucher la rouvre.

En haut de page, un récapitulatif de ses heures de la semaine ou du mois.

- L'adresse d'un nouveau chantier **se complète automatiquement** (base
  officielle française), en ne proposant que l'**Île-de-France**, Paris en tête.
- Le **client** a sa propre case et il est **obligatoire**. Il est rangé avec
  le chantier : il revient tout seul, et un chef peut le corriger (pour tout
  le monde sur ce chantier). Les chantiers s'affichent « Client — adresse ».
- **Alléger ses listes** : sous les cases Chantier et Client, chaque chef peut
  retirer de SA liste ce qui ne le concerne plus, et le remettre plus tard.
  Rien n'est effacé pour les autres ; le réglage reste sur son téléphone.
- Au-delà de 5 jours, seule la direction peut encore enregistrer des heures.

## Ce que la direction peut modifier

Tout, à toute date, sans limite :

- **Régulariser des heures** (oubli, heures en plus, correction après contrôle) :
  Direction → Pointages → **+ RÉGULARISER / AJOUTER DES HEURES**. Personne,
  date (sans limite), chantier, horaires et **motif obligatoire**. La ligne est
  enregistrée validée, avec « Régularisation : motif », et marquée **RÉGUL.**
  Si la personne a déjà des heures ce jour-là, elles sont affichées et il faut
  confirmer qu'il s'agit d'heures EN PLUS (sinon, corrigez la ligne existante).
  **Mois déjà clos** : une journée d'un mois passé (ex. un samedi de septembre
  régularisé en octobre) est payée sur le **mois en cours**. Le rapport
  d'octobre la montre dans un bloc « Régularisations », avec ses majorations
  calculées dans sa vraie semaine ; celui de septembre ne change pas. Le choix
  « mois de la date » reste possible dans le formulaire, et le mois de paie se
  change aussi en modifiant la ligne (✎). Badge **PAYÉ EN …** dans la liste.
- **Paniers** (salariés seulement) : automatiques, 1 panier par jour
  travaillé, logé ou non. Rien à saisir pour les chefs. Dans Pointages, la
  pastille **🥪 PANIER** se clique pour retirer le panier d'une journée
  (barrée = retiré), et se reclique pour le remettre. Le rapport affiche le
  panier jour par jour, le nombre par semaine et le total « PANIERS » du mois.
  Une régularisation d'un jour sans aucune heure donne son panier sur le mois
  de paie ; un complément d'heures sur un jour déjà payé n'en redonne pas.
- **État de paie** (onglet du même nom) : le tableau mensuel à transmettre
  pour la paie, une colonne par salarié. Calculé automatiquement (cases
  grises) : heures normales, samedis, heures à 25/50/100 %, A.T, maladie,
  absences diverses, congés (en jours), paniers, déplacements (jours logés).
  Saisi par la direction (cases blanches, enregistré en quittant la case) :
  matricule (une fois pour toutes), maj. poste 10 %, maj. H.D. 50 %, prime,
  13e mois, acomptes, prêts, saisie, Navigo, frais parking/péage, ventil. MO.
  Boutons **IMPRIMER / PDF** (A4 paysage) et **EXCEL** (fichier .csv).
- **Pense-bête** (onglet Salariés, salariés seulement) : « 📝 ajouter une
  note » sous le nom. Rappelé dans les pointages et en tête de la fiche de
  chaque salarié dans le rapport mensuel. Visible par la direction seulement,
  jamais envoyé aux téléphones des chefs ni des salariés.
- **Pointages** : ajouter (n'importe qui, n'importe quel jour), modifier
  personne, date, chantier, horaires, logement, commentaire ; valider, ou
  revenir sur une validation (↺) ; supprimer.
- **Absences et congés** : ajouter, modifier, supprimer.
- **Chantiers** : nom / adresse, ville, client ; fermer ou rouvrir. Depuis
  les pointages aussi : lien **✎ corriger** sous le nom du chantier.
- **Clients** (onglet Chantiers) : renommer un client mal orthographié, ou le
  **fusionner** avec la bonne orthographe — tous ses chantiers suivent. Les
  noms qui se ressemblent sont signalés « ⚠ ressemble à ».

*Fautes de frappe des chefs* : elles viennent de la **correction automatique
du clavier** du téléphone (« Spie » → « Spielberg »), pas de l'application.
Elle est désormais coupée dans les champs client et adresse, et un nouveau
client proche d'un client connu déclenche « Vouliez-vous dire… ? ».
- **Salariés et intérimaires** : nom, poste, code, chef référent ; archiver.
- Un dimanche ou un jour férié, un bandeau rouge signale la majoration à 100 %.
- **Un seul chef doit déclarer un collègue donné.** Le serveur refuse la
  double déclaration et indique qui a déjà saisi.

## Corriger une erreur

Section **« Mes derniers envois »** en bas de la page du chef : les 10
derniers jours, avec **Corriger** et **Supprimer** tant que la direction n'a
pas validé. Une fois validée, la ligne est verrouillée — il faut passer par vous.

Règles : on corrige ses propres lignes ou celles qui nous concernent ;
**on ne supprime que ce qu'on a soi-même saisi**.

## Si un rapport ne part pas

Un bandeau apparaît avec **📤 Renvoyer maintenant** et **🔍 Tester la connexion**.

- **Bandeau orange** : pas de réseau. Les heures sont sur le téléphone, elles
  repartiront seules.
- **Bandeau rouge** : refus du serveur, avec la raison exacte à vous signaler.

Rien n'est jamais perdu : une saisie non transmise reste sur l'appareil.

---

# 3. Côté direction

| Onglet | Usage |
|---|---|
| **Pointages** | Jour par jour, navigation libre dans le passé, validation, alertes légales |
| **Absences** | Saisie des absences et soldes de congés de tous les salariés |
| **Salariés** | Ajouter / modifier / **archiver**, codes d'accès (4 à 8 chiffres), congés. Un code `0000` = accès fermé |
| **Intérimaires** | Idem, avec agence, chef référent et **fin de mission** |
| **Chantiers** | Créer, fermer, supprimer |
| **Rapport** | Le document de paie — voir ci-dessous |
| **Archives** | Semaines passées, historique complet à la demande |
| **⚙ Paramètres** | Code direction, adresse du serveur, remise à zéro |

## Le rapport hebdomadaire

**Semaine du lundi au dimanche**, et par défaut la **semaine écoulée** —
celle qu'on paie. Les flèches ‹ › permettent de remonter aussi loin qu'il faut.

- **Intérimaires** : payés à la semaine. Ce rapport fait foi et justifie la
  facture de l'agence.
- **Salariés** : payés au mois. Il sert au contrôle en cours de mois. Une
  erreur repérée le lundi se corrige ; la même repérée le 30 coûte une paie.

L'export PDF sépare les deux liasses.

## Le rapport de paie

Choisissez **une personne** (ou toutes) et **une période** : semaine, mois
(sélecteur de mois), **dates libres**, ou tout l'historique.

Chaque fiche présente : identité, **solde de congés**, **absences de la
période**, totaux (base, +25 %, +50 %, +100 %, heures de nuit, nuitées), puis
le détail jour par jour avec sous-totaux hebdomadaires.

Le bouton **👁 Aperçu** montre le document tel qu'il sera imprimé, en **A4
portrait**, une personne par page. De là, **Imprimer / Enregistrer en PDF**.

## Règles de calcul appliquées

| Règle | Valeur |
|---|---|
| Base hebdomadaire | 35 h |
| De la 36ᵉ à la 43ᵉ heure | **+25 %** |
| Au-delà de 43 h | **+50 %** |
| Dimanche et jours fériés | **+100 %** (ces heures ne sont pas recomptées en heures sup) |
| Heures de nuit | 20 h – 06 h |
| Congés payés | **30 jours ouvrables** (lundi→samedi, hors dimanches et fériés) |
| Poste de 24 h | Saisir la même heure en début et fin (ex. 06:00 → 06:00) |

Les 11 jours fériés français sont calculés automatiquement, y compris les
fériés mobiles (Pâques, Ascension, Pentecôte).

---

# 4. Installation sur les téléphones

- **Android** : ouvrir l'adresse dans Chrome → menu ⋮ → *Ajouter à l'écran d'accueil*
- **iPhone** : ouvrir dans **Safari** (obligatoire) → Partager → *Sur l'écran d'accueil*

Aucune configuration n'est nécessaire : l'adresse du serveur est intégrée à
l'application.

## Mettre à jour à distance

1. Modifier **`index.source.html`** (jamais `index.html`)
2. Reconstruire `index.html`, dans le Terminal, depuis le dossier `outils` :
   `npm install` (la première fois seulement), puis `npm run construire`
3. Ouvrir `sw.js` et incrémenter le numéro de version (`v50` → `v51`)
4. Déposer **`index.html`, `sw.js` et le dossier `vendor/`** chez
   l'hébergeur (`vendor/` ne change qu'avec la version de React)

Les téléphones récupèrent la nouvelle version seuls. Un bandeau jaune propose
*« Une nouvelle version est disponible »*. Aucune réinstallation.

Vérifiez le numéro affiché en bas de l'application pour confirmer.

---

# 5. Correspondance avec l'ancien serveur Google

| Fonction du serveur Google | Sur la nouvelle base |
|---|---|
| Connexion par code personnel, blocage après 5 erreurs | Identique |
| Cloisonnement par rôle (direction / chef / salarié) | Identique |
| Droits d'écriture, double déclaration, lignes validées | Identique |
| Garde anti-suppression massive | Identique |
| Journal d'audit (qui a fait quoi) | Identique |
| Verrou d'écriture simultanée | Identique |
| Sauvegarde quotidienne (30 copies, dans Drive) | **60 copies**, conservées en base |
| Sauvegarde mensuelle conservée indéfiniment | Identique |
| Sauvegarde avant toute remise à zéro | Identique |
| Sauvegardes déposées dans Google Drive | Identique (§ 1, étape 8) |
| Récapitulatif hebdomadaire par e-mail | Identique (§ 1, étape 7) |
| Alerte en cas d'échec de sauvegarde | Identique (§ 1, étape 7) |
| Maintien du serveur en éveil | **Sans objet** : la base ne dort pas |
| `installer`, `verifierInstallation` | Remplacés : le script se rejoue |
| `mettreAJourListeSalaries` | Remplacé : la liste est dans le script |
| Diagnostic `?action=etat` | `select public.chok_api('{"action":"etat"}');` |

---

# 6. Ce qui protège vos données

| Protection | Fonctionnement |
|---|---|
| Tables verrouillées | Le schéma n'est pas exposé, RLS active, aucune politique ouverte |
| Point d'entrée unique | Seule `chok_api` est appelable ; elle exige un code personnel |
| Cloisonnement serveur | Chacun ne reçoit que ses données — incontournable depuis le téléphone |
| Sauvegarde quotidienne | 2 h du matin, 60 copies glissantes, conservées en base |
| Avant toute remise à zéro | Sauvegarde obligatoire, **jamais purgée** |
| Anti-suppression massive | Refus au-delà de la moitié d'une table |
| Copie de nuit sur Google Drive | 30 quotidiennes + tous les 1ers du mois |
| Téléchargement à la demande | Direction → ⚙ Paramètres |
| Journal d'audit | Table `journal` : qui a fait quoi, quand |
| Verrou d'écriture | Deux chefs simultanés ne s'écrasent pas |
| File d'attente | Aucune saisie perdue sans réseau |

## Consulter une sauvegarde

SQL Editor :

```sql
select id, cree, motif, lignes from chok.sauvegardes order by cree desc limit 20;
```

## Restaurer une sauvegarde

```sql
-- Remplacez 12 par l'identifiant voulu, vu ci-dessus.
select chok.sauvegarde_complete('avant restauration');   -- filet supplémentaire
delete from chok.pointages;
insert into chok.pointages
select * from jsonb_populate_recordset(null::chok.pointages,
  (select contenu->'pointages' from chok.sauvegardes where id = 12));
```

---

# 7. Maintenance

## Diagnostic

Dans l'onglet **⚙ Paramètres**, le bouton **⚡ TESTER** indique le temps de
réponse réel. Attendu : **150 à 300 ms**.

En SQL, pour un état complet :

```sql
select public.chok_api('{"action":"etat"}'::jsonb);
```

## Voir qui a fait quoi

```sql
select horodatage, action, role, personne, cible, details
  from chok.journal order by horodatage desc limit 50;
```

## Dépannage

**« Fonction chok_api introuvable »** → le script `CHOK_BETON_SUPABASE.sql`
n'a pas été exécuté, ou l'adresse du projet est fausse.

**« Clé d'accès refusée »** → mauvaise clé. Reprenez la clé **anon**, pas la
`service_role`.

**« Serveur non configuré » sur l'écran de connexion** → l'adresse et la clé
ne sont pas inscrites dans l'application. Renseignez-les dans Paramètres, ou
mieux, dans `index.source.html` avant de reconstruire.

**« Trop de codes erronés »** → 5 essais libres, puis blocage de 15 min,
30 min, 1 h, 2 h… (jusqu'à 64 h) à chaque nouvelle erreur. Le compteur est
gardé 30 jours. Pour débloquer quelqu'un tout de suite : Direction →
Salariés → Modifier → lui donner un nouveau code, ce qui le débloque
aussitôt. Ou, dans le SQL Editor : `delete from chok.blocages;`

**« Aucun code personnel ne vous a encore été attribué »** → la fiche porte
le code `0000`, qui n'ouvre plus rien. Donnez-lui un code.

**« Votre accès à l'application n'est pas ouvert »** → personne archivée, ou
intérimaire sans « accès plateforme » coché.

**Un nom ne disparaît pas de la liste** → la liste est gardée 24 h sur
l'appareil. Fermez et rouvrez l'application.

**Projet en pause** → l'offre gratuite met le projet en veille après 7 jours
sans aucune activité. Un clic dans le tableau de bord le réveille. Avec un
usage quotidien, cela n'arrive pas.

---

# 8. Points non traités (à décider avant le lancement réel)

1. **Suivi des saisies manquantes** — vous ne voyez pas qui n'a pas déclaré.
2. **Verrouillage de période** — un mois déjà payé reste modifiable.
3. **Codes = années de naissance** — choix assumé (mémorisables), mais
   devinables. La protection repose sur le blocage progressif ; des codes
   aléatoires de 6 chiffres resteraient plus sûrs.
4. **Contrôle absence / heures** — un chef peut déclarer des heures pour
   quelqu'un en congés, sans alerte.
5. **Report des congés** — les jours non pris disparaissent au 31 décembre.
6. **Période de référence des congés** — année civile ; à confirmer avec
   votre comptable si votre convention utilise 1er juin – 31 mai.
7. **Récapitulatif hebdomadaire par e-mail** — assuré auparavant par Google.
   À rebrancher si vous le souhaitez (Supabase le permet, via une fonction
   planifiée et un service d'envoi).
