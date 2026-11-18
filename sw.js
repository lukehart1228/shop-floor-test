/* Shop Floor — lets the app open with no Wi-Fi.
   Pages, and the shop's own scripts and stylesheets (sf-common…js, sf-style…css):
   fetched fresh when there's a connection (so updates arrive), the saved copy when
   there isn't. Libraries from the CDN, fonts and icons: saved copy first.
   Database requests are never touched — the app handles those itself.
   17 Nov: live (…/shop-floor/) and test (…/shop-floor-test/) share one GitHub name, so a browser that opens
   both holds both sites' saved copies side by side. Each helper keeps to its own: its name comes from
   sfName() (unchanged on live, ending -test on test), it clears only its own site's older copies, and it
   reads only its own copy. */
/* ===== THE SITE: LIVE OR TEST, FROM THE ADDRESS (17 Nov 2026) =====================================
   Word for word the same in index.html, tv.html, sw.js and the shared script (test_site_block.js checks it).
   Live and test run the same files byte for byte; the folder this page was opened from says which it is:
   a folder named shop-floor is live, one named shop-floor-test is test, anything else stops.
   Both publishable keys are here; neither is secret. NEVER a secret key: these files are public.
   Live and test share one GitHub name, so a browser would mix what they save. On test every name a page
   saves under on the device ends in -test (sfName); live's names are unchanged. Plain old JavaScript:
   the floor TV's browser reads this too. */
var SF_SITES = {
  live: { folder: "shop-floor", url: "https://fueyfxjxlicqekaqtydi.supabase.co", key: "sb_publishable_A5rEVQSSejSsQW7nhAX6iw_gNA5EZ9A", ending: "" },
  test: { folder: "shop-floor-test", url: "https://qonmvdusaanbpgobzqep.supabase.co", key: "sb_publishable_ssHGsQ2IlMKJNU35kM9IAQ_JocxExB6", ending: "-test" }
};
var SF_TEST_WORDS = "TEST, not the real floor";
var SF_TEST_FOLDER = "Production TEST";
function sfSiteOf(path) {
  var parts = String(path || "").split("/"), folder = parts.length > 1 ? parts[parts.length - 2] : "";
  return folder === SF_SITES.live.folder ? "live" : folder === SF_SITES.test.folder ? "test" : null;
}
var SF_SITE = sfSiteOf(typeof location !== "undefined" ? location.pathname : "");
var SUPABASE_URL = SF_SITE ? SF_SITES[SF_SITE].url : "";
var SUPABASE_KEY = SF_SITE ? SF_SITES[SF_SITE].key : "";
/** Every name this page saves under on the device: as it always was on live, ending -test on test. */
function sfName(name) {
  if (!SF_SITE) throw new Error("This page isn't at the live or the test address, so it keeps nothing on this device.");
  return name + SF_SITES[SF_SITE].ending;
}
/** Why this page can't start at this address, in words; null when it can. */
function sfSiteProblem() {
  if (!SF_SITE) return "This page was opened from an address that is neither the live app (…/shop-floor/) nor the test app (…/shop-floor-test/), so it doesn't know which database to use. Open it from its usual link.";
  if (SF_SITE === "test" && (SUPABASE_URL.indexOf("PASTE-") >= 0 || SUPABASE_KEY.indexOf("PASTE-") >= 0))
    return "The test project's address and publishable key haven't been filled in yet. A chat puts them in the SF_SITES lines of index.html, tv.html, sw.js and the shared script.";
  return null;
}
/** The second lock. answer: "live" or "test" (what the database says), "missing" (a database from before 17 Nov,
 *  which can only be live) or null (couldn't ask: no connection). Words when this page must stop; null otherwise. */
function sfDatabaseProblem(answer) {
  if (SF_SITE === "test" && (answer === "live" || answer === "missing"))
    return "This is the test app, but the database it reached doesn't say it is the test database. It has stopped and saves nothing. Tell Luke.";
  if (SF_SITE === "live" && answer === "test")
    return "This is the live app, but the database it reached is the test database. It has stopped and saves nothing. Tell Luke.";
  return null;
}
/** Ask the database which it is (after sign-in; a login is needed) and call back with what sfDatabaseProblem takes. */
function sfAskDatabase(db, done) {
  try {
    Promise.resolve(db.rpc("which_database")).then(function (r) {
      if (r && !r.error && (r.data === "live" || r.data === "test")) return done(r.data);
      var e = (r && r.error) || {}, words = String(e.message || "");
      if (e.code === "PGRST202" || e.code === "42883" || /could not find the function|function .* does not exist/i.test(words)) return done("missing");
      done(null);
    }, function () { done(null); });
  } catch (e) { done(null); }
}
/** Stop the page for good: sign this device out of that database and say why. */
function sfStopPage(db, words) {
  try { if (db && db.auth) Promise.resolve(db.auth.signOut({ scope: "local" })).then(function () {}, function () {}); } catch (e) {}
  if (typeof document === "undefined" || !document.body) return;
  document.body.innerHTML = "";
  var box = document.createElement("div");
  box.setAttribute("role", "alert");
  box.style.cssText = "margin:40px auto; max-width:640px; padding:24px; border-radius:12px; background:#181D2E; color:#FFF4D5; font:18px/1.4 sans-serif";
  box.innerHTML = "<h1 style=\"margin:0 0 12px; font-size:26px\">Stop: wrong database</h1><p style=\"margin:0\"></p>";
  box.lastChild.textContent = words;
  document.body.appendChild(box);
}
/** Once a login is signed in, check the database is the one this address means; stop the page if not. */
function sfGuardDatabase(db) {
  var asked = false;
  function ask() {
    if (asked) return;
    asked = true;
    sfAskDatabase(db, function (answer) {
      var p = sfDatabaseProblem(answer);
      if (p) sfStopPage(db, p);
      else if (answer === null) asked = false;               // no connection: ask again at the next sign-in event
    });
  }
  try {
    if (db && db.auth && typeof db.auth.onAuthStateChange === "function")
      db.auth.onAuthStateChange(function (ev, session) { if (session) setTimeout(ask, 0); });
    else if (db && db.auth) Promise.resolve(db.auth.getSession()).then(function (r) { if (r && r.data && r.data.session) ask(); }, function () {});
  } catch (e) {}
}
/** On test: the bar across the top of the page, in the header's own midnight and sawdust (no new colour).
 *  Not inside the office's frames: the office above them carries it. */
