#!/usr/bin/env node
import { run } from '../src/cli.mjs';
import { system } from '../src/system.mjs';

try {
  process.exitCode = await run(process.argv.slice(2), system());
} catch (error) {
  console.error(`Tokrate: ${error.message}`);
  process.exitCode = 1;
}
