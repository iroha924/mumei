// Allowlist for featureKey segments used in filesystem paths under
// .mumei/{specs,plans,archive}/. Mirrors the TypeBox SlugParam pattern
// in server/index.ts; duplicated here as an explicit sanitiser so that
// CodeQL's path-injection dataflow recognises the guard at every public
// API entry point — TypeBox JSON Schema validation is not modelled by
// CodeQL as a sanitiser. Length cap matches SlugParam (maxLength: 100).
const FEATURE_KEY_RE = /^[A-Za-z0-9_-]{1,100}$/

export function isValidFeatureKey(key: string): boolean {
  return FEATURE_KEY_RE.test(key)
}
