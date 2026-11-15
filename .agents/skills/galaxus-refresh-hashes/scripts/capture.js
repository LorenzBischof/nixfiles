async page => {
  const wanted = __OPERATIONS__;
  const operations = {};
  const errors = [];
  let clientVersion;
  const artifact = /params:\s*\{id:\s*"([a-f0-9]{32})",\s*metadata:\{[^}]*\},\s*name:\s*"(\w+)"/g;
  const readArtifacts = source => {
    for (const match of source.matchAll(artifact)) {
      if (wanted.includes(match[2])) operations[match[2]] = match[1];
    }
  };
  page.on('request', request => {
    const match = request.url().match(/\/graphql\/o\/([a-f0-9]{32})\/(\w+)/);
    if (!match) return;
    if (wanted.includes(match[2])) operations[match[2]] = match[1];
    clientVersion = request.headers()['x-dg-graphql-client-version'] ?? clientVersion;
  });

  const paths = [
    '/en/search?q=logitech%20mx%20master',
    '/en/s1/producttype/mouse-62',
    '/en/s1/product/logitech-mx-master-3s-wireless-mouse-61318913',
    '/en/brand/logitech-292',
  ];
  for (const path of paths) {
    try {
      await page.goto('https://www.galaxus.ch' + path, {
        waitUntil: 'domcontentloaded', timeout: 60000,
      });
      await page.waitForTimeout(6000);
      if (path.includes('/product/')) {
        // Ratings are lazy-loaded; scrolling alone did not load their artifact.
        await page.getByRole('button', { name: /^Product ratings/ }).click({ timeout: 10000 });
      }
      await page.mouse.wheel(0, 4000);
      await page.waitForTimeout(3000);
      // Read loaded bundles, including operations that never fired as requests.
      const urls = await page.evaluate(() => performance.getEntriesByType('resource')
        .map(r => r.name).filter(url => /\.js(\?|$)/.test(url)));
      for (const url of new Set(urls)) {
        try {
          const response = await page.context().request.get(url, { timeout: 15000 });
          if (response.ok()) readArtifacts(await response.text());
        } catch { /* Missing hashes below determine whether capture succeeded. */ }
      }
    } catch (error) {
      errors.push(`${path}: ${error.message.split('\n')[0]}`);
    }
  }
  return { operations, clientVersion, errors };
}
