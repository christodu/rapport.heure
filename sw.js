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
//     incrémentez le numéro ci-dessous (v3, v4, …).
//     C'est ce qui force les téléphones à purger l'ancien cache.
// ============================================================
const VERSION = "v4";
const CACHE = `chok-beton-${VERSION}`;
const ASSETS = ["./index.html", "./icon-192.png", "./icon-512.png", "./manifest.json"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)).catch(() => {}));
  self.skipWaiting();
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
  if (url.hostname.includes("script.google.com")) return;    // serveur : toujours en direct

  e.respondWith(
    fetch(req)
      .then(rep => {
        // On rafraîchit le cache au passage, pour le mode hors ligne.
        if (rep && rep.ok && url.origin === self.location.origin) {
          const copie = rep.clone();
          caches.open(CACHE).then(c => c.put(req, copie)).catch(() => {});
        }
        return rep;
      })
      .catch(() => caches.match(req).then(r => r || caches.match("./index.html")))
  );
});
