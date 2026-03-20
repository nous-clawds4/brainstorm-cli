/**
 * Output formatting utility.
 * JSON by default (for agents), pretty-print with --pretty flag.
 *
 * Call configure() once after argument parsing to set global options.
 */

let prettyPrint = false;

export function configure(opts = {}) {
  prettyPrint = !!opts.pretty;
}

export function output(data) {
  if (prettyPrint) {
    console.log(JSON.stringify(data, null, 2));
  } else {
    console.log(JSON.stringify(data));
  }
}

export function outputError(message, details) {
  const err = { error: message };
  if (details) err.details = details;
  console.error(prettyPrint ? JSON.stringify(err, null, 2) : JSON.stringify(err));
  process.exit(1);
}
