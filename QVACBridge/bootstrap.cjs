// QVAC 0.17.1's Bare config loader reads JSON through a CommonJS `require`
// even when the SDK itself is imported from an ES module. Bare does not expose
// that binding to ES modules, so publish the bootstrap's CommonJS loader before
// importing Dropsift's bridge.
globalThis.require = require

import('./bridge.mjs').catch(error => {
  console.error(error)
  Bare.exit(1)
})
