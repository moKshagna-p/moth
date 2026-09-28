// Read colors only; no page-to-browser command bridge or image downloads.
(() => {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) return null;
  const parse = value => {
    if (!value || !CSS.supports("color", value)) return null;
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = value;
    ctx.fillRect(0, 0, 1, 1);
    return Array.from(ctx.getImageData(0, 0, 1, 1).data);
  };
  const over = (fg, bg) => fg
    ? bg.map((v, i) => Math.round(fg[i] * fg[3] / 255 + v * (1 - fg[3] / 255)))
    : bg;
  const root = getComputedStyle(document.documentElement);
  let color = root.colorScheme === "dark" ? [28, 28, 30] : [255, 255, 255];
  color = over(parse(root.backgroundColor), color);
  if (document.body) color = over(parse(getComputedStyle(document.body).backgroundColor), color);
  for (const meta of document.querySelectorAll('meta[name="theme-color" i]')) {
    if (meta.media && !matchMedia(meta.media).matches) continue;
    const theme = parse(meta.content);
    if (theme && theme[3] > 0) { color = over(theme, color); break; }
  }
  return { url: location.href, color };
})()
