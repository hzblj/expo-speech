import {useAppTheme} from '@hzblj/kara-ui'
import {router, Stack} from 'expo-router'
import {useEffect} from 'react'

import {capture} from '../src/capture'
import {Providers} from '../src/providers'

const RootStack = () => {
  const theme = useAppTheme()

  // The `captureRoute` launch argument opens a tab of its own: the captures' way around a simulator without taps.
  useEffect(() => {
    const route = capture.route
    if (route) {
      requestAnimationFrame(() => router.navigate(route as never))
    }
  }, [])

  return (
    <Stack screenOptions={{contentStyle: {backgroundColor: theme.color('surface.base')}, headerShown: false}}>
      <Stack.Screen name="(tabs)" />
    </Stack>
  )
}

export default function RootLayout() {
  return (
    <Providers>
      <RootStack />
    </Providers>
  )
}
