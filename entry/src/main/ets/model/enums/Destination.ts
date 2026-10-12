/*
 * Port of net.newpipe.app.navigation.Destination (NewPipe shared module).
 * A Kotlin sealed interface of NavKey data objects; on HarmonyOS a route name is a string, so
 * each data object becomes the route the NavPathStack pushes.
 */
export enum Destination {
  Settings = 'Settings',
  About = 'About'
}
