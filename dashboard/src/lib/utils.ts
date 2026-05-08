import { type ClassValue, clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

/**
 * shadcn/ui canonical class-merger. Use everywhere we conditionally
 * compose Tailwind utility classes so latter declarations override
 * earlier ones in the merged string.
 */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs))
}
