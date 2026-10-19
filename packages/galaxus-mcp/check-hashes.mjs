#!/usr/bin/env node
// Is every persisted GraphQL operation hash still accepted by the shop? When
// Galaxus deploys a new frontend it rotates them and all seven tools fail at
// once, so this runs daily on vps and exports the answer as a node-exporter
// textfile metric; the alert threshold lives centrally in monitoring.nix.
//
// Upstream's scripts/check-hashes.mjs does the same probe but imports
// ../dist/client.js by relative path and is not in package.json's `files`, so it
// is not installed. Its trick is the part worth keeping: post an operation with
// EMPTY variables. The shop validates the hash before the variables, so a live
// hash complains about a missing variable while a rotated one answers "The
// specified persisted operation key is invalid." - both inside an HTTP 200.
//
// No browser and no page fetch, which is why this works on vps at all: the
// GraphQL endpoints answer from there, the HTML and JS bundles a hash *refresh*
// would need are refused. Refreshing stays manual, on framework, and lands in
// packages/galaxus-mcp/operations.json.
import { mkdtempSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { GalaxusClient, GalaxusError, OPERATION_NAMES } from "./dist/client.js";

const client = new GalaxusClient({});
const stale = [];
const unreachable = [];

for (const operation of OPERATION_NAMES) {
  try {
    await client.query(operation, {});
    // No error at all means the operation takes no variables - the hash is fine
    // either way.
  } catch (error) {
    if (error instanceof GalaxusError && error.hint?.includes("refresh-hashes")) {
      stale.push(operation);
    } else if (error instanceof GalaxusError && /API error on/.test(error.message)) {
      // A GraphQL error that is not the rotated-key one: the hash was accepted,
      // which is all this checks.
    } else {
      unreachable.push(`${operation}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
}

// A network failure must never be reported as a rotation: that would page about
// a frontend deploy that never happened, and the fix it names would be wrong.
// Leave the last good metric in place and fail the unit instead - the timestamp
// below going stale is the signal that this stopped running.
if (unreachable.length) {
  console.error(`galaxus-mcp: ${unreachable.length}/${OPERATION_NAMES.length} operations unreachable`);
  for (const line of unreachable) console.error(`  ${line}`);
  process.exit(1);
}

const metrics = [
  "# HELP galaxus_stale_operation_hashes Persisted GraphQL operation hashes the shop no longer accepts.",
  "# TYPE galaxus_stale_operation_hashes gauge",
  `galaxus_stale_operation_hashes ${stale.length}`,
  "# HELP galaxus_hash_check_timestamp_seconds Unix time of the last completed hash check.",
  "# TYPE galaxus_hash_check_timestamp_seconds gauge",
  `galaxus_hash_check_timestamp_seconds ${Math.floor(Date.now() / 1000)}`,
  "",
].join("\n");

const directory = process.env.GALAXUS_TEXTFILE_DIRECTORY;
if (!directory) {
  // Handy when running this by hand.
  process.stdout.write(metrics);
} else {
  // The collector must never read a half-written file, so write it elsewhere and
  // rename it into place. A directory alongside, not a `.$$` suffix in the
  // collector's own directory, which would be scraped as a metrics file itself.
  const staging = mkdtempSync(join(directory, ".galaxus-hashes-"));
  const temporary = join(staging, "galaxus-hashes.prom");
  writeFileSync(temporary, metrics);
  renameSync(temporary, join(directory, "galaxus-hashes.prom"));
}

if (stale.length) {
  console.error(
    `galaxus-mcp: ${stale.length}/${OPERATION_NAMES.length} operation hashes have rotated: ${stale.join(", ")}`,
  );
  console.error(
    "Re-capture them headed on framework (npm run refresh-hashes), copy the result into " +
      "packages/galaxus-mcp/operations.json, then `just switch vps`.",
  );
}
