import {useAppTheme} from '@hzblj/kara-ui'
import {Stack} from 'expo-router'

/** Each tab is a stack of its own, under a native large title. */
export const TabStack = ({title}: {title: string}) => {
  const theme = useAppTheme()

  return (
    <Stack
      screenOptions={{
        contentStyle: {backgroundColor: theme.color('surface.base')},
        headerLargeTitle: true,
        title,
      }}
    />
  )
}
