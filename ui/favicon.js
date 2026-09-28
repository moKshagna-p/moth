(() => {
  if (!['http:', 'https:'].includes(location.protocol)) {
    return { page: location.href, icon: null };
  }
  const links = Array.from(document.querySelectorAll('link[rel]'));
  const icons = links.filter(link => link.rel.toLowerCase().split(/\s+/).includes('icon'));
  const touchIcons = links.filter(link => link.rel.toLowerCase().split(/\s+/).includes('apple-touch-icon'));
  for (const link of [...icons, ...touchIcons]) {
    const href = link.getAttribute('href');
    if (!href || !href.trim()) continue;
    try {
      const icon = new URL(href, document.baseURI);
      if (['http:', 'https:'].includes(icon.protocol) && !icon.username && !icon.password) {
        return { page: location.href, icon: icon.href };
      }
    } catch (_) {}
  }
  return { page: location.href, icon: new URL('/favicon.ico', location.href).href };
})()
