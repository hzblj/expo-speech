import {adaptive, defineTheme} from '@hzblj/kara-ui'

/**
 * Pit wall colours: Formula 1's red as kara's accent, on the dark surfaces of a timing screen. Every accent token is
 * set in one place, and the Android seed moves with them.
 */
export const theme = defineTheme({
  colors: {
    border: {accent: '#e10600'},
    content: {accent: adaptive({dark: '#ff4d47', light: '#c20500'})},
    fill: {
      accent: {
        base: adaptive({dark: '#e1060033', light: '#fde7e6'}),
        disabled: adaptive({dark: '#e106001f', light: '#f8c9c7'}),
        primary: '#e10600',
      },
    },
    shadow: {btn: {accent: {ring: adaptive({dark: '#e1060000', light: '#f5b3b1'})}}},
  },
  materialSeed: '#e10600',
})
