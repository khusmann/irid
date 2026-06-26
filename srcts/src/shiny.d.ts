// Bridges over the official Shiny types (@types/rstudio-shiny, pinned to a git
// tag in package.json). Those augment `window.Shiny` with the full `ShinyClass`;
// here we only cover the gaps they leave for irid's usage. Keep this file
// import/export-free so it stays an ambient (global) declaration.

// irid's code uses the bare `Shiny` global; alias it to the official type.
declare const Shiny: Window["Shiny"];

// The minimal jQuery surface irid touches: $(document).on/.one, used for the
// shiny:idle / shiny:busy events. (Not worth pulling in all of @types/jquery.)
interface IridJQuery {
  on(event: string, handler: (...args: any[]) => void): IridJQuery;
  one(event: string, handler: (...args: any[]) => void): IridJQuery;
}
declare function $(target: Document | Element): IridJQuery;
