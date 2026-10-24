import {Box, Skeleton} from '@hzblj/kara-ui'
import {type ReactNode, useRef} from 'react'

type RevealProps = {
  /** Whether the content is there: until then, lines shaped like text hold its place. */
  ready: boolean
  children: ReactNode
  /** Under the lines while they wait: what is being waited for. */
  pending?: ReactNode
}

/**
 * A transcript's place while it is on its way: two lines shaped like text, which cross-fade into the words when they
 * come, while the card eases to its new height. Content that was there from the start (a cached transcript, a card
 * scrolled back into view) shows at once, with nothing to fade.
 */
export const Reveal = ({children, pending, ready}: RevealProps) => {
  const waited = useRef(!ready).current

  return (
    <Box layout>
      {ready ? (
        <Box entering={waited ? 'fade' : undefined} key="content">
          {children}
        </Box>
      ) : (
        <Box exiting="fade" gap="s6" key="pending">
          <Skeleton h={14} />
          <Skeleton h={14} w="60%" />
          {pending}
        </Box>
      )}
    </Box>
  )
}