function sfTestBar() {
  if (SF_SITE !== "test" || typeof document === "undefined" || !document.body || document.getElementById("sfTestBar")) return;
  try { if (window.parent !== window && /[?&]embed=1\b/.test(location.search)) return; } catch (e) {}
  var css = document.createElement("style");
  css.textContent = "#sfTestBar{position:sticky; top:0; z-index:2147483000; height:24px; line-height:24px; text-align:center;"
    + " background:#FFF4D5; color:#181D2E; border-bottom:2px solid #181D2E; font:700 14px/24px sans-serif; letter-spacing:.06em}"
    + " body>.top, body>header{top:26px !important}"
    + " @media print{html body>#sfTestBar{display:block !important; position:static !important}}";
  document.head.appendChild(css);
  var bar = document.createElement("div");
  bar.id = "sfTestBar"; bar.setAttribute("role", "note"); bar.textContent = SF_TEST_WORDS;
  document.body.insertBefore(bar, document.body.firstChild);
  document.title = "TEST · " + document.title;
}
/** On test, a folder the app saves into must be named Production TEST; words when this one can't be used, else null. */
function sfFolderProblem(folderName) {
  if (SF_SITE !== "test" || folderName === SF_TEST_FOLDER) return null;
  return "This is the test app, so it saves only into a folder named " + SF_TEST_FOLDER + ", never the real Production folder, the backup drive, Claudes Shop System Folder or PD - POs. Make a folder named " + SF_TEST_FOLDER + " outside Production and choose that. Nothing was changed.";
}
/** On test, every PDF this app makes says so: a band across the top of each page. On live the PDF is untouched. */
function sfMarkPdf(PDFLib, doc) {
  if (SF_SITE !== "test") return Promise.resolve(doc);
  return doc.embedFont(PDFLib.StandardFonts.HelveticaBold).then(function (font) {
    var pages = doc.getPages(), i, pg, w, h;
    for (i = 0; i < pages.length; i++) {
      pg = pages[i]; w = pg.getWidth(); h = pg.getHeight();
      pg.drawRectangle({ x: 0, y: h - 20, width: w, height: 20, color: PDFLib.rgb(1, 0.957, 0.835) });
      pg.drawText(SF_TEST_WORDS, { x: 14, y: h - 14, size: 11, font: font, color: PDFLib.rgb(0.094, 0.114, 0.18) });
    }
    doc.setTitle("TEST · " + (doc.getTitle() || ""));
    return doc;
  });
}
/* ===== END OF THE SITE BLOCK ===== */

const SHELL = sfName("shop-floor-shell-v4");   // v4 (21 Oct): the shop's own .js and .css are fetched fresh like pages, so a shared file can change in place; older saved copies are cleared
const ownSite = (k) => k.startsWith("shop-floor-shell-") && k.endsWith(SF_SITES.test.ending) === (SF_SITE === "test");   // this site's saved copies, never the other's
const saved = (req) => caches.open(SHELL).then((c) => c.match(req));                                                      // this site's saved copy only
const FILES = ["./", "./index.html", "./manifest.webmanifest", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(FILES)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => ownSite(k) && k !== SHELL).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET") return;
  const url = new URL(e.request.url);
  if (url.hostname.endsWith(".supabase.co")) return;          // live data: leave it alone

  const ours = url.origin === self.location.origin;
  const isPage = ours && (e.request.mode === "navigate" || url.pathname.endsWith(".html") || url.pathname.endsWith("/"));
  const isOurScript = ours && (url.pathname.endsWith(".js") || url.pathname.endsWith(".css"));
  if (isPage || isOurScript) {                                 // fresh when connected, saved copy when not
    e.respondWith(fetch(e.request)
      .then((r) => { const copy = r.clone(); caches.open(SHELL).then((c) => c.put(e.request, copy)); return r; })
      .catch(() => saved(e.request).then((hit) => hit || (isPage ? saved("./index.html") : Promise.reject(new Error("offline"))))));
    return;
  }
  // a checked library asks for a readable (CORS) copy; a saved copy that can't be read would fail the check, so skip it
  const usable = (hit) => hit && !(e.request.mode === "cors" && hit.type === "opaque");
  e.respondWith(saved(e.request).then((hit) => usable(hit) ? hit : fetch(e.request).then((r) => {
    if (r.ok || (r.type === "opaque" && e.request.mode !== "cors")) { const copy = r.clone(); caches.open(SHELL).then((c) => c.put(e.request, copy)); }
    return r;
  }).catch(() => hit || Promise.reject(new Error("offline")))));
});
