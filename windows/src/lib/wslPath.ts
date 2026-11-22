// Windows paths as WSL's bash sees them.
//
// Project paths are stored the Windows way (`C:\Users\me\repo`). Typed into
// bash as-is, the backslashes are eaten as escapes (`cd C:Usersmerepo`), so
// anything that runs inside WSL needs the `/mnt/<drive>/...` form instead.

/** `C:\Users\me\my repo` -> `/mnt/c/Users/me/my repo`. Anything that is not a
 *  drive-letter path (already a Unix path, a UNC path) comes back unchanged. */
export function windowsPathToWsl(p: string): string {
  const m = /^([A-Za-z]):[\\/]?(.*)$/.exec(p);
  if (!m) return p;
  const rest = m[2].replace(/\\/g, "/").replace(/\/+$/, "");
  return `/mnt/${m[1].toLowerCase()}${rest ? `/${rest}` : ""}`;
}

/** Single-quote a string for bash, so spaces, `$`, quotes etc. survive. */
export function bashQuote(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}
