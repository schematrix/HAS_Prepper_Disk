/* Rehber sayfalarındaki "daha fazla oku" bağlantılarını kutudaki ZIM'lere bağlar.
   <a class="ara" data-zim="wikipedia_tr_all" data-q="İlk yardım">...</a>
   data-zim: Kiwix dosya adının tarihsiz başı (ana sayfadaki CATS listesiyle aynı).
   data-q:   o kitapta aranacak sözcük.
   Kitap kutuda yüklü değilse bağlantı gri görünür ve "(yüklü değil)" yazar.

   Links the guide's "read more" links to the ZIMs installed on the box. A link whose
   book is not installed is greyed out. */
(function () {
  var links = document.querySelectorAll("a.ara[data-zim]");
  if (!links.length) return;
  fetch("/kiwix/catalog/v2/entries?count=-1").then(function (r) { return r.text(); }).then(function (t) {
    var xml = new DOMParser().parseFromString(t, "application/xml");
    var ids = [];
    xml.querySelectorAll("entry").forEach(function (e) {
      var l = e.querySelector('link[type="text/html"]');
      if (l) ids.push(l.getAttribute("href").split("/").filter(Boolean).pop());
    });
    links.forEach(function (a) {
      var pre = a.getAttribute("data-zim") + "_";
      var id = ids.filter(function (i) { return i.indexOf(pre) === 0; }).sort().pop();
      if (id) a.href = "/kiwix/search?books.name=" + encodeURIComponent(id) +
        "&pattern=" + encodeURIComponent(a.getAttribute("data-q"));
      else a.className += " yok";
    });
  }).catch(function () {
    // Katalog okunamazsa kütüphaneye yönlendir / catalog unreachable: point at the library
    links.forEach(function (a) { a.href = "/kiwix/"; });
  });
})();
