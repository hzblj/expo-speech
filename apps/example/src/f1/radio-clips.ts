import {useMemo} from 'react'

import {type Driver, type Meeting, type Session, type TeamRadio, useOpenF1} from './openf1'

export type RadioClip = {
  id: string
  url: string
  date: Date
  driver: Driver | undefined
}

/** The latest weekend: its meeting and every session of it, the newest first. */
export const useLatestWeekend = () => {
  const latest = useOpenF1<Session[]>('sessions?session_key=latest')
  const meetingKey = latest.data?.[0]?.meeting_key
  const meeting = useOpenF1<Meeting[]>(meetingKey ? `meetings?meeting_key=${meetingKey}` : null)
  const sessions = useOpenF1<Session[]>(meetingKey ? `sessions?meeting_key=${meetingKey}` : null)

  return {
    error: latest.error ?? meeting.error ?? sessions.error,
    loading: latest.loading || meeting.loading || sessions.loading,
    meeting: meeting.data?.[0] ?? null,
    sessions: useMemo(
      () =>
        [...(sessions.data ?? [])]
          .filter(session => new Date(session.date_start).getTime() <= Date.now())
          .sort((a, b) => b.date_start.localeCompare(a.date_start)),
      [sessions.data]
    ),
  }
}

/** A session's team radio with its drivers, the newest message first. */
export const useRadioClips = (sessionKey: number | null) => {
  const radio = useOpenF1<TeamRadio[]>(sessionKey ? `team_radio?session_key=${sessionKey}` : null)
  const drivers = useOpenF1<Driver[]>(sessionKey ? `drivers?session_key=${sessionKey}` : null)

  const clips = useMemo(() => {
    const byNumber = new Map((drivers.data ?? []).map(driver => [driver.driver_number, driver]))

    return [...(radio.data ?? [])]
      .sort((a, b) => b.date.localeCompare(a.date))
      .map<RadioClip>(message => ({
        date: new Date(message.date),
        driver: byNumber.get(message.driver_number),
        id: message.recording_url,
        url: message.recording_url,
      }))
  }, [radio.data, drivers.data])

  return {
    clips,
    drivers: drivers.data,
    error: radio.error ?? drivers.error,
    loading: radio.loading || drivers.loading,
  }
}
