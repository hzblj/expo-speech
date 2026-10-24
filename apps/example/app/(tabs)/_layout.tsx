import {Tabs} from '@hzblj/kara-ui/router'

export default function TabLayout() {
  return (
    <Tabs>
      <Tabs.Screen icon="radio" name="(radio)" selectedIcon="radio-filled" title="Radio" />
      <Tabs.Screen icon="mic" name="live" selectedIcon="mic-filled" title="Pit wall" />
      <Tabs.Screen icon="tune" name="lab" selectedIcon="tune-filled" title="Lab" />
      <Tabs.Screen icon="translate" name="languages" selectedIcon="translate-filled" title="Languages" />
    </Tabs>
  )
}
