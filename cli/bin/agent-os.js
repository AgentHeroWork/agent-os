#!/usr/bin/env node

/**
 * Agent-OS CLI entry point.
 * Imports the main module and runs the CLI.
 */

import { main } from '../src/main.js';

main(process.argv.slice(2));
