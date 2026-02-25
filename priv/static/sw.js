self.addEventListener("install", (event) => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

// Minimal SW: required for installability; avoid aggressive caching for LiveView apps.
self.addEventListener("fetch", (_event) => {});

