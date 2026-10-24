import {useEffect, useState} from 'react'

/**
 * OpenF1 (https://openf1.org): free, unofficial Formula 1 timing data, the team radio among it. The recordings are
 * Formula 1's own files on livetiming.formula1.com, fetched when the app runs; none of them ship with the example.
 */
const BASE = 'https://api.openf1.org/v1'

export type Meeting = {
  meeting_key: number
  meeting_name: string
  country_code: string
  country_name: string
  circuit_short_name: string
  location: string
  date_start: string
  year: number
}

export type Session = {
  session_key: number
  session_name: string
  session_type: string
  meeting_key: number
  country_code: string
  circuit_short_name: string
  date_start: string
  date_end: string
  year: number
}

export type Driver = {
  driver_number: number
  broadcast_name: string
  full_name: string
  name_acronym: string
  team_name: string | null
  team_colour: string | null
  first_name: string
  last_name: string
  headshot_url: string | null
}

export type TeamRadio = {
  date: string
  driver_number: number
  session_key: number
  meeting_key: number
  recording_url: string
}

const cache = new Map<string, Promise<unknown>>()

/** One request per path for the app's lifetime: past sessions don't change, and OpenF1 is a free service. */
export const fetchOpenF1 = <T>(path: string): Promise<T> => {
  const cached = cache.get(path)

  if (cached) {
    return cached as Promise<T>
  }

  const request = (async () => {
    // OpenF1 limits how often it is asked: wait as long as it says (or longer each time) and ask again.
    for (let attempt = 0; ; attempt += 1) {
      const response = await fetch(`${BASE}/${path}`)

      if (response.ok) {
        return (await response.json()) as T
      }
      if (response.status !== 429 || attempt === 4) {
        throw new Error(`OpenF1 answered ${response.status} for ${path}`)
      }

      const retryAfter = Number(response.headers.get('retry-after'))
      const wait = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 1000 * 2 ** attempt
      await new Promise(resolve => setTimeout(resolve, wait))
    }
  })()

  request.catch(() => cache.delete(path))
  cache.set(path, request)
  return request
}

export type Loadable<T> = {data: T | null; error: Error | null; loading: boolean}

export const useOpenF1 = <T>(path: string | null): Loadable<T> => {
  const [state, setState] = useState<Loadable<T>>({data: null, error: null, loading: path !== null})

  useEffect(() => {
    if (!path) {
      setState({data: null, error: null, loading: false})
      return
    }

    let current = true

    setState(previous => ({...previous, error: null, loading: true}))
    fetchOpenF1<T>(path).then(
      data => current && setState({data, error: null, loading: false}),
      error => current && setState({data: null, error, loading: false})
    )

    return () => {
      current = false
    }
  }, [path])

  return state
}

/** The ISO 3166 alpha-3 codes OpenF1 uses, as the alpha-2 ones flags are drawn for: every country on the calendar. */
const ALPHA2: Record<string, string> = {
  ARE: 'AE',
  AUS: 'AU',
  AUT: 'AT',
  AZE: 'AZ',
  BEL: 'BE',
  BHR: 'BH',
  BRA: 'BR',
  CAN: 'CA',
  CHN: 'CN',
  ESP: 'ES',
  GBR: 'GB',
  HUN: 'HU',
  ITA: 'IT',
  JPN: 'JP',
  KSA: 'SA',
  MCO: 'MC',
  MEX: 'MX',
  MON: 'MC',
  NED: 'NL',
  NLD: 'NL',
  QAT: 'QA',
  SAU: 'SA',
  SGP: 'SG',
  UAE: 'AE',
  USA: 'US',
}

export const flagCode = (alpha3: string) => ALPHA2[alpha3] ?? null

/** `#RRGGBB` for a team, with a neutral grey for a driver OpenF1 has no team for. */
export const teamColor = (driver: Pick<Driver, 'team_colour'> | undefined) =>
  driver?.team_colour ? `#${driver.team_colour}` : '#8e8e93'
