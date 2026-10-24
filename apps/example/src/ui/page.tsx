import {Box, Divider, RnScrollView, RnText, VStack} from '@hzblj/kara-ui'
import type {ReactNode} from 'react'

/**
 * Every screen of the example: one React Native scroll view under the native large title, with room at the end for
 * the tab bar. `overlay` sits above it, for a snackbar or a sheet.
 */
export const Page = ({children, overlay}: {children: ReactNode; overlay?: ReactNode}) => (
  <Box flex={1}>
    <RnScrollView
      bg="surface.base"
      content={{gap: 's32', pb: 's80', pt: 's8', px: 's20'}}
      contentInsetAdjustmentBehavior="automatic"
      flex={1}
      keyboardShouldPersistTaps="handled"
    >
      {children}
    </RnScrollView>
    {overlay}
  </Box>
)

type SectionProps = {
  /** A line under the content: what to notice, or where the platforms differ. */
  caption?: string
  children: ReactNode
  title?: string
}

/** A titled block of a page, in the style of a grouped list's header and footer. */
export const Section = ({caption, children, title}: SectionProps) => (
  <Box gap="s8">
    {title ? (
      <RnText color="content.secondary" variant="footnoteMedium">
        {title.toUpperCase()}
      </RnText>
    ) : null}
    {children}
    {caption ? (
      <RnText color="content.tertiary" variant="footnote">
        {caption}
      </RnText>
    ) : null}
  </Box>
)

/** A divider inset from a native card's edges, the way a grouped list draws one. */
export const InsetDivider = () => (
  <VStack px="s16" wide>
    <Divider />
  </VStack>
)
