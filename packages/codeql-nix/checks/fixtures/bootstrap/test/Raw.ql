import Bootstrap as Bootstrap

from string file, string text, int sl, int sc, int el, int ec
where
  Bootstrap::raw(file, text, sl, sc, el, ec) and
  text = ["41", "73", "97"]
select file, text, sl, sc, el, ec
