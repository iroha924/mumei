import os from 'node:os'
import path from 'node:path'

/**
 * Convert an absolute path to a home-relative form when the path is
 * under $HOME, else return the absolute path unchanged. Drives the
 * TopBar project label per REQ-15.6.
 *
 * The `home` argument exists for testability; in production use
 * `homeRelative(p)` and the caller defaults to `os.homedir()`.
 */
export function homeRelative(absPath: string, home: string = os.homedir()): string {
  if (!absPath) return absPath
  const normAbs = path.resolve(absPath)
  const normHome = path.resolve(home)
  if (normAbs === normHome) return '~'
  const prefix = normHome.endsWith(path.sep) ? normHome : normHome + path.sep
  if (normAbs.startsWith(prefix)) {
    return `~${path.sep}${normAbs.slice(prefix.length)}`
  }
  return normAbs
}
