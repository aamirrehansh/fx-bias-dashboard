/* Offline cache: app shell cache-first, data network-first (falls back to cache). */
const V = "fxbias-v15";
const SHELL = ["./", "index.html", "styles.css", "app.js", "data/weeks.js", "data/rates.js", "manifest.webmanifest", "icons/icon-192.png", "icons/icon-512.png"];
self.addEventListener("install", (e) => { e.waitUntil(caches.open(V).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener("activate", (e) => { e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== V).map((k) => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener("fetch", (e) => {
  const u = new URL(e.request.url);
  if (e.request.method !== "GET" || u.origin !== location.origin) return;
  const isData = u.pathname.includes("/data/") || u.pathname.endsWith("app.js") || u.pathname.endsWith("index.html") || u.pathname.endsWith("/");
  if (isData) {
    e.respondWith(fetch(e.request).then((r) => { if (r.ok) { const cp = r.clone(); caches.open(V).then((c) => c.put(e.request.url.split("?")[0], cp)); } return r; })
      .catch(() => caches.match(e.request.url.split("?")[0]).then((r) => r || caches.match("index.html"))));
  } else {
    e.respondWith(caches.match(e.request).then((r) => r || fetch(e.request)));
  }
});
self.addEventListener("notificationclick", (e) => { e.notification.close(); e.waitUntil(self.clients.matchAll({ type: "window" }).then((cs) => cs.length ? cs[0].focus() : self.clients.openWindow("./"))); });
