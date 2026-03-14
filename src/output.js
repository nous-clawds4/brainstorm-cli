/**
 * Output formatting utility.
 * JSON by default (for agents), pretty-print with --pretty flag.
 */

export function output(data, opts = {}) {
  if (opts.pretty) {
    console.log(JSON.stringify(data, null, 2));
  } else {
    console.log(JSON.stringify(data));
  }
}

export function outputError(message, details) {
  const err = { error: message };
  if (details) err.details = details;
  console.error(JSON.stringify(err));
  process.exit(1);
}
