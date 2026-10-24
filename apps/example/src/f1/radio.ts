import data from './radio.json'

/**
 * One Formula 1 weekend's team radio, captured from OpenF1 (https://openf1.org) into `radio.json` by
 * `scripts/radio.mjs`: who said what and when, and where the recordings are. The recordings are Formula 1's own files on
 * livetiming.formula1.com, streamed while the app runs; none of them ship with the example, and nothing asks OpenF1 at
 * run time.
 */

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

type Weekend = {
  meeting: {
    meeting_key: number
    meeting_name: string
    circuit_short_name: string
    country_code: string
    date_start: string
    year: number
  }
  drivers: Driver[]
  sessions: {
    session_key: number
    session_name: string
    date_start: string
    messages: {date: string; driver_number: number; recording_url: string}[]
  }[]
}

export type RadioClip = {
  id: string
  url: string
  date: Date
  driver: Driver | undefined
}

export type RadioSession = {key: number; name: string; clips: RadioClip[]}

const weekend = data as Weekend
const byNumber = new Map(weekend.drivers.map(driver => [driver.driver_number, driver]))

export const MEETING = weekend.meeting
export const DRIVERS = weekend.drivers

/** The weekend's sessions, the last first, each with its messages, the newest first. */
export const SESSIONS: RadioSession[] = weekend.sessions.map(session => ({
  clips: session.messages.map(message => ({
    date: new Date(message.date),
    driver: byNumber.get(message.driver_number),
    id: message.recording_url,
    url: message.recording_url,
  })),
  key: session.session_key,
  name: session.session_name,
}))

/** What the single-message screens play: the race's latest message from a driver. */
export const FIRST_CLIP: RadioClip | undefined = SESSIONS.flatMap(session => session.clips).find(clip => clip.driver)

/** `#RRGGBB` for a team, with a neutral grey for a driver without one. */
export const teamColor = (driver: Pick<Driver, 'team_colour'> | undefined) =>
  driver?.team_colour ? `#${driver.team_colour}` : '#8e8e93'

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
