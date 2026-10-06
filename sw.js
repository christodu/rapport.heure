// ============================================================
//  CHOK BÉTON — Service Worker
//  Rôle : permettre l'usage hors ligne ET garantir que les
//  téléphones reçoivent les mises à jour sans réinstallation.
//
//  Stratégie :
//   - "réseau d'abord" : à chaque ouverture avec du réseau, le
//     téléphone récupère la dernière version déposée sur l'hébergeur ;
//   - repli sur le cache uniquement si le réseau est absent (chantier) ;
//   - skipWaiting + clients.claim : la nouvelle version prend la main
//     immédiatement, sans attendre la fermeture de l'application.
//
//  ⚠ À CHAQUE MISE EN LIGNE D'UNE NOUVELLE VERSION :
//     incrémentez le numéro ci-dessous (v50, v51, …).
//     C'est ce qui force les téléphones à purger l'ancien cache.
// ============================================================
const VERSION = "v58";
const CACHE = `chok-beton-${VERSION}`;
// React fait partie du lot : sans lui, l'application hors ligne restait
// une page blanche, même avec index.html en cache.
const ASSETS = ["./index.html", "./manifest.json", "./icon-192.png", "./icon-512.png",
                "./vendor/react.production.min.js", "./vendor/react-dom.production.min.js"];
const ADRESSES = new Set(ASSETS.map(a => new URL(a, self.location).href));

self.addEventListener("install", e => {
  // Si le lot ne se télécharge pas en entier (réseau de chantier), l'install
  // ÉCHOUE et l'ancienne version reste en place avec son cache. Avaler
  // l'erreur, comme avant, activait une version sans cache et effaçait
  // l'ancien : le téléphone perdait son mode hors ligne.
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("message", e => {
  if (e.data === "SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;                          // écritures : jamais en cache
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;          // serveur, polices… : en direct

  e.respondWith(
    fetch(req)
      .then(rep => {
        // On rafraîchit le cache au passage, pour le mode hors ligne — mais
        // seulement les fichiers de l'application, pas n'importe quelle
        // adresse visitée (le cache grossissait sans limite).
        if (rep && rep.ok && (ADRESSES.has(url.origin + url.pathname) || req.mode === "navigate")) {
          const copie = rep.clone();
          caches.open(CACHE).then(c => c.put(req, copie)).catch(() => {});
        }
        return rep;
      })
      .catch(() => caches.match(req, { ignoreSearch: true }).then(r => {
        if (r) return r;
        // Une PAGE demandée hors ligne reçoit l'application. Un script ou une
        // image, non : leur renvoyer du HTML provoquait une erreur muette.
        if (req.mode === "navigate") return caches.match("./index.html");
        return Response.error();
      }))
  );
});
