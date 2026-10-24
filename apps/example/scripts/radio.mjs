/**
 * Writes `src/f1/radio.json`: one Formula 1 weekend's team radio, captured once from OpenF1 (https://openf1.org), so the
 * example never asks OpenF1 at run time (it closes to the public while a session is live, and limits how often it is
 * asked). The JSON holds the weekend, its qualifying and race, who said what when, and where the recordings are: Formula
 * 1's own files on livetiming.formula1.com, which the app streams. No audio or images are in the repository.
 *
 *   node scripts/radio.mjs 2025 "Abu Dhabi"
 */
import {writeFile} from 'node:fs/promises'
import path from 'node:path'

const [year = '2025', place = 'Abu Dhabi'] = process.argv.slice(2)
const SESSIONS = ['Qualifying', 'Sprint', 'Race']
/** The most messages kept per session, spread over all of it. */
const KEEP = 60

const get = async query => {
  for (let attempt = 0; ; attempt += 1) {
    const response = await fetch(`https://api.openf1.org/v1/${query}`)
    if (response.ok) {
      return response.json()
    }
    if (attempt === 4) {
      throw new Error(`OpenF1 answered ${response.status} for ${query}`)
    }
    await new Promise(resolve => setTimeout(resolve, 1500 * 2 ** attempt))
  }
}

const meetings = await get(`meetings?year=${year}`)
const meeting = meetings.find(candidate =>
  [candidate.meeting_name, candidate.location, candidate.country_name, candidate.circuit_short_name].some(name =>
    name?.toLowerCase().includes(place.toLowerCase())
  )
)
if (!meeting) {
  throw new Error(`No ${year} meeting matches ${place}`)
}

const sessions = (await get(`sessions?meeting_key=${meeting.meeting_key}`))
  .filter(session => SESSIONS.includes(session.session_name))
  .sort((a, b) => b.date_start.localeCompare(a.date_start))

const spread = (items, count) =>
  items.length <= count
    ? items
    : Array.from({length: count}, (_, index) => items[Math.floor((index * items.length) / count)])

const drivers = new Map()
const captured = []

for (const session of sessions) {
  const radio = await get(`team_radio?session_key=${session.session_key}`)
  for (const driver of await get(`drivers?session_key=${session.session_key}`)) {
    drivers.set(driver.driver_number, driver)
  }
  const messages = spread(
    [...radio].sort((a, b) => b.date.localeCompare(a.date)),
    KEEP
  ).map(message => ({date: message.date, driver_number: message.driver_number, recording_url: message.recording_url}))

  captured.push({
    date_start: session.date_start,
    messages,
    session_key: session.session_key,
    session_name: session.session_name,
  })
  console.log(`${session.session_name}: ${messages.length} of ${radio.length} messages`)
}

const data = {
  drivers: [...drivers.values()]
    .sort((a, b) => a.driver_number - b.driver_number)
    .map(driver => ({
      broadcast_name: driver.broadcast_name,
      driver_number: driver.driver_number,
      first_name: driver.first_name,
      full_name: driver.full_name,
      headshot_url: driver.headshot_url,
      last_name: driver.last_name,
      name_acronym: driver.name_acronym,
      team_colour: driver.team_colour,
      team_name: driver.team_name,
    })),
  meeting: {
    circuit_short_name: meeting.circuit_short_name,
    country_code: meeting.country_code,
    date_start: meeting.date_start,
    meeting_key: meeting.meeting_key,
    meeting_name: meeting.meeting_name,
    year: meeting.year,
  },
  sessions: captured,
}

const target = path.join(import.meta.dirname, '..', 'src', 'f1', 'radio.json')
await writeFile(target, `${JSON.stringify(data, null, 2)}\n`)
console.log(`${meeting.meeting_name} ${meeting.year} → ${path.relative(process.cwd(), target)}`)
