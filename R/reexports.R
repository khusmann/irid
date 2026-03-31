# Re-exports from shiny --------------------------------------------------
# We use @rawNamespace rather than the usual `fun <- pkg::fun` pattern
# because the assignment form creates a local copy of the function.
# In shinylive/WebR, shiny's reactiveVal (and others) use sys.call()
# introspection that breaks when called through a copied binding —
# the srcref attributes are lost, causing "could not find function
# get_call_srcref" errors. The @rawNamespace form generates the same
# NAMESPACE directives (importFrom + export) without creating local
# copies, so R resolves the functions directly from shiny's namespace.

#' Shiny reactive primitives
#'
#' These functions are re-exported from \pkg{shiny} for convenience, so you
#' can use them in nacre apps without loading shiny explicitly.
#'
#' - [reactiveVal()]: Create a reactive value
#' - [reactive()]: Create a reactive expression
#' - [observe()]: Create an observer
#' - [observeEvent()]: Create an event-driven observer
#' - [isolate()]: Run an expression without reactive dependencies
#' - [tags]: HTML tag builder
#' - [tagList()]: Combine tags into a list
#'
#' See the \pkg{shiny} documentation for full details.
#'
#' @name reactiveVal
#' @aliases reactive observe observeEvent isolate tags tagList
#' @rawNamespace
#'   importFrom(shiny, reactiveVal)
#'   export(reactiveVal)
#'   importFrom(shiny, reactive)
#'   export(reactive)
#'   importFrom(shiny, observe)
#'   export(observe)
#'   importFrom(shiny, observeEvent)
#'   export(observeEvent)
#'   importFrom(shiny, isolate)
#'   export(isolate)
#'   importFrom(shiny, tags)
#'   export(tags)
#'   importFrom(shiny, tagList)
#'   export(tagList)
NULL
